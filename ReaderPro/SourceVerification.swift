import SwiftUI
import WebKit

// A synchronous rule may wait on user verification, but WebKit and its visible
// controls always run on MainActor. The bridge carries only value types.
@MainActor enum SourceVerification {
    private static var active = false
    static func open(request: URLRequest, title: String, html: String?, source: LegadoSource?, image: Bool = false, timeout: Double) async throws -> SourcePage {
        while active { try await Task.sleep(nanoseconds: 100_000_000) }
        try Task.checkCancellation()
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        guard let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
            throw SourceFailure(stage: "网页验证", message: "请在应用前台完成验证")
        }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        active = true
        defer { active = false }
        let store = try SourceWebDataStore.make(request: request, ephemeral: !(source?.enabledCookieJar ?? true))
        let session = VerificationSession(request: request, html: html, source: source, image: image, store: store)
        let controller = UIHostingController(rootView: VerificationView(session: session, title: title))
        // Keep the requesting screen in the view hierarchy. A .fullScreen
        // presentation calls its onDisappear handlers, which cancel search,
        // chapter loading or source switching while the rule awaits this UI.
        controller.modalPresentationStyle = .overFullScreen
        session.dismiss = { controller.dismiss(animated: true) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                session.continuation = continuation
                session.timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    session.finish(.failure(SourceFailure(stage: "网页验证", message: "等待验证超时，请完成登录后重试")))
                }
                presenter.present(controller, animated: true)
            }
        } onCancel: { Task { @MainActor in session.finish(.failure(CancellationError())) } }
    }
}

@MainActor final class VerificationSession: ObservableObject {
    let request: URLRequest
    let html: String?
    let source: LegadoSource?
    let image: Bool
    let store: WKWebsiteDataStore
    @Published var status = "请完成网页验证，再点击「验证完成」"
    @Published var code = ""
    @Published var imageData: Data?
    weak var web: WKWebView?
    var continuation: CheckedContinuation<SourcePage, Error>?
    var timer: Task<Void, Never>?
    var dismiss: (() -> Void)?
    init(request: URLRequest, html: String?, source: LegadoSource?, image: Bool, store: WKWebsiteDataStore) {
        self.request = request; self.html = html; self.source = source; self.image = image; self.store = store
    }
    func complete() {
        if image {
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "请输入验证码"; return }
            finish(.success(SourcePage(text: code, url: request.url?.absoluteString ?? ""))); return
        }
        guard let web else { return }
        Task {
            do {
                let html = try await web.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
                if source?.enabledCookieJar ?? true {
                    for cookie in await web.configuration.websiteDataStore.httpCookieStore.allCookies() { HTTPCookieStorage.shared.setCookie(cookie) }
                }
                finish(.success(SourcePage(text: html, url: web.url?.absoluteString ?? request.url?.absoluteString ?? "")))
            } catch { status = sourceErrorMessage(error) }
        }
    }
    func finish(_ result: Result<SourcePage, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timer?.cancel(); timer = nil
        web?.stopLoading(); web?.navigationDelegate = nil
        dismiss?(); dismiss = nil; continuation.resume(with: result)
    }
}

private struct VerificationView: View {
    @ObservedObject var session: VerificationSession
    let title: String
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text(session.status).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                if session.image {
                    if let data = session.imageData, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 200) }
                    else { ProgressView("正在加载验证码…") }
                    TextField("输入图片验证码", text: $session.code).textFieldStyle(.roundedBorder).padding().textInputAutocapitalization(.never)
                    Spacer()
                } else { VerificationWebPage(session: session) }
            }.navigationTitle(title.isEmpty ? "书源验证" : title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { session.finish(.failure(CancellationError())) } }
                ToolbarItem(placement: .topBarTrailing) { Button(session.image ? "确认" : "验证完成") { session.complete() } }
            }
            .task {
                guard session.image else { return }
                do {
                    let request = session.request, source = session.source
                    let data = try await Task.detached {
                        if let source { return try await source.withRules { try await SourceTLS.data(for: request).0 } }
                        return try await SourceTLS.data(for: request).0
                    }.value
                    session.imageData = data
                } catch { session.status = sourceErrorMessage(error) }
            }
        }.interactiveDismissDisabled()
    }
}

private struct VerificationWebPage: UIViewRepresentable {
    let session: VerificationSession
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = session.store
        let web = WKWebView(frame: .zero, configuration: configuration)
        session.web = web; web.navigationDelegate = context.coordinator
        web.customUserAgent = session.request.value(forHTTPHeaderField: "User-Agent") ?? sourceUA
        Task {
            do { try await SourceWebDataStore.prepareProxy(configuration, request: session.request) }
            catch { session.finish(.failure(error)); return }
            for cookie in (session.source?.enabledCookieJar ?? true) ? SourceWebDataStore.cookies(for: session.request, sourceURL: session.source?.bookSourceUrl) : [] { await configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
            guard session.continuation != nil else { return }
            if let html = session.html, !html.isEmpty { web.loadHTMLString(html, baseURL: session.request.url) }
            else { web.load(session.request) }
        }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {}
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) { web.stopLoading(); web.navigationDelegate = nil }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        let session: VerificationSession
        init(_ session: VerificationSession) { self.session = session }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard session.source?.enabledCookieJar ?? true else { return }
            Task { for cookie in await webView.configuration.websiteDataStore.httpCookieStore.allCookies() { HTTPCookieStorage.shared.setCookie(cookie) } }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { session.status = sourceErrorMessage(error) }
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let credential = RPWebProxyCredential(webView.configuration.websiteDataStore, challenge) { completionHandler(.useCredential, credential) }
            else if let source = session.source, SourceTLS.isAllowed(source.bookSourceUrl), challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: trust)) }
            else { completionHandler(.performDefaultHandling, nil) }
        }
    }
}

extension SourceJSBridge {
    static func verify(_ request: URLRequest, title: String, html: String?, image: Bool = false) throws -> SourcePage {
        guard !Thread.isMainThread else { throw SourceFailure(stage: "网页验证", message: "验证脚本必须在后台任务执行") }
        let timeout = max(0.1, min(180, LegadoJSCtx.deadline?.timeIntervalSinceNow ?? 180))
        let box = WebBox(), source = LegadoJSCtx.ruleSource
        let task = Task { @MainActor in
            do { box.set(.success(try await SourceVerification.open(request: request, title: title, html: html, source: source, image: image, timeout: timeout))) }
            catch { box.set(.failure(error)) }
        }
        let end = Date().addingTimeInterval(timeout + 1)
        while box.get() == nil {
            if Task.isCancelled { task.cancel(); throw CancellationError() }
            if Date() > end { task.cancel(); throw URLError(.timedOut) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return try box.get()!.get()
    }
}
