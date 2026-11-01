import XCTest
@testable import ReaderPro

private final class HeaderResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Location": "https://redirect.test/new-search", "Content-Type": "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class SourceHeaderCompatibilityTests: XCTestCase {
    func testLegadoJSHeaderTagsRunLibraryAndPreserveHeaderValues() async throws {
        var source = LegadoSource()
        source.bookSourceName = "header fixture"
        source.bookSourceUrl = "https://example.test"
        // Same pattern as the user's G站漫画 source: a helper from jsLib,
        // cache side effects and a JS-produced header JSON object.
        source.jsLib = "function Map(k){return '0,1';} function Get(k){return '0';}"
        source.header = #"""
        <JS>
        var Proxy = Map('代理：').split(',');
        var headers = {'Referer': baseUrl + '/', 'Origin': baseUrl,
                       'User-Agent': 'Fixture-UA',
                       'proxy': Proxy.some(v => parseInt(v, 10) == parseInt(Get('ci0'), 10)) ? '' : Proxy[0]};
        cache.put(java.md5Encode16(Get('url') + 'headers'), JSON.stringify(headers));
        JSON.stringify(headers);
        </JS>
        """#
        let headers = try await withTimeout(10) {
            try await source.withRules { LegadoJSCtx.headers }
        }
        XCTAssertEqual(headers["Referer"], "https://example.test/")
        XCTAssertEqual(headers["Origin"], "https://example.test")
        XCTAssertEqual(headers["User-Agent"], "Fixture-UA")
        XCTAssertEqual(headers["proxy"], "")
    }

    func testInvalidOptionalHeaderRuleDoesNotAbortSource() async throws {
        var source = LegadoSource()
        source.bookSourceUrl = "https://example.test"
        source.header = "<js>throw new Error('broken optional header');</js>"
        let headers = try await withTimeout(10) {
            try await source.withRules { LegadoJSCtx.headers }
        }
        XCTAssertTrue(headers.isEmpty)
    }

    func testAtJSAndPlainHeadersRemainSupported() async throws {
        var source = LegadoSource()
        source.bookSourceUrl = "https://example.test"
        source.header = "@js:JSON.stringify({'Referer': baseUrl, 'X-Test': 'ok'})"
        let scripted = try await withTimeout(10) { try await source.withRules { LegadoJSCtx.headers } }
        XCTAssertEqual(scripted["Referer"], "https://example.test")
        XCTAssertEqual(scripted["X-Test"], "ok")
        source.header = #"{"Accept":"text/html"}"#
        let plain = try await withTimeout(10) { try await source.withRules { LegadoJSCtx.headers } }
        XCTAssertEqual(plain["Accept"], "text/html")
    }

    func testJavaGetResponseHeadersByNameSupportRedirectRules() async throws {
        let output = try await Task.detached {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HeaderResponseProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            return try await SourceHTTP.$testSession.withValue(session) {
                let failures = RuleFailures()
                return try LegadoJSCtx.$failures.withValue(failures) {
                    // From the user's 笔趣阁#6 redirect search pattern.
                    let js = #"""
                    var response = java.get('https://example.test/', {});
                    var locations = response.headers('Location');
                    JSON.stringify({indexed:locations[0], get:locations.get(0), count:locations.size(),
                                    missing:response.headers('Missing').size(),
                                    header:response.header('LOCATION'), all:response.headers().location});
                    """#
                    let text = LegadoJS.run(js, input: "", baseUrl: "https://example.test", sourceKey: "", sourceUrl: "https://example.test")
                    try failures.check()
                    return text
                }
            }
        }.value
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let target = "https://redirect.test/new-search"
        XCTAssertEqual(values["indexed"] as? String, target)
        XCTAssertEqual(values["get"] as? String, target)
        XCTAssertEqual(values["count"] as? Int, 1)
        XCTAssertEqual(values["missing"] as? Int, 0)
        XCTAssertEqual(values["header"] as? String, target)
        XCTAssertEqual(values["all"] as? String, target)
    }

    func testSourceProxyConfigurationAndUnsupportedModes() throws {
        let http = try XCTUnwrap(SourceProxy.parse("http://127.0.0.1:8765"))
        XCTAssertEqual(http.kind, .http)
        XCTAssertEqual(http.host, "127.0.0.1")
        XCTAssertEqual(http.port, 8765)
        XCTAssertFalse(http.networkProxy.allowFailover)
        XCTAssertEqual(try SourceProxy.parse("socks5://proxy.example:1080")?.kind, .socks5)
        XCTAssertNil(try SourceProxy.parse(" "))
        XCTAssertThrowsError(try SourceProxy.parse("socks4://proxy.example:1080"))
        let authenticated = try XCTUnwrap(SourceProxy.parse("http://proxy.example:8080@user@password"))
        XCTAssertEqual(authenticated.username, "user")
        XCTAssertEqual(authenticated.password, "password")
        XCTAssertThrowsError(try SourceProxy.parse("http://proxy.example:8080@user"))
        XCTAssertThrowsError(try SourceProxy.parse("https://proxy.example:8080"))
    }

    func testHTTPProxyRoutesSourceAndScriptRequestsWithoutLeakingHeader() async throws {
        let base = "http://readerproxy.invalid"
        let proxy = "http://127.0.0.1:8765"
        let req = try SourceHTTP.request(base + "/source-proxy-test", base: base,
                                         headers: ["pRoXy": proxy, "X-Fixture": "test"])
        XCTAssertNil(req.value(forHTTPHeaderField: "proxy"))
        XCTAssertEqual(try SourceProxy.configuration(for: req)?.host, "127.0.0.1")
        let page = try await SourceHTTP.load(req, stage: "代理测试")
        XCTAssertEqual(page.text, "proxy-routed:readerproxy.invalid")

        let scriptResult = try await Task.detached {
            try LegadoJSCtx.$headers.withValue(["proxy": proxy]) {
                let failures = RuleFailures()
                return try LegadoJSCtx.$failures.withValue(failures) {
                    let result = LegadoJS.run("java.ajax('http://readerproxy.invalid/source-proxy-test')", input: "", baseUrl: base,
                                             sourceKey: "", sourceUrl: base)
                    try failures.check()
                    return result
                }
            }
        }.value
        XCTAssertEqual(scriptResult, "proxy-routed:readerproxy.invalid")

        // A separate source without a proxy remains on the normal session.
        let direct = try SourceHTTP.request("http://127.0.0.1:8765/health", base: "http://127.0.0.1:8765")
        XCTAssertNil(try SourceProxy.configuration(for: direct))
        let directPage = try await SourceHTTP.load(direct, stage: "直接请求")
        XCTAssertEqual(directPage.text, "ready")
    }

    func testSOCKS5ProxyRoutesSourceRequest() async throws {
        let address = "http://192.0.2.1/source-proxy-test"
        var request = try SourceHTTP.request(address, base: address, headers: ["proxy": "socks5://127.0.0.1:8767"])
        request.timeoutInterval = 5
        XCTAssertNil(request.value(forHTTPHeaderField: "proxy"))
        XCTAssertEqual(try SourceProxy.configuration(for: request)?.kind, .socks5)
        let page = try await SourceHTTP.load(request, stage: "SOCKS5 代理测试")
        XCTAssertEqual(page.text, "socks5-routed")
        let authenticated = try SourceHTTP.request(address, base: address,
            headers: ["proxy": "socks5://127.0.0.1:8769@fixture-user@fixture-pass"])
        let authenticatedPage = try await SourceHTTP.load(authenticated, stage: "SOCKS5 认证测试")
        XCTAssertEqual(authenticatedPage.text, "socks5-routed")
    }

    func testHTTPSProxyUsesConnectAndPreservesCertificatePolicy() async throws {
        let address = "https://readerproxy.invalid/source-proxy-https-test"
        let request = try SourceHTTP.request(address, base: address, headers: ["proxy": "http://127.0.0.1:8765"])
        do {
            _ = try await SourceHTTP.load(request, stage: "HTTPS 代理测试")
            XCTFail("Untrusted fixture certificate must still be rejected through a proxy")
        } catch { /* expected self-signed certificate rejection */ }
        let page = try await SourceTLS.$allowsInvalidCertificates.withValue(true) {
            try await SourceHTTP.load(request, stage: "HTTPS 代理测试")
        }
        XCTAssertEqual(page.text, "https-proxy-routed")
    }

    func testAuthenticatedProxyAndNoDirectFallback() async throws {
        let target = "http://readerproxy.invalid/source-proxy-test"
        let request = try SourceHTTP.request(target, base: target,
                                             headers: ["proxy": "http://127.0.0.1:8768@fixture-user@fixture-pass"])
        let page = try await SourceHTTP.load(request, stage: "认证代理测试")
        XCTAssertEqual(page.text, "proxy-routed:readerproxy.invalid")

        // A failed proxy must not fall back to the reachable direct endpoint.
        let directTarget = "http://127.0.0.1:8765/health"
        var badProxy = try SourceHTTP.request(directTarget, base: directTarget, headers: ["proxy": "http://127.0.0.1:1"])
        badProxy.timeoutInterval = 3
        do {
            _ = try await SourceHTTP.load(badProxy, stage: "代理回退测试")
            XCTFail("Failed proxy must not fall back to direct connection")
        } catch { /* expected failed proxy */ }
    }

    @MainActor func testWebViewUsesIsolatedSourceProxy() async throws {
        let target = "http://readerproxy.invalid/source-proxy-test"
        let request = try SourceHTTP.request(target, base: target, headers: ["proxy": "http://127.0.0.1:8765"])
        let page = try await SourceWebLoader.load(request, timeout: 15)
        XCTAssertTrue(page.text.contains("proxy-routed:readerproxy.invalid"), page.text)
        let direct = try SourceHTTP.request("http://127.0.0.1:8765/web-script", base: "http://127.0.0.1:8765")
        let directPage = try await SourceWebLoader.load(direct, timeout: 15, delay: 0.6)
        XCTAssertTrue(directPage.text.contains("网页脚本正文"), directPage.text)
    }
}
