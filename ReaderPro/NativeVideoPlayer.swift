import SwiftUI
import AVKit

// Keep AVKit's full-screen, AirPlay, PiP and accessibility controls. A hold on
// the picture temporarily changes the rate; taps and transport buttons retain
// their system behavior.
struct NativeVideoPlayer: UIViewControllerRepresentable {
    @ObservedObject var model: VideoPlayerModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = model.player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.speeds = VideoPlayerModel.playbackRates.map { AVPlaybackSpeed(rate: Float($0), localizedName: String(format: "%g 倍", $0)) }
        controller.delegate = context.coordinator
        context.coordinator.attach(to: controller.view)
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.updateIndicator()
    }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.detach(); controller.delegate = nil; controller.player = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, AVPlayerViewControllerDelegate {
        private weak var model: VideoPlayerModel?
        private lazy var hold: UILongPressGestureRecognizer = {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(holding(_:)))
            gesture.minimumPressDuration = 0.45
            gesture.allowableMovement = 30
            gesture.cancelsTouchesInView = true
            gesture.delegate = self
            return gesture
        }()
        private let indicator = UILabel()
        init(model: VideoPlayerModel) {
            self.model = model
            super.init()
            indicator.text = "  2 倍速播放中  "
            indicator.font = .preferredFont(forTextStyle: .subheadline)
            indicator.textColor = .white
            indicator.backgroundColor = UIColor.black.withAlphaComponent(0.7)
            indicator.layer.cornerRadius = 10; indicator.clipsToBounds = true
            indicator.isUserInteractionEnabled = false
            indicator.accessibilityIdentifier = "videoHoldIndicator"
            indicator.isHidden = true
        }
        func attach(to view: UIView) {
            hold.view?.removeGestureRecognizer(hold)
            indicator.removeFromSuperview()
            view.addGestureRecognizer(hold)
            indicator.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(indicator)
            NSLayoutConstraint.activate([
                indicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                indicator.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
                indicator.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
            ])
            updateIndicator()
        }
        func updateIndicator() { indicator.isHidden = model?.isBoosting != true }
        func detach() {
            model?.endBoost(); hold.view?.removeGestureRecognizer(hold)
            indicator.removeFromSuperview()
        }
        @objc private func holding(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                if model?.beginBoost() == true { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            case .ended, .cancelled, .failed: model?.endBoost()
            default: break
            }
            updateIndicator()
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UIControl { return false }
                if current === gestureRecognizer.view { break }
                view = current.superview
            }
            return true
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let model else { return false }
            return model.player.rate > 0 || model.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Don't let a completed hold also fire AVKit's tap-to-pause action.
            otherGestureRecognizer is UIPanGestureRecognizer
        }
        func playerViewController(_ playerViewController: AVPlayerViewController, willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            model?.endBoost()
            coordinator.animate(alongsideTransition: nil) { [weak self, weak playerViewController] context in
                guard let self, let playerViewController else { return }
                self.attach(to: context.isCancelled ? playerViewController.view : (context.viewController(forKey: .to)?.view ?? playerViewController.view))
            }
        }
        func playerViewController(_ playerViewController: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            model?.endBoost()
            coordinator.animate(alongsideTransition: nil) { [weak self, weak playerViewController] context in
                guard let self, let playerViewController else { return }
                if !context.isCancelled { self.attach(to: playerViewController.view) }
            }
        }
    }
}
