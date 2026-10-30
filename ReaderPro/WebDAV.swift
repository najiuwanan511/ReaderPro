import Foundation

// MARK: - WebDAV 客户端（云备份：坚果云 / Nextcloud / 自建 WebDAV 通用）

struct WebDAVClient {
    let baseURL: String
    let username: String
    let password: String

    private func authHeader() -> String? {
        guard !username.isEmpty else { return nil }
        let cred = "\(username):\(password)"
        guard let data = cred.data(using: .utf8) else { return nil }
        return "Basic " + data.base64EncodedString()
    }

    private func fullURL(_ path: String) -> URL? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base), !base.isEmpty else { return nil }
        let comps = p.split(separator: "/").map { String($0) }
        var url = baseURL
        for c in comps where !c.isEmpty {
            url.appendPathComponent(c)
        }
        return url
    }

    private func request(_ url: URL, method: String, body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = method
        if let body = body { req.httpBody = body }
        if let auth = authHeader() { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        return req
    }

    func mkdir(_ path: String) async throws {
        guard let url = fullURL(path) else {
            throw NSError(domain: "webdav", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebDAV 地址无效"])
        }
        let (_, resp) = try await URLSession.shared.data(for: request(url, method: "MKCOL"))
        // 201 创建成功；405 已存在；其余 2xx 也算成功
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode), http.statusCode != 405 {
            // 目录创建失败不致命（有的服务端会拒绝 MKCOL），忽略，交给 PUT 判断
        }
    }

    func upload(data: Data, to path: String) async throws {
        guard let url = fullURL(path) else {
            throw NSError(domain: "webdav", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebDAV 地址无效"])
        }
        // 尽力确保父目录存在
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty && parent != "/" && parent != "." { try? await mkdir(parent) }
        let (_, resp) = try await URLSession.shared.data(for: request(url, method: "PUT", body: data))
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "webdav", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "上传失败（HTTP \(http.statusCode)），请检查地址、账号和目录权限"])
        }
    }

    func download(from path: String) async throws -> Data {
        guard let url = fullURL(path) else {
            throw NSError(domain: "webdav", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebDAV 地址无效"])
        }
        let (data, resp) = try await URLSession.shared.data(for: request(url, method: "GET"))
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "webdav", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "下载失败（HTTP \(http.statusCode)），请确认远程路径有备份文件"])
        }
        return data
    }
}
