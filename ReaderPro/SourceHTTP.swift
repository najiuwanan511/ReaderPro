import Foundation
import CoreFoundation

struct SourceFailure: LocalizedError {
    let stage: String
    let message: String
    var url: String = ""
    var errorDescription: String? {
        "\(stage)：\(message)" + (url.isEmpty ? "" : "\n\(url)")
    }
}

func sourceErrorMessage(_ error: Error) -> String {
    if error is CancellationError { return "已取消" }
    if let failure = error as? SourceFailure { return failure.localizedDescription }
    let e = error as NSError
    guard e.domain == NSURLErrorDomain else { return error.localizedDescription }
    switch e.code {
    case NSURLErrorAppTransportSecurityRequiresSecureConnection:
        return "系统阻止了 HTTP 请求，请检查安装包的网络配置。"
    case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
         NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot:
        return "TLS 连接失败：服务器协议或证书异常。可信旧站点可在该书源详情中开启「旧站点证书兼容」后重试。"
    case NSURLErrorTimedOut: return "请求超时，服务器未及时响应。"
    case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "域名无法解析，书源域名可能已失效。"
    case NSURLErrorNotConnectedToInternet: return "当前设备未联网。"
    case NSURLErrorCancelled: return "已取消"
    default: return "网络请求失败（\(e.code)）：\(error.localizedDescription)"
    }
}

struct SourcePage {
    let text: String
    let url: String
}

enum SourceHTTP {
    static func decode(_ data: Data, response: URLResponse) -> String {
        if let charset = response.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) { return text }
        }
        return decodeTextData(data)
    }
    // Task-local injection lets the real engine run against deterministic HTTP
    // fixtures without changing global state or contacting arbitrary websites.
    @TaskLocal static var testSession: URLSession?
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = .shared
        return config
    }
    static let session = URLSession(configuration: configuration())

    static func options(_ raw: String) -> (url: String, options: [String: Any]) {
        // A comma in a URL/query is legal. Only split at a valid JSON suffix.
        let pattern = try? NSRegularExpression(pattern: #",\s*\{"#)
        let ns = raw as NSString
        for match in (pattern?.matches(in: raw, range: NSRange(location: 0, length: ns.length)) ?? []).reversed() {
            let tail = ns.substring(from: match.range.location + 1).trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = tail.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any] {
                return (ns.substring(to: match.range.location), object)
            }
        }
        return (raw, [:])
    }

    static func headers(_ value: Any?) -> [String: String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [:]) { result, pair in result[pair.key] = String(describing: pair.value) }
        }
        if let string = value as? String, let data = string.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) { return headers(object) }
        return [:]
    }

    static func webViewDelay(_ options: [String: Any]) -> Double {
        let value = options["webViewDelayTime"]
        let milliseconds = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap { Double($0) } ?? 0
        return milliseconds.isFinite ? max(0, milliseconds) / 1000 : 0
    }

    static func expand(_ raw: String, base: String, key: String, page: Int) -> String {
        var value = LegadoSource.fillSearchTemplate(raw, key: key, page: page, sourceUrl: base)
        // AnalyzeUrl replaces the page alternatives only after evaluating
        // embedded {{...}} expressions. Empty first alternatives are common:
        // /<,page/{{page}}> is / on page 1 and /page/2 on page 2.
        // Keep the final alternative for all pages beyond those listed.
        if let pattern = try? NSRegularExpression(pattern: #"<(.*?)>"#) {
            let range = NSRange(value.startIndex..., in: value)
            for match in pattern.matches(in: value, range: range).reversed() {
                guard let whole = Range(match.range, in: value),
                      let alternativesRange = Range(match.range(at: 1), in: value) else { continue }
                let alternatives = String(value[alternativesRange]).components(separatedBy: ",")
                let index = min(max(page, 1) - 1, alternatives.count - 1)
                value.replaceSubrange(whole, with: alternatives[index].trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        let charset = (options(value).options["charset"] as? String ?? "utf-8").lowercased()
        if charset.hasPrefix("gb"), !key.isEmpty {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            if let bytes = key.data(using: encoding) {
                let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
                let encoded = bytes.map { allowed.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
                let utf8 = key.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? key
                value = value.replacingOccurrences(of: utf8, with: encoded)
            }
        }
        return value
    }

    static func request(_ raw: String, base: String, headers sourceHeaders: [String: String] = [:],
                        key: String = "", page: Int = 1, alreadyExpanded: Bool = false,
                        sourceTemplate: String? = nil) throws -> URLRequest {
        let fill: (String) -> String = { LegadoSource.fillSearchTemplate($0, key: key, page: page, sourceUrl: base) }
        // Numeric templates may be unquoted in options JSON ("page":{{page}}).
        // Expand before parsing; parsed body/header strings are already expanded.
        let parsed = options(alreadyExpanded ? raw : expand(raw, base: base, key: key, page: page))
        var address = resolveUrl(parsed.url, base: base)
        guard let initialURL = URL(string: address), ["http", "https"].contains(initialURL.scheme?.lowercased() ?? ""), initialURL.host != nil else {
            throw SourceFailure(stage: "请求地址", message: "规则没有生成有效的 HTTP/HTTPS 地址", url: address)
        }
        var req = URLRequest(url: initialURL, timeoutInterval: 20)
        req.setValue(sourceUA, forHTTPHeaderField: "User-Agent")
        // Use the originating page, never an unrelated source subscription site.
        if let baseURL = URL(string: base), baseURL.host != nil { req.setValue(base, forHTTPHeaderField: "Referer") }
        for (k, v) in sourceHeaders { req.setValue(fill(v), forHTTPHeaderField: k) }
        for (k, v) in headers(parsed.options["headers"] ?? parsed.options["header"]) { req.setValue(v, forHTTPHeaderField: k) }
        // Legado executes URL option `js` after resolving the URL and merging
        // headers. The script can inspect java.url and mutate java.headerMap
        // before the actual request (e.g. retrieve and install a site cookie).
        if let script = parsed.options["js"] as? String, !script.isEmpty {
            let context = SourceJSURLContext(url: address, headers: req.allHTTPHeaderFields ?? [:])
            let result = LegadoJS.run(script, input: address, baseUrl: base, sourceKey: key,
                                      sourceUrl: LegadoJSCtx.sourceUrl.isEmpty ? base : LegadoJSCtx.sourceUrl,
                                      header: context.headers, book: LegadoJSCtx.book, page: page,
                                      expandTemplates: false, urlContext: context)
            try LegadoJSCtx.failures?.check()
            address = context.returnedValue ? result : context.url
            guard let updated = URL(string: address), ["http", "https"].contains(updated.scheme?.lowercased() ?? ""), updated.host != nil else {
                throw SourceFailure(stage: "请求地址", message: "地址脚本没有返回有效的 HTTP/HTTPS 地址", url: address)
            }
            req.url = updated
            req.allHTTPHeaderFields = context.headers
        }
        req.httpMethod = (parsed.options["method"] as? String ?? "GET").uppercased()
        if let body = parsed.options["body"] as? String {
            var text = body
            // AnalyzeUrl sends a JSON body as JSON, with `key` as its original
            // string. URL percent encoding belongs in a URL/form, not inside
            // a JSON value. Preserve explicit JS-encoded values by repairing
            // only a literal {{key}} in the original body template.
            let originalBody = options(sourceTemplate ?? raw).options["body"] as? String ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let charset = (parsed.options["charset"] as? String ?? "utf-8").lowercased()
            let jsonBody = (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) &&
                (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
            if jsonBody && originalBody.contains("{{key}}") && !key.isEmpty,
               let encodedData = try? JSONEncoder().encode(key),
               let quoted = String(data: encodedData, encoding: .utf8), quoted.count >= 2 {
                let escapedKey = String(quoted.dropFirst().dropLast())
                var percentKey = key.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? key
                if charset.hasPrefix("gb"), let bytes = key.data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) {
                    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
                    percentKey = bytes.map { allowed.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
                }
                if percentKey != key { text = text.replacingOccurrences(of: percentKey, with: escapedKey) }
            }
            let encoding = !jsonBody && charset.hasPrefix("gb")
                ? String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))) : .utf8
            guard let data = text.data(using: encoding) else {
                throw SourceFailure(stage: "请求编码", message: "请求正文无法按 \(charset) 编码", url: address)
            }
            req.httpBody = data
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue(jsonBody ? "application/json; charset=utf-8" : "application/x-www-form-urlencoded; charset=\(charset)", forHTTPHeaderField: "Content-Type")
            }
        } else if let body = parsed.options["body"], JSONSerialization.isValidJSONObject(body) {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            if req.value(forHTTPHeaderField: "Content-Type") == nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        }
        return req
    }

    static func inlinePage(_ address: String) throws -> SourcePage? {
        let parsed = options(address)
        guard parsed.url.hasPrefix("data:") else { return nil }
        guard let comma = parsed.url.firstIndex(of: ","), parsed.url[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(parsed.url[parsed.url.index(after: comma)...]), options: .ignoreUnknownCharacters) else {
            throw SourceFailure(stage: "请求地址", message: "data 规则没有生成有效的 Base64 数据")
        }
        // Legado's request type option passes binary responses to rules as hex.
        let text = (parsed.options["type"] as? String ?? "").isEmpty
            ? decodeTextData(data) : data.map { String(format: "%02x", $0) }.joined()
        return SourcePage(text: text, url: parsed.url)
    }

    static func load(_ request: URLRequest, stage: String, hexEncoded: Bool = false) async throws -> SourcePage {
        try Task.checkCancellation()
        do {
            let (data, response) = try await SourceTLS.session().data(for: request)
            let address = response.url?.absoluteString ?? request.url?.absoluteString ?? ""
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let hint: String
                switch http.statusCode {
                case 401: hint = "需要登录"
                case 403: hint = "访问被拒绝，可能需要登录、Cookie 或验证码"
                case 404: hint = "地址不存在，书源规则或域名可能已变更"
                case 429: hint = "请求过于频繁，请稍后重试"
                default: hint = "服务器响应异常"
                }
                throw SourceFailure(stage: stage, message: "HTTP \(http.statusCode)：\(hint)", url: address)
            }
            guard !data.isEmpty else { throw SourceFailure(stage: stage, message: "服务器返回空内容", url: address) }
            return SourcePage(text: hexEncoded ? data.map { String(format: "%02x", $0) }.joined() : decode(data, response: response), url: address)
        } catch let failure as SourceFailure { throw failure }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw SourceFailure(stage: stage, message: sourceErrorMessage(error), url: request.url?.absoluteString ?? "")
        }
    }
}

extension LegadoSource {
    var requestHeaders: [String: String] {
        var text = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("@js:") {
            text = LegadoJS.run(String(text.dropFirst(4)), input: "", baseUrl: bookSourceUrl,
                                sourceKey: bookSourceUrl, sourceUrl: bookSourceUrl)
        }
        text = Self.fillSearchTemplate(text, key: LegadoJSCtx.key, page: 1, sourceUrl: bookSourceUrl)
        if SourceHTTP.headers(text).isEmpty, text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            // The reference tolerates malformed optional header configuration.
            // Still evaluate valid JS-valued maps, without poisoning unrelated
            // extraction rules if a subscription contains broken header JSON.
            text = LegadoJSCtx.$failures.withValue(nil) {
                LegadoJS.run("(" + text + ")", input: "", baseUrl: bookSourceUrl,
                             sourceKey: LegadoJSCtx.key, sourceUrl: bookSourceUrl)
            }
        }
        return SourceHTTP.headers(text)
    }

    func loadPage(_ address: String, base: String? = nil, key: String = "", page: Int = 1, stage: String) async throws -> SourcePage {
        let expanded = SourceHTTP.expand(address, base: base ?? bookSourceUrl, key: key, page: page)
        if let inline = try SourceHTTP.inlinePage(expanded) { return inline }
        let req = try SourceHTTP.request(expanded, base: base ?? bookSourceUrl, headers: requestHeaders, key: key, page: page, alreadyExpanded: true, sourceTemplate: address)
        let options = SourceHTTP.options(expanded).options
        if options["webView"] as? Bool == true || !(options["webJs"] as? String ?? "").isEmpty {
            return try await SourceWebLoader.load(req, script: options["webJs"] as? String ?? "", timeout: min(20, LegadoJSCtx.deadline?.timeIntervalSinceNow ?? 20), delay: SourceHTTP.webViewDelay(options))
        }
        return try await SourceHTTP.load(req, stage: stage, hexEncoded: !(options["type"] as? String ?? "").isEmpty)
    }
}
