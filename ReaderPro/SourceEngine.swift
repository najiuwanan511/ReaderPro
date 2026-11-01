import Foundation

// MARK: - Legado source (subset of the Legado JSON rule spec, enough for real sources)
// Import fix (2026-10-29): the old synthesized Codable was all-or-nothing.
// A real Legado list has null fields, Int/Bool fields, extra fields (exploreUrl,
// ruleExplore, lastUpdateTime, weight, header, loginUrl, ...) and one bad entry
// used to kill the whole array. Now every field is read tolerantly (null -> "",
// number/bool -> string, missing -> default) and every list entry is decoded
// separately, so one bad source no longer blocks the rest.

struct LegadoSource: Identifiable, Codable, Equatable {
    private var originalNullRules: Set<String> = []
    var id: String = UUID().uuidString
    var bookSourceName: String = ""
    var bookSourceUrl: String = ""
    var bookSourceGroup: String = ""
    var enabled: Bool = true
    var searchUrl: String = ""
    var discoverUrl: String = ""
    var exploreUrl: String = ""
    var header: String = ""
    var jsLib: String = ""
    var loginUrl: String = ""
    var bookSourceComment: String = ""
    var variableComment: String? = nil
    var enabledExplore: Bool = true
    var ruleSearch: RuleSet = RuleSet()
    var ruleBookInfo: RuleSet = RuleSet()
    var ruleToc: RuleSet = RuleSet()
    var ruleContent: RuleSet = RuleSet()
    var ruleDiscover: RuleSet = RuleSet()
    var ruleExplore: RuleSet = RuleSet()
    var bookSourceType: Int = 0 // 0 文本, 1 音频, 2 图片/漫画
    struct RuleSet: Codable, Equatable {
        // Preserve Android fields and their null/empty distinctions even when
        // the iOS rule engine does not yet interpret a particular field.
        private var originalValues: [String: String] = [:]
        private var originalNulls: Set<String> = []
        private var decodedObject = false
        var bookList: String = ""
        var name: String = ""
        var author: String = ""
        var bookUrl: String = ""
        var coverUrl: String = ""
        var intro: String = ""
        var tocUrl: String = ""
        var chapterList: String = ""
        var chapterName: String = ""
        var chapterUrl: String = ""
        var content: String = ""
        var nextContentUrl: String = ""
        var nextTocUrl: String = ""
        var kind: String = ""
        var wordCount: String = ""
        var lastChapter: String = ""
        var replaceRegex: String = ""
        var imageUrl: String = ""
        var checkKeyWord: String = ""
        var initRule: String = ""
        enum CodingKeys: String, CodingKey, CaseIterable {
            case bookList, name, author, bookUrl, coverUrl, intro, tocUrl, chapterList, chapterName, chapterUrl, content, nextContentUrl, nextTocUrl, kind, wordCount, lastChapter, replaceRegex, imageUrl, checkKeyWord
            case updateTime, preUpdateJs, formatJs, isVolume, isVip, isPay, subContent, title, webJs, sourceRegex, imageStyle, imageDecode, payAction, callBackJs
            case initRule = "init"
        }
        init() {}
        init(from decoder: Decoder) throws {
            // Legado also accepts a JSON object encoded as a JSON string.
            if let single = try? decoder.singleValueContainer(),
               let text = try? single.decode(String.self),
               let data = text.data(using: .utf8),
               let value = try? JSONDecoder().decode(RuleSet.self, from: data) {
                self = value
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            decodedObject = true
            for key in CodingKeys.allCases where c.contains(key) {
                if (try? c.decodeNil(forKey: key)) == true { originalNulls.insert(key.rawValue) }
                else { originalValues[key.rawValue] = c.tolerantString(key) }
            }
            bookList = c.tolerantString(.bookList); name = c.tolerantString(.name); author = c.tolerantString(.author)
            bookUrl = c.tolerantString(.bookUrl); coverUrl = c.tolerantString(.coverUrl); intro = c.tolerantString(.intro)
            tocUrl = c.tolerantString(.tocUrl); chapterList = c.tolerantString(.chapterList); chapterName = c.tolerantString(.chapterName)
            chapterUrl = c.tolerantString(.chapterUrl); content = c.tolerantString(.content); nextContentUrl = c.tolerantString(.nextContentUrl)
            nextTocUrl = c.tolerantString(.nextTocUrl); kind = c.tolerantString(.kind); wordCount = c.tolerantString(.wordCount)
            lastChapter = c.tolerantString(.lastChapter); replaceRegex = c.tolerantString(.replaceRegex); imageUrl = c.tolerantString(.imageUrl)
            checkKeyWord = c.tolerantString(.checkKeyWord); initRule = c.tolerantString(.initRule)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            for key in CodingKeys.allCases {
                if let value = androidValue(key.rawValue) { try c.encode(value, forKey: key) }
                else if originalNulls.contains(key.rawValue) { try c.encodeNil(forKey: key) }
            }
        }

        // Current engine/editor values win over the imported snapshot. An
        // unchanged empty value remains null only when the original was null
        // or absent; older saved rules that already contain "" remain "".
        func androidValue(_ field: String) -> String? {
            let value: String
            switch field {
            case "bookList": value = bookList
            case "name": value = name
            case "author": value = author
            case "bookUrl": value = bookUrl
            case "coverUrl": value = coverUrl
            case "intro": value = intro
            case "tocUrl": value = tocUrl
            case "chapterList": value = chapterList
            case "chapterName": value = chapterName
            case "chapterUrl": value = chapterUrl
            case "content": value = content
            case "nextContentUrl": value = nextContentUrl
            case "nextTocUrl": value = nextTocUrl
            case "kind": value = kind
            case "wordCount": value = wordCount
            case "lastChapter": value = lastChapter
            case "replaceRegex": value = replaceRegex
            case "imageUrl": value = imageUrl
            case "checkKeyWord": value = checkKeyWord
            case "init": value = initRule
            default: return originalValues[field]
            }
            return value.isEmpty && originalValues[field] == nil ? nil : value
        }
        var hasAndroidObject: Bool {
            decodedObject || CodingKeys.allCases.contains { androidValue($0.rawValue) != nil }
        }
        static func == (lhs: RuleSet, rhs: RuleSet) -> Bool {
            lhs.hasAndroidObject == rhs.hasAndroidObject &&
                CodingKeys.allCases.allSatisfy { lhs.androidValue($0.rawValue) == rhs.androidValue($0.rawValue) }
        }
    }
    enum CodingKeys: String, CodingKey {
        case id, bookSourceName, bookSourceUrl, bookSourceGroup, enabled, searchUrl, discoverUrl, exploreUrl, bookSourceType, ruleSearch, ruleBookInfo, ruleToc, ruleContent, ruleDiscover, ruleExplore, header, jsLib, loginUrl, enabledExplore, bookSourceComment, variableComment
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        for key in [CodingKeys.ruleSearch, .ruleBookInfo, .ruleDiscover, .ruleExplore, .ruleToc, .ruleContent] where c.contains(key) {
            if (try? c.decodeNil(forKey: key)) == true { originalNullRules.insert(key.rawValue) }
        }
        if let s = try? c.decode(String.self, forKey: .id), !s.isEmpty { id = s }
        bookSourceName = c.tolerantString(.bookSourceName); bookSourceUrl = c.tolerantString(.bookSourceUrl)
        bookSourceGroup = c.tolerantString(.bookSourceGroup); enabled = c.tolerantBool(.enabled, defaultValue: true)
        searchUrl = c.tolerantString(.searchUrl); discoverUrl = c.tolerantString(.discoverUrl); exploreUrl = c.tolerantString(.exploreUrl)
        header = c.tolerantString(.header)
        if header.isEmpty, let map = try? c.decode([String: String].self, forKey: .header),
           let data = try? JSONSerialization.data(withJSONObject: map), let text = String(data: data, encoding: .utf8) { header = text }
        jsLib = c.tolerantString(.jsLib); enabledExplore = c.tolerantBool(.enabledExplore, defaultValue: true)
        loginUrl = c.tolerantString(.loginUrl)
        bookSourceComment = c.tolerantString(.bookSourceComment)
        variableComment = try? c.decodeIfPresent(String.self, forKey: .variableComment)
        ruleSearch = (try? c.decodeIfPresent(RuleSet.self, forKey: .ruleSearch)) ?? RuleSet()
        ruleBookInfo = (try? c.decodeIfPresent(RuleSet.self, forKey: .ruleBookInfo)) ?? RuleSet()
        ruleToc = (try? c.decodeIfPresent(RuleSet.self, forKey: .ruleToc)) ?? RuleSet()
        ruleContent = (try? c.decodeIfPresent(RuleSet.self, forKey: .ruleContent)) ?? RuleSet()
        ruleDiscover = (try? c.decodeIfPresent(RuleSet.self, forKey: .ruleDiscover)) ?? RuleSet()
        ruleExplore = (try? c.decodeIfPresent(RuleSet.self, forKey: .ruleExplore)) ?? RuleSet()
        bookSourceType = c.tolerantInt(.bookSourceType)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(bookSourceName, forKey: .bookSourceName); try c.encode(bookSourceUrl, forKey: .bookSourceUrl)
        try c.encode(bookSourceGroup, forKey: .bookSourceGroup); try c.encode(enabled, forKey: .enabled); try c.encode(searchUrl, forKey: .searchUrl)
        try c.encode(discoverUrl, forKey: .discoverUrl); try c.encode(exploreUrl, forKey: .exploreUrl)
        try c.encode(header, forKey: .header); try c.encode(jsLib, forKey: .jsLib); try c.encode(enabledExplore, forKey: .enabledExplore)
        try c.encode(loginUrl, forKey: .loginUrl)
        try c.encode(bookSourceComment, forKey: .bookSourceComment)
        try c.encodeIfPresent(variableComment, forKey: .variableComment)
        func encodeRule(_ rule: RuleSet, _ key: CodingKeys) throws {
            if rule.hasAndroidObject { try c.encode(rule, forKey: key) }
            else if originalNullRules.contains(key.rawValue) { try c.encodeNil(forKey: key) }
        }
        try encodeRule(ruleSearch, .ruleSearch); try encodeRule(ruleBookInfo, .ruleBookInfo)
        try encodeRule(ruleToc, .ruleToc); try encodeRule(ruleContent, .ruleContent)
        try encodeRule(ruleDiscover, .ruleDiscover); try encodeRule(ruleExplore, .ruleExplore)
        try c.encode(bookSourceType, forKey: .bookSourceType)
    }
    // Legado's real discovery fields are exploreUrl + ruleExplore, not discoverUrl.
    static func == (lhs: LegadoSource, rhs: LegadoSource) -> Bool {
        lhs.id == rhs.id && lhs.bookSourceName == rhs.bookSourceName && lhs.bookSourceUrl == rhs.bookSourceUrl &&
        lhs.bookSourceGroup == rhs.bookSourceGroup && lhs.enabled == rhs.enabled && lhs.searchUrl == rhs.searchUrl &&
        lhs.discoverUrl == rhs.discoverUrl && lhs.exploreUrl == rhs.exploreUrl && lhs.header == rhs.header &&
        lhs.jsLib == rhs.jsLib && lhs.loginUrl == rhs.loginUrl && lhs.bookSourceComment == rhs.bookSourceComment &&
        lhs.variableComment == rhs.variableComment && lhs.enabledExplore == rhs.enabledExplore &&
        lhs.ruleSearch == rhs.ruleSearch && lhs.ruleBookInfo == rhs.ruleBookInfo && lhs.ruleToc == rhs.ruleToc &&
        lhs.ruleContent == rhs.ruleContent && lhs.ruleDiscover == rhs.ruleDiscover && lhs.ruleExplore == rhs.ruleExplore &&
        lhs.bookSourceType == rhs.bookSourceType
    }
    var effectiveDiscoverUrl: String { discoverUrl.isEmpty ? exploreUrl : discoverUrl }
    var effectiveDiscoverRule: RuleSet { ruleDiscover.bookList.isEmpty ? ruleExplore : ruleDiscover }
    // 漫画书源：bookSourceType == 2，或正文规则里带图片提取规则 imageUrl
    var isComic: Bool { bookSourceType == 2 || !ruleContent.imageUrl.isEmpty }
}

extension KeyedDecodingContainer {
    func tolerantString(_ key: Key) -> String {
        if let s = try? decode(String.self, forKey: key) { return s }
        if let n = try? decode(Int.self, forKey: key) { return "\(n)" }
        if let n = try? decode(Double.self, forKey: key) { return "\(n)" }
        if let b = try? decode(Bool.self, forKey: key) { return b ? "true" : "false" }
        return ""
    }
    func tolerantBool(_ key: Key, defaultValue: Bool) -> Bool {
        if let b = try? decode(Bool.self, forKey: key) { return b }
        if let n = try? decode(Int.self, forKey: key) { return n != 0 }
        if let s = try? decode(String.self, forKey: key) { return s == "true" || s == "1" }
        return defaultValue
    }
    func tolerantInt(_ key: Key, defaultValue: Int = 0) -> Int {
        if let n = try? decode(Int.self, forKey: key) { return n }
        if let d = try? decode(Double.self, forKey: key) { return Int(d) }
        if let s = try? decode(String.self, forKey: key), let n = Int(s.trimmingCharacters(in: .whitespaces)) { return n }
        return defaultValue
    }
}

let sourceUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

// URLSession and synchronous JS bridge requests both observe this deadline.
func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        let deadline = min(LegadoJSCtx.deadline ?? .distantFuture, Date().addingTimeInterval(seconds))
        group.addTask { try await LegadoJSCtx.$deadline.withValue(deadline) { try await op() } }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw NSError(domain: "timeout", code: -1, userInfo: [NSLocalizedDescriptionKey: "请求超时"])
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw NSError(domain: "timeout", code: -1) }
        return first
    }
}

func fetchText(urlString: String) async throws -> String {
    let request = try SourceHTTP.request(urlString, base: urlString)
    return try await SourceHTTP.load(request, stage: "网络请求").text
}

func fetchText(urlString: String, method: String, body: String) async throws -> String {
    var request = try SourceHTTP.request(urlString, base: urlString)
    request.httpMethod = method
    request.httpBody = body.data(using: .utf8)
    request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
    return try await SourceHTTP.load(request, stage: "网络请求").text
}

func resolveUrl(_ raw: String, base: String) -> String {
    let parsed = SourceHTTP.options(raw)
    if !parsed.options.isEmpty, let data = try? JSONSerialization.data(withJSONObject: parsed.options, options: .sortedKeys), let suffix = String(data: data, encoding: .utf8) {
        let address = resolveUrl(parsed.url, base: SourceHTTP.options(base).url)
        return address.isEmpty ? "" : address + "," + suffix
    }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "&amp;", with: "&")
    guard !value.isEmpty, !value.hasPrefix("javascript:"), value != "#" else { return "" }
    // Trim only the transport address; the original source identity is preserved.
    let transportBase = SourceHTTP.options(base).url.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("//") { return (URL(string: transportBase)?.scheme ?? "https") + ":" + value }
    guard let baseURL = URL(string: transportBase), let url = URL(string: value, relativeTo: baseURL)?.absoluteURL else { return value }
    return url.absoluteString
}

// NOTE: rule engine, search, chapters, content and explore live in LegadoRuleEngine.swift

struct ImportResult { var sources: [LegadoSource]; var skipped: Int }

func sourceIdentityKey(_ source: LegadoSource) -> String {
    // Legado keys by the complete source URL. A trailing slash, path case or
    // fragment can distinguish two separately maintained rule variants.
    let url = source.bookSourceUrl
    return url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "name:" + source.bookSourceName : url
}

private func uniqueSources(_ sources: [LegadoSource]) -> [LegadoSource] {
    var seen = Set<String>()
    return sources.filter { seen.insert(sourceIdentityKey($0)).inserted }
}

// Source packs are not consistent about their envelope. In the wild the array
// can be under data/list/items, encoded as a JSON string, or nested several
// levels deep. Walk the whole JSON value so one envelope cannot hide 980
// otherwise valid sources.
private func collectSourceDictionaries(_ value: Any, depth: Int = 0,
                                       sources: inout [LegadoSource], skipped: inout Int) {
    guard depth < 10 else { return }
    if let dict = value as? [String: Any] {
        let looksLikeSource = dict["bookSourceName"] != nil || dict["bookSourceUrl"] != nil
        if looksLikeSource {
            if let source = decodeOneSource(from: dict) {
                sources.append(source)
            } else {
                skipped += 1
            }
            return
        }
        for nested in dict.values {
            collectSourceDictionaries(nested, depth: depth + 1, sources: &sources, skipped: &skipped)
        }
        return
    }
    if let array = value as? [Any] {
        for nested in array {
            collectSourceDictionaries(nested, depth: depth + 1, sources: &sources, skipped: &skipped)
        }
        return
    }
    if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2, (trimmed.hasPrefix("[") || trimmed.hasPrefix("{")),
              let data = trimmed.data(using: .utf8),
              let nested = try? JSONSerialization.jsonObject(with: data) else { return }
        collectSourceDictionaries(nested, depth: depth + 1, sources: &sources, skipped: &skipped)
    }
}

func extractJSONSubstring(_ text: String) -> String {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("\u{FEFF}") { t = String(t.dropFirst()) }
    // If the page is HTML, pull the JSON out of a <pre> block or the first [/{ ... ]/}
    if t.lowercased().contains("<html") || t.lowercased().contains("<pre") {
        if let preStart = t.range(of: "<pre", options: .caseInsensitive),
           let gt = t[preStart.upperBound...].firstIndex(of: ">"),
           let preEnd = t[gt...].range(of: "</pre>", options: .caseInsensitive) {
            t = String(t[t.index(after: gt)..<preEnd.lowerBound])
        } else if let first = t.firstIndex(where: { $0 == "[" || $0 == "{" }),
                  let last = t.lastIndex(where: { $0 == "]" || $0 == "}" }) {
            t = String(t[first...last])
        }
    }
    if let first = t.firstIndex(where: { $0 == "[" || $0 == "{" }),
       let last = t.lastIndex(where: { $0 == "]" || $0 == "}" }), first <= last {
        // Only slice when there is junk outside the JSON (BOM, comments, HTML tail)
        if first != t.startIndex || last != t.index(before: t.endIndex) { t = String(t[first...last]) }
    }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

func decodeOneSource(from dict: [String: Any]) -> LegadoSource? {
    guard let d = try? JSONSerialization.data(withJSONObject: dict),
          let s = try? JSONDecoder().decode(LegadoSource.self, from: d),
          !s.bookSourceName.isEmpty || !s.bookSourceUrl.isEmpty else { return nil }
    return s
}

func unescapeHTMLJSON(_ text: String) -> String {
    text.replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#34;", with: "\"")
        .replacingOccurrences(of: "&#x22;", with: "\"")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
}

// Scan an HTML/JS page for an object that actually contains bookSourceName.
// A detail page is not JSON: taking first "{" to last "}" grabs the whole page
// and JSON parsing fails. Instead, find each bookSourceName occurrence and
// expand to its enclosing balanced braces (string-aware, so braces inside
// rule strings do not break the count).
func scanEmbeddedSources(_ rawText: String) -> [LegadoSource] {
    let text = unescapeHTMLJSON(rawText)
    var out: [LegadoSource] = []
    var searchFrom = text.startIndex
    while let keyRange = text[searchFrom...].range(of: "\"bookSourceName\"") {
        let keyPos = keyRange.lowerBound
        // Walk backwards to the opening brace that starts this object: track depth.
        var depth = 0; var start: String.Index? = nil
        var idx = keyPos
        while idx > text.startIndex {
            idx = text.index(before: idx)
            let ch = text[idx]
            if ch == "}" { depth += 1 }
            else if ch == "{" {
                if depth == 0 { start = idx; break }
                depth -= 1
            }
        }
        guard let s = start else { break }
        // Walk forwards from s, string-aware, to the matching close brace.
        var d = 0; var inString = false; var escaped = false; var end: String.Index? = nil
        var j = s
        while j < text.endIndex {
            let ch = text[j]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                if ch == "\"" { inString = true }
                else if ch == "{" { d += 1 }
                else if ch == "}" { d -= 1; if d == 0 { end = j; break } }
            }
            j = text.index(after: j)
        }
        if let e = end {
            let chunk = String(text[s...e])
            if let d2 = chunk.data(using: .utf8), let dict = try? JSONSerialization.jsonObject(with: d2) as? [String: Any], let src = decodeOneSource(from: dict) {
                if !out.contains(where: { $0.bookSourceUrl == src.bookSourceUrl && $0.bookSourceName == src.bookSourceName }) { out.append(src) }
            }
            searchFrom = text.index(after: e)
        } else { break }
    }
    return out
}

func importSourcesDetailed(_ rawText: String) -> ImportResult {
    // Decode valid JSON first: unescaping &quot; inside rule strings corrupts JSON.
    let direct = extractJSONSubstring(rawText)
    let directIsJSON = direct.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil
    let text = directIsJSON ? direct : extractJSONSubstring(unescapeHTMLJSON(rawText))
    var sources: [LegadoSource] = []
    var skipped = 0
    if let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) {
        collectSourceDictionaries(root, sources: &sources, skipped: &skipped)
    } else {
        // Last resort: scan concatenated JSON objects with string-aware brace
        // matching. Braces inside JS/regex strings must not end an object.
        var depth = 0; var start: String.Index?
        var inString = false; var escaped = false
        for idx in text.indices {
            let ch = text[idx]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            if ch == "\"" { inString = true }
            else if ch == "{" { if depth == 0 { start = idx }; depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0, let s = start {
                    let chunk = String(text[s...idx])
                    if let data = chunk.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) {
                        collectSourceDictionaries(root, sources: &sources, skipped: &skipped)
                    } else { skipped += 1 }
                    start = nil
                }
            }
        }
    }
    if sources.isEmpty {
        // HTML detail page: the JSON is embedded in the page, not the whole page.
        let embedded = scanEmbeddedSources(rawText)
        if !embedded.isEmpty { return ImportResult(sources: uniqueSources(embedded).map { var x = $0; x.enabled = true; return x }, skipped: skipped) }
    }
    // Legado enables imported sources by default: a JSON enabled=false must not
    // make 1000 imported sources invisible in search/discovery.
    // Dedupe by name+url: a pack that repeats the same source must not
    // inflate the count, and the count shown after import is the real count.
    return ImportResult(sources: uniqueSources(sources).map { var x = $0; x.enabled = true; return x }, skipped: skipped)
}

func importSourcesFromText(_ text: String) -> [LegadoSource] {
    importSourcesDetailed(text).sources
}

func normalizeSourceURL(_ urlString: String) -> String {
    var u = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    // GitHub blob page -> raw file (a blob page is HTML, not JSON, and used to make network import always fail)
    if u.contains("github.com/") && u.contains("/blob/") {
        u = u.replacingOccurrences(of: "github.com/", with: "raw.githubusercontent.com/").replacingOccurrences(of: "/blob/", with: "/")
    }
    return u
}

// yckceo 合集接口（/shuyuans/json/id/xxx.json）会 302 到 jsdelivr 的 .json 直链。
// 若客户端拿到的是 HTML 跳转页（meta refresh / 嵌入的 jsdelivr 链接），从这里把真实 JSON 地址抠出来。
func extractRedirectJSONURL(from text: String) -> String? {
    let metaRe = try? NSRegularExpression(pattern: #"url\s*=\s*["']?(https?://[^"'\s>]+)"#, options: .caseInsensitive)
    let jsonRe = try? NSRegularExpression(pattern: #"https?://[^"'\s<>]+\.json"#, options: .caseInsensitive)
    if let re = metaRe, let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range(at: 1), in: text) {
        let u = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        if u.hasPrefix("http") && (u.contains("jsdelivr") || u.contains("gcore") || u.hasSuffix(".json")) { return u }
    }
    if let re = jsonRe, let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range(at: 0), in: text) {
        let u = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        if u.contains("jsdelivr") || u.contains("gcore") { return u }
    }
    return nil
}

// yckceo detail page (HTML, not JSON) -> its JSON API. The site's own pattern is
// /yuedu/shuyuan/json/id/<id>.json, while the detail page is
// /yuedu/shuyuans/content/id/<id>.html (plural "shuyuans" + "content").
// Pasting the detail page used to fetch HTML and fail with "no source found".
func yckceoJSONCandidates(_ urlString: String) -> [String] {
    let u = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let re = try? NSRegularExpression(pattern: "yuedu/shuyuans?/content/id/(\\d+)\\.html"),
          let m = re.firstMatch(in: u, range: NSRange(u.startIndex..., in: u)),
          let idRange = Range(m.range(at: 1), in: u) else { return [] }
    let id = String(u[idRange])
    // Rebuild from the original URL by replacing the matched path segment.
    let ns = u as NSString
    let replaced = ns.replacingCharacters(in: m.range, with: "yuedu/shuyuan/json/id/\(id).json")
    let alt = ns.replacingCharacters(in: m.range, with: "yuedu/shuyuans/json/id/\(id).json")
    return [replaced, alt]
}

private func collectSourcePackLinks(_ value: Any, baseURL: String,
                                    links: inout [String], depth: Int = 0) {
    guard depth < 8 else { return }
    if let dict = value as? [String: Any] {
        let isSource = dict["bookSourceName"] != nil || dict["bookSourceUrl"] != nil
        // Rule URLs inside a real source are not subscription links.
        if isSource { return }
        if !isSource {
            for key in ["url", "sourceUrl", "link", "src", "href"] {
                guard let raw = dict[key] as? String, !raw.isEmpty else { continue }
                let link = raw.hasPrefix("http") ? raw : resolveUrl(raw, base: baseURL)
                if link.hasPrefix("http"), !links.contains(link) { links.append(link) }
            }
        }
        for nested in dict.values {
            collectSourcePackLinks(nested, baseURL: baseURL, links: &links, depth: depth + 1)
        }
    } else if let array = value as? [Any] {
        for nested in array {
            collectSourcePackLinks(nested, baseURL: baseURL, links: &links, depth: depth + 1)
        }
    } else if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[") || trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let nested = try? JSONSerialization.jsonObject(with: data) else { return }
        collectSourcePackLinks(nested, baseURL: baseURL, links: &links, depth: depth + 1)
    }
}

struct SourcePackImportResult {
    struct Failure { let url: String; let reason: String }
    var sources: [LegadoSource] = []
    var skipped = 0
    var duplicateSources = 0
    var fetchedPacks = 0
    var failures: [Failure] = []
    var diagnostics: String {
        var lines = ["已读取 \(fetchedPacks) 个文件，格式异常 \(skipped) 条，跨文件重复 \(duplicateSources) 条"]
        if !failures.isEmpty {
            lines.append("部分导入：\(failures.count) 个文件失败，未计入成功数量；可复制失败地址重试。")
            lines.append(contentsOf: failures.map { "\($0.url)\n\($0.reason)" })
        }
        return lines.joined(separator: "\n")
    }
}

private struct SourcePackPage {
    let url: String
    var sources: [LegadoSource] = []
    var links: [String] = []
    var skipped = 0
    var error: String?
}

private func fetchSourcePack(_ address: String) async throws -> SourcePackPage {
    let page = try await SourceHTTP.load(SourceHTTP.request(normalizeSourceURL(address), base: address), stage: "书源导入")
    let result = importSourcesDetailed(page.text)
    var links: [String] = []
    for text in [extractJSONSubstring(page.text), extractJSONSubstring(unescapeHTMLJSON(page.text))] {
        if let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) {
            collectSourcePackLinks(root, baseURL: page.url, links: &links)
            break
        }
    }
    if result.sources.isEmpty && links.isEmpty, let redirect = extractRedirectJSONURL(from: page.text) { links.append(redirect) }
    if result.sources.isEmpty && links.isEmpty {
        throw SourceFailure(stage: "书源导入", message: "没有找到有效书源或子合集链接", url: page.url)
    }
    return SourcePackPage(url: page.url, sources: result.sources, links: links, skipped: result.skipped)
}

func importSourcePacksFromURL(_ urlString: String) async throws -> SourcePackImportResult {
    var first: SourcePackPage?
    var lastError: Error?
    for candidate in yckceoJSONCandidates(urlString) + [normalizeSourceURL(urlString)] {
        do { first = try await fetchSourcePack(candidate); break }
        catch { if Task.isCancelled { throw CancellationError() }; lastError = error }
    }
    guard let first else { throw lastError ?? SourceFailure(stage: "书源导入", message: "链接无效", url: urlString) }
    var result = SourcePackImportResult()
    var queue: [String] = []
    var visited = Set([normalizeSourceURL(urlString), first.url])
    var seenSources = Set<String>()
    func absorb(_ page: SourcePackPage) {
        if let error = page.error { result.failures.append(.init(url: page.url, reason: error)); return }
        result.fetchedPacks += 1; result.skipped += page.skipped
        for source in page.sources {
            if seenSources.insert(sourceIdentityKey(source)).inserted { result.sources.append(source) }
            else { result.duplicateSources += 1 }
        }
        for raw in page.links {
            let link = normalizeSourceURL(raw)
            if visited.insert(link).inserted { queue.append(link) }
        }
    }
    absorb(first)
    var index = 0
    while index < queue.count {
        try Task.checkCancellation()
        // Safety limit is visible in the report; never silently drop a tail.
        if index >= 5000 {
            result.failures.append(contentsOf: queue[index...].map { .init(url: $0, reason: "超过单次 5000 个子合集限制，请单独导入此链接") })
            break
        }
        let batch = Array(queue[index..<min(index + 8, queue.count, 5000)])
        index += batch.count
        let pages = await withTaskGroup(of: (Int, SourcePackPage).self) { group in
            for (offset, link) in batch.enumerated() {
                group.addTask {
                    do { return (offset, try await fetchSourcePack(link)) }
                    catch { return (offset, SourcePackPage(url: link, error: sourceErrorMessage(error))) }
                }
            }
            var output: [(Int, SourcePackPage)] = []
            for await page in group { output.append(page) }
            return output.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        for page in pages { absorb(page) }
    }
    try Task.checkCancellation()
    guard !result.sources.isEmpty else { throw SourceFailure(stage: "书源导入", message: result.diagnostics, url: urlString) }
    return result
}

func importSourcesFromURL(_ urlString: String) async throws -> [LegadoSource] {
    try await importSourcePacksFromURL(urlString).sources
}

// MARK: - Legado 订阅源（RssSource）
// 订阅源与书源并列：sourceName/sourceUrl 标识，规则字段 ruleArticles/ruleTitle/
// ruleLink/ruleContent 等用于 RSS/网页订阅解析。yckceo 的订阅源绝大多数是
// singleUrl 导航型（sourceUrl 指向网站或源仓库首页），作用是「源仓库导航书签」。

struct RssSource: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var sourceName: String = ""
    var sourceUrl: String = ""
    var sourceIcon: String = ""
    var sourceGroup: String = ""
    var sourceComment: String = ""
    var enabled: Bool = true
    var articleStyle: Int = 0
    var customOrder: Int = 0
    var enableJs: Bool = true
    var enabledCookieJar: Bool = true
    var loadWithBaseUrl: Bool = true
    var singleUrl: Bool = true
    var lastUpdateTime: Int64 = 0
    // 列表 / 正文规则（真正的 RSS 规则源才有值）
    var sortUrl: String = ""
    var header: String = ""
    var jsLib: String = ""
    var loginUrl: String = ""
    var type: Int = 0
    var ruleArticles: String = ""
    var ruleNextPage: String = ""
    var ruleTitle: String = ""
    var rulePubDate: String = ""
    var ruleDescription: String = ""
    var ruleImage: String = ""
    var ruleLink: String = ""
    var ruleContent: String = ""

    enum CodingKeys: String, CodingKey {
        case id, sourceName, sourceUrl, sourceIcon, sourceGroup, sourceComment, enabled, articleStyle, customOrder, enableJs, enabledCookieJar, loadWithBaseUrl, singleUrl, lastUpdateTime, sortUrl, header, jsLib, loginUrl, type, ruleArticles, ruleNextPage, ruleTitle, rulePubDate, ruleDescription, ruleImage, ruleLink, ruleContent
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id), !s.isEmpty { id = s }
        sourceName = c.tolerantString(.sourceName); sourceUrl = c.tolerantString(.sourceUrl)
        sourceIcon = c.tolerantString(.sourceIcon); sourceGroup = c.tolerantString(.sourceGroup)
        sourceComment = c.tolerantString(.sourceComment)
        enabled = c.tolerantBool(.enabled, defaultValue: true)
        articleStyle = c.tolerantInt(.articleStyle); customOrder = c.tolerantInt(.customOrder)
        enableJs = c.tolerantBool(.enableJs, defaultValue: true)
        enabledCookieJar = c.tolerantBool(.enabledCookieJar, defaultValue: true)
        loadWithBaseUrl = c.tolerantBool(.loadWithBaseUrl, defaultValue: true)
        singleUrl = c.tolerantBool(.singleUrl, defaultValue: false)
        lastUpdateTime = Int64(c.tolerantInt(.lastUpdateTime))
        sortUrl = c.tolerantString(.sortUrl)
        header = c.tolerantString(.header)
        if header.isEmpty, let map = try? c.decode([String: String].self, forKey: .header),
           let data = try? JSONSerialization.data(withJSONObject: map), let text = String(data: data, encoding: .utf8) { header = text }
        jsLib = c.tolerantString(.jsLib); loginUrl = c.tolerantString(.loginUrl); type = c.tolerantInt(.type)
        ruleArticles = c.tolerantString(.ruleArticles); ruleNextPage = c.tolerantString(.ruleNextPage)
        ruleTitle = c.tolerantString(.ruleTitle); rulePubDate = c.tolerantString(.rulePubDate)
        ruleDescription = c.tolerantString(.ruleDescription); ruleImage = c.tolerantString(.ruleImage)
        ruleLink = c.tolerantString(.ruleLink); ruleContent = c.tolerantString(.ruleContent)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(sourceName, forKey: .sourceName); try c.encode(sourceUrl, forKey: .sourceUrl)
        try c.encode(sourceIcon, forKey: .sourceIcon); try c.encode(sourceGroup, forKey: .sourceGroup); try c.encode(sourceComment, forKey: .sourceComment)
        try c.encode(enabled, forKey: .enabled); try c.encode(articleStyle, forKey: .articleStyle); try c.encode(customOrder, forKey: .customOrder)
        try c.encode(enableJs, forKey: .enableJs); try c.encode(enabledCookieJar, forKey: .enabledCookieJar); try c.encode(loadWithBaseUrl, forKey: .loadWithBaseUrl)
        try c.encode(singleUrl, forKey: .singleUrl); try c.encode(lastUpdateTime, forKey: .lastUpdateTime)
        try c.encode(sortUrl, forKey: .sortUrl); try c.encode(header, forKey: .header); try c.encode(jsLib, forKey: .jsLib)
        try c.encode(loginUrl, forKey: .loginUrl); try c.encode(type, forKey: .type)
        try c.encode(ruleArticles, forKey: .ruleArticles); try c.encode(ruleNextPage, forKey: .ruleNextPage)
        try c.encode(ruleTitle, forKey: .ruleTitle); try c.encode(rulePubDate, forKey: .rulePubDate); try c.encode(ruleDescription, forKey: .ruleDescription)
        try c.encode(ruleImage, forKey: .ruleImage); try c.encode(ruleLink, forKey: .ruleLink); try c.encode(ruleContent, forKey: .ruleContent)
    }
    // 真正带列表规则的 RSS 订阅源
    var isRssRuleSource: Bool { !ruleArticles.isEmpty }
}

struct RssImportResult { var sources: [RssSource]; var skipped: Int }

func importRssSourcesDetailed(_ rawText: String) -> RssImportResult {
    // Decode valid JSON first: unescaping &quot; inside rule strings corrupts JSON.
    let direct = extractJSONSubstring(rawText)
    let directIsJSON = direct.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil
    let text = directIsJSON ? direct : extractJSONSubstring(unescapeHTMLJSON(rawText))
    guard let data = text.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) else {
        return RssImportResult(sources: [], skipped: 0)
    }
    var dicts: [[String: Any]] = []
    if let arr = root as? [Any] {
        dicts = arr.compactMap { $0 as? [String: Any] }
    } else if let obj = root as? [String: Any] {
        if let arr = obj["rssSources"] as? [Any] { dicts = arr.compactMap { $0 as? [String: Any] } }
        else if obj["sourceName"] != nil || obj["sourceUrl"] != nil { dicts = [obj] }
    }
    var out: [RssSource] = []
    var skipped = 0
    for dict in dicts {
        guard let d = try? JSONSerialization.data(withJSONObject: dict),
              let s = try? JSONDecoder().decode(RssSource.self, from: d),
              !s.sourceName.isEmpty || !s.sourceUrl.isEmpty else { skipped += 1; continue }
        out.append(s)
    }
    var seen = Set<String>(); var deduped: [RssSource] = []
    for s in out {
        let k = s.sourceUrl.isEmpty ? s.sourceName : s.sourceUrl
        if seen.contains(k) { continue }
        seen.insert(k); deduped.append(s)
    }
    return RssImportResult(sources: deduped, skipped: skipped)
}

func importRssSourcesFromText(_ text: String) -> [RssSource] {
    importRssSourcesDetailed(text).sources
}

// yckceo 订阅源详情页(/yuedu/rss/content/id/ID.html) -> 其 JSON API
func yckceoRssJSONCandidates(_ urlString: String) -> [String] {
    let u = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let re = try? NSRegularExpression(pattern: "yuedu/rsss?/content/id/(\\d+)\\.html"),
          let m = re.firstMatch(in: u, range: NSRange(u.startIndex..., in: u)),
          let idRange = Range(m.range(at: 1), in: u) else { return [] }
    let id = String(u[idRange])
    let ns = u as NSString
    let replaced = ns.replacingCharacters(in: m.range, with: "yuedu/rss/json/id/\(id).json")
    let alt = ns.replacingCharacters(in: m.range, with: "yuedu/rsss/json/id/\(id).json")
    return [replaced, alt]
}

func importRssSourcesFromURL(_ urlString: String) async throws -> [RssSource] {
    var candidates: [String] = []
    for c in yckceoRssJSONCandidates(urlString) where !candidates.contains(c) { candidates.append(c) }
    candidates.append(normalizeSourceURL(urlString))
    for candidate in candidates {
        if let text = try? await fetchText(urlString: candidate) {
            let result = importRssSourcesDetailed(text)
            if !result.sources.isEmpty { return result.sources }
        }
    }
    return []
}
