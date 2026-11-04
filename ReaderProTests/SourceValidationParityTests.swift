import XCTest
@testable import ReaderPro

final class SourceValidationParityTests: XCTestCase {
    private let base = SourceTestFixtures.base

    func testAndroidKeywordExcludesDebugAndURLExpressions() async {
        var source = SourceTestFixtures.html()
        for value in ["", " \n\t", "https://example.invalid/book", "分类::地址", "仙逆++作者", "仙逆--作者"] {
            source.ruleSearch.checkKeyWord = value
            XCTAssertEqual(SourceValidation.checkKeyword(source, fallback: "测试"), "测试", value)
        }
        source.ruleSearch.checkKeyWord = "仙逆"
        XCTAssertEqual(SourceValidation.checkKeyword(source, fallback: "测试"), "仙逆")
        source.ruleSearch.checkKeyWord = "https://example.invalid/debug::仙逆"
        let report = await SourceValidation.run(source, keyword: "测试")
        XCTAssertEqual(report.keyword, "测试")
        XCTAssertEqual(report.status, .passed, report.searchableText)
    }

    private func contextSource(sharedURL: Bool = false) -> LegadoSource {
        var source = SourceTestFixtures.json()
        source.bookSourceUrl = base + "/validation-context-" + UUID().uuidString
        source.searchUrl = base + "/validation/list?origin=search" + (sharedURL ? "&target=/validation/book/shared" : "")
        source.exploreUrl = "上下文分类::" + base + "/validation/list?origin=discovery" + (sharedURL ? "&target=/validation/book/shared" : "")
        source.ruleSearch.bookList = "@js:java.put('validationOrigin','search');JSON.parse(result).data"
        source.ruleExplore = source.ruleSearch
        source.ruleExplore.bookList = "@js:java.put('validationOrigin','discovery');JSON.parse(result).data"
        source.ruleBookInfo.name = ""
        source.ruleBookInfo.tocUrl = "@js:if(java.get('validationOrigin')!==book.name)throw Error('entry context overwritten');JSON.parse(result).toc"
        return source
    }

    func testLegacyEntryOrderReproducesOverwrittenContextAndImmediateChainsPass() async throws {
        let source = contextSource()
        let search = try await source.search(key: "测试")
        _ = try await source.discover()
        do {
            _ = try await source.fetchBookInfo(book: XCTUnwrap(search.first))
            XCTFail("The old search/discovery/reading order must reproduce the overwritten context")
        } catch { XCTAssertTrue(sourceErrorMessage(error).contains("entry context overwritten")) }
        let report = await SourceValidation.run(source, keyword: "测试")
        XCTAssertEqual(report.status, .passed, report.searchableText)
        XCTAssertEqual(report.steps.map(\.stage), ["搜索", "详情", "目录", "正文", "发现", "发现详情", "发现目录", "发现正文"])
    }

    func testSameBookURLIsCheckedUnderBothEntryContexts() async {
        let source = contextSource(sharedURL: true)
        let report = await SourceValidation.run(source, keyword: "测试")
        XCTAssertEqual(report.status, .passed, report.searchableText)
        XCTAssertTrue(report.steps.contains { $0.stage == "正文" && $0.passed })
        XCTAssertTrue(report.steps.contains { $0.stage == "发现正文" && $0.passed })
    }

    func testBrokenDiscoveryContextCannotHideBehindIdenticalSearchURL() async {
        var source = contextSource(sharedURL: true)
        source.ruleBookInfo.tocUrl = "@js:if(java.get('validationOrigin')==='discovery')throw Error('discovery cannot read');JSON.parse(result).toc"
        let report = await SourceValidation.run(source, keyword: "测试")
        XCTAssertEqual(report.status, .partial)
        XCTAssertTrue(report.steps.contains { $0.stage == "正文" && $0.passed })
        XCTAssertTrue(report.steps.contains { $0.stage == "发现详情" && !$0.passed && $0.detail.contains("discovery cannot read") })
    }

    func testSearchDetailPagePatternAndEmptyListFallbackReachRealContent() async throws {
        for pattern in ["", NSRegularExpression.escapedPattern(for: base + "/validation/detail")] {
            var source = SourceTestFixtures.json()
            source.searchUrl = "/validation/detail"
            source.bookUrlPattern = pattern
            source.ruleBookInfo.tocUrl = "$.absentLink"
            // Parse once while recognizing the detail response. The checker
            // must reuse it rather than execute a stateful init rule twice.
            source.ruleBookInfo.initRule = "@js:if(java.get('parsedDetail')==='yes')throw Error('detail fetched twice');java.put('parsedDetail','yes');result"
            try await source.withRules { LegadoJS.putVariable("parsedDetail", "") }
            let report = await SourceValidation.run(source, keyword: "测试")
            XCTAssertEqual(report.status, .passed, report.searchableText)
            XCTAssertTrue(report.steps.contains { $0.stage == "详情" && $0.detail.contains("复用") })
            XCTAssertTrue(report.steps.contains { $0.stage == "正文" && $0.passed })
        }
    }

    func testEmptyTocLinkFallsBackToDetailPageButStillRequiresChapters() async {
        for target in ["/validation/detail", "/validation/no-toc"] {
            var source = SourceTestFixtures.json()
            source.searchUrl = "/validation/list?target=" + target
            source.ruleBookInfo.tocUrl = "$.absentLink"
            let report = await SourceValidation.run(source, keyword: "测试")
            if target.hasSuffix("/detail") {
                XCTAssertEqual(report.status, .passed, report.searchableText)
                XCTAssertTrue(report.steps.contains { $0.stage == "正文" && $0.passed })
            } else {
                XCTAssertEqual(report.status, .partial)
                XCTAssertTrue(report.steps.contains { $0.stage == "目录" && !$0.passed })
            }
        }
    }

    func testSingleBookListCanUseResponseURLWithoutASeparateBookURLRule() async {
        var source = SourceTestFixtures.json()
        source.searchUrl = "/validation/detail"
        source.ruleSearch.bookList = ""; source.ruleSearch.bookUrl = ""
        source.ruleBookInfo.tocUrl = "$.absentLink"
        let report = await SourceValidation.run(source, keyword: "测试")
        XCTAssertEqual(report.status, .passed, report.searchableText)
        XCTAssertTrue(report.steps.contains { $0.stage == "正文" && $0.passed })
    }

    func testDiscoveryWithoutItsOwnListUsesTheSearchRules() async {
        var source = SourceTestFixtures.json()
        source.exploreUrl = "复用搜索列表::/json/search"
        source.ruleExplore.name = "@js:throw Error('Android ignores an incomplete explore rule')"
        let report = await SourceValidation.run(source, keyword: "测试")
        XCTAssertEqual(report.status, .passed, report.searchableText)
        XCTAssertTrue(report.steps.contains { $0.stage == "发现正文" && $0.passed })
    }

    func testListOrderPrefixesSelectTheSameFirstSampleAsAndroid() async {
        for prefix in ["-", "-+", "+"] {
            var source = SourceTestFixtures.json()
            source.searchUrl = "/validation/order"
            source.ruleSearch.bookList = prefix + "$.data"
            source.ruleToc.chapterList = "+$.chapters[*]"
            let report = await SourceValidation.run(source, keyword: "测试")
            XCTAssertEqual(report.status, prefix.hasPrefix("-") ? .passed : .partial, report.searchableText)
            if prefix.hasPrefix("-") { XCTAssertTrue(report.steps.contains { $0.stage == "正文" && $0.passed }) }
            else { XCTAssertTrue(report.steps.contains { $0.stage == "详情" && !$0.passed && $0.detail.contains("403") }) }
        }
    }

    func testVolumeHeadingIsSkippedButVolumeWithRealChapterURLIsChecked() async throws {
        var source = SourceTestFixtures.json()
        source.ruleBookInfo.tocUrl = "@js:'" + base + "/validation/volumes'"
        source.ruleToc = try JSONDecoder().decode(LegadoSource.RuleSet.self, from: Data(#"{"chapterList":"$.chapters[*]","chapterName":"$.name","chapterUrl":"$.url","isVolume":"$.volume"}"#.utf8))
        let book = try await source.fetchBookInfo(book: SourceBook(title: "卷样本", url: base + "/json/book"))
        let chapters = try await source.fetchChapters(book: book)
        XCTAssertEqual(chapters.map(\.isVolume), [true, true])
        XCTAssertNil(chapters.first?.url)
        XCTAssertEqual(chapters.last?.url, base + "/json/chapter")
        let report = await SourceValidation.run(source, keyword: "测试")
        XCTAssertEqual(report.status, .passed, report.searchableText)
        XCTAssertTrue(report.steps.contains { $0.stage == "正文" && $0.detail.contains("有正文的卷") })
    }

    func testRuleOnlyAudioAndVideoDoNotFetchOrConvertUnavailableDASH() async {
        for type in [1, 4] {
            var source = SourceTestFixtures.json()
            source.bookSourceType = type
            source.ruleContent.content = "@js:'" + base + "/validation/media.mpd'"
            let ruleOnly = await SourceValidation.run(source, keyword: "测试")
            XCTAssertEqual(ruleOnly.status, .passed, ruleOnly.searchableText)
            XCTAssertTrue(ruleOnly.configuration?.contains("未实测") == true)
            var strict = SourceValidationOptions(); strict.mediaPlayback = true
            let actualPlayback = await SourceValidation.run(source, keyword: "测试", options: strict)
            XCTAssertEqual(actualPlayback.status, .partial)
            XCTAssertTrue(actualPlayback.steps.contains { !$0.passed && $0.stage == (type == 1 ? "音频" : "视频") })
        }
    }

    func testWebPlayerRuleSuccessDoesNotClaimPlaybackWasVerified() async {
        var source = SourceTestFixtures.json(); source.bookSourceType = 4
        source.ruleContent.content = "@js:'" + base + "/player/validation'"
        let ruleOnly = await SourceValidation.run(source, keyword: "测试")
        XCTAssertEqual(ruleOnly.status, .passed, ruleOnly.searchableText)
        XCTAssertTrue(ruleOnly.steps.contains { $0.stage == "视频" && $0.detail.contains("未检查播放器") })
        var strict = SourceValidationOptions(); strict.mediaPlayback = true
        let actualPlayback = await SourceValidation.run(source, keyword: "测试", options: strict)
        XCTAssertEqual(actualPlayback.status, .partial)
        XCTAssertTrue(actualPlayback.steps.contains { $0.stage == "视频" && !$0.passed })
    }

    func testComicRuleCheckAndImageDownloadAreSeparateOptions() async {
        var source = SourceTestFixtures.json(); source.bookSourceType = 2
        source.ruleContent.imageUrl = "@js:'" + base + "/denied'"
        let ruleOnly = await SourceValidation.run(source, keyword: "测试")
        XCTAssertEqual(ruleOnly.status, .passed, ruleOnly.searchableText)
        XCTAssertTrue(ruleOnly.steps.contains { $0.stage == "正文" && $0.detail.contains("未检查图片响应") })
        var strict = SourceValidationOptions(); strict.mediaPlayback = true
        let image = await SourceValidation.run(source, keyword: "测试", options: strict)
        XCTAssertEqual(image.status, .partial)
        XCTAssertTrue(image.steps.contains { $0.stage == "正文" && !$0.passed && $0.detail.contains("403") })
    }

    func testEmptyMediaAndTextRulesStillCannotPass() async {
        for type in [0, 1, 2, 4] {
            var source = SourceTestFixtures.json(); source.bookSourceType = type
            source.ruleContent.content = "@js:''"
            let report = await SourceValidation.run(source, keyword: "测试")
            XCTAssertEqual(report.status, .partial)
            XCTAssertFalse(SourceStatusFilter.passed.matches(report: report, checking: false))
            XCTAssertTrue(report.steps.contains { !$0.passed })
        }
    }

    func testAndroidDefaultsMigrateOnceAndPreserveLaterExplicitChoices() throws {
        let suite = "ValidationParity." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = SourceValidationOptions.load(defaults: defaults)
        XCTAssertFalse(initial.mediaPlayback)
        XCTAssertTrue(initial.disabledDiscovery)
        defaults.set(Data(#"{"timeout":75,"search":true,"discovery":false,"info":true,"catalog":true,"content":false,"mediaPlayback":true,"disabledDiscovery":false}"#.utf8), forKey: "source.validationOptions")
        var migrated = SourceValidationOptions.load(defaults: defaults)
        XCTAssertEqual(migrated.timeout, 75)
        XCTAssertFalse(migrated.discovery)
        XCTAssertFalse(migrated.content)
        XCTAssertFalse(migrated.mediaPlayback)
        XCTAssertTrue(migrated.disabledDiscovery)
        migrated.mediaPlayback = true; migrated.disabledDiscovery = false
        migrated.save(defaults: defaults)
        XCTAssertEqual(SourceValidationOptions.load(defaults: defaults), migrated)
        let minimal = try JSONDecoder().decode(SourceValidationOptions.self, from: Data(#"{"compatibilityVersion":2,"timeout":30}"#.utf8))
        XCTAssertEqual(minimal.timeout, 30)
        XCTAssertTrue(minimal.search)
        XCTAssertFalse(minimal.mediaPlayback)
    }

    func testDisabledDiscoveryIsCheckedByDefaultAsOnAndroid() async {
        var source = SourceTestFixtures.json()
        source.enabledExplore = false; source.exploreUrl = "关闭分类::/denied"
        let android = await SourceValidation.run(source, keyword: "测试")
        XCTAssertEqual(android.status, .partial)
        XCTAssertTrue(android.steps.contains { $0.stage == "发现" && !$0.passed })
        var selected = SourceValidationOptions(); selected.disabledDiscovery = false
        let enabledOnly = await SourceValidation.run(source, keyword: "测试", options: selected)
        XCTAssertEqual(enabledOnly.status, .passed, enabledOnly.searchableText)
    }
}
