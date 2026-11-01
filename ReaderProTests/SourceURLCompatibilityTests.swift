import XCTest
@testable import ReaderPro

private final class URLScriptProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/plain; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("token=abc".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class SourceURLCompatibilityTests: XCTestCase {
    func testLegadoPageAlternativesAndSearchEncoding() throws {
        // An actual search rule from the user's 1325 and 1329 packs.
        let search = "/<,page/{{page}}>?s={{key}}"
        let base = "https://example.test"
        let first = try SourceHTTP.request(search, base: base, key: "斗罗大陆", page: 1)
        let second = try SourceHTTP.request(search, base: base, key: "斗罗大陆", page: 2)
        let fifth = try SourceHTTP.request(search, base: base, key: "斗罗大陆", page: 5)
        XCTAssertEqual(first.url?.absoluteString, "https://example.test/?s=%E6%96%97%E7%BD%97%E5%A4%A7%E9%99%86")
        XCTAssertEqual(second.url?.absoluteString, "https://example.test/page/2?s=%E6%96%97%E7%BD%97%E5%A4%A7%E9%99%86")
        XCTAssertEqual(fifth.url?.absoluteString, "https://example.test/page/5?s=%E6%96%97%E7%BD%97%E5%A4%A7%E9%99%86")
    }

    func testPageAlternativesAfterEmbeddedJavaScript() throws {
        // The choices are selected after JS evaluation, including arithmetic
        // containing a > operator; only the chosen branch reaches URL parsing.
        let template = "/books/<first,{{page > 1 ? 'next-' + page : 'bad'}}>/item<1,2,3>"
        XCTAssertEqual(SourceHTTP.expand(template, base: "https://example.test", key: "", page: 1), "/books/first/item1")
        XCTAssertEqual(SourceHTTP.expand(template, base: "https://example.test", key: "", page: 2), "/books/next-2/item2")
        XCTAssertEqual(SourceHTTP.expand(template, base: "https://example.test", key: "", page: 8), "/books/next-8/item3")
    }

    func testURLScriptCanReadURLAndChangeRequestHeaders() throws {
        // Based on the 1329 刚够小说网 rule, which sets a cookie through
        // java.headerMap before using java.url for the real request.
        let raw = #"/search?q={{key}},{"method":"POST","body":"page={{page}}","headers":{"X-Original":"yes"},"js":"java.headerMap.put('Cookie','is_human=ok'); java.headerMap.remove('X-Original'); java.url + '&from=js'"}"#
        let request = try SourceHTTP.request(raw, base: "https://example.test", key: "斗罗", page: 2)
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/search?q=%E6%96%97%E7%BD%97&from=js")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "is_human=ok")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Original"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), sourceUA)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8), "page=2")
    }

    func testURLScriptReplacesHeadersIgnoringCase() throws {
        let raw = #"/search,{"headers":{"X-Original":"old"},"js":"java.headerMap.put('x-original','new');java.url"}"#
        let request = try SourceHTTP.request(raw, base: "https://example.test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Original"), "new")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), sourceUA)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://example.test")
    }

    func testURLScriptWithoutReturnPreservesOriginalURL() throws {
        let raw = #"/search,{"js":"java.toast('正在搜索');"}"#
        let request = try SourceHTTP.request(raw, base: "https://example.test")
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/search")
        let mutating = #"/search,{"js":"java.url='https://example.test/rewritten';java.toast('提示');"}"#
        let rewritten = try SourceHTTP.request(mutating, base: "https://example.test")
        XCTAssertEqual(rewritten.url?.absoluteString, "https://example.test/rewritten")
    }

    func testURLScriptCanFetchItsURLBeforeSettingCookie() async throws {
        let result = try await Task.detached {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [URLScriptProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            return try await SourceHTTP.$testSession.withValue(session) {
                let raw = #"/search,{"js":"var token=java.ajax(java.url).match(/token=([a-z]+)/)[1];java.headerMap.put('Cookie','is_human='+token);java.url"}"#
                let request = try SourceHTTP.request(raw, base: "https://example.test")
                return request.value(forHTTPHeaderField: "Cookie") ?? ""
            }
        }.value
        XCTAssertEqual(result, "is_human=abc")
    }

    func testJSONSearchBodyKeepsKeywordAndUsesJSONContentType() throws {
        // The user's 爱下电子 source sends a JSON string as its POST body.
        let raw = #"/search,{"body":'{"searchTerms":"{{key}}","pageSize":"20","pageNum":"{{page}}"}',"method":"POST"}"#
        let request = try SourceHTTP.request(raw, base: "https://example.test", key: "斗罗\"大陆", page: 3)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object["searchTerms"], "斗罗\"大陆")
        XCTAssertEqual(object["pageNum"], "3")

        // ASCII terms must not accidentally rewrite unrelated JSON keys.
        let asciiRequest = try SourceHTTP.request(raw, base: "https://example.test", key: "a", page: 1)
        let asciiObject = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(asciiRequest.httpBody)) as? [String: String])
        XCTAssertEqual(asciiObject["searchTerms"], "a")
        XCTAssertEqual(asciiObject["pageNum"], "1")
    }

    @MainActor func testWebViewRespectsSourceDelay() async throws {
        XCTAssertEqual(SourceHTTP.webViewDelay(["webViewDelayTime": 2500]), 2.5)
        XCTAssertEqual(SourceHTTP.webViewDelay(["webViewDelayTime": "500"]), 0.5)
        XCTAssertEqual(SourceHTTP.webViewDelay(["webViewDelayTime": -1]), 0)
        let request = URLRequest(url: URL(string: "https://example.test/")!)
        let html = "<html><body>waiting<script>setTimeout(function(){document.body.innerHTML='ready'}, 500);</script></body></html>"
        let page = try await SourceWebLoader.load(request, html: html, timeout: 10, delay: 1)
        XCTAssertTrue(page.text.contains("ready"), page.text)
        XCTAssertFalse(page.text.contains("waiting"), page.text)
    }
}
