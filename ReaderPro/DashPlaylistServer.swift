import Foundation
import Network

// Only generated playlists are served, on loopback. Segment URLs remain the
// original source URLs and AVPlayer receives the source's request headers.
actor DashPlaylistServer {
    static let shared = DashPlaylistServer()
    private var listener: NWListener?
    private var ready: Task<UInt16, Error>?
    private var folders: [String: [String: String]] = [:]
    private var order: [String] = []
    private let queue = DispatchQueue(label: "ReaderPro.DASH")
    func register(_ manifest: DashManifest) async throws -> URL {
        let port = try await start(), token = UUID().uuidString
        folders[token] = manifest.playlists; order.append(token)
        while order.count > 6 { folders[order.removeFirst()] = nil }
        return URL(string: "http://127.0.0.1:\(port)/\(token)/master.m3u8")!
    }
    private func start() async throws -> UInt16 {
        if let ready { return try await ready.value }
        let task = Task<UInt16, Error> {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let server = try NWListener(using: parameters)
            listener = server
            server.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            return try await withCheckedThrowingContinuation { continuation in
                let state = DashServerStartup(continuation)
                server.stateUpdateHandler = { status in
                    switch status {
                    case .ready: if let port = server.port?.rawValue { state.finish(.success(port)) }
                    case .failed(let error): state.finish(.failure(error))
                    case .cancelled: state.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                server.start(queue: queue)
            }
        }
        ready = task
        do { return try await task.value }
        catch { listener?.cancel(); listener = nil; ready = nil; throw error }
    }
    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let timeout = Task { try? await Task.sleep(nanoseconds: 10_000_000_000); if !Task.isCancelled { connection.cancel() } }
        receive(connection, buffer: Data(), timeout: timeout)
    }
    private func receive(_ connection: NWConnection, buffer: Data, timeout: Task<Void, Never>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            Task {
                var buffer = buffer; if let data { buffer.append(data) }
                guard error == nil, buffer.count <= 32768 else { timeout.cancel(); connection.cancel(); return }
                if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    await self?.respond(connection, request: buffer); timeout.cancel()
                } else if done { timeout.cancel(); connection.cancel() }
                else { await self?.receive(connection, buffer: buffer, timeout: timeout) }
            }
        }
    }
    private func respond(_ connection: NWConnection, request: Data) {
        let line = String(decoding: request.prefix(32768), as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let fields = line.split(separator: " ")
        let path = fields.count == 3 ? String(fields[1]).components(separatedBy: "?")[0].split(separator: "/").map(String.init) : []
        let method = fields.first.map(String.init) ?? ""
        let body = path.count == 2 ? folders[path[0]]?[path[1]] : nil
        let accepted = (method == "GET" || method == "HEAD") && body != nil
        let data = Data((accepted ? body! : "播放清单已失效").utf8)
        let status = accepted ? "200 OK" : "404 Not Found"
        let header = "HTTP/1.1 \(status)\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8); if method != "HEAD" { response.append(data) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class DashServerStartup: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func finish(_ result: Result<UInt16, Error>) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
}

extension SourceVideoResource {
    func resolvedForPlayback() async throws -> SourceVideoResource {
        guard case .dash(let html, let request) = self else { return self }
        let data: Data, url: URL
        if let html { data = Data(html.utf8); url = request.url! }
        else {
            let response = try await SourceTLS.data(for: request)
            guard let http = response.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode), let address = response.1.url else {
                throw SourceFailure(stage: "DASH 视频", message: "获取 MPD 清单失败", url: request.url?.absoluteString ?? "")
            }
            data = response.0; url = address
        }
        let manifest = try DashManifest(data: data, url: url)
        let local = try await DashPlaylistServer.shared.register(manifest)
        var result = URLRequest(url: local); result.allHTTPHeaderFields = request.allHTTPHeaderFields
        return .native(result)
    }
}
