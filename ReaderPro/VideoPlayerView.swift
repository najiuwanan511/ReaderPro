import SwiftUI
import AVFoundation
import AVKit

// MARK: - 视频播放模型

final class VideoPlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isBuffering = false
    var player = AVPlayer()
    private var timeObserver: Any?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            self.currentTime = t.seconds.isFinite ? t.seconds : 0
            if let d = self.player.currentItem?.duration, d.seconds.isFinite { self.duration = d.seconds }
        }
    }

    func play(url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
    }

    func toggle() {
        if player.rate > 0 { player.pause(); isPlaying = false } else { player.play(); isPlaying = true }
    }

    func seek(to t: TimeInterval) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        currentTime = t
    }
}

// MARK: - AVPlayerLayer 桥接

final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerContainerView {
        let v = PlayerContainerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }
    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

// MARK: - 弹幕

struct DanmakuItem: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let lane: Int
    let color: Color
}

final class DanmakuModel: ObservableObject {
    @Published var items: [DanmakuItem] = []
    @Published var enabled = true
    private static let colors: [Color] = [.white, Color(red: 1, green: 0.85, blue: 0.4), Color(red: 0.5, green: 0.85, blue: 1), Color(red: 1, green: 0.6, blue: 0.75), Color(red: 0.6, green: 1, blue: 0.7)]

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let item = DanmakuItem(text: t, lane: Int.random(in: 0..<8), color: Self.colors.randomElement() ?? .white)
        items.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
            self?.items.removeAll { $0.id == item.id }
        }
    }

    func seedDemo() {
        let demo = ["终于等到了", "前方高能", "这画质可以", "好片推荐", "弹幕护体", "来了来了"]
        for (i, t) in demo.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 2.2) { [weak self] in
                let item = DanmakuItem(text: t, lane: Int.random(in: 0..<8), color: Self.colors.randomElement() ?? .white)
                self?.items.append(item)
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { self?.items.removeAll { $0.id == item.id } }
            }
        }
    }
}

struct DanmakuOverlayView: View {
    @ObservedObject var model: DanmakuModel
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(model.items) { item in
                    DanmakuText(item: item, laneHeight: 34, width: geo.size.width)
                }
            }
            .clipped()
        }
        .allowsHitTesting(false)
    }
}

struct DanmakuText: View {
    let item: DanmakuItem
    let laneHeight: CGFloat
    let width: CGFloat
    @State private var x: CGFloat = 0
    var body: some View {
        Text(item.text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(item.color)
            .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 1)
            .fixedSize()
            .position(x: x, y: laneHeight / 2 + CGFloat(item.lane) * laneHeight)
            .onAppear {
                x = width + 120
                withAnimation(.linear(duration: 8)) {
                    x = -200
                }
            }
    }
}

// MARK: - 视频选集条目

struct VideoEpisode: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: String
}

/// 解析 __URL__ 前缀（与网络书的正文缓存约定一致）
func videoURLFromChapter(_ text: String) -> String {
    if text.hasPrefix("__URL__") { return String(text.dropFirst(7)) }
    return text
}

// MARK: - 视频播放器（弹幕 + 选集 + 换源，对标阅读Sigma「带弹幕的视频播放」）

struct VideoPlayerView: View {
    let title: String
    let episodes: [VideoEpisode]
    let sources: [String]

    @StateObject private var playerModel = VideoPlayerModel()
    @StateObject private var danmaku = DanmakuModel()
    @Environment(\.dismiss) private var dismiss
    @State private var episodeIndex = 0
    @State private var sourceIndex = 0
    @State private var danmakuText = ""
    @State private var controlsVisible = true
    @State private var showEpisodes = false
    @State private var showSources = false

    init(book: LocalBook) {
        title = book.title
        episodes = book.chapters.map { VideoEpisode(title: $0.title, url: videoURLFromChapter($0.text)) }
        var src = book.videoUrls
        if src.isEmpty, let first = episodes.first { src = [first.url] }
        sources = src
    }

    /// 当前播放地址
    private var currentURL: String {
        if !sources.isEmpty && sourceIndex < sources.count { return sources[sourceIndex] }
        if episodeIndex < episodes.count { return episodes[episodeIndex].url }
        return ""
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    PlayerLayerView(player: playerModel.player)
                    DanmakuOverlayView(model: danmaku)
                        .opacity(danmaku.enabled ? 1 : 0)
                    if controlsVisible {
                        controlOverlay
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { controlsVisible.toggle() } }
            }
            .ignoresSafeArea(edges: .top)
        }
        .onAppear { playCurrent() }
        .onDisappear { playerModel.player.pause() }
        .sheet(isPresented: $showEpisodes) { episodeSheet }
        .sheet(isPresented: $showSources) { sourceSheet }
    }

    var controlOverlay: some View {
        VStack {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3).foregroundStyle(.white).padding(8).background(Circle().fill(Color.black.opacity(0.4))) }
                Spacer()
                Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Button { danmaku.enabled.toggle() } label: {
                    Image(systemName: danmaku.enabled ? "captions.bubble.fill" : "captions.bubble").font(.title3).foregroundStyle(.white).padding(8).background(Circle().fill(Color.black.opacity(0.4)))
                }
            }
            Spacer()
            Button { playerModel.toggle() } label: {
                Image(systemName: playerModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56)).foregroundStyle(.white.opacity(0.9))
            }
            Spacer()
            // 弹幕输入
            HStack(spacing: 8) {
                TextField("发个弹幕…", text: $danmakuText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.5)))
                    .foregroundStyle(.white)
                    .onSubmit { sendDanmaku() }
                Button("发送") { sendDanmaku() }
                    .font(.subheadline).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(AppTheme.unreadBadge))
                Button { danmaku.seedDemo() } label: { Image(systemName: "wand.and.stars").foregroundStyle(.white) }
            }
            .padding(.horizontal)
            // 进度条 + 时间
            VStack(spacing: 4) {
                Slider(value: Binding(get: { playerModel.currentTime }, set: { playerModel.seek(to: $0) }), in: 0...(playerModel.duration > 0 ? playerModel.duration : 1))
                    .tint(.white)
                HStack {
                    Text(fmt(playerModel.currentTime)).font(.caption2).foregroundStyle(.white).monospacedDigit()
                    Spacer()
                    Button { showSources = true } label: { Label(sources.isEmpty ? "默认" : "源 \(sourceIndex + 1)/\(sources.count)", systemImage: "arrow.triangle.2.circlepath").font(.caption2).foregroundStyle(.white) }
                    Spacer()
                    Button { showEpisodes = true } label: { Label("选集 \(episodeIndex + 1)/\(max(episodes.count,1))", systemImage: "list.number").font(.caption2).foregroundStyle(.white) }
                    Spacer()
                    Text(fmt(playerModel.duration)).font(.caption2).foregroundStyle(.white).monospacedDigit()
                }
            }
            .padding(.horizontal).padding(.bottom, 10)
        }
    }

    var episodeSheet: some View {
        NavigationStack {
            List {
                ForEach(Array(episodes.enumerated()), id: \.offset) { i, ep in
                    Button {
                        episodeIndex = i
                        showEpisodes = false
                        playCurrent()
                    } label: {
                        HStack {
                            Text(ep.title).foregroundStyle(i == episodeIndex ? AppTheme.unreadBadge : .primary)
                            Spacer()
                            if i == episodeIndex { Image(systemName: "checkmark").foregroundStyle(AppTheme.unreadBadge) }
                        }
                    }
                }
            }
            .navigationTitle("选集")
            .toolbar { Button("关闭") { showEpisodes = false } }
        }
        .presentationDetents([.medium, .large])
    }

    var sourceSheet: some View {
        NavigationStack {
            List {
                ForEach(Array(sources.enumerated()), id: \.offset) { i, s in
                    Button {
                        sourceIndex = i
                        showSources = false
                        playCurrent()
                    } label: {
                        HStack {
                            Text("播放源 \(i + 1)").foregroundStyle(i == sourceIndex ? AppTheme.unreadBadge : .primary)
                            Spacer()
                            Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            if i == sourceIndex { Image(systemName: "checkmark").foregroundStyle(AppTheme.unreadBadge) }
                        }
                    }
                }
                Text("换源即切换当前集的播放地址。视频地址来自书源/浏览器识别的 <video> 或你手动导入的 m3u8/mp4 直链。").font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("播放源")
            .toolbar { Button("关闭") { showSources = false } }
        }
        .presentationDetents([.medium])
    }

    func playCurrent() {
        guard !currentURL.isEmpty, let u = URL(string: currentURL) else { return }
        playerModel.play(url: u)
    }

    func sendDanmaku() {
        danmaku.send(danmakuText)
        danmakuText = ""
    }

    func fmt(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "00:00" }
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
