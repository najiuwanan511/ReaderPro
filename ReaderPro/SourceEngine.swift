import Foundation

// MARK: - Legado source (subset of the Legado JSON rule spec, enough for real sources)
// Import fix (2026-10-29): the old synthesized Codable was all-or-nothing.
// A real Legado list has null fields, Int/Bool fields, extra fields (exploreUrl,
// ruleExplore, lastUpdateTime, weight, header, loginUrl, ...) and one bad entry
// used to kill the whole array. Now every field is read tolerantly (null -> "",
// number/bool -> string, missing -> default) and every list entry is decoded
// separately, so one bad source no longer blocks the rest.

struct LegadoSource: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var bookSourceName: String = ""
    var bookSourceUrl: String = ""
    var bookSourceGroup: String = ""
    var enabled: Bool = true
    var searchUrl: String = ""
    var discoverUrl: String = ""
    var exploreUrl: String = ""
    var ruleSearch: RuleSet = RuleSet()
    var ruleBookInfo: RuleSet = RuleSet()
    var ruleToc: RuleSet = RuleSet()
    var ruleContent: RuleSet = RuleSet()
    var ruleDiscover: RuleSet = RuleSet()
    var ruleExplore: RuleSet = RuleSet()
    var bookSourceType: Int = 0 // 0 文本, 1 音频, 2 图片/漫画
    struct RuleSet: Codable, Equatable {
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
        enum CodingKeys: String, CodingKey {
            case bookList, name, author, bookUrl, coverUrl, intro, tocUrl, chapterList, chapterName, chapterUrl, content, nextContentUrl, nextTocUrl, kind, wordCount, lastChapter, replaceRegex, imageUrl
        }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bookList = c.tolerantString(.bookList); name = c.tolerantString(.name); author = c.tolerantString(.author)
            bookUrl = c.tolerantString(.bookUrl); coverUrl = c.tolerantString(.coverUrl); intro = c.tolerantString(.intro)
            tocUrl = c.tolerantString(.tocUrl); chapterList = c.tolerantString(.chapterList); chapterName = c.tolerantString(.chapterName)
            chapterUrl = c.tolerantString(.chapterUrl); content = c.tolerantString(.content); nextContentUrl = c.tolerantString(.nextContentUrl)
            nextTocUrl = c.tolerantString(.nextTocUrl); kind = c.tolerantString(.kind); wordCount = c.tolerantString(.wordCount)
            lastChapter = c.tolerantString(.lastChapter); replaceRegex = c.tolerantString(.replaceRegex); imageUrl = c.tolerantString(.imageUrl)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(bookList, forKey: .bookList); try c.encode(name, forKey: .name); try c.encode(author, forKey: .author)
            try c.encode(bookUrl, forKey: .bookUrl); try c.encode(coverUrl, forKey: .coverUrl); try c.encode(intro, forKey: .intro)
            try c.encode(tocUrl, forKey: .tocUrl); try c.encode(chapterList, forKey: .chapterList); try c.encode(chapterName, forKey: .chapterName)
            try c.encode(chapterUrl, forKey: .chapterUrl); try c.encode(content, forKey: .content); try c.encode(nextContentUrl, forKey: .nextContentUrl)
            try c.encode(nextTocUrl, forKey: .nextTocUrl); try c.encode(kind, forKey: .kind); try c.encode(wordCount, forKey: .wordCount)
            try c.encode(lastChapter, forKey: .lastChapter); try c.encode(replaceRegex, forKey: .replaceRegex); try c.encode(imageUrl, forKey: .imageUrl)
        }
    }
    enum CodingKeys: String, CodingKey {
        case id, bookSourceName, bookSourceUrl, bookSourceGroup, enabled, searchUrl, discoverUrl, exploreUrl, bookSourceType, ruleSearch, ruleBookInfo, ruleToc, ruleContent, ruleDiscover, ruleExplore
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id), !s.isEmpty { id = s }
        bookSourceName = c.tolerantString(.bookSourceName); bookSourceUrl = c.tolerantString(.bookSourceUrl)
        bookSourceGroup = c.tolerantString(.bookSourceGroup); enabled = c.tolerantBool(.enabled, defaultValue: true)
        searchUrl = c.tolerantString(.searchUrl); discoverUrl = c.tolerantString(.discoverUrl); exploreUrl = c.tolerantString(.exploreUrl)
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
        try c.encode(ruleSearch, forKey: .ruleSearch); try c.encode(ruleBookInfo, forKey: .ruleBookInfo); try c.encode(ruleToc, forKey: .ruleToc)
        try c.encode(ruleContent, forKey: .ruleContent); try c.encode(ruleDiscover, forKey: .ruleDiscover); try c.encode(ruleExplore, forKey: .ruleExplore); try c.encode(bookSourceType, forKey: .bookSourceType)
    }
    // Legado's real discovery fields are exploreUrl + ruleExplore, not discoverUrl.
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

func fetchText(urlString: String) async throws -> String {
    guard let url = URL(string: urlString) else { throw NSError(domain: "url", code: 1) }
    var req = URLRequest(url: url, timeoutInterval: 90)
    req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) ReaderPro/1.0", forHTTPHeaderField: "User-Agent")
    req.setValue("https://www.yckceo.com/", forHTTPHeaderField: "Referer")
    let (data, _) = try await URLSession.shared.data(for: req)
    return decodeTextData(data)
}

func fetchText(urlString: String, method: String, body: String) async throws -> String {
    guard let url = URL(string: urlString) else { throw NSError(domain: "url", code: 1) }
    var req = URLRequest(url: url, timeoutInterval: 25)
    req.httpMethod = method
    req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) ReaderPro/1.0", forHTTPHeaderField: "User-Agent")
    req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
    req.httpBody = body.data(using: .utf8)
    let (data, _) = try await URLSession.shared.data(for: req)
    return decodeTextData(data)
}

func resolveUrl(_ raw: String, base: String) -> String {
    if raw.hasPrefix("http") { return raw }
    if raw.hasPrefix("//") { return "https:" + raw }
    guard let baseURL = URL(string: base), let u = URL(string: raw, relativeTo: baseURL) else { return raw }
    return u.absoluteString
}

// NOTE: rule engine, search, chapters, content and explore live in LegadoRuleEngine.swift

struct ImportResult { var sources: [LegadoSource]; var skipped: Int }

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
    let text = extractJSONSubstring(unescapeHTMLJSON(rawText))
    guard let data = text.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) else {
        // Last resort: scan for individual {...} objects (newline-separated sources, no array)
        var sources: [LegadoSource] = []; var skipped = 0
        var depth = 0; var start: String.Index? = nil
        for idx in text.indices {
            let ch = text[idx]
            if ch == "{" { if depth == 0 { start = idx }; depth += 1 }
            else if ch == "}" { depth -= 1; if depth == 0, let s = start {
                let chunk = String(text[s...idx])
                if let d = chunk.data(using: .utf8), let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let src = decodeOneSource(from: dict) { sources.append(src) } else { skipped += 1 }
                start = nil
            } }
        }
        return ImportResult(sources: sources, skipped: skipped)
    }
    var dicts: [[String: Any]] = []
    if let arr = root as? [Any] {
        dicts = arr.compactMap { $0 as? [String: Any] }
    } else if let obj = root as? [String: Any] {
        for key in ["sources", "bookSources", "data", "list", "items", "results"] {
            if let arr = obj[key] as? [Any] { dicts = arr.compactMap { $0 as? [String: Any] }; break }
            if let single = obj[key] as? [String: Any], single["bookSourceName"] != nil || single["bookSourceUrl"] != nil { dicts = [single]; break }
        }
        if dicts.isEmpty && (obj["bookSourceName"] != nil || obj["bookSourceUrl"] != nil) { dicts = [obj] }
    }
    var sources: [LegadoSource] = []; var skipped = 0
    for dict in dicts {
        if let s = decodeOneSource(from: dict) { sources.append(s) } else { skipped += 1 }
    }
    if sources.isEmpty {
        // HTML detail page: the JSON is embedded in the page, not the whole page.
        let embedded = scanEmbeddedSources(rawText)
        if !embedded.isEmpty { return ImportResult(sources: embedded.map { var x = $0; x.enabled = true; return x }, skipped: skipped) }
    }
    // Legado enables imported sources by default: a JSON enabled=false must not
    // make 1000 imported sources invisible in search/discovery.
    // Dedupe by name+url: a pack that repeats the same source must not
    // inflate the count, and the count shown after import is the real count.
    var seen = Set<String>(); var deduped: [LegadoSource] = []
    for s in sources {
        let k = s.bookSourceName + "|" + s.bookSourceUrl
        if seen.contains(k) { continue }
        seen.insert(k); deduped.append(s)
    }
    return ImportResult(sources: deduped.map { var x = $0; x.enabled = true; return x }, skipped: skipped)
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

func importSourcesFromURL(_ urlString: String) async throws -> [LegadoSource] {
    // Try the JSON API first for detail pages, then the original URL.
    var candidates: [String] = []
    for c in yckceoJSONCandidates(urlString) where !candidates.contains(c) { candidates.append(c) }
    candidates.append(normalizeSourceURL(urlString))
    var lastText = ""
    for candidate in candidates {
        var text: String? = nil
        // 11MB 大合集在慢网络下容易超时，重试 2 次
        for _ in 0..<2 {
            if let t = try? await fetchText(urlString: candidate) { text = t; break }
        }
        guard var t = text else { continue }
        lastText = t
        // yckceo 合集接口会 302 到 jsdelivr；若拿到的是 HTML 跳转页（非标准重定向），提取真实 JSON 地址再拉一次
        if let real = extractRedirectJSONURL(from: t), let t2 = try? await fetchText(urlString: real) {
            t = t2; lastText = t2
        }
        let result = importSourcesDetailed(t)
        if !result.sources.isEmpty { return result.sources }
    }
    let text = lastText
    // Subscription list: an array of {name, url} entries pointing at other source lists.
    // Fix for "1000 sources imported, only ~18 show": the old code capped this
    // at the first 20 links, so a link-pack of hundreds/thousands of sources
    // silently became ~18-20. Fetch up to 300 linked lists, 20 at a time.
    if let data = extractJSONSubstring(text).data(using: .utf8),
       let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
        var links: [String] = []
        for item in arr {
            if let d = item as? [String: Any], let link = d["url"] as? String, link.hasPrefix("http"), !links.contains(link) { links.append(link) }
        }
        var out: [LegadoSource] = []
        var idx = 0
        while idx < links.count && idx < 300 {
            let batch = Array(links[idx..<min(idx + 20, links.count, 300)])
            idx += batch.count
            let batchSources = await withTaskGroup(of: [LegadoSource].self) { group in
                for link in batch {
                    group.addTask {
                        if let t2 = try? await fetchText(urlString: normalizeSourceURL(link)) {
                            return importSourcesDetailed(t2).sources
                        }
                        return []
                    }
                }
                var collected: [LegadoSource] = []
                for await s in group { collected.append(contentsOf: s) }
                return collected
            }
            out.append(contentsOf: batchSources)
        }
        // Dedupe by name+url so the same source from several links is not counted twice.
        var seen = Set<String>(); var deduped: [LegadoSource] = []
        for s in out {
            let k = s.bookSourceName + "|" + s.bookSourceUrl
            if seen.contains(k) { continue }
            seen.insert(k); deduped.append(s)
        }
        if !deduped.isEmpty { return deduped }
    }
    return []
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
    var ruleArticles: String = ""
    var ruleNextPage: String = ""
    var ruleTitle: String = ""
    var rulePubDate: String = ""
    var ruleDescription: String = ""
    var ruleImage: String = ""
    var ruleLink: String = ""
    var ruleContent: String = ""

    enum CodingKeys: String, CodingKey {
        case id, sourceName, sourceUrl, sourceIcon, sourceGroup, sourceComment, enabled, articleStyle, customOrder, enableJs, enabledCookieJar, loadWithBaseUrl, singleUrl, lastUpdateTime, sortUrl, ruleArticles, ruleNextPage, ruleTitle, rulePubDate, ruleDescription, ruleImage, ruleLink, ruleContent
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
        singleUrl = c.tolerantBool(.singleUrl, defaultValue: true)
        lastUpdateTime = Int64(c.tolerantInt(.lastUpdateTime))
        sortUrl = c.tolerantString(.sortUrl)
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
        try c.encode(sortUrl, forKey: .sortUrl); try c.encode(ruleArticles, forKey: .ruleArticles); try c.encode(ruleNextPage, forKey: .ruleNextPage)
        try c.encode(ruleTitle, forKey: .ruleTitle); try c.encode(rulePubDate, forKey: .rulePubDate); try c.encode(ruleDescription, forKey: .ruleDescription)
        try c.encode(ruleImage, forKey: .ruleImage); try c.encode(ruleLink, forKey: .ruleLink); try c.encode(ruleContent, forKey: .ruleContent)
    }
    // 真正带列表规则的 RSS 订阅源
    var isRssRuleSource: Bool { !ruleArticles.isEmpty }
}

struct RssImportResult { var sources: [RssSource]; var skipped: Int }

func importRssSourcesDetailed(_ rawText: String) -> RssImportResult {
    let text = extractJSONSubstring(unescapeHTMLJSON(rawText))
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
        let k = s.sourceName + "|" + s.sourceUrl
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
