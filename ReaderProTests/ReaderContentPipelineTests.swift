import XCTest
@testable import ReaderPro

@MainActor final class ReaderContentPipelineTests: XCTestCase {
    private func store() -> BookStore {
        let store = BookStore()
        store.sources = [SourceTestFixtures.html()]
        var book = LocalBook(title: "测试小说", sourceName: store.sources[0].bookSourceName,
                             sourceUrl: store.sources[0].bookSourceUrl, fileName: "test.web", kind: "web")
        book.id = "prefetch-book"
        book.chapters = (0..<7).map { BookChapter(id: "chapter-\($0)", title: "第\($0 + 1)章", text: $0 == 0 ? "首章原文" : "__URL__/\($0)", url: "https://fixture.invalid/\($0)") }
        store.books = [book]
        return store
    }
    private func savedFiles() -> [(URL, Data?)] { [BookStore.booksURL, BookStore.metaURL].map { ($0, try? Data(contentsOf: $0)) } }
    private func restore(_ files: [(URL, Data?)]) {
        for (url, data) in files {
            if let data { try? data.write(to: url) }
            else { try? FileManager.default.removeItem(at: url) }
        }
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("后台缓存没有在本地无网络的测试中完成")
    }

    func testPreloadsExactlyNextThreeAndMovesWindowWithoutRedownload() async throws {
        let files = savedFiles(); defer { restore(files) }
        let store = store(); var calls: [String] = []
        let cache = ReaderChapterCache(store: store) { _, chapter, next in
            calls.append(chapter.id)
            XCTAssertEqual(next, "https://fixture.invalid/\((chapter.ruleIndex ?? Int(chapter.id.split(separator: "-").last!)!) + 1)")
            return "原文" + chapter.id
        }
        defer { cache.cancel(bookID: "prefetch-book") }
        cache.preload(bookID: "prefetch-book", after: 0)
        try await waitUntil { !store.books[0].chapters[3].text.hasPrefix("__URL__") }
        XCTAssertEqual(calls, ["chapter-1", "chapter-2", "chapter-3"])
        XCTAssertTrue(store.books[0].chapters[4].text.hasPrefix("__URL__"))
        let cached = try await cache.content(bookID: "prefetch-book", index: 1)
        XCTAssertEqual(cached, "原文chapter-1")
        cache.preload(bookID: "prefetch-book", after: 1)
        try await waitUntil { !store.books[0].chapters[4].text.hasPrefix("__URL__") }
        XCTAssertEqual(calls, ["chapter-1", "chapter-2", "chapter-3", "chapter-4"])
        XCTAssertTrue(store.books[0].chapters[5].text.hasPrefix("__URL__"))
    }

    func testTurningToInflightPrefetchReusesRequest() async throws {
        let files = savedFiles(); defer { restore(files) }
        let store = store(); var calls = 0
        let cache = ReaderChapterCache(store: store) { _, _, _ in
            calls += 1
            try await Task.sleep(nanoseconds: 50_000_000)
            return "预下载的正文"
        }
        defer { cache.cancel(bookID: "prefetch-book") }
        cache.preload(bookID: "prefetch-book", after: 0, count: 1)
        try await waitUntil { calls == 1 }
        let text = try await cache.content(bookID: "prefetch-book", index: 1)
        XCTAssertEqual(text, "预下载的正文"); XCTAssertEqual(calls, 1)
    }

    func testLateOldSourceResponseCannotOverwriteNewDirectory() async throws {
        let files = savedFiles(); defer { restore(files) }
        let store = store()
        let cache = ReaderChapterCache(store: store) { _, _, _ in
            try? await Task.sleep(nanoseconds: 40_000_000) // Deliberately ignore cancellation, as a JS fetch may.
            return "旧来源正文"
        }
        let load = Task { try await cache.content(bookID: "prefetch-book", index: 1) }
        try await Task.sleep(nanoseconds: 10_000_000)
        cache.cancel(bookID: "prefetch-book")
        store.books[0].sourceUrl = "https://new.invalid"
        store.books[0].chapters[1].text = "新来源正文"
        do { _ = try await load.value; XCTFail("旧来源请求应被取消") } catch { }
        XCTAssertEqual(store.books[0].chapters[1].text, "新来源正文")
    }

    func testFailedPreloadRemainsRetryableAndDoesNotCacheErrorText() async throws {
        let files = savedFiles(); defer { restore(files) }
        let store = store(); var calls = 0
        let cache = ReaderChapterCache(store: store) { _, _, _ in
            calls += 1
            if calls == 1 { throw URLError(.timedOut) }
            return "重试成功"
        }
        do { _ = try await cache.content(bookID: "prefetch-book", index: 1); XCTFail("应超时") } catch { }
        XCTAssertTrue(store.books[0].chapters[1].text.hasPrefix("__URL__"))
        let text = try await cache.content(bookID: "prefetch-book", index: 1)
        XCTAssertEqual(text, "重试成功"); XCTAssertEqual(calls, 2)
    }

    func testLocalBooksAndLastChapterDoNotTriggerNetwork() async throws {
        let files = savedFiles(); defer { restore(files) }
        let store = store(); var calls = 0
        let cache = ReaderChapterCache(store: store) { _, _, _ in calls += 1; return "unexpected" }
        cache.preload(bookID: "prefetch-book", after: 6)
        store.books[0].kind = "txt"
        cache.preload(bookID: "prefetch-book", after: 0)
        await Task.yield(); XCTAssertEqual(calls, 0)
        cache.cancel(bookID: "prefetch-book")
    }

    func testLegadoRuleJSONAndOldLocalRulesRemainCompatible() throws {
        let input = #"[{"id":123,"name":"普通替换","pattern":"a.b","replacement":"$1","isEnabled":false,"isRegex":false,"scopeTitle":true,"scopeContent":false,"group":"测试","scope":"小说","excludeScope":"https://exclude.invalid","timeoutMillisecond":500,"order":2}]"#
        let rule = try XCTUnwrap(ReplacementRuleDocument.decode(Data(input.utf8)).first)
        XCTAssertEqual(rule.id, "123"); XCTAssertFalse(rule.enabled); XCTAssertFalse(rule.isRegex)
        XCTAssertTrue(rule.scopeTitle); XCTAssertFalse(rule.scopeContent); XCTAssertEqual(rule.timeoutMillisecond, 500)
        let roundTrip = try XCTUnwrap(ReplacementRuleDocument.decode(ReplacementRuleDocument.encode([rule])).first)
        XCTAssertEqual(rule, roundTrip)
        let legacy = #"{"id":"old-uuid","name":"旧规则","pattern":"广告","replacement":"","enabled":false}"#
        let old = try JSONDecoder().decode(ReplaceRule.self, from: Data(legacy.utf8))
        XCTAssertFalse(old.enabled); XCTAssertTrue(old.isRegex); XCTAssertTrue(old.scopeContent)
        XCTAssertEqual(try JSONDecoder().decode(ReplaceRule.self, from: JSONEncoder().encode(old)), old)
    }

    func testLiteralAndRegexGroupReplacementAreDifferent() throws {
        var rule = ReplaceRule(pattern: "a.b", replacement: "$1", isRegex: false)
        XCTAssertEqual(try rule.replacing("a.b axb"), "$1 axb")
        rule.pattern = "(第)([0-9]+)(章)"; rule.replacement = "$1<$2>$3"; rule.isRegex = true
        XCTAssertEqual(try rule.replacing("第12章"), "第<12>章")
    }

    func testRegexProgressDeadlineStopsPathologicalRule() throws {
        let rule = ReplaceRule(name: "超时测试", pattern: "^(a+)+$", replacement: "", timeoutMillisecond: 1)
        let start = Date()
        XCTAssertThrowsError(try rule.replacing(String(repeating: "a", count: 800) + "!"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "错误的净化规则不能长期阻塞阅读")
    }

    func testTitleContentScopeExclusionAndPerBookToggle() throws {
        let files = savedFiles(); defer { restore(files) }
        let store = store(); var book = store.books[0]
        store.replaceRules = [ReplaceRule(pattern: "原文", replacement: "净化", scope: "测试小说", scopeTitle: true, scopeContent: false)]
        XCTAssertEqual(store.purify("原文", book: book), "原文")
        XCTAssertEqual(store.purify("原文", book: book, title: true), "净化")
        store.replaceRules[0].excludeScope = book.sourceUrl
        XCTAssertEqual(store.purify("原文", book: book, title: true), "原文")
        store.replaceRules[0].excludeScope = ""; book.useReplaceRule = false
        XCTAssertEqual(store.purify("原文", book: book, title: true), "原文")
        book.useReplaceRule = true; book.title = "其他小说"
        XCTAssertEqual(store.purify("原文", book: book, title: true), "原文")
    }

    func testRulesDoNotMutateCachedRawChapters() throws {
        let files = savedFiles(); defer { restore(files) }
        let store = store(); let book = store.books[0]
        store.replaceRules = [ReplaceRule(pattern: "原文", replacement: "净化")]
        XCTAssertEqual(store.purify(book.chapters[0].text, book: book), "首章净化")
        store.replaceRules[0].enabled = false
        XCTAssertEqual(store.purify(book.chapters[0].text, book: book), "首章原文")
        XCTAssertEqual(store.books[0].chapters[0].text, "首章原文")
    }

    func testInvalidImportIsAtomicAndReimportUpdatesWithoutDuplicates() throws {
        let files = savedFiles(); defer { restore(files) }
        let store = store(); store.replaceRules = []
        XCTAssertThrowsError(try store.importReplaceRules(Data(#"[{"pattern":"ok"},{"pattern":"["}]"#.utf8)))
        XCTAssertTrue(store.replaceRules.isEmpty)
        let data = Data(#"[{"id":1,"name":"规则","pattern":"广告","replacement":""}]"#.utf8)
        _ = try store.importReplaceRules(data); _ = try store.importReplaceRules(data)
        XCTAssertEqual(store.replaceRules.count, 1)
        XCTAssertEqual(BookStore().replaceRules.count, 1)
    }

    func testSourceCandidatesKeepDifferentSourcesAndRejectDifferentNovels() {
        let first = SourceBook(title: "测试小说", author: "作者", url: "https://one.invalid/book", sourceName: "来源一", sourceUrl: "https://one.invalid")
        var second = first; second.sourceName = "来源二"; second.sourceUrl = "https://two.invalid"
        XCTAssertNotEqual(ReaderSourceCandidate(book: first).id, ReaderSourceCandidate(book: second).id)
        XCTAssertTrue(ReaderSourceChangeModel.matches(second, title: "测试 小说", author: "作者"))
        XCTAssertFalse(ReaderSourceChangeModel.matches(second, title: "测试小说续集", author: "作者"))
        XCTAssertFalse(ReaderSourceChangeModel.matches(second, title: "测试小说", author: "其他作者"))
        second.author = "作者（连载）"
        XCTAssertTrue(ReaderSourceChangeModel.matches(second, title: "测试小说", author: "作者"))
    }
}
