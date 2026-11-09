import Foundation
import AVFoundation
import Combine

final class VideoPlayerModel: ObservableObject {
    static let playbackRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    let player = AVPlayer()
    @Published var status = "等待播放"
    @Published var error = ""
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playbackRate: Double
    @Published private(set) var isBoosting = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isSeeking = false
    private let defaults: UserDefaults
    private var itemObservation: NSKeyValueObservation?
    private var stateObservation: NSKeyValueObservation?
    private var defaultRateObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var seekID = UUID()
    private let controlID = UUID()
    var onEnded: (() -> Void)?

    var canSeek: Bool { duration > 0 && player.currentItem?.status == .readyToPlay }
    var effectiveRate: Double { isBoosting ? 2 : playbackRate }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.object(forKey: "video.playbackRate") as? Double ?? 1
        playbackRate = Self.playbackRates.contains(saved) ? saved : 1
        player.defaultRate = Float(playbackRate)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self else { return }
            if !self.isSeeking { self.currentTime = time.seconds.isFinite ? max(0, time.seconds) : 0 }
            self.refreshDuration()
            MediaPlaybackControls.shared.update(owner: self.controlID, time: self.currentTime, duration: self.duration, rate: self.player.rate)
        }
        stateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPlaying = self.player.currentItem != nil && self.player.timeControlStatus != .paused
                // A system pause/interruption during a hold must not resume on release.
                if !self.isPlaying { self.isBoosting = false }
                guard self.error.isEmpty else { return }
                switch self.player.timeControlStatus {
                case .playing: self.status = "正在播放"
                case .waitingToPlayAtSpecifiedRate: self.status = "正在缓冲…"
                default: self.status = "已暂停"
                }
            }
        }
        // AVKit's full-screen speed menu changes defaultRate too. Keep the
        // visible selector and next episode in sync without persisting a hold.
        defaultRateObservation = player.observe(\.defaultRate, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.setPlaybackRate(Double(self.player.defaultRate))
            }
        }
    }

    deinit {
        MediaPlaybackControls.shared.release(owner: controlID)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func setPlaybackRate(_ rate: Double) {
        guard Self.playbackRates.contains(rate) else { return }
        if playbackRate != rate { playbackRate = rate }
        defaults.set(rate, forKey: "video.playbackRate")
        if player.defaultRate != Float(rate) { player.defaultRate = Float(rate) }
        if player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            player.rate = Float(effectiveRate)
        }
    }

    func resume() {
        guard player.currentItem != nil else { return }
        player.play()
        if isBoosting { player.rate = 2 }
    }
    func pause() { endBoost(); player.pause() }
    func togglePlayback() {
        if player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate { pause() }
        else { resume() }
    }

    @discardableResult func beginBoost() -> Bool {
        guard !isBoosting, error.isEmpty, player.currentItem?.status == .readyToPlay,
              player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return false }
        isBoosting = true; player.rate = 2
        return true
    }
    func endBoost() {
        guard isBoosting else { return }
        isBoosting = false
        if player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate { player.rate = Float(playbackRate) }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, canSeek, let item = player.currentItem else { return }
        endBoost()
        let target = min(max(0, seconds), duration)
        let id = UUID(); seekID = id; isSeeking = true; currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] finished in
            DispatchQueue.main.async {
                guard let self, self.seekID == id, let item, self.player.currentItem === item else { return }
                self.isSeeking = false
                let time = self.player.currentTime().seconds
                if time.isFinite { self.currentTime = max(0, time) }
                if !finished { self.status = "快进未完成，请重试" }
            }
        }
    }

    private func refreshDuration() {
        let value = player.currentItem?.duration.seconds ?? 0
        duration = value.isFinite && value > 0 ? value : 0
    }

    func stop() {
        MediaPlaybackControls.shared.release(owner: controlID)
        seekID = UUID(); isSeeking = false; isBoosting = false; isPlaying = false
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        player.currentItem?.cancelPendingSeeks()
        player.pause(); player.replaceCurrentItem(with: nil)
        currentTime = 0; duration = 0; error = ""; status = "正在解析播放地址…"
    }

    func play(_ request: URLRequest, title: String = "视频", author: String = "") {
        stop()
        guard let url = request.url else { error = "播放地址无效"; return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        var options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": request.allHTTPHeaderFields ?? [:]]
        options[AVURLAssetHTTPCookiesKey] = HTTPCookieStorage.shared.cookies(for: url) ?? []
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        item.audioTimePitchAlgorithm = .spectral
        error = ""; status = "正在缓冲…"
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.player.currentItem === item else { return }
                self.refreshDuration()
                if item.status == .failed {
                    self.isBoosting = false; self.isPlaying = false
                    self.error = "视频播放失败：" + (item.error.map(sourceErrorMessage) ?? "地址不可用或格式不受系统支持")
                    self.status = "播放失败"
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self, self.player.currentItem === item else { return }
            self.endBoost(); self.onEnded?()
        }
        player.replaceCurrentItem(with: item)
        player.defaultRate = Float(playbackRate)
        MediaPlaybackControls.shared.activate(owner: controlID, title: title, author: author,
            play: { [weak self] in self?.resume() }, pause: { [weak self] in self?.pause() },
            isPlaying: { [weak self] in guard let self else { return false }; return self.player.rate > 0 || self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate },
            toggle: { [weak self] in self?.togglePlayback() },
            seek: { [weak self] in self?.seek(to: $0) },
            skip: { [weak self] seconds in guard let self else { return }; self.seek(to: self.currentTime + seconds) }, next: onEnded)
        resume()
    }
}
