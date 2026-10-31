import Foundation

// MARK: - JS 规则执行上下文（TaskLocal，并发安全）
// 书源引擎执行 @js:/<js> 规则时需要知道当前书源的 sourceUrl、搜索词 key、书信息 book。
// 这些是"环境变量"，用 @TaskLocal 传递，避免在并发多源搜索时互相串值。
enum LegadoJSCtx {
    @TaskLocal static var sourceUrl: String = ""
    @TaskLocal static var key: String = ""
    @TaskLocal static var book: LegadoJS.BookCtx? = nil
}

// MARK: - Legado rule engine (subset, CSS/XPath/JSON/regex + JS via JavaScriptCore)
// Research basis (see report): gedoor/legado BookSource fields
// bookSourceName/bookSourceUrl/bookSourceType/searchUrl/exploreUrl/
// ruleSearch/ruleBookInfo/ruleToc/ruleContent/ruleExplore, and rule syntax
// from Legado's ruleHelp/AnalyzeRule mirrors: Default (class./tag./id.),
// @css:, @json:/$., :regex, ##replace, && join, || first-non-empty,
// indices .0/.1/.-1, chained @text/@href/@src/@html/@textNodes and
// @attr(...). @js:/<js> 规则由 LegadoJSEngine.swift（JavaScriptCore）执行；
// @xpath:// 暂不支持（返回空，不崩溃）。

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

func findElements(_ html: String, tag: String?, classes: [String], idVal: String?, attrName: String?, attrOp: String?, attrVal: String?) -> [HtmlEl] {
    var out: [HtmlEl] = []
    let ns = html as NSString
    let voidTags: Set<String> = ["img", "input", "br", "hr", "link", "meta", "source", "area", "base", "col", "embed", "track", "wbr"]
    // Paired elements
    if let tag = tag {
        let pat = "<\(NSRegularExpression.escapedPattern(for: tag))\\b([^>]*)>(.*?)</\(NSRegularExpression.escapedPattern(for: tag))>"
        if let re = try? NSRegularExpression(pattern: pat, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let full = ns.substring(with: m.range)
                let openAttrs = ns.substring(with: m.range(at: 1))
                let inner = ns.substring(with: m.range(at: 2))
                let open = "<\(tag) \(openAttrs)>"
                if !classes.allSatisfy({ classTokens(open).contains($0) }) { continue }
                if let idv = idVal, htmlAttrs(open)["id"] != idv { continue }
                if let an = attrName {
                    let v = htmlAttrs(open)[an.lowercased()] ?? ""
                    if !attrMatches(v, op: attrOp ?? "=", val: attrVal ?? "") { continue }
                }
                out.append(HtmlEl(open: open, inner: inner, full: full))
            }
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
        // Any tag
        let pat = "<([A-Za-z][A-Za-z0-9]*)\\b([^>]*)>(.*?)</\\1>"
        if let re = try? NSRegularExpression(pattern: pat, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let full = ns.substring(with: m.range)
                let tagName = ns.substring(with: m.range(at: 1))
                let openAttrs = ns.substring(with: m.range(at: 2))
                let inner = ns.substring(with: m.range(at: 3))
                let open = "<\(tagName) \(openAttrs)>"
                if !classes.allSatisfy({ classTokens(open).contains($0) }) { continue }
                if let idv = idVal, htmlAttrs(open)["id"] != idv { continue }
                if let an = attrName {
                    let v = htmlAttrs(open)[an.lowercased()] ?? ""
                    if !attrMatches(v, op: attrOp ?? "=", val: attrVal ?? "") { continue }
                }
                out.append(HtmlEl(open: open, inner: inner, full: full))
            }
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

func findElementsSel(_ html: String, _ sel: Sel) -> [HtmlEl] {
    filterNth(findElements(html, tag: sel.tag, classes: sel.classes, idVal: sel.idVal, attrName: sel.attrName, attrOp: sel.attrOp, attrVal: sel.attrVal), sel: sel)
}

func cssElements(_ html: String, _ selector: String) -> [HtmlEl] {
    var els: [HtmlEl] = [HtmlEl(open: "", inner: html, full: html)]
    for seg in splitCssSelector(selector) {
        let parsed = parseSelectorToken(seg)
        var found: [HtmlEl] = []
        for el in els {
            if !el.open.isEmpty && matchesSelf(el, parsed: parsed) { found.append(el) }
            let searchIn = el.open.isEmpty ? el.full : el.inner
            found.append(contentsOf: findElementsSel(searchIn, parsed))
        }
        els = found
        if let idx = parsed.index { els = pickIndex(els, idx) }
        if els.isEmpty { break }
    }
    return els
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
    case "textNodes": return stripText(el.inner, preserveNewlines: true)
    case "html": return el.inner
    case "ownText": return stripText(el.inner, preserveNewlines: false)
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
        } else if ["href", "src", "content", "data-src", "data-original", "data-url", "title", "alt", "value"].contains(last) {
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
        // Qualifier: class.xxx / id.xxx after a selector filters the current elements
        if (token.hasPrefix("class.") || token.hasPrefix("id.")) && prevWasSelector {
            els = els.filter { el in
                if token.hasPrefix("class.") { return parsed.classes.allSatisfy { classTokens(el.open).contains($0) } }
                return htmlAttrs(el.open)["id"] == parsed.idVal
            }
            if let idx = parsed.index { els = pickIndex(els, idx) }
            prevWasSelector = true
            continue
        }
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
        if token.contains(" ") || token.contains(">") {
            for el in els {
                let searchIn = el.open.isEmpty ? el.full : el.inner
                found.append(contentsOf: cssElements(searchIn, token))
                if !el.open.isEmpty && matchesSelf(el, parsed: parsed) {
                    // A segment that matches the element itself (rare) is kept too.
                }
            }
        } else {
            for el in els {
                if !el.open.isEmpty && matchesSelf(el, parsed: parsed) { found.append(el) }
                let searchIn = el.open.isEmpty ? el.full : el.inner
                found.append(contentsOf: findElementsSel(searchIn, parsed))
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
       ["text", "textNodes", "html", "ownText", "href", "src", "content", "data-src", "data-original"].contains(last) || last.hasPrefix("attr(") {
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
    if p.hasPrefix("@json:") { p = String(p.dropFirst(6)) }
    else if p.hasPrefix("@Json:") { p = String(p.dropFirst(6)) }
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
                if let d = c as? [String: Any], let v = d[k] { values.append(v) }
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
    if let dbl = pat.range(of: "||") {
        return applyRegexReplace(text, pattern: String(pat[..<dbl.lowerBound]), replacement: String(pat[dbl.upperBound...]))
    }
    return applyRegexReplace(text, pattern: pat, replacement: "")
}

// MARK: - Dispatcher

func applyRuleNoReplace(_ input: String, _ rule: String, base: String) -> [String] {
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
    // Template string: "{{@@rule}} ... {{@@rule2}}" or plain text with templates
    if rule.contains("{{") {
        var out = rule
        var changed = false
        while let s = out.range(of: "{{@@"), let e = out[s.upperBound...].range(of: "}}") {
            let inner = String(out[s.upperBound..<e.lowerBound])
            let val = applyRuleFirst(input, inner, base: base)
            out.replaceSubrange(s.lowerBound..<e.upperBound, with: val); changed = true
        }
        while let s = out.range(of: "{{"), let e = out[s.upperBound...].range(of: "}}") {
            out.replaceSubrange(s.lowerBound..<e.upperBound, with: ""); changed = true
        }
        if changed { return [out] }
    }
    if rule.hasPrefix("@css:") { return evalCss(input, String(rule.dropFirst(5))) }
    if rule.hasPrefix("@json:") || rule.hasPrefix("@Json:") { return jsonExtract(input, rule) }
    if rule.hasPrefix("$.") || rule == "$" { return jsonExtract(input, rule) }
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
            for ci in current { vals.append(contentsOf: applyRuleNoReplace(ci, prefix, base: base)) }
        }
        var jsOut: [String] = []
        for v in vals {
            let jr = LegadoJS.run(jsCode, input: v, baseUrl: base,
                                  sourceKey: LegadoJSCtx.key, sourceUrl: LegadoJSCtx.sourceUrl,
                                  book: LegadoJSCtx.book)
            if !jr.isEmpty { jsOut.append(jr) }
        }
        current = jsOut
        if rest.isEmpty { out.append(contentsOf: jsOut) }
    }
    if !rest.isEmpty {
        for ci in current { out.append(contentsOf: applyRuleNoReplace(ci, rest, base: base)) }
    }
    return out
}

func applyRule(_ htmlOrJson: String, _ rule: String, base: String) -> [String] {
    var r = rule.trimmingCharacters(in: .whitespacesAndNewlines)
    if r.isEmpty { return [] }
    // 1) 整段 JS 规则：@js:code
    if r.hasPrefix("@js:") || r.hasPrefix("@JS:") {
        let js = String(r.dropFirst(4))
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
        let vals = applyRuleNoReplace(htmlOrJson, prefix, base: base)
        var out: [String] = []
        for v in vals {
            let jr = LegadoJS.run(jsCode, input: v, baseUrl: base,
                                  sourceKey: LegadoJSCtx.key, sourceUrl: LegadoJSCtx.sourceUrl,
                                  book: LegadoJSCtx.book)
            if !jr.isEmpty { out.append(jr) }
        }
        return out
    }
    if let jsRange2 = r.range(of: "@JS:") {
        let prefix = String(r[..<jsRange2.lowerBound])
        let jsCode = String(r[jsRange2.upperBound...])
        let vals = applyRuleNoReplace(htmlOrJson, prefix, base: base)
        var out: [String] = []
        for v in vals {
            let jr = LegadoJS.run(jsCode, input: v, baseUrl: base,
                                  sourceKey: LegadoJSCtx.key, sourceUrl: LegadoJSCtx.sourceUrl,
                                  book: LegadoJSCtx.book)
            if !jr.isEmpty { out.append(jr) }
        }
        return out
    }
    if r.hasPrefix("@xpath:") || r.hasPrefix("@XPath:") || r.hasPrefix("//") { return [] }
    var main = r; var replacePattern: String? = nil; var replaceWith = ""
    if let range = r.range(of: "##") {
        main = String(r[..<range.lowerBound])
        let after = String(r[range.upperBound...])
        if let dbl = after.range(of: "||") {
            replacePattern = String(after[..<dbl.lowerBound]); replaceWith = String(after[dbl.upperBound...])
        } else {
            replacePattern = after; replaceWith = ""
        }
    }
    let vals = applyRuleNoReplace(htmlOrJson, main, base: base)
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
    func exploreCategories() -> [ExploreCategory] {
        let raw = effectiveDiscoverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return [] }
        // JS exploreUrl：@js:...;JSON.stringify(s) —— 执行 JS 拿到分类 JSON 数组。
        // 之前这里直接 return []，导致 133 个 JS 分类源在发现页完全消失。
        var t = raw
        if t.hasPrefix("@js:") || t.hasPrefix("@JS:") {
            let js = String(t.dropFirst(4))
            let out = LegadoJS.run(js, input: "", baseUrl: bookSourceUrl,
                                   sourceKey: bookSourceUrl, sourceUrl: bookSourceUrl,
                                   book: nil, page: 1)
            t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if t.contains("<js>") {
            let out = LegadoJS.run(t, input: "", baseUrl: bookSourceUrl,
                                   sourceKey: bookSourceUrl, sourceUrl: bookSourceUrl,
                                   book: nil, page: 1)
            t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if t.isEmpty { return [] }
        // Legado's other exploreUrl format (used by most yckceo/1325 sources):
        // one "标题::链接" per line, separated by \n. The old code only knew
        // JSON arrays and single URLs, so it treated the whole multi-line
        // string as one URL and discovery always failed.
        if t.contains("::") {
            var out: [ExploreCategory] = []
            for line in t.components(separatedBy: .newlines) {
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
        return [ExploreCategory(title: "推荐", url: raw)]
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
        var out = template
        let encKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
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
                                   sourceKey: key, sourceUrl: sourceUrl,
                                   book: nil, page: page)
            out.replaceSubrange(s.lowerBound..<e.upperBound, with: val)
        }
        return out
    }

    func booksFromBlocks(_ blocks: [String], nameRule: String, authorRule: String, urlRule: String, coverRule: String, introRule: String) -> [SourceBook] {
        var out: [SourceBook] = []
        for blk in blocks {
            let name = applyRuleFirst(blk, nameRule, base: bookSourceUrl)
            if name.isEmpty { continue }
            var b = SourceBook(title: name, url: resolveUrl(applyRuleFirst(blk, urlRule, base: bookSourceUrl), base: bookSourceUrl), sourceName: bookSourceName, sourceUrl: bookSourceUrl)
            b.author = applyRuleFirst(blk, authorRule, base: bookSourceUrl)
            b.cover = resolveUrl(applyRuleFirst(blk, coverRule, base: bookSourceUrl), base: bookSourceUrl)
            b.intro = applyRuleFirst(blk, introRule, base: bookSourceUrl)
            out.append(b)
        }
        return out
    }

    func booksFromJSON(_ text: String, rule: RuleSet) -> [SourceBook] {
        // JSON list: either per-object blocks, or global field paths
        if !rule.bookList.isEmpty {
            let objs = jsonObjects(text, rule.bookList)
            if !objs.isEmpty {
                var out: [SourceBook] = []
                for obj in objs {
                    let name = applyRuleFirst(obj, rule.name, base: bookSourceUrl)
                    if name.isEmpty { continue }
                    var b = SourceBook(title: name, url: resolveUrl(applyRuleFirst(obj, rule.bookUrl, base: bookSourceUrl), base: bookSourceUrl), sourceName: bookSourceName, sourceUrl: bookSourceUrl)
                    b.author = applyRuleFirst(obj, rule.author, base: bookSourceUrl)
                    b.cover = resolveUrl(applyRuleFirst(obj, rule.coverUrl, base: bookSourceUrl), base: bookSourceUrl)
                    b.intro = applyRuleFirst(obj, rule.intro, base: bookSourceUrl)
                    out.append(b)
                }
                if !out.isEmpty { return out }
            }
        }
        let names = applyRule(text, rule.name, base: bookSourceUrl)
        if names.isEmpty { return [] }
        let authors = applyRule(text, rule.author, base: bookSourceUrl)
        let urls = applyRule(text, rule.bookUrl, base: bookSourceUrl)
        let covers = applyRule(text, rule.coverUrl, base: bookSourceUrl)
        let intros = applyRule(text, rule.intro, base: bookSourceUrl)
        var out: [SourceBook] = []
        for i in 0..<names.count {
            var b = SourceBook(title: names[i], url: i < urls.count ? resolveUrl(urls[i], base: bookSourceUrl) : "", sourceName: bookSourceName, sourceUrl: bookSourceUrl)
            if i < authors.count { b.author = authors[i] }
            if i < covers.count { b.cover = resolveUrl(covers[i], base: bookSourceUrl) }
            if i < intros.count { b.intro = intros[i] }
            out.append(b)
        }
        return out
    }

    func search(key: String) async throws -> [SourceBook] {
        try await LegadoJSCtx.$key.withValue(key) {
            try await LegadoJSCtx.$sourceUrl.withValue(self.bookSourceUrl) {
                try await self.searchImpl(key: key, filterByKeyword: true)
            }
        }
    }
    // 发现页兜底分类用：分类名（热门/玄幻…）不是书名，不能按关键词过滤，
    // 否则搜回来的书标题里没有“热门”二字就全被过滤掉，发现永远是空的。
    // 这就是截图里点分类也没书的根因。
    func searchForDiscovery(key: String) async throws -> [SourceBook] {
        try await LegadoJSCtx.$key.withValue(key) {
            try await LegadoJSCtx.$sourceUrl.withValue(self.bookSourceUrl) {
                try await self.searchImpl(key: key, filterByKeyword: false)
            }
        }
    }
    private func searchImpl(key: String, filterByKeyword: Bool = true) async throws -> [SourceBook] {
        // POST search (common in yckceo/1325): searchUrl carries
        // ,{"method":"post","body":"searchkey={{key}}"} after the URL.
        // The old code stripped that part and GET-fetched the bare search
        // page, so it returned the site's homepage junk, not results.
        var html = ""
        if let post = postSearchRequest(for: key) {
            html = try await fetchText(urlString: post.url, method: post.method, body: post.body)
        } else {
            let url = searchURL(for: key)
            guard !url.isEmpty else { return [] }
            html = try await fetchText(urlString: url)
        }
        let trimmed = html.trimmingCharacters(in: .whitespaces)
        var raw: [SourceBook] = []
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let j = booksFromJSON(html, rule: ruleSearch)
            if !j.isEmpty { raw = j }
        }
        if raw.isEmpty {
            if ruleSearch.bookList.isEmpty { raw = booksFromBlocks([html], nameRule: ruleSearch.name, authorRule: ruleSearch.author, urlRule: ruleSearch.bookUrl, coverRule: ruleSearch.coverUrl, introRule: ruleSearch.intro) }
            else {
                let blocks = applyRule(html, ruleSearch.bookList, base: bookSourceUrl)
                if !blocks.isEmpty { raw = booksFromBlocks(blocks, nameRule: ruleSearch.name, authorRule: ruleSearch.author, urlRule: ruleSearch.bookUrl, coverRule: ruleSearch.coverUrl, introRule: ruleSearch.intro) }
            }
        }
        // Fix for "search 仙逆 returns a pile of unrelated books": many sites
        // return their hot/recommend list when a search misses, or a too-broad
        // bookList grabs the whole page. Keep only results whose title or
        // author actually contains the keyword, and cap per-source output so
        // one junk source cannot fill the whole 500-result budget.
        // 发现兜底分类不走这一步（见 searchForDiscovery）。
        let normKey = key.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "").lowercased()
        if filterByKeyword && !normKey.isEmpty {
            let filtered = raw.filter {
                $0.title.replacingOccurrences(of: " ", with: "").lowercased().contains(normKey) ||
                $0.author.replacingOccurrences(of: " ", with: "").lowercased().contains(normKey)
            }
            if !filtered.isEmpty { return Array(filtered.prefix(30)) }
            // 兜底：过滤后为空（可能是书名格式/编码差异），退回原始结果，避免「搜得到但被过滤光」
            return Array(raw.prefix(10))
        }
        return Array(raw.prefix(30))
    }

    func discover(category: ExploreCategory? = nil) async throws -> [SourceBook] {
        try await LegadoJSCtx.$sourceUrl.withValue(self.bookSourceUrl) {
            try await self.discoverImpl(category: category)
        }
    }
    private func discoverImpl(category: ExploreCategory? = nil) async throws -> [SourceBook] {
        let cats = exploreCategories()
        let cat = category ?? cats.first
        guard let cat = cat else { return [] }
        // 分类 URL 也可能带 {{page}} / {{java...}} 占位符，统一走模板求值
        var url = Self.fillSearchTemplate(cat.url, key: "", page: 1, sourceUrl: bookSourceUrl)
        if !url.hasPrefix("http") { url = resolveUrl(url, base: bookSourceUrl) }
        let html = try await fetchText(urlString: url)
        let rule = effectiveDiscoverRule.bookList.isEmpty ? ruleSearch : effectiveDiscoverRule
        let trimmed = html.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let j = booksFromJSON(html, rule: rule)
            if !j.isEmpty { return j }
        }
        if !rule.bookList.isEmpty {
            let blocks = applyRule(html, rule.bookList, base: bookSourceUrl)
            if !blocks.isEmpty {
                let books = booksFromBlocks(blocks, nameRule: rule.name, authorRule: rule.author, urlRule: rule.bookUrl, coverRule: rule.coverUrl, introRule: rule.intro)
                if !books.isEmpty { return books }
            }
        }
        // 兜底：发现页和搜索页 HTML 结构不同，ruleSearch 的选择器常匹配不到发现页，
        // 导致「点分类进去一片空白」。这里用通用链接提取保住分类列表。
        return booksFromLinksFallback(html)
    }

    // 通用兜底：从页面提取所有 <a> 链接 + 文字，过滤出像书名的条目。
    // 用于发现分类页规则不匹配时，保证「点分类能出书」。
    func booksFromLinksFallback(_ html: String) -> [SourceBook] {
        let links = cssExtractAll(html, "a@href")
        let texts = cssExtractAll(html, "a@text")
        var out: [SourceBook] = []
        let chinese = try? NSRegularExpression(pattern: "[\\u4e00-\\u9fa5]")
        for i in 0..<min(links.count, texts.count) {
            let t = texts[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2 && t.count <= 40 else { continue }
            guard chinese?.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil else { continue }
            // 跳过明显的导航/翻页词
            let skip = ["首页", "下一页", "上一页", "末页", "下一页»", "加入书架", "开始阅读", "目录", "简介", "排行", "分类", "最新", "热门"]
            if skip.contains(where: { t == $0 }) { continue }
            let u = resolveUrl(links[i], base: bookSourceUrl)
            out.append(SourceBook(title: t, url: u, sourceName: bookSourceName, sourceUrl: bookSourceUrl))
            if out.count >= 50 { break }
        }
        return out
    }

    func fetchBookInfo(book: SourceBook) async throws -> SourceBook {
        let ctx = LegadoJS.BookCtx(bookUrl: book.url, name: book.title, author: book.author)
        return try await LegadoJSCtx.$book.withValue(ctx) {
            try await LegadoJSCtx.$sourceUrl.withValue(self.bookSourceUrl) {
                try await LegadoJSCtx.$key.withValue(book.title) {
                    try await self.fetchBookInfoImpl(book: book)
                }
            }
        }
    }
    private func fetchBookInfoImpl(book: SourceBook) async throws -> SourceBook {
        // If ruleBookInfo is empty, the search result itself is the detail.
        if ruleBookInfo.name.isEmpty && ruleBookInfo.tocUrl.isEmpty && ruleBookInfo.coverUrl.isEmpty && ruleBookInfo.intro.isEmpty { return book }
        let html = try await fetchText(urlString: book.url)
        var b = book
        let name = applyRuleFirst(html, ruleBookInfo.name, base: bookSourceUrl)
        if !name.isEmpty { b.title = name }
        let author = applyRuleFirst(html, ruleBookInfo.author, base: bookSourceUrl)
        if !author.isEmpty { b.author = author }
        let cover = applyRuleFirst(html, ruleBookInfo.coverUrl, base: bookSourceUrl)
        if !cover.isEmpty { b.cover = resolveUrl(cover, base: bookSourceUrl) }
        let intro = applyRuleFirst(html, ruleBookInfo.intro, base: bookSourceUrl)
        if !intro.isEmpty { b.intro = intro }
        return b
    }

    func fetchChapters(book: SourceBook) async throws -> [BookChapter] {
        let ctx = LegadoJS.BookCtx(bookUrl: book.url, name: book.title, author: book.author)
        return try await LegadoJSCtx.$book.withValue(ctx) {
            try await LegadoJSCtx.$sourceUrl.withValue(self.bookSourceUrl) {
                try await LegadoJSCtx.$key.withValue(book.title) {
                    try await self.fetchChaptersImpl(book: book)
                }
            }
        }
    }
    private func fetchChaptersImpl(book: SourceBook) async throws -> [BookChapter] {
        var tocUrl = book.url
        if !ruleBookInfo.tocUrl.isEmpty {
            let html = try await fetchText(urlString: book.url)
            let t = applyRuleFirst(html, ruleBookInfo.tocUrl, base: bookSourceUrl)
            if !t.isEmpty { tocUrl = resolveUrl(t, base: bookSourceUrl) }
        }
        var chapters: [BookChapter] = []
        var currentUrl: String? = tocUrl
        var pages = 0
        while let pageUrl = currentUrl, pages < 4 {
            pages += 1
            let html = try await fetchText(urlString: pageUrl)
            let trimmed = html.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                let objs = jsonObjects(html, ruleToc.chapterList)
                if !objs.isEmpty {
                    for obj in objs {
                        let name = applyRuleFirst(obj, ruleToc.chapterName, base: bookSourceUrl)
                        let url = resolveUrl(applyRuleFirst(obj, ruleToc.chapterUrl, base: bookSourceUrl), base: bookSourceUrl)
                        let title = name.isEmpty ? stripText(obj, preserveNewlines: false) : name
                        if !title.isEmpty { chapters.append(BookChapter(title: title, text: "__URL__" + url)) }
                    }
                }
            } else if !ruleToc.chapterList.isEmpty {
                let items = applyRule(html, ruleToc.chapterList, base: bookSourceUrl)
                for item in items {
                    let name = applyRuleFirst(item, ruleToc.chapterName, base: bookSourceUrl)
                    let url = resolveUrl(applyRuleFirst(item, ruleToc.chapterUrl, base: bookSourceUrl), base: bookSourceUrl)
                    let title = name.isEmpty ? stripText(item, preserveNewlines: false) : name
                    if title.isEmpty { continue }
                    chapters.append(BookChapter(title: title, text: "__URL__" + url))
                }
            }
            if chapters.isEmpty && pages == 1 {
                let links = cssExtractAll(html, "a@href")
                let texts = cssExtractAll(html, "a@text")
                for i in 0..<min(links.count, texts.count) {
                    let t = texts[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.count > 2 && t.count < 80 { chapters.append(BookChapter(title: t, text: "__URL__" + resolveUrl(links[i], base: bookSourceUrl))) }
                }
            }
            // Next TOC page
            if !ruleToc.nextTocUrl.isEmpty {
                let next = applyRuleFirst(html, ruleToc.nextTocUrl, base: bookSourceUrl)
                if !next.isEmpty {
                    let nextUrl = resolveUrl(next, base: bookSourceUrl)
                    if nextUrl != pageUrl { currentUrl = nextUrl; continue }
                }
            }
            currentUrl = nil
        }
        return chapters
    }

    func fetchChapterContent(_ chapter: BookChapter) async throws -> String {
        try await LegadoJSCtx.$sourceUrl.withValue(self.bookSourceUrl) {
            try await self.fetchChapterContentImpl(chapter)
        }
    }
    private func fetchChapterContentImpl(_ chapter: BookChapter) async throws -> String {
        guard chapter.text.hasPrefix("__URL__") else { return chapter.text }
        let url = String(chapter.text.dropFirst(7))
        var content = ""
        var currentUrl: String? = url
        var pages = 0
        while let pageUrl = currentUrl, pages < 5 {
            pages += 1
            let html = try await fetchText(urlString: pageUrl)
            var part = ""
            if !ruleContent.content.isEmpty {
                let parts = applyRule(html, ruleContent.content, base: bookSourceUrl)
                part = parts.joined(separator: "\n")
                if part.isEmpty { part = stripText(html, preserveNewlines: true) }
            } else {
                part = stripText(html, preserveNewlines: true)
            }
            if !content.isEmpty { content += "\n" }
            content += part
            if !ruleContent.nextContentUrl.isEmpty {
                let next = applyRuleFirst(html, ruleContent.nextContentUrl, base: bookSourceUrl)
                if !next.isEmpty {
                    let nextUrl = resolveUrl(next, base: bookSourceUrl)
                    if nextUrl != pageUrl { currentUrl = nextUrl; continue }
                }
            }
            currentUrl = nil
        }
        if !ruleContent.replaceRegex.isEmpty { content = applyRuleReplace(content, replaceRegex: ruleContent.replaceRegex) }
        // If a content rule returned raw HTML, strip it for reading
        if content.contains("<") && content.contains(">") {
            content = stripText(content, preserveNewlines: true)
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 拉取漫画章节的图片 URL 列表（用 ruleContent.imageUrl 规则，兜底 img@src，支持多页正文）
    func fetchChapterImages(_ chapter: BookChapter) async throws -> [String] {
        guard chapter.text.hasPrefix("__URL__") else { return chapter.imageUrls }
        let url = String(chapter.text.dropFirst(7))
        var images: [String] = []
        var currentUrl: String? = url
        var pages = 0
        while let pageUrl = currentUrl, pages < 5 {
            pages += 1
            let html = try await fetchText(urlString: pageUrl)
            var pageImages: [String] = []
            // 1) 优先用漫画书源的图片规则 imageUrl（如 @css:.content img@src）
            if !ruleContent.imageUrl.isEmpty {
                pageImages = applyRule(html, ruleContent.imageUrl, base: bookSourceUrl)
                    .map { resolveUrl($0, base: bookSourceUrl) }
            }
            // 2) 兜底：从 content 规则结果里提图片
            if pageImages.isEmpty && !ruleContent.content.isEmpty {
                let parts = applyRule(html, ruleContent.content, base: bookSourceUrl)
                for p in parts {
                    if p.hasPrefix("http") || p.hasPrefix("//") {
                        pageImages.append(resolveUrl(p, base: bookSourceUrl))
                    } else if p.lowercased().contains("<img") {
                        pageImages.append(contentsOf: cssExtractAll(p, "img@src").map { resolveUrl($0, base: bookSourceUrl) })
                    }
                }
            }
            // 3) 兜底：从整页 HTML 提所有 img 的 src
            if pageImages.isEmpty {
                pageImages = cssExtractAll(html, "img@src").map { resolveUrl($0, base: bookSourceUrl) }
            }
            pageImages = pageImages.filter { !$0.isEmpty && !$0.hasPrefix("data:") }
            images.append(contentsOf: pageImages)
            // 下一页正文（漫画一章可能分多页）
            if !ruleContent.nextContentUrl.isEmpty {
                let next = applyRuleFirst(html, ruleContent.nextContentUrl, base: bookSourceUrl)
                if !next.isEmpty {
                    let nextUrl = resolveUrl(next, base: bookSourceUrl)
                    if nextUrl != pageUrl { currentUrl = nextUrl; continue }
                }
            }
            currentUrl = nil
        }
        return images
    }
}

// Multi-source search: batched TaskGroup (20 at a time, so 1000 sources do not
// all fire at once), per-source errors swallowed, dedupe by title+author.
// The returned list is deduped for display; callers keep the raw list separately
// when they need "change source" alternatives.
func searchAllSources(_ sources: [LegadoSource], key: String) async -> [SourceBook] {
    var all: [SourceBook] = []
    var index = 0
    while index < sources.count {
        let batch = Array(sources[index..<min(index + 20, sources.count)])
        index += batch.count
        let batchResults = await withTaskGroup(of: [SourceBook].self) { group in
            for src in batch {
                group.addTask {
                    do { return try await withTimeout(25) { try await src.search(key: key) } }
                    catch { return [] }
                }
            }
            var collected: [SourceBook] = []
            for await r in group { collected.append(contentsOf: r) }
            return collected
        }
        all.append(contentsOf: batchResults)
        if all.count >= 300 { break }
    }
    var seen = Set<String>(); var out: [SourceBook] = []
    for b in all {
        let k = (b.title + "|" + b.author).lowercased().trimmingCharacters(in: .whitespaces)
        if seen.contains(k) { continue }
        seen.insert(k); out.append(b)
    }
    return out
}

func dedupeKey(_ b: SourceBook) -> String {
    (b.title + "|" + b.author).lowercased().trimmingCharacters(in: .whitespaces)
}

func searchAllRawSources(_ sources: [LegadoSource], key: String) async -> [SourceBook] {
    var all: [SourceBook] = []
    var index = 0
    while index < sources.count {
        let batch = Array(sources[index..<min(index + 20, sources.count)])
        index += batch.count
        let batchResults = await withTaskGroup(of: [SourceBook].self) { group in
            for src in batch {
                group.addTask {
                    do { return try await withTimeout(25) { try await src.search(key: key) } }
                    catch { return [] }
                }
            }
            var collected: [SourceBook] = []
            for await r in group { collected.append(contentsOf: r) }
            return collected
        }
        all.append(contentsOf: batchResults)
        if all.count >= 500 { break }
    }
    return all
}
