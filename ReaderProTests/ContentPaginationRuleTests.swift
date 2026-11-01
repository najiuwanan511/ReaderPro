import Foundation
import XCTest
@testable import ReaderPro

// Network-independent fixtures exercise the real source rule engine and its
// URLSession path. They include both Legado pagination forms and a chapter
// boundary; no external source state is changed.
private final class PaginationURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "paging.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let bodies: [String: String] = [
            "/list/1": #"{"content":"one","images":["/image/1.jpg"],"pages":["/list/1","/list/2","/list/3","/list/2","/chapter/next"]}"#,
            "/list/2": #"{"content":"two","images":["/image/2.jpg"],"pages":["/list/unexpected"]}"#,
            "/list/3": #"{"content":"three","images":["/image/3.jpg"],"pages":["/chapter/next"]}"#,
            "/list/unexpected": #"{"content":"unexpected","images":["/image/unexpected.jpg"],"pages":[]}"#,
            "/chapter/next": #"{"content":"next chapter","images":["/image/next.jpg"],"pages":[]}"#,
            "/chain/1": #"{"content":"one","pages":["/chain/2"]}"#,
            "/chain/2": #"{"content":"two","pages":["/chain/3"]}"#,
            "/chain/3": #"{"content":"three","pages":["/chapter/next"]}"#,
            "/gold/1": #"<div id="content">one</div><small>页数(3)</small>"#,
            "/gold/1/2.html": #"<div id="content">two</div><small>页数(3)</small>"#,
            "/gold/1/3.html": #"<div id="content">three</div><small>页数(3)</small>"#
        ]
        let url = request.url!
        guard let body = bodies[url.path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ContentPaginationRuleTests: XCTestCase {
    private let base = "https://paging.test"
    // Verbatim nextContentUrl from the user's 1325 and 1329 collections.
    private let goldRule = #"""
    small@text##(\d+)\)$##$1###
    <js>
    Array.from(
     { length: Number(result[0]) - 1 },
     (_, i) => baseUrl.replace(/\/?$/g, '/' + (i + 2) + '.html')
    )
    </js>
    """#
    private func source() -> LegadoSource {
        var source = LegadoSource()
        source.bookSourceUrl = base
        source.ruleContent.content = "$.content"
        source.ruleContent.imageUrl = "$.images[*]"
        source.ruleContent.nextContentUrl = "$.pages[*]"
        return source
    }
    private func chapter(_ path: String) -> BookChapter {
        let url = base + path
        return BookChapter(id: url, title: "分页章节", text: "__URL__" + url, url: url)
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PaginationURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testTextPageListKeepsAllPagesInOrderAndSkipsNextChapter() async throws {
        let content = try await SourceHTTP.$testSession.withValue(session()) {
            try await source().fetchChapterContent(chapter("/list/1"), nextChapterUrl: base + "/chapter/next")
        }
        XCTAssertEqual(content, "one\ntwo\nthree")
    }

    func testJavaScriptArrayOfNextPagesIsNotTreatedAsOneURL() async throws {
        // The user's 黄金屋 source also returns an array of URLs from JS.
        var jsSource = source()
        jsSource.ruleContent.nextContentUrl = "@js:JSON.parse(result).pages"
        let content = try await SourceHTTP.$testSession.withValue(session()) {
            try await jsSource.fetchChapterContent(chapter("/list/1"), nextChapterUrl: base + "/chapter/next")
        }
        XCTAssertEqual(content, "one\ntwo\nthree")
    }

    func testJavaScriptNewlineSeparatedNextPages() async throws {
        var jsSource = source()
        jsSource.ruleContent.nextContentUrl = #"@js:JSON.parse(result).pages.join('\n')"#
        let content = try await SourceHTTP.$testSession.withValue(session()) {
            try await jsSource.fetchChapterContent(chapter("/list/1"), nextChapterUrl: base + "/chapter/next")
        }
        XCTAssertEqual(content, "one\ntwo\nthree")
    }

    func testFirstMatchReplacementExtractsOnlyTheMatch() {
        let rule = #"small@text##(\d+)\)$##$1###"#
        XCTAssertEqual(applyRuleFirst("<small>页数(3)</small>", rule, base: base), "3")
        XCTAssertEqual(applyRuleFirst("<small>没有页数</small>", rule, base: base), "")
        XCTAssertEqual(applyRegexReplace("页数(3)", pattern: #"(\d+)\)$"#, replacement: "$1"), "页数(3")
    }

    func testOriginalHuangJinWuMultiplePagesRule() async throws {
        var gold = source()
        gold.ruleContent.content = "@css:#content@text"
        gold.ruleContent.nextContentUrl = goldRule
        let content = try await SourceHTTP.$testSession.withValue(session()) {
            try await gold.fetchChapterContent(chapter("/gold/1"))
        }
        XCTAssertEqual(content, "one\ntwo\nthree")
    }

    func testOriginalHuangJinWuPassesWholeMultiDigitPageCountToJS() throws {
        let value = try XCTUnwrap(applyContentNextPageRule("<small>页数(15)</small>", goldRule, base: base + "/gold/1").first)
        let urls = try JSONDecoder().decode([String].self, from: Data(value.utf8))
        XCTAssertEqual(urls.count, 14)
        XCTAssertEqual(urls.first, base + "/gold/1/2.html")
        XCTAssertEqual(urls.last, base + "/gold/1/15.html")
    }

    func testSingleNextPageStillFollowsChainAndStopsAtNextChapter() async throws {
        let content = try await SourceHTTP.$testSession.withValue(session()) {
            try await source().fetchChapterContent(chapter("/chain/1"), nextChapterUrl: base + "/chapter/next")
        }
        XCTAssertEqual(content, "one\ntwo\nthree")
    }

    func testComicPageListKeepsAllImagesInOrderAndSkipsNextChapter() async throws {
        let images = try await SourceHTTP.$testSession.withValue(session()) {
            try await source().fetchChapterImages(chapter("/list/1"), nextChapterUrl: base + "/chapter/next")
        }
        XCTAssertEqual(images, [base + "/image/1.jpg", base + "/image/2.jpg", base + "/image/3.jpg"])
    }
}
