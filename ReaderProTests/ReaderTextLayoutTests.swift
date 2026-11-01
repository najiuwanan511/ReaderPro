import XCTest
import UIKit
@testable import ReaderPro

final class ReaderTextLayoutTests: XCTestCase {
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
