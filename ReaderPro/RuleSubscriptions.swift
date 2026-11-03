import SwiftUI

struct RuleSubscription: ManagedReaderRule {
    var id = Int64(Date().timeIntervalSince1970 * 1000)
    var name = "规则订阅"
    var url = ""
    var type = 0
    var customOrder = 0
    var autoUpdate = false
    var update: Int64 = 0
    var updateInterval = 24
    var silentUpdate = false
    var js: String? = nil
    var showRule: String? = nil
    var sourceUrl: String? = nil
    var active: Bool { get { autoUpdate } set { autoUpdate = newValue } }
    static var empty: Self { Self() }
    enum CodingKeys: String, CodingKey { case id, name, url, type, customOrder, autoUpdate, update, updateInterval, silentUpdate, js, showRule, sourceUrl }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? c.decode(Int64.self, forKey: .id) { id = value }
        name = c.tolerantString(.name); url = c.tolerantString(.url); type = c.tolerantInt(.type)
        customOrder = c.tolerantInt(.customOrder); autoUpdate = c.tolerantBool(.autoUpdate, defaultValue: false)
        update = (try? c.decode(Int64.self, forKey: .update)) ?? 0
        updateInterval = (try? c.decode(Int.self, forKey: .updateInterval)) ?? 24
        silentUpdate = c.tolerantBool(.silentUpdate, defaultValue: false)
        js = try? c.decode(String.self, forKey: .js); showRule = try? c.decode(String.self, forKey: .showRule); sourceUrl = try? c.decode(String.self, forKey: .sourceUrl)
    }
    func validate() throws {
        guard !name.isEmpty, isSourceURL(url), [0, 1, 2, 3].contains(type), updateInterval >= 0 else {
            throw SourceFailure(stage: "规则订阅", message: "请填写名称、HTTP(S) 地址、类型和有效的更新间隔")
        }
    }
    func isDue(at date: Date = Date()) -> Bool { autoUpdate && date.timeIntervalSince1970 * 1000 >= Double(update) + Double(updateInterval) * 3_600_000 }
}

@MainActor final class RuleSubscriptionStore: ObservableObject {
    static let shared = RuleSubscriptionStore()
    @Published var subscriptions: [RuleSubscription] {
        didSet {
            defaults.set(try? JSONEncoder().encode(subscriptions), forKey: "rules.subscriptions")
            let ids = Set(subscriptions.map(\.id)); staged = staged.filter { ids.contains($0.key) }; pending = pending.filter { ids.contains($0.key) }
        }
    }
    @Published private(set) var running = false
    @Published private(set) var status: [Int64: String] = [:]
    @Published private(set) var pending: [Int64: Int] = [:]
    private let defaults: UserDefaults
    private enum Payload: Codable {
        case sources(SourcePackImportResult), replacements([ReplaceRule])
        enum CodingKeys: String, CodingKey { case bookSources, rssSources, replacements }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if c.contains(.replacements) { self = .replacements(try c.decode([ReplaceRule].self, forKey: .replacements)) }
            else {
                var document = SourcePackImportResult()
                document.sources = try c.decode([LegadoSource].self, forKey: .bookSources)
                document.rssSources = try c.decode([RssSource].self, forKey: .rssSources); self = .sources(document)
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .sources(let document): try c.encode(document.sources, forKey: .bookSources); try c.encode(document.rssSources, forKey: .rssSources)
            case .replacements(let rules): try c.encode(rules, forKey: .replacements)
            }
        }
        var count: Int { switch self { case .sources(let document): return document.sources.count + document.rssSources.count; case .replacements(let rules): return rules.count } }
    }
    private var staged: [Int64: Payload] = [:] {
        didSet { defaults.set(try? JSONEncoder().encode(staged), forKey: "rules.pendingUpdates") }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        subscriptions = defaults.data(forKey: "rules.subscriptions").flatMap { try? JSONDecoder().decode([RuleSubscription].self, from: $0) } ?? []
        let ids = Set(subscriptions.map(\.id))
        staged = (defaults.data(forKey: "rules.pendingUpdates").flatMap { try? JSONDecoder().decode([Int64: Payload].self, from: $0) } ?? [:]).filter { ids.contains($0.key) }
        pending = staged.mapValues(\.count)
    }

    func updateDue(store: BookStore) async { await update(subscriptions.filter { $0.isDue() }, store: store, manual: false) }
    func update(_ items: [RuleSubscription], store: BookStore, manual: Bool = true) async {
        guard !running else { return }; running = true; defer { running = false }
        for subscription in items {
            guard !Task.isCancelled else { return }
            status[subscription.id] = "正在检查…"
            let boundSource = store.sources.first { $0.bookSourceUrl == subscription.sourceUrl } ?? LegadoSource()
            do {
                let downloaded = try await Task.detached(priority: .utility) {
                    try await withTimeout(90) {
                        var engine = boundSource
                        if engine.bookSourceUrl.isEmpty { engine.bookSourceUrl = subscription.url }
                        return try await engine.withRules {
                            var address = subscription.url
                            if let js = subscription.js, !js.isEmpty {
                                let output = LegadoJS.run(sourceScriptBody(js), input: address, baseUrl: address, sourceKey: "", sourceUrl: engine.bookSourceUrl)
                                if !output.isEmpty { address = output }
                            }
                            let noUA = address.hasSuffix("#requestWithoutUA")
                            if noUA { address = String(address.dropLast("#requestWithoutUA".count)) }
                            var request = try SourceHTTP.request(address, base: engine.bookSourceUrl, headers: engine.requestHeaders)
                            if noUA { request.setValue("", forHTTPHeaderField: "User-Agent") }
                            let response = try await SourceHTTP.load(request, stage: "规则订阅")
                            let text: String
                            if let rule = subscription.showRule, !rule.isEmpty { text = applyRule(response.text, rule, base: response.url).joined(separator: "\n") }
                            else { text = response.text }
                            if subscription.type == 2 || subscription.type == 3 { return Payload.replacements(try ReplacementRuleDocument.decode(Data(text.utf8))) }
                            let imported = importSourceDocument(text)
                            var document = SourcePackImportResult()
                            if subscription.type == 0 { document.sources = imported.sources } else { document.rssSources = imported.rssSources }
                            guard !document.isEmpty else { throw SourceFailure(stage: "规则订阅", message: "地址没有返回对应类型的规则") }
                            return Payload.sources(document)
                        }
                    }
                }.value
                guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { continue }
                subscriptions[index].update = Int64(Date().timeIntervalSince1970 * 1000)
                let payload = changed(downloaded, store: store), count = payload.count
                guard count > 0 else {
                    staged[subscription.id] = nil; pending[subscription.id] = nil; status[subscription.id] = "规则没有变化"; continue
                }
                if manual || subscription.silentUpdate {
                    apply(payload, store: store); status[subscription.id] = "已更新 \(count) 条规则"; staged[subscription.id] = nil; pending[subscription.id] = nil
                } else {
                    staged[subscription.id] = payload; pending[subscription.id] = count; status[subscription.id] = "发现 \(count) 条规则，等待应用"
                }
            } catch { status[subscription.id] = "更新失败：" + sourceErrorMessage(error) }
        }
    }
    func applyPending(_ id: Int64, store: BookStore) {
        guard let payload = staged.removeValue(forKey: id) else { return }
        apply(payload, store: store); status[id] = "已应用 \(pending[id] ?? 0) 条规则"; pending[id] = nil
    }
    private func changed(_ payload: Payload, store: BookStore) -> Payload {
        switch payload {
        case .sources(var document):
            document.sources = document.sources.filter { incoming in
                guard let old = store.sources.first(where: { $0.bookSourceUrl == incoming.bookSourceUrl }) else { return true }
                var copy = incoming; copy.id = old.id; copy.enabled = old.enabled; copy.enabledExplore = old.enabledExplore; copy.customOrder = old.customOrder; copy.bookSourceGroup = old.bookSourceGroup
                return copy != old
            }
            document.rssSources = document.rssSources.filter { incoming in
                guard let old = store.rssSources.first(where: { $0.sourceUrl == incoming.sourceUrl }) else { return true }
                var copy = incoming; copy.id = old.id; copy.enabled = old.enabled; copy.articleStyle = old.articleStyle; copy.customOrder = old.customOrder; copy.sourceGroup = old.sourceGroup
                return copy != old
            }
            return .sources(document)
        case .replacements(let rules):
            return .replacements(rules.filter { incoming in
                guard let old = store.replaceRules.first(where: { $0.id == incoming.id || ($0.name == incoming.name && $0.pattern == incoming.pattern) }) else { return true }
                var copy = incoming; copy.id = old.id; copy.enabled = old.enabled; copy.order = old.order
                return copy != old
            })
        }
    }
    private func apply(_ payload: Payload, store: BookStore) {
        switch payload {
        case .sources(var document):
            document.sources = document.sources.map { incoming in
                guard let old = store.sources.first(where: { $0.bookSourceUrl == incoming.bookSourceUrl }) else { return incoming }
                var copy = incoming; copy.enabled = old.enabled; copy.enabledExplore = old.enabledExplore; copy.customOrder = old.customOrder; copy.bookSourceGroup = old.bookSourceGroup; return copy
            }
            _ = store.mergeImportedSources(document)
        case .replacements(let rules):
            for rule in rules {
                if let index = store.replaceRules.firstIndex(where: { $0.id == rule.id || ($0.name == rule.name && $0.pattern == rule.pattern) }) {
                    var copy = rule; copy.id = store.replaceRules[index].id; copy.enabled = store.replaceRules[index].enabled; copy.order = store.replaceRules[index].order
                    store.replaceRules[index] = copy
                } else { store.replaceRules.append(rule) }
            }
            store.save()
        }
    }
}

struct RuleSubscriptionsView: View {
    @ObservedObject var store: BookStore
    @ObservedObject private var subscriptions = RuleSubscriptionStore.shared
    var body: some View {
        List {
            NavigationLink("管理订阅地址 / 导入开源阅读规则订阅") { ReaderRuleLibraryView(title: "规则订阅", rules: $subscriptions.subscriptions) }
            Text("类型：0 书源、1 订阅源、2/3 替换规则。更新间隔单位为小时。自动更新在打开应用时检查；关闭静默更新时，先检查再手动应用。").font(.caption).foregroundStyle(.secondary)
            ForEach(subscriptions.subscriptions) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name).font(.headline)
                    Text(subscriptions.status[item.id] ?? (item.update == 0 ? "尚未更新" : "上次检查：" + Date(timeIntervalSince1970: Double(item.update) / 1000).formatted())).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("立即更新") { Task { await subscriptions.update([item], store: store) } }.disabled(subscriptions.running)
                        if subscriptions.pending[item.id] != nil { Button("应用更新") { subscriptions.applyPending(item.id, store: store) } }
                    }.buttonStyle(.borderless)
                }
            }
        }.navigationTitle("规则订阅")
        .toolbar { Button("全部更新") { Task { await subscriptions.update(subscriptions.subscriptions, store: store) } }.disabled(subscriptions.running) }
    }
}
