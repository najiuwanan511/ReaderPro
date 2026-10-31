import Foundation
import Security
import CryptoKit

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
        init(allow: Bool, redirects: Bool) { self.allow = allow; self.redirects = redirects }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if allow, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: trust)) }
            else { completionHandler(.performDefaultHandling, nil) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(redirects ? request : nil)
        }
    }
    private static func makeSession(allow: Bool, redirects: Bool) -> URLSession {
        URLSession(configuration: SourceHTTP.configuration(), delegate: Delegate(allow: allow, redirects: redirects), delegateQueue: nil)
    }
    private static let legacy = makeSession(allow: true, redirects: true)
    private static let legacyDirect = makeSession(allow: true, redirects: false)
    private static let strictDirect = makeSession(allow: false, redirects: false)
    static func session(followRedirects: Bool = true) -> URLSession {
        if let test = SourceHTTP.testSession { return test }
        if allowsInvalidCertificates { return followRedirects ? legacy : legacyDirect }
        return followRedirects ? SourceHTTP.session : strictDirect
    }
}
