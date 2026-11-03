import Foundation
import CryptoKit

struct CachedChapterMedia {
    let request: URLRequest
    let auxiliary: String
}

// Only a completed download gets a record. A cancelled/failed transfer never
// appears as an offline chapter, and changing source invalidates the key.
actor MediaDiskCache {
    static let shared = MediaDiskCache()
    nonisolated let root: URL
    private struct Record: Codable { let entry: String; let auxiliary: String }
    private struct Transfer { let bookID: String; let token: UUID; let task: Task<Record, Error> }
    private var transfers: [String: Transfer] = [:]
    init(root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ChapterMedia")) {
        self.root = root
    }
    private func bookDirectory(_ bookID: String) -> URL { root.appendingPathComponent(Self.hash(bookID)) }
    private func directory(_ book: LocalBook, _ chapter: BookChapter) -> URL {
        let key = [book.kind, book.sourceUrl, book.sourceName, book.bookUrl, chapter.id, chapter.url ?? "", chapter.text].joined(separator: "\u{1f}")
        return bookDirectory(book.id).appendingPathComponent(Self.hash(key))
    }
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func record(_ directory: URL) -> Record? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("record.json")),
              let value = try? JSONDecoder().decode(Record.self, from: data),
              value.entry == (value.entry as NSString).lastPathComponent,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(value.entry).path) else { return nil }
        return value
    }
    func cached(book: LocalBook, chapter: BookChapter) async throws -> CachedChapterMedia? {
        let folder = directory(book, chapter)
        guard let value = record(folder) else { return nil }
        return try await playable(value, in: folder)
    }
    private func playable(_ record: Record, in directory: URL) async throws -> CachedChapterMedia {
        let file = directory.appendingPathComponent(record.entry)
        let url = record.entry.hasSuffix(".m3u8") ? try await OfflineMediaServer.shared.register(directory: directory, entry: record.entry) : file
        return CachedChapterMedia(request: URLRequest(url: url), auxiliary: record.auxiliary)
    }
    func download(book: LocalBook, chapter: BookChapter, request: URLRequest, auxiliary: String = "") async throws -> CachedChapterMedia {
        if let cached = try await cached(book: book, chapter: chapter) { return cached }
        let folder = directory(book, chapter), key = folder.path
        if let current = transfers[key] {
            let value = try await current.task.value
            return try await playable(value, in: folder)
        }
        let token = UUID(), staging = folder.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        let task = Task<Record, Error> {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let builder = MediaDownloadBuilder(folder: staging)
            let entry = try await builder.fetch(request, depth: 0)
            try Task.checkCancellation()
            let value = Record(entry: entry, auxiliary: auxiliary)
            try JSONEncoder().encode(value).write(to: staging.appendingPathComponent("record.json"), options: .atomic)
            // This actor owns both the commit and cancellation. Clearing the
            // book cannot race a late transfer into recreating its cache.
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            try FileManager.default.moveItem(at: staging, to: folder)
            return value
        }
        transfers[key] = Transfer(bookID: book.id, token: token, task: task)
        defer { if transfers[key]?.token == token { transfers[key] = nil } }
        let value = try await task.value
        return try await playable(value, in: folder)
    }
    func clear(bookID: String) {
        for key in transfers.keys.filter({ transfers[$0]?.bookID == bookID }) {
            transfers.removeValue(forKey: key)?.task.cancel()
        }
        try? FileManager.default.removeItem(at: bookDirectory(bookID))
    }
    func count(book: LocalBook) -> Int { book.chapters.filter { record(directory(book, $0)) != nil }.count }
}

private final class MediaDownloadBuilder {
    let folder: URL
    private var completed: [String: String] = [:]
    private var visiting = Set<String>()
    private var bytes: Int64 = 0
    init(folder: URL) { self.folder = folder }
    private func failure(_ text: String) -> SourceFailure { SourceFailure(stage: "媒体缓存", message: text) }
    func fetch(_ original: URLRequest, depth: Int) async throws -> String {
        try Task.checkCancellation()
        guard let url = original.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), depth <= 8 else {
            throw failure("媒体地址无效或清单嵌套过深")
        }
        let key = url.absoluteString
        if let file = completed[key] { return file }
        guard !visiting.contains(key), completed.count < 10000 else { throw failure("播放清单循环或分段过多") }
        visiting.insert(key); defer { visiting.remove(key) }
        var request = original; request.setValue(nil, forHTTPHeaderField: "Range"); request.timeoutInterval = 90
        try await SourceRateLimiter.shared.wait()
        let lease = try SourceTLS.lease(for: request); defer { lease.finish() }
        let (temporary, response) = try await lease.session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw failure("下载失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        let size = (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size > 0, Int64(size) <= 1024 * 1024 * 1024 - bytes else { throw failure("媒体为空或单章缓存超过 1 GB") }
        bytes += Int64(size)
        let probe = try FileHandle(forReadingFrom: temporary)
        let prefix = try probe.read(upToCount: 16) ?? Data(); try probe.close()
        let hls = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
        let name: String
        if hls {
            guard size <= 4 * 1024 * 1024 else { throw failure("播放清单过大") }
            let text = try String(contentsOf: temporary, encoding: .utf8)
            let rewritten = try await playlist(text, request: request, base: response.url ?? url, depth: depth)
            name = MediaDiskCache.hash(key) + ".m3u8"
            try Data(rewritten.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
        } else {
            guard http.mimeType?.lowercased() != "text/html" else { throw failure("返回了网页，可能需要重新登录；没有将它标记为已缓存媒体") }
            let ext = url.pathExtension.lowercased()
            let mimeExtension = ["audio/mpeg": "mp3", "audio/mp4": "m4a", "video/mp4": "mp4", "video/mp2t": "ts", "audio/wav": "wav"][http.mimeType ?? ""]
            let suffix = ext.count <= 8 && ext.range(of: "^[a-z0-9]+$", options: .regularExpression) != nil ? ext : (mimeExtension ?? "bin")
            name = MediaDiskCache.hash(key) + "." + suffix
            try FileManager.default.moveItem(at: temporary, to: folder.appendingPathComponent(name))
        }
        completed[key] = name
        return name
    }
    private func playlist(_ text: String, request: URLRequest, base: URL, depth: Int) async throws -> String {
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let master = lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF:") }
        guard master || lines.contains("#EXT-X-ENDLIST") else { throw failure("直播清单不能作为完整离线章节下载") }
        if master {
            // Cache one playable quality and its associated audio/subtitles,
            // rather than silently downloading every rendition of a movie.
            let candidates = lines.indices.filter { lines[$0].hasPrefix("#EXT-X-STREAM-INF:") && $0 + 1 < lines.count }
            let chosen = candidates.max { bandwidth(lines[$0]) < bandwidth(lines[$1]) }
            let removed = Set(candidates.filter { $0 != chosen }.flatMap { [$0, $0 + 1] })
            lines = lines.indices.filter { !removed.contains($0) && !lines[$0].hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }.map { lines[$0] }
        }
        let uri = try NSRegularExpression(pattern: #"URI="([^"]+)""#)
        for i in lines.indices {
            try Task.checkCancellation()
            let line = lines[i]
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
                guard line.contains("METHOD=NONE") || (line.contains("METHOD=AES-128") && (!line.contains("KEYFORMAT=") || line.contains("KEYFORMAT=\"identity\""))) else {
                    throw failure("此媒体使用系统 DRM，无法保存为普通离线分段")
                }
            }
            if !line.hasPrefix("#") { lines[i] = try await reference(line, request: request, base: base, depth: depth); continue }
            let matches = uri.matches(in: line, range: NSRange(line.startIndex..., in: line))
            var value = line
            for match in matches.reversed() {
                let address = (line as NSString).substring(with: match.range(at: 1))
                let file = try await reference(address, request: request, base: base, depth: depth)
                value = (value as NSString).replacingCharacters(in: match.range(at: 1), with: file)
            }
            lines[i] = value
        }
        return lines.joined(separator: "\n")
    }
    private func reference(_ value: String, request: URLRequest, base: URL, depth: Int) async throws -> String {
        guard !value.contains("{$"), let url = URL(string: value, relativeTo: base)?.absoluteURL else { throw failure("清单中的媒体地址无效") }
        var child = request; child.url = url
        return try await fetch(child, depth: depth + 1)
    }
    private func bandwidth(_ text: String) -> Int {
        guard let range = text.range(of: #"[:,]BANDWIDTH=\d+"#, options: .regularExpression) else { return 0 }
        return Int(text[range].split(separator: "=").last ?? "0") ?? 0
    }
}
