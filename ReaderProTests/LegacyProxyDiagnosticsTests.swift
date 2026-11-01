#if READERPRO_PROXY_DIAGNOSTICS
import Foundation
import XCTest
@testable import ReaderPro

// Opt-in experiment only. The production implementation uses Network's
// proxyConfigurations; this evaluates the older CFNetwork session settings.
private final class LegacyProxyDiagnosticDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let proxyPort: Int
    private let lock = NSLock()
    private var matched = 0
    private var received: [String] = []

    init(proxyPort: Int) { self.proxyPort = proxyPort }
    var report: (Int, [String]) {
        lock.lock(); defer { lock.unlock() }
        return (matched, received)
    }

    private func respond(_ challenge: URLAuthenticationChallenge,
                         completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        lock.lock()
        received.append("proxy=\(space.isProxy()) host=\(space.host) port=\(space.port) method=\(space.authenticationMethod) attempt=\(challenge.previousFailureCount)")
        lock.unlock()
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           (space.host == "readerproxy.invalid" || (space.host == "127.0.0.1" && space.port == 8766)),
           let trust = space.serverTrust {
            completion(.useCredential, URLCredential(trust: trust))
        } else if space.isProxy(), space.host == "127.0.0.1", space.port == proxyPort,
                  challenge.previousFailureCount == 0 {
            lock.lock(); matched += 1; lock.unlock()
            completion(.useCredential, URLCredential(user: "fixture-user", password: "fixture-pass", persistence: .none))
        } else {
            completion(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        respond(challenge, completion: completionHandler)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        respond(challenge, completion: completionHandler)
    }
}

final class LegacyProxyDiagnosticsTests: XCTestCase {
    private func probeAuthenticatedProxy(port: Int) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port]
        config.urlCredentialStorage = nil
        let delegate = LegacyProxyDiagnosticDelegate(proxyPort: port)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://readerproxy.invalid/source-proxy-https-test")!)
        request.timeoutInterval = 6
        do {
            let (data, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "challenges: \(delegate.report.1)")
            XCTAssertEqual(String(data: data, encoding: .utf8), "https-proxy-routed", "Destination must not receive proxy credentials")
            XCTAssertGreaterThan(delegate.report.0, 0, "Expected a matching proxy challenge; got \(delegate.report.1)")
        } catch {
            XCTFail("Legacy HTTPS proxy on port \(port) failed: \(sourceErrorMessage(error)); challenges: \(delegate.report.1)")
        }
    }

    func testHTTP10AuthenticationChallenge() async throws { try await probeAuthenticatedProxy(port: 8768) }
    func testHTTP11AuthenticationChallenge() async throws { try await probeAuthenticatedProxy(port: 8770) }

    func testFailedLegacyProxyDoesNotConnectDirectly() async throws {
        let directConfig = URLSessionConfiguration.ephemeral
        directConfig.connectionProxyDictionary = [:]
        let directSession = URLSession(configuration: directConfig, delegate: LegacyProxyDiagnosticDelegate(proxyPort: 1), delegateQueue: nil)
        defer { directSession.invalidateAndCancel() }
        let address = URL(string: "https://127.0.0.1:8766/source-proxy-https-test")!
        let (directData, directResponse) = try await directSession.data(from: address)
        XCTAssertEqual((directResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: directData, encoding: .utf8), "https-proxy-routed", "The direct endpoint must be reachable before testing fallback")

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 1]
        config.urlCredentialStorage = nil
        let delegate = LegacyProxyDiagnosticDelegate(proxyPort: 1)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: address)
        request.timeoutInterval = 4
        do {
            _ = try await session.data(for: request)
            XCTFail("Broken proxy was bypassed and reachable TLS destination was contacted directly")
        } catch { /* Failure is required; an unproxied request would succeed. */ }
    }
}
#endif
