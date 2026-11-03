import UIKit

// Script notifications are non-modal so a discovery action can report its
// result without cancelling or intercepting the user's next navigation.
@MainActor enum SourceScriptToast {
    private static var visible: UIView?
    private static var dismissal: Task<Void, Never>?

    static func show(_ message: String, tag: String, long: Bool) {
        dismissal?.cancel(); visible?.removeFromSuperview(); visible = nil
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let text = tag.isEmpty ? message : tag + ": " + message
        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.backgroundColor = UIColor(white: 0.12, alpha: 0.94)
        panel.layer.cornerRadius = 12
        panel.isUserInteractionEnabled = false
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text; label.numberOfLines = 4; label.textAlignment = .center
        label.textColor = .white; label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.accessibilityIdentifier = "sourceScriptToast"
        panel.addSubview(label); window.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            panel.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -64),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: window.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10)
        ])
        visible = panel
        UIAccessibility.post(notification: .announcement, argument: text)
        dismissal = Task {
            do { try await Task.sleep(nanoseconds: long ? 3_500_000_000 : 2_000_000_000) }
            catch { return }
            guard visible === panel else { return }
            panel.removeFromSuperview(); visible = nil; dismissal = nil
        }
    }
}
