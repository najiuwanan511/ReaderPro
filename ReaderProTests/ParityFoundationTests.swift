import XCTest
@testable import ReaderPro

final class ParityFoundationTests: XCTestCase {
    func testSourceArchiveScriptsExtractRealSevenZipAndRarContents() throws {
        for (suffix, name, expected) in [("7z", "chapter.txt", "七压缩正文"), ("rar", "README.md", "# Unrar\n\nA description of this package.\n")] {
            let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "source-files", withExtension: suffix))
            let path = "/archive-test-" + UUID().uuidString + "." + suffix
            let file = try SourceFiles.file(path)
            try FileManager.default.createDirectory(at: SourceFiles.root, withIntermediateDirectories: true)
            try Data(contentsOf: fixture).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let failures = RuleFailures()
            let folder = LegadoJSCtx.$failures.withValue(failures) {
                LegadoJS.run("java." + (suffix == "7z" ? "un7zFile" : "unrarFile") + "(result)", input: path, baseUrl: "https://archive.test", sourceKey: "", sourceUrl: "https://archive.test")
            }
            try failures.check()
            let extracted = try SourceFiles.file(folder)
            defer { try? FileManager.default.removeItem(at: extracted) }
            XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent(name), encoding: .utf8), expected)
            if suffix == "7z" { XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("nested/chapter.txt"), encoding: .utf8), "嵌套正文") }
            let entry = LegadoJSCtx.$failures.withValue(failures) {
                LegadoJS.run("java." + (suffix == "7z" ? "get7zStringContent" : "getRarStringContent") + "(result,'\(name)','UTF-8')", input: path, baseUrl: "https://archive.test", sourceKey: "", sourceUrl: "https://archive.test")
            }
            try failures.check()
            XCTAssertEqual(entry, expected)
            XCTAssertNil(try SourceFiles.archiveEntry(Data(contentsOf: fixture), path: "missing.txt"))
            XCTAssertThrowsError(try SourceFiles.archiveEntry(Data(contentsOf: fixture), path: "../../outside.txt"))
        }
    }

    func testCachedScriptFilesReuseContentAndRedownloadAfterDeletionOrExpiry() async throws {
        var source = LegadoSource(); source.bookSourceUrl = "http://127.0.0.1:8765/cache-file-test-" + UUID().uuidString
        try await source.withRules {
            let script = #"""
            var url='http://127.0.0.1:8765/health', count=0, original=java.downloadFile;
            java.downloadFile=function(){count++;return original.apply(java,arguments);};
            var first=java.cacheFile(url,60), second=java.cacheFile(url,60), key=java.md5Encode16(url);
            var path=cache.get(key), file=java.getFile(path);
            if(first!==second||count!==1||!file.exists()||!file.isFile()||file.isDirectory()||file.length()<=0)throw Error('cache miss or wrong stat');
            if(file.getName()!==path.split('/').pop()||file.getPath()!==path)throw Error('wrong path');
            file.delete();if(file.exists())throw Error('delete failed');
            java.cacheFile(url,60);if(count!==2)throw Error('deleted file not downloaded');
            source.put('cache:'+key,JSON.stringify({value:cache.get(key),until:Date.now()-1}));
            var last=java.cacheFile(url,60);java.getFile(cache.get(key)).delete();cache.delete(key);
            [first,last,count].join('|');
            """#
            let value = LegadoJS.run(script, input: "", baseUrl: source.bookSourceUrl, sourceKey: "", sourceUrl: source.bookSourceUrl)
            try LegadoJSCtx.failures?.check()
            XCTAssertEqual(value, "ready|ready|3")
        }
    }

    private func source(_ overrides: [String: Any] = [:]) throws -> LegadoSource {
        var fields: [String: Any] = [
            "bookSourceName": "规则对照", "bookSourceUrl": "http://127.0.0.1:8765",
            "searchUrl": "/parity/search?page={{page}}",
            "ruleSearch": ["bookList": "$.books[*]", "name": "$.title", "author": "$.author", "bookUrl": "$.url"]
        ]
        fields.merge(overrides) { _, new in new }
        return try JSONDecoder().decode(LegadoSource.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func testSearchSecondPageExpandsRequestAndFieldScriptPage() async throws {
        let source = try source(["ruleSearch": ["bookList": "$.books[*]", "name": "@js:'第'+page+'页'", "bookUrl": "$.url"]])
        let books = try await source.search(key: "小说", page: 2)
        XCTAssertEqual(books.first?.title, "第2页")
        XCTAssertEqual(books.first?.url, "http://127.0.0.1:8765/parity/book/2")
    }

    @MainActor func testPaginationKeepsEarlierResultsAndStopsAtEmptyPage() async throws {
        let controller = SourceSearchController()
        controller.start([try source()], key: "小说")
        try await wait(controller)
        XCTAssertEqual(controller.results.count, 1)
        XCTAssertTrue(controller.hasMore)
        controller.loadMore(); try await wait(controller)
        XCTAssertEqual(controller.results.map(\.title), ["分页小说1", "分页小说2"])
        controller.loadMore(); try await wait(controller)
        XCTAssertFalse(controller.hasMore)
        XCTAssertEqual(controller.results.count, 2)
    }

    @MainActor func testRepeatedPageStopsAndNewSearchReplacesActiveSearch() async throws {
        let controller = SourceSearchController()
        let repeated = try source(["searchUrl": "/parity/search-repeat?page={{page}}"])
        controller.start([repeated], key: "旧词")
        controller.start([repeated], key: "新词")
        try await wait(controller)
        XCTAssertEqual(controller.keyword, "新词")
        XCTAssertEqual(controller.results.count, 1)
        controller.loadMore(); try await wait(controller)
        XCTAssertFalse(controller.hasMore)
        XCTAssertEqual(controller.allResults.count, 1)
    }

    func testLoginCheckReceivesErrorResponseAndCanReturnReplacementResponse() async throws {
        let source = try source([
            "searchUrl": "/parity/protected",
            "loginCheckJs": "if(result.code()!==401 || result.header('X-Parity')!=='response-header' || result.url.indexOf('/protected')<0) throw Error('wrong response'); java.connect('/parity/search?page=1')"
        ])
        let books = try await source.search(key: "小说")
        XCTAssertEqual(books.first?.title, "分页小说1")
    }

    func testLoginCheckCannotTurnAnErrorIntoASilentEmptySuccess() async throws {
        let source = try source(["searchUrl": "/parity/protected", "loginCheckJs": "result"])
        do { _ = try await source.search(key: "小说"); XCTFail("Unresolved HTTP failure must fail") }
        catch { XCTAssertTrue(sourceErrorMessage(error).contains("401")) }
    }

    func testDirectoryPreUpdateFormattingAndVolumeVipFlags() async throws {
        let source = try source(["ruleToc": [
            "preUpdateJs": "book.tocUrl=source.bookSourceUrl+'/parity/toc'",
            "chapterList": "$.chapters[*]", "chapterName": "$.title", "chapterUrl": "$.url",
            "isVolume": "$.volume", "isVip": "$.vip", "isPay": "$.paid",
            "formatJs": "gInt++; index+':'+gInt+':'+title"
        ]])
        var book = SourceBook(title: "小说", url: "http://127.0.0.1:8765/parity/book/1")
        book.tocUrl = "http://127.0.0.1:8765/this-must-not-be-loaded"
        let chapters = try await source.fetchChapters(book: book)
        XCTAssertEqual(chapters.map(\.title), ["1:1:第一卷", "2:2:第一章", "3:3:第二章"])
        XCTAssertEqual(chapters.map(\.isVolume), [true, false, false])
        XCTAssertEqual(chapters.map(\.isVip), [false, true, true])
        XCTAssertEqual(chapters.map(\.isPay), [false, false, true])
        XCTAssertEqual(chapters.readableIndex(from: 0), 1)
        XCTAssertNil(chapters.readableIndex(from: 3))
        XCTAssertNil(chapters.readableIndex(from: 0, direction: -1))
        XCTAssertEqual(try JSONDecoder().decode([BookChapter].self, from: JSONEncoder().encode(chapters)), chapters)
    }

    @MainActor func testEditedRulesReplaceStoredSourceAndRejectDuplicateAddress() throws {
        let store = BookStore(), original = UUID().uuidString
        let saved = store.sources
        defer { store.sources = saved; store.save() }
        var first = try source(); first.id = original
        var second = first; second.id = UUID().uuidString; second.bookSourceUrl += "/other"
        store.sources = [first, second]
        var edited = first; edited.id = "JSON-must-not-replace-stable-id"; edited.bookSourceName = "已修改"
        edited.ruleSearch.name = "@js:'新规则'"
        let result = try store.saveEditedSource(String(decoding: JSONEncoder().encode(edited), as: UTF8.self), replacing: first.id)
        XCTAssertEqual(result.id, first.id)
        XCTAssertEqual(store.sources[0].ruleSearch.name, "@js:'新规则'")
        XCTAssertEqual(BookStore().sources.first(where: { $0.id == first.id })?.bookSourceName, "已修改")
        edited.bookSourceUrl = second.bookSourceUrl
        XCTAssertThrowsError(try store.saveEditedSource(String(decoding: JSONEncoder().encode(edited), as: UTF8.self), replacing: first.id))
        XCTAssertEqual(store.sources[0].bookSourceUrl, first.bookSourceUrl)
    }

    @MainActor private func wait(_ controller: SourceSearchController) async throws {
        let deadline = Date().addingTimeInterval(15)
        while controller.searching && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(controller.searching, "Search exceeded deterministic test deadline")
    }
}
