import Foundation
import JavaScriptCore
import CryptoKit
import CoreFoundation
import SWCompression
import Unrar

enum SourceFiles {
    static var root: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SourceFiles", isDirectory: true) }
    static func file(_ path: String) throws -> URL {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let normalized = path.replacingOccurrences(of: "\\", with: "/").drop(while: { $0 == "/" })
        let file = base.appendingPathComponent(String(normalized)).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base.path + "/") else { throw SourceFailure(stage: "脚本文件", message: "文件路径越界") }
        return file
    }
    static func write(_ data: Data, address: String) throws -> String {
        let options = SourceHTTP.options(address)
        let suffix = (options.options["type"] as? String ?? URL(string: options.url)?.pathExtension ?? "bin").filter { $0.isLetter || $0.isNumber }
        let digest = Insecure.MD5.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = "/" + String(digest.dropFirst(8).prefix(16)) + "." + (suffix.isEmpty ? "bin" : suffix)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: file(path), options: .atomic)
        return path
    }
    static func bytes(_ address: String, base: String) throws -> Data {
        if isSourceURL(address) || address.hasPrefix("//") {
            let response = try SourceJSBridge.request(address, base: base, headers: LegadoJSCtx.headers, binary: true)
            guard let status = response["status"] as? Int, (200..<300).contains(status),
                  let raw = response["text"] as? String, let data = SourceCrypto.hex(raw) else {
                throw SourceFailure(stage: "脚本文件", message: "下载失败", url: address)
            }
            return data
        }
        if let data = SourceCrypto.hex(address), !data.isEmpty { return data }
        return try Data(contentsOf: file(address))
    }
    static func text(_ data: Data, charset: String) throws -> String {
        if charset.isEmpty { return decodeTextData(data) }
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cf != kCFStringEncodingInvalidId,
              let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) else {
            throw SourceFailure(stage: "脚本文件", message: "不能使用指定编码读取文件：" + charset)
        }
        return text
    }
    static func unzip(_ path: String) throws -> String {
        let archive = try file(path), data = try Data(contentsOf: archive)
        guard data.count <= 64 * 1024 * 1024 else { throw SourceFailure(stage: "脚本解压", message: "压缩包超过大小限制") }
        if data.starts(with: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) {
            let info = try SevenZipContainer.info(container: data)
            guard info.count <= 10000 else { throw SourceFailure(stage: "脚本解压", message: "压缩包文件过多") }
            var total: Int64 = 0
            for entry in info {
                guard entry.type == .regular || entry.type == .directory, !entry.isAnti,
                      let size = entry.size, size >= 0, size <= 64 * 1024 * 1024 else {
                    if entry.type == .directory { continue }
                    throw SourceFailure(stage: "脚本解压", message: "压缩包包含不支持的条目或超大文件")
                }
                total += Int64(size)
            }
            guard total <= 256 * 1024 * 1024 else { throw SourceFailure(stage: "脚本解压", message: "压缩包超过解压大小限制") }
            let entries = try SevenZipContainer.open(container: data)
            return try extractEntries(entries.filter { $0.info.type == .regular }.map { ($0.info.name, $0.data ?? Data()) })
        }
        if data.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07]) {
            let rar = try Unrar.Archive(fileURL: archive), entries = try rar.entries()
            guard entries.count <= 10000, entries.allSatisfy({ $0.uncompressedSize <= 64 * 1024 * 1024 && $0.redirectionType == 0 }),
                  entries.reduce(UInt64(0), { $0 + $1.uncompressedSize }) <= 256 * 1024 * 1024 else {
                throw SourceFailure(stage: "脚本解压", message: "压缩包包含链接或超过解压大小限制")
            }
            let names = entries.filter { !$0.directory }
            return try extractEntries(names.map { entry in
                try Task.checkCancellation()
                return (entry.fileName, try rar.extract(entry))
            })
        }
        let entries = readZipEntries(data)
        guard !entries.isEmpty else { throw SourceFailure(stage: "脚本解压", message: "不是可读取的 ZIP 文件") }
        guard entries.count <= 10000, entries.allSatisfy({ $0.uncompressedSize >= 0 && $0.uncompressedSize <= 64 * 1024 * 1024 }),
              entries.reduce(Int64(0), { $0 + Int64($1.uncompressedSize) }) <= 256 * 1024 * 1024 else {
            throw SourceFailure(stage: "脚本解压", message: "压缩包超过解压大小限制")
        }
        let targetPath = "/archives/" + UUID().uuidString
        let target = try file(targetPath)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        do {
            for entry in entries where !entry.name.hasSuffix("/") {
                try Task.checkCancellation()
                let destination = target.appendingPathComponent(entry.name.replacingOccurrences(of: "\\", with: "/")).standardizedFileURL
                guard destination.path.hasPrefix(target.path + "/") else { throw SourceFailure(stage: "脚本解压", message: "压缩包包含越界路径") }
                guard let bytes = extractZipEntry(data, entry), bytes.count == entry.uncompressedSize else { throw SourceFailure(stage: "脚本解压", message: "解压失败：" + entry.name) }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: destination, options: .atomic)
            }
        } catch { try? FileManager.default.removeItem(at: target); throw error }
        return targetPath
    }
    private static func extractEntries(_ entries: [(String, Data)]) throws -> String {
        let path = "/archives/" + UUID().uuidString, target = try file(path)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        do {
            for (name, data) in entries {
                try Task.checkCancellation()
                let destination = target.appendingPathComponent(name.replacingOccurrences(of: "\\", with: "/")).standardizedFileURL
                guard !name.contains("\0"), destination.path.hasPrefix(target.path + "/") else {
                    throw SourceFailure(stage: "脚本解压", message: "压缩包包含越界路径")
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            }
        } catch { try? FileManager.default.removeItem(at: target); throw error }
        return path
    }
    static func install(_ java: JSValue, base: String) {
        let operation: @convention(block) (String, String, String, String) -> String = { action, first, second, charset in
            do {
                switch action {
                case "download":
                    let data = second.isEmpty ? try bytes(first, base: base) : (SourceCrypto.hex(first) ?? Data())
                    return try write(data, address: second.isEmpty ? first : second)
                case "read":
                    let url = try file(first)
                    return FileManager.default.fileExists(atPath: url.path) ? try text(Data(contentsOf: url), charset: charset) : ""
                case "readBytes":
                    let data = (try? Data(contentsOf: file(first))) ?? Data()
                    return String(decoding: try JSONEncoder().encode(data.map { Int(Int8(bitPattern: $0)) }), as: UTF8.self)
                case "delete":
                    let url = try file(first)
                    guard FileManager.default.fileExists(atPath: url.path) else { return "false" }
                    try FileManager.default.removeItem(at: url); return "true"
                case "unzip": return try unzip(first)
                case "folder":
                    let folder = try file(first)
                    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey]).sorted { $0.lastPathComponent < $1.lastPathComponent }
                    let result = try files.filter { (try $0.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true }.map { try text(Data(contentsOf: $0), charset: charset) }.joined(separator: "\n")
                    try FileManager.default.removeItem(at: folder); return result
                case "zipText", "zipBytes":
                    let data = try bytes(first, base: base)
                    guard let entry = readZipEntries(data).first(where: { $0.name == second }), let extracted = extractZipEntry(data, entry) else { return action == "zipBytes" ? "null" : "" }
                    if action == "zipText" { return try text(extracted, charset: charset) }
                    return String(decoding: try JSONEncoder().encode(extracted.map { Int(Int8(bitPattern: $0)) }), as: UTF8.self)
                default: throw SourceFailure(stage: "脚本文件", message: "不支持的文件操作")
                }
            } catch {
                JSContext.current()?.exception = JSValue(newErrorFromMessage: sourceErrorMessage(error), in: JSContext.current()); return ""
            }
        }
        java.setObject(operation, forKeyedSubscript: "_file" as NSString)
    }
}
