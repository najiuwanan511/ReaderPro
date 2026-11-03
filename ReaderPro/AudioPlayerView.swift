import SwiftUI
import AVFoundation
import MediaPlayer

// MARK: - LRC 歌词解析

struct LyricLine: Identifiable, Equatable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}

/// 解析标准 LRC 歌词文本：支持 [mm:ss.xx] 与一行多时间标签
func parseLRC(_ raw: String) -> [LyricLine] {
    var out: [LyricLine] = []
    guard let re = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#) else { return [] }
    for rawLine in raw.components(separatedBy: .newlines) {
        let ns = rawLine as NSString
        let matches = re.matches(in: rawLine, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty, let last = matches.last else { continue }
        let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { continue }
        for m in matches {
            let token = ns.substring(with: m.range)
            let digits = token.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let parts = digits.components(separatedBy: CharacterSet(charactersIn: ":."))
            guard parts.count >= 2, let min = Double(parts[0]), let sec = Double(parts[1]) else { continue }
            var frac: Double = 0
            if parts.count >= 3, let f = Double(parts[2]) {
                frac = f / pow(10.0, Double(parts[2].count))
            }
            out.append(LyricLine(time: min * 60 + sec + frac, text: text))
        }
    }
    return out.sorted { $0.time < $1.time }
}

// MARK: - 音频播放模型

final class AudioPlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackRate: Float = 1.0
    var player: AVPlayer?
    @Published var error = ""
    var onEnded: (() -> Void)?
    private var itemObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func load(url: URL) { load(URLRequest(url: url)) }

    func load(_ request: URLRequest, position: TimeInterval = 0) {
        stop()
        guard let url = request.url else { error = "音频地址无效"; return }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": request.allHTTPHeaderFields ?? [:]]))
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { self?.error = item.error.map(sourceErrorMessage) ?? "音频播放失败"; self?.isPlaying = false }
        }
        let p = AVPlayer(playerItem: item)
        player = p
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            let sec = t.seconds.isFinite ? t.seconds : 0
            self.currentTime = sec
            if let d = p.currentItem?.duration, d.seconds.isFinite { self.duration = d.seconds }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.isPlaying = false
            self?.onEnded?()
        }
        if position > 0 { p.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
        p.playImmediately(atRate: playbackRate)
        isPlaying = true
    }

    func toggle() {
        guard let p = player else { return }
        if p.rate > 0 { p.pause(); isPlaying = false } else { p.playImmediately(atRate: playbackRate); isPlaying = true }
    }

    func seek(to t: TimeInterval) {
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600))
        currentTime = t
    }

    func setRate(_ r: Float) {
        playbackRate = r
        if player?.rate ?? 0 > 0 { player?.rate = r }
    }

    func stop() {
        itemObservation = nil; error = ""
        if let o = timeObserver, let p = player { p.removeTimeObserver(o) }
        timeObserver = nil
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false; currentTime = 0; duration = 0
    }
}

// MARK: - 音频播放器（沉浸式全屏，对标阅读Sigma「带歌词的音频播放」）

struct AudioPlayerView: View {
    let book: LocalBook
    let store: BookStore?
    let source: LegadoSource?
    @State private var chapterIndex: Int
    @State private var retry = 0
    @State private var loading = false
    @State private var showLogin = false
    @State private var showSourceChange = false
    private var chapters: [BookChapter] { (store?.books.first(where: { $0.id == book.id }) ?? book).chapters }

    init(book: LocalBook, store: BookStore? = nil, source: LegadoSource? = nil) {
        self.book = book; self.store = store; self.source = source
        _chapterIndex = State(initialValue: book.chapters.readableIndex(from: max(0, min(book.chapterIndex, book.chapters.count - 1))) ?? 0)
    }
    @StateObject private var model = AudioPlayerModel()
    @Environment(\.dismiss) private var dismiss
    @State private var lyrics: [LyricLine] = []
    @State private var showPlaylist = false
    @State private var showTimer = false
    @State private var sleepRemaining: TimeInterval? = nil
    @State private var loadError = ""
    private let sleepTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // 全屏模糊背景（取封面/渐变色）
            LinearGradient(colors: coverGradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            GeometryReader { geo in
                if !book.coverUrl.isEmpty, let u = URL(string: book.coverUrl) {
                    AsyncImage(url: u) { img in img.resizable().scaledToFill().blur(radius: 40) } placeholder: { EmptyView() }
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                }
            }
            .ignoresSafeArea()
            Color.black.opacity(0.35).ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶栏
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3).foregroundStyle(.white) }
                    Spacer()
                    VStack(spacing: 2) {
                        Text(book.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                        if !book.author.isEmpty { Text(book.author).font(.caption).foregroundStyle(.white.opacity(0.7)) }
                    }
                    Spacer()
                    Button { showTimer = true } label: { Image(systemName: "timer").font(.title3).foregroundStyle(.white) }
                }
                .padding(.horizontal)

                Spacer(minLength: 8)

                // 大圆封面
                coverCircle
                    .padding(.bottom, 18)

                // 逐行歌词
                if chapters.indices.contains(chapterIndex) { Text(chapters[chapterIndex].title).foregroundStyle(.white).lineLimit(1) }
                if loading { ProgressView("正在解析音频…").tint(.white).foregroundStyle(.white) }
                LyricsScrollView(lyrics: lyrics, currentTime: model.currentTime)
                    .frame(maxHeight: 260)

                Spacer(minLength: 8)

                // 进度条
                VStack(spacing: 6) {
                    Slider(value: Binding(get: { model.currentTime }, set: { model.seek(to: $0) }), in: 0...(model.duration > 0 ? model.duration : 1))
                        .tint(.white)
                    HStack {
                        Text(fmt(model.currentTime)).font(.caption).foregroundStyle(.white.opacity(0.8)).monospacedDigit()
                        Spacer()
                        if let s = sleepRemaining { Text("⏰ \(fmt(s))").font(.caption).foregroundStyle(.white.opacity(0.8)) }
                        Spacer()
                        Text(fmt(model.duration)).font(.caption).foregroundStyle(.white.opacity(0.8)).monospacedDigit()
                    }
                }
                .padding(.horizontal)

                // 控制栏
                HStack(spacing: 30) {
                    Button { showPlaylist = true } label: { Image(systemName: "list.bullet").font(.title2).foregroundStyle(.white) }
                    Button { model.setRate(model.playbackRate >= 2 ? 1 : model.playbackRate + 0.25) } label: {
                        Text(String(format: "%.2f", model.playbackRate) + "x").font(.subheadline).foregroundStyle(.white)
                    }
                    Button { seek(-15) } label: { Image(systemName: "gobackward.15").font(.title).foregroundStyle(.white) }
                    Button { model.toggle() } label: {
                        Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 68)).foregroundStyle(.white)
                    }
                    Button { seek(15) } label: { Image(systemName: "goforward.15").font(.title).foregroundStyle(.white) }
                    Button { showTimer = true } label: { Image(systemName: "moon.zzz.fill").font(.title2).foregroundStyle(.white) }
                    Menu {
                        Button("上一章") { changeChapter(-1) }
                        Button("下一章") { changeChapter(1) }
                        Button("重新加载") { retry += 1 }
                        if source?.hasLogin == true { Button("登录 / 接口设置") { showLogin = true } }
                        if source != nil, store != nil { Button("换源") { showSourceChange = true } }
                    } label: { Image(systemName: "ellipsis").font(.title2).foregroundStyle(.white) }
                }
                .padding(.bottom, 30)
            }
            .padding()

            if !loadError.isEmpty || !model.error.isEmpty {
                VStack { Spacer(); Text(loadError.isEmpty ? model.error : loadError).font(.footnote).foregroundStyle(.red).padding().background(.regularMaterial).cornerRadius(10); Spacer() }
            }
        }
        .task(id: "\(chapterIndex)-\(retry)") { await load() }
        .onDisappear { savePosition(); model.stop() }
        .sheet(isPresented: $showLogin) { if let source { SourceLoginView(source: source) } }
        .sheet(isPresented: $showSourceChange, onDismiss: { retry += 1 }) {
            if let store, let current = store.books.first(where: { $0.id == book.id }) {
                ReaderSourceChangeView(store: store, current: current) { candidate, index in
                    guard let chapters = candidate.chapters else { return }
                    var updated = current; updated.chapters = chapters
                    updated.sourceUrl = candidate.book.sourceUrl; updated.sourceName = candidate.book.sourceName
                    updated.chapterIndex = index ?? 0; updated.charOffset = 0
                    store.updateBook(updated); chapterIndex = updated.chapterIndex; showSourceChange = false
                }
            }
        }
        .onReceive(sleepTick) { _ in
            if Int(model.currentTime) % 10 == 0 { savePosition() }
            guard var s = sleepRemaining else { return }
            s -= 1
            if s <= 0 {
                sleepRemaining = nil
                model.player?.pause(); model.isPlaying = false
            } else { sleepRemaining = s }
        }
        .sheet(isPresented: $showPlaylist) { playlistSheet }
        .confirmationDialog("定时关闭", isPresented: $showTimer, titleVisibility: .visible) {
            Button("15 分钟") { setSleep(15 * 60) }
            Button("30 分钟") { setSleep(30 * 60) }
            Button("60 分钟") { setSleep(60 * 60) }
            Button("关闭定时") { sleepRemaining = nil }
            Button("取消", role: .cancel) {}
        }
    }

    var coverCircle: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: coverGradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            if !book.coverUrl.isEmpty, let u = URL(string: book.coverUrl) {
                AsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: { EmptyView() }
                    .frame(width: 220, height: 220).clipShape(Circle())
            } else {
                Text(String(book.title.prefix(2))).font(.system(size: 56, weight: .bold)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: 220, height: 220)
        .overlay(Circle().stroke(AppTheme.unreadBadge.opacity(0.9), lineWidth: 2))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
    }

    var coverGradient: [Color] {
        BookCover.gradient(for: book.title)
    }

    var playlistSheet: some View {
        NavigationStack {
            List {
                if book.chapters.isEmpty {
                    Label("单曲模式", systemImage: "music.note").foregroundStyle(.secondary)
                    Text("导入音频时会生成曲目/章节列表；若只有一个文件就是单曲。").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(book.chapters.enumerated()), id: \.offset) { i, ch in
                        Button { savePosition(); chapterIndex = i; showPlaylist = false } label: {
                            HStack { Text(ch.displayTitle); Spacer(); if i == chapterIndex { Image(systemName: "play.fill") } }
                        }.disabled(ch.isVolume)
                    }
                }
            }
            .navigationTitle("播放列表")
            .toolbar { Button("关闭") { showPlaylist = false } }
        }
        .presentationDetents([.medium])
    }

    @MainActor func load() async {
        model.stop(); loadError = ""; loading = true; lyrics = []
        let index = chapterIndex
        let current = store?.books.first(where: { $0.id == book.id }) ?? book
        let activeSource = store?.sourceForBook(current) ?? source
        model.onEnded = { changeChapter(1) }
        do {
            let request: URLRequest
            var rawLyrics = current.lyrics
            if let activeSource, chapters.indices.contains(index) {
                let chapter = chapters[index]
                let media = try await withTimeout(60) { try await activeSource.fetchChapterAudio(chapter) }
                request = media.request; rawLyrics = media.lyrics
            } else if !current.audioUrl.isEmpty, let url = URL(string: current.audioUrl) {
                request = URLRequest(url: url)
            } else {
                let path = chapters.indices.contains(index) ? videoURLFromChapter(chapters[index].text) : ""
                let local = URL(string: path).flatMap { $0.isFileURL ? $0 : nil } ?? BookStore.filesDir.appendingPathComponent(current.fileName)
                guard FileManager.default.fileExists(atPath: local.path) else { throw SourceFailure(stage: "音频", message: "找不到音频文件，请重新导入") }
                request = URLRequest(url: local)
            }
            guard !Task.isCancelled, chapterIndex == index else { return }
            lyrics = parseLRC(rawLyrics)
            let position = current.chapterIndex == index ? Double(current.charOffset) : 0
            model.load(request, position: position); loading = false
        } catch {
            guard !Task.isCancelled, chapterIndex == index else { return }
            loading = false; loadError = sourceErrorMessage(error)
        }
    }

    func changeChapter(_ delta: Int) {
        guard let index = chapters.readableIndex(from: chapterIndex + delta, direction: delta) else { return }
        savePosition(); chapterIndex = index
    }

    func savePosition() {
        guard let store, !loading, var current = store.books.first(where: { $0.id == book.id }) else { return }
        current.chapterIndex = chapterIndex; current.charOffset = Int(max(0, model.currentTime))
        current.lastRead = Date()
        current.progress = chapters.isEmpty ? 0 : (Double(chapterIndex) + (model.duration > 0 ? model.currentTime / model.duration : 0)) / Double(chapters.count)
        store.updateBook(current)
    }

    func seek(_ delta: TimeInterval) {
        model.seek(to: max(0, model.currentTime + delta))
    }

    func setSleep(_ sec: TimeInterval) {
        sleepRemaining = sec
    }

    func fmt(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "00:00" }
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 歌词滚动视图（当前行高亮居中）

struct LyricsScrollView: View {
    let lyrics: [LyricLine]
    let currentTime: TimeInterval

    private var currentIndex: Int {
        var idx = -1
        for (i, l) in lyrics.enumerated() where l.time <= currentTime { idx = i }
        return idx
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if lyrics.isEmpty {
                    VStack(spacing: 12) {
                        Text("暂无歌词").font(.title3).foregroundStyle(.white.opacity(0.5))
                        Text("导入音频时附带同名 .lrc 或纯文本歌词即可显示").font(.caption).foregroundStyle(.white.opacity(0.35))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(Array(lyrics.enumerated()), id: \.offset) { i, line in
                            Text(line.text)
                                .font(i == currentIndex ? .title3.weight(.semibold) : .body)
                                .foregroundStyle(i == currentIndex ? .white : .white.opacity(0.45))
                                .multilineTextAlignment(.center)
                                .id(i)
                                .animation(.easeInOut(duration: 0.2), value: currentIndex)
                        }
                    }
                    .padding(.vertical, 100)
                }
            }
            .onChange(of: currentIndex) { _, idx in
                guard idx >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
    }
}
