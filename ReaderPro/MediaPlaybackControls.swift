import Foundation
import MediaPlayer

// One lock-screen owner across audio and video. Late callbacks from a previous
// chapter cannot clear the current player's metadata or remote commands.
final class MediaPlaybackControls {
    static let shared = MediaPlaybackControls()
    private var owner: UUID?
    private var handlers: [(MPRemoteCommand, Any)] = []
    func activate(owner: UUID, title: String, author: String, play: @escaping () -> Void, pause: @escaping () -> Void,
                  toggle: @escaping () -> Void, seek: @escaping (Double) -> Void,
                  skip: @escaping (Double) -> Void, next: (() -> Void)? = nil, previous: (() -> Void)? = nil) {
        clear(); self.owner = owner
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
        add(commands.changePlaybackPositionCommand) { if let event = $0 as? MPChangePlaybackPositionCommandEvent { seek(event.positionTime) } }
        commands.skipForwardCommand.preferredIntervals = [15]; commands.skipBackwardCommand.preferredIntervals = [15]
        add(commands.skipForwardCommand) { skip(($0 as? MPSkipIntervalCommandEvent)?.interval ?? 15) }
        add(commands.skipBackwardCommand) { skip(-(($0 as? MPSkipIntervalCommandEvent)?.interval ?? 15)) }
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
    private func clear() {
        for (command, token) in handlers { command.removeTarget(token); command.isEnabled = false }
        handlers = []; owner = nil; MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
