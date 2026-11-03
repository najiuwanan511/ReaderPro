import XCTest
import WebKit
import Network
import UIKit
@testable import ProxyProbe

// A separate, tiny host tests Apple's API without ReaderPro's rule engine,
// schedulers or WebView loader. Production routing assertions remain intact.
@MainActor final class ProxyProbeTests: XCTestCase {
    enum Store { case ephemeral, identified, shared }
    func probe(socks: Bool, store kind: Store, warmup: Bool = false, https: Bool = false, matching: Int = 0) async {
        let store: WKWebsiteDataStore
        switch kind {
        case .ephemeral: store = .nonPersistent()
        case .identified: store = WKWebsiteDataStore(forIdentifier: UUID())
        case .shared: store = .default()
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        func configure() {
            if matching > 0 { XCTAssertTrue(RPProbeSetDefaultProxy(store, socks, matching == 2)) }
            else { XCTAssertTrue(RPSetWebProxy(store, "127.0.0.1", socks ? 8769 : 8765, socks,
                                               socks ? "fixture-user" : nil, socks ? "fixture-pass" : nil)) }
        }
        configure()
        let loader = ProbeLoader(configuration)
        defer { loader.stop(); _ = RPSetWebProxy(store, nil, 0, false, nil, nil) }
        do {
            if warmup { _ = try await loader.page(html: "<html><body>warmup</body></html>", url: URL(string: "about:blank")!) }
            _ = await store.httpCookieStore.allCookies()
            configure()
            _ = await store.httpCookieStore.allCookies()
            let target = socks ? "http://192.0.2.1/source-proxy-test" : (https ? "https://readerproxy.invalid/source-proxy-https-test" : "http://readerproxy.invalid/source-proxy-test")
            let result = try await loader.page(url: URL(string: target)!)
            print("WEBKIT_PROXY_PROBE socks=\(socks) store=\(kind) warmup=\(warmup) https=\(https) matching=\(matching) result=\(result)")
            XCTAssertEqual(result, socks ? "socks5-routed" : (https ? "https-proxy-routed" : "proxy-routed:readerproxy.invalid"))
        } catch {
            print("WEBKIT_PROXY_PROBE socks=\(socks) store=\(kind) warmup=\(warmup) https=\(https) matching=\(matching) error=\(error)")
            XCTFail(String(describing: error))
        }
    }
    func testEphemeralHTTP() async { await probe(socks: false, store: .ephemeral) }
    func testEphemeralSOCKS() async { await probe(socks: true, store: .ephemeral) }
    func testIdentifiedHTTP() async { await probe(socks: false, store: .identified) }
    func testIdentifiedSOCKS() async { await probe(socks: true, store: .identified) }
    func testSharedHTTP() async { await probe(socks: false, store: .shared) }
    func testSharedSOCKS() async { await probe(socks: true, store: .shared) }
    func testWarmupHTTP() async { await probe(socks: false, store: .ephemeral, warmup: true) }
    func testWarmupSOCKS() async { await probe(socks: true, store: .ephemeral, warmup: true) }
    func testEphemeralHTTPS() async { await probe(socks: false, store: .ephemeral, https: true) }
    func testDefaultMatchingHTTP() async { await probe(socks: false, store: .ephemeral, warmup: true, matching: 1) }
    func testDefaultMatchingSOCKS() async { await probe(socks: true, store: .ephemeral, warmup: true, matching: 1) }
    func testExactMatchingHTTP() async { await probe(socks: false, store: .ephemeral, warmup: true, matching: 2) }
    func testExactMatchingSOCKS() async { await probe(socks: true, store: .ephemeral, warmup: true, matching: 2) }
}

@MainActor private final class ProbeLoader: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private var continuation: CheckedContinuation<String, Error>?
    private var timer: Task<Void, Never>?
    init(_ configuration: WKWebViewConfiguration) {
        web = WKWebView(frame: UIScreen.main.bounds, configuration: configuration)
        super.init()
        web.navigationDelegate = self
        UIApplication.shared.windows.first(where: \.isKeyWindow)?.insertSubview(web, at: 0)
    }
    func stop() { timer?.cancel(); web.stopLoading(); web.removeFromSuperview(); web.navigationDelegate = nil }
    func page(html: String? = nil, url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timer = Task {
                do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
                finish(.failure(URLError(.timedOut)))
            }
            if let html { web.loadHTMLString(html, baseURL: nil) }
            else { web.load(URLRequest(url: url)) }
        }
    }
    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timer?.cancel(); timer = nil
        continuation.resume(with: result)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            do { finish(.success((try await webView.evaluateJavaScript("document.body.innerText") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))) }
            catch { finish(.failure(error)) }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Only this isolated fixture host has a locally generated certificate.
        if challenge.protectionSpace.host == "readerproxy.invalid", let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }
}
