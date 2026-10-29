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
        enum CodingKeys: String, CodingKey {
            case bookList, name, author, bookUrl, coverUrl, intro, tocUrl, chapterList, chapterName, chapterUrl, content, nextContentUrl, nextTocUrl, kind, wordCount, lastChapter, replaceRegex
        }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bookList = c.tolerantString(.bookList); name = c.tolerantString(.name); author = c.tolerantString(.author)
            bookUrl = c.tolerantString(.bookUrl); coverUrl = c.tolerantString(.coverUrl); intro = c.tolerantString(.intro)
            tocUrl = c.tolerantString(.tocUrl); chapterList = c.tolerantString(.chapterList); chapterName = c.tolerantString(.chapterName)
            chapterUrl = c.tolerantString(.chapterUrl); content = c.tolerantString(.content); nextContentUrl = c.tolerantString(.nextContentUrl)
            nextTocUrl = c.tolerantString(.nextTocUrl); kind = c.tolerantString(.kind); wordCount = c.tolerantString(.wordCount)
            lastChapter = c.tolerantString(.lastChapter); replaceRegex = c.tolerantString(.replaceRegex)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(bookList, forKey: .bookList); try c.encode(name, forKey: .name); try c.encode(author, forKey: .author)
            try c.encode(bookUrl, forKey: .bookUrl); try c.encode(coverUrl, forKey: .coverUrl); try c.encode(intro, forKey: .intro)
            try c.encode(tocUrl, forKey: .tocUrl); try c.encode(chapterList, forKey: .chapterList); try c.encode(chapterName, forKey: .chapterName)
            try c.encode(chapterUrl, forKey: .chapterUrl); try c.encode(content, forKey: .content); try c.encode(nextContentUrl, forKey: .nextContentUrl)
            try c.encode(nextTocUrl, forKey: .nextTocUrl); try c.encode(kind, forKey: .kind); try c.encode(wordCount, forKey: .wordCount)
            try c.encode(lastChapter, forKey: .lastChapter); try c.encode(replaceRegex, forKey: .replaceRegex)
        }
    }
    enum CodingKeys: String, CodingKey {
        case id, bookSourceName, bookSourceUrl, bookSourceGroup, enabled, searchUrl, discoverUrl, exploreUrl, ruleSearch, ruleBookInfo, ruleToc, ruleContent, ruleDiscover, ruleExplore
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
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(bookSourceName, forKey: .bookSourceName); try c.encode(bookSourceUrl, forKey: .bookSourceUrl)
        try c.encode(bookSourceGroup, forKey: .bookSourceGroup); try c.encode(enabled, forKey: .enabled); try c.encode(searchUrl, forKey: .searchUrl)
        try c.encode(discoverUrl, forKey: .discoverUrl); try c.encode(exploreUrl, forKey: .exploreUrl)
        try c.encode(ruleSearch, forKey: .ruleSearch); try c.encode(ruleBookInfo, forKey: .ruleBookInfo); try c.encode(ruleToc, forKey: .ruleToc)
        try c.encode(ruleContent, forKey: .ruleContent); try c.encode(ruleDiscover, forKey: .ruleDiscover); try c.encode(ruleExplore, forKey: .ruleExplore)
    }
    // Legado's real discovery fields are exploreUrl + ruleExplore, not discoverUrl.
    var effectiveDiscoverUrl: String { discoverUrl.isEmpty ? exploreUrl : discoverUrl }
    var effectiveDiscoverRule: RuleSet { ruleDiscover.bookList.isEmpty ? ruleExplore : ruleDiscover }
    static var demoGutenberg: LegadoSource {
        var s = LegadoSource()
        s.bookSourceName = "Gutenberg（公版书演示源）"
        s.bookSourceUrl = "https://www.gutenberg.org"
        s.searchUrl = "https://www.gutenberg.org/ebooks/search/?query={{key}}"
        s.ruleSearch.bookList = "@css:li.booklink"
        s.ruleSearch.name = "@css:a.link@text"
        s.ruleSearch.author = "@css:span.subtitle@text"
        s.ruleSearch.bookUrl = "@css:a.link@href"
        s.ruleSearch.intro = "@css:span.extra@text"
        // Gutenberg 书页没有小说目录结构，留空走通用链接兜底（正文 txt 链接可直接读）
        s.ruleContent.content = "@css:body@text"
        return s
    }
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
}

func fetchText(urlString: String) async throws -> String {
    guard let url = URL(string: urlString) else { throw NSError(domain: "url", code: 1) }
    var req = URLRequest(url: url, timeoutInterval: 25)
    req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) CialloReaderIOS/1.0", forHTTPHeaderField: "User-Agent")
    let (data, _) = try await URLSession.shared.data(for: req)
    return decodeTextData(data)
}

func resolveUrl(_ raw: String, base: String) -> String {
    if raw.hasPrefix("http") { return raw }
    if raw.hasPrefix("//") { return "https:" + raw }
    guard let baseURL = URL(string: base), let u = URL(string: raw, relativeTo: baseURL) else { return raw }
    return u.absoluteString
}

// Simple CSS-ish extraction: supports tag, tag.class, .class, tag#id, and suffix @text / @attr(name) / @href
func cssExtractAll(_ html: String, _ selector: String) -> [String] {
    var sel = selector
    var attr: String? = nil
    if let at = sel.range(of: "@") {
        attr = String(sel[at.upperBound...]); sel = String(sel[..<at.lowerBound])
    }
    sel = sel.trimmingCharacters(in: .whitespaces)
    if sel.isEmpty || sel == "@text" { return [stripHTML(html)] }
    let parts = sel.split(separator: ".")
    let tag = parts.first.map(String.init) ?? ""
    let cls = parts.count > 1 ? String(parts[1]) : nil
    // Find elements: <tag ...>...</tag>  (non-greedy, dot matches newline via (?s))
    let tagPat = tag.isEmpty ? "[a-zA-Z][a-zA-Z0-9]*" : NSRegularExpression.escapedPattern(for: tag)
    var pattern = "<\(tagPat)\\b[^>]*>(.*?)</\(tagPat)>"
    if tag.isEmpty { pattern = "<([a-zA-Z][a-zA-Z0-9]*)\\b[^>]*>(.*?)</\\1>" }
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
    let ns = html as NSString
    var out: [String] = []
    for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
        let full = ns.substring(with: m.range)
        let innerRange = m.numberOfRanges >= 2 ? m.range(at: m.numberOfRanges - 1) : m.range
        let inner = ns.substring(with: innerRange)
        if cls != nil, !full.lowercased().contains("class=\"") && !full.lowercased().contains("class='") { continue }
        if let c = cls {
            // check class attribute contains c
            let classRe = try? NSRegularExpression(pattern: "class=[\"']([^\"']*)[\"']")
            let fr = full as NSString
            var ok = false
            if let cm = classRe?.firstMatch(in: full, range: NSRange(location: 0, length: fr.length)) {
                let v = fr.substring(with: cm.range(at: 1))
                ok = v.split(separator: " ").contains(where: { String($0) == c })
            }
            if !ok { continue }
        }
        if let a = attr {
            if a == "text" { out.append(stripHTML(inner).trimmingCharacters(in: .whitespacesAndNewlines)) }
            else {
                let aRe = try? NSRegularExpression(pattern: "\(NSRegularExpression.escapedPattern(for: a))=[\"']([^\"']*)[\"']")
                let fr = full as NSString
                if let am = aRe?.firstMatch(in: full, range: NSRange(location: 0, length: fr.length)) { out.append(fr.substring(with: am.range(at: 1))) }
            }
        } else {
            out.append(inner)
        }
    }
    return out
}

func cssFirst(_ html: String, _ selector: String) -> String {
    cssExtractAll(html, selector).first ?? ""
}

// JSON path: $.data[*].title  /  $.results[*].name  (array of objects only)
func jsonExtract(_ jsonText: String, _ rule: String) -> [String] {
    var path = rule
    if path.hasPrefix("@json:") { path = String(path.dropFirst(6)) }
    guard let data = jsonText.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
    // split on [*]
    let segs = path.replacingOccurrences(of: "$.", with: "").replacingOccurrences(of: "$", with: "").split(separator: ".").map(String.init)
    var current: [Any] = [root]
    for seg in segs {
        var next: [Any] = []
        if seg == "[*]" || seg == "*" {
            for c in current { if let arr = c as? [Any] { next.append(contentsOf: arr) } }
        } else if seg.hasSuffix("[*]") {
            let key = String(seg.dropLast(3))
            for c in current { if let d = c as? [String: Any], let arr = d[key] as? [Any] { next.append(contentsOf: arr) } }
        } else {
            for c in current { if let d = c as? [String: Any], let v = d[seg] { next.append(v) } }
        }
        current = next
    }
    return current.map { v in
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }.filter { !$0.isEmpty }
}

func applyRule(_ htmlOrJson: String, _ rule: String, base: String) -> [String] {
    let r = rule.trimmingCharacters(in: .whitespaces)
    if r.isEmpty { return [] }
    if r.hasPrefix("@json:") { return jsonExtract(htmlOrJson, r) }
    if r.hasPrefix("@css:") { return cssExtractAll(htmlOrJson, String(r.dropFirst(5))) }
    if r.hasPrefix("@") {
        // @text / @href on a fragment
        if r == "@text" { return [stripHTML(htmlOrJson).trimmingCharacters(in: .whitespacesAndNewlines)] }
        if r == "@href" {
            let re = try? NSRegularExpression(pattern: "href=[\"']([^\"']*)[\"']")
            let ns = htmlOrJson as NSString
            if let m = re?.firstMatch(in: htmlOrJson, range: NSRange(location: 0, length: ns.length)) { return [ns.substring(with: m.range(at: 1))] }
            return []
        }
        return []
    }
    // plain: treat as json path if input looks like json, else css
    if htmlOrJson.trimmingCharacters(in: .whitespaces).hasPrefix("{") { return jsonExtract(htmlOrJson, r) }
    return cssExtractAll(htmlOrJson, r)
}

func applyRuleFirst(_ htmlOrJson: String, _ rule: String, base: String) -> String {
    applyRule(htmlOrJson, rule, base: base).first ?? ""
}

extension LegadoSource {
    func search(key: String) async throws -> [SourceBook] {
        let url = searchUrl.replacingOccurrences(of: "{{key}}", with: key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key)
            .replacingOccurrences(of: "{{page}}", with: "1")
            .replacingOccurrences(of: "{{page-1}}", with: "0")
        let html = try await fetchText(urlString: url)
        // bookList defines blocks; if empty, treat whole page as one block list via name rule
        var blocks: [String] = []
        if !ruleSearch.bookList.isEmpty {
            if ruleSearch.bookList.hasPrefix("@json:") {
                // json list: use name rule to get count, then per-index fields
                let names = applyRule(html, ruleSearch.name, base: bookSourceUrl)
                let authors = applyRule(html, ruleSearch.author, base: bookSourceUrl)
                let urls = applyRule(html, ruleSearch.bookUrl, base: bookSourceUrl)
                let intros = applyRule(html, ruleSearch.intro, base: bookSourceUrl)
                var out: [SourceBook] = []
                for i in 0..<names.count {
                    var b = SourceBook(title: names[i], url: i < urls.count ? resolveUrl(urls[i], base: bookSourceUrl) : "", sourceName: bookSourceName)
                    if i < authors.count { b.author = authors[i] }
                    if i < intros.count { b.intro = intros[i] }
                    out.append(b)
                }
                return out
            } else {
                blocks = applyRule(html, ruleSearch.bookList, base: bookSourceUrl)
            }
        }
        if blocks.isEmpty { blocks = [html] }
        var out: [SourceBook] = []
        for blk in blocks {
            let name = applyRuleFirst(blk, ruleSearch.name, base: bookSourceUrl)
            if name.isEmpty { continue }
            var b = SourceBook(title: name, url: resolveUrl(applyRuleFirst(blk, ruleSearch.bookUrl, base: bookSourceUrl), base: bookSourceUrl), sourceName: bookSourceName)
            b.author = applyRuleFirst(blk, ruleSearch.author, base: bookSourceUrl)
            b.cover = resolveUrl(applyRuleFirst(blk, ruleSearch.coverUrl, base: bookSourceUrl), base: bookSourceUrl)
            b.intro = applyRuleFirst(blk, ruleSearch.intro, base: bookSourceUrl)
            out.append(b)
        }
        return out
    }
    func fetchChapters(book: SourceBook) async throws -> [BookChapter] {
        var tocUrl = book.url
        if !ruleBookInfo.tocUrl.isEmpty {
            let html = try await fetchText(urlString: book.url)
            let t = applyRuleFirst(html, ruleBookInfo.tocUrl, base: bookSourceUrl)
            if !t.isEmpty { tocUrl = resolveUrl(t, base: bookSourceUrl) }
        }
        let html = try await fetchText(urlString: tocUrl)
        let items: [String]
        if !ruleToc.chapterList.isEmpty {
            items = applyRule(html, ruleToc.chapterList, base: bookSourceUrl)
        } else {
            items = []
        }
        var chapters: [BookChapter] = []
        if items.isEmpty {
            // fallback: all links in page
            let links = cssExtractAll(html, "a@href")
            let texts = cssExtractAll(html, "a@text")
            for i in 0..<min(links.count, texts.count) {
                let t = texts[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count > 2 && t.count < 80 { chapters.append(BookChapter(title: t, text: "")) }
            }
            // store urls in text field temporarily via id? use chapter text as url marker
            for i in 0..<chapters.count where i < links.count { chapters[i].text = "__URL__" + resolveUrl(links[i], base: bookSourceUrl) }
            return chapters
        }
        for item in items {
            let name = applyRuleFirst(item, ruleToc.chapterName, base: bookSourceUrl)
            let url = resolveUrl(applyRuleFirst(item, ruleToc.chapterUrl, base: bookSourceUrl), base: bookSourceUrl)
            let title = name.isEmpty ? stripHTML(item).trimmingCharacters(in: .whitespacesAndNewlines) : name
            if title.isEmpty { continue }
            chapters.append(BookChapter(title: title, text: "__URL__" + url))
        }
        return chapters
    }
    func fetchChapterContent(_ chapter: BookChapter) async throws -> String {
        guard chapter.text.hasPrefix("__URL__") else { return chapter.text }
        let url = String(chapter.text.dropFirst(7))
        let html = try await fetchText(urlString: url)
        var content = ""
        if !ruleContent.content.isEmpty {
            let parts = applyRule(html, ruleContent.content, base: bookSourceUrl)
            content = parts.joined(separator: "\n")
            if content.isEmpty { content = stripHTML(html) }
        } else {
            content = stripHTML(html)
        }
        // next page support (simplified: follow once if rule gives a url different from current)
        if !ruleContent.nextContentUrl.isEmpty {
            let next = applyRuleFirst(html, ruleContent.nextContentUrl, base: bookSourceUrl)
            if !next.isEmpty, next != url {
                let html2 = try? await fetchText(urlString: resolveUrl(next, base: bookSourceUrl))
                if let h2 = html2 {
                    let p2 = applyRule(h2, ruleContent.content, base: bookSourceUrl).joined(separator: "\n")
                    if !p2.isEmpty { content += "\n" + p2 }
                }
            }
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension LegadoSource {
    func discover() async throws -> [SourceBook] {
        guard !effectiveDiscoverUrl.isEmpty else { return [] }
        let html = try await fetchText(urlString: effectiveDiscoverUrl)
        let ruleDiscover = effectiveDiscoverRule
        if ruleDiscover.bookList.isEmpty { return [] }
        if ruleDiscover.bookList.hasPrefix("@json:") {
            let names = applyRule(html, ruleDiscover.name, base: bookSourceUrl)
            let authors = applyRule(html, ruleDiscover.author, base: bookSourceUrl)
            let urls = applyRule(html, ruleDiscover.bookUrl, base: bookSourceUrl)
            let covers = applyRule(html, ruleDiscover.coverUrl, base: bookSourceUrl)
            let intros = applyRule(html, ruleDiscover.intro, base: bookSourceUrl)
            var out: [SourceBook] = []
            for i in 0..<names.count {
                var b = SourceBook(title: names[i], url: i < urls.count ? resolveUrl(urls[i], base: bookSourceUrl) : "", sourceName: bookSourceName)
                if i < authors.count { b.author = authors[i] }
                if i < covers.count { b.cover = resolveUrl(covers[i], base: bookSourceUrl) }
                if i < intros.count { b.intro = intros[i] }
                out.append(b)
            }
            return out
        }
        let blocks = applyRule(html, ruleDiscover.bookList, base: bookSourceUrl)
        var out: [SourceBook] = []
        for blk in blocks {
            let name = applyRuleFirst(blk, ruleDiscover.name, base: bookSourceUrl)
            if name.isEmpty { continue }
            var b = SourceBook(title: name, url: resolveUrl(applyRuleFirst(blk, ruleDiscover.bookUrl, base: bookSourceUrl), base: bookSourceUrl), sourceName: bookSourceName)
            b.author = applyRuleFirst(blk, ruleDiscover.author, base: bookSourceUrl)
            b.cover = resolveUrl(applyRuleFirst(blk, ruleDiscover.coverUrl, base: bookSourceUrl), base: bookSourceUrl)
            b.intro = applyRuleFirst(blk, ruleDiscover.intro, base: bookSourceUrl)
            out.append(b)
        }
        return out
    }
}

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
        if !embedded.isEmpty { return ImportResult(sources: embedded, skipped: skipped) }
    }
    return ImportResult(sources: sources, skipped: skipped)
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
        if let text = try? await fetchText(urlString: candidate) {
            lastText = text
            let result = importSourcesDetailed(text)
            if !result.sources.isEmpty { return result.sources }
        }
    }
    let text = lastText
    // Subscription list: an array of {name, url} entries pointing at other source lists.
    // Fetch each linked list (cap 20) instead of giving up with "no source found".
    if let data = extractJSONSubstring(text).data(using: .utf8),
       let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
        var out: [LegadoSource] = []
        for item in arr.prefix(20) {
            if let d = item as? [String: Any], let link = d["url"] as? String, link.hasPrefix("http") {
                if let t2 = try? await fetchText(urlString: normalizeSourceURL(link)) {
                    out.append(contentsOf: importSourcesDetailed(t2).sources)
                }
            }
        }
        if !out.isEmpty { return out }
    }
    return []
}
