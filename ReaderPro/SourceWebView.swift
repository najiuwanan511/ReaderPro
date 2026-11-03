import Foundation
import WebKit
import Security
import UIKit

@MainActor final class SourceWebLoader: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
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
    private var cookiesEnabled = true
    private var resourcePattern: NSRegularExpression?
    private var navigationPattern: NSRegularExpression?
    private var initialURL = ""
    private var loadingPhase = "准备网页"
    private var capturesURL: Bool { resourcePattern != nil || navigationPattern != nil }

    static func load(_ request: URLRequest, html: String? = nil, script: String = "", timeout: Double = 20, delay: Double = 0,
                     resourceRegex: String? = nil, navigationRegex: String? = nil, cacheFirst: Bool = false) async throws -> SourcePage {
        let store = try SourceWebDataStore.make(request: request,
            ephemeral: SourceTLS.allowsInvalidCertificates || !(LegadoJSCtx.ruleSource?.enabledCookieJar ?? true))
        // Each WKWebView can launch a separate WebKit process. Keeping only
        // two active reduces peak memory when many book sources are searched.
        try await SourceRateLimiter.shared.wait()
        while active.count >= 2 { try await Task.sleep(nanoseconds: 50_000_000) }
        let loader = SourceWebLoader()
        loader.resourcePattern = try resourceRegex.map { try NSRegularExpression(pattern: $0) }
        loader.navigationPattern = try navigationRegex.map { try NSRegularExpression(pattern: $0) }
        loader.initialURL = request.url?.absoluteString ?? ""
        loader.allowsInvalidCertificates = SourceTLS.allowsInvalidCertificates
        loader.cookiesEnabled = LegadoJSCtx.ruleSource?.enabledCookieJar ?? true
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                active[loader.id] = loader
                loader.continuation = continuation; loader.script = script; loader.delay = delay
                let config = WKWebViewConfiguration()
                config.websiteDataStore = store
                if loader.resourcePattern != nil {
                    config.userContentController.add(loader, name: "readerResource")
                    config.userContentController.addUserScript(WKUserScript(source: resourceObserver, injectionTime: .atDocumentStart, forMainFrameOnly: false))
                }
                let web = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 844), configuration: config)
                loader.webView = web; web.navigationDelegate = loader
                web.customUserAgent = request.value(forHTTPHeaderField: "User-Agent") ?? sourceUA
                // iOS 17 may suspend an unattached WebContent process, even
                // for loadHTMLString. Keep the renderer in the app's window
                // behind its root view, without intercepting input or exposing
                // a second accessibility tree. Remove it on every exit path.
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                let windows = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
                if let window = windows.first(where: \.isKeyWindow) ?? windows.first(where: { !$0.isHidden }) {
                    web.isUserInteractionEnabled = false
                    web.accessibilityElementsHidden = true
                    window.insertSubview(web, at: 0)
                }
                loader.timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    loader.finish(.failure(SourceFailure(stage: "网页脚本", message: "WebView 加载或脚本等待超时（" + loader.loadingPhase + "）", url: request.url?.absoluteString ?? "")))
                }
                Task {
                    do { try await SourceWebDataStore.prepareProxy(config, request: request) }
                    catch { loader.finish(.failure(error)); return }
                    for cookie in loader.cookiesEnabled ? SourceWebDataStore.cookies(for: request, sourceURL: LegadoJSCtx.ruleSource?.bookSourceUrl) : [] {
                        guard loader.continuation != nil, !Task.isCancelled else { return }
                        await config.websiteDataStore.httpCookieStore.setCookie(cookie)
                    }
                    guard loader.continuation != nil else { return }
                    loader.loadingPhase = "等待页面加载"
                    if let html, !html.isEmpty { web.loadHTMLString(html, baseURL: request.url) }
                    else {
                        var configured = request
                        if cacheFirst { configured.cachePolicy = .returnCacheDataElseLoad }
                        web.load(configured)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in loader.finish(.failure(CancellationError())) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingPhase = "等待网页脚本结果"
        guard !startedPolling else { return }; startedPolling = true
        polling = Task {
            // Give asynchronous page scripts a chance to populate the DOM.
            try? await Task.sleep(nanoseconds: UInt64(max(0.35, min(delay, 3600)) * 1_000_000_000))
            while !Task.isCancelled, continuation != nil {
                do {
                    if capturesURL {
                        // Capture APIs execute the script for its side effects;
                        // a script return value is not the requested URL.
                        if !script.isEmpty { _ = try await webView.evaluateJavaScript(script) }
                        return
                    }
                    let value = try await webView.evaluateJavaScript(script.isEmpty ? "document.documentElement.outerHTML" : script)
                    if let value, !(value is NSNull) {
                        let text: String
                        if let string = value as? String { text = string }
                        else if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) { text = String(decoding: data, as: UTF8.self) }
                        else { text = String(describing: value) }
                        if !text.isEmpty {
                            if cookiesEnabled {
                                for cookie in await webView.configuration.websiteDataStore.httpCookieStore.allCookies() { HTTPCookieStorage.shared.setCookie(cookie) }
                            }
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

    private static let resourceObserver = #"""
    (function(){
      function report(value){try{if(value)window.webkit.messageHandlers.readerResource.postMessage(new URL(String(value),document.baseURI).href);}catch(e){}}
      var open=XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open=function(method,url){report(url);return open.apply(this,arguments);};
      var fetch=window.fetch;
      window.fetch=function(input){report(typeof input==='string'?input:input.url);return fetch.apply(this,arguments);};
      if(window.PerformanceObserver){try{new PerformanceObserver(function(list){list.getEntries().forEach(function(e){report(e.name);});}).observe({type:'resource',buffered:true});}catch(e){}}
      document.addEventListener('load',function(e){var n=e.target;if(n)report(n.currentSrc||n.src||n.href);},true);
      document.addEventListener('DOMContentLoaded',function(){document.querySelectorAll('[src],link[href]').forEach(function(n){report(n.currentSrc||n.src||n.href);});});
    })();
    """#

    private func matches(_ value: String, pattern: NSRegularExpression?) -> Bool {
        guard let pattern else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return pattern.firstMatch(in: value, range: range)?.range == range
    }

    private func captured(_ address: String) {
        Task {
            if cookiesEnabled, let webView {
                for cookie in await webView.configuration.websiteDataStore.httpCookieStore.allCookies() { HTTPCookieStorage.shared.setCookie(cookie) }
            }
            finish(.success(.init(text: address, url: initialURL)))
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let address = message.body as? String, matches(address, pattern: resourcePattern) else { return }
        captured(address)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let address = navigationAction.request.url?.absoluteString, matches(address, pattern: navigationPattern) {
            decisionHandler(.cancel); captured(address)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(SourceFailure(stage: "网页脚本", message: "网页渲染进程已退出，请重试", url: webView.url?.absoluteString ?? "")))
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if allowsInvalidCertificates, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.performDefaultHandling, nil) }
    }

    private func finish(_ result: Result<SourcePage, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel(); polling?.cancel(); webView?.stopLoading(); webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "readerResource")
        webView?.removeFromSuperview(); webView = nil
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
    static func web(_ request: URLRequest, html: String? = nil, script: String = "", delay: Double = 0,
                    resourceRegex: String? = nil, navigationRegex: String? = nil, cacheFirst: Bool = false) throws -> SourcePage {
        guard !Thread.isMainThread else { throw SourceFailure(stage: "脚本兼容性", message: "WebView 脚本必须在后台书源任务中执行") }
        let box = WebBox()
        let timeout = max(0.1, min(20, LegadoJSCtx.deadline?.timeIntervalSinceNow ?? 20))
        let task = Task { @MainActor in
            do { box.set(.success(try await SourceWebLoader.load(request, html: html, script: script, timeout: timeout, delay: delay,
                                                                resourceRegex: resourceRegex, navigationRegex: navigationRegex, cacheFirst: cacheFirst))) }
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
