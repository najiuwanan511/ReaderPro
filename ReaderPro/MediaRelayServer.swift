import Foundation
import Network

// AVPlayer does not honor URLProtocol metadata or the source's TLS delegate.
// A loopback relay keeps those requests in SourceTLS, including HLS children,
// while streaming bounded chunks instead of downloading a movie into memory.
actor MediaRelayServer {
    static let shared = MediaRelayServer()
    private struct Context {
        let template: URLRequest
        let source: LegadoSource?
        let allowInvalidTLS: Bool
        var requests: [String: URLRequest] = [:]
        var playlists: [String: String] = [:]
    }
    private let queue = DispatchQueue(label: "ReaderPro.mediaRelay")
    private var listener: NWListener?
    private var startup: Task<UInt16, Error>?
    private var contexts: [String: Context] = [:]
    private var order: [String] = []
    func register(_ request: URLRequest, manifest: DashManifest? = nil) async throws -> URL {
        let port = try await start(), token = UUID().uuidString
        contexts[token] = Context(template: request, source: LegadoJSCtx.ruleSource, allowInvalidTLS: SourceTLS.allowsInvalidCertificates)
        order.append(token)
        while order.count > 32 { contexts[order.removeFirst()] = nil }
        if let manifest {
            let base = URL(string: "http://127.0.0.1:\(port)/\(token)/")!
            for (name, text) in manifest.playlists {
                let rewritten = try rewrite(text, base: request.url!, token: token, port: port, generated: Set(manifest.playlists.keys))
                contexts[token]?.playlists[name] = rewritten
            }
            return base.appendingPathComponent("master.m3u8")
        }
        return try address(request.url!, token: token, port: port)
    }
    private func address(_ url: URL, token: String, port: UInt16) throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let context = contexts[token], context.requests.count < 20000 else {
            throw SourceFailure(stage: "媒体请求", message: "媒体地址无效或清单分段过多")
        }
        let ext = url.pathExtension.lowercased()
        let suffix = ext.range(of: "^[a-z0-9]{1,8}$", options: .regularExpression) != nil ? ext : "bin"
        let name = MediaDiskCache.hash(url.absoluteString) + "." + suffix
        var request = context.template; request.url = url
        contexts[token]?.requests[name] = request
        return URL(string: "http://127.0.0.1:\(port)/\(token)/\(name)")!
    }
    private func rewrite(_ text: String, base: URL, token: String, port: UInt16, generated: Set<String> = []) throws -> String {
        let regex = try NSRegularExpression(pattern: #"URI="([^"]+)""#)
        func local(_ value: String) throws -> String {
            if generated.contains(value) { return "http://127.0.0.1:\(port)/\(token)/" + value }
            guard let url = URL(string: value, relativeTo: base)?.absoluteURL else { throw URLError(.badURL) }
            return try address(url, token: token, port: port).absoluteString
        }
        return try text.components(separatedBy: .newlines).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return line }
            if !trimmed.hasPrefix("#") { return try local(trimmed) }
            var result = line
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                let value = try local((line as NSString).substring(with: match.range(at: 1)))
                result = (result as NSString).replacingCharacters(in: match.range(at: 1), with: value)
            }
            return result
        }.joined(separator: "\n")
    }
    private func start() async throws -> UInt16 {
        if let startup { return try await startup.value }
        let task = Task<UInt16, Error> {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let server = try NWListener(using: parameters); listener = server
            server.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
            return try await withCheckedThrowingContinuation { continuation in
                let completion = MediaRelayStartup(continuation)
                server.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if let port = server.port?.rawValue { completion.finish(.success(port)) }
                    case .failed(let error): completion.finish(.failure(error))
                    case .cancelled: completion.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                server.start(queue: queue)
            }
        }
        startup = task
        do { return try await task.value }
        catch { listener?.cancel(); listener = nil; startup = nil; throw error }
    }
    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let deadline = Task { try? await Task.sleep(nanoseconds: 10_000_000_000); if !Task.isCancelled { connection.cancel() } }
        read(connection, data: Data(), deadline: deadline)
    }
    private func read(_ connection: NWConnection, data: Data, deadline: Task<Void, Never>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] part, _, done, error in
            Task {
                var data = data; if let part { data.append(part) }
                guard error == nil, data.count <= 32768 else { deadline.cancel(); connection.cancel(); return }
                if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                    deadline.cancel(); await self?.respond(connection, data: data)
                } else if done { deadline.cancel(); connection.cancel() }
                else { await self?.read(connection, data: data, deadline: deadline) }
            }
        }
    }
    private func respond(_ connection: NWConnection, data: Data) {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        let fields = (lines.first ?? "").split(separator: " ")
        let path = fields.count == 3 ? fields[1].split(separator: "?")[0].split(separator: "/").map(String.init) : []
        guard fields.first == "GET" || fields.first == "HEAD", path.count == 2, let context = contexts[path[0]], let port = listener?.port?.rawValue else {
            fail(connection); return
        }
        let head = fields.first == "HEAD"
        if let text = context.playlists[path[1]] {
            let body = Data(text.utf8)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var response = Data(header.utf8); if !head { response.append(body) }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() }); return
        }
        guard var request = context.requests[path[1]] else { fail(connection); return }
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }) { request.setValue(range.dropFirst(6).trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "Range") }
        request.timeoutInterval = 60
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = Task {
            defer { connection.stateUpdateHandler = nil; connection.cancel() }
            do {
                try await SourceRateLimiter.shared.wait()
                let lease = try SourceTLS.$allowsInvalidCertificates.withValue(context.allowInvalidTLS) {
                    try LegadoJSCtx.$ruleSource.withValue(context.source) { try SourceTLS.lease(for: request) }
                }
                defer { lease.finish() }
                let (bytes, response) = try await lease.session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                var iterator = bytes.makeAsyncIterator(), prefix = Data()
                for _ in 0..<16 { if let byte = try await iterator.next() { prefix.append(byte) } else { break } }
                let playlist = String(decoding: prefix, as: UTF8.self).hasPrefix("#EXTM3U")
                if playlist, (200..<300).contains(http.statusCode) {
                    var body = prefix
                    while let byte = try await iterator.next() {
                        guard body.count < 4 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }; body.append(byte)
                    }
                    let result = try rewrite(String(decoding: body, as: UTF8.self), base: response.url ?? request.url!, token: path[0], port: port)
                    let content = Data(result.utf8)
                    let header = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(content.count)\r\nConnection: close\r\n\r\n"
                    var output = Data(header.utf8); if !head { output.append(content) }
                    try await send(connection, data: output)
                } else {
                    var header = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\n"
                    for key in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"] {
                        if key == "Content-Length", let encoding = http.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" { continue }
                        if let value = http.value(forHTTPHeaderField: key), !value.contains("\r"), !value.contains("\n") { header += key + ": " + value + "\r\n" }
                    }
                    header += "Connection: close\r\n\r\n"
                    try await send(connection, data: Data(header.utf8))
                    guard !head else { return }
                    var chunk = prefix; chunk.reserveCapacity(65536)
                    while let byte = try await iterator.next() {
                        chunk.append(byte)
                        if chunk.count >= 65536 { try await send(connection, data: chunk); chunk.removeAll(keepingCapacity: true) }
                    }
                    if !chunk.isEmpty { try await send(connection, data: chunk) }
                }
            } catch {
                if !Task.isCancelled { try? await send(connection, data: Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)) }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state { case .cancelled, .failed: task.cancel(); default: break }
        }
    }
    private func send(_ connection: NWConnection, data: Data) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func fail(_ connection: NWConnection) {
        connection.send(content: Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
private final class MediaRelayStartup: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func finish(_ result: Result<UInt16, Error>) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(with: result)
    }
}
