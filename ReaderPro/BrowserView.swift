import SwiftUI
import UIKit
import WebKit
import AVFoundation
import AVKit

// MARK: - 视频画中画（ALOOK 式悬浮小窗）
// 单例常驻：退出浏览器后画中画仍可悬浮播放，切到别的 App 也不停。

final class VideoPiPManager: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = VideoPiPManager()

    private var player: AVPlayer?
    private var pip: AVPictureInPictureController?
    private var layer: AVPlayerLayer?

    var isActive: Bool { pip?.isPictureInPictureActive ?? false }

    func start(url: URL) {
        stop()

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let p = AVPlayer(url: url)
        let l = AVPlayerLayer(player: p)
        // 画中画要求 playerLayer 可见并挂在视图层级里；用一个 4x4 不可感知的小 layer
        l.frame = CGRect(x: 0, y: 0, width: 4, height: 4)
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene,
           let window = scene.windows.first(where: { $0.isKeyWindow }) {
            window.rootViewController?.view.layer.addSublayer(l)
        }

        let source = AVPictureInPictureController.ContentSource(playerLayer: l)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        c.canStartPictureInPictureAutomaticallyFromInline = true

        player = p; layer = l; pip = c
        p.play()
        // 等 layer 渲染就绪再进画中画，避免 startPictureInPicture 静默失败
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pip?.startPictureInPicture()
        }
    }

    func stop() {
        pip?.stopPictureInPicture()
        player?.pause()
        layer?.removeFromSuperlayer()
        player = nil; layer = nil; pip = nil
    }
}

// MARK: - 浏览器状态模型（订阅 WKWebView 的 KVO）

final class WebViewModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var title = ""
    @Published var canBack = false
    @Published var canForward = false
    @Published var progress: Double = 0
    @Published var currentURL = ""
    @Published var isLoading = false
    @Published var hasVideo = false
    @Published var videoSrc = ""

    let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.progress = wv.estimatedProgress }
            },
            webView.observe(\.canGoBack) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.canBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.canForward = wv.canGoForward }
            },
            webView.observe(\.title) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.title = wv.title ?? "" }
            },
            webView.observe(\.url) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.currentURL = wv.url?.absoluteString ?? "" }
            },
        ]
    }

    deinit {
        observations.forEach { $0.invalidate() }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DispatchQueue.main.async { [weak self] in
            self?.isLoading = true
            self?.hasVideo = false
            self?.videoSrc = ""
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.async { [weak self] in self?.isLoading = false }
        detectVideo()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.isLoading = false }
    }

    // 探测网页里第一个可播放的 <video>（取 currentSrc 优先，兼容 m3u8/mp4）
    func detectVideo() {
        let js = """
        (function(){
            var v = document.querySelector('video');
            if (v && (v.currentSrc || v.src)) { return v.currentSrc || v.src; }
            return '';
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            if let s = result as? String, !s.isEmpty {
                DispatchQueue.main.async {
                    self?.videoSrc = s
                    self?.hasVideo = true
                }
            }
        }
    }
}

// MARK: - WKWebView 桥接

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 内置浏览器

struct BrowserView: View {
    var initialURL: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: WebViewModel
    @State private var urlText = ""
    @State private var pipHint = ""

    init(initialURL: String = "https://www.baidu.com") {
        self.initialURL = initialURL
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true            // iPhone 上视频内联播放（否则强制全屏）
        config.allowsPictureInPictureMediaPlayback = true  // 网页视频原生支持画中画
        config.allowsAirPlayForMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: config)
        _model = StateObject(wrappedValue: WebViewModel(webView: wv))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canBack)
                Button { model.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canForward)
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                TextField("输入网址", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .textInputAutocapitalization(.never)
                    .onSubmit { loadText() }
                Button("前往") { loadText() }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.hasVideo {
                    Button { startPiP() } label: {
                        Label("小窗", systemImage: "pip.enter")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if model.progress > 0 && model.progress < 1 {
                ProgressView(value: model.progress).progressViewStyle(.linear)
            }

            WebViewContainer(webView: model.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !pipHint.isEmpty {
                Text(pipHint).font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
        .navigationTitle(model.title.isEmpty ? "浏览器" : model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .onAppear {
            if model.webView.url == nil { load(initialURL) }
        }
    }

    func reload() {
        if model.webView.url != nil { model.webView.reload() } else { loadText() }
    }

    func loadText() {
        let t = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { load(t) }
    }

    func load(_ raw: String) {
        let s = raw.contains("://") ? raw : "https://" + raw
        if let url = URL(string: s) { model.webView.load(URLRequest(url: url)) }
    }

    func startPiP() {
        guard !model.videoSrc.isEmpty, let url = URL(string: model.videoSrc) else {
            pipHint = "没找到可播放的视频源"
            return
        }
        VideoPiPManager.shared.start(url: url)
        pipHint = "已开启画中画小窗，可返回或切到别的 App 继续看"
    }
}
