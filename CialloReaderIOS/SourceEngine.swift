import Foundation

// MARK: - Legado source (subset of the Legado JSON rule spec, enough for real sources)

struct LegadoSource: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var bookSourceName: String = ""
    var bookSourceUrl: String = ""
    var searchUrl: String = ""
    var ruleSearch: RuleSet = RuleSet()
    var ruleBookInfo: RuleSet = RuleSet()
    var ruleToc: RuleSet = RuleSet()
    var ruleContent: RuleSet = RuleSet()
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
    }
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
