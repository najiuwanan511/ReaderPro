import XCTest
@testable import ReaderPro

final class LegadoIndexRuleTests: XCTestCase {
    private let base = "https://index.test"

    func testActualCollectionRulesSupportInclusiveIndexListsAndRanges() {
        let html = #"<div class="mytable"><table><tbody><tr><td>标题</td></tr><tr><td>第一本</td></tr><tr><td>第二本</td></tr><tr><td>第三本</td></tr></tbody></table></div>"#
        // Verbatim bookList from 1329 的「金银小说网」.
        let rows = applyRule(html, "class.mytable@tag.tbody@tag.tr[1:]", base: base)
        XCTAssertEqual(rows.map { stripText($0, preserveNewlines: false) }, ["第一本", "第二本", "第三本"])
        let paragraphs = "<div><p>零</p><p>一</p><p>二</p><p>三</p></div>"
        // 1329 的「涩涩小说」 uses p[1,2,3]; 「八零小说」 uses p[-2:-3].
        XCTAssertEqual(applyRule(paragraphs, "p[1,2,3]@text", base: base), ["一", "二", "三"])
        XCTAssertEqual(applyRule(paragraphs, "p[-2:-3]@text", base: base), ["二", "一"])
        XCTAssertEqual(applyRule(paragraphs, "p[-1:0:2]@text", base: base), ["三", "一"])
        XCTAssertEqual(applyRule(paragraphs, "p[!0,2]@text", base: base), ["一", "三"])
        XCTAssertEqual(applyRule(paragraphs, "p[100:200]@text", base: base), [])
    }

    func testIndexIsAppliedToEachParentAndCSSAttributesStayCSS() {
        let html = #"<div class="group"><a href="/a">a</a><a href="/b">b</a></div><div class="group"><a href="/c">c</a><a href="/d">d</a></div>"#
        XCTAssertEqual(applyRule(html, "class.group@a[0]@text", base: base), ["a", "c"])
        XCTAssertEqual(applyRule(html, "class.group@a.0@text", base: base), ["a", "c"])
        XCTAssertEqual(applyRule(html, "class.group@children[1]@text", base: base), ["b", "d"])
        XCTAssertEqual(applyRule(html, "a[href='/b']@text", base: base), ["b"])
    }

    func testBilingualSourceInterleavesMatchingLines() {
        let html = #"<p class="line_en">Hello</p><p class="line_cn" title="你好"></p><p class="line_en">Goodbye</p><p class="line_cn" title="再见"></p>"#
        // This is the actual 1325 双语小说正文 rule.
        XCTAssertEqual(applyRule(html, ".line_en@text%%.line_cn@title", base: base), ["Hello", "你好", "Goodbye", "再见"])
        let asymmetric = #"<p class="line_en">One</p><p class="line_cn" title="一"></p><p class="line_cn" title="额外"></p>"#
        XCTAssertEqual(applyRule(asymmetric, ".line_en@text%%.line_cn@title", base: base), ["One", "一"])
    }
}
