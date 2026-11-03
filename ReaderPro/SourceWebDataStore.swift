import Foundation
import WebKit

@MainActor enum SourceWebDataStore {
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
        guard RPSetWebProxy(store, proxy?.host, UInt16(proxy?.port ?? 0), proxy?.kind == .socks5,
                            proxy?.username, proxy?.password) else {
            throw SourceFailure(stage: "书源代理", message: "无法配置网页代理")
        }
    }
}
