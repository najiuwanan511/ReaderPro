import XCTest
@testable import ReaderPro

final class RssSourceTests: XCTestCase {
    func testBookNetworkImporterRecognizes203WithoutExpandingItsWebsites() async throws {
        let result = try await importSourcePacksFromURL(SourceTestFixtures.base + "/packs/rss203")
        XCTAssertTrue(result.sources.isEmpty, "订阅源不能混进书源列表")
        XCTAssertEqual(result.rssSources.count, 71)
        XCTAssertEqual(result.fetchedPacks, 1, "只下载合集 JSON，不能抓取订阅网站")
        XCTAssertEqual(result.skipped, 0)
        XCTAssertTrue(result.failures.isEmpty, result.diagnostics)
        await MainActor.run {
            let store = BookStore()
            let oldBooks = store.sources, oldRss = store.rssSources
            defer { store.sources = oldBooks; store.rssSources = oldRss; store.save() }
            store.rssSources = []
            let message = store.mergeImportedSources(result)
            XCTAssertTrue(message.contains("71 个订阅源"))
            XCTAssertTrue(message.contains("订阅源管理"))
            XCTAssertEqual(store.sources, oldBooks)
            XCTAssertEqual(store.rssSources.count, 71)
            let ids = store.rssSources.map(\.id)
            store.rssSources[0].enabled = false
            _ = store.mergeImportedSources(result)
            XCTAssertEqual(store.rssSources.count, 71)
            XCTAssertEqual(store.rssSources.map(\.id), ids)
            XCTAssertFalse(store.rssSources[0].enabled)
            let reloaded = BookStore()
            XCTAssertEqual(reloaded.rssSources, store.rssSources)
            XCTAssertEqual(reloaded.sources, oldBooks)
        }
    }

    func testMixedBookAndRSSChildCollectionsNeverFetchSubscriptionURLs() async throws {
        let token = UUID().uuidString
        let result = try await importSourcePacksFromURL(SourceTestFixtures.base + "/packs/book-and-rss?token=" + token)
        XCTAssertEqual(result.sources.map(\.bookSourceName), ["混合书源"])
        XCTAssertEqual(result.rssSources.map(\.sourceName), ["导航订阅", "规则订阅"])
        XCTAssertEqual(result.fetchedPacks, 2)
        XCTAssertTrue(result.failures.isEmpty, result.diagnostics)
        let count = try await fetchText(urlString: SourceTestFixtures.base + "/rss-import-trap/" + token + "/count")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(count.utf8)) as? [String: Int])
        XCTAssertEqual(object["count"], 0, "订阅站点、分类与脚本中的 URL 均不能作为子合集请求")
    }

    func testDocumentImportRoutesWrappedAndMixedJSONWithoutMisreadingLinkDescriptors() throws {
        let rss: [String: Any] = ["sourceName": "示例订阅", "sourceUrl": "https://rss.invalid", "singleUrl": true,
                                  "header": ["X-Value": "&quot;"], "ruleContent": "@js:result.replace(/&quot;/g,'x')"]
        let book: [String: Any] = ["bookSourceName": "示例书源", "bookSourceUrl": "https://book.invalid"]
        let contents = try JSONSerialization.data(withJSONObject: [rss, book, ["sourceUrl": "/child-pack"], rss,
                                                                   ["sourceName": "坏订阅", "sourceUrl": NSNull()]])
        let wrapped = try JSONSerialization.data(withJSONObject: ["data": ["items": String(decoding: contents, as: UTF8.self)]])
        let result = importSourceDocument(String(decoding: wrapped, as: UTF8.self))
        XCTAssertEqual(result.sources.map(\.bookSourceName), ["示例书源"])
        XCTAssertEqual(result.rssSources.map(\.sourceName), ["示例订阅"])
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(result.rssSources[0].ruleContent.contains("&quot;"))
        XCTAssertEqual(importSourceDocument(String(decoding: try JSONEncoder().encode(result.rssSources[0]), as: UTF8.self)).rssSources.count, 1)
        XCTAssertTrue(importRssSourcesDetailed(#"{"sourceUrl":"https://pack.invalid/list.json"}"#).sources.isEmpty)
    }

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
        // This exact field pattern occurs in the user's 203 source pack.
        source.ruleImage = "img@data-cover"
        source.ruleNextPage = "@css:a.next@href"
        source.ruleContent = "@css:div.content@html"
        let categories = try await source.categories()
        XCTAssertEqual(categories.map(\.title), ["推荐", "其他"])
        let first = try await source.articles(at: categories[0].url)
        XCTAssertEqual(first.articles.map(\.title), ["样本文章"])
        XCTAssertEqual(first.articles.first?.link, SourceTestFixtures.base + "/rss/article")
        XCTAssertEqual(first.articles.first?.pubDate, "今天")
        XCTAssertEqual(first.articles.first?.image, SourceTestFixtures.base + "/rss/cover.jpg")
        let next = try XCTUnwrap(first.nextURL)
        let second = try await source.articles(at: next, page: 2)
        XCTAssertEqual(second.articles.map(\.title), ["第二页文章"])
        XCTAssertEqual(second.articles.first?.image, "")
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
        XCTAssertEqual(article.image, SourceTestFixtures.base + "/rss/cover.jpg")
        XCTAssertTrue(article.content.contains("内容"))
    }

    func testInvalidOptionalImageRuleDoesNotDiscardArticles() async throws {
        var source = RssSource()
        source.sourceUrl = SourceTestFixtures.base
        source.header = #"{"X-Fixture":"RSS"}"#
        source.ruleArticles = "@css:article"
        source.ruleTitle = "@css:a.title@text"
        source.ruleLink = "@css:a.title@href"
        source.ruleImage = "@js:throw new Error('bad optional image rule')"
        let page = try await source.articles(at: "/rss/list")
        XCTAssertEqual(page.articles.map(\.title), ["样本文章"])
        XCTAssertEqual(page.articles.first?.image, "")
    }

    func testRSSImageEnclosureDoesNotMistakeAudioForCover() {
        let xml = #"<rss><channel><item><title>样本</title><enclosure url="/audio.mp3" type="audio/mpeg"/><enclosure url="/cover.jpg" type="image/jpeg"/></item></channel></rss>"#
        let article = parseRssXML(Data(xml.utf8)).first
        XCTAssertEqual(article?.image, "/cover.jpg")
        XCTAssertEqual(parseRssXML(Data("<rss><channel><item><title>无图</title></item></channel></rss>".utf8)).first?.image, "")
    }
}

