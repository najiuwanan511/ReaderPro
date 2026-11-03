import SwiftUI
import UIKit

extension Notification.Name { static let readerSelectionAction = Notification.Name("ReaderPro.readerSelectionAction") }

struct ReaderSelectedText: Identifiable {
    let id = UUID()
    let text: String
    let offset: Int
}

// UIKit owns selection handles and its long-press recognizer. Keep taps and
// page pans available until a selection is active, then let the editor own it.
final class ReaderSelectionDelegate: NSObject, UITextViewDelegate {
    static let shared = ReaderSelectionDelegate()
    private weak var selectedView: UITextView?
    var hasSelection: Bool { selectedView?.window != nil && (selectedView?.selectedRange.length ?? 0) > 0 }
    func textViewDidChangeSelection(_ textView: UITextView) { selectedView = textView }
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0, NSMaxRange(range) <= textView.textStorage.length else { return nil }
        let text = (textView.text as NSString).substring(with: range)
        let offset = (textView as? ReaderSelectableTextView)?.chapterOffset ?? 0
        let actions = [("复制", "copy", "doc.on.doc"), ("字典", "dictionary", "character.book.closed"), ("替换", "replace", "wand.and.stars"),
                       ("书签", "bookmark", "bookmark"), ("朗读", "speak", "speaker.wave.2"),
                       ("全文搜索", "search", "magnifyingglass"), ("分享", "share", "square.and.arrow.up")]
        let custom = actions.map { title, action, icon in
            UIAction(title: title, image: UIImage(systemName: icon)) { [weak textView] _ in
                if action == "copy" { UIPasteboard.general.string = text }
                else { NotificationCenter.default.post(name: .readerSelectionAction, object: nil,
                                                userInfo: ["action": action, "text": text, "offset": offset + range.location])
                }
                textView?.selectedRange = NSRange(location: 0, length: 0)
            }
        }
        return UIMenu(children: custom)
    }
}

final class ReaderSelectableTextView: UITextView {
    var chapterOffset = 0
    static var selectionEnabled: Bool { UserDefaults.standard.object(forKey: "reader.selectionEnabled") as? Bool ?? true }
}

struct ReaderShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [text], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
