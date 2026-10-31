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

    static func variable(_ key: String) -> String {
        storeLock.lock(); defer { storeLock.unlock() }
        return store[LegadoJSCtx.sourceUrl]?[key] ?? ""
    }
    static func putVariable(_ key: String, _ value: String) {
        storeLock.lock(); defer { storeLock.unlock() }
        store[LegadoJSCtx.sourceUrl, default: [:]][key] = value
    }

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
        let jput: @convention(block) (String, JSValue) -> String = { k, v in
            storeLock.lock(); defer { storeLock.unlock() }
            if store[storeKey] == nil { store[storeKey] = [:] }
            store[storeKey]?[k] = v.toString() ?? ""
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
        java.setObject(LegadoJS.urlEncodeBlock, forKeyedSubscript: "urlEncode" as NSString)
        java.setObject(LegadoJS.urlEncodeBlock, forKeyedSubscript: "encodeURI" as NSString)
        var content = input
        let getString: @convention(block) (String, String, Bool) -> String = { rule, text, isURL in
            let values = applyRule(text, rule, base: baseUrl)
            let value = values.joined(separator: "\n")
            return isURL ? resolveUrl(value, base: baseUrl) : value
        }
        let getElements: @convention(block) (String, String) -> [String] = { rule, text in applyRule(text, rule, base: baseUrl) }
        let getContent: @convention(block) () -> String = { content }
        let setContent: @convention(block) (String) -> Void = { content = $0 }
        java.setObject(getString, forKeyedSubscript: "_getString" as NSString)
        java.setObject(getElements, forKeyedSubscript: "_getElements" as NSString)
        java.setObject(getContent, forKeyedSubscript: "_content" as NSString)
        java.setObject(setContent, forKeyedSubscript: "setContent" as NSString)
        java.setObject(LegadoJS.urlDecodeBlock, forKeyedSubscript: "urlDecode" as NSString)
        java.setObject(LegadoJS.formatDateBlock, forKeyedSubscript: "formatDate" as NSString)
        java.setObject(LegadoJS.timeMillisBlock, forKeyedSubscript: "timeMillis" as NSString)
        java.setObject(LegadoJS.timeMillisBlock, forKeyedSubscript: "time" as NSString)
        java.setObject(LegadoJS.substringBlock, forKeyedSubscript: "subString" as NSString)
        java.setObject(LegadoJS.substringBlock, forKeyedSubscript: "substring" as NSString)
        java.setObject(LegadoJS.strBlock, forKeyedSubscript: "str" as NSString)
        ctx.setObject(java, forKeyedSubscript: "java" as NSString)

        let request: @convention(block) (String, String, String, String, Double, Bool) -> [String: Any] = { address, method, body, headersJSON, timeout, follow in
            do {
                let headers = LegadoJSCtx.headers.merging(SourceHTTP.headers(headersJSON)) { _, value in value }
                return try SourceJSBridge.request(address, base: baseUrl, headers: headers,
                                                   method: method, body: body,
                                                   timeout: timeout > 0 ? timeout / 1000 : 20, followRedirects: follow)
            } catch {
                return ["error": sourceErrorMessage(error)]
            }
        }
        java.setObject(request, forKeyedSubscript: "_request" as NSString)
        let web: @convention(block) (String, String, String) -> String = { html, address, script in
            do {
                let request = try SourceHTTP.request(address.isEmpty ? baseUrl : address, base: baseUrl, headers: LegadoJSCtx.headers)
                return try SourceJSBridge.web(request, html: html, script: script).text
            } catch {
                JSContext.current()?.exception = JSValue(newErrorFromMessage: sourceErrorMessage(error), in: JSContext.current())
                return ""
            }
        }
        java.setObject(web, forKeyedSubscript: "_webView" as NSString)
        let select: @convention(block) (String, String) -> [String] = { text, selector in LegadoDOM.css(text, selector).map(\.full) }
        let attribute: @convention(block) (String, String) -> String = { text, name in
            LegadoDOM.css(text, "body > *").first.map { htmlAttrs($0.open)[name.lowercased()] ?? "" } ?? ""
        }
        let textOnly: @convention(block) (String) -> String = { stripText($0, preserveNewlines: false) }
        java.setObject(select, forKeyedSubscript: "_select" as NSString)
        java.setObject(attribute, forKeyedSubscript: "_attr" as NSString)
        java.setObject(textOnly, forKeyedSubscript: "_textOnly" as NSString)
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
        let getLoginMap: @convention(block) () -> [String: String] = { loginInfo }
        let getLoginStr: @convention(block) () -> String = { loginInfo.map { "\($0.key)=\($0.value)" }.joined(separator: "&") }
        let getHeader: @convention(block) () -> [String: String] = { header }
        let concurrentBox = ConcurrentBox()
        let getConcurrent: @convention(block) () -> Int = { concurrentBox.value }
        let putConcurrent: @convention(block) (JSValue) -> Void = { v in concurrentBox.value = Int(v.toNumber()?.intValue ?? 0) }
        source.setObject(sourceUrl, forKeyedSubscript: "key" as NSString)
        source.setObject(sourceUrl, forKeyedSubscript: "bookSourceUrl" as NSString)
        source.setObject(LegadoJSCtx.comment, forKeyedSubscript: "bookSourceComment" as NSString)
        source.setObject(getKey, forKeyedSubscript: "getKey" as NSString)
        source.setObject(getSourceUrl, forKeyedSubscript: "getBookSourceUrl" as NSString)
        source.setObject(getLoginMap, forKeyedSubscript: "getLoginInfoMap" as NSString)
        source.setObject(getLoginStr, forKeyedSubscript: "getLoginInfo" as NSString)
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
        ctx.setObject(bookObj, forKeyedSubscript: "book" as NSString)
        let chapter = LegadoJSCtx.chapter
        let chapterObj = JSValue(newObjectIn: ctx)!
        chapterObj.setObject(chapter?.title ?? "", forKeyedSubscript: "title" as NSString)
        chapterObj.setObject(chapter?.url ?? baseUrl, forKeyedSubscript: "url" as NSString)
        chapterObj.setObject(chapter?.ruleIndex ?? 0, forKeyedSubscript: "index" as NSString)
        ctx.setObject(chapterObj, forKeyedSubscript: "chapter" as NSString)

        ctx.evaluateScript(Self.compatibilityScript)
        SourceCrypto.install(java, context: ctx)
        let digest: @convention(block) (String, String) -> String = { text, algorithm in
            let data = Data(text.utf8)
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
        java.setObject(digest, forKeyedSubscript: "digestHex" as NSString)
        java.setObject(randomUUID, forKeyedSubscript: "randomUUID" as NSString)
        ctx.evaluateScript(Self.javaStringScript)

        // ---- 执行 ----
        // 关键修复：JS 规则大量用「最后一行是表达式」的方式返回结果，
        // 例如 exploreUrl 的 @js:...;JSON.stringify(s)，正文规则的 @js:...;result。
        // 之前把 evaluateScript 的返回值丢弃了、只读 result 变量，导致
        // JSON.stringify(...) 这种「靠返回值」的规则全部拿不到结果（发现/搜索/正文全空）。
        var library = LegadoJSCtx.library
        if !library.isEmpty {
            if library.hasPrefix("http://") || library.hasPrefix("https://") {
                do {
                    library = try SourceJSBridge.request(library, base: sourceUrl, headers: header)["text"] as? String ?? ""
                } catch {
                    LegadoJSCtx.failures?.add("远程 jsLib：" + sourceErrorMessage(error)); return ""
                }
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

    private static let compatibilityScript = #"""
    function _text(value) {
        if (value == null) return java._content();
        if (typeof value.outerHtml === 'function') return value.outerHtml();
        return typeof value === 'object' ? JSON.stringify(value) : String(value);
    }
    function _array(items) {
        items.toArray = function() { return this; };
        items.size = function() { return this.length; };
        items.get = function(i) { return this[i]; };
        return items;
    }
    java.getString = function(rule, content, isUrl) { return java._getString(String(rule), _text(content), !!isUrl); };
    java.getStringList = function(rule, content) { return _array(java._getElements(String(rule), _text(content))); };
    java.getElements = java.getStringList;
    java.getElement = function(rule, content) { return java.getElements(rule, content)[0] || ''; };
    function _response(data) {
        if (data.error) throw new Error(data.error);
        return {
            body: function() { return data.text; },
            code: function() { return data.status; }, statusCode: function() { return data.status; },
            header: function(name) { return data.headers[String(name).toLowerCase()] || ''; },
            headers: function() { return data.headers; }, url: function() { return data.url; },
            raw: function() { return {request:function() {return {url:function(){return data.url;}};}}; },
            toString: function() { return data.text; }
        };
    }
    java.connect = function(url, headers, timeout) {
        return _response(java._request(String(url), '', '', typeof headers === 'string' ? headers : JSON.stringify(headers || {}), timeout || 20000, true));
    };
    java.ajax = function(url, timeout) { return java.connect(Array.isArray(url) ? url[0] : url, {}, timeout).body(); };
    java.ajaxAll = function(urls) { return _array(urls.map(function(url) { return java.connect(url); })); };
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
    java.log = function(value) { return value; };
    java.toast = java.longToast = java.refreshExplore = function() {};
    java.ruleUrl = baseUrl;
    java.getSource = function() { return source; };
    java.getBook = function() { return book; };
    java.webView = function(html, url, script) { return java._webView(html == null ? '' : String(html), url == null ? baseUrl : String(url), script == null ? '' : String(script)); };
    function _element(html) {
        return {
            outerHtml:function(){return html;}, toString:function(){return html;},
            text:function(){return java._textOnly(html);},
            html:function(){return html.replace(/^<[^>]+>/,'').replace(/<\/[^>]+>$/,'');},
            attr:function(name){return java._attr(html, String(name));},
            select:function(selector){return _elements(java._select(html, String(selector)));},
            selectFirst:function(selector){return this.select(selector).first();},
            getElementsByTag:function(tag){return this.select(tag);},
            getElementsByClass:function(name){return this.select('.'+name);},
            hasClass:function(name){return (' '+this.attr('class')+' ').indexOf(' '+name+' ')>=0;}
        };
    }
    function _elements(htmls) {
        var items=_array(htmls.map(_element));
        items.first=function(){return this[0] || null;}; items.last=function(){return this[this.length-1] || null;};
        items.text=function(){return this.map(function(e){return e.text();}).join(' ');};
        items.attr=function(name){return this.length ? this[0].attr(name) : '';};
        items.outerHtml=function(){return this.map(String).join('\n');};
        items.select=function(selector){return _elements([].concat.apply([],this.map(function(e){return java._select(String(e),selector); })));};
        return items;
    }
    var org={jsoup:{Jsoup:{parse:function(html){return _element(String(html));}}}};
    cookie.getKey = function(url, key) {
        var pairs = cookie.getCookie(String(url)).split(';');
        for (var i=0;i<pairs.length;i++) { var p=pairs[i].trim(), at=p.indexOf('='); if(p.slice(0,at)===key)return p.slice(at+1); }
        return '';
    };
    var cache = {
        put: function(key, value, seconds) { return source.put('cache:'+key, JSON.stringify({value:String(value),until:seconds ? Date.now()+seconds*1000 : 0})); },
        get: function(key) { try { var item=JSON.parse(source.get('cache:'+key)); return item.until && item.until<Date.now() ? '' : item.value; } catch(e) { return ''; } },
        delete: function(key) { source.put('cache:'+key,''); }
    };
    """#

    private static let javaStringScript = #"""
    function _JavaString(value) {
        var text = Array.isArray(value) ? java.bytesToStr(value) : String(value == null ? '' : value);
        this.toString = function() { return text; };
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
