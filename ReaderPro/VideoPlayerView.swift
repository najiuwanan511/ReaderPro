import SwiftUI
import AVFoundation
import AVKit
import WebKit

func videoURLFromChapter(_ text: String) -> String {
    text.hasPrefix("__URL__") ? String(text.dropFirst(7)) : text
}

// Web-based players and rule-generated HTML stay in the app, including iframe
// players. Each episode owns a new web view so old playback cannot continue.
struct EpisodeWebPlayer: UIViewRepresentable {
    let resource: SourceVideoResource
    let sourceRegex: String
    let onStatus: (String) -> Void
    let onMedia: (URLRequest) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let request: URLRequest
        switch resource {
        case .native(let original), .web(let original), .html(_, let original), .dash(_, let original): request = original
        }
        do { config.websiteDataStore = try SourceWebDataStore.make(request: request, ephemeral: true) }
        catch {
            let message = sourceErrorMessage(error)
            Task { @MainActor in if !context.coordinator.cancelled { onStatus(message) } }
            return WKWebView(frame: .zero, configuration: config)
        }
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "readerVideo")
        config.userContentController.addUserScript(WKUserScript(source: #"""
        function reportReaderVideo() {
            var v=document.querySelector('video');
            if(v){v.controls=true;v.setAttribute('playsinline','');
                window.webkit.messageHandlers.readerVideo.postMessage({state:v.error?'网页视频播放失败':(!v.paused?'正在播放':'网页播放器已就绪'),url:v.currentSrc||v.src||''});}
            var entries=performance.getEntriesByType('resource');
            for(var i=entries.length-1;i>=0;i--){if(/\.(m3u8|mp4)(\?|$)/i.test(entries[i].name)){
                window.webkit.messageHandlers.readerVideo.postMessage({url:entries[i].name});break;}}
        }
        setInterval(reportReaderVideo,1000);
        """#, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.isOpaque = false; web.backgroundColor = .black
        Task { @MainActor in
            do {
                try await SourceWebDataStore.prepareProxy(config, request: request)
            }
            catch { onStatus(sourceErrorMessage(error)); return }
            for cookie in SourceWebDataStore.cookies(for: request) { await config.websiteDataStore.httpCookieStore.setCookie(cookie) }
            guard !context.coordinator.cancelled else { return }
            switch resource {
            case .native(let request), .web(let request):
                web.customUserAgent = request.value(forHTTPHeaderField: "User-Agent") ?? sourceUA
                web.load(request)
            case .html(let html, let request), .dash(.some(let html), let request):
                web.customUserAgent = request.value(forHTTPHeaderField: "User-Agent") ?? sourceUA
                web.loadHTMLString(html, baseURL: request.url)
            case .dash(.none, let request): web.load(request)
            }
        }
        return web
    }
    func updateUIView(_ view: WKWebView, context: Context) { }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.cancelled = true
        view.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(v=>v.pause())", completionHandler: nil)
        view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "readerVideo")
        view.loadHTMLString("", baseURL: nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let parent: EpisodeWebPlayer
        var cancelled = false
        private var handedOff = false
        init(parent: EpisodeWebPlayer) { self.parent = parent }
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let credential = RPWebProxyCredential(webView.configuration.websiteDataStore, challenge) { completionHandler(.useCredential, credential) }
            else { completionHandler(.performDefaultHandling, nil) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.onStatus("网页播放器已加载") }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !cancelled, (error as NSError).code != NSURLErrorCancelled else { return }
            parent.onStatus("网页播放器加载失败：" + sourceErrorMessage(error))
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { parent.onStatus("网页播放器已退出，请重试") }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }; return nil
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !cancelled, let value = message.body as? [String: String] else { return }
            if let status = value["state"] { parent.onStatus(status) }
            guard !handedOff, let raw = value["url"], SourceVideoResource.isMediaURL(raw), isSourceURL(raw) else { return }
            if !parent.sourceRegex.isEmpty, raw.range(of: parent.sourceRegex, options: .regularExpression) == nil { return }
            // Page cookies and the originating Referer are required on many
            // media CDNs. Forward them when handing off to the native player.
            var request = URLRequest(url: URL(string: raw)!)
            switch parent.resource {
            case .native(let original), .web(let original): request.allHTTPHeaderFields = original.allHTTPHeaderFields
            case .html(_, let original), .dash(_, let original): request.allHTTPHeaderFields = original.allHTTPHeaderFields
            }
            // AVPlayer does not inherit this WebKit store's proxy. Keep the
            // HTML media element playing through its configured transport.
            let original: URLRequest
            switch parent.resource {
            case .native(let value), .web(let value), .html(_, let value), .dash(_, let value): original = value
            }
            guard (try? SourceProxy.configuration(for: original)) == nil else { return }
            handedOff = true
            Task { @MainActor in
                if let web = message.webView {
                    for cookie in await web.configuration.websiteDataStore.httpCookieStore.allCookies() { HTTPCookieStorage.shared.setCookie(cookie) }
                }
                guard !self.cancelled else { return }
                let cookies = HTTPCookieStorage.shared.cookies(for: request.url!) ?? []
                for (key, val) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(val, forHTTPHeaderField: key) }
                self.parent.onMedia(request)
            }
        }
    }
}

struct VideoPlayerView: View {
    let book: LocalBook
    let source: LegadoSource?
    let store: BookStore?
    @StateObject private var model = VideoPlayerModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var episodeIndex: Int
    @State private var resource: SourceVideoResource?
    @State private var retry = 0
    @State private var loading = true
    @State private var resolveError = ""
    @State private var webStatus = "正在加载网页播放器…"
    @State private var danmaku: [DanmakuEntry] = []
    @State private var showVideoSettings = false
    @State private var showEpisodes = false
    @State private var showLogin = false
    @State private var showEditor = false
    @State private var showSourceAction = false
    @State private var paymentAction = false
    @AppStorage("video.showDanmaku") private var showDanmaku = true
    @AppStorage("video.danmakuFontSize") private var danmakuFontSize = 16.0
    @AppStorage("video.danmakuOpacity") private var danmakuOpacity = 0.85
    @AppStorage("video.danmakuDuration") private var danmakuDuration = 8.0

    init(book: LocalBook, source: LegadoSource? = nil, store: BookStore? = nil) {
        self.book = book; self.source = source; self.store = store
        let initial = min(max(0, book.chapterIndex), max(0, book.chapters.count - 1))
        _episodeIndex = State(initialValue: book.chapters.readableIndex(from: initial) ?? book.chapters.readableIndex(from: initial, direction: -1) ?? 0)
    }
    private var chapters: [BookChapter] {
        let current = store?.readingBook(id: book.id) ?? book
        return current.chapters.isEmpty ? current.videoUrls.enumerated().map { BookChapter(title: "第 \($0.offset + 1) 集", text: "__URL__" + $0.element) } : current.chapters
    }
    private var status: String {
        if loading { return "正在解析播放地址…" }
        if !resolveError.isEmpty { return resolveError }
        if !model.error.isEmpty { return model.error }
        switch resource { case .web, .html: return webStatus; default: return model.status }
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let resource {
                    switch resource {
                    case .native: NativeVideoPlayer(model: model)
                    case .web, .html, .dash:
                        EpisodeWebPlayer(resource: resource, sourceRegex: source?.ruleContent.androidValue("sourceRegex") ?? "", onStatus: { webStatus = $0 }, onMedia: { request in
                            self.resource = .native(request); model.play(request, title: book.title, author: book.author)
                        }).id("\(episodeIndex)-\(retry)")
                    }
                }
                if showDanmaku, !danmaku.isEmpty { DanmakuOverlay(entries: danmaku, currentTime: model.currentTime).allowsHitTesting(false) }
                if loading { ProgressView().tint(.white) }
            }.aspectRatio(16 / 9, contentMode: .fit).accessibilityIdentifier("chapterVideoPlayer")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(chapters.indices.contains(episodeIndex) ? chapters[episodeIndex].title : book.title).font(.headline)
                        .accessibilityIdentifier("videoEpisodeTitle")
                    Spacer()
                    Button { showEpisodes = true } label: { Label("选集", systemImage: "list.bullet") }
                        .accessibilityIdentifier("videoChooseEpisode")
                }
                Text(status).font(.caption).foregroundStyle(resolveError.isEmpty && model.error.isEmpty ? Color.secondary : .red)
                    .accessibilityIdentifier("videoPlaybackStatus")
                if case .some(.native) = resource {
                    VideoPlaybackControls(model: model).id("\(episodeIndex)-\(retry)")
                }
                HStack {
                    Text("已播放 \(Int(model.currentTime)) 秒").font(.caption).monospacedDigit().accessibilityIdentifier("videoPlaybackTime")
                    Spacer()
                    Button("重新加载") { retry += 1 }.accessibilityIdentifier("videoRetry")
                    Button("下一集") { if let next = chapters.readableIndex(from: episodeIndex + 1) { episodeIndex = next } }
                        .disabled(chapters.readableIndex(from: episodeIndex + 1) == nil).accessibilityIdentifier("videoNextEpisode")
                }
            }.padding(16)
            episodeList(inPicker: false)
        }
        .background(AppTheme.surface)
        .navigationTitle(book.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("返回目录") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("播放与弹幕设置") { showVideoSettings = true }
                    Toggle("显示弹幕", isOn: $showDanmaku)
                    if source?.hasLogin == true { Button("登录 / 接口设置") { showLogin = true } }
                    if source != nil, store != nil { Button("编辑书源") { showEditor = true } }
                    if source?.customButton == true { Button("书源自定义按钮") { paymentAction = false; showSourceAction = true } }
                    if !(source?.ruleContent.androidValue("payAction") ?? "").isEmpty { Button("购买 / 解锁本集") { paymentAction = true; showSourceAction = true } }
                    if let url = resource?.request.url {
                        Button("复制播放地址") { UIPasteboard.general.string = url.absoluteString }
                        ShareLink("其他应用打开 / 分享", item: url)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showLogin, onDismiss: { retry += 1 }) { if let source { SourceLoginView(source: source) } }
        .sheet(isPresented: $showEditor, onDismiss: { retry += 1 }) {
            if let source, let store { NavigationStack { SourceDetailView(store: store, source: source) } }
        }
        .sheet(isPresented: $showSourceAction, onDismiss: { if paymentAction { retry += 1 } }) {
            if let source {
                NavigationStack {
                    SourceCustomActionView(source: source, book: (store?.readingBook(id: book.id) ?? book).sourceBook,
                        chapter: chapters.indices.contains(episodeIndex) ? chapters[episodeIndex] : nil, payment: paymentAction,
                        onPaymentSuccess: {
                            if let store { try await store.refreshPurchasedChapter(bookID: book.id, chapterURL: chapters.indices.contains(episodeIndex) ? chapters[episodeIndex].url : nil) }
                            retry += 1
                        })
                }
            }
        }
        .sheet(isPresented: $showVideoSettings) {
            NavigationStack {
                Form {
                    Section("播放") {
                        Picker("倍速", selection: Binding(get: { model.playbackRate }, set: { model.setPlaybackRate($0) })) {
                            ForEach(VideoPlayerModel.playbackRates, id: \.self) { Text("\($0, specifier: "%.2g") 倍").tag($0) }
                        }
                        Text("播放时长按画面临时使用 2 倍速，松手恢复所选倍速。")
                    }
                    Section("弹幕") {
                        Toggle("显示弹幕", isOn: $showDanmaku)
                        LabeledContent("字号", value: "\(Int(danmakuFontSize))"); Slider(value: $danmakuFontSize, in: 12...30, step: 1)
                        Text("不透明度"); Slider(value: $danmakuOpacity, in: 0.2...1)
                        Text("显示时长"); Slider(value: $danmakuDuration, in: 3...15, step: 1)
                    }
                }.navigationTitle("播放器设置").toolbar { Button("完成") { showVideoSettings = false } }
            }
        }
        .sheet(isPresented: $showEpisodes) {
            NavigationStack {
                episodeList(inPicker: true).navigationTitle("选集")
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showEpisodes = false } } }
            }.presentationDetents([.medium, .large])
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.endBoost() } }
        .task(id: "\(episodeIndex)-\(retry)") { await loadEpisode() }
        .onDisappear { model.stop() }
    }

    private func episodeList(inPicker: Bool) -> some View {
        ScrollViewReader { proxy in
            List {
                Section("选集 · \(chapters.filter { !$0.isVolume }.count) 集") {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                        Button {
                            episodeIndex = index
                            if inPicker { showEpisodes = false }
                        } label: {
                            HStack {
                                Text(chapter.displayTitle).foregroundStyle(index == episodeIndex ? AppTheme.accent : .primary)
                                Spacer()
                                if index == episodeIndex { Image(systemName: "play.fill").foregroundStyle(AppTheme.accent) }
                            }
                        }.disabled(chapter.isVolume)
                            .accessibilityIdentifier("\(inPicker ? "video-picker-episode" : "video-episode")-\(index)")
                            .accessibilityValue(index == episodeIndex ? "当前集" : "")
                            .id(index)
                    }
                }
            }.listStyle(.plain)
                .task { await Task.yield(); proxy.scrollTo(episodeIndex, anchor: .top) }
                .onChange(of: episodeIndex) { _, index in proxy.scrollTo(index, anchor: .top) }
        }
    }
    private func loadEpisode() async {
        model.stop(); danmaku = []; resource = nil; loading = true; resolveError = ""; webStatus = "正在加载网页播放器…"
        guard chapters.indices.contains(episodeIndex) else { loading = false; resolveError = "没有可播放的章节"; return }
        let index = episodeIndex
        var chapter = chapters[index]
        chapter.ruleIndex = index
        if chapter.ruleBook == nil { chapter.ruleBook = .init(bookUrl: chapter.url ?? "", name: book.title, author: book.author) }
        model.onEnded = { if let next = chapters.readableIndex(from: episodeIndex + 1) { episodeIndex = next } }
        if let store {
            var saved = store.readingBook(id: book.id) ?? book
            saved.kind = "video"; saved.chapterIndex = index; saved.lastRead = Date()
            store.updateBook(saved)
        }
        do {
            let resolved: SourceVideoResource
            let selectedChapter = chapter
            let activeSource = store.flatMap { store in store.readingBook(id: book.id).flatMap { store.sourceForBook($0) } } ?? source
            let current = store?.readingBook(id: book.id) ?? book
            if let cached = try await MediaDiskCache.shared.cached(book: current, chapter: selectedChapter) {
                resolved = .native(cached.request); danmaku = parseDanmaku(cached.auxiliary)
            } else if let activeSource {
                let details = try await withTimeout(60) { try await activeSource.fetchChapterVideoDetails(selectedChapter) }
                guard !Task.isCancelled, episodeIndex == index else { return }
                resolved = details.resource; danmaku = parseDanmaku(details.subContent)
            }
            else { resolved = try SourceVideoResource.make(videoURLFromChapter(chapter.text), base: chapter.url ?? videoURLFromChapter(chapter.text), headers: [:]) }
            guard !Task.isCancelled, episodeIndex == index else { return }
            resource = resolved; loading = false
            if case .native(let request) = resolved { model.play(request, title: book.title + " · " + chapters[index].title, author: book.author) }
            if activeSource != nil { store?.mediaCache.preload(bookID: book.id, from: index) }
        } catch {
            guard !Task.isCancelled, episodeIndex == index else { return }
            loading = false; resolveError = sourceErrorMessage(error)
        }
    }
}
