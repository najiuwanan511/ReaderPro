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
        return "TLS 连接失败：服务器协议或证书异常。请更新书源地址；不会把 HTTPS 请求悄悄改成 HTTP。"
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
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = .shared
        return URLSession(configuration: config)
    }()

    static func options(_ raw: String) -> (url: String, options: [String: Any]) {
        // A comma in a URL/query is legal. Only split at a valid JSON suffix.
        let pattern = try? NSRegularExpression(pattern: #",\s*\{"#)
        let ns = raw as NSString
        for match in (pattern?.matches(in: raw, range: NSRange(location: 0, length: ns.length)) ?? []).reversed() {
            let tail = ns.substring(from: match.range.location + 1).trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = tail.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
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
           let object = try? JSONSerialization.jsonObject(with: data) { return headers(object) }
        return [:]
    }

    static func expand(_ raw: String, base: String, key: String, page: Int) -> String {
        var value = LegadoSource.fillSearchTemplate(raw, key: key, page: page, sourceUrl: base)
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
                        key: String = "", page: Int = 1) throws -> URLRequest {
        let fill: (String) -> String = { LegadoSource.fillSearchTemplate($0, key: key, page: page, sourceUrl: base) }
        // Numeric templates may be unquoted in options JSON ("page":{{page}}).
        // Expand before parsing; parsed body/header strings are already expanded.
        let parsed = options(expand(raw, base: base, key: key, page: page))
        let address = resolveUrl(parsed.url, base: base)
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw SourceFailure(stage: "请求地址", message: "规则没有生成有效的 HTTP/HTTPS 地址", url: address)
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(sourceUA, forHTTPHeaderField: "User-Agent")
        // Use the originating page, never an unrelated source subscription site.
        if let baseURL = URL(string: base), baseURL.host != nil { req.setValue(base, forHTTPHeaderField: "Referer") }
        for (k, v) in sourceHeaders { req.setValue(fill(v), forHTTPHeaderField: k) }
        for (k, v) in headers(parsed.options["headers"] ?? parsed.options["header"]) { req.setValue(v, forHTTPHeaderField: k) }
        req.httpMethod = (parsed.options["method"] as? String ?? "GET").uppercased()
        if let body = parsed.options["body"] as? String {
            let text = body
            let charset = (parsed.options["charset"] as? String ?? "utf-8").lowercased()
            let encoding = charset.hasPrefix("gb")
                ? String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))) : .utf8
            guard let data = text.data(using: encoding) else {
                throw SourceFailure(stage: "请求编码", message: "请求正文无法按 \(charset) 编码", url: address)
            }
            req.httpBody = data
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/x-www-form-urlencoded; charset=\(charset)", forHTTPHeaderField: "Content-Type")
            }
        } else if let body = parsed.options["body"], JSONSerialization.isValidJSONObject(body) {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            if req.value(forHTTPHeaderField: "Content-Type") == nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        }
        return req
    }

    static func load(_ request: URLRequest, stage: String) async throws -> SourcePage {
        try Task.checkCancellation()
        do {
            let (data, response) = try await (testSession ?? session).data(for: request)
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
            return SourcePage(text: decode(data, response: response), url: address)
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
            text = LegadoJS.run("(" + text + ")", input: "", baseUrl: bookSourceUrl,
                                sourceKey: LegadoJSCtx.key, sourceUrl: bookSourceUrl)
        }
        return SourceHTTP.headers(text)
    }

    func loadPage(_ address: String, base: String? = nil, key: String = "", page: Int = 1, stage: String) async throws -> SourcePage {
        let expanded = SourceHTTP.expand(address, base: base ?? bookSourceUrl, key: key, page: page)
        let req = try SourceHTTP.request(expanded, base: base ?? bookSourceUrl, headers: requestHeaders, key: key, page: page)
        let options = SourceHTTP.options(expanded).options
        if options["webView"] as? Bool == true || !(options["webJs"] as? String ?? "").isEmpty {
            return try await SourceWebLoader.load(req, script: options["webJs"] as? String ?? "", timeout: min(20, LegadoJSCtx.deadline?.timeIntervalSinceNow ?? 20))
        }
        return try await SourceHTTP.load(req, stage: stage)
    }
}
