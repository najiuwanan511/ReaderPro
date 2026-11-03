import Foundation

struct ExploreStyle: Equatable {
    var grow: Double = 0
    var shrink: Double = 1
    var alignSelf = "auto"
    var basisPercent: Double = -1
    var wrapBefore = false
    var justifySelf = "auto"

    init(_ fields: [String: Any] = [:]) {
        func number(_ key: String, _ fallback: Double) -> Double {
            let value = (fields[key] as? NSNumber)?.doubleValue ?? Double(fields[key] as? String ?? "") ?? fallback
            return value.isFinite ? value : fallback
        }
        grow = max(0, number("layout_flexGrow", 0))
        shrink = max(0, number("layout_flexShrink", 1))
        basisPercent = number("layout_flexBasisPercent", -1)
        alignSelf = fields["layout_alignSelf"] as? String ?? "auto"
        justifySelf = fields["layout_justifySelf"] as? String ?? "auto"
        wrapBefore = (fields["layout_wrapBefore"] as? Bool) ?? (fields["layout_wrapBefore"] as? String == "true")
    }
}

struct ExploreCategory: Identifiable, Equatable {
    var id: String { title + "|" + url }
    var title: String
    var url: String
    var type = "url"
    var action: String? = nil
    var chars: [String]? = nil
    var defaultValue: String? = nil
    var viewName: String? = nil
    var style = ExploreStyle()
    var displayTitle: String? = nil
    var displayError: String? = nil
    var diagnosticMessage: String? { type == "url" && title.hasPrefix("ERROR:") ? url : nil }
    var canNavigate: Bool { type == "url" && diagnosticMessage == nil && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var choices: [String] { chars ?? ["chars", "is null"] }

    static func parse(_ text: String) -> [ExploreCategory] {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        // JSON must win: URLs, labels and scripts can themselves contain :: or &&.
        if raw.hasPrefix("[") {
            guard let data = raw.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [[String: Any]] else { return [] }
            return rows.map { row in
                ExploreCategory(title: row["title"] as? String ?? "", url: row["url"] as? String ?? "",
                                type: row["type"] as? String ?? "url", action: row["action"] as? String,
                                chars: (row["chars"] as? [Any])?.compactMap { $0 as? String },
                                defaultValue: row["default"] as? String, viewName: row["viewName"] as? String,
                                style: ExploreStyle(row["style"] as? [String: Any] ?? [:]))
            }
        }
        // Retain section labels without URLs, and duplicate entries in source order.
        if raw.contains("::") || raw.contains("&&") || raw.contains("\n") || !raw.hasPrefix("http") && !raw.hasPrefix("/") {
            return raw.replacingOccurrences(of: "&&", with: "\n").components(separatedBy: .newlines).compactMap { line in
                let line = line.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { return nil }
                guard let separator = line.range(of: "::") else { return ExploreCategory(title: line, url: "") }
                return ExploreCategory(title: String(line[..<separator.lowerBound]), url: String(line[separator.upperBound...]))
            }
        }
        return [ExploreCategory(title: "推荐", url: raw)]
    }
}

enum ExploreSources {
    static func groups(_ sources: [LegadoSource]) -> [String] {
        Array(Set(sources.filter { $0.enabledExplore && !$0.effectiveDiscoverUrl.isEmpty }
            .flatMap { groupNames($0.bookSourceGroup) })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    static func groupNames(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    static func filter(_ sources: [LegadoSource], query: String = "", group: String? = nil) -> [LegadoSource] {
        sources.enumerated().filter { _, source in
            source.enabledExplore && !source.effectiveDiscoverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                (group == nil || groupNames(source.bookSourceGroup).contains(group!)) &&
                (query.isEmpty || source.bookSourceName.localizedCaseInsensitiveContains(query) || source.bookSourceGroup.localizedCaseInsensitiveContains(query))
        }.sorted { a, b in a.element.customOrder == b.element.customOrder ? a.offset < b.offset : a.element.customOrder < b.element.customOrder }.map(\.element)
    }
}

// No JSValue crosses a worker boundary. Every map operation is atomic and scoped
// to the original source URL; scripts and all five discovery controls share it.
enum ExploreInfo {
    private static let lock = NSLock()
    private static var maps: [String: [String: String]] = [:]
    private static var saves: [String: Int] = [:]
    private static var revisions: [String: Int] = [:]
    private static func load(_ source: String) -> [String: String] {
        if let map = maps[source] { return map }
        let record = UserDefaults.standard.dictionary(forKey: "explore.info." + source) ?? [:]
        let expiry = record["expiry"] as? Double ?? 0
        let map = expiry == 0 || expiry > Date().timeIntervalSince1970 ? record["map"] as? [String: String] ?? [:] : [:]
        maps[source] = map
        return map
    }
    static func value(_ source: String, _ key: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return load(source)[key] ?? ""
    }
    static func put(_ source: String, _ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        var map = load(source); map[key] = value; maps[source] = map
    }
    static func revision(_ source: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return revisions[source] ?? 0
    }
    static func refresh(_ source: String) {
        lock.lock(); defer { lock.unlock() }; revisions[source, default: 0] += 1
    }
    static func savePending(_ source: String) {
        lock.lock(); defer { lock.unlock() }
        if let seconds = saves.removeValue(forKey: source) { persist(source, seconds) }
    }
    private static func persist(_ source: String, _ seconds: Int) {
        UserDefaults.standard.set(["map": load(source), "expiry": seconds > 0 ? Date().timeIntervalSince1970 + Double(seconds) : 0], forKey: "explore.info." + source)
    }
    static func bridge(_ source: String, _ operation: String, _ payload: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let args = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [Any] ?? []
        let key = args.first as? String ?? ""
        var map = load(source)
        var result: Any = NSNull()
        switch operation {
        case "get": result = args.isEmpty ? map : map[key] as Any? ?? NSNull()
        case "put": result = map[key] as Any? ?? NSNull(); map[key] = args.count > 1 ? args[1] as? String ?? "" : ""
        case "remove": result = map.removeValue(forKey: key) as Any? ?? NSNull()
        case "clear": map = [:]
        case "set", "putAll":
            if let incoming = args.first as? [String: String] { map = operation == "set" ? incoming : map.merging(incoming) { _, new in new } }
        case "save":
            if args.count < 2 || (args[1] as? Bool ?? true) { saves[source] = (args.first as? Int) ?? 0 }
            else { saves.removeValue(forKey: source) }
        case "saveNow": persist(source, saves.removeValue(forKey: source) ?? 0)
        default: break
        }
        maps[source] = map
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed, .sortedKeys]) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
    }
}

extension LegadoSource {
    var exploreCacheKey: String {
        // Include script dependencies, not only exploreUrl. A successful refresh
        // must also bypass this key when a control calls refreshExplore().
        [bookSourceUrl, effectiveDiscoverUrl, jsLib, header, bookSourceComment, variableComment ?? "", loginUrl].joined(separator: "\u{0}")
    }
    func resolvedExploreCategories() async throws -> [ExploreCategory] {
        try await withTimeout(30) {
            try await self.withRules {
                var categories = self.exploreCategories()
                for index in categories.indices {
                    try Task.checkCancellation()
                    let category = categories[index]
                    if (category.type == "toggle" || category.type == "select"), ExploreInfo.value(self.bookSourceUrl, category.title).isEmpty {
                        ExploreInfo.put(self.bookSourceUrl, category.title, category.defaultValue ?? category.choices.first ?? "")
                    }
                    if let name = category.viewName {
                        if (3...19).contains(name.count), name.hasPrefix("'"), name.hasSuffix("'") {
                            categories[index].displayTitle = String(name.dropFirst().dropLast())
                        } else {
                            // A bad display-name script must not discard the
                            // source's otherwise usable category URLs.
                            let failures = RuleFailures()
                            let title = LegadoJSCtx.$failures.withValue(failures) { self.runExploreScript(name) }
                            categories[index].displayTitle = title.isEmpty ? "null" : title
                            do { try failures.check() }
                            catch {
                                try Task.checkCancellation()
                                if let deadline = LegadoJSCtx.deadline, deadline <= Date() { throw error }
                                categories[index].displayTitle = "err"
                                categories[index].displayError = "分类「\(category.title)」名称脚本：" + sourceErrorMessage(error)
                            }
                        }
                    }
                }
                try LegadoJSCtx.failures?.check()
                guard !categories.isEmpty else { throw SourceFailure(stage: "发现分类", message: "规则未返回分类", url: self.bookSourceUrl) }
                return categories
            }
        }
    }
    func performExploreAction(_ category: ExploreCategory) async throws -> Bool {
        guard let action = category.action, !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return try await withTimeout(30) {
            try await self.withRules {
                let before = ExploreInfo.revision(self.bookSourceUrl)
                _ = self.runExploreScript(action)
                try LegadoJSCtx.failures?.check()
                return before != ExploreInfo.revision(self.bookSourceUrl)
            }
        }
    }
    private func runExploreScript(_ script: String) -> String {
        LegadoJS.run(script, input: "", baseUrl: bookSourceUrl, sourceKey: bookSourceUrl, sourceUrl: bookSourceUrl)
    }
}
