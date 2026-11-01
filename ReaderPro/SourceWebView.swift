import Foundation
import WebKit
import Security

@MainActor final class SourceWebLoader: NSObject, WKNavigationDelegate {
    private static var active: [UUID: SourceWebLoader] = [:]
    private let id = UUID()
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<SourcePage, Error>?
    private var timer: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var script = ""
    private var delay: Double = 0
    private var startedPolling = false
    private var allowsInvalidCertificates = false

    static func load(_ request: URLRequest, html: String? = nil, script: String = "", timeout: Double = 20, delay: Double = 0) async throws -> SourcePage {
        // Each WKWebView can launch a separate WebKit process. Keeping only
        // two active reduces peak memory when many book sources are searched.
        while active.count >= 2 { try await Task.sleep(nanoseconds: 50_000_000) }
        let loader = SourceWebLoader()
        loader.allowsInvalidCertificates = SourceTLS.allowsInvalidCertificates
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                active[loader.id] = loader
                loader.continuation = continuation; loader.script = script; loader.delay = delay
                let config = WKWebViewConfiguration()
                config.websiteDataStore = loader.allowsInvalidCertificates ? .nonPersistent() : .default()
                let web = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844), configuration: config)
                loader.webView = web; web.navigationDelegate = loader
                web.customUserAgent = request.value(forHTTPHeaderField: "User-Agent") ?? sourceUA
                loader.timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    loader.finish(.failure(SourceFailure(stage: "网页脚本", message: "WebView 加载或脚本等待超时", url: request.url?.absoluteString ?? "")))
                }
                Task {
                    for cookie in HTTPCookieStorage.shared.cookies ?? [] {
                        await config.websiteDataStore.httpCookieStore.setCookie(cookie)
                    }
                    guard loader.continuation != nil else { return }
                    if let html, !html.isEmpty { web.loadHTMLString(html, baseURL: request.url) }
                    else { web.load(request) }
                }
            }
        } onCancel: {
            Task { @MainActor in loader.finish(.failure(CancellationError())) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !startedPolling else { return }; startedPolling = true
        polling = Task {
            // Give asynchronous page scripts a chance to populate the DOM.
            try? await Task.sleep(nanoseconds: UInt64(max(0.35, min(delay, 3600)) * 1_000_000_000))
            while !Task.isCancelled, continuation != nil {
                do {
                    let value = try await webView.evaluateJavaScript(script.isEmpty ? "document.documentElement.outerHTML" : script)
                    if let value, !(value is NSNull) {
                        let text: String
                        if let string = value as? String { text = string }
                        else if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) { text = String(decoding: data, as: UTF8.self) }
                        else { text = String(describing: value) }
                        if !text.isEmpty {
                            for cookie in await webView.configuration.websiteDataStore.httpCookieStore.allCookies() { HTTPCookieStorage.shared.setCookie(cookie) }
                            finish(.success(.init(text: text, url: webView.url?.absoluteString ?? ""))); return
                        }
                    }
                } catch {
                    finish(.failure(SourceFailure(stage: "网页脚本", message: error.localizedDescription, url: webView.url?.absoluteString ?? ""))); return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if allowsInvalidCertificates, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.performDefaultHandling, nil) }
    }

    private func finish(_ result: Result<SourcePage, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel(); polling?.cancel(); webView?.stopLoading(); webView?.navigationDelegate = nil; webView = nil
        Self.active[id] = nil
        continuation.resume(with: result)
    }
}

extension SourceJSBridge {
    final class WebBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<SourcePage, Error>?
        func set(_ result: Result<SourcePage, Error>) { lock.lock(); value = result; lock.unlock() }
        func get() -> Result<SourcePage, Error>? { lock.lock(); defer { lock.unlock() }; return value }
    }
    static func web(_ request: URLRequest, html: String? = nil, script: String = "", delay: Double = 0) throws -> SourcePage {
        guard !Thread.isMainThread else { throw SourceFailure(stage: "脚本兼容性", message: "WebView 脚本必须在后台书源任务中执行") }
        let box = WebBox()
        let timeout = max(0.1, min(20, LegadoJSCtx.deadline?.timeIntervalSinceNow ?? 20))
        let task = Task { @MainActor in
            do { box.set(.success(try await SourceWebLoader.load(request, html: html, script: script, timeout: timeout, delay: delay))) }
            catch { box.set(.failure(error)) }
        }
        let deadline = Date().addingTimeInterval(timeout + 1)
        while box.get() == nil {
            if Task.isCancelled { task.cancel(); throw CancellationError() }
            if Date() >= deadline { task.cancel(); throw URLError(.timedOut) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return try box.get()!.get()
    }
}
