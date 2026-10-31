import Foundation
import JavaScriptCore
import CryptoKit

// MARK: - Legado JS 书源引擎（JavaScriptCore）
// 对标阅读(Legado/legado-E)的 @js: / <js> 规则执行环境。
// 之前的引擎把一切 @js:/<js> 规则直接 return []，导致大量书源"搜得到但看不了"
// （目录、正文、URL 拼接常用 JS 做解密/构造）。iOS 自带 JavaScriptCore，完全可以
// 执行这些 JS —— 这里注入 Legado 书源 JS 依赖的内置对象（java/source/book）和
// 全局变量（result/baseUrl/key/page/geturl），执行后读回 result。

final class LegadoJS {

    struct BookCtx {
        var bookUrl = ""
        var name = ""
        var author = ""
        var order = 0
        var tocUrl = ""
        var coverUrl = ""
    }

    // 可变引用盒：@convention(block) 闭包间共享的可变并发数（避免捕获 var 装箱的不确定性）
    final class ConcurrentBox {
        var value: Int = 0
    }

    // java 键值存储：按 sourceUrl 分键，跨章节/跨请求共享（对标 Legado 的 java.put/get）
    private static var store: [String: [String: String]] = [:]
    private static let storeLock = NSLock()

    // 执行一段 JS 规则。input 是规则输入（result 初始值），返回执行后 result 的字符串值。
    static func run(_ js: String, input: String, baseUrl: String,
                    sourceKey: String, sourceUrl: String,
                    loginInfo: [String: String] = [:], header: [String: String] = [:],
                    book: BookCtx? = nil, page: Int = 1) -> String {
        let script = js.trimmingCharacters(in: .whitespacesAndNewlines)
        if script.isEmpty { return input }
        guard let ctx = JSContext() else { return input }
        var exception = ""
        ctx.exceptionHandler = { _, error in exception = error?.toString() ?? "未知 JavaScript 错误" }

        let storeKey = sourceUrl.isEmpty ? "global" : sourceUrl

        // ---- 全局变量 ----
        ctx.setObject(input, forKeyedSubscript: "result" as NSString)
        ctx.setObject(baseUrl, forKeyedSubscript: "baseUrl" as NSString)
        ctx.setObject(sourceKey, forKeyedSubscript: "key" as NSString)
        ctx.setObject(page, forKeyedSubscript: "page" as NSString)
        ctx.setObject(sourceUrl, forKeyedSubscript: "sourceUrl" as NSString)
        let geturl: @convention(block) () -> String = { baseUrl }
        ctx.setObject(geturl, forKeyedSubscript: "geturl" as NSString)

        // ---- java 对象（跨页键值存储 + 工具方法）----
        let java = JSValue(newObjectIn: ctx)!
        let jget: @convention(block) (String) -> String = { k in
            storeLock.lock(); defer { storeLock.unlock() }
            return store[storeKey]?[k] ?? ""
        }
        let jput: @convention(block) (String, JSValue) -> Void = { k, v in
            storeLock.lock(); defer { storeLock.unlock() }
            if store[storeKey] == nil { store[storeKey] = [:] }
            store[storeKey]?[k] = v.toString() ?? ""
        }
        java.setObject(jget, forKeyedSubscript: "get" as NSString)
        java.setObject(jput, forKeyedSubscript: "put" as NSString)
        java.setObject(LegadoJS.hexEncodeBlock, forKeyedSubscript: "hexEncodeToString" as NSString)
        java.setObject(LegadoJS.hexDecodeBlock, forKeyedSubscript: "hexDecodeToString" as NSString)
        java.setObject(LegadoJS.base64EncodeBlock, forKeyedSubscript: "base64Encode" as NSString)
        java.setObject(LegadoJS.base64DecodeBlock, forKeyedSubscript: "base64Decode" as NSString)
        java.setObject(LegadoJS.md5Block, forKeyedSubscript: "md5Encode" as NSString)
        java.setObject(LegadoJS.md5_16Block, forKeyedSubscript: "md5Encode16" as NSString)
        java.setObject(LegadoJS.sha1Block, forKeyedSubscript: "sha1Encode" as NSString)
        java.setObject(LegadoJS.urlEncodeBlock, forKeyedSubscript: "urlEncode" as NSString)
        java.setObject(LegadoJS.urlEncodeBlock, forKeyedSubscript: "encodeURI" as NSString)
        let getString: @convention(block) (String) -> String = { rule in applyRuleFirst(input, rule, base: baseUrl) }
        let getElements: @convention(block) (String) -> [String] = { rule in applyRule(input, rule, base: baseUrl) }
        java.setObject(getString, forKeyedSubscript: "getString" as NSString)
        java.setObject(getElements, forKeyedSubscript: "getElements" as NSString)
        java.setObject(LegadoJS.urlDecodeBlock, forKeyedSubscript: "urlDecode" as NSString)
        java.setObject(LegadoJS.formatDateBlock, forKeyedSubscript: "formatDate" as NSString)
        java.setObject(LegadoJS.timeMillisBlock, forKeyedSubscript: "timeMillis" as NSString)
        java.setObject(LegadoJS.timeMillisBlock, forKeyedSubscript: "time" as NSString)
        java.setObject(LegadoJS.substringBlock, forKeyedSubscript: "subString" as NSString)
        java.setObject(LegadoJS.substringBlock, forKeyedSubscript: "substring" as NSString)
        java.setObject(LegadoJS.strBlock, forKeyedSubscript: "str" as NSString)
        ctx.setObject(java, forKeyedSubscript: "java" as NSString)

        // ---- source 对象 ----
        let source = JSValue(newObjectIn: ctx)!
        // Legado BaseSource.getKey identifies the source, while the global
        // `key` remains the current search keyword.
        let getKey: @convention(block) () -> String = { sourceUrl }
        let getSourceUrl: @convention(block) () -> String = { sourceUrl }
        let getLoginMap: @convention(block) () -> [String: String] = { loginInfo }
        let getLoginStr: @convention(block) () -> String = { loginInfo.map { "\($0.key)=\($0.value)" }.joined(separator: "&") }
        let getHeader: @convention(block) () -> [String: String] = { header }
        let concurrentBox = ConcurrentBox()
        let getConcurrent: @convention(block) () -> Int = { concurrentBox.value }
        let putConcurrent: @convention(block) (JSValue) -> Void = { v in concurrentBox.value = Int(v.toNumber()?.intValue ?? 0) }
        source.setObject(sourceUrl, forKeyedSubscript: "key" as NSString)
        source.setObject(sourceUrl, forKeyedSubscript: "bookSourceUrl" as NSString)
        source.setObject(getKey, forKeyedSubscript: "getKey" as NSString)
        source.setObject(getSourceUrl, forKeyedSubscript: "getBookSourceUrl" as NSString)
        source.setObject(getLoginMap, forKeyedSubscript: "getLoginInfoMap" as NSString)
        source.setObject(getLoginStr, forKeyedSubscript: "getLoginInfo" as NSString)
        source.setObject(getHeader, forKeyedSubscript: "headerMap" as NSString)
        source.setObject(getConcurrent, forKeyedSubscript: "getConcurrent" as NSString)
        source.setObject(putConcurrent, forKeyedSubscript: "putConcurrent" as NSString)
        ctx.setObject(source, forKeyedSubscript: "source" as NSString)

        // ---- book 对象 ----
        let b = book ?? BookCtx()
        let bookObj = JSValue(newObjectIn: ctx)!
        bookObj.setObject(b.bookUrl, forKeyedSubscript: "bookUrl" as NSString)
        bookObj.setObject(b.name, forKeyedSubscript: "name" as NSString)
        bookObj.setObject(b.author, forKeyedSubscript: "author" as NSString)
        bookObj.setObject(b.order, forKeyedSubscript: "order" as NSString)
        bookObj.setObject(b.tocUrl, forKeyedSubscript: "tocUrl" as NSString)
        bookObj.setObject(b.coverUrl, forKeyedSubscript: "coverUrl" as NSString)
        ctx.setObject(bookObj, forKeyedSubscript: "book" as NSString)

        // ---- 执行 ----
        // 关键修复：JS 规则大量用「最后一行是表达式」的方式返回结果，
        // 例如 exploreUrl 的 @js:...;JSON.stringify(s)，正文规则的 @js:...;result。
        // 之前把 evaluateScript 的返回值丢弃了、只读 result 变量，导致
        // JSON.stringify(...) 这种「靠返回值」的规则全部拿不到结果（发现/搜索/正文全空）。
        let library = LegadoJSCtx.library
        if !library.isEmpty {
            if library.hasPrefix("http://") || library.hasPrefix("https://") {
                LegadoJSCtx.failures?.add("jsLib 是远程脚本地址，当前需要在书源中内嵌脚本内容")
                return ""
            }
            ctx.evaluateScript(library)
        }
        let ret = ctx.evaluateScript(script)
        guard exception.isEmpty else {
            LegadoJSCtx.failures?.add(exception)
            return ""
        }
        func string(_ value: JSValue?) -> String? {
            guard let value, !value.isNull, !value.isUndefined else { return nil }
            if value.isObject {
                return ctx.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [value])?.toString()
            }
            return value.toString()
        }
        // An explicit empty string is a real result, never substitute input.
        return string(ret) ?? string(ctx.objectForKeyedSubscript("result")) ?? ""
    }

    // MARK: 工具 block（静态，避免每次 run 重复创建）

    static let hexEncodeBlock: @convention(block) (String) -> String = { s in
        Data(s.utf8).map { String(format: "%02x", $0) }.joined()
    }
    static let hexDecodeBlock: @convention(block) (String) -> String = { s in
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count % 2 != 0 { t = "0" + t }
        var bytes: [UInt8] = []
        var idx = t.startIndex
        while idx < t.endIndex {
            let next = t.index(idx, offsetBy: 2, limitedBy: t.endIndex) ?? t.endIndex
            if let byte = UInt8(t[idx..<next], radix: 16) { bytes.append(byte) }
            idx = next
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
    static let base64EncodeBlock: @convention(block) (String) -> String = { s in
        Data(s.utf8).base64EncodedString()
    }
    static let base64DecodeBlock: @convention(block) (String) -> String = { s in
        var t = s.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        let rem = t.count % 4
        if rem > 0 { t += String(repeating: "=", count: 4 - rem) }
        guard let d = Data(base64Encoded: t) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }
    static let md5Block: @convention(block) (String) -> String = { s in
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    static let md5_16Block: @convention(block) (String) -> String = { s in
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex.count == 32 else { return hex }
        let start = hex.index(hex.startIndex, offsetBy: 8)
        let end = hex.index(hex.startIndex, offsetBy: 24)
        return String(hex[start..<end])
    }
    static let sha1Block: @convention(block) (String) -> String = { s in
        let digest = Insecure.SHA1.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    static let urlEncodeBlock: @convention(block) (String) -> String = { s in
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }
    static let urlDecodeBlock: @convention(block) (String) -> String = { s in
        s.removingPercentEncoding ?? s
    }
    static let formatDateBlock: @convention(block) (String, JSValue) -> String = { pattern, ts in
        let f = DateFormatter()
        f.dateFormat = pattern
        let millis = ts.toNumber()?.doubleValue ?? (Date().timeIntervalSince1970 * 1000)
        return f.string(from: Date(timeIntervalSince1970: millis / 1000))
    }
    static let timeMillisBlock: @convention(block) () -> Double = { Date().timeIntervalSince1970 * 1000 }
    static let substringBlock: @convention(block) (String, JSValue, JSValue) -> String = { s, a, b in
        let ns = s as NSString
        let start = Int(a.toNumber()?.intValue ?? 0)
        let end = b.isUndefined ? ns.length : Int(b.toNumber()?.intValue ?? ns.length)
        if start >= ns.length { return "" }
        let safeStart = max(0, start)
        let safeEnd = min(ns.length, max(safeStart, end))
        return ns.substring(with: NSRange(location: safeStart, length: safeEnd - safeStart))
    }
    static let strBlock: @convention(block) (JSValue) -> String = { v in v.toString() ?? "" }
}
