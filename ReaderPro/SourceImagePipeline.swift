import Foundation
import UIKit

enum SourceImagePipeline {
    static func decode(_ data: Data, source: LegadoSource, cover: Bool, url: String) throws -> Data {
        let script = cover ? source.coverDecodeJs : (source.ruleContent.androidValue("imageDecode") ?? "")
        guard !script.isEmpty else { return data }
        let output = LegadoJS.run(sourceScriptBody(script), input: "", baseUrl: url,
                                  sourceKey: LegadoJSCtx.key, sourceUrl: source.bookSourceUrl,
                                  book: LegadoJSCtx.book, structuredResult: data.map { Int($0) })
        try LegadoJSCtx.failures?.check()
        if let json = output.data(using: .utf8), let values = try? JSONDecoder().decode([Int].self, from: json) {
            guard values.allSatisfy({ (-128...255).contains($0) }) else { throw SourceFailure(stage: "图片解密", message: "脚本返回了无效字节") }
            return Data(values.map { UInt8(truncatingIfNeeded: $0) })
        }
        if let decoded = Data(base64Encoded: output), !decoded.isEmpty { return decoded }
        throw SourceFailure(stage: "图片解密", message: "脚本需要返回图片字节数组或 Base64 数据", url: url)
    }

    static func load(_ address: String, source: LegadoSource?, cover: Bool) async throws -> Data {
        guard let source else {
            let request = try SourceHTTP.request(address, base: address)
            let (data, response) = try await SourceHTTP.session.data(for: request)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
                throw SourceFailure(stage: "图片", message: "图片请求失败", url: address)
            }
            return data
        }
        return try await source.withRules {
            let request = try SourceHTTP.request(address, base: source.bookSourceUrl, headers: source.requestHeaders)
            let (data, response) = try await SourceTLS.data(for: request)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
                throw SourceFailure(stage: "图片", message: "图片请求失败", url: address)
            }
            return try decode(data, source: source, cover: cover, url: address)
        }
    }
}
