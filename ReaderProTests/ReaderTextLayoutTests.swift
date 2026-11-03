import XCTest
import UIKit
import SwiftUI
@testable import ReaderPro

final class ReaderTextLayoutTests: XCTestCase {
    @MainActor func testSwiftUIColumnsRetainSeparateFramesAndWrappedText() async {
        let size = CGSize(width: 180, height: 300)
        let original = NSAttributedString(string: String(repeating: "分页正文必须换行。", count: 30), attributes: [.font: UIFont.systemFont(ofSize: 18)])
        let page = original.attributedSubstring(from: Paginator.paginate(original, pageSize: size)[0])
        let controller = UIHostingController(rootView: HStack(spacing: 0) {
            PageTextView(attributed: page, pageSize: size, viewportSize: CGSize(width: 210, height: 360))
            PageTextView(attributed: page, pageSize: size, viewportSize: CGSize(width: 210, height: 360))
        }.frame(width: 420, height: 360))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 360))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 100_000_000)
        controller.view.layoutIfNeeded()
        func surfaces(_ view: UIView) -> [ReaderPageSurface] {
            if let surface = view as? ReaderPageSurface { return [surface] }
            return view.subviews.flatMap(surfaces)
        }
        let columns = surfaces(controller.view)
        XCTAssertEqual(columns.count, 2)
        guard columns.count == 2 else { return }
        let frames = columns.map { $0.textView.convert($0.textView.bounds, to: window) }
        XCTAssertGreaterThan(abs(frames[0].midX - frames[1].midX), 180)
        for column in columns {
            let text = column.textView
            XCTAssertEqual(text.textContainer.size, size)
            let used = text.layoutManager.usedRect(for: text.textContainer)
            XCTAssertGreaterThan(used.height, 100, "SwiftUI measurement must not flatten a page into one overwide line")
            XCTAssertLessThanOrEqual(used.maxX, size.width + 1)
            XCTAssertLessThanOrEqual(used.maxY, size.height + 1)
        }
    }
    private final class StorageObserver: NSObject, NSTextStorageDelegate {
        var edits = 0
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
                         range editedRange: NSRange, changeInLength delta: Int) { edits += 1 }
    }

    @MainActor func testUnchangedReaderTextDoesNotInvalidateTextKitStorage() async {
        let original = NSAttributedString(string: String(repeating: "阅读正文。", count: 200), attributes: [.font: UIFont.systemFont(ofSize: 18)])
        let view = makeReaderTextView(attributed: original, size: CGSize(width: 320, height: 500))
        let observer = StorageObserver()
        view.textStorage.delegate = observer
        setReaderTextIfChanged(view, original.copy() as! NSAttributedString)
        XCTAssertEqual(observer.edits, 0, "An unrelated SwiftUI update must not replace or relayout the chapter text")
        let changed = NSAttributedString(string: original.string + "新内容", attributes: [.font: UIFont.systemFont(ofSize: 18)])
        setReaderTextIfChanged(view, changed)
        XCTAssertGreaterThan(observer.edits, 0)
        XCTAssertEqual(view.textStorage.string, changed.string)
    }

    func testOlderBookmarksWithoutCharacterOffsetRemainReadable() throws {
        let old = #"{"id":"old","bookId":"book","chapterIndex":2,"paragraphIndex":3,"snippet":"旧书签","date":0}"#
        let bookmark = try JSONDecoder().decode(Bookmark.self, from: Data(old.utf8))
        XCTAssertEqual(bookmark.paragraphIndex, 3)
        XCTAssertNil(bookmark.charOffset)
        var current = bookmark
        current.charOffset = 531
        let restored = try JSONDecoder().decode(Bookmark.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(restored.charOffset, 531)
    }
}
