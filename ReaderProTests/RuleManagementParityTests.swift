import XCTest
import UIKit
@testable import ReaderPro

final class RuleManagementParityTests: XCTestCase {
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
