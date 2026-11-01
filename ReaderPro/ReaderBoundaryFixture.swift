#if DEBUG || READERPRO_TESTING
import SwiftUI

// Isolated simulator fixture; never included in the distributed IPA.
struct ReaderBoundaryFixtureRoot: View {
    @StateObject private var store: BookStore
    private let bookID = "reader-boundary-fixture"

    init() {
        let args = ProcessInfo.processInfo.arguments
        let store = BookStore()
        if let arg = args.first(where: { $0.hasPrefix("--reader-mode=") }),
           let mode = Int(arg.dropFirst("--reader-mode=".count)) { store.pageTurn = mode }
        if args.contains("--reset-reader-boundary") {
            let base = SourceTestFixtures.base
            var source = SourceTestFixtures.html()
            source.ruleContent.content = "@css:#content@text"
            source.ruleContent.nextContentUrl = ""
            var book = LocalBook(title: "翻页回归", sourceName: source.bookSourceName,
                                 sourceUrl: source.bookSourceUrl, fileName: "fixture.txt", kind: "web")
            book.id = "reader-boundary-fixture"
            let url = base + "/reader-boundary/long"
            book.chapters = [
                BookChapter(id: "boundary-first", title: "第一章", text: "__URL__" + url, url: url),
                BookChapter(id: "boundary-second", title: "第二章", text: "第二章正文标记"),
                BookChapter(id: "boundary-third", title: "第三章", text: "第三章正文标记")
            ]
            book.chapterIndex = args.contains("--reader-start-second") ? 1 : 0
            store.books = [book]
            store.sources = [source]
            store.save()
        }
        _store = StateObject(wrappedValue: store)
    }

    var body: some View { ReaderView(store: store, bookId: bookID) }
}
#endif
