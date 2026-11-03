import XCTest
import UIKit
@testable import ReaderPro

private actor SpeechPrefetchTestState {
    var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

final class RuleManagementParityTests: XCTestCase {
    func testLegadoAppLinksPreserveNestedQueryAndRecognizeLegacySchemes() throws {
        let source = "https://rules.test/list?group=甲&token=a+b%25#requestWithoutUA"
        var components = URLComponents(string: "legado://import/bookSource")!
        components.queryItems = [URLQueryItem(name: "src", value: source)]
        let parsed = try LegadoAppLink.parse(XCTUnwrap(components.url))
        XCTAssertEqual(parsed.kind, .bookSource); XCTAssertEqual(parsed.source, source)
        for (url, kind) in [
            ("yuedu://rsssource/importonline?src=https%3A%2F%2Ftest.invalid%2Frss", LegadoAppLink.Kind.rssSource),
            ("legado://replace/importonline?src=https%3A%2F%2Ftest.invalid%2Frules", .replaceRule),
            ("legado://import/httpTTS?src=inline", .httpTTS),
            ("legado://import/addToBookshelf?src=https%3A%2F%2Fbook.test%2F1", .addToBookshelf)
        ] { XCTAssertEqual(try LegadoAppLink.parse(XCTUnwrap(URL(string: url))).kind, kind) }
        XCTAssertThrowsError(try LegadoAppLink.parse(URL(string: "legado://import/bookSource")!))
        XCTAssertThrowsError(try LegadoAppLink.parse(URL(string: "legado://import/bookSource?src=%20")!))
        XCTAssertFalse(LegadoAppLink.accepts(URL(string: "https://import/bookSource?src=a")!))
        XCTAssertThrowsError(try LegadoAppLink.parse(URL(string: "legado://import/readConfig?src=a")!))
    }

    func testAppLinkImportPreviewKeepsRequestedSourceType() throws {
        let raw = #"[{"bookSourceName":"书源","bookSourceUrl":"https://book.test"},{"sourceName":"订阅","sourceUrl":"https://rss.test","ruleArticles":".item"}]"#
        XCTAssertEqual(try LegadoLinkDocument.decode(Data(raw.utf8), kind: .bookSource).names, ["书源"])
        XCTAssertEqual(try LegadoLinkDocument.decode(Data(raw.utf8), kind: .rssSource).names, ["订阅"])
        XCTAssertEqual(try LegadoLinkDocument.decode(Data(raw.utf8), kind: .automatic).names, ["书源", "订阅"])
        let bookOnly = #"{"bookSourceName":"书源","bookSourceUrl":"https://book.test"}"#
        XCTAssertThrowsError(try LegadoLinkDocument.decode(Data(bookOnly.utf8), kind: .rssSource))
    }

    func testAppLinkAutomaticDetectionValidatesRulePayloads() throws {
        for (raw, name) in [
            (#"{"name":"字典","urlRule":"https://dict.test/{{key}}"}"#, "字典"),
            (#"{"id":42,"name":"目录","rule":"^第.*章"}"#, "目录"),
            (#"{"id":43,"name":"朗读","url":"https://tts.test/{{speakText}}"}"#, "朗读"),
            (#"{"id":44,"name":"替换","pattern":"旧字","replacement":"新字"}"#, "替换")
        ] { XCTAssertEqual(try LegadoLinkDocument.decode(Data(raw.utf8), kind: .automatic).names, [name]) }
        XCTAssertThrowsError(try LegadoLinkDocument.decode(Data("[]".utf8), kind: .textTocRule))
        XCTAssertThrowsError(try LegadoLinkDocument.decode(Data(#"{"name":"错误","rule":"["}"#.utf8), kind: .textTocRule))
        XCTAssertThrowsError(try LegadoLinkDocument.decode(Data(#"{"name":"错误"}"#.utf8), kind: .dictRule))
    }

    @MainActor func testAppLinkPreviewDoesNotSaveUntilAppliedAndMergesRuleIdentity() async throws {
        let suite = "ReaderPro.AppLinkTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!, library = ReaderRuleLibrary(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let raw = #"[{"id":7,"name":"初始","rule":"^第.*章"}]"#
        let preview = try LegadoLinkDocument.decode(Data(raw.utf8), kind: .textTocRule)
        XCTAssertTrue(library.txtRules.isEmpty)
        let store = BookStore()
        _ = try await preview.apply(store: store, library: library)
        _ = try await LegadoLinkDocument.decode(Data(#"{"id":7,"name":"更新","rule":"^卷"}"#.utf8), kind: .textTocRule).apply(store: store, library: library)
        XCTAssertEqual(library.txtRules.count, 1); XCTAssertEqual(library.txtRules[0].name, "更新")
        XCTAssertEqual(ReaderRuleLibrary(defaults: defaults).txtRules[0].rule, "^卷")
    }

    @MainActor func testScriptOpenURLRoutesImportWithoutStartingVerificationWebView() async throws {
        let event = expectation(description: "App import route")
        let observer = NotificationCenter.default.addObserver(forName: .sourceOpenAppURL, object: nil, queue: .main) { value in
            XCTAssertEqual(value.object as? String, "legado://import/bookSource?src=https%3A%2F%2Frules.test%2Flist")
            event.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let source = SourceTestFixtures.login()
        try await Task.detached {
            try await source.withRules {
                _ = LegadoJS.run("java.openUrl('legado://import/bookSource?src=https%3A%2F%2Frules.test%2Flist')", input: "", baseUrl: source.bookSourceUrl, sourceKey: "", sourceUrl: source.bookSourceUrl)
                try LegadoJSCtx.failures?.check()
            }
        }.value
        await fulfillment(of: [event], timeout: 3)
    }

    @MainActor func testPurchaseRefreshPreservesPositionAndInvalidatesOnlyPurchasedText() async throws {
        let store = BookStore(), oldBooks = store.books, oldSources = store.sources
        defer { store.books = oldBooks; store.sources = oldSources; store.save() }
        var source = LegadoSource(); source.bookSourceUrl = "http://127.0.0.1:8765"; source.bookSourceName = "购买刷新样例"
        source.ruleToc = try JSONDecoder().decode(LegadoSource.RuleSet.self, from: Data(#"{"chapterList":"$.chapters[*]","chapterName":"$.title","chapterUrl":"$.url","isVolume":"$.volume","isVip":"$.vip","isPay":"$.paid"}"#.utf8))
        store.sources.append(source)
        var book = LocalBook(title: "付费书", sourceName: source.bookSourceName, sourceUrl: source.bookSourceUrl, fileName: "purchase.web", kind: "web")
        book.bookUrl = source.bookSourceUrl + "/parity/book/1"; book.tocUrl = source.bookSourceUrl + "/parity/toc"
        book.chapters = try await source.fetchChapters(book: book.sourceBook)
        book.chapters[1].text = "旧试读内容"; book.chapters[2].text = "已下载下一章"; book.chapterIndex = 1; book.charOffset = 25
        store.updateBook(book)
        try await store.refreshPurchasedChapter(bookID: book.id, chapterURL: book.chapters[1].url)
        let refreshed = try XCTUnwrap(store.books.first { $0.id == book.id })
        XCTAssertTrue(refreshed.chapters[1].text.hasPrefix("__URL__")); XCTAssertEqual(refreshed.chapters[2].text, "已下载下一章")
        XCTAssertEqual(refreshed.chapterIndex, 1); XCTAssertEqual(refreshed.charOffset, 25); XCTAssertTrue(refreshed.chapters[2].isPay)
    }

    @MainActor func testMangaCacheClearRemovesBookIDDirectoryAndParsedImageList() async throws {
        let store = BookStore(), original = store.books
        var book = LocalBook(title: "漫画缓存样例", fileName: "comic.web", kind: "comic")
        book.chapters = [BookChapter(title: "第一话", text: "", imageUrls: ["https://cache.test/old.jpg"], url: "https://cache.test/chapter/1")]
        let directory = BookStore.filesDir.appendingPathComponent(book.id).appendingPathComponent("mangaCache")
        defer { store.books = original; store.saveBooks(); try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: directory.appendingPathComponent("cached.img"))
        store.updateBook(book); await store.clearChapterCache(bookID: book.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(store.books.first { $0.id == book.id }?.chapters.first?.imageUrls.isEmpty == true)
    }

    func testRemoteLibraryBrowsesDownloadsUploadsAndDeletesWithAuthentication() async throws {
        let client = try RemoteLibraryClient(address: "http://127.0.0.1:8765/remote-library/", username: "reader", password: "secret")
        let entries = try await client.list(client.root)
        XCTAssertEqual(entries.map(\.name), ["sub", "Book.txt"])
        let bookEntry = try XCTUnwrap(entries.first { !$0.directory })
        guard case .book(let book) = try await client.download(bookEntry, txtRules: []) else { return XCTFail("Must parse downloaded TXT") }
        defer { try? FileManager.default.removeItem(at: BookStore.filesDir.appendingPathComponent(book.fileName)) }
        XCTAssertTrue(book.chapters.map(\.text).joined().contains("远程书库正文"))
        let name = UUID().uuidString + ".txt", bytes = Data("上传正文".utf8)
        try await client.upload(bytes, name: name, folder: client.root)
        let entry = RemoteLibraryEntry(url: client.root.appendingPathComponent(name), name: name, directory: false, bytes: Int64(bytes.count))
        let (downloaded, response) = try await URLSession.shared.data(for: client.request(entry.url, method: "GET"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200); XCTAssertEqual(downloaded, bytes)
        try await client.delete(entry)
        let (_, deleted) = try await URLSession.shared.data(for: client.request(entry.url, method: "GET"))
        XCTAssertEqual((deleted as? HTTPURLResponse)?.statusCode, 404)
        let anonymous = try RemoteLibraryClient(address: client.root.absoluteString)
        do { _ = try await anonymous.list(anonymous.root); XCTFail("Anonymous requests must be denied") }
        catch { XCTAssertTrue(sourceErrorMessage(error).contains("401")) }
    }

    func testRemoteLibraryRejectsOutsideRootAndFailedDAVProperties() throws {
        let client = try RemoteLibraryClient(address: "https://dav.test/books/")
        XCTAssertFalse(client.contains(URL(string: "https://dav.test.evil/books/a.txt")!))
        XCTAssertFalse(client.contains(URL(string: "https://dav.test/books2/a.txt")!))
        XCTAssertFalse(client.contains(URL(string: "https://dav.test/books/../secret/a.txt")!))
        XCTAssertFalse(client.contains(URL(string: "http://dav.test/books/a.txt")!))
        let xml = #"<d:multistatus xmlns:d="DAV:"><d:response><d:href>https://evil.test/book.txt</d:href></d:response><d:response><d:href>/books/one.txt</d:href><d:propstat><d:prop><d:displayname>正确.txt</d:displayname></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat><d:propstat><d:prop><d:displayname>错误.txt</d:displayname></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response></d:multistatus>"#
        XCTAssertEqual(try client.parse(Data(xml.utf8), folder: client.root).map(\.name), ["正确.txt"])
        XCTAssertThrowsError(try client.request(URL(string: "https://evil.test/book.txt")!, method: "GET"))
    }

    func testShelfListsAcceptAndroidNullsAndExportPortableNamesAndOnlineAddresses() throws {
        let decoded = try ShelfTransfer.decode(Data(#"[{"name":"书名","author":null,"intro":null},{"name":""}]"#.utf8))
        XCTAssertEqual(decoded.count, 1); XCTAssertEqual(decoded[0].author, "")
        var local = LocalBook(title: "本地书", author: "作者", fileName: "private.txt", kind: "txt")
        local.bookUrl = "/private/path/private.txt"
        var web = LocalBook(title: "在线书", fileName: "a.web", kind: "web")
        web.sourceUrl = "https://books.test"; web.bookUrl = "https://books.test/1"
        let exported = try ShelfTransfer.decode(ShelfTransfer.encode([local, web]))
        XCTAssertTrue(exported[0].bookUrl.isEmpty); XCTAssertEqual(exported[1].bookUrl, web.bookUrl)
        XCTAssertEqual(exported.map(\.name), ["本地书", "在线书"])
    }

    func testBookURLMatchingUsesExactHostExplicitOriginAndFullPattern() {
        var domain = LegadoSource(); domain.bookSourceUrl = "https://books.test"
        var other = LegadoSource(); other.bookSourceUrl = "https://rules.test"; other.bookUrlPattern = #"https://mirror\.test/book/\d+"#
        XCTAssertEqual(ShelfTransfer.matchingSources(for: "https://books.test/book/1", sources: [domain,other]).map(\.id), [domain.id])
        XCTAssertTrue(ShelfTransfer.matchingSources(for: "https://books.test.evil/book/1", sources: [domain,other]).isEmpty)
        XCTAssertEqual(ShelfTransfer.matchingSources(for: "https://mirror.test/book/1", sources: [domain,other]).map(\.id), [other.id])
        XCTAssertTrue(ShelfTransfer.matchingSources(for: "https://mirror.test/book/1/extra", sources: [domain,other]).isEmpty)
        XCTAssertEqual(ShelfTransfer.matchingSources(for: #"https://books.test/book/1,{"origin":"https://rules.test"}"#, sources: [domain,other]).map(\.id), [other.id])
        other.enabled = false
        XCTAssertTrue(ShelfTransfer.matchingSources(for: "https://mirror.test/book/1", sources: [domain,other]).isEmpty)
    }

    func testAddBookURLAndAndroidListSearchFetchActualMetadataAndDirectory() async throws {
        var source = LegadoSource(); source.bookSourceUrl = "http://127.0.0.1:8765"; source.bookSourceName = "清单样例"
        source.searchUrl = "/parity/search?page={{page}}"
        source.ruleSearch.bookList = "$.books[*]"; source.ruleSearch.name = "$.title"; source.ruleSearch.author = "$.author"; source.ruleSearch.bookUrl = "$.url"
        source.ruleBookInfo.name = "$.title"; source.ruleBookInfo.author = "$.author"; source.ruleBookInfo.tocUrl = "$.toc"
        source.ruleToc = try JSONDecoder().decode(LegadoSource.RuleSet.self, from: Data(#"{"chapterList":"$.chapters[*]","chapterName":"$.title","chapterUrl":"$.url","isVolume":"$.volume"}"#.utf8))
        let result = try await ShelfTransfer.resolveURL(source.bookSourceUrl + "/parity/book/1", sources: [source])
        let book = try await ShelfTransfer.makeBook(source: result.0, info: result.1)
        XCTAssertEqual(book.title, "分页小说1"); XCTAssertEqual(book.author, "作者"); XCTAssertEqual(book.chapters.count, 3)
        XCTAssertEqual(book.bookUrl, source.bookSourceUrl + "/parity/book/1")
        let matched = try await ShelfTransfer.preciseSearch(ShelfListEntry(name: "分页小说1", author: "作者"), sources: [source])
        XCTAssertEqual(matched.1.url, book.bookUrl)
        do {
            _ = try await ShelfTransfer.preciseSearch(ShelfListEntry(name: "分页小说1", author: "另一个作者"), sources: [source])
            XCTFail("Must not import an unrelated author's book")
        } catch { XCTAssertTrue(sourceErrorMessage(error).contains("同名同作者")) }
    }

    func testReadingStatisticsCarryShortSessionsAndSplitAtMidnight() throws {
        let suite = "ReadingStatistics." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let stats = ReadingStatistics(defaults: defaults), start = Date(timeIntervalSince1970: 86380)
        XCTAssertEqual(stats.record(bookID: "book", title: "书", from: start, to: start.addingTimeInterval(40), calendar: calendar), 0)
        XCTAssertEqual(stats.entries.map(\.seconds), [20,20])
        let restored = ReadingStatistics(defaults: defaults)
        XCTAssertEqual(restored.record(bookID: "book", title: "书", from: start.addingTimeInterval(100), to: start.addingTimeInterval(125), calendar: calendar), 1)
        XCTAssertEqual(restored.entries.reduce(0) { $0 + $1.seconds }, 65)
    }

    func testReaderTapRegionsUseIndependentRowsAndColumnsWithPersistedActions() {
        let suite = "TapRegions." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let size = CGSize(width: 300, height: 600)
        XCTAssertEqual(ReaderInteraction.action(at: CGPoint(x: 10,y: 10), size: size, defaults: defaults), .previous)
        XCTAssertEqual(ReaderInteraction.action(at: CGPoint(x: 150,y: 300), size: size, defaults: defaults), .menu)
        defaults.set(ReaderTapAction.bookmark.rawValue, forKey: ReaderInteraction.key(2,2))
        XCTAssertEqual(ReaderInteraction.action(at: CGPoint(x: 290,y: 590), size: size, defaults: defaults), .bookmark)
        XCTAssertEqual(ReaderInteraction.action(at: CGPoint(x: 290,y: 10), size: size, defaults: defaults), .next)
    }

    @MainActor func testPendingRuleUpdatesSurviveRelaunchAndUnchangedRulesAreNotOfferedAgain() async throws {
        let name = "RuleUpdate." + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let store = BookStore(), original = store.sources
        defer { defaults.removePersistentDomain(forName: name); store.sources = original; store.save() }
        store.sources.removeAll { $0.bookSourceUrl == "https://rule-update-fixture.test" }
        var subscription = RuleSubscription(); subscription.url = "http://127.0.0.1:8765/parity/rule-sub"
        let first = RuleSubscriptionStore(defaults: defaults); first.subscriptions = [subscription]
        await first.update([subscription], store: store, manual: false)
        XCTAssertEqual(first.pending[subscription.id], 1)
        XCTAssertFalse(store.sources.contains(where: { $0.bookSourceUrl == "https://rule-update-fixture.test" }))
        let relaunched = RuleSubscriptionStore(defaults: defaults)
        XCTAssertEqual(relaunched.pending[subscription.id], 1)
        relaunched.applyPending(subscription.id, store: store)
        XCTAssertTrue(store.sources.contains(where: { $0.bookSourceUrl == "https://rule-update-fixture.test" }))
        await relaunched.update([subscription], store: store, manual: false)
        XCTAssertNil(relaunched.pending[subscription.id]); XCTAssertEqual(relaunched.status[subscription.id], "规则没有变化")
    }

    func testWebUploadParserWaitsForCompleteBinaryBodyAndRejectsAmbiguousLengths() throws {
        let head = Data("POST /file?name=book.txt&key=secret HTTP/1.1\r\nContent-Length: 4\r\n\r\n".utf8)
        XCTAssertNil(try LocalWebRequest.parse(head + Data([0,255])))
        let request = try XCTUnwrap(LocalWebRequest.parse(head + Data([0,255,13,10])))
        XCTAssertEqual(request.body, Data([0,255,13,10])); XCTAssertEqual(request.value("name"), "book.txt")
        for invalid in ["Content-Length: -1", "Content-Length: 4\r\nContent-Length: 4", "Transfer-Encoding: chunked"] {
            XCTAssertThrowsError(try LocalWebRequest.parse(Data(("POST /file HTTP/1.1\r\n" + invalid + "\r\n\r\n").utf8)))
        }
    }

    @MainActor func testLocalWebServiceAuthenticatesAndImportsActualUploadedBook() async throws {
        let store = BookStore(), original = store.books, service = LocalWebService()
        service.start(store: store)
        defer {
            service.stop()
            for book in store.books where !original.contains(where: { $0.id == book.id }) { try? FileManager.default.removeItem(at: BookStore.filesDir.appendingPathComponent(book.fileName)) }
            store.books = original; store.saveBooks()
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in service.running }, object: nil)
        await fulfillment(of: [ready], timeout: 10)
        let base = try XCTUnwrap(service.loopbackAddress)
        var anonymous = try XCTUnwrap(URLComponents(url: base, resolvingAgainstBaseURL: false)); anonymous.query = nil
        let (_, denied) = try await URLSession.shared.data(from: try XCTUnwrap(anonymous.url))
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 403)
        var components = try XCTUnwrap(URLComponents(url: base, resolvingAgainstBaseURL: false))
        components.path = "/file"; components.queryItems?.append(URLQueryItem(name: "name", value: "Web上传.txt"))
        var upload = URLRequest(url: try XCTUnwrap(components.url)); upload.httpMethod = "POST"; upload.httpBody = Data("第一章 开篇\nWeb上传正文".utf8)
        let (body, response) = try await URLSession.shared.data(for: upload)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: body, as: UTF8.self))
        XCTAssertTrue(store.books.contains(where: { $0.title == "Web上传" && $0.chapters.first?.text.contains("Web上传正文") == true }))
    }

    private func fontFixture(code: Int) -> Data {
        func number(_ value: Int, _ width: Int) -> Data {
            Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        var head = Data(repeating: 0, count: 54); head[51] = 1
        var glyph = number(1,2); glyph += Data(repeating: 0, count: 8)
        glyph += number(1,2); glyph += number(0,2); glyph += Data([1,1])
        for value in [10,20,30,40] { glyph += number(value,2) }
        var cmap = Data()
        for value in [0,1,3,10] { cmap += number(value,2) }
        cmap += number(12,4); cmap += number(12,2); cmap += number(0,2)
        for value in [28,0,1,code,code,1] { cmap += number(value,4) }
        let tables: [(String,Data)] = [("head",head),("maxp",number(0x10000,4)+number(2,2)),("loca",number(0,4)+number(0,4)+number(glyph.count,4)),("glyf",glyph),("cmap",cmap)]
        var output = number(0x10000,4) + number(tables.count,2) + Data(repeating:0,count:6)
        var payload = Data(), offset = 12 + tables.count * 16
        for (name, data) in tables {
            output += Data(name.utf8); output += number(0,4); output += number(offset,4); output += number(data.count,4)
            payload += data; offset += data.count
        }
        return output + payload
    }

    func testTrueTypeFontReplacementMatchesContoursAcrossRemappedUnicodeAndFiltersUnknowns() async throws {
        let wrong = fontFixture(code: 0xe001), correct = fontFixture(code: 0x1f600)
        let font = try SourceFont(wrong)
        XCTAssertEqual(font.ids[0xe001], 1); XCTAssertEqual(font.outlines[0xe001], "10,30|20,40")
        XCTAssertEqual(try SourceFont(correct).outlines[0x1f600], font.outlines[0xe001])
        XCTAssertThrowsError(try SourceFont(Data(wrong.prefix(30))))
        let result = await Task.detached {
            LegadoJS.run("var wrong=java.queryBase64TTF('\(wrong.base64EncodedString())'),correct=java.queryTTF('\(correct.base64EncodedString())');[java.replaceFont('\\ue001 X',wrong,correct),java.replaceFont('\\ue001 X',wrong,correct,true)].join('|')", input: "", baseUrl: "https://font.test", sourceKey: "", sourceUrl: "https://font.test")
        }.value
        XCTAssertEqual(result, "😀 X|😀 ")
    }

    func testScriptFileDownloadUnzipAndImportScriptUseSameSandbox() async throws {
        let archive = writeStoredZip([(name: "nested/library.js", data: Data("var localLibrary='可执行';".utf8)), (name: "chapter.txt", data: Data("测试正文".utf8))])
        let hex = archive.map { String(format: "%02x", $0) }.joined()
        var source = LegadoSource(); source.bookSourceUrl = "https://file-bridge.test"
        let output = try await source.withRules {
            let script = "var archive=java.downloadFile('\(hex)','https://files.test/pack.zip,{\"type\":\"zip\"}');var folder=java.unzipFile(archive);eval(java.importScript(folder+'/nested/library.js'));var text=java.readTxtFile(folder+'/chapter.txt');var bytes=java.getZipByteArrayContent('\(hex)','chapter.txt');java.deleteFile(folder);java.deleteFile(archive);[localLibrary,text,bytes.length].join('|')"
            let value = LegadoJS.run(script, input: "", baseUrl: source.bookSourceUrl, sourceKey: "", sourceUrl: source.bookSourceUrl)
            try LegadoJSCtx.failures?.check(); return value
        }
        XCTAssertEqual(output, "可执行|测试正文|12")
    }

    func testArchiveTraversalAndMalformedDeflateAreRejected() throws {
        XCTAssertThrowsError(try SourceFiles.file("../../outside.txt"))
        let archive = writeStoredZip([(name: "../../outside.txt", data: Data([1]))])
        let path = try SourceFiles.write(archive, address: "https://files.test/traversal.zip")
        defer { if let file = try? SourceFiles.file(path) { try? FileManager.default.removeItem(at: file) } }
        XCTAssertThrowsError(try SourceFiles.unzip(path))
        XCTAssertNil(inflate(Data([0xff, 0xff, 0xff])))
        // Raw DEFLATE: one fixed-Huffman block containing "hello".
        let deflate = Data([0xcb,0x48,0xcd,0xc9,0xc9,0x07,0x00])
        XCTAssertEqual(inflate(deflate, limit: 5), Data("hello".utf8))
        XCTAssertNil(inflate(deflate, limit: 4))
    }

    func testFileSourceDownloadRuleImportsReadableOfflineChapters() async throws {
        let source = try JSONDecoder().decode(LegadoSource.self, from: Data(#"{"bookSourceName":"文件源","bookSourceUrl":"http://127.0.0.1:8765","bookSourceType":3,"ruleBookInfo":{"downloadUrls":"$.downloads[*]"}}"#.utf8))
        let book = SourceBook(title: "文件小说", author: "作者", url: "http://127.0.0.1:8765/parity/file-info")
        let addresses = try await source.fileDownloadURLs(book: book)
        XCTAssertEqual(addresses, ["http://127.0.0.1:8765/parity/book.txt"])
        let local = try await source.downloadBookFile(try XCTUnwrap(addresses.first), book: book, txtRules: [])
        defer { try? FileManager.default.removeItem(at: BookStore.filesDir.appendingPathComponent(local.fileName)) }
        XCTAssertEqual(local.kind, "txt"); XCTAssertEqual(local.title, "文件小说"); XCTAssertEqual(local.author, "作者")
        XCTAssertEqual(local.chapters.count, 2); XCTAssertTrue(local.chapters[1].text.contains("离线内容二"))
    }

    func testComicImportKeepsSameNamedImagesInDifferentFoldersAndFilesDoNotOverwrite() throws {
        let archive = writeStoredZip([(name: "a/1.png", data: Data([1,2,3])), (name: "b/1.png", data: Data([4,5,6]))])
        guard case .book(let book) = try BookFileImporter.parse(archive, name: "comic.cbz", txtRules: []) else { return XCTFail("Not a comic") }
        defer {
            try? FileManager.default.removeItem(at: BookStore.filesDir.appendingPathComponent(book.fileName))
            try? FileManager.default.removeItem(at: BookStore.filesDir.appendingPathComponent(book.id))
        }
        XCTAssertEqual(book.imageNames.count, 2); XCTAssertEqual(Set(book.imageNames).count, 2)
        let images = try book.imageNames.map { try Data(contentsOf: BookStore.filesDir.appendingPathComponent(book.id).appendingPathComponent($0)) }
        XCTAssertEqual(images, [Data([1,2,3]), Data([4,5,6])])
        guard case .book(let first) = try BookFileImporter.parse(Data("第1章\n甲".utf8), name: "same.txt", txtRules: []),
              case .book(let second) = try BookFileImporter.parse(Data("第1章\n乙".utf8), name: "same.txt", txtRules: []) else { return XCTFail("Not text") }
        defer {
            try? FileManager.default.removeItem(at: BookStore.filesDir.appendingPathComponent(first.fileName))
            try? FileManager.default.removeItem(at: BookStore.filesDir.appendingPathComponent(second.fileName))
        }
        XCTAssertNotEqual(first.fileName, second.fileName); XCTAssertEqual(first.title, second.title)
        XCTAssertEqual(try String(contentsOf: BookStore.filesDir.appendingPathComponent(first.fileName)), "第1章\n甲")
    }

    func testWebResourceCaptureExecutesScriptAndReturnsResourceInsteadOfScriptResult() async throws {
        var source = LegadoSource(); source.bookSourceUrl = "http://127.0.0.1:8765"
        let output = try await source.withRules {
            let output = LegadoJS.run(#"java.webViewGetSource('<html><body>播放器</body></html>',baseUrl,'fetch("/parity/search?capture=1");"ignored"','.*parity/search[?]capture=1',false,10)"#,
                                      input: "", baseUrl: source.bookSourceUrl, sourceKey: "", sourceUrl: source.bookSourceUrl)
            try LegadoJSCtx.failures?.check(); return output
        }
        XCTAssertEqual(output, "http://127.0.0.1:8765/parity/search?capture=1")
    }

    func testWebNavigationCaptureReturnsMatchingCustomScheme() async throws {
        var source = LegadoSource(); source.bookSourceUrl = "http://127.0.0.1:8765"
        let output = try await source.withRules {
            let output = LegadoJS.run(#"java.webViewGetOverrideUrl('<html><body>跳转</body></html>',baseUrl,'location.href="reader-fixture://video/episode/1"','reader-fixture://video/episode/\\d+',false,0)"#,
                                      input: "", baseUrl: source.bookSourceUrl, sourceKey: "", sourceUrl: source.bookSourceUrl)
            try LegadoJSCtx.failures?.check(); return output
        }
        XCTAssertEqual(output, "reader-fixture://video/episode/1")
    }

    func testBatchCanExplicitlySkipSourceRateLimit() async throws {
        var source = LegadoSource(); source.bookSourceUrl = "http://127.0.0.1:8765"; source.concurrentRate = "1/60000"
        let output = try await source.withRules {
            let json = LegadoJS.run(#"java.ajaxAll(['/parity/search?page=1','/parity/search?page=2'],true).map(function(r){return r.code();}).join(',')"#,
                                    input: "", baseUrl: source.bookSourceUrl, sourceKey: "", sourceUrl: source.bookSourceUrl)
            try LegadoJSCtx.failures?.check(); return json
        }
        XCTAssertEqual(output, "200,200")
    }

    func testHttpTtsExpandsSpeakTextAndSpeedIntoActualAudioRequest() async throws {
        let json = #"{"id":100,"name":"测试朗读","url":"http://127.0.0.1:8765/parity/tts?text={{speakText}}&speed={{speakSpeed}}","contentType":"audio/wav","loginUi":[{"name":"接口","type":"text"}]}"#
        let engine = try JSONDecoder().decode(HttpTTS.self, from: Data(json.utf8))
        XCTAssertTrue(engine.loginUi.contains("接口"))
        let data = try await engine.audio(text: "你好世界", speed: 12)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertGreaterThan(data.count, 1000)
    }

    func testHttpTtsLoginCheckCanRecoverUnauthorizedResponseAndReplaceAudioBytes() async throws {
        var engine = HttpTTS(); engine.name = "登录朗读"; engine.url = "http://127.0.0.1:8765/parity/protected"
        engine.contentType = "audio/(wav|mpeg)"
        engine.loginCheckJs = #"if(result.code()===401){result=java.connect('http://127.0.0.1:8765/parity/tts?text='+encodeURIComponent(speakText)+'&speed='+speakSpeed);} result;"#
        let data = try await engine.audio(text: "你好世界", speed: 12)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        engine.loginCheckJs = "result"
        do { _ = try await engine.audio(text: "你好世界", speed: 12); XCTFail("Unrecovered 401 must fail") }
        catch { XCTAssertTrue(sourceErrorMessage(error).contains("401")) }
    }

    @MainActor func testHttpSpeechPrefetchesOnlyTheNextSegmentAndPlaysInOrder() async throws {
        let nextReady = expectation(description: "Next audio fetched during current playback")
        let state = SpeechPrefetchTestState()
        var played: [String] = []
        var started: [Int] = []
        try await SpeechAudioSequence.run(parts: ["一", "二", "三"], fetch: { text in
            await state.record(text)
            if text == "二" { nextReady.fulfill() }
            return Data(text.utf8)
        }, onStart: { started.append($0) }, play: { data in
            let text = String(decoding: data, as: UTF8.self)
            if text == "一" {
                await self.fulfillment(of: [nextReady], timeout: 5)
                let fetched = await state.values
                XCTAssertEqual(fetched, ["一", "二"])
            }
            played.append(text)
        })
        XCTAssertEqual(played, ["一", "二", "三"])
        XCTAssertEqual(started, [0,1,2])
    }

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

    func testInteractiveCallbacksReceiveLongClickInputAndNullAbsentContext() async throws {
        var source = LegadoSource(); source.bookSourceUrl = "https://events.test"; source.eventListener = true
        source.ruleContent = try JSONDecoder().decode(LegadoSource.RuleSet.self, from: Data(#"{"callBackJs":"[event,result,chapter===null,isLongClick].join('|')"}"#.utf8))
        let book = SourceBook(title: "小说", author: "作者", url: "https://events.test/book")
        let callback = try await source.performBookEvent("longClickAuthor", book: book, input: "作者", longClick: true)
        XCTAssertEqual(callback?.value, "longClickAuthor|作者|true|true")
        source.ruleContent = try JSONDecoder().decode(LegadoSource.RuleSet.self, from: Data(#"{"callBackJs":"[event,book===null,chapter===null,result===null].join('|')"}"#.utf8))
        let refresh = try await source.sourceEventResult("startShelfRefresh")
        XCTAssertEqual(refresh, "startShelfRefresh|true|true|true")
        source.eventListener = false
        let disabled = try await source.performBookEvent("clickAuthor", book: book, input: "作者")
        XCTAssertNil(disabled)
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
