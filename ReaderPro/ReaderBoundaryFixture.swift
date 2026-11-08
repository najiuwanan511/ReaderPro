#if DEBUG || READERPRO_TESTING
import SwiftUI

// Isolated simulator fixture; never included in the distributed IPA.
struct ReaderBoundaryFixtureRoot: View {
    @StateObject private var store: BookStore
    @AppStorage("ReaderPro.test.visibleScrollOffset") private var visibleScrollOffset = 0
    private let bookID = "reader-boundary-fixture"

    init() {
        let args = ProcessInfo.processInfo.arguments
        let store = BookStore()
        if args.contains("--reader-scroll-position-fixture") {
            UserDefaults.standard.set(0, forKey: "ReaderPro.test.visibleScrollOffset")
        }
        store.showHeader = true
        store.showFooter = true
        UserDefaults.standard.set(args.contains("--reader-double-page"), forKey: "reader.landscapeDoublePage")
        if let arg = args.first(where: { $0.hasPrefix("--reader-mode=") }),
           let mode = Int(arg.dropFirst("--reader-mode=".count)) { store.pageTurn = mode }
        if args.contains("--reset-reader-boundary") {
            for row in 0..<3 { for column in 0..<3 { UserDefaults.standard.removeObject(forKey: ReaderInteraction.key(row, column)) } }
            UserDefaults.standard.set(true, forKey: "reader.selectionEnabled")
            UserDefaults.standard.set(50.0, forKey: "reader.swipeDistance")
            UserDefaults.standard.set(0, forKey: "ReaderPro.test.visibleScrollOffset")
            let base = SourceTestFixtures.base
            var source = SourceTestFixtures.html()
            source.ruleContent.content = "@css:#content@text"
            source.ruleContent.nextContentUrl = ""
            var book = LocalBook(title: "翻页回归", sourceName: source.bookSourceName,
                                 sourceUrl: source.bookSourceUrl, fileName: "fixture.txt", kind: "web")
            if args.contains("--reader-source-change-fixture") { book.title = "测试小说" }
            book.id = "reader-boundary-fixture"
            let url = base + "/reader-boundary/long"
            book.chapters = [
                BookChapter(id: "boundary-first", title: "第一章", text: "__URL__" + url, url: url),
                BookChapter(id: "boundary-second", title: "第二章", text: "第二章正文标记"),
                BookChapter(id: "boundary-third", title: "第三章", text: "第三章正文标记")
            ]
            book.chapterIndex = args.contains("--reader-start-second") ? 1 : 0
            if args.contains("--reader-catalog-position-fixture") {
                book.chapters = (1...120).map { number in
                    BookChapter(id: "catalog-\(number)", title: "第\(number)章", text: "目录定位第\(number)章正文标记")
                }
                let start = args.first(where: { $0.hasPrefix("--reader-catalog-start=") })
                    .flatMap { Int($0.dropFirst("--reader-catalog-start=".count)) } ?? 70
                book.chapterIndex = boundedReadingIndex(start - 1, count: book.chapters.count)
            }
            store.books = [book]
            store.sources = [source]
            if args.contains("--reader-bookmark-fixture") {
                let endOffset = (String(repeating: "第一章分页内容。", count: 1200) as NSString).length
                store.bookmarks = [
                    Bookmark(bookId: book.id, chapterIndex: 0, paragraphIndex: 2, snippet: "旧网络书签"),
                    Bookmark(bookId: book.id, chapterIndex: 0, paragraphIndex: 2, snippet: "新网络书签", charOffset: endOffset)
                ]
            }
            store.save()
        }
        if args.contains("--reader-custom-cover-tap") {
            UserDefaults.standard.set(ReaderTapAction.catalog.rawValue, forKey: ReaderInteraction.key(1, 2))
        }
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        ReaderView(store: store, bookId: bookID)
            .overlay(alignment: .topLeading) {
                if ProcessInfo.processInfo.arguments.contains("--reader-scroll-position-fixture") {
                    VStack {
                        // SwiftUI formats interpolated integers for the current locale
                        // (for example, 9,139). Expose stable decimal digits so the
                        // UI tests can parse offsets above one thousand correctly.
                        Text(verbatim: String(visibleScrollOffset)).accessibilityIdentifier("readerVisibleScrollOffset")
                        Text(verbatim: String(store.books.first(where: { $0.id == bookID })?.charOffset ?? 0))
                            .accessibilityIdentifier("readerSavedScrollOffset")
                    }.font(.system(size: 1)).opacity(0.5).allowsHitTesting(false)
                }
            }
    }
}
#endif
