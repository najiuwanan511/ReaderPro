import Foundation

struct ReplaceRule: Identifiable, Codable, Equatable, Hashable {
    var id = UUID().uuidString
    var name = ""
    var pattern = ""
    var replacement = ""
    var enabled = true
    var group = ""
    var isRegex = true
    var scope = ""
    var excludeScope = ""
    var scopeTitle = false
    var scopeContent = true
    var timeoutMillisecond = 3000
    var order = 0

    static var defaults: [ReplaceRule] {
        [ReplaceRule(name: "去“本章未完”", pattern: "本章未完，点击下一页继续阅读.*"),
         ReplaceRule(name: "去广告网址行", pattern: "https?://[^\\s\\n]+"),
         ReplaceRule(name: "去多余空行", pattern: "\\n{3,}", replacement: "\n\n")]
    }

    func applies(to book: LocalBook?, title: Bool) -> Bool {
        guard enabled, !pattern.isEmpty, (title ? scopeTitle : scopeContent) else { return false }
        let identities = [book?.title ?? "", book?.sourceUrl ?? ""].filter { !$0.isEmpty }
        if !excludeScope.isEmpty && identities.contains(where: { excludeScope.contains($0) }) { return false }
        return scope.isEmpty || identities.contains(where: { scope.contains($0) })
    }

    func validate() throws {
        guard !pattern.isEmpty else { throw SourceFailure(stage: "替换规则", message: "替换内容不能为空") }
        if isRegex { _ = try NSRegularExpression(pattern: pattern) }
    }

    func replacing(_ text: String) throws -> String {
        try validate()
        if !isRegex { return text.replacingOccurrences(of: pattern, with: replacement) }
        let regex = try NSRegularExpression(pattern: pattern)
        let original = text as NSString
        let deadline = Date().addingTimeInterval(Double(timeoutMillisecond > 0 ? timeoutMillisecond : 3000) / 1000)
        var replacements: [(NSRange, String)] = []
        var timedOut = false
        // ICU reports progress even while searching for the first match.
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: original.length)) { match, _, stop in
            if Date() > deadline { timedOut = true; stop.pointee = true; return }
            if let match { replacements.append((match.range, regex.replacementString(for: match, in: text, offset: 0, template: replacement))) }
        }
        if timedOut { throw SourceFailure(stage: "替换规则", message: "规则“\(name)”执行超时") }
        let output = NSMutableString(string: text)
        for (range, value) in replacements.reversed() { output.replaceCharacters(in: range, with: value) }
        return output as String
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, pattern, replacement, enabled, isEnabled, group, isRegex, scope, excludeScope, scopeTitle, scopeContent, timeoutMillisecond, order
    }
}

extension ReplaceRule {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? c.decode(String.self, forKey: .id) { id = value }
        else if let value = try? c.decode(Int64.self, forKey: .id) { id = String(value) }
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        pattern = try c.decode(String.self, forKey: .pattern)
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        isRegex = try c.decodeIfPresent(Bool.self, forKey: .isRegex) ?? true
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? ""
        excludeScope = try c.decodeIfPresent(String.self, forKey: .excludeScope) ?? ""
        scopeTitle = try c.decodeIfPresent(Bool.self, forKey: .scopeTitle) ?? false
        scopeContent = try c.decodeIfPresent(Bool.self, forKey: .scopeContent) ?? true
        timeoutMillisecond = try c.decodeIfPresent(Int.self, forKey: .timeoutMillisecond) ?? 3000
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(pattern, forKey: .pattern); try c.encode(replacement, forKey: .replacement)
        try c.encode(enabled, forKey: .enabled); try c.encode(enabled, forKey: .isEnabled)
        try c.encode(group, forKey: .group); try c.encode(isRegex, forKey: .isRegex)
        try c.encode(scope, forKey: .scope); try c.encode(excludeScope, forKey: .excludeScope)
        try c.encode(scopeTitle, forKey: .scopeTitle); try c.encode(scopeContent, forKey: .scopeContent)
        try c.encode(timeoutMillisecond, forKey: .timeoutMillisecond); try c.encode(order, forKey: .order)
    }
}

enum ReplacementRuleDocument {
    static func decode(_ data: Data) throws -> [ReplaceRule] {
        let object = try JSONSerialization.jsonObject(with: data)
        let values: [Any]
        if let array = object as? [Any] { values = array }
        else if let dictionary = object as? [String: Any], dictionary["pattern"] != nil { values = [dictionary] }
        else { throw SourceFailure(stage: "替换规则导入", message: "需要开源阅读替换规则 JSON 对象或数组") }
        guard !values.isEmpty else { throw SourceFailure(stage: "替换规则导入", message: "没有找到替换规则") }
        var entries: [(position: Int, rule: ReplaceRule)] = []
        for (index, value) in values.enumerated() {
            let encoded = try JSONSerialization.data(withJSONObject: value)
            let rule = try JSONDecoder().decode(ReplaceRule.self, from: encoded)
            try rule.validate()
            entries.append((position: index, rule: rule))
        }
        entries.sort { left, right in
            if left.rule.order == right.rule.order { return left.position < right.position }
            return left.rule.order < right.rule.order
        }
        return entries.map { $0.rule }
    }

    static func encode(_ rules: [ReplaceRule]) throws -> Data {
        let objects: [[String: Any]] = try rules.map { rule in
            let data = try JSONEncoder().encode(rule)
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SourceFailure(stage: "替换规则导出", message: "规则格式错误")
            }
            // Android expects a Long ID; keep ReaderPro's UUID in local backups,
            // and use a stable positive numeric identity in exchange documents.
            let hash = rule.id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            object["id"] = Int64(rule.id) ?? Int64(hash & UInt64(Int64.max))
            object.removeValue(forKey: "enabled")
            return object
        }
        return try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
    }
}

extension BookStore {
    @discardableResult func importReplaceRules(_ data: Data) throws -> Int {
        let incoming = try ReplacementRuleDocument.decode(data)
        for var rule in incoming {
            if let index = replaceRules.firstIndex(where: {
                $0.id == rule.id || ($0.name == rule.name && $0.pattern == rule.pattern && $0.scope == rule.scope && $0.group == rule.group)
            }) {
                rule.id = replaceRules[index].id; replaceRules[index] = rule
            } else { replaceRules.append(rule) }
        }
        save(); return incoming.count
    }
}
