import XCTest
@testable import ReaderPro

// The exact user pack is downloaded and hash checked by CI. These calls use
// the production iOS engine and the real public website, rather than fixtures.
final class LiveSourceTests: XCTestCase {
    func testXiaoxiaoRealCommentDecoderCategoriesDirectoryAndFreeChapter() async throws {
        executionTimeAllowance = 300
        let raw = try await fetchText(urlString: SourceTestFixtures.base + "/packs/user")
        let source = try XCTUnwrap(importSourcesDetailed(raw).sources.first { $0.bookSourceUrl == "https://s.mysignal.cn" })
        let search = try await withTimeout(40) { try await source.search(key: source.ruleSearch.checkKeyWord) }
        let sample = try XCTUnwrap(search.first)
        let categories = try await withTimeout(40) { try await source.withRules { source.exploreCategories() } }
        XCTAssertGreaterThan(categories.count, 6)
        let discovered = try await withTimeout(40) { try await source.discover(category: categories.first) }
        XCTAssertFalse(discovered.isEmpty)
        let detail = try await withTimeout(40) { try await source.fetchBookInfo(book: sample) }
        XCTAssertEqual(detail.tocUrl?.contains("catalog.mysignal.cn"), true, detail.tocUrl ?? "No directory URL")
        let chapters = try await withTimeout(90) { try await source.fetchChapters(book: detail) }
        XCTAssertGreaterThan(chapters.count, 10)
        let first = try XCTUnwrap(chapters.first)
        let text = try await withTimeout(40) { try await source.fetchChapterContent(first, nextChapterUrl: chapters.dropFirst().first?.url) }
        XCTAssertGreaterThan(text.count, 300)
        let evidence = "真实备注解密书源：\(source.bookSourceName)；搜索 \(search.count) 本；分类 \(categories.count) 个；发现 \(discovered.count) 本；目录 \(chapters.count) 章；首章解密 \(text.count) 字。"
        print(evidence)
        let attachment = XCTAttachment(string: evidence); attachment.lifetime = .keepAlways; add(attachment)
    }

    func testQimaoAndQieziRealSearchDirectoryAndDecryptedFreeChapter() async throws {
        let raw = try await fetchText(urlString: SourceTestFixtures.base + "/packs/user")
        let sources = importSourcesDetailed(raw).sources
        for address in ["https://api-bc.wtzw.com/", "https://api-bc.wenxueapp.com"] {
            let source = try XCTUnwrap(sources.first { $0.bookSourceUrl == address })
            let keyword = source.ruleSearch.checkKeyWord.isEmpty ? "斗罗大陆" : source.ruleSearch.checkKeyWord
            let books = try await withTimeout(35) { try await source.search(key: keyword) }
            let sample = try XCTUnwrap(books.first)
            let detail = try await withTimeout(30) { try await source.fetchBookInfo(book: sample) }
            let chapters = try await withTimeout(90) { try await source.fetchChapters(book: detail) }
            let first = try XCTUnwrap(chapters.first)
            let text = try await withTimeout(35) { try await source.fetchChapterContent(first, nextChapterUrl: chapters.dropFirst().first?.url) }
            XCTAssertGreaterThan(chapters.count, 10)
            XCTAssertGreaterThan(text.count, 300)
            XCTAssertFalse(text.hasPrefix("\""), "A Java String must not be returned as JSON-quoted chapter text")
            let evidence = "真实加密书源：\(source.bookSourceName)；搜索 \(books.count) 本；目录 \(chapters.count) 章；首章解密 \(text.count) 字。"
            print(evidence)
            let attachment = XCTAttachment(string: evidence); attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testChuangshiRealSearchCategoryDirectoryAndFreeChapter() async throws {
        let raw = try await fetchText(urlString: SourceTestFixtures.base + "/packs/chuangshi")
        let source = try XCTUnwrap(importSourcesDetailed(raw).sources.first)
        let search = try await withTimeout(35) { try await source.search(key: "神墓") }
        XCTAssertFalse(search.isEmpty)
        let categories = source.exploreCategories()
        XCTAssertFalse(categories.isEmpty)
        let discovered = try await withTimeout(35) { try await source.discover(category: categories.first) }
        XCTAssertFalse(discovered.isEmpty)
        let sample = SourceBook(title: "创世公开阅读回归", url: "https://chuangshi.qq.com/detail/56936324", sourceName: source.bookSourceName, sourceUrl: source.bookSourceUrl)
        let detail = try await source.fetchBookInfo(book: sample)
        XCTAssertEqual(detail.tocUrl, "https://chuangshi.qq.com/chapter/56936324")
        let chapters = try await withTimeout(90) { try await source.fetchChapters(book: detail) }
        XCTAssertGreaterThan(chapters.count, 100)
        let first = try XCTUnwrap(chapters.first)
        let text = try await withTimeout(35) { try await source.fetchChapterContent(first, nextChapterUrl: chapters.dropFirst().first?.url) }
        XCTAssertGreaterThan(text.count, 500)
        let evidence = "真实书源：\(source.bookSourceName)；搜索 \(search.count) 本；分类 \(categories.count) 个；发现 \(discovered.count) 本；目录 \(chapters.count) 章；首个免费章节 \(text.count) 字。"
        print(evidence)
        let attachment = XCTAttachment(string: evidence); attachment.lifetime = .keepAlways; add(attachment)
    }
}
