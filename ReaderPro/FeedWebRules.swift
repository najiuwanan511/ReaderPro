import Foundation

enum FeedWebRules {
    static func entries(_ value: String) -> [String] {
        value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    // Android gives a nonempty blacklist precedence over the whitelist.
    static func allows(_ url: String, source: RssSource) -> Bool {
        func matches(_ pattern: String) -> Bool {
            if url.hasPrefix(pattern) { return true }
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(url.startIndex..., in: url)
            return regex.firstMatch(in: url, range: range)?.range == range
        }
        let blacklist = entries(source.contentBlacklist)
        if !blacklist.isEmpty { return !blacklist.contains(where: matches) }
        let whitelist = entries(source.contentWhitelist)
        return whitelist.isEmpty || whitelist.contains(where: matches)
    }
    static func contentRules(_ source: RssSource) -> String? {
        let black = entries(source.contentBlacklist), white = entries(source.contentWhitelist)
        guard !black.isEmpty || !white.isEmpty else { return nil }
        var rules: [[String: Any]] = []
        func append(_ filter: String, action: String) {
            rules.append(["trigger": ["url-filter": filter, "url-filter-is-case-sensitive": true], "action": ["type": action]])
        }
        if black.isEmpty { append(".*", action: "block") }
        for item in black.isEmpty ? white : black {
            let action = black.isEmpty ? "ignore-previous-rules" : "block"
            append("^" + NSRegularExpression.escapedPattern(for: item), action: action)
            append("^(" + item + ")$", action: action)
        }
        return (try? JSONSerialization.data(withJSONObject: rules)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
