import Foundation
import Cunrar

// Use RAR_TEST + PROCESSDATA to obtain bytes. The dependency's convenience
// extract(Data) path uses RAR_EXTRACT and attempts to write in the process CWD,
// which is not writable on iOS. Native code never receives an output path.
enum SourceRar {
    private final class Output {
        var data = Data(), limit = 0
        var failure: String?
    }
    static func entries(_ file: URL) throws -> [(String, Data)] {
        try file.path.withCString { path in
            var options = RAROpenArchiveDataEx()
            options.ArcName = UnsafeMutablePointer(mutating: path); options.OpenMode = UInt32(RAR_OM_EXTRACT)
            guard let archive = RAROpenArchiveEx(&options), options.OpenResult == 0 else {
                throw SourceFailure(stage: "RAR 解压", message: "无法打开压缩包（\(options.OpenResult)），请检查文件是否完整或加密")
            }
            defer { RARCloseArchive(archive) }
            let output = Output(), pointer = Unmanaged.passUnretained(output).toOpaque()
            let callback: UNRARCALLBACK = { message, userData, address, length in
                guard let raw = UnsafeRawPointer(bitPattern: userData) else { return -1 }
                let output = Unmanaged<Output>.fromOpaque(raw).takeUnretainedValue()
                guard !Task.isCancelled else { output.failure = "解压已取消"; return -1 }
                switch message {
                case UCM_PROCESSDATA.rawValue:
                    guard length >= 0, length <= output.limit - output.data.count, let data = UnsafeRawPointer(bitPattern: address) else {
                        output.failure = "RAR 解压数据超过条目大小"; return -1
                    }
                    output.data.append(data.assumingMemoryBound(to: UInt8.self), count: length); return 0
                case UCM_NEEDPASSWORD.rawValue, UCM_NEEDPASSWORDW.rawValue:
                    output.failure = "此 RAR 压缩包需要密码"; return -1
                case UCM_CHANGEVOLUME.rawValue, UCM_CHANGEVOLUMEW.rawValue:
                    output.failure = "此 RAR 压缩包需要其他分卷"; return -1
                default: return 0
                }
            }
            RARSetCallback(archive, callback, Int(bitPattern: pointer))
            defer { RARSetCallback(archive, nil, 0) }
            var files: [(String, Data)] = [], total: UInt64 = 0, count = 0
            while true {
                try Task.checkCancellation()
                var header = RARHeaderDataEx()
                let result = RARReadHeaderEx(archive, &header)
                if result == ERAR_END_ARCHIVE { break }
                guard result == 0 else { throw SourceFailure(stage: "RAR 解压", message: "无法读取 RAR 条目（\(result)）") }
                count += 1
                let size = UInt64(header.UnpSizeHigh) << 32 | UInt64(header.UnpSize)
                guard count <= 10000, header.RedirType == 0, size <= 64 * 1024 * 1024,
                      header.DictSize <= 64 * 1024 * 1024 else {
                    throw SourceFailure(stage: "RAR 解压", message: "RAR 条目包含链接或超过解压大小限制")
                }
                total += size
                guard total <= 256 * 1024 * 1024 else { throw SourceFailure(stage: "RAR 解压", message: "RAR 压缩包超过解压大小限制") }
                let name = withUnsafePointer(to: &header.FileName.0) { String(cString: $0) }
                let directory = header.Flags & UInt32(RHDF_DIRECTORY) != 0
                output.data = Data(); output.limit = Int(size); output.failure = nil
                let status = RARProcessFile(archive, directory ? RAR_SKIP : RAR_TEST, nil, nil)
                guard status == 0 else { throw SourceFailure(stage: "RAR 解压", message: output.failure ?? "RAR 数据校验失败（\(status)）") }
                if !directory {
                    guard output.data.count == Int(size) else { throw SourceFailure(stage: "RAR 解压", message: "RAR 解压数据不完整") }
                    files.append((name, output.data))
                }
            }
            return files
        }
    }
}
