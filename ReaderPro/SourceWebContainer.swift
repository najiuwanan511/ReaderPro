import UIKit
import WebKit

// Dynamic source headers are resolved off the main thread. Wait for that
// request before constructing WebKit: iOS 17 cannot retrofit an existing
// network session with a retained proxy configuration.
@MainActor final class SourceWebContainer: UIView {
    private(set) var web: WKWebView?
    func install(_ view: WKWebView) {
        clear(); web = view
        view.frame = bounds; view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
    }
    func clear() {
        web?.stopLoading(); web?.navigationDelegate = nil; web?.uiDelegate = nil
        subviews.forEach { $0.removeFromSuperview() }; web = nil
    }
    func showError(_ message: String) {
        clear()
        let label = UILabel(frame: bounds)
        label.text = message; label.numberOfLines = 0; label.textColor = .secondaryLabel
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]; addSubview(label)
    }
}
