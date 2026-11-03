import SwiftUI
import AVFoundation
import AVKit
import WebKit

func videoURLFromChapter(_ text: String) -> String {
    text.hasPrefix("__URL__") ? String(text.dropFirst(7)) : text
}

final class VideoPlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published var status = "等待播放"
    @Published var error = ""
    @Published var currentTime: TimeInterval = 0
    private var itemObservation: NSKeyValueObservation?
    private var stateObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    var onEnded: (() -> Void)?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            self?.currentTime = time.seconds.isFinite ? time.seconds : 0
        }
        stateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self, self.error.isEmpty else { return }
                switch player.timeControlStatus {
                case .playing: self.status = "正在播放"
                case .waitingToPlayAtSpecifiedRate: self.status = "正在缓冲…"
                default: self.status = "已暂停"
                }
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func stop() {
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        currentTime = 0; error = ""; status = "正在解析播放地址…"
    }

    func play(_ request: URLRequest) {
        guard let url = request.url else { error = "播放地址无效"; return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        var options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": request.allHTTPHeaderFields ?? [:]]
        options[AVURLAssetHTTPCookiesKey] = HTTPCookieStorage.shared.cookies(for: url) ?? []
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        error = ""; status = "正在缓冲…"
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.player.currentItem === item else { return }
                if item.status == .failed {
                    self.error = "视频播放失败：" + (item.error.map(sourceErrorMessage) ?? "地址不可用或格式不受系统支持")
                    self.status = "播放失败"
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self, self.player.currentItem === item else { return }
            self.onEnded?()
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }
}

struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) { controller.player = nil }
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
        switch resource {
        case .native(let request), .web(let request):
            web.customUserAgent = request.value(forHTTPHeaderField: "User-Agent") ?? sourceUA
            Task { @MainActor in
                for cookie in HTTPCookieStorage.shared.cookies ?? [] { await config.websiteDataStore.httpCookieStore.setCookie(cookie) }
                guard !context.coordinator.cancelled else { return }
                web.load(request)
            }
        case .html(let html, let base): web.loadHTMLString(html, baseURL: base)
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
            case .html(_, let base): request.setValue(base.absoluteString, forHTTPHeaderField: "Referer")
            }
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
    @State private var episodeIndex: Int
    @State private var resource: SourceVideoResource?
    @State private var retry = 0
    @State private var loading = true
    @State private var resolveError = ""
    @State private var webStatus = "正在加载网页播放器…"

    init(book: LocalBook, source: LegadoSource? = nil, store: BookStore? = nil) {
        self.book = book; self.source = source; self.store = store
        _episodeIndex = State(initialValue: min(max(0, book.chapterIndex), max(0, book.chapters.count - 1)))
    }
    private var chapters: [BookChapter] {
        book.chapters.isEmpty ? book.videoUrls.enumerated().map { BookChapter(title: "第 \($0.offset + 1) 集", text: "__URL__" + $0.element) } : book.chapters
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
                    case .native: NativeVideoPlayer(player: model.player)
                    case .web, .html:
                        EpisodeWebPlayer(resource: resource, sourceRegex: source?.ruleContent.androidValue("sourceRegex") ?? "", onStatus: { webStatus = $0 }, onMedia: { request in
                            self.resource = .native(request); model.play(request)
                        }).id("\(episodeIndex)-\(retry)")
                    }
                }
                if loading { ProgressView().tint(.white) }
            }.aspectRatio(16 / 9, contentMode: .fit).accessibilityIdentifier("chapterVideoPlayer")
            VStack(alignment: .leading, spacing: 8) {
                Text(chapters.indices.contains(episodeIndex) ? chapters[episodeIndex].title : book.title).font(.headline)
                    .accessibilityIdentifier("videoEpisodeTitle")
                Text(status).font(.caption).foregroundStyle(resolveError.isEmpty && model.error.isEmpty ? Color.secondary : .red)
                    .accessibilityIdentifier("videoPlaybackStatus")
                HStack {
                    Text("已播放 \(Int(model.currentTime)) 秒").font(.caption).monospacedDigit().accessibilityIdentifier("videoPlaybackTime")
                    Spacer()
                    Button("重新加载") { retry += 1 }.accessibilityIdentifier("videoRetry")
                    Button("下一集") { if episodeIndex + 1 < chapters.count { episodeIndex += 1 } }
                        .disabled(episodeIndex + 1 >= chapters.count).accessibilityIdentifier("videoNextEpisode")
                }
            }.padding(16)
            List {
                Section("选集 · \(chapters.count) 集") {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                        Button { episodeIndex = index } label: {
                            HStack {
                                Text(chapter.title).foregroundStyle(index == episodeIndex ? AppTheme.accent : .primary)
                                Spacer()
                                if index == episodeIndex { Image(systemName: "play.fill").foregroundStyle(AppTheme.accent) }
                            }
                        }.accessibilityIdentifier("video-episode-\(index)")
                    }
                }
            }.listStyle(.plain)
        }
        .background(AppTheme.surface)
        .navigationTitle(book.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("返回目录") { dismiss() } } }
        .task(id: "\(episodeIndex)-\(retry)") { await loadEpisode() }
        .onDisappear { model.stop() }
    }
    private func loadEpisode() async {
        model.stop(); resource = nil; loading = true; resolveError = ""
        guard chapters.indices.contains(episodeIndex) else { loading = false; resolveError = "没有可播放的章节"; return }
        let index = episodeIndex
        var chapter = chapters[index]
        chapter.ruleIndex = index
        if chapter.ruleBook == nil { chapter.ruleBook = .init(bookUrl: chapter.url ?? "", name: book.title, author: book.author) }
        model.onEnded = { if episodeIndex + 1 < chapters.count { episodeIndex += 1 } }
        if let store {
            var saved = store.books.first(where: { $0.id == book.id }) ?? book
            saved.kind = "video"; saved.chapterIndex = index; saved.lastRead = Date()
            store.updateBook(saved)
        }
        do {
            let resolved: SourceVideoResource
            if let source { resolved = try await withTimeout(60) { try await source.fetchChapterVideo(chapter) } }
            else { resolved = try SourceVideoResource.make(videoURLFromChapter(chapter.text), base: chapter.url ?? videoURLFromChapter(chapter.text), headers: [:]) }
            guard !Task.isCancelled, episodeIndex == index else { return }
            resource = resolved; loading = false
            if case .native(let request) = resolved { model.play(request) }
        } catch {
            guard !Task.isCancelled, episodeIndex == index else { return }
            loading = false; resolveError = sourceErrorMessage(error)
        }
    }
}
