import Foundation
import Network

// AVPlayer requires HTTP for loose HLS playlists. Expose only registered,
// completed cache files through a random token on the loopback interface.
actor OfflineMediaServer {
    static let shared = OfflineMediaServer()
    private var listener: NWListener?
    private var startup: Task<UInt16, Error>?
    private var folders: [String: URL] = [:]
    private var order: [String] = []
    private let queue = DispatchQueue(label: "ReaderPro.offlineMedia")
    func register(directory: URL, entry: String) async throws -> URL {
        let port = try await start()
        let token = UUID().uuidString
        folders[token] = directory; order.append(token)
        while order.count > 100 { folders[order.removeFirst()] = nil }
        return URL(string: "http://127.0.0.1:\(port)/\(token)/\(entry)")!
    }
    private func start() async throws -> UInt16 {
        if let startup { return try await startup.value }
        let task = Task<UInt16, Error> {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let server = try NWListener(using: parameters); listener = server
            server.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
            return try await withCheckedThrowingContinuation { continuation in
                let completion = OfflineServerStartup(continuation)
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
        let path = fields.count == 3 ? fields[1].split(separator: "/").map(String.init) : []
        guard fields.first == "GET" || fields.first == "HEAD", path.count == 2,
              path[1].range(of: "^[a-f0-9]{64}\\.[a-z0-9]{1,8}$", options: .regularExpression) != nil,
              let folder = folders[path[0]],
              let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent(path[1])) else {
            fail(connection, status: "404 Not Found"); return
        }
        do {
            let size = try handle.seekToEnd(); guard size > 0 else { throw URLError(.zeroByteResource) }
            var lower: UInt64 = 0, upper = size - 1, partial = false
            if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
                let raw = range.dropFirst(6).trimmingCharacters(in: .whitespaces)
                guard raw.hasPrefix("bytes="), !raw.contains(",") else {
                    try? handle.close(); fail(connection, status: "416 Range Not Satisfiable", extra: "Content-Range: bytes */\(size)\r\n"); return
                }
                let parts = raw.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count == 2 else { try? handle.close(); fail(connection, status: "416 Range Not Satisfiable"); return }
                if parts[0].isEmpty, let suffix = UInt64(parts[1]), suffix > 0 { lower = size - min(size, suffix) }
                else if let start = UInt64(parts[0]), start < size {
                    lower = start
                    if !parts[1].isEmpty {
                        guard let end = UInt64(parts[1]), end >= start else { try? handle.close(); fail(connection, status: "416 Range Not Satisfiable"); return }
                        upper = min(size - 1, end)
                    }
                } else { try? handle.close(); fail(connection, status: "416 Range Not Satisfiable"); return }
                partial = true
            }
            let length = upper - lower + 1
            try handle.seek(toOffset: lower)
            let mime = path[1].hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : path[1].hasSuffix(".ts") ? "video/mp2t" : "application/octet-stream"
            let header = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(mime)\r\nContent-Length: \(length)\r\nAccept-Ranges: bytes\r\n" + (partial ? "Content-Range: bytes \(lower)-\(upper)/\(size)\r\n" : "") + "Connection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
                if error != nil || fields.first == "HEAD" { try? handle.close(); connection.cancel(); return }
                Task { await self?.send(connection, handle: handle, remaining: length) }
            })
        } catch { try? handle.close(); connection.cancel() }
    }
    private func send(_ connection: NWConnection, handle: FileHandle, remaining: UInt64) {
        guard remaining > 0, let part = try? handle.read(upToCount: Int(min(remaining, 128 * 1024))), !part.isEmpty else {
            try? handle.close(); connection.cancel(); return
        }
        connection.send(content: part, completion: .contentProcessed { [weak self] error in
            guard error == nil else { try? handle.close(); connection.cancel(); return }
            Task { await self?.send(connection, handle: handle, remaining: remaining - UInt64(part.count)) }
        })
    }
    private func fail(_ connection: NWConnection, status: String, extra: String = "") {
        let header = "HTTP/1.1 \(status)\r\n\(extra)Content-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class OfflineServerStartup: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func finish(_ result: Result<UInt16, Error>) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(with: result)
    }
}
