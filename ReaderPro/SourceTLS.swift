import Foundation
import Security
import CryptoKit
import Network
import CFNetwork

// Legado's `proxy` source-header entry controls the client, not an HTTP
// request header. Store it in URLProtocol metadata so it can never leak to
// the remote site, and create a session scoped to that one request.
enum SourceProxy {
    private static let propertyKey = "ReaderPro.sourceProxy"

    struct Configuration: Equatable {
        enum Kind: Equatable { case http, socks5 }
        let kind: Kind
        let host: String
        let port: Int
        let username: String?
        let password: String?

        // All supported platforms start at iOS 17, where Network exposes
        // per-session HTTP CONNECT and SOCKS5 proxies as public APIs.
        var networkProxy: ProxyConfiguration {
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!)
            var result: ProxyConfiguration
            switch kind {
            case .http:
                result = ProxyConfiguration(httpCONNECTProxy: endpoint)
            case .socks5:
                result = ProxyConfiguration(socksv5Proxy: endpoint)
            }
            // A configured book-source proxy must never silently fall back to
            // a direct connection after a proxy failure.
            result.allowFailover = false
            if let username, let password { result.applyCredential(username: username, password: password) }
            return result
        }
    }

    static func parse(_ value: String) throws -> Configuration? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        // Android's syntax places optional credentials after the port as
        // `http://host:port@username@password`, not URL userinfo syntax.
        let parts = raw.components(separatedBy: "@")
        guard parts.count == 1 || (parts.count == 3 && !parts[1].isEmpty && !parts[2].isEmpty) else {
            throw SourceFailure(stage: "书源代理", message: "代理账号格式无效")
        }
        guard let components = URLComponents(string: parts[0]), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty, let port = components.port,
              (1...65535).contains(port), components.path.isEmpty,
              components.query == nil, components.fragment == nil else {
            throw SourceFailure(stage: "书源代理", message: "代理地址格式无效，请使用 http://主机:端口 或 socks5://主机:端口")
        }
        let username = parts.count == 3 ? parts[1] : nil
        let password = parts.count == 3 ? parts[2] : nil
        switch scheme {
        case "http": return Configuration(kind: .http, host: host, port: port, username: username, password: password)
        case "socks5": return Configuration(kind: .socks5, host: host, port: port, username: username, password: password)
        case "socks4": throw SourceFailure(stage: "书源代理", message: "暂不支持 SOCKS4 代理")
        default: throw SourceFailure(stage: "书源代理", message: "不支持的代理类型：\(scheme)")
        }
    }

    static func attach(_ raw: String?, to request: URLRequest) throws -> URLRequest {
        guard let raw, try parse(raw) != nil else { return request }
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            throw SourceFailure(stage: "书源代理", message: "无法设置请求代理")
        }
        URLProtocol.setProperty(raw, forKey: propertyKey, in: mutable)
        return mutable as URLRequest
    }

    static func configuration(for request: URLRequest) throws -> Configuration? {
        guard let raw = URLProtocol.property(forKey: propertyKey, in: request) as? String else { return nil }
        return try parse(raw)
    }
}

// A local, explicit choice per source. An imported JSON cannot opt the user
// into ignoring certificates, and WebDAV/backups keep their normal trust policy.
enum SourceTLS {
    @TaskLocal static var allowsInvalidCertificates = false
    private static let lock = NSLock()
    private static var preferences: [String: Bool] = [:]

    private static func preferenceKey(_ sourceURL: String) -> String {
        "ReaderPro.sourceTLS." + SHA256.hash(data: Data(sourceURL.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func isAllowed(_ sourceURL: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let cached = preferences[sourceURL] { return cached }
        let allowed = UserDefaults.standard.bool(forKey: preferenceKey(sourceURL))
        preferences[sourceURL] = allowed
        return allowed
    }
    static func setAllowed(_ allowed: Bool, for sourceURL: String) {
        lock.lock(); defer { lock.unlock() }
        preferences[sourceURL] = allowed
        UserDefaults.standard.set(allowed, forKey: preferenceKey(sourceURL))
    }

    private final class Delegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let allow: Bool
        let redirects: Bool
        let proxy: SourceProxy.Configuration?
        init(allow: Bool, redirects: Bool, proxy: SourceProxy.Configuration? = nil) {
            self.allow = allow; self.redirects = redirects; self.proxy = proxy
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            #if DEBUG || READERPRO_TESTING
            if proxy != nil {
                print("SOURCE_PROXY_CHALLENGE isProxy=\(challenge.protectionSpace.isProxy()) method=\(challenge.protectionSpace.authenticationMethod) attempt=\(challenge.previousFailureCount)")
            }
            #endif
            if allow, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: trust)) }
            else if let proxy, let username = proxy.username, let password = proxy.password,
                    challenge.protectionSpace.isProxy(),
                    challenge.protectionSpace.host.caseInsensitiveCompare(proxy.host) == .orderedSame,
                    challenge.protectionSpace.port == proxy.port,
                    challenge.previousFailureCount == 0 {
                // Credentials only answer the configured proxy's challenge,
                // never a destination server's authentication challenge.
                completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
            }
            else { completionHandler(.performDefaultHandling, nil) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            // HTTP and HTTPS use different iOS proxy transports. A cross-
            // scheme redirect must not silently escape the configured proxy.
            let changesScheme = response.url?.scheme?.lowercased() != request.url?.scheme?.lowercased()
            completionHandler(redirects && !(proxy?.kind == .http && changesScheme) ? request : nil)
        }
    }
    private static func makeSession(allow: Bool, redirects: Bool, proxy: SourceProxy.Configuration? = nil,
                                    scheme: String = "") -> URLSession {
        let configuration = SourceHTTP.configuration()
        if let proxy {
            if proxy.kind == .http && scheme.lowercased() == "http" {
                // On iOS 17 proxyConfigurations CONNECT works for HTTPS, but
                // does not route plain HTTP. Use Apple's supported HTTP keys.
                var settings: [AnyHashable: Any] = ["HTTPEnable": 1, "HTTPProxy": proxy.host, "HTTPPort": proxy.port]
                // These public CFNetwork keys identify proxy credentials; do
                // not attach Proxy-Authorization to the destination request.
                if let username = proxy.username, let password = proxy.password {
                    settings[kCFProxyUsernameKey as String] = username
                    settings[kCFProxyPasswordKey as String] = password
                }
                configuration.connectionProxyDictionary = settings
            } else {
                configuration.proxyConfigurations = [proxy.networkProxy]
            }
        }
        return URLSession(configuration: configuration, delegate: Delegate(allow: allow, redirects: redirects, proxy: proxy), delegateQueue: nil)
    }
    private static let legacy = makeSession(allow: true, redirects: true)
    private static let legacyDirect = makeSession(allow: true, redirects: false)
    private static let strictDirect = makeSession(allow: false, redirects: false)
    static func session(followRedirects: Bool = true) -> URLSession {
        if let test = SourceHTTP.testSession { return test }
        if allowsInvalidCertificates { return followRedirects ? legacy : legacyDirect }
        return followRedirects ? SourceHTTP.session : strictDirect
    }

    struct Lease {
        let session: URLSession
        let owned: Bool
        func finish() { if owned { session.finishTasksAndInvalidate() } }
    }

    static func lease(for request: URLRequest, followRedirects: Bool = true) throws -> Lease {
        let proxy = try SourceProxy.configuration(for: request)
        // Preserve the existing test-injection semantics. A test-provided
        // URLSession captures the request without contacting real proxies.
        if let test = SourceHTTP.testSession { return Lease(session: test, owned: false) }
        if let proxy {
            return Lease(session: makeSession(allow: allowsInvalidCertificates, redirects: followRedirects,
                                              proxy: proxy, scheme: request.url?.scheme ?? ""), owned: true)
        }
        return Lease(session: session(followRedirects: followRedirects), owned: false)
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let lease = try lease(for: request)
        defer { lease.finish() }
        return try await lease.session.data(for: request)
    }
}
