import Foundation
import MediaPlayer
import AVFoundation

// One lock-screen owner across audio and video. Late callbacks from a previous
// chapter cannot clear the current player's metadata or remote commands.
final class MediaPlaybackControls {
    static let shared = MediaPlaybackControls()
    private var owner: UUID?
    private var handlers: [(MPRemoteCommand, Any)] = []
    private var observers: [NSObjectProtocol] = []
    private var playAction: (() -> Void)?
    private var pauseAction: (() -> Void)?
    private var isPlaying: (() -> Bool)?
    private var interruptedOwner: UUID?
    private init() {
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.interruption(note)
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let value = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber,
                  AVAudioSession.RouteChangeReason(rawValue: value.uintValue) == .oldDeviceUnavailable else { return }
            self?.interruptedOwner = nil; self?.pauseAction?()
        })
    }
    private func interruption(_ note: Notification) {
        guard let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
              let type = AVAudioSession.InterruptionType(rawValue: value.uintValue) else { return }
        if type == .began {
            interruptedOwner = isPlaying?() == true ? owner : nil
            pauseAction?()
        } else {
            let expected = interruptedOwner; interruptedOwner = nil
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            guard expected != nil, expected == owner, AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) else { return }
            do { try AVAudioSession.sharedInstance().setActive(true); playAction?() }
            catch { SourceExecutionLog.shared.add("恢复播放失败：" + sourceErrorMessage(error), source: "播放器") }
        }
    }
    func activate(owner: UUID, title: String, author: String, play: @escaping () -> Void, pause: @escaping () -> Void,
                  isPlaying: @escaping () -> Bool,
                  toggle: @escaping () -> Void, seek: ((Double) -> Void)?,
                  skip: ((Double) -> Void)?, next: (() -> Void)? = nil, previous: (() -> Void)? = nil) {
        clear(); self.owner = owner
        playAction = play; pauseAction = pause; self.isPlaying = isPlaying
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: author,
            MPNowPlayingInfoPropertyPlaybackRate: 0.0, MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0]
        let commands = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, action: @escaping (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let token = command.addTarget { [weak self] event in
                DispatchQueue.main.async { guard self?.owner == owner else { return }; action(event) }
                return .success
            }
            handlers.append((command, token))
        }
        add(commands.playCommand) { _ in play() }; add(commands.pauseCommand) { _ in pause() }
        add(commands.togglePlayPauseCommand) { _ in toggle() }
        commands.changePlaybackPositionCommand.isEnabled = seek != nil
        if let seek { add(commands.changePlaybackPositionCommand) { if let event = $0 as? MPChangePlaybackPositionCommandEvent { seek(event.positionTime) } } }
        commands.skipForwardCommand.preferredIntervals = [15]; commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.isEnabled = skip != nil; commands.skipBackwardCommand.isEnabled = skip != nil
        if let skip {
            add(commands.skipForwardCommand) { skip(($0 as? MPSkipIntervalCommandEvent)?.interval ?? 15) }
            add(commands.skipBackwardCommand) { skip(-(($0 as? MPSkipIntervalCommandEvent)?.interval ?? 15)) }
        }
        commands.nextTrackCommand.isEnabled = next != nil; commands.previousTrackCommand.isEnabled = previous != nil
        if let next { add(commands.nextTrackCommand) { _ in next() } }
        if let previous { add(commands.previousTrackCommand) { _ in previous() } }
    }
    func update(owner: UUID, time: Double, duration: Double, rate: Float) {
        guard self.owner == owner else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time.isFinite ? max(0, time) : 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        if duration.isFinite && duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    func release(owner: UUID) { if self.owner == owner { clear() } }
    func updateSpeech(owner: UUID, paragraph: Int, count: Int, playing: Bool) {
        guard self.owner == owner else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        info[MPMediaItemPropertyAlbumTitle] = "第 \(paragraph + 1) / \(count) 段"
        // Paragraphs have no reliable duration until synthesized. Do not
        // advertise a time scrubber with invented second-based positions.
        info.removeValue(forKey: MPNowPlayingInfoPropertyElapsedPlaybackTime)
        info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func clear() {
        for (command, token) in handlers { command.removeTarget(token); command.isEnabled = false }
        handlers = []; owner = nil; interruptedOwner = nil; playAction = nil; pauseAction = nil; isPlaying = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
