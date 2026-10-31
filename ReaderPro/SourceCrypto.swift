import Foundation
import CommonCrypto
import JavaScriptCore

enum SourceCrypto {
    static func bytes(_ value: JSValue) -> Data {
        if value.isArray { return Data((value.toArray() ?? []).compactMap { ($0 as? NSNumber).map { UInt8(truncating: $0) } }) }
        return Data((value.toString() ?? "").utf8)
    }
    static func hex(_ text: String) -> Data? {
        guard text.count % 2 == 0, text.range(of: #"^[0-9a-fA-F]*$"#, options: .regularExpression) != nil else { return nil }
        var data = Data(); var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: 2)
            guard let byte = UInt8(text[start..<end], radix: 16) else { return nil }
            data.append(byte); start = end
        }
        return data
    }
    static func base64(_ text: String) -> Data? {
        var text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text, options: .ignoreUnknownCharacters)
    }

    static func crypt(_ input: Data, algorithm: String, key: Data, iv: Data, decrypt: Bool) throws -> Data {
        let spec = algorithm.uppercased().split(separator: "/").map(String.init)
        let algorithmID: CCAlgorithm
        let block: Int
        switch spec.first ?? "AES" {
        case "AES": algorithmID = CCAlgorithm(kCCAlgorithmAES); block = kCCBlockSizeAES128
        case "DES": algorithmID = CCAlgorithm(kCCAlgorithmDES); block = kCCBlockSizeDES
        case "DESEDE", "TRIPLEDES", "3DES": algorithmID = CCAlgorithm(kCCAlgorithm3DES); block = kCCBlockSize3DES
        default: throw SourceFailure(stage: "脚本兼容性", message: "不支持的加密算法：\(algorithm)")
        }
        let mode = spec.count > 1 ? spec[1] : "ECB"
        guard ["ECB", "CBC"].contains(mode) else { throw SourceFailure(stage: "脚本兼容性", message: "不支持的加密模式：\(mode)") }
        let padding = spec.count > 2 ? spec[2] : "PKCS5PADDING"
        guard ["PKCS5PADDING", "PKCS7PADDING", "NOPADDING", "ZEROPADDING"].contains(padding) else { throw SourceFailure(stage: "脚本兼容性", message: "不支持的填充：\(padding)") }
        guard mode != "CBC" || iv.count == block else { throw SourceFailure(stage: "脚本解密", message: "IV 长度必须为 \(block) 字节") }
        var data = input
        if !decrypt && padding == "ZEROPADDING" && data.count % block != 0 { data.append(Data(repeating: 0, count: block - data.count % block)) }
        var options: CCOptions = mode == "ECB" ? CCOptions(kCCOptionECBMode) : 0
        if padding.hasPrefix("PKCS") { options |= CCOptions(kCCOptionPKCS7Padding) }
        let capacity = data.count + block
        var output = [UInt8](repeating: 0, count: capacity)
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { inputBytes in
                    CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), algorithmID, options,
                            keyBytes.baseAddress, key.count, iv.isEmpty ? nil : ivBytes.baseAddress,
                            inputBytes.baseAddress, data.count, &output, capacity, &written)
                }
            }
        }
        guard status == kCCSuccess else { throw SourceFailure(stage: "脚本解密", message: "加解密失败（\(status)），请检查密钥、IV 和填充规则") }
        var result = Data(output.prefix(written))
        if decrypt && padding == "ZEROPADDING" { while result.last == 0 { result.removeLast() } }
        return result
    }

    static func install(_ java: JSValue, context: JSContext) {
        let transform: @convention(block) (JSValue, String, JSValue, JSValue, Bool, String) -> JSValue? = { input, algorithm, key, iv, decrypt, output in
            do {
                let data: Data
                if decrypt && !input.isArray {
                    let text = input.toString() ?? ""
                    guard let decoded = hex(text) ?? base64(text) else { throw SourceFailure(stage: "脚本解密", message: "密文不是有效的 Hex 或 Base64") }
                    data = decoded
                } else { data = bytes(input) }
                let result = try crypt(data, algorithm: algorithm, key: bytes(key), iv: iv.isNull || iv.isUndefined ? Data() : bytes(iv), decrypt: decrypt)
                let current = JSContext.current()
                switch output {
                case "string": return JSValue(object: String(decoding: result, as: UTF8.self), in: current)
                case "base64": return JSValue(object: result.base64EncodedString(), in: current)
                case "hex": return JSValue(object: result.map { String(format: "%02x", $0) }.joined(), in: current)
                default: return JSValue(object: result.map(Int.init), in: current)
                }
            } catch {
                JSContext.current()?.exception = JSValue(newErrorFromMessage: sourceErrorMessage(error), in: JSContext.current())
                return nil
            }
        }
        let base64Bytes: @convention(block) (String) -> [Int] = { (base64($0) ?? Data()).map(Int.init) }
        let hexBytes: @convention(block) (String) -> [Int] = { (hex($0) ?? Data()).map(Int.init) }
        let toBytes: @convention(block) (String) -> [Int] = { Data($0.utf8).map(Int.init) }
        let toString: @convention(block) (JSValue) -> String = { String(decoding: bytes($0), as: UTF8.self) }
        let encode64: @convention(block) (JSValue) -> String = { bytes($0).base64EncodedString() }
        let hmac: @convention(block) (String, String, String, Bool) -> String = { text, algorithm, secret, useBase64 in
            let kind: CCHmacAlgorithm
            let length: Int
            switch algorithm.uppercased().replacingOccurrences(of: "-", with: "") {
            case "HMACMD5": kind = CCHmacAlgorithm(kCCHmacAlgMD5); length = Int(CC_MD5_DIGEST_LENGTH)
            case "HMACSHA1": kind = CCHmacAlgorithm(kCCHmacAlgSHA1); length = Int(CC_SHA1_DIGEST_LENGTH)
            case "HMACSHA256": kind = CCHmacAlgorithm(kCCHmacAlgSHA256); length = Int(CC_SHA256_DIGEST_LENGTH)
            case "HMACSHA512": kind = CCHmacAlgorithm(kCCHmacAlgSHA512); length = Int(CC_SHA512_DIGEST_LENGTH)
            default:
                JSContext.current()?.exception = JSValue(newErrorFromMessage: "不支持的 HMAC 算法：" + algorithm, in: JSContext.current()); return ""
            }
            let key = Data(secret.utf8), input = Data(text.utf8)
            var digest = [UInt8](repeating: 0, count: length)
            key.withUnsafeBytes { keyBytes in
                input.withUnsafeBytes { inputBytes in CCHmac(kind, keyBytes.baseAddress, key.count, inputBytes.baseAddress, input.count, &digest) }
            }
            return useBase64 ? Data(digest).base64EncodedString() : digest.map { String(format: "%02x", $0) }.joined()
        }
        java.setObject(transform, forKeyedSubscript: "_crypt" as NSString)
        java.setObject(base64Bytes, forKeyedSubscript: "base64DecodeToByteArray" as NSString)
        java.setObject(hexBytes, forKeyedSubscript: "hexDecodeToByteArray" as NSString)
        java.setObject(toBytes, forKeyedSubscript: "strToBytes" as NSString)
        java.setObject(toString, forKeyedSubscript: "bytesToStr" as NSString)
        java.setObject(encode64, forKeyedSubscript: "base64Encode" as NSString)
        java.setObject(hmac, forKeyedSubscript: "_hmac" as NSString)
        context.evaluateScript(#"""
        java.createSymmetricCrypto = function(algorithm, key, iv) {
            return {
                decrypt:function(value){return java._crypt(value,algorithm,key,iv,true,'bytes');},
                decryptStr:function(value){return java._crypt(value,algorithm,key,iv,true,'string');},
                encrypt:function(value){return java._crypt(value,algorithm,key,iv,false,'bytes');},
                encryptBase64:function(value){return java._crypt(value,algorithm,key,iv,false,'base64');},
                encryptHex:function(value){return java._crypt(value,algorithm,key,iv,false,'hex');}
            };
        };
        java.aesBase64DecodeToString = function(data,key,algorithm,iv){return java._crypt(java.base64DecodeToByteArray(data),algorithm || 'AES/ECB/PKCS5Padding',key,iv,true,'string');};
        java.desEncodeToBase64String = function(data,key,algorithm,iv){return java._crypt(data,algorithm || 'DES/ECB/PKCS5Padding',key,iv,false,'base64');};
        java.base64Decoder = java.base64DecodeToByteArray;
        java.HMacHex=function(text,algorithm,key){return java._hmac(String(text),String(algorithm),String(key),false);};
        java.HMacBase64=function(text,algorithm,key){return java._hmac(String(text),String(algorithm),String(key),true);};
        """#)
    }
}
