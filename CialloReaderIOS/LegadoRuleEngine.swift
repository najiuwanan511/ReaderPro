import Foundation

// MARK: - Legado rule engine (subset, best-effort, no JS/XPath)
// Research basis (see report): gedoor/legado BookSource fields
// bookSourceName/bookSourceUrl/bookSourceType/searchUrl/exploreUrl/
// ruleSearch/ruleBookInfo/ruleToc/ruleContent/ruleExplore, and rule syntax
// from Legado's ruleHelp/AnalyzeRule mirrors: Default (class./tag./id.),
// @css:, @json:/$., :regex, ##replace, && join, || first-non-empty,
// indices .0/.1/.-1, chained @text/@href/@src/@html/@textNodes and
// @attr(...). @js:/<js>/{{js}} and @xpath:// are deliberately unsupported
// (they return empty, never crash) - see report for why.

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
    var index: Int? = nil
    // Trailing .<int> / .-<int> index, e.g. p.2, class.book_other.0, ul.1
    var parts = t.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    if parts.count >= 2, let last = parts.last, let v = Int(last) {
        // Only treat as index when there is a real selector before it
        index = v; parts.removeLast(); t = parts.joined(separator: ".")
    }
    if t.hasPrefix("class.") {
        let rest = String(t.dropFirst(6))
        return Sel(tag: nil, classes: rest.split(separator: " ").map(String.init), index: index)
    }
    if t.hasPrefix("tag.") {
        return Sel(tag: String(t.dropFirst(4)), index: index)
    }
    if t.hasPrefix("id.") {
        return Sel(idVal: String(t.dropFirst(3)), index: index)
    }
    if t.hasPrefix(".") {
        return Sel(classes: [String(t.dropFirst())], index: index)
    }
    if t.hasPrefix("[") && t.hasSuffix("]") {
        let inner = String(t.dropFirst().dropLast())
        let a = parseAttrSelector(inner)
        return Sel(attrName: a.name, attrOp: a.op, attrVal: a.val, index: index)
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
    return Sel(tag: tag, classes: classes, idVal: idVal, attrName: attrName, attrOp: attrOp, attrVal: attrVal, index: index)
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
        for el in els {
            if !el.open.isEmpty && matchesSelf(el, parsed: parsed) { found.append(el) }
            let searchIn = el.open.isEmpty ? el.full : el.inner
            found.append(contentsOf: findElements(searchIn, tag: parsed.tag, classes: parsed.classes, idVal: parsed.idVal, attrName: parsed.attrName, attrOp: parsed.attrOp, attrVal: parsed.attrVal))
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
    var els: [HtmlEl] = [HtmlEl(open: "", inner: html, full: html)]
    for sel in splitCssSelector(selector) {
        let parsed = parseSelectorToken(sel)
        var found: [HtmlEl] = []
        for el in els {
            if !el.open.isEmpty && matchesSelf(el, parsed: parsed) { found.append(el) }
            let searchIn = el.open.isEmpty ? el.full : el.inner
            found.append(contentsOf: findElements(searchIn, tag: parsed.tag, classes: parsed.classes, idVal: parsed.idVal, attrName: parsed.attrName, attrOp: parsed.attrOp, attrVal: parsed.attrVal))
        }
        els = found
        if els.isEmpty { break }
    }
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

func applyRule(_ htmlOrJson: String, _ rule: String, base: String) -> [String] {
    var r = rule.trimmingCharacters(in: .whitespacesAndNewlines)
    if r.isEmpty { return [] }
    if r.hasPrefix("@js:") || r.hasPrefix("@JS:") || r.contains("<js>") { return [] }
    // Trailing @js: transformation (e.g. tocUrl ...@href@js:...) - evaluate the
    // selector part and ignore the JS transform (unsupported, best-effort).
    if let jsRange = r.range(of: "@js:") { r = String(r[..<jsRange.lowerBound]) }
    if let jsRange2 = r.range(of: "@JS:") { r = String(r[..<jsRange2.lowerBound]) }
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
        if raw.hasPrefix("@js:") || raw.hasPrefix("@JS:") || raw.contains("<js>") { return [] }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func searchURL(for key: String, page: Int = 1) -> String {
        var u = searchUrl
        // Legado AnalyzeUrl may append ,{"method":"POST",...} - best-effort GET only
        if let comma = u.firstIndex(of: ",") {
            let rest = u[comma...]
            if rest.contains("{") { u = String(u[..<comma]) }
        }
        let enc = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        u = u.replacingOccurrences(of: "{{key}}", with: enc)
            .replacingOccurrences(of: "{{page}}", with: "\(page)")
            .replacingOccurrences(of: "{{page-1}}", with: "\(page - 1)")
        if u.isEmpty { return "" }
        if u.hasPrefix("http") { return u }
        return resolveUrl(u, base: bookSourceUrl)
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
        let url = searchURL(for: key)
        guard !url.isEmpty else { return [] }
        let html = try await fetchText(urlString: url)
        let trimmed = html.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let j = booksFromJSON(html, rule: ruleSearch)
            if !j.isEmpty { return j }
        }
        if ruleSearch.bookList.isEmpty { return booksFromBlocks([html], nameRule: ruleSearch.name, authorRule: ruleSearch.author, urlRule: ruleSearch.bookUrl, coverRule: ruleSearch.coverUrl, introRule: ruleSearch.intro) }
        let blocks = applyRule(html, ruleSearch.bookList, base: bookSourceUrl)
        if blocks.isEmpty { return [] }
        return booksFromBlocks(blocks, nameRule: ruleSearch.name, authorRule: ruleSearch.author, urlRule: ruleSearch.bookUrl, coverRule: ruleSearch.coverUrl, introRule: ruleSearch.intro)
    }

    func discover(category: ExploreCategory? = nil) async throws -> [SourceBook] {
        let cats = exploreCategories()
        let cat = category ?? cats.first
        guard let cat = cat else { return [] }
        var url = cat.url.replacingOccurrences(of: "{{page}}", with: "1").replacingOccurrences(of: "{{page-1}}", with: "0")
        if !url.hasPrefix("http") { url = resolveUrl(url, base: bookSourceUrl) }
        let html = try await fetchText(urlString: url)
        let rule = effectiveDiscoverRule.bookList.isEmpty ? ruleSearch : effectiveDiscoverRule
        let trimmed = html.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let j = booksFromJSON(html, rule: rule)
            if !j.isEmpty { return j }
        }
        if rule.bookList.isEmpty { return [] }
        let blocks = applyRule(html, rule.bookList, base: bookSourceUrl)
        return booksFromBlocks(blocks, nameRule: rule.name, authorRule: rule.author, urlRule: rule.bookUrl, coverRule: rule.coverUrl, introRule: rule.intro)
    }

    func fetchBookInfo(book: SourceBook) async throws -> SourceBook {
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
                    do { return try await src.search(key: key) } catch { return [] }
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
                    do { return try await src.search(key: key) } catch { return [] }
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
