import Foundation
import XCTest
@testable import ReaderPro

private final class DiscoveryPageProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "discover-pages.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value ?? "1"
        let body = page == "1" ? #"{"items":[{"name":"第一页","url":"/book/1"}]}"#
            : page == "2" ? #"{"items":[{"name":"第二页","url":"/book/2"}]}"# : #"{"items":[]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class DiscoveryPaginationTests: XCTestCase {
    func testDiscoveryExpandsRequestedPageAndEndsOnEmptyLaterPage() async throws {
        var source = LegadoSource()
        source.bookSourceUrl = "https://discover-pages.test"
        source.ruleExplore.bookList = "$.items[*]"
        source.ruleExplore.name = "$.name"
        source.ruleExplore.bookUrl = "$.url"
        let category = ExploreCategory(title: "分类", url: "/list?page={{page}}")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryPageProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        try await SourceHTTP.$testSession.withValue(session) {
            let first = try await source.discover(category: category)
            let second = try await source.discover(category: category, page: 2)
            let end = try await source.discover(category: category, page: 3)
            XCTAssertEqual(first.map(\.title), ["第一页"])
            XCTAssertEqual(second.map(\.title), ["第二页"])
            XCTAssertTrue(end.isEmpty)
        }
    }
}
