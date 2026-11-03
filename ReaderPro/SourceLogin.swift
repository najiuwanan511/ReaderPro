import Foundation

enum SourceLoginInfo {
    private static let lock = NSLock()
    private static var cache: [String: [String: String]] = [:]
    // Use the same protected Keychain / sideload fallback as login headers,
    // with a distinct account so credentials can never become HTTP headers.
    private static func key(_ source: String) -> String { "login-info\u{0}" + source }
    static func get(_ source: String) -> String? { SourceLoginHeaders.get(key(source)) }
    static func map(_ source: String) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let value = cache[source] { return value }
        let value = SourceLoginHeaders.map(key(source)) ?? [:]; cache[source] = value
        return value
    }
    static func put(_ values: [String: String], source: String) throws {
        lock.lock(); defer { lock.unlock() }
        if cache[source] == values { return }
        let data = try JSONSerialization.data(withJSONObject: values, options: .sortedKeys)
        try SourceLoginHeaders.put(String(decoding: data, as: UTF8.self), source: key(source))
        cache[source] = values
    }
    static func remove(_ source: String) throws {
        lock.lock(); defer { lock.unlock() }
        try SourceLoginHeaders.remove(key(source)); cache[source] = [:]
    }
}

struct SourceLoginRow: Equatable {
    var name: String
    var type: String
    var action: String?
    var choices: [String]
    var defaultValue: String?
    var viewName: String?
    var displayName: String
    var style: ExploreStyle
    static func parse(_ text: String) throws -> [SourceLoginRow] {
        guard let rows = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .json5Allowed) as? [[String: Any]] else {
            throw SourceFailure(stage: "书源登录", message: "登录界面规则未返回有效的表单数组")
        }
        return rows.map {
            let name = $0["name"] as? String ?? ""
            return SourceLoginRow(name: name, type: $0["type"] as? String ?? "text", action: $0["action"] as? String,
                                  choices: ($0["chars"] as? [Any])?.compactMap { $0 as? String } ?? [],
                                  defaultValue: $0["default"] as? String, viewName: $0["viewName"] as? String,
                                  displayName: name, style: ExploreStyle($0["style"] as? [String: Any] ?? [:]))
        }
    }
}

struct SourceLoginBrowser: Identifiable {
    let id = UUID()
    let url: String
    var html: String? = nil
    var script: String? = nil
}

// Confined to one rule worker; no JSValue is retained or passed to SwiftUI.
final class SourceLoginContext {
    var values: [String: String]
    var updates: [String: String] = [:]
    var resetDefaults = false
    var rebuild = false
    var message = ""
    var copyText: String?
    var browser: SourceLoginBrowser?
    var isLongClick = false
    init(_ values: [String: String]) { self.values = values }
}

extension LegadoJSCtx {
    @TaskLocal static var loginContext: SourceLoginContext?
}

extension LegadoSource {
    var hasLogin: Bool { !loginUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !loginUi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var loginScript: String { Self.unwrapLoginScript(loginUrl) ?? loginUrl }
    static func unwrapLoginScript(_ text: String) -> String? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("@js:") { return String(raw.dropFirst(4)) }
        if raw.hasPrefix("<js>"), let end = raw.range(of: "</js>", options: .backwards) { return String(raw[raw.index(raw.startIndex, offsetBy: 4)..<end.lowerBound]) }
        return nil
    }
    var webLoginURL: String? {
        guard loginUi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.unwrapLoginScript(loginUrl) == nil else { return nil }
        let raw = loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains("\n"), !raw.contains("function ") else { return nil }
        let resolved = resolveUrl(raw, base: bookSourceUrl)
        guard let url = URL(string: resolved), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return resolved
    }

    struct LoginSnapshot {
        var rows: [SourceLoginRow]
        var values: [String: String]
        var message: String
        var browser: SourceLoginBrowser?
        var copyText: String?
    }

    func loginSnapshot(values: [String: String]? = nil, action: String? = nil, longClick: Bool = false) async throws -> LoginSnapshot {
        try await withTimeout(30) {
            try await self.withRules {
                let context = SourceLoginContext(values ?? SourceLoginInfo.map(self.bookSourceUrl))
                context.isLongClick = longClick
                return try await LegadoJSCtx.$loginContext.withValue(context) {
                    func evaluate(_ expression: String) throws -> String {
                        let code = self.webLoginURL == nil ? self.loginScript + "\n;\n" + expression : expression
                        let result = LegadoJS.run(code, input: "", baseUrl: self.bookSourceUrl, sourceKey: "", sourceUrl: self.bookSourceUrl,
                                                  structuredResult: context.values, expandTemplates: false)
                        try LegadoJSCtx.failures?.check()
                        return result
                    }
                    func rows() throws -> [SourceLoginRow] {
                        let definition = self.loginUi.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !definition.isEmpty else { return [] }
                        return try SourceLoginRow.parse(Self.unwrapLoginScript(definition).map { try evaluate($0) } ?? definition)
                    }
                    var currentRows = try rows()
                    func applyDefaults() {
                        for row in currentRows where row.type != "button" && context.values[row.name] == nil {
                            context.values[row.name] = row.defaultValue ?? (["select", "toggle"].contains(row.type) ? row.choices.first ?? "" : "")
                        }
                    }
                    applyDefaults()
                    // Values must be visible through getLoginInfoMap while a
                    // source action changes its API/route or performs login.
                    if let action {
                        try SourceLoginInfo.put(context.values, source: self.bookSourceUrl)
                        if action.hasPrefix("http://") || action.hasPrefix("https://") {
                            context.browser = SourceLoginBrowser(url: action)
                        } else { _ = try evaluate(Self.unwrapLoginScript(action) ?? action) }
                    }
                    if context.rebuild { currentRows = try rows() }
                    if context.resetDefaults { context.values = [:] }
                    applyDefaults()
                    for row in currentRows where row.type != "button" {
                        if let value = context.updates[row.name] { context.values[row.name] = value }
                    }
                    for index in currentRows.indices {
                        let row = currentRows[index]
                        if let name = context.updates[row.name], row.type == "button" { currentRows[index].displayName = name }
                        else if let expression = row.viewName {
                            // Android reports a bad label independently of the
                            // actual controls; it must not discard the form.
                            let errors = RuleFailures()
                            do {
                                let label = try LegadoJSCtx.$failures.withValue(errors) { try evaluate(expression) }
                                currentRows[index].displayName = label.isEmpty ? "null" : label
                            } catch { currentRows[index].displayName = "err" }
                        }
                    }
                    try SourceLoginInfo.put(context.values, source: self.bookSourceUrl)
                    ExploreInfo.refresh(self.bookSourceUrl)
                    return LoginSnapshot(rows: currentRows, values: context.values, message: context.message,
                                         browser: context.browser, copyText: context.copyText)
                }
            }
        }
    }
}
