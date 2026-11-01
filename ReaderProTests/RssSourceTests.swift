import XCTest
@testable import ReaderPro

final class RssSourceTests: XCTestCase {
    func testImportActual203CollectionAndMergeWithoutDuplicates() async throws {
        // The fixture server supplies an unmodified CI-only download of the
        // exact user-provided collection; no third-party data ships in the app.
        let url = SourceTestFixtures.base + "/packs/rss203"
        let sources = try await importRssSourcesFromURL(url)
        XCTAssertEqual(sources.count, 71)
        XCTAssertEqual(Set(sources.map(\.sourceUrl)).count, 71)
        XCTAssertEqual(sources.filter(\.singleUrl).count, 29)
        XCTAssertEqual(sources.filter(\.isRssRuleSource).count, 43)
        XCTAssertTrue(sources.contains { !$0.sortUrl.isEmpty && !$0.ruleTitle.isEmpty && !$0.ruleLink.isEmpty })
        let imported = mergeRssSources([], incoming: sources)
        var disabled = imported
        disabled[0].enabled = false
        let importedAgain = mergeRssSources(disabled, incoming: sources)
        XCTAssertEqual(importedAgain.count, 71)
        XCTAssertEqual(importedAgain[0].id, disabled[0].id)
        XCTAssertFalse(importedAgain[0].enabled)
        let roundTrip = try JSONDecoder().decode([RssSource].self, from: JSONEncoder().encode(importedAgain))
        XCTAssertEqual(roundTrip, importedAgain)
    }

    func testLegadoCategoryListHeadersPaginationAndContent() async throws {
        var source = RssSource()
        source.sourceName = "订阅测试"
        source.sourceUrl = SourceTestFixtures.base
        source.header = #"{"X-Fixture":"RSS"}"#
        source.sortUrl = "推荐::/rss/list\n其他::/rss/list2"
        source.ruleArticles = "@css:article"
        source.ruleTitle = "@css:a.title@text"
        source.ruleLink = "@css:a.title@href"
        source.rulePubDate = "@css:.date@text"
        source.ruleNextPage = "@css:a.next@href"
        source.ruleContent = "@css:div.content@html"
        let categories = try await source.categories()
        XCTAssertEqual(categories.map(\.title), ["推荐", "其他"])
        let first = try await source.articles(at: categories[0].url)
        XCTAssertEqual(first.articles.map(\.title), ["样本文章"])
        XCTAssertEqual(first.articles.first?.link, SourceTestFixtures.base + "/rss/article")
        XCTAssertEqual(first.articles.first?.pubDate, "今天")
        let next = try XCTUnwrap(first.nextURL)
        let second = try await source.articles(at: next, page: 2)
        XCTAssertEqual(second.articles.map(\.title), ["第二页文章"])
        let content = try await source.articleContent(XCTUnwrap(first.articles.first))
        XCTAssertTrue(content.contains("订阅测试正文"))
    }

    func testAtomCDATAAndRelativeLink() async throws {
        var source = RssSource()
        source.sourceUrl = SourceTestFixtures.base + "/rss/atom"
        let page = try await source.articles(at: source.sourceUrl)
        let article = try XCTUnwrap(page.articles.first)
        XCTAssertEqual(article.title, "Atom 样本")
        XCTAssertEqual(article.link, SourceTestFixtures.base + "/rss/article")
        XCTAssertTrue(article.content.contains("内容"))
    }
}

