import XCTest
@testable import ReaderPro

final class MediaAndRssParityTests: XCTestCase {
    func testImageDecodeAcceptsSignedAndroidBytesAndRejectsInvalidOutput() async throws {
        var source = LegadoSource(); source.bookSourceUrl = "https://image-decode.test"
        source.coverDecodeJs = "result.map(function(n){return n>127?n-256:n;})"
        let input = Data([0, 127, 128, 255])
        try await source.withRules {
            XCTAssertEqual(try SourceImagePipeline.decode(input, source: source, cover: true, url: source.bookSourceUrl), input)
        }
        source.coverDecodeJs = "[999]"
        do {
            _ = try await source.withRules { try SourceImagePipeline.decode(input, source: source, cover: true, url: source.bookSourceUrl) }
            XCTFail("Invalid bytes must fail")
        } catch { XCTAssertTrue(sourceErrorMessage(error).contains("字节")) }
    }

    func testSourceRateUsesAndroidMillisecondsAndRequestCount() {
        XCTAssertEqual(SourceRateLimiter.Rate("3/1000")?.count, 3)
        XCTAssertEqual(SourceRateLimiter.Rate("3/1000")?.interval, 1)
        XCTAssertEqual(SourceRateLimiter.Rate("500")?.count, 1)
        XCTAssertEqual(SourceRateLimiter.Rate("500")?.interval, 0.5)
        for invalid in ["", "0/1000", "2/0", "a/b", "1/2/3", "-1"] { XCTAssertNil(SourceRateLimiter.Rate(invalid)) }
    }

    func testRssWebBlacklistPrecedesWhitelistAndMatchesWholeRegexOrPrefix() {
        var source = RssSource()
        source.contentWhitelist = "https://allowed.test/"
        XCTAssertTrue(FeedWebRules.allows("https://allowed.test/image.jpg", source: source))
        XCTAssertFalse(FeedWebRules.allows("https://other.test/image.jpg", source: source))
        source.contentBlacklist = ".*\\.gif,https://ads.test/"
        XCTAssertFalse(FeedWebRules.allows("https://allowed.test/a.gif", source: source))
        XCTAssertFalse(FeedWebRules.allows("https://ads.test/a", source: source))
        XCTAssertTrue(FeedWebRules.allows("https://other.test/a.jpg", source: source))
        XCTAssertNotNil(FeedWebRules.contentRules(source))
    }

    func testRssFavoritesAndHistorySurviveRelaunchWithoutDuplicates() throws {
        let name = "RssParityTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var source = RssSource(); source.sourceName = "订阅"; source.sourceUrl = "https://rss.test"
        let first = SavedRssArticle(source: source, article: RssArticle(title: "文章", link: "https://rss.test/a", content: "正文"))
        let store = RssReadingStore(defaults: defaults)
        store.toggle(first); store.record(first); store.record(first)
        let loaded = RssReadingStore(defaults: defaults)
        XCTAssertEqual(loaded.favorites.count, 1); XCTAssertEqual(loaded.history.count, 1)
        XCTAssertEqual(loaded.history.first?.article.content, "正文")
        loaded.toggle(first)
        XCTAssertTrue(RssReadingStore(defaults: defaults).favorites.isEmpty)
    }

    func testDanmakuParsesTimedXmlAndJsonAndRejectsInvalidTimes() {
        let xml = "<i><d p='2.5,5,25,16711680'>甲&amp;乙</d><d p='-1,1'>丢弃</d><d p='1,1,25,16777215'>先显示</d></i>"
        let entries = parseDanmaku(xml)
        XCTAssertEqual(entries.map(\.text), ["先显示", "甲&乙"])
        XCTAssertEqual(entries.last?.mode, 5); XCTAssertEqual(entries.last?.color, 0xFF0000)
        XCTAssertEqual(parseDanmaku("[{\"time\":1,\"text\":\"字幕\"},{\"time\":-2,\"text\":\"忽略\"}]").map(\.text), ["字幕"])
    }

    func testOnlineAudioUsesChapterRuleAndPreservesHeaders() async throws {
        var source = LegadoSource(); source.bookSourceUrl = "https://audio.test"; source.bookSourceType = 1
        source.header = "{\"X-Audio\":\"token\"}"
        source.ruleContent.content = "@js:baseUrl"
        let resource = try await source.fetchChapterAudio(BookChapter(title: "第1集", text: "", url: "https://audio.test/1.mp3"))
        XCTAssertEqual(resource.request.url?.absoluteString, "https://audio.test/1.mp3")
        XCTAssertEqual(resource.request.value(forHTTPHeaderField: "X-Audio"), "token")
        XCTAssertEqual(source.localBookKind, "audio")
    }
}
