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

    func testContentPaginationStopsAtNextChapterBoundary() async throws {
        var source = SourceTestFixtures.html()
        source.ruleContent.nextContentUrl = "@css:a.next@href||@css:a.next-chapter@href"
        let chapter = BookChapter(id: "first", title: "第一章", text: "__URL__" + base + "/book/1/chapter/1", url: base + "/book/1/chapter/1")
        let text = try await source.fetchChapterContent(chapter, nextChapterUrl: base + "/book/1/chapter/2")
        XCTAssertTrue(text.contains("第1章第7段"))
        XCTAssertFalse(text.contains("第2章"))
        XCTAssertEqual(text.components(separatedBy: "这是完整正文").count - 1, 7)
    }

    func testDirectoryOptionListLoadsEveryPageEvenWhenFirstIsCurrent() async throws {
        var source = SourceTestFixtures.html()
        source.ruleToc.nextTocUrl = "@css:option@value"
        let books = try await source.discover()
        let chapters = try await source.fetchChapters(book: XCTUnwrap(books.first))
        XCTAssertEqual(chapters.map(\.title), (1...6).map { "第\($0)章" })
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

    func testWebViewRunsPageScriptsAndSharesCookies() async throws {
        let request = try SourceHTTP.request("/web-script", base: base)
        let page = try await SourceWebLoader.load(request, script: "document.getElementById('dynamic').textContent")
        XCTAssertEqual(page.text, "网页脚本正文")
        XCTAssertTrue((HTTPCookieStorage.shared.cookies(for: URL(string: base)!) ?? []).contains { $0.name == "wv" && $0.value == "ready" })
        var source = SourceTestFixtures.html()
        source.exploreUrl = #"脚本分类::/web-script,{"webView":true,"webJs":"document.documentElement.outerHTML"}"#
        source.ruleExplore = .init()
        source.ruleExplore.bookList = "#dynamic"
        source.ruleExplore.name = "@js:'网页脚本正文'"
        source.ruleExplore.bookUrl = "@js:'/book/1/'"
        let books = try await source.discover()
        XCTAssertEqual(books.first?.title, "网页脚本正文")
    }

    func testUserProvidedPackImportsEverySourceWithoutLosingRules() async throws {
        let page = try await SourceHTTP.load(SourceHTTP.request("/packs/user", base: base), stage: "实际合集导入")
        let originals = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(page.text.utf8)) as? [[String: Any]])
        let imported = importSourcesDetailed(page.text)
        XCTAssertEqual(imported.sources.count, 1466)
        XCTAssertEqual(imported.skipped, 0)
        XCTAssertEqual(Set(imported.sources.map(\.bookSourceUrl)).count, 1466)
        for source in imported.sources {
            let original = try XCTUnwrap(originals.first { $0["bookSourceUrl"] as? String == source.bookSourceUrl })
            XCTAssertEqual(source.bookSourceName, original["bookSourceName"] as? String)
            XCTAssertEqual(source.searchUrl, original["searchUrl"] as? String ?? "")
            XCTAssertEqual(source.ruleToc.chapterList, (original["ruleToc"] as? [String: Any])?["chapterList"] as? String ?? "")
            XCTAssertEqual(source.ruleContent.content, (original["ruleContent"] as? [String: Any])?["content"] as? String ?? "")
        }
        let first = try XCTUnwrap(imported.sources.first)
        XCTAssertGreaterThan(first.exploreCategories().count, 5)
        await MainActor.run {
            let store = BookStore()
            let previous = store.sources
            defer { store.sources = previous; store.save() }
            store.sources = []
            XCTAssertEqual(store.mergeSources(imported.sources).added, 1466)
            XCTAssertEqual(store.sources.count, 1466)
            XCTAssertEqual(store.mergeSources(imported.sources).updated, 1466)
            XCTAssertEqual(store.sources.count, 1466)
        }
    }

    func testCommonAndroidJSNetworkCookieVariableAndDOMInterfaces() async throws {
        let result = await Task.detached { [base] in
            LegadoJS.run(#"""
            cookie.setCookie(source.getKey(), 'readerpro=ready');
            if(java.ajax(baseUrl+'/bridge-cookie').indexOf('readerpro=ready')<0) throw Error('cookie not sent');
            var post=java.post(baseUrl+'/bridge-post','key=测试',{}).body();
            if(post!=='key=测试') throw Error('post');
            if(java.get(baseUrl+'/bridge-redirect',{}).header('Location')!=='/json/search') throw Error('redirect');
            var connected=java.connect(baseUrl+'/json/search');
            if(connected.code()!==200 || !connected.raw().request().url().endsWith('/json/search')) throw Error('connect');
            java.setContent(connected.body());
            source.setVariable('stored');
            java.put('saved', java.getString('$.data[0].name'));
            if(source.getVariable()!=='stored' || java.get('saved')!=='JSON测试') throw Error('variables');
            var element=org.jsoup.Jsoup.parse('<div><a href="/chapter">章节</a></div>').select('a').first();
            if(element.attr('href')!=='/chapter' || element.text()!=='章节') throw Error('DOM');
            cookie.removeCookie(source.key);
            if(cookie.getCookie(source.key).indexOf('readerpro=ready')>=0) throw Error('cookie clear');
            'bridge passed';
            """#, input: "", baseUrl: base, sourceKey: "测试", sourceUrl: base)
        }.value
        XCTAssertEqual(result, "bridge passed")
        let remote = await Task.detached { [base] in
            LegadoJSCtx.$library.withValue(base + "/bridge-library") {
                LegadoJS.run("remoteCategory()", input: "", baseUrl: base, sourceKey: "", sourceUrl: base)
            }
        }.value
        XCTAssertEqual(remote, "远程分类")
    }

    func testRuleTemplatesRecursiveJSONAndStoredValues() {
        let json = #"{"data":[{"name":"甲","time":0},{"name":"乙"}]}"#
        XCTAssertEqual(applyRule(json, "$..name", base: base), ["甲", "乙"])
        XCTAssertEqual(applyRule(json, "@JSon:$.data[0].name", base: base), ["甲"])
        XCTAssertEqual(applyRule("第十二章·正文", "<js>java.toNumChapter(result)</js>\n##·##|", base: base), ["第12章|正文"])
        XCTAssertEqual(applyRuleFirst(json, "书名：{{$.data[0].name}}，{{java.getString('$.data[1].name')}}", base: base), "书名：甲，乙")
        _ = applyRule(json, #"@put:{"bookID":"$.data[0].name"}"#, base: base)
        XCTAssertEqual(applyRuleFirst(json, "https://example.org/@get:{bookID}", base: base), "https://example.org/甲")
        XCTAssertEqual(LegadoSource.fillSearchTemplate("<js>cookie.removeCookie(source.key); '/search?key={{key}}'</js>", key: "测试", page: 1, sourceUrl: base), "/search?key=%E6%B5%8B%E8%AF%95")
    }

    func testAndroidCryptoUsesKnownAESAndDigestVectors() {
        let value = LegadoJS.run(#"""
        var key=java.hexDecodeToByteArray('2b7e151628aed2a6abf7158809cf4f3c');
        var iv=java.hexDecodeToByteArray('000102030405060708090a0b0c0d0e0f');
        var cipher=java.createSymmetricCrypto('AES/CBC/NoPadding',key,iv);
        var encrypted=cipher.encryptHex(java.hexDecodeToByteArray('6bc1bee22e409f96e93d7e117393172a'));
        if(encrypted!=='7649abac8119b246cee98e9b12e9197d') throw Error('NIST AES CBC vector');
        if(java.digestHex('abc','SHA-256')!=='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') throw Error('SHA256');
        if(java.HMacHex('The quick brown fox jumps over the lazy dog','HmacMD5','key')!=='80070713463e7749b90c2dc24911e275') throw Error('HMAC');
        var padded=java.createSymmetricCrypto('AES/CBC/PKCS7Padding','0123456789abcdef','0123456789abcdef');
        var encoded=padded.encryptBase64('中文加密正文');
        if(padded.decryptStr(encoded)!=='中文加密正文') throw Error('PKCS7');
        String(new Packages.java.lang.String(java.base64DecodeToByteArray('5Lit5paH')));
        """#, input: "", baseUrl: base, sourceKey: "", sourceUrl: base)
        XCTAssertEqual(value, "中文")
    }

    func testChapterScriptsRetainBookAndChapterContextAcrossPersistence() async throws {
        var source = SourceTestFixtures.html()
        let books = try await source.discover()
        let chapters = try await source.fetchChapters(book: XCTUnwrap(books.first))
        let persisted = try JSONDecoder().decode([BookChapter].self, from: JSONEncoder().encode(chapters))
        source.ruleContent.content = "@js:book.name + '|' + chapter.title + '|' + chapter.index"
        source.ruleContent.nextContentUrl = ""
        let text = try await source.fetchChapterContent(persisted[1])
        XCTAssertEqual(text, "测试小说|第2章|1")
    }

    func testGBKSearchEncodesTheKeywordAsTheSourceRequires() throws {
        let request = try SourceHTTP.request(#"/search,{"method":"POST","body":"key={{key}}","charset":"gbk"}"#, base: base, key: "测试")
        XCTAssertEqual(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self), "key=%B2%E2%CA%D4")
    }

    @MainActor func testSearchPublishesBeforeSlowSourceAndCancelsWithoutStaleResults() async throws {
        var slow = SourceTestFixtures.json(); slow.id = "slow"; slow.searchUrl = "/slow-search"
        let fast = SourceTestFixtures.json()
        let controller = SourceSearchController()
        controller.start([slow, fast], key: "测试")
        let deadline = Date().addingTimeInterval(3)
        while controller.results.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(controller.results.isEmpty, "Fast results must appear before the slow source finishes")
        XCTAssertTrue(controller.searching)
        XCTAssertEqual(controller.completed, 1)
        controller.cancel()
        XCTAssertFalse(controller.searching)
        controller.start([fast], key: "新搜索")
        while controller.searching { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(controller.completed, 1)
        XCTAssertEqual(controller.total, 1)
        XCTAssertEqual(controller.keyword, "新搜索")
    }

    func testRealDOMCSSXPathAndLegadoSelectors() {
        let html = #"<section><ul><li class="item"><a href="a">一</a></li><li class="item"><a href="b">二</a></li></ul><p id="info">直接<span>嵌套</span>尾部</p></section>"#
        XCTAssertEqual(applyRule(html, "@css:ul > li:nth-child(2) a@href", base: base), ["b"])
        XCTAssertEqual(applyRule(html, "@css:li + li a@text", base: base), ["二"])
        XCTAssertEqual(applyRule(html, "class.item.1@tag.a@text", base: base), ["二"])
        XCTAssertEqual(applyRule(html, "@xpath://li[2]/a/@href", base: base), ["b"])
        XCTAssertEqual(applyRule(html, "@xpath:string(//li[2]/a)", base: base), ["二"])
        XCTAssertEqual(applyRule(html, "id.info@ownText", base: base), ["直接 尾部"])
        XCTAssertEqual(applyRule(html, "id.info@textNodes", base: base), ["直接\n尾部"])
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
        XCTAssertEqual(LegadoJS.run("[source.getKey(), source.key, key].join('|')", input: "", baseUrl: base, sourceKey: "测试", sourceUrl: base), "\(base)|\(base)|测试")
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

    func testMixedNetworkPackExpandsAllLinksAndReportsFailures() async throws {
        let result = try await importSourcePacksFromURL(base + "/packs/mixed")
        XCTAssertEqual(result.sources.count, 1501)
        XCTAssertEqual(result.sources.first?.bookSourceName, "direct")
        XCTAssertEqual(result.sources.last?.bookSourceName, "linked1499")
        XCTAssertEqual(result.fetchedPacks, 3)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.url, base + "/denied")
        XCTAssertTrue(result.failures.first?.reason.contains("403") == true)
        XCTAssertTrue(result.diagnostics.contains("部分导入"))
        XCTAssertEqual(Set(result.sources.map(\.bookSourceUrl)).count, 1501)
        do { _ = try await importSourcePacksFromURL(base + "/packs/broken"); XCTFail("All failed links cannot be success") }
        catch { XCTAssertTrue(sourceErrorMessage(error).contains("403")) }
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
        source = SourceTestFixtures.html(); source.ruleContent.content = "@js:java.unsupportedDecoder(result)"
        let incompatible = await SourceValidation.run(source, keyword: "测试")
        XCTAssertEqual(incompatible.status, .partial)
        XCTAssertTrue(incompatible.searchableText.contains("脚本兼容性"))
        XCTAssertTrue(incompatible.steps.contains { $0.stage == "搜索" && $0.passed })
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
