import XCTest
import CryptoKit
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
        let fixture = source
        let headers = try await withTimeout(10) {
            try await fixture.withRules { LegadoJSCtx.headers }
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
        let fixture = source
        let headers = try await withTimeout(10) {
            try await fixture.withRules { LegadoJSCtx.headers }
        }
        XCTAssertTrue(headers.isEmpty)
    }

    func testAtJSAndPlainHeadersRemainSupported() async throws {
        var source = LegadoSource()
        source.bookSourceUrl = "https://example.test"
        source.header = "@js:JSON.stringify({'Referer': baseUrl, 'X-Test': 'ok'})"
        let scriptedSource = source
        let scripted = try await withTimeout(10) { try await scriptedSource.withRules { LegadoJSCtx.headers } }
        XCTAssertEqual(scripted["Referer"], "https://example.test")
        XCTAssertEqual(scripted["X-Test"], "ok")
        source.header = #"{"Accept":"text/html"}"#
        let plainSource = source
        let plain = try await withTimeout(10) { try await plainSource.withRules { LegadoJSCtx.headers } }
        XCTAssertEqual(plain["Accept"], "text/html")
    }

    func testJavaGetResponseHeadersByNameSupportRedirectRules() async throws {
        let output = try await Task.detached {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HeaderResponseProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            return try SourceHTTP.$testSession.withValue(session) {
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

    #if DEBUG || READERPRO_TESTING
    func testLoginHeaderFallbackWhenKeychainEntitlementIsMissing() throws {
        let source = "https://fallback-\(UUID().uuidString).example"
        let other = "https://other-\(UUID().uuidString).example"
        let account = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let folder = root.appendingPathComponent("SourceLoginHeaders", isDirectory: true)
        let stored = folder.appendingPathComponent(account)
        defer { try? SourceLoginHeaders.testPurgeFallback(source) }
        try SourceLoginHeaders.$testForceMissingEntitlement.withValue(true) {
            try SourceLoginHeaders.put(#"{"Authorization":"fixture-secret"}"#, source: source)
            XCTAssertEqual(SourceLoginHeaders.map(source)?["Authorization"], "fixture-secret")
            XCTAssertNil(SourceLoginHeaders.get(other))
            XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
            let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: stored.path)[.posixPermissions] as? Int)
            XCTAssertEqual(permissions & 0o077, 0, "Fallback file must not be accessible to other users")
            try SourceLoginHeaders.put(#"{"Authorization":"updated"}"#, source: source)
            XCTAssertEqual(SourceLoginHeaders.map(source)?["Authorization"], "updated")
        }
        // A new context must read the protected fallback even if Keychain
        // later becomes available again.
        XCTAssertEqual(SourceLoginHeaders.map(source)?["Authorization"], "updated")
        try SourceLoginHeaders.$testForceMissingEntitlement.withValue(true) { try SourceLoginHeaders.remove(source) }
        XCTAssertNil(SourceLoginHeaders.get(source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
        SourceLoginHeaders.$testKeychainReadValue.withValue(#"{"Authorization":"old-keychain-token"}"#) {
            XCTAssertNil(SourceLoginHeaders.get(source), "Deleting without entitlement must suppress stale Keychain values after access returns")
        }
        try SourceLoginHeaders.$testForceMissingEntitlement.withValue(true) {
            try SourceLoginHeaders.put(#"{"Authorization":"new-token"}"#, source: source)
        }
        SourceLoginHeaders.$testKeychainReadValue.withValue(#"{"Authorization":"old-keychain-token"}"#) {
            XCTAssertEqual(SourceLoginHeaders.map(source)?["Authorization"], "new-token", "A new login must replace the deletion marker")
        }
    }
    #endif

    func testSourceLoginHeaderPersistenceIsolationAndImmediateAjax() async throws {
        let base = "http://127.0.0.1:8765"
        let identity = base + "/login-" + UUID().uuidString
        let otherIdentity = base + "/other-" + UUID().uuidString
        defer {
            try? SourceLoginHeaders.remove(identity)
            try? SourceLoginHeaders.remove(otherIdentity)
            #if DEBUG || READERPRO_TESTING
            try? SourceLoginHeaders.testPurgeFallback(identity)
            try? SourceLoginHeaders.testPurgeFallback(otherIdentity)
            #endif
            if let url = URL(string: identity) {
                for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] where cookie.name == "fixturelogin" {
                    HTTPCookieStorage.shared.deleteCookie(cookie)
                }
            }
        }
        let result = await Task.detached {
            let failures = RuleFailures()
            let script = #"""
            if(source.getLoginHeader()!==null || source.getLoginHeaderMap()!==null) throw Error('initial state');
            source.putLoginHeader(JSON.stringify({Authorization:'Bearer fixture-token',Cookie:'fixturelogin=ready','X-Login':'stored'}));
            var stored=JSON.parse(source.getLoginHeader()), map=source.getLoginHeaderMap();
            if(stored.Authorization!=='Bearer fixture-token' || map.get('X-Login')!=='stored' || map.Cookie!=='fixturelogin=ready') throw Error('login header read');
            var immediate=JSON.parse(java.ajax(baseUrl+'/bridge-login-check'));
            if(immediate.authorization!=='Bearer fixture-token' || immediate.cookie.indexOf('fixturelogin=ready')<0 || immediate.custom!=='stored') throw Error('immediate ajax');
            var explicit=JSON.parse(java.connect(baseUrl+'/bridge-login-check', {authorization:'explicit'}).body());
            if(explicit.authorization!=='explicit') throw Error('explicit request headers must win');
            'ok';
            """#
            let value = LegadoJSCtx.$failures.withValue(failures) {
                LegadoJS.run(script, input: "", baseUrl: base, sourceKey: "", sourceUrl: identity,
                             header: ["authorization": "base"])
            }
            do { try failures.check(); return value } catch { return sourceErrorMessage(error) }
        }.value
        XCTAssertEqual(result, "ok")
        XCTAssertNotNil(SourceLoginHeaders.get(identity), "Login header must persist between script contexts")
        XCTAssertNil(SourceLoginHeaders.get(otherIdentity), "Another source must not inherit credentials")
        var source = LegadoSource()
        source.bookSourceUrl = identity
        source.header = #"{"authorization":"base","X-Base":"kept"}"#
        XCTAssertEqual(source.requestHeaders.first { $0.key.lowercased() == "authorization" }?.value, "Bearer fixture-token")
        XCTAssertEqual(source.requestHeaders["X-Base"], "kept")
        let removed = await Task.detached {
            LegadoJS.run("source.removeLoginHeader(); source.getLoginHeader()===null && source.getLoginHeaderMap()===null ? 'ok' : 'failed'",
                         input: "", baseUrl: base, sourceKey: "", sourceUrl: identity)
        }.value
        XCTAssertEqual(removed, "ok")
        XCTAssertNil(SourceLoginHeaders.get(identity))
        XCTAssertFalse((HTTPCookieStorage.shared.cookies(for: URL(string: identity)!) ?? []).contains { $0.name == "fixturelogin" })
        XCTAssertEqual(source.requestHeaders["authorization"], "base")
        try SourceLoginHeaders.put("{malformed", source: identity)
        XCTAssertEqual(SourceLoginHeaders.get(identity), "{malformed", "Android preserves the original header even if it cannot be parsed")
        XCTAssertNil(SourceLoginHeaders.map(identity))
        XCTAssertEqual(source.requestHeaders["authorization"], "base")
        try SourceLoginHeaders.put(#"{"Authorization":"replacement"}"#, source: identity)
        XCTAssertEqual(source.requestHeaders.first { $0.key.lowercased() == "authorization" }?.value, "replacement")
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

    func testAuthenticatedPlainHTTPProxyIsRejectedWithoutDirectFallback() async throws {
        // This address is reachable directly: a request that escapes the
        // configured proxy would succeed rather than raise our explicit error.
        let target = "http://127.0.0.1:8765/health"
        let request = try SourceHTTP.request(target, base: target,
                                             headers: ["proxy": "http://127.0.0.1:8768@fixture-user@fixture-pass"])
        do {
            _ = try await SourceHTTP.load(request, stage: "认证代理测试")
            XCTFail("Unsupported authenticated HTTP proxy must not connect directly")
        } catch {
            XCTAssertTrue(sourceErrorMessage(error).contains("暂不支持需要认证的 HTTP 明文代理请求"), sourceErrorMessage(error))
        }
    }

    private func verifyAuthenticatedHTTPSProxy(port: Int) async throws {
        let target = "https://readerproxy.invalid/source-proxy-https-test"
        let request = try SourceHTTP.request(target, base: target,
            headers: ["proxy": "http://127.0.0.1:\(port)@fixture-user@fixture-pass"])
        if #available(iOS 18.0, *) {
            let page = try await SourceTLS.$allowsInvalidCertificates.withValue(true) {
                try await SourceHTTP.load(request, stage: "HTTPS 认证代理测试")
            }
            // The TLS fixture responds 400 if credentials reach the target.
            XCTAssertEqual(page.text, "https-proxy-routed")
        } else {
            do {
                _ = try await SourceTLS.$allowsInvalidCertificates.withValue(true) {
                    try await SourceHTTP.load(request, stage: "HTTPS 认证代理测试")
                }
                XCTFail("iOS 17 unexpectedly authenticated; re-evaluate this known limitation")
            } catch {
                let description = sourceErrorMessage(error)
                XCTAssertTrue(description.contains("iOS 17 未能完成 HTTP 代理认证"), description)
                XCTAssertTrue(description.contains("NSPOSIXErrorDomain 80"), description)
                XCTAssertFalse(description.contains("fixture-pass"), description)
            }
        }
    }

    func testAuthenticatedHTTPSProxyDoesNotLeakCredentials() async throws { try await verifyAuthenticatedHTTPSProxy(port: 8768) }

    func testAuthenticatedHTTPSProxyWithPersistentHTTP11Challenge() async throws { try await verifyAuthenticatedHTTPSProxy(port: 8770) }

    func testProxyAuthenticationErrorPreservesSystemContext() throws {
        let target = "https://readerproxy.invalid/source-proxy-https-test"
        let request = try SourceHTTP.request(target, base: target,
            headers: ["proxy": "http://127.0.0.1:8768@fixture-user@fixture-pass"])
        let original = NSError(domain: NSPOSIXErrorDomain, code: 80,
                               userInfo: [NSLocalizedDescriptionKey: "fixture authentication error"])
        let result = SourceTLS.contextualizeProxyError(original, request: request)
        if #available(iOS 18.0, *) {
            XCTAssertEqual((result as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((result as NSError).code, 80)
        } else {
            let description = sourceErrorMessage(result)
            XCTAssertTrue(description.contains("iOS 17 未能完成 HTTP 代理认证"), description)
            XCTAssertTrue(description.contains("NSPOSIXErrorDomain 80"), description)
            XCTAssertTrue(description.contains("fixture authentication error"), description)
            XCTAssertFalse(description.contains("fixture-pass"), description)
        }
        let timeout = URLError(.timedOut)
        XCTAssertEqual((SourceTLS.contextualizeProxyError(timeout, request: request) as NSError).code, NSURLErrorTimedOut)
        let direct = try SourceHTTP.request(target, base: target)
        XCTAssertEqual((SourceTLS.contextualizeProxyError(original, request: direct) as NSError).domain, NSPOSIXErrorDomain)
    }

    func testFailedProxyAndCrossSchemeRedirectNeverFallBackDirectly() async throws {
        // A failed proxy must not fall back to the reachable direct endpoint.
        let directTarget = "http://127.0.0.1:8765/health"
        var badProxy = try SourceHTTP.request(directTarget, base: directTarget, headers: ["proxy": "http://127.0.0.1:1"])
        badProxy.timeoutInterval = 3
        do {
            _ = try await SourceHTTP.load(badProxy, stage: "代理回退测试")
            XCTFail("Failed proxy must not fall back to direct connection")
        } catch { /* expected failed proxy */ }

        // The two schemes use different iOS proxy transports; never follow a
        // cross-scheme redirect on a session that could connect directly.
        let cross = try SourceHTTP.request("http://readerproxy.invalid/source-proxy-cross-scheme", base: "http://readerproxy.invalid",
                                           headers: ["proxy": "http://127.0.0.1:8765"])
        do {
            _ = try await SourceHTTP.load(cross, stage: "代理跳转测试")
            XCTFail("Proxy redirects must not silently switch transports")
        } catch {
            XCTAssertTrue(sourceErrorMessage(error).contains("跨 HTTP/HTTPS 跳转"), sourceErrorMessage(error))
        }
    }

    @MainActor func testWebViewRejectsProxyWithoutFallingBackDirectly() async throws {
        let target = "http://readerproxy.invalid/source-proxy-test"
        let request = try SourceHTTP.request(target, base: target, headers: ["proxy": "http://127.0.0.1:8765"])
        do {
            _ = try await SourceWebLoader.load(request, timeout: 5)
            XCTFail("WebView must never silently bypass an unsupported source proxy")
        } catch {
            XCTAssertTrue(sourceErrorMessage(error).contains("网页渲染暂不支持该代理"), sourceErrorMessage(error))
        }
        let direct = try SourceHTTP.request("http://127.0.0.1:8765/web-script", base: "http://127.0.0.1:8765")
        let directPage = try await SourceWebLoader.load(direct, timeout: 15, delay: 0.6)
        XCTAssertTrue(directPage.text.contains("网页脚本正文"), directPage.text)
    }
}
