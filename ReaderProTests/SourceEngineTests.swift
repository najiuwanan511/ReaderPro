import XCTest
import UIKit
@testable import ReaderPro

final class SourceEngineTests: XCTestCase {
    let base = SourceTestFixtures.base

    func testHTTPDiscoveryDetailDirectoryAndCompleteContent() async throws {
        let source = SourceTestFixtures.html()
        let books = try await source.discover()
        XCTAssertEqual(books.count, 1)
        let sample = try XCTUnwrap(books.first)
        XCTAssertEqual(sample.title, "测试小说")
        XCTAssertEqual(sample.url, base + "/book/1/") // redirected page's relative URL
        XCTAssertEqual(sample.author, "测试作者")
        let detail = try await source.fetchBookInfo(book: sample)
        XCTAssertEqual(detail.tocUrl, base + "/book/1/toc/1")
        let chapters = try await source.fetchChapters(book: detail)
        XCTAssertEqual(chapters.map(\.title), (1...6).map { "第\($0)章" })
        XCTAssertEqual(Set(chapters.compactMap(\.url)).count, 6)
        for chapter in [chapters[0], chapters[3], chapters[5]] {
            let text = try await source.fetchChapterContent(chapter)
            for page in 1...7 { XCTAssertTrue(text.contains("第\(page)段"), text) }
            XCTAssertEqual(text.components(separatedBy: "这是完整正文").count - 1, 7)
        }
    }

    func testPOSTSearchCarriesSourceHeadersAndEncodedKeyword() async throws {
        let results = try await SourceTestFixtures.html().search(key: "测试")
        XCTAssertEqual(results.first?.title, "测试小说")
        let req = try SourceHTTP.request(#"/search,{"method":"POST","body":{"key":"{{key}}","page":{{page}}},"headers":{"X-Test":"yes"}}"#,
                                         base: base, key: "a&=中文", page: 3)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Test"), "yes")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(body["page"] as? Int, 3)
        XCTAssertEqual(body["key"] as? String, "a%26%3D%E4%B8%AD%E6%96%87")
        XCTAssertEqual(SourceHTTP.options(base + "/a,b?q=1,2").url, base + "/a,b?q=1,2")
    }

    func testJSONEndToEnd() async throws {
        let source = SourceTestFixtures.json()
        let results = try await source.search(key: "测试")
        let book = try await source.fetchBookInfo(book: XCTUnwrap(results.first))
        let chapters = try await source.fetchChapters(book: book)
        XCTAssertEqual(chapters.count, 1)
        let content = try await source.fetchChapterContent(XCTUnwrap(chapters.first))
        XCTAssertEqual(content, "JSON首章正文")
    }

    func testHTTPFailuresNeverBecomeBooksOrChapterText() async throws {
        for endpoint in ["/denied", "/empty"] {
            do {
                _ = try await SourceHTTP.load(SourceHTTP.request(endpoint, base: base), stage: "发现")
                XCTFail("Must fail: \(endpoint)")
            } catch {
                XCTAssertTrue(sourceErrorMessage(error).contains(endpoint == "/denied" ? "403" : "空内容"))
            }
        }
        var source = SourceTestFixtures.html()
        source.exploreUrl = "分类::/navigation"
        do { _ = try await source.discover(); XCTFail("Navigation links are not books") }
        catch { XCTAssertTrue(sourceErrorMessage(error).contains("未匹配")) }
        let book = SourceBook(title: "测试", url: base + "/navigation", sourceName: "", sourceUrl: base)
        source.ruleBookInfo.tocUrl = ""
        do { _ = try await source.fetchChapters(book: book); XCTFail("Navigation links are not chapters") }
        catch { XCTAssertTrue(sourceErrorMessage(error).contains("章节规则")) }
        let chapter = BookChapter(title: "测试", text: "__URL__" + base + "/navigation")
        do { _ = try await source.fetchChapterContent(chapter); XCTFail("Navigation is not content") }
        catch { XCTAssertTrue(sourceErrorMessage(error).contains("正文规则")) }
    }

    func testWebViewDependencyIsAnExplicitCompatibilityFailure() throws {
        XCTAssertThrowsError(try SourceHTTP.request(#"/x,{"webView":true}"#, base: base)) {
            XCTAssertTrue(sourceErrorMessage($0).contains("WebView"))
        }
    }

    func testRealDOMCSSXPathAndLegadoSelectors() {
        let html = #"<section><ul><li class="item"><a href="a">一</a></li><li class="item"><a href="b">二</a></li></ul><p id="info">直接<span>嵌套</span>尾部</p></section>"#
        XCTAssertEqual(applyRule(html, "@css:ul > li:nth-child(2) a@href", base: base), ["b"])
        XCTAssertEqual(applyRule(html, "@css:li + li a@text", base: base), ["二"])
        XCTAssertEqual(applyRule(html, "class.item.1@tag.a@text", base: base), ["二"])
        XCTAssertEqual(applyRule(html, "@xpath://li[2]/a/@href", base: base), ["b"])
        XCTAssertEqual(applyRule(html, "@xpath:string(//li[2]/a)", base: base), ["二"])
        XCTAssertEqual(applyRule(html, "id.info@ownText", base: base), ["直接\n尾部"])
        XCTAssertEqual(applyRule("广告正文广告", "##广告##", base: base), ["正文"])
        XCTAssertEqual(applyRule(html, "id.missing@text||id.info@text", base: base), ["直接嵌套尾部"])
    }

    func testJSArraysLibrariesExceptionsAndCategories() async throws {
        var source = SourceTestFixtures.html()
        source.jsLib = "function categoryTitle() { return '脚本分类'; }"
        source.exploreUrl = #"@js:[{title:categoryTitle(),url:'/redirect'}]"#
        let books = try await source.discover()
        XCTAssertEqual(books.count, 1)
        source.exploreUrl = "@js:throw new Error('测试脚本异常')"
        do { _ = try await source.discover(); XCTFail("JS exception cannot pass validation") }
        catch { XCTAssertTrue(sourceErrorMessage(error).contains("脚本")) }
        let encoded = LegadoJS.run("java.encodeURI('中&=')", input: "", baseUrl: base, sourceKey: "", sourceUrl: base)
        XCTAssertEqual(encoded, "%E4%B8%AD%26%3D")
        XCTAssertEqual(LegadoJS.run("''", input: "not a result", baseUrl: base, sourceKey: "", sourceUrl: base), "")
        source.exploreUrl = "甲::/a&&乙::/b"
        XCTAssertEqual(source.exploreCategories().map(\.title), ["甲", "乙"])
    }

    func testImport1500SourcesWithMixedValuesAndNestedEnvelope() throws {
        let entries: [[String: Any]] = (0..<1500).map { i in
            ["bookSourceName": "源\(i)", "bookSourceUrl": "https://source\(i).test", "enabled": i % 2,
             "bookSourceType": "0", "header": ["User-Agent": "fixture"], "jsLib": "var x=1;",
             "ruleSearch": ["name": NSNull(), "checkKeyWord": "测试", "bookList": "class.item"]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["data": ["items": entries + [entries[0]]]])
        let result = importSourcesDetailed(try XCTUnwrap(String(data: data, encoding: .utf8)))
        XCTAssertEqual(result.sources.count, 1500)
        XCTAssertTrue(result.sources.allSatisfy(\.enabled))
        for index in [0, 749, 1499] {
            XCTAssertEqual(result.sources[index].bookSourceName, "源\(index)")
            XCTAssertEqual(result.sources[index].requestHeaders["User-Agent"], "fixture")
            XCTAssertEqual(result.sources[index].ruleSearch.checkKeyWord, "测试")
        }
        let roundtrip = try JSONDecoder().decode([LegadoSource].self, from: JSONEncoder().encode(result.sources))
        XCTAssertEqual(roundtrip, result.sources)
        let wrapped = try JSONSerialization.data(withJSONObject: ["data": String(data: data, encoding: .utf8)!])
        XCTAssertEqual(importSourcesDetailed(String(data: wrapped, encoding: .utf8)!).sources.count, 1500)
    }

    func testImportPreservesHTMLRuleEntitiesAndSkipsOnlyMalformedEntries() throws {
        let text = #"[{"bookSourceName":"好源","bookSourceUrl":"https://a.test","ruleContent":{"content":"@js:result.replace(/&quot;/g,'x')"}},null,7,{"bookSourceName":null,"bookSourceUrl":null},{"bookSourceName":"第二源","bookSourceUrl":"https://b.test"}]"#
        let result = importSourcesDetailed(text)
        XCTAssertEqual(result.sources.count, 2)
        XCTAssertTrue(result.sources[0].ruleContent.content.contains("&quot;"))
        XCTAssertEqual(result.skipped, 1)
        let escaped = "<html><pre>" + text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;") + "</pre></html>"
        XCTAssertEqual(importSourcesDetailed(escaped).sources.count, 2)
    }

    func testValidationChecksReadingChainAndDistinguishesNoResults() async {
        let passed = await SourceValidation.run(SourceTestFixtures.html(), keyword: "不存在")
        XCTAssertEqual(passed.status, .passed, passed.summary)
        XCTAssertEqual(passed.steps.map(\.stage), ["搜索", "发现", "详情", "目录", "正文"])
        var source = SourceTestFixtures.html(); source.searchUrl = "/denied"; source.exploreUrl = ""
        let failed = await SourceValidation.run(source, keyword: "测试")
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.searchableText.contains("403"))
        source = SourceTestFixtures.json(); source.searchUrl = "/json/noresults"
        let partial = await SourceValidation.run(source, keyword: "测试")
        XCTAssertEqual(partial.status, .partial)
        XCTAssertFalse(SourceStatusFilter.passed.matches(report: partial, checking: false))
        XCTAssertTrue(SourceStatusFilter.partial.matches(report: partial, checking: false))
        XCTAssertTrue(SourceStatusFilter.failed.matches(report: failed, checking: false))
        XCTAssertTrue(SourceStatusFilter.unchecked.matches(report: nil, checking: false))
        XCTAssertTrue(SourceStatusFilter.checking.matches(report: passed, checking: true))
    }

    @MainActor func testReportPersistenceAndRuleChangesInvalidateResult() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        var source = SourceTestFixtures.html()
        let store = SourceValidationStore(url: url)
        let report = SourceValidationReport(id: source.id, fingerprint: SourceValidation.fingerprint(source), checkedAt: Date(), keyword: "测试", status: .failed,
                                            steps: [.init(stage: "目录", passed: false, detail: "HTTP 403")])
        store.set(report); store.save()
        XCTAssertEqual(store.persistenceError, "")
        let reloaded = SourceValidationStore(url: url)
        XCTAssertEqual(reloaded.report(for: source), report)
        source.enabled = false; source.bookSourceGroup = "分组"
        XCTAssertNotNil(reloaded.report(for: source))
        source.header = "{}"
        XCTAssertNil(reloaded.report(for: source))
    }

    func testRelativeURLsAndOldChapterMigration() throws {
        XCTAssertEqual(resolveUrl("../chapter/1", base: base + "/book/1/toc/1"), base + "/book/1/chapter/1")
        XCTAssertEqual(resolveUrl("", base: base), "")
        XCTAssertEqual(resolveUrl("#", base: base), "")
        let data = Data(#"{"id":"old","title":"旧章节","text":"__URL__https://example.test/1"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(BookChapter.self, from: data).url, "https://example.test/1")
    }

    @MainActor func testPaginationFitsStandalonePagesWithoutLosingUnicode() throws {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8; paragraph.paragraphSpacing = 10; paragraph.firstLineHeadIndent = 38
        paragraph.lineBreakMode = .byCharWrapping
        let text = String(repeating: "这是分页测试。👨‍👩‍👧‍👦 e\u{301}，长段落需要逐页完整显示而不能越过底部。", count: 24)
            + "\n" + String(repeating: "下一段落：中文English混排。\n", count: 45)
        for fontSize: CGFloat in [16, 23, 32] {
            let attributed = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraph])
            for size in [CGSize(width: 285, height: 420), CGSize(width: 360, height: 620)] {
                let pages = Paginator.paginate(attributed, pageSize: size)
                XCTAssertGreaterThan(pages.count, 1)
                var offset = 0; var recovered = ""
                for range in pages {
                    XCTAssertEqual(range.location, offset)
                    let page = attributed.attributedSubstring(from: range)
                    recovered += page.string; offset = NSMaxRange(range)
                    let storage = NSTextStorage(attributedString: page)
                    let layout = NSLayoutManager(); layout.usesFontLeading = true; storage.addLayoutManager(layout)
                    let container = NSTextContainer(size: size); container.lineFragmentPadding = 0; container.lineBreakMode = .byCharWrapping
                    layout.addTextContainer(container); layout.ensureLayout(for: container)
                    let visible = layout.characterRange(forGlyphRange: layout.glyphRange(for: container), actualGlyphRange: nil)
                    XCTAssertEqual(visible.length, page.length, "A page contains hidden text")
                    XCTAssertLessThanOrEqual(layout.usedRect(for: container).maxY, size.height + 0.5)
                    XCTAssertFalse(page.string.utf16.first.map { (0xDC00...0xDFFF).contains($0) } ?? false)
                }
                XCTAssertEqual(offset, attributed.length)
                XCTAssertEqual(recovered, text)
            }
        }
    }
}
