import Foundation

// MARK: - JS 规则执行上下文（TaskLocal，并发安全）
// 书源引擎执行 @js:/<js> 规则时需要知道当前书源的 sourceUrl、搜索词 key、书信息 book。
// 这些是"环境变量"，用 @TaskLocal 传递，避免在并发多源搜索时互相串值。
enum LegadoJSCtx {
    @TaskLocal static var deadline: Date?
    @TaskLocal static var sourceUrl: String = ""
    @TaskLocal static var key: String = ""
    @TaskLocal static var book: LegadoJS.BookCtx? = nil
    @TaskLocal static var chapter: BookChapter?
    @TaskLocal static var library = ""
    @TaskLocal static var comment = ""
    @TaskLocal static var loginURL = ""
    @TaskLocal static var failures: RuleFailures? = nil
    @TaskLocal static var headers: [String: String] = [:]
}

func isJavaScriptRule(_ rule: String) -> Bool {
    rule.range(of: #"^@js(?::|\s|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
}

func expandScriptRuleTemplates(_ script: String, input: String, base: String, key: String, page: Int,
                               sourceURL: String, book: LegadoJS.BookCtx?) -> String {
    var expanded = script, count = 0
    while let start = expanded.range(of: "{{"), let end = expanded[start.upperBound...].range(of: "}}"), count < 100 {
        count += 1
        var expression = String(expanded[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String
        if expression.hasPrefix("@@") { expression = String(expression.dropFirst(2)) }
        if expression.hasPrefix("$") || expression.hasPrefix("@") || expression.hasPrefix("//") || expression.hasPrefix("class.") || expression.hasPrefix("id.") || expression.hasPrefix("tag.") {
            value = applyRuleFirst(input, expression, base: base)
        } else if expression == "key" { value = key }
        else if expression == "page" { value = String(page) }
        else {
            value = LegadoJS.run(expression, input: input, baseUrl: base, sourceKey: key, sourceUrl: sourceURL, book: book, page: page)
        }
        expanded.replaceSubrange(start.lowerBound..<end.upperBound, with: value)
    }
    return expanded
}

// Android's Gson also accepts bare extraction rules in @put:{bid:$.id}.
// Parse those as data; evaluating them as JavaScript would change their meaning.
func sourcePutFields(_ body: String) -> [String: String] {
    if let data = ("{" + body + "}").data(using: .utf8),
       let fields = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: String] { return fields }
    var fields: [String: String] = [:]
    var pieces: [String] = [], piece = "", quote: Character?, escaped = false, depth = 0
    for char in body {
        if let current = quote {
            piece.append(char)
            if escaped { escaped = false }
            else if char == "\\" { escaped = true }
            else if char == current { quote = nil }
        } else if char == "\"" || char == "'" { quote = char; piece.append(char) }
        else if char == "[" || char == "(" { depth += 1; piece.append(char) }
        else if char == "]" || char == ")" { depth -= 1; piece.append(char) }
        else if char == "," && depth == 0 { pieces.append(piece); piece = "" }
        else { piece.append(char) }
    }
    pieces.append(piece)
    for pair in pieces {
        guard let colon = pair.firstIndex(of: ":") else { continue }
        func unquote(_ text: String) -> String {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, let first = value.first, (first == "\"" || first == "'"), value.last == first { return String(value.dropFirst().dropLast()) }
            return value
        }
        let key = unquote(String(pair[..<colon]))
        if !key.isEmpty { fields[key] = unquote(String(pair[pair.index(after: colon)...])) }
    }
    return fields
}

// MARK: - Legado rule engine (subset, CSS/XPath/JSON/regex + JS via JavaScriptCore)
// Research basis (see report): gedoor/legado BookSource fields
// bookSourceName/bookSourceUrl/bookSourceType/searchUrl/exploreUrl/
// ruleSearch/ruleBookInfo/ruleToc/ruleContent/ruleExplore, and rule syntax
// from Legado's ruleHelp/AnalyzeRule mirrors: Default (class./tag./id.),
// @css:, @json:/$., :regex, ##replace, && join, || first-non-empty,
// indices .0/.1/.-1, chained @text/@href/@src/@html/@textNodes and
// @attr(...). @js:/<js> 规则由 LegadoJSEngine.swift（JavaScriptCore）执行；
// @xpath:// 使用 libxml2 DOM 解析。

struct HtmlEl {
    var open: String
    var inner: String
    var full: String
}

struct Sel {
    var tag: String? = nil
    var classes: [String] = []
    var idVal: String? = nil
    var attrName: String? = nil
    var attrOp: String? = nil
    var attrVal: String? = nil
    var index: Int? = nil
    // :nth-of-type(an+b) / :nth-child(an+b), stored as (a, b); a=0 means exact b.
    var nthA: Int? = nil
    var nthB: Int? = nil
    var nthLast: Bool = false
    // Legado "p!-1" suffix: drop the element at that index (-1 = last).
    var excludeIndex: Int? = nil
}

func parseNth(_ expr: String) -> (Int, Int)? {
    let e = expr.trimmingCharacters(in: .whitespaces).lowercased()
    if e == "odd" { return (2, 1) }
    if e == "even" { return (2, 0) }
    if let n = Int(e) { return (0, n) }
    // Forms: n, n+2, -n+3, 2n+1, 2n-1
    var s = e
    var a = 1
    if s.hasPrefix("-n") { a = -1; s = String(s.dropFirst(2)) }
    else if s.hasPrefix("n") { s = String(s.dropFirst()) }
    else if let r = s.range(of: "n") {
        a = Int(String(s[..<r.lowerBound])) ?? 1
        s = String(s[r.upperBound...])
    } else { return nil }
    if s.isEmpty { return (a, 0) }
    if let b = Int(s) { return (a, b) }
    return nil
}

func filterNth(_ els: [HtmlEl], sel: Sel) -> [HtmlEl] {
    var out = els
    if let a = sel.nthA, let b = sel.nthB {
        out = out.enumerated().filter { (i, _) in
            let pos = sel.nthLast ? (out.count - i) : (i + 1)
            if a == 0 { return pos == b }
            if a > 0 { return pos >= b && (pos - b) % a == 0 }
            return pos <= b && (b - pos) % (-a) == 0
        }.map { $0.element }
    }
    if let ex = sel.excludeIndex {
        let idx = ex >= 0 ? ex : out.count + ex
        if idx >= 0 && idx < out.count { out.remove(at: idx) }
    }
    return out
}

func htmlAttrs(_ open: String) -> [String: String] {
    var out: [String: String] = [:]
    guard let re = try? NSRegularExpression(pattern: "([A-Za-z_\\-:]+)\\s*=\\s*\"([^\"]*)\"|([A-Za-z_\\-:]+)\\s*=\\s*'([^']*)'", options: [.caseInsensitive]) else { return out }
    let ns = open as NSString
    for m in re.matches(in: open, range: NSRange(location: 0, length: ns.length)) {
        if m.range(at: 1).location != NSNotFound {
            out[ns.substring(with: m.range(at: 1)).lowercased()] = ns.substring(with: m.range(at: 2))
        } else if m.range(at: 3).location != NSNotFound {
            out[ns.substring(with: m.range(at: 3)).lowercased()] = ns.substring(with: m.range(at: 4))
        }
    }
    return out
}

func classTokens(_ open: String) -> [String] {
    guard let c = htmlAttrs(open)["class"] else { return [] }
    return c.split(separator: " ").map(String.init)
}

func tagNameOfOpen(_ open: String) -> String {
    guard let re = try? NSRegularExpression(pattern: "<\\s*([A-Za-z][A-Za-z0-9]*)"),
          let m = re.firstMatch(in: open, range: NSRange(open.startIndex..., in: open)) else { return "" }
    return (open as NSString).substring(with: m.range(at: 1))
}

func attrMatches(_ value: String, op: String, val: String) -> Bool {
    switch op {
    case "=": return value == val
    case "$=": return value.hasSuffix(val)
    case "^=": return value.hasPrefix(val)
    case "*=": return value.contains(val)
    case "~=": return value.split(separator: " ").map(String.init).contains(val)
    case "|=": return value == val || value.hasPrefix(val + "-")
    default: return !value.isEmpty
    }
}

// 平衡匹配 <tag>...</tag>：正确处理同名标签嵌套。
// 用栈记录每个开标签位置，遇到闭标签就弹出最近的未闭合开标签，取两者之间的内容。
func findBalanced(_ html: String, tag: String) -> [HtmlEl] {
    let ns = html as NSString
    let t = NSRegularExpression.escapedPattern(for: tag)
    guard let openRe = try? NSRegularExpression(pattern: "<\(t)\\b([^>]*)>", options: [.caseInsensitive]),
          let closeRe = try? NSRegularExpression(pattern: "</\(t)\\s*>", options: [.caseInsensitive]) else { return [] }

    // (位置, 是否开标签, 属性串, 长度)
    var marks: [(loc: Int, isOpen: Bool, attrs: String, len: Int)] = []
    for m in openRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
        marks.append((m.range.location, true, ns.substring(with: m.range(at: 1)), m.range.length))
    }
    for m in closeRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
        marks.append((m.range.location, false, "", m.range.length))
    }
    marks.sort { $0.loc < $1.loc }

    var out: [HtmlEl] = []
    var stack: [(loc: Int, attrs: String, len: Int)] = []
    for m in marks {
        if m.isOpen {
            stack.append((m.loc, m.attrs, m.len))
        } else if let open = stack.popLast() {
            let openEnd = open.loc + open.len
            if m.loc < openEnd { continue }
            let inner = ns.substring(with: NSRange(location: openEnd, length: m.loc - openEnd))
            let full = ns.substring(with: NSRange(location: open.loc, length: m.loc + m.len - open.loc))
            out.append(HtmlEl(open: "<\(tag) \(open.attrs)>", inner: inner, full: full))
        }
    }
    return out
}

// 通用平衡匹配：匹配所有标签（正确配对嵌套），返回 (标签名, open, inner, full)。
// 供无显式标签名的选择器（class./id./[attr]）使用，避免同名嵌套截断。
struct AnyHtmlEl {
    var open: String
    var inner: String
    var full: String
}

func findBalancedAny(_ html: String) -> [AnyHtmlEl] {
    let ns = html as NSString
    guard let openRe = try? NSRegularExpression(pattern: "<([A-Za-z][A-Za-z0-9]*)\\b([^>]*)>", options: [.caseInsensitive]),
          let closeRe = try? NSRegularExpression(pattern: "</([A-Za-z][A-Za-z0-9]*)\\s*>", options: [.caseInsensitive]) else { return [] }

    // (位置, 是否开标签, 标签名小写, 属性串, 长度)
    var marks: [(loc: Int, isOpen: Bool, tag: String, attrs: String, len: Int)] = []
    for m in openRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
        marks.append((m.range.location, true, ns.substring(with: m.range(at: 1)).lowercased(), ns.substring(with: m.range(at: 2)), m.range.length))
    }
    for m in closeRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
        marks.append((m.range.location, false, ns.substring(with: m.range(at: 1)).lowercased(), "", m.range.length))
    }
    marks.sort { $0.loc < $1.loc }

    var out: [AnyHtmlEl] = []
    var stack: [(loc: Int, tag: String, attrs: String, len: Int)] = []
    for m in marks {
        if m.isOpen {
            stack.append((m.loc, m.tag, m.attrs, m.len))
        } else {
            // 容错配对：从栈尾往前找最近同名未闭合开标签（不严格嵌套也能配）
            var idx = -1
            for i in stride(from: stack.count - 1, through: 0, by: -1) where stack[i].tag == m.tag { idx = i; break }
            guard idx >= 0 else { continue }
            let open = stack.remove(at: idx)
            let openEnd = open.loc + open.len
            if m.loc < openEnd { continue }
            let inner = ns.substring(with: NSRange(location: openEnd, length: m.loc - openEnd))
            let full = ns.substring(with: NSRange(location: open.loc, length: m.loc + m.len - open.loc))
            out.append(AnyHtmlEl(open: "<\(open.tag) \(open.attrs)>", inner: inner, full: full))
        }
    }
    return out
}

func findElements(_ html: String, tag: String?, classes: [String], idVal: String?, attrName: String?, attrOp: String?, attrVal: String?) -> [HtmlEl] {
    var out: [HtmlEl] = []
    let ns = html as NSString
    let voidTags: Set<String> = ["img", "input", "br", "hr", "link", "meta", "source", "area", "base", "col", "embed", "track", "wbr"]
    // Paired elements: use a balanced (stack-based) matcher so nested
    // same-name tags are handled correctly. The old non-greedy regex
    // "<div\b([^>]*)>(.*?)</div>" stopped at the FIRST nested "</div>", so a
    // bookList like "div.c_row" (whose rows contain a cover <div> and a text
    // <div>) lost everything after the cover — name/author matched nothing and
    // search/discovery came back empty. This is why e.g. 穿越小说 (kk169.la)
    // returned no results while 文桑小说 (dl, no nesting) worked.
    if let tag = tag {
        for el in findBalanced(html, tag: tag) {
            if !classes.allSatisfy({ classTokens(el.open).contains($0) }) { continue }
            if let idv = idVal, htmlAttrs(el.open)["id"] != idv { continue }
            if let an = attrName {
                let v = htmlAttrs(el.open)[an.lowercased()] ?? ""
                if !attrMatches(v, op: attrOp ?? "=", val: attrVal ?? "") { continue }
            }
            out.append(el)
        }
        // Void elements (img etc.) have no closing tag
        if voidTags.contains(tag.lowercased()) {
            let pat2 = "<\(NSRegularExpression.escapedPattern(for: tag))\\b([^>]*)/?>"
            if let re2 = try? NSRegularExpression(pattern: pat2, options: [.caseInsensitive]) {
                for m in re2.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                    let full = ns.substring(with: m.range)
                    let open = full
                    if !classes.allSatisfy({ classTokens(open).contains($0) }) { continue }
                    if let idv = idVal, htmlAttrs(open)["id"] != idv { continue }
                    if let an = attrName {
                        let v = htmlAttrs(open)[an.lowercased()] ?? ""
                        if !attrMatches(v, op: attrOp ?? "=", val: attrVal ?? "") { continue }
                    }
                    // Avoid duplicating a paired match (void tags never pair, so safe)
                    out.append(HtmlEl(open: open, inner: "", full: full))
                }
            }
        }
    } else {
        // Any tag (id-only / class-only / attr-only selectors): balanced matcher,
        // same fix as the paired-tag case so nested same-name tags don't truncate.
        for el in findBalancedAny(html) {
            if !classes.allSatisfy({ classTokens(el.open).contains($0) }) { continue }
            if let idv = idVal, htmlAttrs(el.open)["id"] != idv { continue }
            if let an = attrName {
                let v = htmlAttrs(el.open)[an.lowercased()] ?? ""
                if !attrMatches(v, op: attrOp ?? "=", val: attrVal ?? "") { continue }
            }
            out.append(HtmlEl(open: el.open, inner: el.inner, full: el.full))
        }
    }
    return out
}

func parseAttrSelector(_ inside: String) -> (name: String, op: String, val: String) {
    let ops = ["$=", "*=", "^=", "~=", "|=", "="]
    for op in ops {
        if let r = inside.range(of: op) {
            let name = String(inside[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            var val = String(inside[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return (name, op, val)
        }
    }
    return (inside.trimmingCharacters(in: .whitespaces), "=", "")
}

func parseSelectorToken(_ token: String) -> Sel {
    var t = token.trimmingCharacters(in: .whitespaces)
    // Legado "p!-1" / "p!0": drop one element after matching.
    var excludeIndex: Int? = nil
    if let bang = t.firstIndex(of: "!") {
        let after = String(t[t.index(after: bang)...])
        if let v = Int(after) { excludeIndex = v; t = String(t[..<bang]) }
    }
    // Pseudo-classes: :nth-of-type(n+2), :nth-child(1), :first-child, :last-child
    var nthA: Int? = nil; var nthB: Int? = nil; var nthLast = false
    if let colon = t.range(of: ":nth-of-type(", options: .backwards) ?? t.range(of: ":nth-child(", options: .backwards) {
        let after = t[colon.upperBound...]
        if let close = after.firstIndex(of: ")"), let nth = parseNth(String(after[..<close])) {
            nthA = nth.0; nthB = nth.1; t = String(t[..<colon.lowerBound])
        }
    } else if t.hasSuffix(":first-child") { nthA = 0; nthB = 1; t = String(t.dropLast(":first-child".count)) }
    else if t.hasSuffix(":last-child") { nthA = 0; nthB = 1; nthLast = true; t = String(t.dropLast(":last-child".count)) }
    else if t.hasSuffix(":first-of-type") { nthA = 0; nthB = 1; t = String(t.dropLast(":first-of-type".count)) }
    else if t.hasSuffix(":last-of-type") { nthA = 0; nthB = 1; nthLast = true; t = String(t.dropLast(":last-of-type".count)) }
    var index: Int? = nil
    // Trailing .<int> / .-<int> index, e.g. p.2, class.book_other.0, ul.1
    var parts = t.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    if parts.count >= 2, let last = parts.last, let v = Int(last) {
        // Only treat as index when there is a real selector before it
        index = v; parts.removeLast(); t = parts.joined(separator: ".")
    }
    if t.hasPrefix("class.") {
        let rest = String(t.dropFirst(6))
        return Sel(tag: nil, classes: rest.split(separator: " ").map(String.init), index: index, nthA: nthA, nthB: nthB, nthLast: nthLast, excludeIndex: excludeIndex)
    }
    if t.hasPrefix("tag.") {
        return Sel(tag: String(t.dropFirst(4)), index: index, nthA: nthA, nthB: nthB, nthLast: nthLast, excludeIndex: excludeIndex)
    }
    if t.hasPrefix("id.") {
        return Sel(idVal: String(t.dropFirst(3)), index: index, nthA: nthA, nthB: nthB, nthLast: nthLast, excludeIndex: excludeIndex)
    }
    if t.hasPrefix(".") {
        return Sel(classes: [String(t.dropFirst())], index: index, nthA: nthA, nthB: nthB, nthLast: nthLast, excludeIndex: excludeIndex)
    }
    if t.hasPrefix("[") && t.hasSuffix("]") {
        let inner = String(t.dropFirst().dropLast())
        let a = parseAttrSelector(inner)
        return Sel(attrName: a.name, attrOp: a.op, attrVal: a.val, index: index, nthA: nthA, nthB: nthB, nthLast: nthLast, excludeIndex: excludeIndex)
    }
    // tag, tag.class, tag#id, tag[attr], tag.class[attr]
    var attrName: String? = nil; var attrOp: String? = nil; var attrVal: String? = nil
    var base = t
    if let b = t.firstIndex(of: "[") {
        base = String(t[..<b])
        let attrPart = String(t[b...])
        if attrPart.hasPrefix("[") && attrPart.hasSuffix("]") {
            let a = parseAttrSelector(String(attrPart.dropFirst().dropLast()))
            attrName = a.name; attrOp = a.op; attrVal = a.val
        }
    }
    var tag: String? = nil; var classes: [String] = []; var idVal: String? = nil
    let dotParts = base.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    if let first = dotParts.first, !first.isEmpty {
        if let hash = first.firstIndex(of: "#") {
            let tg = String(first[..<hash])
            tag = tg.isEmpty ? nil : tg
            idVal = String(first[first.index(after: hash)...])
        } else {
            tag = first
        }
        classes = Array(dotParts.dropFirst())
    }
    return Sel(tag: tag, classes: classes, idVal: idVal, attrName: attrName, attrOp: attrOp, attrVal: attrVal, index: index, nthA: nthA, nthB: nthB, nthLast: nthLast, excludeIndex: excludeIndex)
}

func findElementsSel(_ html: String, _ sel: Sel, token: String? = nil) -> [HtmlEl] {
    var css = sel.tag ?? "*"
    for name in sel.classes { css += "." + name }
    if let id = sel.idVal { css += "#" + id }
    if let attribute = sel.attrName {
        css += "[" + attribute
        if let op = sel.attrOp, let value = sel.attrVal { css += op + "\"" + value + "\"" }
        css += "]"
    }
    if let a = sel.nthA, let b = sel.nthB {
        css += ":" + (sel.nthLast ? "nth-last-child" : "nth-child") + "(\(a)n\(b < 0 ? "" : "+")\(b))"
    }
    if var raw = token, !raw.hasPrefix("class."), !raw.hasPrefix("tag."), !raw.hasPrefix("id.") {
        if let bang = raw.lastIndex(of: "!"), Int(raw[raw.index(after: bang)...]) != nil { raw = String(raw[..<bang]) }
        if let dot = raw.lastIndex(of: "."), Int(raw[raw.index(after: dot)...]) != nil { raw = String(raw[..<dot]) }
        css = raw
    }
    var elements = LegadoDOM.css(html, css)
    if let excluded = sel.excludeIndex {
        let index = excluded < 0 ? elements.count + excluded : excluded
        if elements.indices.contains(index) { elements.remove(at: index) }
    }
    return elements
}

func cssElements(_ html: String, _ selector: String) -> [HtmlEl] {
    LegadoDOM.css(html, selector)
}

func pickIndex(_ els: [HtmlEl], _ idx: Int) -> [HtmlEl] {
    if els.isEmpty { return [] }
    let i = idx >= 0 ? idx : els.count + idx
    guard i >= 0 && i < els.count else { return [] }
    return [els[i]]
}

func matchesSelf(_ el: HtmlEl, parsed: Sel) -> Bool {
    if el.open.isEmpty { return false }
    if let tag = parsed.tag, tagNameOfOpen(el.open).lowercased() != tag.lowercased() { return false }
    if !parsed.classes.allSatisfy({ classTokens(el.open).contains($0) }) { return false }
    if let idv = parsed.idVal, htmlAttrs(el.open)["id"] != idv { return false }
    if let an = parsed.attrName {
        let v = htmlAttrs(el.open)[an.lowercased()] ?? ""
        if !attrMatches(v, op: parsed.attrOp ?? "=", val: parsed.attrVal ?? "") { return false }
    }
    return true
}

func stripText(_ html: String, preserveNewlines: Bool) -> String {
    let s = stripHTML(html)
    if preserveNewlines {
        return s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
}

func extractFromElement(_ el: HtmlEl, _ ext: String) -> String {
    switch ext {
    case "text": return stripText(el.inner, preserveNewlines: false)
    case "textNodes": return LegadoDOM.ownText(el.full)
    case "html": return el.inner
    case "ownText": return LegadoDOM.ownText(el.full).replacingOccurrences(of: "\n", with: " ")
    case "all": return el.full
    case "allText": return stripText(el.inner, preserveNewlines: false)
    default:
        if !el.open.isEmpty {
            return htmlAttrs(el.open)[ext.lowercased()] ?? ""
        }
        // Pseudo element: first occurrence of attr="..." in the fragment
        if let re = try? NSRegularExpression(pattern: "\(NSRegularExpression.escapedPattern(for: ext))\\s*=\\s*\"([^\"]*)\"|\(NSRegularExpression.escapedPattern(for: ext))\\s*=\\s*'([^']*)'"),
           let m = re.firstMatch(in: el.full, range: NSRange(el.full.startIndex..., in: el.full)) {
            let ns = el.full as NSString
            if m.range(at: 1).location != NSNotFound { return ns.substring(with: m.range(at: 1)) }
            if m.range(at: 2).location != NSNotFound { return ns.substring(with: m.range(at: 2)) }
        }
        return ""
    }
}

func evalDefaultChain(_ input: String, _ chain: String) -> [String] {
    var chain = chain
    // {{@@inner}} template substitution (Legado intro templates)
    while let s = chain.range(of: "{{@@"), let e = chain[s.upperBound...].range(of: "}}") {
        let inner = String(chain[s.upperBound..<e.lowerBound])
        let val = applyRuleFirst(input, inner, base: "")
        chain.replaceSubrange(s.lowerBound..<e.upperBound, with: val)
    }
    // {{js}} -> empty (unsupported)
    while let s = chain.range(of: "{{"), let e = chain[s.upperBound...].range(of: "}}") {
        chain.replaceSubrange(s.lowerBound..<e.upperBound, with: "")
    }
    let rawTokens = chain.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
    var tokens = rawTokens.filter { !$0.isEmpty }
    if tokens.isEmpty { return [] }
    // Extractor is the last token when it is a known extractor
    var extractor: String? = nil
    var selectorTokens = tokens
    if let last = tokens.last {
        if ["text", "textNodes", "html", "ownText", "all", "allText"].contains(last) {
            extractor = last; selectorTokens = Array(tokens.dropLast())
        } else if last.hasPrefix("attr(") && last.hasSuffix(")") {
            extractor = String(last.dropFirst(5).dropLast()); selectorTokens = Array(tokens.dropLast())
        } else if ["href", "src", "content", "id", "class", "name", "onclick", "style", "target", "srcset", "title", "alt", "value"].contains(last) || last.hasPrefix("data-") {
            extractor = last; selectorTokens = Array(tokens.dropLast())
        }
    }
    if selectorTokens.isEmpty {
        // Pure extractor on the input itself, e.g. "text" or "href" for a chapter <a> block
        let pseudo = HtmlEl(open: "", inner: input, full: input)
        if let ext = extractor {
            // For href/src on a fragment, try its first tag
            if let re = try? NSRegularExpression(pattern: "<[A-Za-z][A-Za-z0-9]*\\b[^>]*>", options: .caseInsensitive),
               let m = re.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) {
                let tag = (input as NSString).substring(with: m.range)
                let el = HtmlEl(open: tag, inner: input, full: input)
                let v = extractFromElement(el, ext)
                if !v.isEmpty { return [v] }
            }
            let v = extractFromElement(pseudo, ext)
            return v.isEmpty ? [] : [v]
        }
        return [input]
    }
    var els: [HtmlEl] = [HtmlEl(open: "", inner: input, full: input)]
    var prevWasSelector = false
    for token in selectorTokens {
        if let idx = Int(token) {
            els = pickIndex(els, idx); prevWasSelector = false; continue
        }
        let parsed = parseSelectorToken(token)
        if token.hasPrefix("text.") {
            let needle = String(token.dropFirst(5))
            var found: [HtmlEl] = []
            for el in els {
                let searchIn = el.open.isEmpty ? el.full : el.inner
                let all = findElements(searchIn, tag: nil, classes: [], idVal: nil, attrName: nil, attrOp: nil, attrVal: nil)
                found.append(contentsOf: all.filter { stripText($0.inner, preserveNewlines: false).contains(needle) })
            }
            els = found
            if let idx = parsed.index { els = pickIndex(els, idx) }
            prevWasSelector = true
            continue
        }
        var found: [HtmlEl] = []
        // CSS-style segment with spaces/child combinators, e.g. "#info p:nth-of-type(1) a"
        // or ".s2 a": the old single-token parser treated the whole string as one
        // tag and matched nothing, which broke most yckceo/1325 rules.
        if (token.contains(" ") || token.contains(">") || token.contains("+") || token.contains("~")) && !token.hasPrefix("class.") {
            for el in els {
                let searchIn = el.open.isEmpty ? el.full : el.inner
                found.append(contentsOf: findElementsSel(searchIn, parsed, token: token))
                if !el.open.isEmpty && matchesSelf(el, parsed: parsed) {
                    // A segment that matches the element itself (rare) is kept too.
                }
            }
        } else {
            for el in els {

                let searchIn = el.open.isEmpty ? el.full : el.inner
                found.append(contentsOf: findElementsSel(searchIn, parsed, token: token))
            }
        }
        els = found
        if let idx = parsed.index { els = pickIndex(els, idx) }
        prevWasSelector = true
        if els.isEmpty { break }
    }
    if let ext = extractor {
        return els.map { extractFromElement($0, ext) }.filter { !$0.isEmpty }
    }
    return els.map { $0.full }
}

func splitCssSelector(_ selector: String) -> [String] {
    // Split on ">" and spaces outside [...] brackets
    var out: [String] = []; var cur = ""; var depth = 0
    for ch in selector {
        if ch == "[" { depth += 1 }
        if ch == "]" { depth = max(0, depth - 1) }
        if depth == 0 && (ch == ">" || ch == " ") {
            let t = cur.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(t) }
            cur = ""
        } else {
            cur.append(ch)
        }
    }
    let t = cur.trimmingCharacters(in: .whitespaces)
    if !t.isEmpty { out.append(t) }
    return out
}

func evalCss(_ html: String, _ selectorAndAttr: String) -> [String] {
    var parts = selectorAndAttr.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
    var extractor: String? = nil
    if parts.count > 1, let last = parts.last,
       last.range(of: #"^[A-Za-z_][A-Za-z0-9_:.-]*$"#, options: .regularExpression) != nil || last.hasPrefix("attr(") {
        extractor = last; parts.removeLast()
    }
    let selector = parts.joined(separator: "@")
    let els = cssElements(html, selector)
    if let ext = extractor {
        if ext.hasPrefix("attr(") && ext.hasSuffix(")") {
            let name = String(ext.dropFirst(5).dropLast()).lowercased()
            return els.map { htmlAttrs($0.open)[name] ?? "" }.filter { !$0.isEmpty }
        }
        return els.map { extractFromElement($0, ext) }.filter { !$0.isEmpty }
    }
    return els.map { $0.full }
}

func cssExtractAll(_ html: String, _ selector: String) -> [String] {
    // Back-compat for old callers: selector may already contain @attr
    return evalCss(html, selector)
}

func cssFirst(_ html: String, _ selector: String) -> String {
    cssExtractAll(html, selector).first ?? ""
}

// MARK: - JSON

func jsonPathTokens(_ path: String) -> [String] {
    var p = path.trimmingCharacters(in: .whitespaces)
    if p.lowercased().hasPrefix("@json:") { p = String(p.dropFirst(6)) }
    p = p.replacingOccurrences(of: "..", with: ".**.")
    if p.hasPrefix("$.") { p = String(p.dropFirst(2)) }
    else if p == "$" { return [] }
    else if p.hasPrefix("$") { p = String(p.dropFirst()) }
    // Split on '.' outside brackets
    var out: [String] = []; var cur = ""; var depth = 0
    for ch in p {
        if ch == "[" { depth += 1 }
        if ch == "]" { depth = max(0, depth - 1) }
        if ch == "." && depth == 0 {
            if !cur.isEmpty { out.append(cur) }
            cur = ""
        } else { cur.append(ch) }
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}

func jsonWalk(_ root: Any, _ path: String) -> [Any] {
    let tokens = jsonPathTokens(path)
    if tokens.isEmpty { return [root] }
    var current: [Any] = [root]
    for tok in tokens {
        if tok == "**" {
            func descendants(_ value: Any) -> [Any] {
                if let dictionary = value as? [String: Any] { return [value] + dictionary.values.flatMap(descendants) }
                if let array = value as? [Any] { return [value] + array.flatMap(descendants) }
                return [value]
            }
            current = current.flatMap(descendants).filter { !($0 is [Any]) }
            continue
        }
        var next: [Any] = []
        // tok may be "key", "key[*]", "key[0]", "key[-1]", "[*]", "[0]"
        var key: String? = nil; var bracket: String? = nil
        if let b = tok.firstIndex(of: "[") {
            key = String(tok[..<b])
            bracket = String(tok[b...])
        } else if tok.hasPrefix("[") {
            bracket = tok
        } else {
            key = tok
        }
        for c in current {
            var values: [Any] = []
            if let k = key, !k.isEmpty {
                if k == "*", let d = c as? [String: Any] { values.append(contentsOf: d.values) }
                else if let d = c as? [String: Any], let v = d[k] { values.append(v) }
                else if let arr = c as? [Any] {
                    for e in arr { if let d = e as? [String: Any], let v = d[k] { values.append(v) } }
                }
            } else {
                values.append(c)
            }
            for v in values {
                if let br = bracket {
                    let inner = br.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    if inner == "*" {
                        if let arr = v as? [Any] { next.append(contentsOf: arr) }
                    } else if let idx = Int(inner) {
                        if let arr = v as? [Any] {
                            let i = idx >= 0 ? idx : arr.count + idx
                            if i >= 0 && i < arr.count { next.append(arr[i]) }
                        }
                    }
                } else {
                    next.append(v)
                }
            }
        }
        current = next
        if current.isEmpty { break }
    }
    return current
}

func jsonValueToString(_ v: Any) -> String {
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    if let b = v as? Bool { return b ? "true" : "false" }
    if JSONSerialization.isValidJSONObject(v), let data = try? JSONSerialization.data(withJSONObject: v) {
        return String(data: data, encoding: .utf8) ?? ""
    }
    return ""
}

func jsonExtract(_ jsonText: String, _ rule: String) -> [String] {
    guard let data = jsonText.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
    let vals = jsonWalk(root, rule)
    // If the walk ends at an array (path without [*]), expand it
    var flat: [Any] = []
    for v in vals {
        if let arr = v as? [Any], jsonPathTokens(rule).last?.contains("[") == false {
            // Only expand when the caller asked for a list-like path; for a
            // single field this would be wrong, so only expand if the value
            // is an array of scalars.
            if arr.allSatisfy({ $0 is String || $0 is NSNumber }) { flat.append(contentsOf: arr) } else { flat.append(v) }
        } else { flat.append(v) }
    }
    return flat.map(jsonValueToString).filter { !$0.isEmpty }
}

func jsonObjects(_ jsonText: String, _ path: String) -> [String] {
    guard let data = jsonText.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
    var vals = jsonWalk(root, path)
    // Walk may return [array] if path has no [*]
    if vals.count == 1, let arr = vals[0] as? [Any] { vals = arr }
    var out: [String] = []
    for v in vals {
        if let d = try? JSONSerialization.data(withJSONObject: v, options: []),
           let s = String(data: d, encoding: .utf8) { out.append(s) }
    }
    return out
}

// MARK: - Regex / replace

func regexExtract(_ text: String, _ pattern: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
    let ns = text as NSString
    var out: [String] = []
    for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        if m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound {
            out.append(ns.substring(with: m.range(at: 1)))
        } else {
            out.append(ns.substring(with: m.range))
        }
    }
    return out
}

func applyRegexReplace(_ text: String, pattern: String, replacement: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return re.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
}

func applyRuleReplace(_ text: String, replaceRegex: String) -> String {
    var pat = replaceRegex.trimmingCharacters(in: .whitespaces)
    if pat.hasPrefix("##") { pat = String(pat.dropFirst(2)) }
    if pat.isEmpty { return text }
    if let split = pat.range(of: "##") {
        return applyRegexReplace(text, pattern: String(pat[..<split.lowerBound]), replacement: String(pat[split.upperBound...]))
    }
    return applyRegexReplace(text, pattern: pat, replacement: "")
}

// MARK: - Dispatcher

func applyRuleNoReplace(_ input: String, _ rule: String, base: String) -> [String] {
    if rule.isEmpty { return [] }
    if rule == "@baseUrl" { return [base] }
    // Templates may contain JavaScript operators; expand them before splitting
    // the surrounding rule at || or &&.
    if rule.contains("{{") {
        var out = rule
        var count = 0
        while let start = out.range(of: "{{"), let end = out[start.upperBound...].range(of: "}}"), count < 100 {
            count += 1
            var expression = String(out[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value: String
            if expression.hasPrefix("@@") { expression = String(expression.dropFirst(2)) }
            if expression.hasPrefix("$") || expression.hasPrefix("@") || expression.contains("@text") || expression.contains("@href") || expression.hasPrefix("class.") || expression.hasPrefix("id.") || expression.hasPrefix("tag.") {
                value = applyRuleFirst(input, expression, base: base)
            } else {
                value = LegadoJS.run(expression, input: input, baseUrl: base, sourceKey: LegadoJSCtx.key,
                                     sourceUrl: LegadoJSCtx.sourceUrl, book: LegadoJSCtx.book)
            }
            out.replaceSubrange(start.lowerBound..<end.upperBound, with: value)
        }
        return [out]
    }
    if rule.hasPrefix("http://") || rule.hasPrefix("https://") || rule.hasPrefix("/") && !rule.hasPrefix("//") { return [rule] }
    if rule.contains("&&") {
        var out: [String] = []
        for part in rule.components(separatedBy: "&&") {
            out.append(contentsOf: applyRuleNoReplace(input, part, base: base))
        }
        return out
    }
    if rule.contains("||") {
        for part in rule.components(separatedBy: "||") {
            let v = applyRuleNoReplace(input, part, base: base)
            if !v.filter({ !$0.isEmpty }).isEmpty { return v }
        }
        return []
    }
    if rule.lowercased().hasPrefix("@xpath:") { return LegadoDOM.xpath(input, String(rule.dropFirst(7))) }
    if rule.hasPrefix("//") || rule.hasPrefix("./") { return LegadoDOM.xpath(input, rule) }
    if rule.hasPrefix("@css:") { return evalCss(input, String(rule.dropFirst(5))) }
    if rule.lowercased().hasPrefix("@json:") { return jsonExtract(input, rule) }
    if rule.hasPrefix("$") { return jsonExtract(input, rule) }
    if rule.hasPrefix(":") { return regexExtract(input, String(rule.dropFirst())) }
    if rule.hasPrefix("@@") { return evalDefaultChain(input, String(rule.dropFirst(2))) }
    let trimmedInput = input.trimmingCharacters(in: .whitespaces)
    if trimmedInput.hasPrefix("{") || trimmedInput.hasPrefix("[") {
        return jsonExtract(input, rule)
    }
    return evalDefaultChain(input, rule)
}

// 内嵌 <js>code</js> 块：前缀规则先求值，结果作为 JS 的 result，返回值拼接。
func evalJsEmbedded(_ input: String, _ rule: String, base: String) -> [String] {
    var out: [String] = []
    var rest = rule
    var current: [String] = [input]
    while let open = rest.range(of: "<js>") {
        let prefix = String(rest[..<open.lowerBound])
        guard let close = rest[open.upperBound...].range(of: "</js>") else { break }
        let jsCode = String(rest[open.upperBound..<close.lowerBound])
        rest = String(rest[close.upperBound...])
        var vals: [String]
        if prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            vals = current
        } else {
            vals = []
            for ci in current { vals.append(contentsOf: applyRule(ci, prefix, base: base)) }
        }
        var jsOut: [String] = []
        let elements = !vals.isEmpty && vals.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") }
        let structured: Any? = !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && elements ? vals : nil
        for v in structured == nil ? vals : [input] {
            let jr = LegadoJS.run(jsCode, input: v, baseUrl: base,
                                  sourceKey: LegadoJSCtx.key, sourceUrl: LegadoJSCtx.sourceUrl,
                                  book: LegadoJSCtx.book, originalContent: input, structuredResult: structured)
            if !jr.isEmpty { jsOut.append(jr) }
        }
        current = jsOut
        if rest.isEmpty { out.append(contentsOf: jsOut) }
    }
    if !rest.isEmpty {
        for ci in current { out.append(contentsOf: applyRule(ci, rest, base: base)) }
    }
    return out
}

// A replacement marker inside {{...}} belongs to that nested extraction rule.
// Splitting at it would truncate the template (e.g. 潇湘书院's kind rule).
func ruleReplacementStart(_ rule: String) -> Range<String.Index>? {
    var index = rule.startIndex, templateDepth = 0
    while index < rule.endIndex {
        let next = rule.index(after: index)
        guard next < rule.endIndex else { break }
        let end = rule.index(after: next)
        let pair = rule[index..<end]
        if pair == "{{" { templateDepth += 1; index = end }
        else if pair == "}}", templateDepth > 0 { templateDepth -= 1; index = end }
        else if pair == "##", templateDepth == 0 { return index..<end }
        else { index = next }
    }
    return nil
}

func applyRule(_ htmlOrJson: String, _ rule: String, base: String) -> [String] {
    var r = rule.trimmingCharacters(in: .whitespacesAndNewlines)
    if r.isEmpty { return [] }
    if !isJavaScriptRule(r), !r.contains("<js>") {
        if let start = r.range(of: "@put:{"), let end = r[start.upperBound...].firstIndex(of: "}") {
            let fields = sourcePutFields(String(r[start.upperBound..<end]))
            for (key, valueRule) in fields { LegadoJS.putVariable(key, applyRuleFirst(htmlOrJson, valueRule, base: base)) }
            r.removeSubrange(start.lowerBound...end)
            if r.isEmpty { return [htmlOrJson] }
        }
        while let start = r.range(of: "@get:{"), let end = r[start.upperBound...].firstIndex(of: "}") {
            r.replaceSubrange(start.lowerBound...end, with: LegadoJS.variable(String(r[start.upperBound..<end])))
        }
    }
    // 1) 整段 JS 规则：@js:code
    if isJavaScriptRule(r) {
        var js = String(r.dropFirst(3)); if js.hasPrefix(":") { js.removeFirst() }
        let out = LegadoJS.run(js, input: htmlOrJson, baseUrl: base,
                               sourceKey: LegadoJSCtx.key, sourceUrl: LegadoJSCtx.sourceUrl,
                               book: LegadoJSCtx.book)
        return out.isEmpty ? [] : [out]
    }
    // 2) 内嵌 <js>...</js> 块
    if r.contains("<js>") {
        return evalJsEmbedded(htmlOrJson, r, base: base)
    }
    // 3) 尾部 @js: 转换链（先执行选择器，再对结果跑 JS）
    if let jsRange = r.range(of: "@js:") {
        let prefix = String(r[..<jsRange.lowerBound])
        let jsCode = String(r[jsRange.upperBound...])
        let vals = applyRule(htmlOrJson, prefix, base: base)
        var out: [String] = []
        for v in vals {
            let jr = LegadoJS.run(jsCode, input: v, baseUrl: base,
                                  sourceKey: LegadoJSCtx.key, sourceUrl: LegadoJSCtx.sourceUrl,
                                  book: LegadoJSCtx.book, originalContent: htmlOrJson)
            if !jr.isEmpty { out.append(jr) }
        }
        return out
    }
    if let jsRange2 = r.range(of: "@JS:") {
        let prefix = String(r[..<jsRange2.lowerBound])
        let jsCode = String(r[jsRange2.upperBound...])
        let vals = applyRule(htmlOrJson, prefix, base: base)
        var out: [String] = []
        for v in vals {
            let jr = LegadoJS.run(jsCode, input: v, baseUrl: base,
                                  sourceKey: LegadoJSCtx.key, sourceUrl: LegadoJSCtx.sourceUrl,
                                  book: LegadoJSCtx.book, originalContent: htmlOrJson)
            if !jr.isEmpty { out.append(jr) }
        }
        return out
    }
    // Templates also occur in the replacement pattern itself. Expand the
    // complete non-JS rule before separating its outer replacement fields.
    let templated = r.contains("{{")
    if templated { r = applyRuleNoReplace(htmlOrJson, r, base: base).first ?? "" }
    var main = r; var replacePattern: String? = nil; var replaceWith = ""
    if let range = ruleReplacementStart(r) {
        main = String(r[..<range.lowerBound])
        let after = String(r[range.upperBound...])
        let fields = after.components(separatedBy: "##")
        replacePattern = fields.first
        replaceWith = fields.count > 1 ? fields[1] : ""
    }
    let vals = templated ? [main] : (main.isEmpty ? [htmlOrJson] : applyRuleNoReplace(htmlOrJson, main, base: base))
    if let pat = replacePattern, !pat.isEmpty {
        return vals.map { applyRegexReplace($0, pattern: pat, replacement: replaceWith) }
    }
    return vals
}

func applyRuleFirst(_ htmlOrJson: String, _ rule: String, base: String) -> String {
    let vals = applyRule(htmlOrJson, rule, base: base)
    let joined = rule.contains("&&") ? vals.joined() : (vals.first ?? "")
    // A bare selector with no @text/@html extractor returns element HTML;
    // for a single field (title/author/url) that HTML is never wanted.
    if !rule.hasSuffix("@html") && joined.contains("<") && joined.contains(">") {
        return stripText(joined, preserveNewlines: false)
    }
    return joined
}

// MARK: - Explore categories

struct ExploreCategory: Identifiable, Equatable {
    var id: String { title + "|" + url }
    var title: String
    var url: String
}

extension LegadoSource {
    func fetchExploreCategories() async throws -> [ExploreCategory] {
        try await withTimeout(30) {
            try await self.withRules {
                let categories = self.exploreCategories()
                try LegadoJSCtx.failures?.check()
                guard !categories.isEmpty else {
                    throw SourceFailure(stage: "发现分类", message: "规则未返回可用分类，请检查发现规则或使用搜索", url: self.bookSourceUrl)
                }
                return categories
            }
        }
    }

    func exploreCategories() -> [ExploreCategory] {
        LegadoJSCtx.$library.withValue(jsLib) {
            LegadoJSCtx.$comment.withValue(bookSourceComment) { exploreCategoriesImpl() }
        }
    }

    private func exploreCategoriesImpl() -> [ExploreCategory] {
        let raw = effectiveDiscoverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return [] }
        // JS exploreUrl：@js:...;JSON.stringify(s) —— 执行 JS 拿到分类 JSON 数组。
        // 之前这里直接 return []，导致 133 个 JS 分类源在发现页完全消失。
        var t = raw
        if isJavaScriptRule(t) {
            var js = String(t.dropFirst(3)); if js.hasPrefix(":") { js.removeFirst() }
            let out = LegadoJS.run(js, input: "", baseUrl: bookSourceUrl,
                                   sourceKey: bookSourceUrl, sourceUrl: bookSourceUrl,
                                   book: nil, page: 1)
            t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if t.contains("<js>") {
            let out = Self.fillSearchTemplate(t, key: "", page: 1, sourceUrl: bookSourceUrl)
            t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if t.isEmpty { return [] }
        // Legado's other exploreUrl format (used by most yckceo/1325 sources):
        // one "标题::链接" per line, separated by \n. The old code only knew
        // JSON arrays and single URLs, so it treated the whole multi-line
        // string as one URL and discovery always failed.
        if t.contains("::") {
            var out: [ExploreCategory] = []
            for line in t.replacingOccurrences(of: "&&", with: "\n").components(separatedBy: .newlines) {
                let l = line.trimmingCharacters(in: .whitespaces)
                guard let r = l.range(of: "::") else { continue }
                let title = String(l[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let url = String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty && !url.isEmpty { out.append(ExploreCategory(title: title, url: url)) }
            }
            if !out.isEmpty { return out }
        }
        if t.hasPrefix("[") {
            guard let data = t.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            var out: [ExploreCategory] = []
            for obj in arr {
                let title = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let url = (obj["url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                if !title.isEmpty && !url.isEmpty { out.append(ExploreCategory(title: title, url: url)) }
            }
            return out
        }
        // Plain URL = a single "推荐" category
        return [ExploreCategory(title: "推荐", url: t)]
    }

    func postSearchRequest(for key: String) -> (url: String, method: String, body: String)? {
        guard let comma = searchUrl.firstIndex(of: ",") else { return nil }
        let rest = String(searchUrl[comma...].dropFirst())
        guard rest.contains("{"), let data = rest.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = (obj["method"] as? String)?.uppercased(), method == "POST",
              let bodyTemplate = obj["body"] as? String else { return nil }
        // body 里同样有 {{java.encodeURI(key)}}/{{page}} 等占位符，统一走模板求值
        let body = Self.fillSearchTemplate(bodyTemplate, key: key, page: 1, sourceUrl: bookSourceUrl)
        var base = String(searchUrl[..<comma])
        if !base.hasPrefix("http") { base = resolveUrl(base, base: bookSourceUrl) }
        return (base, "POST", body)
    }

    func searchURL(for key: String, page: Int = 1) -> String {
        var u = searchUrl
        // Legado AnalyzeUrl may append ,{"method":"POST",...} - best-effort GET only
        if let comma = u.firstIndex(of: ",") {
            let rest = u[comma...]
            if rest.contains("{") { u = String(u[..<comma]) }
        }
        u = Self.fillSearchTemplate(u, key: key, page: page, sourceUrl: bookSourceUrl)
        if u.isEmpty { return "" }
        if u.hasPrefix("http") { return u }
        return resolveUrl(u, base: bookSourceUrl)
    }

    // 求值 searchUrl / POST body 里的 {{...}} 模板占位符。
    // 支持 {{key}}/{{page}}/{{page-1}}，以及 {{java.encodeURI(key)}}/{{(page-1)*10+1}}
    // 这类 JS 表达式（用 JavaScriptCore 求值，key/page 作为变量注入）。
    // 之前只替换 {{key}}/{{page}}，导致 100+ 个用 JS 构造搜索地址的源 URL 拼错、搜不到。
    static func fillSearchTemplate(_ template: String, key: String, page: Int, sourceUrl: String) -> String {
        var out = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if isJavaScriptRule(out) {
            var code = String(out.dropFirst(3)); if code.hasPrefix(":") { code.removeFirst() }
            out = LegadoJS.run(code, input: "", baseUrl: sourceUrl, sourceKey: key, sourceUrl: LegadoJSCtx.sourceUrl.isEmpty ? sourceUrl : LegadoJSCtx.sourceUrl, book: LegadoJSCtx.book, page: page, expandTemplates: false)
        } else {
            var rest = out, result = out, hasScript = false
            while let start = rest.range(of: "<js>"), let end = rest[start.upperBound...].range(of: "</js>") {
                hasScript = true
                let prefix = String(rest[..<start.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty { result = prefix.replacingOccurrences(of: "@result", with: result) }
                let code = String(rest[start.upperBound..<end.lowerBound])
                result = LegadoJS.run(code, input: result, baseUrl: sourceUrl, sourceKey: key,
                                         sourceUrl: LegadoJSCtx.sourceUrl.isEmpty ? sourceUrl : LegadoJSCtx.sourceUrl, book: LegadoJSCtx.book, page: page, expandTemplates: false)
                rest = String(rest[end.upperBound...])
            }
            if hasScript {
                let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                out = tail.isEmpty ? result : tail.replacingOccurrences(of: "@result", with: result)
            }
        }
        let encKey = key.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? key
        out = out.replacingOccurrences(of: "{{key}}", with: encKey)
        out = out.replacingOccurrences(of: "{{page}}", with: "\(page)")
        out = out.replacingOccurrences(of: "{{page-1}}", with: "\(page - 1)")
        // 剩余的 {{...}} 用 JS 求值（java.put 副作用返回空，java.encodeURI 返回编码值等）
        var guardCount = 0
        while let s = out.range(of: "{{"), let e = out[s.upperBound...].range(of: "}}"), guardCount < 20 {
            guardCount += 1
            let expr = String(out[s.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if expr.isEmpty { out.replaceSubrange(s.lowerBound..<e.upperBound, with: ""); continue }
            let val = LegadoJS.run(expr, input: "", baseUrl: sourceUrl,
                                   sourceKey: key, sourceUrl: LegadoJSCtx.sourceUrl.isEmpty ? sourceUrl : LegadoJSCtx.sourceUrl,
                                   book: LegadoJSCtx.book, page: page)
            out.replaceSubrange(s.lowerBound..<e.upperBound, with: val)
        }
        while let start = out.range(of: "@get:{"), let end = out[start.upperBound...].firstIndex(of: "}") {
            out.replaceSubrange(start.lowerBound...end, with: LegadoJS.variable(String(out[start.upperBound..<end])))
        }
        return out
    }

    // Every stage uses the source headers, redirect URL and one isolated JS context.
    func withRules<T>(key: String = "", book: SourceBook? = nil, _ operation: () async throws -> T) async throws -> T {
        let failures = RuleFailures()
        let context = book.map { LegadoJS.BookCtx(bookUrl: $0.url, name: $0.title, author: $0.author,
                                                 tocUrl: $0.tocUrl ?? "", coverUrl: $0.cover) }
        return try await SourceTLS.$allowsInvalidCertificates.withValue(SourceTLS.isAllowed(bookSourceUrl)) {
          try await LegadoJSCtx.$sourceUrl.withValue(bookSourceUrl) {
            try await LegadoJSCtx.$key.withValue(key) {
                try await LegadoJSCtx.$book.withValue(context) {
                    try await LegadoJSCtx.$library.withValue(jsLib) {
                      try await LegadoJSCtx.$comment.withValue(bookSourceComment) {
                        try await LegadoJSCtx.$loginURL.withValue(loginUrl) {
                        try await LegadoJSCtx.$failures.withValue(failures) {
                            return try await LegadoJSCtx.$headers.withValue(requestHeaders) {
                              do {
                                let result = try await operation()
                                try failures.check()
                                return result
                            } catch {
                                // A script error can otherwise be hidden by a later
                                // generic "no books"/"empty chapters" parse error.
                                try failures.check()
                                throw error
                              }
                            }
                        }
                        }
                      }
                    }
                }
            }
          }
        }
    }

    func ruleItems(_ text: String, rule: String, base: String) -> [String] {
        let values = applyRule(text, rule, base: base)
        return values.flatMap { value -> [String] in
            guard let data = value.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [value] }
            return array.compactMap { item in
                if let string = item as? String { return string }
                guard JSONSerialization.isValidJSONObject(item), let data = try? JSONSerialization.data(withJSONObject: item) else { return nil }
                return String(data: data, encoding: .utf8)
            }
        }
    }

    func parseBooks(_ response: SourcePage, rule: RuleSet, stage: String) throws -> [SourceBook] {
        guard !rule.name.isEmpty, !rule.bookUrl.isEmpty else {
            throw SourceFailure(stage: stage, message: "缺少书名或详情地址规则", url: response.url)
        }
        let blocks = rule.bookList.isEmpty ? [response.text] : ruleItems(response.text, rule: rule.bookList, base: response.url)
        var seen = Set<String>()
        let books = blocks.compactMap { block -> SourceBook? in
            let name = applyRuleFirst(block, rule.name, base: response.url)
            // Search APIs may mix recommendation/group rows with book rows.
            // Do not evaluate a book-ID script on entries with no book name.
            guard !name.isEmpty else { return nil }
            let address = resolveUrl(applyRuleFirst(block, rule.bookUrl, base: response.url), base: response.url)
            guard isSourceURL(address), seen.insert(address).inserted else { return nil }
            var book = SourceBook(title: name, url: address, sourceName: bookSourceName, sourceUrl: bookSourceUrl)
            book.author = applyRuleFirst(block, rule.author, base: response.url)
            book.cover = resolveUrl(applyRuleFirst(block, rule.coverUrl, base: response.url), base: response.url)
            book.intro = applyRuleFirst(block, rule.intro, base: response.url)
            return book
        }
        try LegadoJSCtx.failures?.check()
        return books
    }

    func search(key: String) async throws -> [SourceBook] {
        try await withRules(key: key) { try await searchImpl(key: key) }
    }
    func searchForDiscovery(key: String) async throws -> [SourceBook] { try await search(key: key) }
    private func searchImpl(key: String) async throws -> [SourceBook] {
        guard !searchUrl.isEmpty else { throw SourceFailure(stage: "搜索", message: "书源未配置搜索地址") }
        let response = try await loadPage(searchUrl, key: key, stage: "搜索")
        let books = try parseBooks(response, rule: ruleSearch, stage: "搜索")
        // The site determines its own search semantics (aliases, author, fuzzy
        // matching). Never substitute a random navigation-link fallback.
        return books
    }

    func discover(category: ExploreCategory? = nil) async throws -> [SourceBook] {
        try await withRules {
            guard let category = category ?? exploreCategories().first else {
                throw SourceFailure(stage: "发现分类", message: "没有解析到分类，请检查 exploreUrl 或脚本兼容性")
            }
            let response = try await loadPage(category.url, stage: "发现分类「\(category.title)」")
            let rule = effectiveDiscoverRule.bookList.isEmpty && effectiveDiscoverRule.name.isEmpty ? ruleSearch : effectiveDiscoverRule
            let books = try parseBooks(response, rule: rule, stage: "发现列表")
            guard !books.isEmpty else {
                throw SourceFailure(stage: "发现列表", message: "页面已返回，但书籍规则未匹配到有效书名和地址（也可能是验证码或登录页）", url: response.url)
            }
            return books
        }
    }

    func fetchBookInfo(book: SourceBook) async throws -> SourceBook {
        try await withRules(key: book.title, book: book) { try await fetchBookInfoImpl(book: book) }
    }
    private func fetchBookInfoImpl(book: SourceBook) async throws -> SourceBook {
        let response = try await loadPage(book.url, stage: "书籍详情")
        let text = ruleBookInfo.initRule.isEmpty ? response.text : applyRule(response.text, ruleBookInfo.initRule, base: response.url).joined(separator: "\n")
        var book = book
        if SourceHTTP.options(book.url).options.isEmpty { book.url = response.url }
        let fields = ruleBookInfo
        let name = applyRuleFirst(text, fields.name, base: response.url)
        let author = applyRuleFirst(text, fields.author, base: response.url)
        let cover = applyRuleFirst(text, fields.coverUrl, base: response.url)
        let intro = applyRuleFirst(text, fields.intro, base: response.url)
        if !name.isEmpty { book.title = name }
        if !author.isEmpty { book.author = author }
        if !cover.isEmpty { book.cover = resolveUrl(cover, base: response.url) }
        if !intro.isEmpty { book.intro = intro }
        if !fields.tocUrl.isEmpty {
            let toc = resolveUrl(applyRuleFirst(text, fields.tocUrl, base: response.url), base: response.url)
            try LegadoJSCtx.failures?.check()
            guard isSourceURL(toc) else { throw SourceFailure(stage: "目录入口", message: "详情页目录地址规则未匹配", url: response.url) }
            book.tocUrl = toc
        } else { book.tocUrl = SourceHTTP.options(book.url).options.isEmpty ? response.url : book.url }
        return book
    }

    func fetchChapters(book: SourceBook) async throws -> [BookChapter] {
        try await withRules(key: book.title, book: book) { try await fetchChaptersImpl(book: book) }
    }
    private func fetchChaptersImpl(book: SourceBook) async throws -> [BookChapter] {
        guard !ruleToc.chapterList.isEmpty, !ruleToc.chapterName.isEmpty, !ruleToc.chapterUrl.isEmpty else {
            throw SourceFailure(stage: "目录", message: "缺少章节列表、章节名或章节地址规则")
        }
        let detailed = book.tocUrl == nil ? try await fetchBookInfoImpl(book: book) : book
        let initial = detailed.tocUrl ?? detailed.url
        var pending = [initial]; var queued: Set<String> = [initial]; var cursor = 0
        var visited = Set<String>(); var seen = Set<String>(); var chapters: [BookChapter] = []
        var pageCount = 0
        while cursor < pending.count {
            try Task.checkCancellation()
            let next = pending[cursor]; cursor += 1
            guard !next.isEmpty, visited.insert(next).inserted else { continue }
            guard pageCount < 1000 else { throw SourceFailure(stage: "目录分页", message: "超过 1000 页保护限制，未保存不完整目录", url: next) }
            pageCount += 1
            let response = try await loadPage(next, stage: "目录第 \(pageCount) 页")
            visited.insert(response.url)
            let listRule = ruleToc.chapterList.hasPrefix("-") ? String(ruleToc.chapterList.dropFirst()) : ruleToc.chapterList
            let items = ruleItems(response.text, rule: listRule, base: response.url)
            var matched = 0
            for item in items {
                let name = applyRuleFirst(item, ruleToc.chapterName, base: response.url)
                let address = resolveUrl(applyRuleFirst(item, ruleToc.chapterUrl, base: response.url), base: response.url)
                guard !name.isEmpty, isSourceURL(address) else { continue }
                matched += 1
                if seen.insert(address).inserted {
                    var chapter = BookChapter(id: address, title: name, text: "__URL__" + address, url: address)
                    chapter.ruleBook = .init(bookUrl: detailed.url, name: detailed.title, author: detailed.author,
                                             tocUrl: detailed.tocUrl ?? detailed.url, coverUrl: detailed.cover)
                    chapter.ruleIndex = chapters.count
                    chapters.append(chapter)
                }
            }
            try LegadoJSCtx.failures?.check()
            guard matched > 0 else { throw SourceFailure(stage: "目录解析", message: "章节规则没有匹配到有效章节，未使用导航链接冒充目录", url: response.url) }
            for value in applyRule(response.text, ruleToc.nextTocUrl, base: response.url) {
                let address = resolveUrl(value, base: response.url)
                if isSourceURL(address), !visited.contains(address), queued.insert(address).inserted { pending.append(address) }
            }
        }
        if ruleToc.chapterList.hasPrefix("-") { chapters.reverse() }
        for index in chapters.indices { chapters[index].ruleIndex = index }
        return chapters
    }

    func fetchChapterContent(_ chapter: BookChapter, nextChapterUrl: String? = nil) async throws -> String {
        guard chapter.text.hasPrefix("__URL__") || (chapter.text.isEmpty && chapter.url != nil) else { return chapter.text }
        return try await withChapterRules(chapter) {
            guard !ruleContent.content.isEmpty else { throw SourceFailure(stage: "正文", message: "书源缺少正文规则") }
            var next = chapter.url ?? String(chapter.text.dropFirst(7))
            var visited = Set<String>(); var parts: [String] = []
            while !next.isEmpty {
                try Task.checkCancellation()
                guard visited.count < 100 else { throw SourceFailure(stage: "正文分页", message: "超过 100 页保护限制，未缓存不完整正文", url: next) }
                guard visited.insert(next).inserted else { break }
                let response = try await loadPage(next, stage: "正文第 \(visited.count) 页")
                let raw = applyRule(response.text, ruleContent.content, base: response.url).joined(separator: "\n")
                let part = stripText(raw, preserveNewlines: true).trimmingCharacters(in: .whitespacesAndNewlines)
                try LegadoJSCtx.failures?.check()
                guard !part.isEmpty else { throw SourceFailure(stage: "正文解析", message: "正文规则未匹配到内容，请检查规则、登录状态或验证码", url: response.url) }
                parts.append(part)
                next = resolveUrl(applyRuleFirst(response.text, ruleContent.nextContentUrl, base: response.url), base: response.url)
                if let boundary = nextChapterUrl,
                   SourceHTTP.options(next).url == SourceHTTP.options(resolveUrl(boundary, base: response.url)).url { break }
                if next == response.url { break }
            }
            var content = parts.joined(separator: "\n")
            if !ruleContent.replaceRegex.isEmpty { content = applyRuleReplace(content, replaceRegex: ruleContent.replaceRegex) }
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SourceFailure(stage: "正文替换", message: "替换规则移除了全部正文")
            }
            return content
        }
    }

    func fetchChapterImages(_ chapter: BookChapter) async throws -> [String] {
        guard chapter.text.hasPrefix("__URL__") || (chapter.text.isEmpty && chapter.url != nil) else { return chapter.imageUrls }
        return try await withChapterRules(chapter) {
            var next = chapter.url ?? String(chapter.text.dropFirst(7))
            var visited = Set<String>(); var seen = Set<String>(); var images: [String] = []
            while !next.isEmpty {
                guard visited.count < 100 else { throw SourceFailure(stage: "漫画分页", message: "超过 100 页保护限制", url: next) }
                guard visited.insert(next).inserted else { break }
                let response = try await loadPage(next, stage: "漫画正文")
                let rule = ruleContent.imageUrl.isEmpty ? ruleContent.content : ruleContent.imageUrl
                let extracted = applyRule(response.text, rule, base: response.url)
                let addresses = extracted.flatMap { value in
                    value.contains("<img") ? cssExtractAll(value, "img@src") : [value]
                }.map { resolveUrl($0, base: response.url) }.filter { isSourceURL($0) }
                guard !addresses.isEmpty else { throw SourceFailure(stage: "漫画解析", message: "图片规则未匹配，不使用页面广告图片冒充正文", url: response.url) }
                for url in addresses where seen.insert(url).inserted { images.append(url) }
                next = resolveUrl(applyRuleFirst(response.text, ruleContent.nextContentUrl, base: response.url), base: response.url)
                if next == response.url { break }
            }
            return images
        }
    }

    private func withChapterRules<T>(_ chapter: BookChapter, operation: () async throws -> T) async throws -> T {
        try await withRules {
            try await LegadoJSCtx.$book.withValue(chapter.ruleBook) {
                try await LegadoJSCtx.$chapter.withValue(chapter) { try await operation() }
            }
        }
    }
}

func isSourceURL(_ text: String) -> Bool {
    guard let url = URL(string: SourceHTTP.options(text).url) else { return false }
    return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
}

private actor SourceSearchAccumulator {
    var books: [SourceBook] = []
    func add(_ values: [SourceBook]) { books.append(contentsOf: values) }
}

func searchAllSources(_ sources: [LegadoSource], key: String) async -> [SourceBook] {
    let all = await searchAllRawSources(sources, key: key)
    var seen = Set<String>()
    return all.filter { seen.insert(dedupeKey($0)).inserted }
}

func dedupeKey(_ book: SourceBook) -> String {
    (book.title + "|" + book.author).lowercased().trimmingCharacters(in: .whitespaces)
}

func searchAllRawSources(_ sources: [LegadoSource], key: String) async -> [SourceBook] {
    let collected = SourceSearchAccumulator()
    await streamSourceSearch(sources, key: key) { result in await collected.add(result.books) }
    return await collected.books
}
