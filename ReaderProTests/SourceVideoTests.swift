import XCTest
@testable import ReaderPro

final class SourceVideoTests: XCTestCase {
    func testVideoTypeRoutesToPlayerAndOtherTypesRemainDistinct() throws {
        let source = try JSONDecoder().decode(LegadoSource.self, from: Data(#"{"bookSourceType":4}"#.utf8))
        XCTAssertTrue(source.isVideo)
        XCTAssertEqual(source.localBookKind, "video")
        var comic = source; comic.bookSourceType = 2
        XCTAssertEqual(comic.localBookKind, "comic")
        var text = source; text.bookSourceType = 0
        XCTAssertEqual(text.localBookKind, "web")
    }

    func testImportedLocalVideoStillUsesTheNativePlayer() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data([0, 0, 0, 24]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        guard case .native(let request) = try SourceVideoResource.make(file.absoluteString, base: file.absoluteString, headers: [:]) else { return XCTFail("Expected imported local video") }
        XCTAssertEqual(request.url, file)
        XCTAssertThrowsError(try SourceVideoResource.make(file.appendingPathExtension("missing").absoluteString, base: file.absoluteString, headers: [:]))
    }

    func testPack1330DramaRulesResolveDifferentEpisodesAndPreserveSignedURLs() async throws {
        let source = SourceTestFixtures.video()
        let books = try await source.discover(category: ExploreCategory(title: "短剧", url: "/video/list"))
        let info = try await source.fetchBookInfo(book: XCTUnwrap(books.first))
        let chapters = try await source.fetchChapters(book: info)
        XCTAssertEqual(chapters.map(\.title), ["第1集", "第2集", "第3集"])
        for index in 0..<3 {
            guard case .native(let request) = try await source.fetchChapterVideo(chapters[index]) else { return XCTFail("Expected native chapter video") }
            XCTAssertEqual(request.url?.path, "/video/episode\(index + 1).mp4")
            XCTAssertEqual(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery }, "token=a%2Bb&part=\(index + 1)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Video"), "ReaderPro")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), SourceTestFixtures.base + "/video/book")
        }
    }

    func testDirectStreamRuleDoesNotDownloadMediaToParseIt() async throws {
        var source = SourceTestFixtures.video()
        source.ruleContent.content = "@js:java.toast('正在加载: ' + chapter.title); result = baseUrl;"
        // This host must never be contacted by the resolver.
        let address = "https://never-download.invalid/episode.m3u8?sign=a%2Bb&part=2"
        let chapter = BookChapter(title: "第2集", text: "__URL__" + address, url: address)
        guard case .native(let request) = try await source.fetchChapterVideo(chapter) else { return XCTFail("Expected stream") }
        XCTAssertEqual(request.url?.absoluteString, address)
    }

    func testOriginal1330JSONVideoSourceCompletesDiscoveryDirectoryAndEpisodeRules() async throws {
        let raw = try await fetchText(urlString: SourceTestFixtures.base + "/video/public-source")
        var source = try JSONDecoder().decode(LegadoSource.self, from: Data(raw.utf8))
        XCTAssertEqual(source.bookSourceType, 4)
        // Replace only the host. Every extraction rule is the imported rule.
        source.bookSourceUrl = SourceTestFixtures.base
        let books = try await source.discover(category: ExploreCategory(title: "短剧", url: "/api.php/provide/vod/?ac=detail&t=36&pg={{page}}"))
        XCTAssertEqual(books.first?.title, "测试API短剧")
        let detail = try await source.fetchBookInfo(book: XCTUnwrap(books.first))
        let chapters = try await source.fetchChapters(book: detail)
        XCTAssertEqual(chapters.map(\.title), ["第1集", "第2集", "第3集"])
        guard case .native(let request) = try await source.fetchChapterVideo(chapters[1]) else { return XCTFail("Expected HLS chapter") }
        XCTAssertEqual(request.url?.absoluteString, SourceTestFixtures.base + "/video/episode2.m3u8?sign=a%2Bb&part=2")
    }

    func testPromptTextAndUnsupportedManifestProduceExplicitErrors() {
        XCTAssertThrowsError(try SourceVideoResource.make("刷新正文播放", base: SourceTestFixtures.base, headers: [:]))
        XCTAssertThrowsError(try SourceVideoResource.make("<MPD><Period/></MPD>", base: SourceTestFixtures.base, headers: [:]))
    }

    func testVideoURLOptionsOverrideSourceHeadersWithoutDamagingSignature() throws {
        let raw = #"https://media.test/2.m3u8?token=a%2Bb&part=2,{"headers":{"User-Agent":"Video Player","Referer":"https://player.test/episode2","X-Token":"episode2"}}"#
        guard case .native(let request) = try SourceVideoResource.make(raw, base: "https://source.test", headers: ["Referer": "https://source.test", "User-Agent": "Source UA"]) else { return XCTFail("Expected native media") }
        XCTAssertEqual(request.url?.absoluteString, "https://media.test/2.m3u8?token=a%2Bb&part=2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Video Player")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://player.test/episode2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Token"), "episode2")
    }

    func testPlayerHTMLIsNotStrippedAndEmptyRulesUseChapterLink() async throws {
        let html = "<html><script>var signature='a&b';</script><iframe src='/player'></iframe></html>"
        guard case .html(let returned, _) = try SourceVideoResource.make(html, base: SourceTestFixtures.base, headers: [:]) else { return XCTFail("Expected HTML player") }
        XCTAssertEqual(returned, html)
        var source = SourceTestFixtures.video(); source.ruleContent.content = ""
        let url = SourceTestFixtures.base + "/video/embed"
        guard case .web(let request) = try await source.fetchChapterVideo(BookChapter(title: "网页视频", text: "__URL__" + url, url: url)) else { return XCTFail("Expected embedded web player") }
        XCTAssertEqual(request.url?.absoluteString, url)
    }

    func testLegacyBrowserHandoffUsesTheSelectedChapterContext() async throws {
        var source = SourceTestFixtures.video()
        source.ruleContent.content = "@js:if(book.durChapterIndex==chapter.index) java.startBrowser('/video/embed',title); result='刷新正文播放';"
        var chapter = BookChapter(title: "第3集", text: "__URL__" + SourceTestFixtures.base + "/video/play?ep=3")
        chapter.ruleIndex = 2
        guard case .web(let request) = try await source.fetchChapterVideo(chapter) else { return XCTFail("Expected in-app player handoff") }
        XCTAssertEqual(request.url?.path, "/video/embed")
    }

    func testEmptyVideoContentProducesActionableError() async throws {
        let source = SourceTestFixtures.video()
        do {
            _ = try await source.fetchChapterVideo(BookChapter(title: "空视频", text: "__URL__" + SourceTestFixtures.base + "/video/empty"))
            XCTFail("Must not silently open a blank page")
        } catch {
            XCTAssertTrue(sourceErrorMessage(error).contains("播放地址"), sourceErrorMessage(error))
        }
    }
}
