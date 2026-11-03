import SwiftUI
import WebKit

@MainActor final class SourceLoginModel: ObservableObject {
    @Published var rows: [SourceLoginRow] = []
    @Published var values: [String: String] = [:]
    @Published var running = false
    @Published var error = ""
    @Published var message = ""
    @Published var browser: SourceLoginBrowser?
    private var worker: Task<LegadoSource.LoginSnapshot, Error>?
    private var pendingEdit: Task<Void, Never>?
    let source: LegadoSource
    init(source: LegadoSource) { self.source = source }
    func load() async { await perform() }
    func edit(_ row: SourceLoginRow, value: String) {
        values[row.name] = value
        pendingEdit?.cancel()
        guard let action = row.action, !action.isEmpty else { return }
        pendingEdit = Task {
            do { try await Task.sleep(nanoseconds: 600_000_000); try Task.checkCancellation() }
            catch { return }
            pendingEdit = nil
            await perform(action: action)
        }
    }
    func perform(action: String? = nil, longClick: Bool = false) async {
        guard !running else { return }
        pendingEdit?.cancel(); running = true; error = ""; message = ""
        let source = self.source; let values = rows.isEmpty ? nil : self.values
        let task = Task.detached(priority: .userInitiated) { try await source.loginSnapshot(values: values, action: action, longClick: longClick) }
        worker = task
        defer { worker = nil; running = false }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            rows = result.rows; self.values = result.values
            message = result.message; browser = result.browser
            if let text = result.copyText { UIPasteboard.general.string = text; message = "已复制" }
        } catch { self.error = sourceErrorMessage(error) }
    }
    func save() async -> Bool {
        pendingEdit?.cancel()
        let source = self.source; let values = self.values
        do {
            try await Task.detached(priority: .userInitiated) { try SourceLoginInfo.put(values, source: source.bookSourceUrl) }.value
            ExploreInfo.refresh(source.bookSourceUrl); return true
        } catch { self.error = sourceErrorMessage(error); return false }
    }
    func cancel() { worker?.cancel(); pendingEdit?.cancel() }
}

struct SourceLoginView: View {
    let source: LegadoSource
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SourceLoginModel
    @State private var webRevision = 0
    @State private var showHeader = false
    @State private var headerText = ""
    init(source: LegadoSource) { self.source = source; _model = StateObject(wrappedValue: SourceLoginModel(source: source)) }
    var body: some View {
        NavigationStack {
            loginContent
            .navigationTitle("登录 " + source.bookSourceName).readerNavigationStyle()
            .toolbar { loginToolbar }
            .task { if source.webLoginURL == nil { await model.load() } }
            .onDisappear {
                model.cancel()
                if source.webLoginURL == nil && !model.rows.isEmpty { Task { _ = await model.save() } }
            }
            .interactiveDismissDisabled(model.running)
            .sheet(item: $model.browser) { page in
                NavigationStack {
                    SourceLoginWebPage(source: source, page: page, revision: 0, status: $model.message)
                        .navigationTitle("书源网页登录").readerNavigationStyle()
                        .toolbar { Button("完成") { Task { await syncCookies(); model.browser = nil } } }
                }
            }
            .sheet(isPresented: $showHeader) {
                NavigationStack {
                    ScrollView { Text(headerText).font(.footnote).textSelection(.enabled).padding() }
                        .navigationTitle("登录头").toolbar { Button("关闭") { showHeader = false } }
                }
            }
        }
    }
    @ViewBuilder private var loginContent: some View {
        if let url = source.webLoginURL {
            VStack(spacing: 0) {
                if !model.message.isEmpty { Text(model.message).font(.caption).padding(8) }
                SourceLoginWebPage(source: source, page: SourceLoginBrowser(url: url), revision: webRevision, status: $model.message)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.running { HStack { ProgressView(); Text("正在执行书源登录规则…"); Spacer(); Button("停止") { model.cancel() } }.font(.footnote) }
                    if !model.error.isEmpty { Text(model.error).foregroundStyle(.red).font(.footnote).accessibilityIdentifier("sourceLoginError") }
                    if !model.message.isEmpty { Text(model.message).font(.footnote).accessibilityIdentifier("sourceLoginMessage") }
                    CategoryFlow {
                        ForEach(Array(model.rows.enumerated()), id: \.offset) { entry in
                            rowControl(entry.element).layoutValue(key: ExploreStyleKey.self, value: entry.element.style)
                        }
                    }.disabled(model.running)
                    if model.rows.isEmpty && !model.running {
                        Text(model.error.isEmpty ? "书源没有提供登录表单。" : "请检查书源登录规则后重试。")
                            .foregroundStyle(.secondary).font(.footnote)
                    }
                }.padding(16)
            }.accessibilityIdentifier("sourceLoginForm")
        }
    }
    @ToolbarContentBuilder private var loginToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("关闭") { Task {
                if source.webLoginURL != nil { await syncCookies(); dismiss() }
                else if await model.save() { dismiss() }
            } }.disabled(model.running)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if source.webLoginURL == nil {
                Button("保存并登录") { Task { await model.perform(action: "if(typeof login==='function'){login.apply(this)}else{throw Error('书源未实现 login 函数，请使用表单中的操作按钮')}") } }
                    .disabled(model.running).accessibilityIdentifier("sourceLoginSubmit")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("刷新登录界面") { if source.webLoginURL != nil { webRevision += 1 } else { Task { await model.load() } } }
                Button("查看登录头") { Task {
                    headerText = await Task.detached { SourceLoginHeaders.get(source.bookSourceUrl) ?? "暂无登录头" }.value
                    showHeader = true
                } }
                Button("删除登录头", role: .destructive) { Task {
                    do {
                        try await Task.detached {
                            try SourceLoginHeaders.remove(source.bookSourceUrl)
                            if let url = URL(string: source.bookSourceUrl) {
                                for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] { HTTPCookieStorage.shared.deleteCookie(cookie) }
                            }
                        }.value
                        for cookie in await WKWebsiteDataStore.default().httpCookieStore.allCookies() {
                            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                            let host = URL(string: source.bookSourceUrl)?.host ?? ""
                            if host == domain || host.hasSuffix("." + domain) {
                                await WKWebsiteDataStore.default().httpCookieStore.deleteCookie(cookie)
                            }
                        }
                        model.message = "已删除登录头"; ExploreInfo.refresh(source.bookSourceUrl)
                    } catch { model.error = sourceErrorMessage(error) }
                } }
            } label: { Image(systemName: "ellipsis.circle") }.disabled(model.running).accessibilityLabel("登录选项")
        }
    }
    @MainActor private func syncCookies() async {
        for cookie in await WKWebsiteDataStore.default().httpCookieStore.allCookies() { HTTPCookieStorage.shared.setCookie(cookie) }
        ExploreInfo.refresh(source.bookSourceUrl)
    }
    @ViewBuilder private func rowControl(_ row: SourceLoginRow) -> some View {
        let value = model.values[row.name] ?? ""
        switch row.type {
        case "password", "text":
            VStack(alignment: .leading, spacing: 6) {
                Text(row.displayName).font(.caption).foregroundStyle(.secondary)
                let binding = Binding(get: { model.values[row.name] ?? "" }, set: { model.edit(row, value: $0) })
                if row.type == "password" { SecureField(row.displayName, text: binding).accessibilityIdentifier("login-field-" + row.name) }
                else { TextField(row.displayName, text: binding).accessibilityIdentifier("login-field-" + row.name) }
            }.textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).frame(minWidth: 120)
        case "select":
            Menu {
                ForEach(row.choices, id: \.self) { choice in
                    Button { model.values[row.name] = choice; Task { await model.perform(action: row.action) } }
                    label: { Label(choice, systemImage: value == choice ? "checkmark" : "circle") }
                }
            } label: { Label(row.displayName + "：" + value, systemImage: "chevron.down").frame(minHeight: 36) }
                .accessibilityIdentifier("login-select-" + row.name)
        case "toggle":
            Button {
                guard !row.choices.isEmpty else { return }
                let next = ((row.choices.firstIndex(of: value) ?? -1) + 1) % row.choices.count
                model.values[row.name] = row.choices[next]; Task { await model.perform(action: row.action) }
            } label: { Text(row.style.justifySelf == "right" ? row.displayName + value : value + row.displayName).frame(minHeight: 36) }
                .accessibilityIdentifier("login-toggle-" + row.name)
        default:
            Button { Task { await model.perform(action: row.action) } } label: { Text(row.displayName).frame(minHeight: 36) }
                .buttonStyle(.bordered).accessibilityIdentifier("login-button-" + row.name)
                .contextMenu { if let action = row.action { Button("长按操作") { Task { await model.perform(action: action, longClick: true) } } } }
        }
    }
}

// Use an actual WebKit login session. Cookie changes are copied into the HTTP
// rule engine on every navigation and immediately when the page writes them.
struct SourceLoginWebPage: UIViewRepresentable {
    let source: LegadoSource
    let page: SourceLoginBrowser
    let revision: Int
    @Binding var status: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .default()
        if let script = page.script { config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false)) }
        let web = WKWebView(frame: .zero, configuration: config)
        web.accessibilityIdentifier = "sourceLoginWebView"; web.navigationDelegate = context.coordinator; web.uiDelegate = context.coordinator
        config.websiteDataStore.httpCookieStore.add(context.coordinator)
        context.coordinator.load(web); return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.revision != revision { context.coordinator.load(web) }
    }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.websiteDataStore.httpCookieStore.remove(coordinator); web.stopLoading(); coordinator.task?.cancel()
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        var parent: SourceLoginWebPage
        var revision = -1
        var task: Task<Void, Never>?
        init(_ parent: SourceLoginWebPage) { self.parent = parent }
        func load(_ web: WKWebView) {
            revision = parent.revision; task?.cancel()
            let source = parent.source; let page = parent.page
            task = Task {
                do {
                    let request = try await Task.detached {
                        try await source.withRules { try SourceHTTP.request(page.url, base: source.bookSourceUrl, headers: source.requestHeaders) }
                    }.value
                    if try SourceProxy.configuration(for: request) != nil { throw SourceFailure(stage: "书源登录", message: "网页登录暂不支持此书源代理配置") }
                    for cookie in HTTPCookieStorage.shared.cookies ?? [] { await web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
                    try Task.checkCancellation()
                    web.customUserAgent = request.value(forHTTPHeaderField: "User-Agent") ?? sourceUA
                    if let html = page.html { web.loadHTMLString(html, baseURL: request.url) } else { web.load(request) }
                } catch { parent.status = sourceErrorMessage(error) }
            }
        }
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { for cookie in await cookieStore.allCookies() { HTTPCookieStorage.shared.setCookie(cookie) } }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            cookiesDidChange(in: webView.configuration.websiteDataStore.httpCookieStore)
            parent.status = "网页已加载，登录状态会自动保存"
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.status = sourceErrorMessage(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.status = sourceErrorMessage(error) }
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if SourceTLS.isAllowed(parent.source.bookSourceUrl), challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: trust)) }
            else { completionHandler(.performDefaultHandling, nil) }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { webView.load(navigationAction.request); return nil }
    }
}
