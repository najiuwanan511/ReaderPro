import XCTest
import UIKit
@testable import ReaderPro

final class RuleManagementParityTests: XCTestCase {
    func testDirectoryRefreshPreservesRawCacheAndPositionWhenChaptersAreInserted() {
        var book = LocalBook(title: "测试书", fileName: "refresh.web", kind: "web")
        book.bookUrl = "https://refresh.test/book"; book.tocUrl = "https://refresh.test/toc"
        book.chapters = [BookChapter(title: "第一章", text: "已缓存正文", url: "/1"), BookChapter(title: "第二章", text: "__URL__/2", url: "/2")]
        book.chapterIndex = 1; book.charOffset = 42
        var heading = BookChapter(title: "第一卷", text: ""); heading.isVolume = true
        let refreshed = book.refreshingDirectory([heading, BookChapter(title: "首章", text: "__URL__/1", url: "/1"), BookChapter(title: "第二章", text: "__URL__/2", url: "/2"), BookChapter(title: "第三章", text: "__URL__/3", url: "/3")])
        XCTAssertEqual(refreshed.chapterIndex, 2); XCTAssertEqual(refreshed.charOffset, 42)
        XCTAssertEqual(refreshed.chapters[1].text, "已缓存正文"); XCTAssertEqual(refreshed.unreadCount, 1)
        XCTAssertEqual(refreshed.sourceBook.url, "https://refresh.test/book")
    }

    func testRuleSubscriptionUsesHourIntervalsAndExplicitAutomaticOptIn() throws {
        var subscription = try JSONDecoder().decode(RuleSubscription.self, from: Data(#"{"id":1,"name":"订阅","url":"https://rules.test/list","autoUpdate":true,"update":1000000,"updateInterval":2}"#.utf8))
        XCTAssertFalse(subscription.isDue(at: Date(timeIntervalSince1970: 8199)))
        XCTAssertTrue(subscription.isDue(at: Date(timeIntervalSince1970: 8200)))
        subscription.autoUpdate = false
        XCTAssertFalse(subscription.isDue(at: .distantFuture))
        try subscription.validate()
    }

    func testCustomSourceActionReceivesEventBookChapterAndReturnsResult() async throws {
        var source = LegadoSource(); source.bookSourceUrl = "https://actions.test"
        let book = SourceBook(title: "小说", author: "作者", url: "https://actions.test/book")
        let chapter = BookChapter(title: "第一章", text: "正文", url: "https://actions.test/chapter/1")
        let result = try await source.performBookAction(script: "[event,book.name,book.author,chapter.title,title,baseUrl].join('|')", book: book, chapter: chapter, event: "clickCustomButton")
        XCTAssertEqual(result.value, "clickCustomButton|小说|作者|第一章|第一章|https://actions.test/chapter/1")
    }

    func testCustomTxtTocRegexSplitsUnicodeAndAppliesCaptureReplacement() throws {
        let rule = try JSONDecoder().decode(TxtTocRule.self, from: Data(#"{"name":"标题规则","rule":"^【(.*?)】$","replacement":"$1"}"#.utf8))
        let chapters = splitTxtChapters("前言内容\n【开篇😀】\n甲内容\n【结尾】\n乙内容", bookTitle: "测试", rules: [rule])
        XCTAssertEqual(chapters.map(\.title), ["前言", "开篇😀", "结尾"])
        XCTAssertEqual(chapters.map(\.text), ["前言内容", "甲内容", "乙内容"])
        var disabled = rule; disabled.enable = false
        XCTAssertEqual(splitTxtChapters("【开篇】\n正文", bookTitle: "测试", rules: [disabled]).count, 1)
    }

    func testRuleLibraryPersistsEnabledAndReplacementWithoutRequiringNewFields() throws {
        let name = "RuleLibraryTest." + UUID().uuidString, defaults = UserDefaults(suiteName: "rules." + UUID().uuidString)!
        defer { defaults.removeObject(forKey: "reader.txtRules"); defaults.removeObject(forKey: "reader.dictionaries") }
        let library = ReaderRuleLibrary(defaults: defaults)
        var toc = TxtTocRule(); toc.name = name; toc.rule = "^Chapter (\\d+)$"; toc.replacement = "第$1章"; toc.enable = false
        library.txtRules = [toc]
        let dictionary = try JSONDecoder().decode(DictRule.self, from: Data(#"{"name":"字典","urlRule":"https://example.test/{{key}}"}"#.utf8))
        library.dictionaries = [dictionary]
        let loaded = ReaderRuleLibrary(defaults: defaults)
        XCTAssertEqual(loaded.txtRules.first?.replacement, "第$1章"); XCTAssertEqual(loaded.txtRules.first?.enable, false)
        XCTAssertEqual(loaded.dictionaries.first?.enabled, true)
    }

    @MainActor func testReaderTextViewsSupportNativeSelection() {
        let view = makeReaderTextView(attributed: NSAttributedString(string: "可选择的正文"), size: CGSize(width: 300, height: 500))
        XCTAssertTrue(view.isSelectable); XCTAssertTrue(view.isUserInteractionEnabled); XCTAssertFalse(view.isEditable)
        XCTAssertNotNil(view.delegate)
    }

    func testAjaxAllExecutesConcurrentlyPreservesOrderAndTaskLocalPageAndKeyword() async throws {
        var source = LegadoSource(); source.bookSourceUrl = "http://127.0.0.1:8765"
        let batch = UUID().uuidString
        let rows = try await source.withRules {
            try LegadoJSCtx.$key.withValue("并发小说") {
                try LegadoJSCtx.$page.withValue(4) {
                    let script = "var urls=Array.from({length:6},function(_,i){return '/parity/ajax?batch=\(batch)&index='+i+'&page={{page}}&key={{key}}';});java.ajaxAll(urls).map(function(r){return JSON.parse(r.body());})"
                    let json = LegadoJS.run(script, input: "", baseUrl: source.bookSourceUrl, sourceKey: "并发小说", sourceUrl: source.bookSourceUrl)
                    try LegadoJSCtx.failures?.check()
                    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
                }
            }
        }
        XCTAssertEqual(rows.compactMap { $0["index"] as? String }, (0..<6).map(String.init))
        XCTAssertTrue(rows.allSatisfy { $0["key"] as? String == "并发小说" && $0["page"] as? String == "4" })
        XCTAssertGreaterThan(rows.compactMap { $0["maxActive"] as? Int }.max() ?? 0, 1)
    }
}
