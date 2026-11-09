import SwiftUI

struct VideoPlaybackControls: View {
    @ObservedObject var model: VideoPlayerModel
    @State private var scrubbing = false
    @State private var draft = 0.0

    private var position: Double { scrubbing ? draft : model.currentTime }
    private func time(_ seconds: Double) -> String {
        let value = Int(seconds.isFinite ? max(0, seconds) : 0)
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60)
    }
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(time(position)).monospacedDigit()
                Slider(value: Binding(get: { min(max(0, position), max(1, model.duration)) }, set: { draft = $0 }),
                       in: 0...max(1, model.duration), onEditingChanged: { editing in
                    if editing { draft = model.currentTime; scrubbing = true }
                    else { model.seek(to: draft); scrubbing = false }
                }).disabled(!model.canSeek)
                    .accessibilityLabel("播放进度")
                    .accessibilityIdentifier("videoSeekSlider")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: model.seek(to: model.currentTime + 10)
                        case .decrement: model.seek(to: model.currentTime - 10)
                        @unknown default: break
                        }
                    }
                Text(model.duration > 0 ? time(model.duration) : "--:--").monospacedDigit()
            }.font(.caption)
            HStack {
                Button { model.togglePlayback() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(minWidth: 36, minHeight: 32) }
                    .disabled(model.player.currentItem == nil || !model.error.isEmpty)
                    .accessibilityLabel(model.isPlaying ? "暂停播放" : "继续播放")
                    .accessibilityIdentifier("videoPlayPause")
                Menu {
                    ForEach(VideoPlayerModel.playbackRates, id: \.self) { rate in
                        Button { model.setPlaybackRate(rate) } label: {
                            if rate == model.playbackRate { Label("\(rate, specifier: "%g") 倍", systemImage: "checkmark") }
                            else { Text("\(rate, specifier: "%g") 倍") }
                        }.accessibilityIdentifier("video-rate-\(rate)")
                    }
                } label: { Text("\(model.playbackRate, specifier: "%g") 倍速").monospacedDigit() }
                    .accessibilityIdentifier("videoSpeedMenu")
                    .accessibilityValue("\(model.playbackRate, specifier: "%g") 倍")
                Spacer()
                Text(model.duration > 0 ? "长按画面 2 倍速" : "直播或暂不可快进").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
