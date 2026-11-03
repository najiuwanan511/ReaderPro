import Foundation
import JavaScriptCore
import CryptoKit

// Mutable per-request state exposed to an AnalyzeUrl options `js` script.
// It is confined to the synchronous JavaScriptCore evaluation for one URL.
final class SourceJSURLContext {
    var url: String
    var headers: [String: String]
    var returnedValue = false
    init(url: String, headers: [String: String]) { self.url = url; self.headers = headers }
    func setHeader(_ name: String, _ value: String) {
        for existing in Array(headers.keys) where existing.caseInsensitiveCompare(name) == .orderedSame { headers.removeValue(forKey: existing) }
        headers[name] = value
    }
    func header(_ name: String) -> String {
        headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value ?? ""
    }
    func removeHeader(_ name: String) {
        for existing in Array(headers.keys) where existing.caseInsensitiveCompare(name) == .orderedSame { headers.removeValue(forKey: existing) }
    }
}

// MARK: - Legado JS 书源引擎（JavaScriptCore）
// 对标阅读(Legado/legado-E)的 @js: / <js> 规则执行环境。
// 之前的引擎把一切 @js:/<js> 规则直接 return []，导致大量书源"搜得到但看不了"
// （目录、正文、URL 拼接常用 JS 做解密/构造）。iOS 自带 JavaScriptCore，完全可以
// 执行这些 JS —— 这里注入 Legado 书源 JS 依赖的内置对象（java/source/book）和
// 全局变量（result/baseUrl/key/page/geturl），执行后读回 result。

final class LegadoJS {

    struct BookCtx: Codable, Equatable, Hashable {
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
    private static let androidIdentifier: String = {
        let key = "ReaderPro.sourceAndroidIdentifier"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let generated = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }()

    static func variable(_ key: String) -> String {
        storeLock.lock(); defer { storeLock.unlock() }
        return store[LegadoJSCtx.sourceUrl]?[key] ?? ""
    }
    static func putVariable(_ key: String, _ value: String) {
        storeLock.lock(); defer { storeLock.unlock() }
        store[LegadoJSCtx.sourceUrl, default: [:]][key] = value
    }

    static func persistentValues(source: String) -> [String: String] {
        storeLock.lock(); defer { storeLock.unlock() }
        let identity = source.isEmpty ? "global" : source
        let key = "ReaderPro.sourceValues." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if store[identity] == nil { store[identity] = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        return store[identity] ?? [:]
    }
    static func putPersistentValue(_ key: String, value: String, source: String) {
        _ = persistentValues(source: source)
        storeLock.lock(); defer { storeLock.unlock() }
        let identity = source.isEmpty ? "global" : source
        let storage = "ReaderPro.sourceValues." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        store[identity, default: [:]][key] = value
        UserDefaults.standard.set(store[identity], forKey: storage)
    }

    // 执行一段 JS 规则。input 是规则输入（result 初始值），返回执行后 result 的字符串值。
    static func run(_ js: String, input: String, baseUrl: String,
                    sourceKey: String, sourceUrl: String,
                    loginInfo: [String: String] = [:], header: [String: String] = [:],
                    book: BookCtx? = nil, page: Int? = nil, originalContent: String? = nil,
                    structuredResult: Any? = nil, expandTemplates: Bool = true,
                    urlContext: SourceJSURLContext? = nil, response: SourcePage? = nil) -> String {
        let page = page ?? LegadoJSCtx.page
        if Task.isCancelled || (LegadoJSCtx.deadline.map { $0 <= Date() } ?? false) {
            LegadoJSCtx.failures?.add(Task.isCancelled ? "书源脚本已取消" : "书源脚本执行超时")
            return ""
        }
        // A single search can evaluate hundreds of field scripts without an
        // async suspension. Drain Objective-C JSValue/context temporaries per
        // evaluation instead of retaining them until the worker's outer pool.
        return autoreleasepool {
            runInPool(js, input: input, baseUrl: baseUrl, sourceKey: sourceKey, sourceUrl: sourceUrl,
                      loginInfo: loginInfo, header: header, book: book, page: page,
                      originalContent: originalContent, structuredResult: structuredResult,
                      expandTemplates: expandTemplates, urlContext: urlContext, response: response)
        }
    }

    private static func runInPool(_ js: String, input: String, baseUrl: String,
                                  sourceKey: String, sourceUrl: String,
                                  loginInfo: [String: String], header: [String: String],
                                  book: BookCtx?, page: Int, originalContent: String?,
                                  structuredResult: Any?, expandTemplates: Bool,
                                  urlContext: SourceJSURLContext?, response: SourcePage?) -> String {
        let script = SourceScript.adaptingJavaCalls(expandTemplates ? expandScriptRuleTemplates(js, input: originalContent ?? input, base: baseUrl, key: sourceKey,
                                              page: page, sourceURL: sourceUrl, book: book) : js).trimmingCharacters(in: .whitespacesAndNewlines)
        if script.isEmpty { return input }
        guard let ctx = JSContext() else { return input }
        guard let budget = SourceJSBudget.install(ctx) else {
            LegadoJSCtx.failures?.add("当前系统不支持安全中断书源脚本，已停止执行")
            return ""
        }
        defer { budget.clear() }
        var exception = ""
        ctx.exceptionHandler = { _, error in exception = error?.toString() ?? "未知 JavaScript 错误" }

        let storeKey = sourceUrl.isEmpty ? "global" : sourceUrl
        let persistentStoreKey = "ReaderPro.sourceValues." + SHA256.hash(data: Data(storeKey.utf8)).map { String(format: "%02x", $0) }.joined()
        storeLock.lock()
        if store[storeKey] == nil { store[storeKey] = UserDefaults.standard.dictionary(forKey: persistentStoreKey) as? [String: String] ?? [:] }
        storeLock.unlock()

        // ---- 全局变量 ----
        ctx.setObject(structuredResult ?? input, forKeyedSubscript: "result" as NSString)
        ctx.setObject(originalContent ?? input, forKeyedSubscript: "src" as NSString)
        ctx.setObject(baseUrl, forKeyedSubscript: "baseUrl" as NSString)
        ctx.setObject(sourceKey, forKeyedSubscript: "key" as NSString)
        ctx.setObject(page, forKeyedSubscript: "page" as NSString)
        ctx.setObject(LegadoJSCtx.speakText, forKeyedSubscript: "speakText" as NSString)
        ctx.setObject(LegadoJSCtx.speakSpeed, forKeyedSubscript: "speakSpeed" as NSString)
        ctx.setObject(sourceUrl, forKeyedSubscript: "sourceUrl" as NSString)
        ctx.setObject(LegadoJSCtx.strictContentHTTP, forKeyedSubscript: "_strictContentHTTP" as NSString)
        let geturl: @convention(block) () -> String = { baseUrl }
        ctx.setObject(geturl, forKeyedSubscript: "geturl" as NSString)

        // ---- java 对象（跨页键值存储 + 工具方法）----
        let java = JSValue(newObjectIn: ctx)!
        let jget: @convention(block) (String) -> String = { k in
            storeLock.lock(); defer { storeLock.unlock() }
            return store[storeKey]?[k] ?? ""
        }
        let jput: @convention(block) (String, JSValue) -> String = { k, v in
            storeLock.lock(); defer { storeLock.unlock() }
            if store[storeKey] == nil { store[storeKey] = [:] }
            store[storeKey]?[k] = v.toString() ?? ""
            UserDefaults.standard.set(store[storeKey], forKey: persistentStoreKey)
            return v.toString() ?? ""
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
        java.setObject(LegadoJS.traditionalToSimplifiedBlock, forKeyedSubscript: "t2s" as NSString)
        java.setObject(LegadoJS.simplifiedToTraditionalBlock, forKeyedSubscript: "s2t" as NSString)
        if let urlContext {
            java.setObject(urlContext.url, forKeyedSubscript: "url" as NSString)
            let map = JSValue(newObjectIn: ctx)!
            let get: @convention(block) (String) -> String = { urlContext.header($0) }
            let put: @convention(block) (String, String) -> Void = { urlContext.setHeader($0, $1) }
            let remove: @convention(block) (String) -> Void = { urlContext.removeHeader($0) }
            map.setObject(get, forKeyedSubscript: "get" as NSString)
            map.setObject(put, forKeyedSubscript: "put" as NSString)
            map.setObject(remove, forKeyedSubscript: "remove" as NSString)
            java.setObject(map, forKeyedSubscript: "headerMap" as NSString)
        }
        java.setObject(LegadoJS.urlEncodeBlock, forKeyedSubscript: "urlEncode" as NSString)
        java.setObject(LegadoJS.urlEncodeBlock, forKeyedSubscript: "encodeURI" as NSString)
        var content = originalContent ?? input
        let getString: @convention(block) (String, String, Bool) -> String = { rule, text, isURL in
            let values = applyRule(text, rule, base: baseUrl)
            let value = values.joined(separator: "\n")
            return isURL ? resolveUrl(value, base: baseUrl) : value
        }
        func encodedStrings(_ values: [String]) -> String {
            guard let data = try? JSONEncoder().encode(values), let json = String(data: data, encoding: .utf8) else {
                JSContext.current()?.exception = JSValue(newErrorFromMessage: "脚本列表序列化失败", in: JSContext.current())
                return "[]"
            }
            return json
        }
        let getElements: @convention(block) (String, String) -> String = { rule, text in encodedStrings(applyRule(text, rule, base: baseUrl)) }
        let getContent: @convention(block) () -> String = { content }
        let setContent: @convention(block) (String) -> Void = { content = $0 }
        java.setObject(getString, forKeyedSubscript: "_getString" as NSString)
        java.setObject(getElements, forKeyedSubscript: "_getElements" as NSString)
        java.setObject(getContent, forKeyedSubscript: "_content" as NSString)
        java.setObject(setContent, forKeyedSubscript: "_setContent" as NSString)
        java.setObject(LegadoJS.urlDecodeBlock, forKeyedSubscript: "urlDecode" as NSString)
        java.setObject(LegadoJS.formatDateBlock, forKeyedSubscript: "formatDate" as NSString)
        java.setObject(LegadoJS.timeMillisBlock, forKeyedSubscript: "timeMillis" as NSString)
        java.setObject(LegadoJS.timeMillisBlock, forKeyedSubscript: "time" as NSString)
        java.setObject(LegadoJS.substringBlock, forKeyedSubscript: "subString" as NSString)
        java.setObject(LegadoJS.substringBlock, forKeyedSubscript: "substring" as NSString)
        java.setObject(LegadoJS.strBlock, forKeyedSubscript: "str" as NSString)
        ctx.setObject(java, forKeyedSubscript: "java" as NSString)

        // Return one string over the Objective-C/JavaScriptCore callback
        // boundary. Returning nested Swift dictionaries requires JavaScriptCore
        // to recursively bridge transient containers while a script is active.
        let request: @convention(block) (String, String, String, String, Double, Bool) -> String = { address, method, body, headersJSON, timeout, follow in
            let result: [String: Any]
            do {
                let defaults = SourceLoginHeaders.merge(urlContext?.headers ?? LegadoJSCtx.headers, source: sourceUrl)
                let headers = SourceLoginHeaders.overlay(SourceHTTP.headers(headersJSON), onto: defaults)
                result = try SourceJSBridge.request(address, base: baseUrl, headers: headers,
                                                    method: method, body: body,
                                                    timeout: timeout > 0 ? timeout / 1000 : 20, followRedirects: follow)
            } catch {
                result = ["error": sourceErrorMessage(error)]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: result),
                  let json = String(data: data, encoding: .utf8) else {
                return #"{"error":"脚本网络响应序列化失败"}"#
            }
            return json
        }
        java.setObject(request, forKeyedSubscript: "_request" as NSString)
        let requests: @convention(block) (String, Bool, Double, Bool) -> String = { json, skipRateLimit, timeout, isTest in
            do {
                let addresses = try JSONDecoder().decode([String].self, from: Data(json.utf8))
                let headers = SourceLoginHeaders.merge(urlContext?.headers ?? LegadoJSCtx.headers, source: sourceUrl)
                let results = try SourceJSBridge.requestAll(addresses, base: baseUrl, headers: headers, skipRateLimit: skipRateLimit,
                                                            timeout: timeout > 0 ? timeout / 1000 : 20, isTest: isTest)
                return String(decoding: try JSONSerialization.data(withJSONObject: results), as: UTF8.self)
            } catch {
                JSContext.current()?.exception = JSValue(newErrorFromMessage: sourceErrorMessage(error), in: JSContext.current())
                return "[]"
            }
        }
        java.setObject(requests, forKeyedSubscript: "_requests" as NSString)
        let parseURL: @convention(block) (String, String) -> String = { address, base in
            do {
                let relativeBase = base.isEmpty ? nil : URL(string: base)
                guard let url = URL(string: address, relativeTo: relativeBase)?.absoluteURL,
                      let parts = URLComponents(url: url, resolvingAgainstBaseURL: true), let scheme = parts.scheme else {
                    throw SourceFailure(stage: "脚本 URL", message: "无效的绝对地址或基准地址")
                }
                var params: [String: String] = [:]
                for pair in (parts.percentEncodedQuery ?? "").split(separator: "&", omittingEmptySubsequences: false) {
                    let fields = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard fields.count == 2 else { continue }
                    // Android JsURL decodes values as form data, retains the
                    // original key, and keeps the last duplicated parameter.
                    params[String(fields[0])] = String(fields[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(fields[1])
                }
                let host = parts.host ?? ""
                let origin = scheme + "://" + host + (parts.port.map { ":\($0)" } ?? "")
                var result: [String: Any] = ["host": host, "origin": origin, "pathname": parts.percentEncodedPath]
                if parts.percentEncodedQuery == nil { result["searchParams"] = NSNull() }
                else { result["searchParams"] = params }
                return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
            } catch {
                JSContext.current()?.exception = JSValue(newErrorFromMessage: sourceErrorMessage(error), in: JSContext.current())
                return "{}"
            }
        }
        java.setObject(parseURL, forKeyedSubscript: "_toURL" as NSString)
        let log: @convention(block) (String) -> Void = { SourceExecutionLog.shared.add($0, source: sourceUrl) }
        java.setObject(log, forKeyedSubscript: "_log" as NSString)
        let importScript: @convention(block) (String) -> String = { path in
            do {
                let headers = SourceLoginHeaders.merge(urlContext?.headers ?? LegadoJSCtx.headers, source: sourceUrl)
                return try SourceJSBridge.importScript(path, base: baseUrl, headers: headers, source: sourceUrl)
            } catch {
                JSContext.current()?.exception = JSValue(newErrorFromMessage: sourceErrorMessage(error), in: JSContext.current())
                return ""
            }
        }
        java.setObject(importScript, forKeyedSubscript: "importScript" as NSString)
        let invalidateImportedScripts: @convention(block) () -> Void = { SourceJSBridge.invalidateImportedScripts() }
        java.setObject(invalidateImportedScripts, forKeyedSubscript: "_invalidateImportedScripts" as NSString)
        let web: @convention(block) (String, String, String, String, String, Bool, Double) -> String = { html, address, script, resourceRegex, navigationRegex, cacheFirst, delay in
            do {
                let request = try SourceHTTP.request(address.isEmpty ? baseUrl : address, base: baseUrl, headers: LegadoJSCtx.headers)
                return try SourceJSBridge.web(request, html: html, script: script, delay: max(0, delay) / 1000,
                                              resourceRegex: resourceRegex.isEmpty ? nil : resourceRegex,
                                              navigationRegex: navigationRegex.isEmpty ? nil : navigationRegex, cacheFirst: cacheFirst).text
            } catch {
                JSContext.current()?.exception = JSValue(newErrorFromMessage: sourceErrorMessage(error), in: JSContext.current())
                return ""
            }
        }
        java.setObject(web, forKeyedSubscript: "_webView" as NSString)
        let verification: @convention(block) (String, String, String, Bool, Bool) -> String = { address, title, html, refetch, image in
            do {
                let request = try SourceHTTP.request(address, base: baseUrl, headers: LegadoJSCtx.headers)
                let verified = try SourceJSBridge.verify(request, title: title, html: html.isEmpty ? nil : html, image: image)
                if image { return verified.text }
                let response: [String: Any]
                if refetch { response = try SourceJSBridge.request(verified.url, base: baseUrl, headers: LegadoJSCtx.headers) }
                else { response = ["text": verified.text, "url": verified.url, "status": 200, "headers": [String: String]()] }
                return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
            } catch { JSContext.current()?.exception = JSValue(newErrorFromMessage: sourceErrorMessage(error), in: JSContext.current()); return "" }
        }
        java.setObject(verification, forKeyedSubscript: "_verify" as NSString)
        let browse: @convention(block) (String, String, JSValue) -> Void = { address, title, html in
            do {
                let request = try SourceHTTP.request(address, base: baseUrl, headers: LegadoJSCtx.headers)
                let source = LegadoJSCtx.ruleSource, content = html.isNull || html.isUndefined ? nil : html.toString()
                Task { @MainActor in
                    do { _ = try await SourceVerification.open(request: request, title: title, html: content, source: source, timeout: 180) }
                    catch { if !(error is CancellationError) { SourceExecutionLog.shared.add(sourceErrorMessage(error), source: sourceUrl) } }
                }
            } catch { JSContext.current()?.exception = JSValue(newErrorFromMessage: sourceErrorMessage(error), in: JSContext.current()) }
        }
        java.setObject(browse, forKeyedSubscript: "startBrowser" as NSString)
        java.setObject(browse, forKeyedSubscript: "openUrl" as NSString)
        let select: @convention(block) (String, String) -> String = { text, selector in encodedStrings(LegadoDOM.css(text, selector).map(\.full)) }
        let attribute: @convention(block) (String, String) -> String = { text, name in
            LegadoDOM.css(text, "body > *").first.map { htmlAttrs($0.open)[name.lowercased()] ?? "" } ?? ""
        }
        let textOnly: @convention(block) (String) -> String = { stripText($0, preserveNewlines: false) }
        let unescapeEntities: @convention(block) (String, Bool) -> String = { text, inAttribute in
            LegadoDOM.unescapeEntities(text, inAttribute: inAttribute)
        }
        java.setObject(select, forKeyedSubscript: "_select" as NSString)
        java.setObject(attribute, forKeyedSubscript: "_attr" as NSString)
        java.setObject(textOnly, forKeyedSubscript: "_textOnly" as NSString)
        java.setObject(unescapeEntities, forKeyedSubscript: "_unescapeEntities" as NSString)
        let cookieRead: @convention(block) (String) -> String = { address in
            guard let url = URL(string: resolveUrl(address, base: baseUrl)) else { return "" }
            return (HTTPCookieStorage.shared.cookies(for: url) ?? []).map { $0.name + "=" + $0.value }.joined(separator: "; ")
        }
        let cookieWrite: @convention(block) (String, String) -> Void = { address, value in
            guard let url = URL(string: resolveUrl(address, base: baseUrl)) else { return }
            // Legado accepts a Cookie request header containing several pairs.
            let attributes: Set<String> = ["path", "domain", "expires", "max-age", "samesite", "secure", "httponly"]
            for pair in value.components(separatedBy: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, !attributes.contains(parts[0].lowercased()) else { continue }
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": parts.joined(separator: "=") + "; Path=/"], for: url)
                for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
            }
        }
        let cookieRemove: @convention(block) (String) -> Void = { address in
            guard let url = URL(string: resolveUrl(address, base: baseUrl)) else { return }
            for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] { HTTPCookieStorage.shared.deleteCookie(cookie) }
        }
        let cookies = JSValue(newObjectIn: ctx)!
        cookies.setObject(cookieRead, forKeyedSubscript: "getCookie" as NSString)
        cookies.setObject(cookieWrite, forKeyedSubscript: "setCookie" as NSString)
        cookies.setObject(cookieRemove, forKeyedSubscript: "removeCookie" as NSString)
        ctx.setObject(cookies, forKeyedSubscript: "cookie" as NSString)

        // ---- source 对象 ----
        let source = JSValue(newObjectIn: ctx)!
        // Legado BaseSource.getKey identifies the source, while the global
        // `key` remains the current search keyword.
        let getKey: @convention(block) () -> String = { sourceUrl }
        let getSourceUrl: @convention(block) () -> String = { sourceUrl }
        let loginContext = LegadoJSCtx.loginContext
        let savedLogin = loginInfo.isEmpty ? SourceLoginInfo.map(sourceUrl) : loginInfo
        let getLoginMap: @convention(block) () -> [String: String] = { loginContext?.values ?? savedLogin }
        let getLoginStr: @convention(block) () -> JSValue? = {
            guard let context = JSContext.current() else { return nil }
            let values = loginContext?.values ?? savedLogin
            guard !values.isEmpty else { return JSValue(nullIn: context) }
            let data = try? JSONSerialization.data(withJSONObject: values, options: .sortedKeys)
            return JSValue(object: data.map { String(decoding: $0, as: UTF8.self) } ?? "{}", in: context)
        }
        let getHeader: @convention(block) () -> [String: String] = { header }
        let concurrentBox = ConcurrentBox()
        let getConcurrent: @convention(block) () -> Int = { concurrentBox.value }
        let putConcurrent: @convention(block) (JSValue) -> Void = { v in concurrentBox.value = Int(v.toNumber()?.intValue ?? 0) }
        source.setObject(sourceUrl, forKeyedSubscript: "key" as NSString)
        source.setObject(sourceUrl, forKeyedSubscript: "bookSourceUrl" as NSString)
        // Some sources store their decoder library here and eval it from
        // search/info/category rules. Apply the same token-aware Java string
        // adaptation as jsLib; the persisted source comment remains original.
        source.setObject(SourceScript.adaptingJavaCalls(LegadoJSCtx.comment), forKeyedSubscript: "bookSourceComment" as NSString)
        source.setObject(LegadoJSCtx.variableComment as Any? ?? NSNull(), forKeyedSubscript: "variableComment" as NSString)
        // Android exposes the nullable Kotlin data-class rule objects. Its
        // generated toString includes type, declared field order and nulls;
        // real rules also access the same fields directly.
        func installRule(_ name: String, type: String, rule: LegadoSource.RuleSet?, fields: [String]) {
            guard let rule, rule.hasAndroidObject, let object = JSValue(newObjectIn: ctx) else {
                source.setObject(NSNull(), forKeyedSubscript: name as NSString)
                return
            }
            for field in fields {
                object.setObject(rule.androidValue(field) as Any? ?? NSNull(), forKeyedSubscript: field as NSString)
            }
            let description: @convention(block) () -> String = {
                type + "(" + fields.map { $0 + "=" + (rule.androidValue($0) ?? "null") }.joined(separator: ", ") + ")"
            }
            object.setObject(description, forKeyedSubscript: "toString" as NSString)
            source.setObject(object, forKeyedSubscript: name as NSString)
        }
        let bookFields = ["bookList", "name", "author", "intro", "kind", "lastChapter", "updateTime", "bookUrl", "coverUrl", "wordCount"]
        let actualSource = LegadoJSCtx.ruleSource
        installRule("ruleSearch", type: "SearchRule", rule: actualSource?.ruleSearch, fields: ["checkKeyWord"] + bookFields)
        installRule("ruleExplore", type: "ExploreRule", rule: actualSource?.ruleExplore, fields: bookFields)
        installRule("ruleBookInfo", type: "BookInfoRule", rule: actualSource?.ruleBookInfo,
                    fields: ["init", "name", "author", "intro", "kind", "lastChapter", "updateTime", "coverUrl", "tocUrl", "wordCount", "canReName", "downloadUrls"])
        installRule("ruleToc", type: "TocRule", rule: actualSource?.ruleToc,
                    fields: ["preUpdateJs", "chapterList", "chapterName", "chapterUrl", "formatJs", "isVolume", "isVip", "isPay", "updateTime", "nextTocUrl"])
        installRule("ruleContent", type: "ContentRule", rule: actualSource?.ruleContent,
                    fields: ["content", "subContent", "title", "nextContentUrl", "webJs", "sourceRegex", "replaceRegex", "imageStyle", "imageDecode", "payAction", "callBackJs"])
        source.setObject(LegadoJSCtx.loginURL, forKeyedSubscript: "loginUrl" as NSString)
        source.setObject(getKey, forKeyedSubscript: "getKey" as NSString)
        source.setObject(getSourceUrl, forKeyedSubscript: "getBookSourceUrl" as NSString)
        source.setObject(getLoginMap, forKeyedSubscript: "getLoginInfoMap" as NSString)
        source.setObject(getLoginStr, forKeyedSubscript: "getLoginInfo" as NSString)
        let putLoginInfo: @convention(block) (String) -> Bool = { raw in
            do {
                guard let values = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String] else {
                    throw SourceFailure(stage: "书源登录", message: "登录信息必须为字符串字典")
                }
                try SourceLoginInfo.put(values, source: sourceUrl); loginContext?.values = values
                return true
            } catch {
                JSContext.current()?.exception = JSValue(newErrorFromMessage: sourceErrorMessage(error), in: JSContext.current())
                return false
            }
        }
        let removeLoginInfo: @convention(block) () -> Void = {
            do { try SourceLoginInfo.remove(sourceUrl); loginContext?.values = [:] }
            catch { JSContext.current()?.exception = JSValue(newErrorFromMessage: sourceErrorMessage(error), in: JSContext.current()) }
        }
        source.setObject(putLoginInfo, forKeyedSubscript: "putLoginInfo" as NSString)
        source.setObject(removeLoginInfo, forKeyedSubscript: "removeLoginInfo" as NSString)
        let getLoginHeader: @convention(block) () -> JSValue? = {
            guard let context = JSContext.current() else { return nil }
            guard let value = SourceLoginHeaders.get(sourceUrl) else { return JSValue(nullIn: context) }
            return JSValue(object: value, in: context)
        }
        let getLoginHeaderMap: @convention(block) () -> JSValue? = {
            guard let context = JSContext.current() else { return nil }
            guard let values = SourceLoginHeaders.map(sourceUrl) else { return JSValue(nullIn: context) }
            guard let map = JSValue(newObjectIn: context) else { return nil }
            for (key, value) in values { map.setObject(value, forKeyedSubscript: key as NSString) }
            let get: @convention(block) (String) -> JSValue? = { key in
                guard let current = JSContext.current() else { return nil }
                guard let value = values[key] else { return JSValue(nullIn: current) }
                return JSValue(object: value, in: current)
            }
            map.setObject(get, forKeyedSubscript: "get" as NSString)
            return map
        }
        let putLoginHeader: @convention(block) (String) -> Void = { value in
            do {
                try SourceLoginHeaders.put(value, source: sourceUrl)
                let parsed = SourceHTTP.headers(value)
                if let cookie = parsed["Cookie"] ?? parsed["cookie"] { cookieWrite(sourceUrl, cookie) }
            } catch {
                JSContext.current()?.exception = JSValue(newErrorFromMessage: sourceErrorMessage(error), in: JSContext.current())
            }
        }
        let removeLoginHeader: @convention(block) () -> Void = {
            do { try SourceLoginHeaders.remove(sourceUrl); cookieRemove(sourceUrl) }
            catch { JSContext.current()?.exception = JSValue(newErrorFromMessage: sourceErrorMessage(error), in: JSContext.current()) }
        }
        source.setObject(getLoginHeader, forKeyedSubscript: "getLoginHeader" as NSString)
        source.setObject(getLoginHeaderMap, forKeyedSubscript: "getLoginHeaderMap" as NSString)
        source.setObject(putLoginHeader, forKeyedSubscript: "putLoginHeader" as NSString)
        source.setObject(removeLoginHeader, forKeyedSubscript: "removeLoginHeader" as NSString)
        source.setObject(getHeader, forKeyedSubscript: "headerMap" as NSString)
        source.setObject(getConcurrent, forKeyedSubscript: "getConcurrent" as NSString)
        source.setObject(putConcurrent, forKeyedSubscript: "putConcurrent" as NSString)
        source.setObject(jget, forKeyedSubscript: "get" as NSString)
        source.setObject(jput, forKeyedSubscript: "put" as NSString)
        let variableKey = "ReaderPro.sourceVariable." + sourceUrl
        let getVariable: @convention(block) () -> String = { UserDefaults.standard.string(forKey: variableKey) ?? "" }
        let setVariable: @convention(block) (String) -> Void = { UserDefaults.standard.set($0, forKey: variableKey) }
        source.setObject(getVariable, forKeyedSubscript: "getVariable" as NSString)
        source.setObject(setVariable, forKeyedSubscript: "setVariable" as NSString)
        source.setObject(setVariable, forKeyedSubscript: "putVariable" as NSString)
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
        let bookVariableKey = "ReaderPro.bookVariables." + SHA256.hash(data: Data((sourceUrl + "\n" + b.bookUrl).utf8)).map { String(format: "%02x", $0) }.joined()
        let getBookVariable: @convention(block) (String) -> String = { key in
            storeLock.lock(); defer { storeLock.unlock() }
            return (UserDefaults.standard.dictionary(forKey: bookVariableKey) as? [String: String])?[key] ?? ""
        }
        let putBookVariable: @convention(block) (String, JSValue) -> Bool = { key, value in
            storeLock.lock(); defer { storeLock.unlock() }
            var values = UserDefaults.standard.dictionary(forKey: bookVariableKey) as? [String: String] ?? [:]
            values[key] = value.isNull || value.isUndefined ? nil : value.toString()
            UserDefaults.standard.set(values, forKey: bookVariableKey)
            return true
        }
        bookObj.setObject(getBookVariable, forKeyedSubscript: "getVariable" as NSString)
        bookObj.setObject(putBookVariable, forKeyedSubscript: "putVariable" as NSString)
        ctx.setObject(bookObj, forKeyedSubscript: "book" as NSString)
        if LegadoJSCtx.mediaCapture != nil {
            bookObj.setObject(LegadoJSCtx.chapter?.ruleIndex ?? 0, forKeyedSubscript: "durChapterIndex" as NSString)
            let browser: @convention(block) (String) -> Void = { url in LegadoJSCtx.mediaCapture?.set(url) }
            java.setObject(browser, forKeyedSubscript: "startBrowser" as NSString)
            java.setObject(browser, forKeyedSubscript: "openUrl" as NSString)
            ctx.setObject(LegadoJSCtx.chapter?.title ?? "", forKeyedSubscript: "title" as NSString)
        }
        let chapter = LegadoJSCtx.chapter
        ctx.setObject(chapter?.title ?? "", forKeyedSubscript: "title" as NSString)
        let chapterObj = JSValue(newObjectIn: ctx)!
        chapterObj.setObject(chapter?.title ?? "", forKeyedSubscript: "title" as NSString)
        chapterObj.setObject(chapter?.url ?? baseUrl, forKeyedSubscript: "url" as NSString)
        chapterObj.setObject(chapter?.ruleIndex ?? 0, forKeyedSubscript: "index" as NSString)
        chapterObj.setObject(chapter?.isVolume ?? false, forKeyedSubscript: "isVolume" as NSString)
        chapterObj.setObject(chapter?.isVip ?? false, forKeyedSubscript: "isVip" as NSString)
        chapterObj.setObject(chapter?.isPay ?? false, forKeyedSubscript: "isPay" as NSString)
        ctx.setObject(chapterObj, forKeyedSubscript: "chapter" as NSString)

        let notify: @convention(block) (String, String, Bool) -> Void = { message, tag, long in
            SourceExecutionLog.shared.add(tag.isEmpty ? message : tag + ": " + message, source: sourceUrl)
            Task { @MainActor in SourceScriptToast.show(message, tag: tag, long: long) }
        }
        java.setObject(notify, forKeyedSubscript: "_toast" as NSString)
        ctx.evaluateScript(Self.compatibilityScript)
        ctx.evaluateScript(#"""
        function _loginMap(value) {
            Object.defineProperties(value, {
                get: {value:function(k){return this[k] == null ? null : this[k];}},
                put: {value:function(k,v){var old=this[k];this[k]=String(v);return old;}},
                containsKey: {value:function(k){return Object.prototype.hasOwnProperty.call(this,k);}},
                size: {value:function(){return Object.keys(this).length;}},
                isEmpty: {value:function(){return Object.keys(this).length===0;}},
                keySet: {value:function(){return _array(Object.keys(this));}}
            });
            return value;
        }
        var _getLoginInfoMap = source.getLoginInfoMap;
        source.getLoginInfoMap = function(){return _loginMap(_getLoginInfoMap());};
        source.login = function(){eval(source.loginUrl.replace(/^@js:/,'').replace(/^<js>/,'').replace(/<\/js>\s*$/,'')); if(typeof login==='function') return login(); throw Error('书源未实现 login 函数');};
        """#)
        if let loginContext {
            ctx.setObject(loginContext.isLongClick, forKeyedSubscript: "isLongClick" as NSString)
            ctx.evaluateScript("if(result !== null && typeof result === 'object' && !Array.isArray(result)) result = _loginMap(result)")
            let update: @convention(block) (JSValue) -> Void = { value in
                if value.isNull || value.isUndefined { loginContext.resetDefaults = true; return }
                if let fields = value.toDictionary() as? [String: Any] {
                    for (key, item) in fields {
                        let text = item is NSNull ? "" : String(describing: item)
                        loginContext.updates[key] = text; loginContext.values[key] = text
                    }
                }
            }
            let rebuild: @convention(block) () -> Void = { loginContext.rebuild = true }
            let toast: @convention(block) (String) -> Void = { loginContext.message = $0 }
            let copy: @convention(block) (String) -> Void = { loginContext.copyText = $0 }
            let browser: @convention(block) (String) -> Void = { url in loginContext.browser = SourceLoginBrowser(url: resolveUrl(url, base: baseUrl)) }
            let showBrowser: @convention(block) (String, JSValue, JSValue) -> Void = { url, html, script in
                loginContext.browser = SourceLoginBrowser(url: resolveUrl(url, base: baseUrl),
                    html: html.isNull || html.isUndefined ? nil : html.toString(),
                    script: script.isNull || script.isUndefined ? nil : script.toString())
            }
            java.setObject(update, forKeyedSubscript: "upLoginData" as NSString)
            java.setObject(rebuild, forKeyedSubscript: "reLoginView" as NSString)
            java.setObject(rebuild, forKeyedSubscript: "reUiView" as NSString)
            java.setObject(rebuild, forKeyedSubscript: "refreshExplore" as NSString)
            java.setObject(toast, forKeyedSubscript: "toast" as NSString)
            java.setObject(toast, forKeyedSubscript: "longToast" as NSString)
            java.setObject(copy, forKeyedSubscript: "copyText" as NSString)
            java.setObject(browser, forKeyedSubscript: "startBrowser" as NSString)
            java.setObject(browser, forKeyedSubscript: "openUrl" as NSString)
            java.setObject(showBrowser, forKeyedSubscript: "showBrowser" as NSString)
        }
        if structuredResult is [String] {
            ctx.evaluateScript("result = _elements(result)")
        }
        let infoMap: @convention(block) (String, String) -> String = { operation, payload in
            ExploreInfo.bridge(sourceUrl, operation, payload)
        }
        let refreshExplore: @convention(block) () -> Void = { ExploreInfo.refresh(sourceUrl) }
        ctx.setObject(infoMap, forKeyedSubscript: "_exploreInfo" as NSString)
        if loginContext == nil { java.setObject(refreshExplore, forKeyedSubscript: "refreshExplore" as NSString) }
        ctx.evaluateScript(Self.exploreInfoScript)
        SourceCrypto.install(java, context: ctx)
        SourceFiles.install(java, base: baseUrl)
        SourceFont.install(java, context: ctx, base: baseUrl)
        ctx.evaluateScript(#"""
        java.downloadFile=function(content,url){return java._file('download',String(content),url==null?'':String(url),'');};
        java.readTxtFile=function(path,charset){return java._file('read',String(path),'',charset||'');};
        java.readFile=function(path){return _array(JSON.parse(java._file('readBytes',String(path),'','')));};
        java.deleteFile=function(path){return java._file('delete',String(path),'','')==='true';};
        java.unzipFile=function(path){return java._file('unzip',String(path),'','');};
        java.unArchiveFile=java.un7zFile=java.unrarFile=java.unzipFile;
        java.getTxtInFolder=function(path){return java._file('folder',String(path),'','');};
        java.getZipStringContent=function(url,path,charset){return java._file('zipText',String(url),String(path),charset||'');};
        java.getZipByteArrayContent=function(url,path){var a=JSON.parse(java._file('zipBytes',String(url),String(path),''));return a==null?null:_array(a);};
        java.getRarStringContent=java.get7zStringContent=function(url,path,charset){return java._file('archiveText',String(url),String(path),charset||'');};
        java.getRarByteArrayContent=java.get7zByteArrayContent=function(url,path){var a=JSON.parse(java._file('archiveBytes',String(url),String(path),''));return a==null?null:_array(a);};
        java.getFile=function(path){
          path=String(path);function stat(){return JSON.parse(java._file('stat',path,'',''));}
          return {path:path,absolutePath:path,getPath:function(){return path;},getAbsolutePath:function(){return path;},
            getName:function(){return stat().name;},exists:function(){return stat().exists;},isFile:function(){return stat().file;},
            isDirectory:function(){return stat().directory;},length:function(){return stat().length;},
            delete:function(){return java.deleteFile(path);},toString:function(){return path;}};
        };
        java.cacheFile=function(url,saveTime){
          url=String(url);var key=java.md5Encode16(url),path=cache.get(key);
          if(!path||!java.getFile(path).exists()){path=java.downloadFile(url);cache.put(key,path,Number(saveTime)||0);}
          return java.readTxtFile(path);
        };
        """#)
        let digest: @convention(block) (JSValue, String) -> String = { text, algorithm in
            let data = SourceCrypto.bytes(text)
            let bytes: [UInt8]
            switch algorithm.uppercased().replacingOccurrences(of: "-", with: "") {
            case "MD5": bytes = Array(Insecure.MD5.hash(data: data))
            case "SHA1": bytes = Array(Insecure.SHA1.hash(data: data))
            case "SHA256": bytes = Array(SHA256.hash(data: data))
            case "SHA384": bytes = Array(SHA384.hash(data: data))
            case "SHA512": bytes = Array(SHA512.hash(data: data))
            default:
                JSContext.current()?.exception = JSValue(newErrorFromMessage: "不支持的摘要算法：" + algorithm, in: JSContext.current()); return ""
            }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        let randomUUID: @convention(block) () -> String = { UUID().uuidString.lowercased() }
        let androidID: @convention(block) () -> String = { androidIdentifier }
        java.setObject(androidID, forKeyedSubscript: "androidId" as NSString)
        let chapterNumber: @convention(block) (String) -> String = { text in
            guard let regex = try? NSRegularExpression(pattern: "第([零〇一二两三四五六七八九十百千万亿]+)([章回节集卷部])") else { return text }
            var result = text
            let digits: [Character: Int] = ["零":0, "〇":0, "一":1, "二":2, "两":2, "三":3, "四":4, "五":5, "六":6, "七":7, "八":8, "九":9]
            let units: [Character: Int] = ["十":10, "百":100, "千":1000, "万":10000, "亿":100000000]
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                var total = 0, section = 0, number = 0
                for char in ns.substring(with: match.range(at: 1)) {
                    if let digit = digits[char] { number = digit }
                    else if let unit = units[char] {
                        if unit < 10000 { section += max(number, 1) * unit }
                        else { total += (section + number) * unit; section = 0 }
                        number = 0
                    }
                }
                let replacement = "第\(total + section + number)" + ns.substring(with: match.range(at: 2))
                if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: replacement) }
            }
            return result
        }
        java.setObject(digest, forKeyedSubscript: "digestHex" as NSString)
        let timeFormatUTC: @convention(block) (JSValue, String, Int) -> String = { value, format, offset in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            // legado-E passes sh directly to SimpleTimeZone (milliseconds).
            let millis = value.toNumber()?.doubleValue ?? 0
            guard millis.isFinite else { return "" }
            return formatter.string(from: Date(timeIntervalSince1970: (millis + Double(offset)) / 1000))
        }
        java.setObject(timeFormatUTC, forKeyedSubscript: "timeFormatUTC" as NSString)
        java.setObject(randomUUID, forKeyedSubscript: "randomUUID" as NSString)
        java.setObject(chapterNumber, forKeyedSubscript: "toNumChapter" as NSString)
        let getUA: @convention(block) () -> String = { sourceUA }
        java.setObject(getUA, forKeyedSubscript: "getWebViewUA" as NSString)
        let htmlFormat: @convention(block) (String) -> String = { SourceHTMLFormatter.format($0) }
        java.setObject(htmlFormat, forKeyedSubscript: "htmlFormat" as NSString)
        let mediaCapture = LegadoJSCtx.mediaCapture, mediaSource = LegadoJSCtx.ruleSource
        let openVideo: @convention(block) (String, JSValue, JSValue) -> Void = { address, title, _ in
            let resolved = resolveUrl(address, base: baseUrl)
            if let mediaCapture { mediaCapture.set(resolved); return }
            let name = title.isNull || title.isUndefined ? "视频" : title.toString() ?? "视频"
            Task { @MainActor in
                do { try SourceScriptVideo.open(url: resolved, title: name, base: baseUrl, source: mediaSource) }
                catch { SourceExecutionLog.shared.add(sourceErrorMessage(error), source: sourceUrl) }
            }
        }
        java.setObject(openVideo, forKeyedSubscript: "openVideoPlayer" as NSString)
        let configuration: @convention(block) (String) -> String = { kind in
            switch kind {
            case "mode": return SourceScriptConfiguration.themeMode()
            case "theme": return SourceScriptConfiguration.json(SourceScriptConfiguration.themeConfig())
            default: return SourceScriptConfiguration.json(SourceScriptConfiguration.readConfig())
            }
        }
        java.setObject(configuration, forKeyedSubscript: "_configuration" as NSString)
        ctx.evaluateScript(Self.javaStringScript)
        ctx.evaluateScript(SourceJava.script)
        if let response {
            var payload: [String: Any] = ["text": response.text, "url": response.url, "status": response.status, "headers": response.headers]
            if let bytes = response.bytes { payload["bytesBase64"] = bytes.base64EncodedString() }
            if let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) {
                ctx.setObject(false, forKeyedSubscript: "_strictContentHTTP" as NSString)
                let value = ctx.objectForKeyedSubscript("_response")?.call(withArguments: [json])
                // StrResponse exposes url as a field in Android login checks.
                value?.setObject(response.url, forKeyedSubscript: "url" as NSString)
                ctx.setObject(value, forKeyedSubscript: "result" as NSString)
            }
        }

        // ---- 执行 ----
        // 关键修复：JS 规则大量用「最后一行是表达式」的方式返回结果，
        // 例如 exploreUrl 的 @js:...;JSON.stringify(s)，正文规则的 @js:...;result。
        // 之前把 evaluateScript 的返回值丢弃了、只读 result 变量，导致
        // JSON.stringify(...) 这种「靠返回值」的规则全部拿不到结果（发现/搜索/正文全空）。
        let library = LegadoJSCtx.library.trimmingCharacters(in: .whitespacesAndNewlines)
        if !library.isEmpty {
            let mappedURLs = SourceScript.remoteLibraryURLs(library)
            let scripts: [String]
            if let mappedURLs {
                scripts = mappedURLs
            } else {
                scripts = [library]
            }
            for item in scripts {
                var source = item
                if item.hasPrefix("http://") || item.hasPrefix("https://") {
                    do {
                        let response = try SourceJSBridge.request(item, base: sourceUrl, headers: header)
                        let status = response["status"] as? Int ?? 0
                        guard (200..<300).contains(status) else {
                            LegadoJSCtx.failures?.add("远程 jsLib：HTTP \(status)（\(item)）"); return ""
                        }
                        source = response["text"] as? String ?? ""
                    } catch {
                        LegadoJSCtx.failures?.add("远程 jsLib：" + sourceErrorMessage(error)); return ""
                    }
                }
                source = SourceScript.adaptingJavaCalls(source)
                ctx.evaluateScript(source)
                if exception.contains("Cannot declare a let variable twice") {
                    let repaired = SourceScript.repairingParameterRedeclarations(source)
                    if repaired != source {
                        exception = ""; ctx.exception = nil
                        ctx.evaluateScript(repaired)
                    }
                }
                guard exception.isEmpty else { LegadoJSCtx.failures?.add("远程 jsLib：" + exception); return "" }
            }
        }
        let ret = ctx.evaluateScript(script)
        if budget.terminated {
            LegadoJSCtx.failures?.add(Task.isCancelled ? "书源脚本已取消" : "书源脚本执行超时，已终止无限重试或长时间计算")
            return ""
        }
        guard exception.isEmpty else {
            LegadoJSCtx.failures?.add(exception)
            return ""
        }
        if let urlContext, let updated = java.objectForKeyedSubscript("url"), !updated.isUndefined, !updated.isNull {
            urlContext.url = updated.toString() ?? urlContext.url
            if let ret { urlContext.returnedValue = !ret.isUndefined && !ret.isNull }
        }
        if response != nil {
            let value = ret?.isUndefined == false ? ret : ctx.objectForKeyedSubscript("result")
            guard let value, value.isObject, value.hasProperty("body"),
                  let body = value.invokeMethod("body", withArguments: [])?.toString(),
                  let status = value.invokeMethod("code", withArguments: [])?.toInt32() else {
                LegadoJSCtx.failures?.add("loginCheckJs 必须返回响应对象，例如 result 或 java.connect(url)")
                return ""
            }
            let address: String
            if let url = value.objectForKeyedSubscript("url"), url.isString { address = url.toString() ?? baseUrl }
            else { address = value.invokeMethod("url", withArguments: [])?.toString() ?? baseUrl }
            let headers = value.invokeMethod("headers", withArguments: [])?.toDictionary() as? [String: String] ?? [:]
            guard exception.isEmpty else { LegadoJSCtx.failures?.add(exception); return "" }
            var payload: [String: Any] = ["text": body, "url": address, "status": Int(status), "headers": headers]
            if response?.bytes != nil {
                let object = value.invokeMethod("body", withArguments: [])
                if let values = object?.invokeMethod("bytes", withArguments: [])?.toArray() as? [NSNumber],
                   values.allSatisfy({ (-128...255).contains($0.intValue) }) {
                    payload["bytesBase64"] = Data(values.map { UInt8(truncatingIfNeeded: $0.intValue) }).base64EncodedString()
                } else { LegadoJSCtx.failures?.add("在线朗读登录检测必须返回包含音频字节的响应"); return "" }
            }
            return (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        func string(_ value: JSValue?) -> String? {
            guard let value, !value.isNull, !value.isUndefined else { return nil }
            if value.isObject {
                if let constructor = ctx.objectForKeyedSubscript("_JavaString"), value.isInstance(of: constructor) {
                    return value.toString()
                }
                return ctx.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [value])?.toString()
            }
            return value.toString()
        }
        // An explicit empty string is a real result, never substitute input.
        return string(ret) ?? string(ctx.objectForKeyedSubscript("result")) ?? ""
    }

    // MARK: 工具 block（静态，避免每次 run 重复创建）

    // Foundation uses ICU's character conversion. Legado uses a different
    // dictionary with explicit phrase exclusions, so regional phrase choices
    // are not guaranteed to be identical even when individual characters are.
    static let traditionalToSimplifiedBlock: @convention(block) (String) -> String = { text in
        text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
    }
    static let simplifiedToTraditionalBlock: @convention(block) (String) -> String = { text in
        text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: true) ?? text
    }

    private static let exploreInfoScript = #"""
    var infoMap = (function() {
        function call(op, args) { return JSON.parse(_exploreInfo(op, JSON.stringify(args))); }
        function map(value) {
            Object.defineProperties(value, {
                get: {value: function(k) {return this[String(k)] == null ? null : this[String(k)];}},
                put: {value: function(k,v) {var old=this[k]; this[k]=String(v); return old;}},
                size: {value: function() {return Object.keys(this).length;}},
                keySet: {value: function() {return _array(Object.keys(this));}}
            });
            return value;
        }
        return {
            get: function(k) {return arguments.length ? call('get',[String(k)]) : map(call('get',[]));},
            put: function(k,v) {return call('put',[String(k),String(v)]);},
            remove: function(k) {return call('remove',[String(k)]);},
            clear: function() {call('clear',[]);},
            set: function(v) {call('set',[v]);},
            putAll: function(v) {call('putAll',[v]);},
            containsKey: function(k) {return call('get',[String(k)]) !== null;},
            containsValue: function(v) {var m=call('get',[]); return Object.keys(m).some(function(k){return m[k]===String(v);});},
            size: function() {return Object.keys(call('get',[])).length;},
            isEmpty: function() {return this.size()===0;},
            keySet: function() {return _array(Object.keys(call('get',[])));},
            values: function() {var m=call('get',[]);return _array(Object.keys(m).map(function(k){return m[k];}));},
            entrySet: function() {var m=call('get',[]);return _array(Object.keys(m).map(function(k){return {getKey:function(){return k;},getValue:function(){return m[k];}};}));},
            save: function(time,need) {call('save',[time || 0,need === undefined ? true : !!need]);},
            saveNow: function() {call('saveNow',[]);}
        };
    })();
    """#

    private static let compatibilityScript = #"""
    function _text(value) {
        if (value == null) return java._content();
        if (typeof value.outerHtml === 'function') return value.outerHtml();
        return typeof value === 'object' ? JSON.stringify(value) : String(value);
    }
    function _array(items) {
        _methods(items, {
            toArray:function(){return this;}, size:function(){return this.length;},
            get:function(i){return this[i];}, isEmpty:function(){return this.length===0;}
        });
        return items;
    }
    function _methods(object, methods) {
        Object.keys(methods).forEach(function(name) {
            Object.defineProperty(object, name, {value:methods[name], configurable:true, writable:true, enumerable:false});
        });
        return object;
    }
    java.getString = function(rule, content, isUrl) { return java._getString(String(rule), _text(content), !!isUrl); };
    function _configMap(value) {
        var keys=Object.keys(value);
        return _methods(value, {
            get:function(key){return keys.indexOf(String(key))>=0 ? this[String(key)] : null;},
            containsKey:function(key){return keys.indexOf(String(key))>=0;},
            size:function(){return Object.keys(this).length;},
            keySet:function(){return _array(Object.keys(this));},
            values:function(){var self=this;return _array(Object.keys(this).map(function(key){return self[key];}));},
            entrySet:function(){var self=this;return _array(Object.keys(this).map(function(key){return {getKey:function(){return key;},getValue:function(){return self[key];}};}));}
        });
    }
    java.getReadBookConfig=function(){return java._configuration('read');};
    java.getReadBookConfigMap=function(){return _configMap(JSON.parse(java.getReadBookConfig()));};
    java.getThemeMode=function(){return java._configuration('mode');};
    java.getThemeConfig=function(){return java._configuration('theme');};
    java.getThemeConfigMap=function(){return _configMap(JSON.parse(java.getThemeConfig()));};
    java.getStringList = function(rule, content) { return _array(JSON.parse(java._getElements(String(rule), _text(content)))); };
    function _typed(value) {
        if (typeof value !== 'string') return value;
        if (/^\s*</.test(value)) return _element(value);
        if (/^\s*[\[{]/.test(value)) { try { return JSON.parse(value); } catch(e) {} }
        return value;
    }
    java.getElements = function(rule, content) {
        var values=JSON.parse(java._getElements(String(rule), _text(content))).map(_typed);
        if(values.length===1 && Array.isArray(values[0])) values=values[0];
        return values.every(function(value){return value && typeof value.outerHtml==='function';}) ? _elements(values) : _array(values);
    };
    java.getElement = function(rule, content) {
        var values=java.getElements(rule, content);
        // Jsoup getElement returns Elements, while JSONPath returns the
        // selected object/scalar (or a list for an indefinite path).
        if(/^\s*[\[{]/.test(_text(content)) && String(rule).indexOf('*')<0) return values.length===1 ? values[0] : values;
        return values;
    };
    java.setContent = function(value) { java._setContent(_text(value)); };
    function _response(data) {
        data = JSON.parse(data);
        if (data.error) throw new Error(data.error);
        return {
            body: function() {
                if(_strictContentHTTP && (data.status<200 || data.status>=300)) throw Error('HTTP '+data.status+'：正文脚本请求失败');
                if(data.bytesBase64 != null) return {
                    bytes:function(){return java.base64DecodeToByteArray(data.bytesBase64);},
                    string:function(){return data.text;}, toString:function(){return data.text;}
                };
                return data.text;
            },
            code: function() { return data.status; }, statusCode: function() { return data.status; },
            isSuccessful: function() { return data.status>=200 && data.status<300; },
            callTime: function() { return data.callTime || 0; },
            putCallTime: function(value) { data.callTime=Number(value); },
            header: function(name) { return data.headers[String(name).toLowerCase()] || ''; },
            // Jsoup's Response.headers(name) returns a list; without a name,
            // headers() returns the map. Real redirect rules use [0] or
            // .get(0), and HTTP header names are case-insensitive.
            headers: function(name) {
                if (name == null) return data.headers;
                var value = data.headers[String(name).toLowerCase()];
                return _array(value == null ? [] : Array.isArray(value) ? value : [String(value)]);
            },
            url: function() { return data.url; },
            raw: function() { return {
                request:function() {return {url:function(){return data.url;}};},
                headers:function(name) {
                    var value = data.headers[String(name).toLowerCase()];
                    return _array(value == null ? [] : Array.isArray(value) ? value : [String(value)]);
                }
            }; },
            toString: function() { return data.text; }
        };
    }
    java.connect = function(url, headers, timeout) {
        return _response(java._request(String(url), '', '', typeof headers === 'string' ? headers : JSON.stringify(headers || {}), timeout || 20000, true));
    };
    java.ajax = function(url, timeout) { return java.connect(Array.isArray(url) ? url[0] : url, {}, timeout).body(); };
    java.ajaxAll = function(urls, skipRateLimit) { return _array(JSON.parse(java._requests(JSON.stringify(Array.from(urls).map(String)), !!skipRateLimit, 20000, false)).map(function(data){return _response(JSON.stringify(data));})); };
    java.ajaxTestAll = function(urls, timeout, skipRateLimit) { return _array(JSON.parse(java._requests(JSON.stringify(Array.from(urls).map(String)), !!skipRateLimit, Number(timeout)||20000, true)).map(function(data){return _response(JSON.stringify(data));})); };
    java.toURL = function(url, base) {
        var parsed=JSON.parse(java._toURL(String(url),base==null?'':String(base))), values=parsed.searchParams;
        if(values!==null)parsed.searchParams=_methods(Object.assign({},values),{
            get:function(key){return Object.prototype.hasOwnProperty.call(values,String(key))?values[String(key)]:null;},
            containsKey:function(key){return Object.prototype.hasOwnProperty.call(values,String(key));},
            size:function(){return Object.keys(values).length;},
            keySet:function(){return _array(Object.keys(values));}
        });
        return parsed;
    };
    ['get','head','post'].forEach(function(method) {
        var storedGet = java.get;
        java[method] = function(url, body, headers, timeout) {
            if (method === 'get' && arguments.length === 1) return storedGet(String(url));
            if (method !== 'post') { timeout = headers; headers = body; body = ''; }
            return _response(java._request(String(url), method.toUpperCase(), String(body || ''), JSON.stringify(headers || {}), timeout || 20000, false));
        };
    });
    java.timeFormat = function(time) {
        var date = new Date(Number(time)), pad = function(n) { return ('0'+n).slice(-2); };
        if (isNaN(date.getTime())) return '';
        return date.getFullYear()+'/'+pad(date.getMonth()+1)+'/'+pad(date.getDate())+' '+pad(date.getHours())+':'+pad(date.getMinutes());
    };
    java.log = function(value) { java._log(String(value)); return value; };
    java.logType = function(value) { java._log(value==null?'null':Object.prototype.toString.call(value)); };
    java.getTag = function() { return source.bookSourceName || source.sourceName || ''; };
    java.toast = function(value) { java._toast(String(value), java.getTag(), false); };
    java.longToast = function(value) { java._toast(String(value), java.getTag(), true); };
    java.ruleUrl = baseUrl;
    java.getSource = function() { return source; };
    java.getBook = function() { return book; };
    java.webView = function(html, url, script, cacheFirst) { return java._webView(html == null ? '' : String(html), url == null ? baseUrl : String(url), script == null ? '' : String(script), '', '', !!cacheFirst, 0); };
    java.webViewGetSource = function(html,url,script,regex,cacheFirst,delay) { return java._webView(html==null?'':String(html),url==null?baseUrl:String(url),script==null?'':String(script),String(regex),'',!!cacheFirst,Number(delay)||0); };
    java.webViewGetOverrideUrl = function(html,url,script,regex,cacheFirst,delay) { return java._webView(html==null?'':String(html),url==null?baseUrl:String(url),script==null?'':String(script),'',String(regex),!!cacheFirst,Number(delay)||0); };
    java.startBrowserAwait=function(url,title,refetch,html){return _response(java._verify(String(url),title==null?'':String(title),html==null?'':String(html),refetch!==false,false));};
    java.getVerificationCode=function(url){return java._verify(String(url),'图片验证码','',false,true);};
    function _element(html) {
        return {
            outerHtml:function(){return html;}, toString:function(){return html;}, toJSON:function(){return html;},
            text:function(){return java._textOnly(html);},
            html:function(){return html.replace(/^<[^>]+>/,'').replace(/<\/[^>]+>$/,'');},
            attr:function(name){return java._attr(html, String(name));},
            select:function(selector){return _elements(JSON.parse(java._select(html, String(selector))));},
            selectFirst:function(selector){return this.select(selector).first();},
            getElementsByTag:function(tag){return this.select(tag);},
            getElementsByClass:function(name){return this.select('.'+name);},
            hasClass:function(name){return (' '+this.attr('class')+' ').indexOf(' '+name+' ')>=0;}
        };
    }
    function _elements(htmls) {
        var items=_array(htmls.map(_typed));
        return _methods(items, {
            first:function(){return this[0] || null;}, last:function(){return this[this.length-1] || null;},
            text:function(){return this.map(function(e){return typeof e.text==='function' ? e.text() : String(e);}).join(' ');},
            attr:function(name){return this.length && typeof this[0].attr==='function' ? this[0].attr(name) : '';},
            html:function(){return this.map(function(e){return typeof e.html==='function' ? e.html() : String(e);}).join('\n');},
            outerHtml:function(){return this.map(String).join('\n');}, toString:function(){return this.outerHtml();},
            select:function(selector){return _elements([].concat.apply([],this.map(function(e){return JSON.parse(java._select(String(e),selector)); })));}
        });
    }
    var org={jsoup:{Jsoup:{parse:function(html){return _element(String(html));}},
        parser:{Parser:{unescapeEntities:function(text,inAttribute){return java._unescapeEntities(String(text),!!inAttribute);}}}}};
    cookie.getKey = function(url, key) {
        var pairs = cookie.getCookie(String(url)).split(';');
        for (var i=0;i<pairs.length;i++) { var p=pairs[i].trim(), at=p.indexOf('='); if(p.slice(0,at)===key)return p.slice(at+1); }
        return '';
    };
    java.getCookie = function(url,key){return key == null ? cookie.getCookie(url) : cookie.getKey(url,key);};
    java.clearCookie = cookie.removeCookie;
    var cache = {
        put: function(key, value, seconds) { return source.put('cache:'+key, JSON.stringify({value:String(value),until:seconds ? Date.now()+seconds*1000 : 0})); },
        // Legado CacheManager.get returns null for a missing or expired key.
        // Several real comic sources pass that value directly to JSON.parse:
        // JSON.parse(null) is valid, whereas JSON.parse('') throws.
        get: function(key) { try { var item=JSON.parse(source.get('cache:'+key)); return item.until && item.until<=Date.now() ? null : item.value; } catch(e) { return null; } },
        delete: function(key) { source.put('cache:'+key,''); java._invalidateImportedScripts(); }
    };
    """#

    private static let javaStringScript = #"""
    function _JavaString(value) {
        if(!(this instanceof _JavaString)) return new _JavaString(value);
        var text = Array.isArray(value) ? java.bytesToStr(value) : String(value == null ? '' : value);
        this.toString = function() { return text; };
        this.toJSON = function() { return text; };
        this.valueOf = function() { return text; };
        this.getBytes = function() { return java.strToBytes(text); };
        this.length = function() { return text.length; };
        this.charAt = function(i) { return text.charAt(i); };
        this.substring = function(a,b) { return text.substring(a,b); };
        this.trim = function() { return text.trim(); };
        this.split = function(separator) { return text.split(separator); };
        this.replace = function(a,b) { return text.replace(a,b); };
        this.replaceAll = function(a,b) { return text.replace(new RegExp(a,'g'),b); };
        this.contains = function(part) { return text.indexOf(part)>=0; };
        this.equals = function(value) { return text === String(value); };
    }
    java.lang = {String:_JavaString};
    java.util = {
        UUID:{randomUUID:java.randomUUID},
        Base64:{getDecoder:function(){return {decode:java.base64DecodeToByteArray};},getEncoder:function(){return {encodeToString:java.base64Encode};}}
    };
    java.nio={charset:{StandardCharsets:{UTF_8:'UTF-8',US_ASCII:'ASCII'}}};
    var Packages = {java:java,org:org};
    """#

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
