import XCTest
@testable import ReaderPro

@MainActor final class SearchAndPreviewTests: XCTestCase {
    private var files: [(URL, Data?)] = []
    override func setUp() {
        super.setUp()
        files = [BookStore.booksURL, BookStore.metaURL].map { ($0, try? Data(contentsOf: $0)) }
    }
    override func tearDown() {
        for (url, data) in files {
            if let data { try? data.write(to: url) }
            else { try? FileManager.default.removeItem(at: url) }
        }
        super.tearDown()
    }
    private func book() -> LocalBook {
        var book = LocalBook(title: "试读样本", sourceName: "JSON测试源", sourceUrl: SourceTestFixtures.base, fileName: "preview.web", kind: "web")
        book.chapters = [BookChapter(id: "first", title: "第一章", text: "__URL__/chapter", url: SourceTestFixtures.base + "/json/chapter")]
        return book
    }

    func testPreviewProgressAndCacheNeverPersistToShelf() async throws {
        let store = BookStore(), preview = book(), original = store.books
        store.sources = [SourceTestFixtures.json()]
        store.openForReading(preview)
        let cache = ReaderChapterCache(store: store) { _, _, _ in "试读正文" }
        let text = try await cache.content(bookID: preview.id, index: 0)
        XCTAssertEqual(text, "试读正文")
        var changed = try XCTUnwrap(store.readingBook(id: preview.id))
        changed.charOffset = 20; store.updateBook(changed); store.save()
        XCTAssertEqual(store.books, original)
        XCTAssertEqual(store.readingBook(id: preview.id)?.chapters[0].text, "试读正文")
        XCTAssertEqual(store.readingBook(id: preview.id)?.charOffset, 20)
        XCTAssertFalse(BookStore().books.contains { $0.id == preview.id })
    }

    func testExplicitAddPreservesPreviewPositionAndSavesExactlyOnce() throws {
        let store = BookStore(), preview = book()
        store.openForReading(preview)
        var changed = preview; changed.charOffset = 37; changed.chapters[0].text = "已读正文"
        store.updateBook(changed)
        store.addToShelf(try XCTUnwrap(store.readingBook(id: preview.id)))
        store.addToShelf(changed)
        XCTAssertEqual(store.books.filter { $0.id == preview.id }.count, 1)
        XCTAssertNil(store.readingPreviews[preview.id])
        XCTAssertEqual(BookStore().books.first { $0.id == preview.id }?.charOffset, 37)
        changed.charOffset = 45; store.updateBook(changed)
        XCTAssertEqual(BookStore().books.first { $0.id == preview.id }?.charOffset, 45)
    }

    func testDismissedPreviewIgnoresLateProgressAndFetch() async throws {
        let store = BookStore(), preview = book()
        store.sources = [SourceTestFixtures.json()]; store.openForReading(preview)
        var started = false, release = false
        let cache = ReaderChapterCache(store: store) { _, _, _ in
            started = true
            while !release { try await Task.sleep(nanoseconds: 5_000_000) }
            return "迟到的正文"
        }
        let load = Task { try await cache.content(bookID: preview.id, index: 0) }
        for _ in 0..<100 { if started { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(started)
        store.discardReadingPreview(id: preview.id)
        store.updateBook(preview); release = true
        do { _ = try await load.value; XCTFail("已结束的试读不能接收迟到缓存") } catch { }
        XCTAssertNil(store.readingBook(id: preview.id))
        XCTAssertFalse(store.books.contains { $0.id == preview.id })
    }

    func testOpeningExistingShelfBookKeepsPersistingProgress() {
        let store = BookStore(); var saved = book()
        store.updateBook(saved); saved.charOffset = 17
        store.openForReading(saved)
        XCTAssertNil(store.readingPreviews[saved.id])
        XCTAssertEqual(BookStore().books.first { $0.id == saved.id }?.charOffset, 17)
    }

    func testExactAndFuzzyRequireWholeKeywordInTitleOrAuthor() {
        let books = [SourceBook(title: "《仙逆》", author: "耳根", url: "1"),
                     SourceBook(title: "仙逆外传", author: "样例作者", url: "2"),
                     SourceBook(title: "仙路漫漫", author: "样例作者", url: "3"),
                     SourceBook(title: "逆天传", author: "样例作者", url: "4"),
                     SourceBook(title: "仙", author: "逆", url: "5")]
        XCTAssertEqual(books.filter { SearchMatchMode.exact.matches($0, keyword: " 仙逆 ") }.map(\.url), ["1"])
        XCTAssertEqual(books.filter { SearchMatchMode.fuzzy.matches($0, keyword: "仙逆") }.map(\.url), ["1", "2"])
        XCTAssertTrue(SearchMatchMode.exact.matches(books[0], keyword: "耳根"))
        XCTAssertTrue(SearchMatchMode.fuzzy.matches(books[0], keyword: "耳"))
        XCTAssertFalse(SearchMatchMode.fuzzy.matches(books[0], keyword: "  "))
        XCTAssertTrue(SearchMatchMode.exact.matches(SourceBook(title: "ＡＢＣ", url: "6"), keyword: "abc"))
    }

    private func finish(_ controller: SourceSearchController) async throws {
        for _ in 0..<200 { if !controller.searching { return }; try await Task.sleep(nanoseconds: 25_000_000) }
        XCTFail("本地搜索应完成")
    }
    func testMatchingSwitchReusesResultsAndUnmatchedPagesRemainPageable() async throws {
        var source = SourceTestFixtures.json()
        source.searchUrl = "/json/search-match?page={{page}}"; source.ruleSearch.author = "$.author"
        let search = SourceSearchController()
        search.start([source], key: "仙逆", matching: .exact); try await finish(search)
        XCTAssertEqual(search.results.map(\.title), ["仙逆"])
        search.setMatchingMode(.fuzzy)
        XCTAssertEqual(search.results.map(\.title), ["仙逆", "仙逆外传"])
        search.setMatchingMode(.exact)
        XCTAssertEqual(search.results.map(\.title), ["仙逆"])
        search.start([source], key: "无匹配书名", matching: .exact); try await finish(search)
        XCTAssertTrue(search.results.isEmpty); XCTAssertTrue(search.hasMore)
        search.loadMore(); try await finish(search)
        XCTAssertFalse(search.hasMore); XCTAssertEqual(search.page, 2)
    }
}
