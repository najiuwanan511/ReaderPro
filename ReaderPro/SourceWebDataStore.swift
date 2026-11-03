import Foundation
import WebKit

@MainActor enum SourceWebDataStore {
    private static var loopbackRules: Task<WKContentRuleList?, Error>?
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
        if proxy != nil, let host = request.url?.host?.lowercased(),
           host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("127.") || ["::1", "[::1]", "0:0:0:0:0:0:0:1"].contains(host) {
            // WebKit ignores proxy routing for loopback even with failover
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
        if loopbackRules == nil {
            loopbackRules = Task {
                let rules = #"[{"trigger":{"url-filter":"^https?://(localhost|[a-z0-9.-]+\\.localhost|127\\.[0-9.]+|\\[::1\\])([:/]|$)","url-filter-is-case-sensitive":false},"action":{"type":"block"}}]"#
                return try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "ReaderPro.proxyNoLocalBypass", encodedContentRuleList: rules)
            }
        }
        if let rules = try await loopbackRules?.value { configuration.userContentController.add(rules) }
    }
}
