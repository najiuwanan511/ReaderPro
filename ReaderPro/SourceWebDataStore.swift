import Foundation
import WebKit
import Darwin
import Network

@MainActor enum SourceWebDataStore {
    private static var localRules: (String, Task<WKContentRuleList?, Error>)?

    static func normalizedHost(_ host: String) -> String {
        let value = (host.removingPercentEncoding ?? host).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .components(separatedBy: "%")[0].lowercased()
        return IPv6Address(value)?.debugDescription ?? value
    }

    static func deviceHosts() -> Set<String> {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces, hosts = Set<String>()
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                hosts.insert(normalizedHost(String(cString: buffer)))
            }
        }
        return hosts
    }

    static func isDeviceHost(_ host: String) -> Bool {
        let value = normalizedHost(host)
        return value == "localhost" || value.hasSuffix(".localhost") || value.hasPrefix("127.") || value == "::1" || deviceHosts().contains(value)
    }

    static func cookies(for request: URLRequest, sourceURL: String? = nil, available: [HTTPCookie]? = nil) -> [HTTPCookie] {
        let hosts = [request.url?.host, URL(string: sourceURL ?? "")?.host].compactMap { $0?.lowercased() }
        // Do not issue an IPC write for every cookie from thousands of other
        // sources before loading this page. Include every path on the current
        // domains, so navigation to /login or /api keeps its scoped cookies.
        return (available ?? HTTPCookieStorage.shared.cookies ?? []).filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return !domain.isEmpty && hosts.contains { $0 == domain || $0.hasSuffix("." + domain) }
        }
    }
    static func make(request: URLRequest, ephemeral: Bool = false) throws -> WKWebsiteDataStore {
        let proxy = try SourceProxy.configuration(for: request)
        // Never change proxy settings on a shared default store: an unrelated
        // source or an in-flight login must keep its own transport.
        let store: WKWebsiteDataStore = ephemeral || proxy != nil ? .nonPersistent() : .default()
        if proxy != nil { try configure(store, request: request) }
        return store
    }

    static func configure(_ store: WKWebsiteDataStore, request: URLRequest) throws {
        let proxy = try SourceProxy.configuration(for: request)
        if proxy != nil, let host = request.url?.host, isDeviceHost(host) {
            // WebKit ignores proxy routing for this device's own addresses,
            // including its routable interface IPs, even with failover
            // disabled. Refuse that unsupported destination instead of letting
            // an explicitly proxied request connect directly.
            throw SourceFailure(stage: "书源代理", message: "系统网页引擎不能通过书源代理访问本机地址")
        }
        guard RPSetWebProxy(store, proxy?.host, UInt16(proxy?.port ?? 0), proxy?.kind == .socks5,
                            proxy?.username, proxy?.password) else {
            throw SourceFailure(stage: "书源代理", message: "无法配置网页代理")
        }
    }
    static func preventLocalBypass(_ configuration: WKWebViewConfiguration, request: URLRequest) async throws {
        guard try SourceProxy.configuration(for: request) != nil else { return }
        let hosts = deviceHosts().sorted(), signature = hosts.joined(separator: ",")
        if localRules?.0 != signature {
            localRules = (signature, Task {
                // Content blockers accept a smaller regex language than ICU;
                // separate alternatives instead of using unsupported '|'.
                var patterns = ["^https?://localhost[:/]", "^https?://[a-z0-9.-]+[.]localhost[:/]",
                                "^https?://127[.][0-9.]+[:/]", #"^https?://\[::1\]"#,
                                #"^https?://\[0:0:0:0:0:0:0:1\]"#]
                patterns += hosts.map { host in
                    host.contains(":") ? #"^https?://\["# + host + #"[%a-z0-9]*\]"# : "^https?://" + host.replacingOccurrences(of: ".", with: "[.]") + "[:/]"
                }
                let entries = patterns.map { ["trigger": ["url-filter": $0, "url-filter-is-case-sensitive": false], "action": ["type": "block"]] as [String: Any] }
                let rules = String(decoding: try JSONSerialization.data(withJSONObject: entries), as: UTF8.self)
                return try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "ReaderPro.proxyNoLocalBypass", encodedContentRuleList: rules)
            })
        }
        do {
            if let rules = try await localRules?.1.value { configuration.userContentController.add(rules) }
        } catch { if localRules?.0 == signature { localRules = nil }; throw error }
    }
}
