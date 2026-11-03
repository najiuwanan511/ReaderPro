import SwiftUI

protocol ManagedReaderRule: Codable, Identifiable where ID: Hashable {
    var name: String { get set }
    var active: Bool { get set }
    static var empty: Self { get }
    func validate() throws
}

struct TxtTocRule: ManagedReaderRule {
    var id = Int64(Date().timeIntervalSince1970 * 1000)
    var name = "新目录规则"
    var rule = ""
    var replacement = ""
    var example: String? = nil
    var serialNumber = 0
    var enable = true
    var active: Bool { get { enable } set { enable = newValue } }
    static var empty: Self { Self() }
    enum CodingKeys: String, CodingKey { case id, name, rule, replacement, example, serialNumber, enable }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? c.decode(Int64.self, forKey: .id) { id = value }
        name = c.tolerantString(.name); rule = c.tolerantString(.rule); replacement = c.tolerantString(.replacement)
        example = try? c.decode(String.self, forKey: .example); serialNumber = c.tolerantInt(.serialNumber)
        enable = c.tolerantBool(.enable, defaultValue: true)
    }
    func validate() throws {
        guard !name.isEmpty, !rule.isEmpty else { throw SourceFailure(stage: "目录规则", message: "名称和正则不能为空") }
        _ = try NSRegularExpression(pattern: rule)
    }
}

struct DictRule: ManagedReaderRule {
    var name = "新字典"
    var urlRule = "https://www.baidu.com/s?wd={{key}}"
    var showRule = ""
    var enabled = true
    var sortNumber = 0
    var id: String { name }
    var active: Bool { get { enabled } set { enabled = newValue } }
    static var empty: Self { Self() }
    enum CodingKeys: String, CodingKey { case name, urlRule, showRule, enabled, sortNumber }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.tolerantString(.name); urlRule = c.tolerantString(.urlRule); showRule = c.tolerantString(.showRule)
        enabled = c.tolerantBool(.enabled, defaultValue: true); sortNumber = c.tolerantInt(.sortNumber)
    }
    func validate() throws {
        guard !name.isEmpty, !urlRule.isEmpty else { throw SourceFailure(stage: "字典规则", message: "名称和地址规则不能为空") }
    }
    func lookup(_ word: String) async throws -> String {
        var source = LegadoSource(); source.bookSourceName = name; source.bookSourceUrl = SourceHTTP.options(urlRule).url
        return try await withTimeout(30) {
            try await source.withRules {
                try await LegadoJSCtx.$key.withValue(word) {
                    let response = try await source.loadPage(urlRule, key: word, stage: "字典查询")
                    return showRule.isEmpty ? response.text : applyRule(response.text, showRule, base: response.url).joined(separator: "\n")
                }
            }
        }
    }
}

final class ReaderRuleLibrary: ObservableObject {
    static let shared = ReaderRuleLibrary()
    private let defaults: UserDefaults
    @Published var txtRules: [TxtTocRule] { didSet { persist(txtRules, key: "reader.txtRules") } }
    @Published var dictionaries: [DictRule] { didSet { persist(dictionaries, key: "reader.dictionaries") } }
    @Published var httpTts: [HttpTTS] { didSet { persist(httpTts, key: "reader.httpTts") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        txtRules = defaults.data(forKey: "reader.txtRules").flatMap { try? JSONDecoder().decode([TxtTocRule].self, from: $0) } ?? []
        dictionaries = defaults.data(forKey: "reader.dictionaries").flatMap { try? JSONDecoder().decode([DictRule].self, from: $0) } ?? []
        httpTts = defaults.data(forKey: "reader.httpTts").flatMap { try? JSONDecoder().decode([HttpTTS].self, from: $0) } ?? []
    }
    private func persist<T: Encodable>(_ value: T, key: String) { defaults.set(try? JSONEncoder().encode(value), forKey: key) }
}

struct ReaderRuleLibraryView<Rule: ManagedReaderRule>: View {
    let title: String
    @Binding var rules: [Rule]
    @State private var editing: Rule?
    @State private var code = ""
    @State private var importing = false
    @State private var importText = ""
    @State private var error = ""
    @State private var query = ""
    var body: some View {
        List {
            if rules.isEmpty { Text("暂无规则，可新建或导入开源阅读 JSON").foregroundStyle(.secondary) }
            ForEach(rules.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { rule in
                HStack {
                    Button(rule.name) { edit(rule) }.foregroundStyle(.primary)
                    Spacer()
                    Toggle("启用", isOn: Binding(get: { rule.active }, set: { enabled in
                        if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i].active = enabled }
                    })).labelsHidden()
                }.contextMenu {
                    Button("编辑") { edit(rule) }
                    Button("删除", role: .destructive) { rules.removeAll { $0.id == rule.id } }
                }
            }.onDelete { offsets in
                let visible = rules.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                let ids = Set(offsets.map { visible[$0].id }); rules.removeAll { ids.contains($0.id) }
            }
        }
        .navigationTitle(title).searchable(text: $query, prompt: "搜索规则")
        .toolbar {
            Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }.accessibilityLabel("导入规则")
            ShareLink(item: encoded(rules)) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("导出规则")
            Button { edit(Rule.empty) } label: { Image(systemName: "plus") }
        }
        .sheet(item: $editing) { original in
            NavigationStack {
                CodeEditorView(title: "编辑" + title, code: $code, onSave: {
                    do {
                        let updated = try JSONDecoder().decode(Rule.self, from: Data(code.utf8)); try updated.validate()
                        guard !rules.contains(where: { $0.id == updated.id && $0.id != original.id }) else { throw SourceFailure(stage: title, message: "存在同名或同 ID 规则") }
                        if let i = rules.firstIndex(where: { $0.id == original.id }) { rules[i] = updated } else { rules.append(updated) }
                        editing = nil
                    } catch { self.error = sourceErrorMessage(error) }
                })
                .alert("保存失败", isPresented: hasError) { Button("确定") { error = "" } } message: { Text(error) }
            }
        }
        .sheet(isPresented: $importing) {
            NavigationStack {
                VStack { TextEditor(text: $importText).font(.system(.footnote, design: .monospaced)).padding(); Text("粘贴 JSON 数组，或输入规则文件网址").font(.caption).foregroundStyle(.secondary) }
                    .navigationTitle("导入" + title)
                    .toolbar {
                        Button("取消") { importing = false }
                        Button("导入") { Task { await importRules() } }.disabled(importText.isEmpty)
                    }
                    .alert("导入失败", isPresented: hasError) { Button("确定") { error = "" } } message: { Text(error) }
            }
        }
    }
    private var hasError: Binding<Bool> { Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } }) }
    private func encoded<T: Encodable>(_ value: T) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    private func edit(_ rule: Rule) { code = encoded(rule); editing = rule }
    @MainActor private func importRules() async {
        do {
            let text = importText.trimmingCharacters(in: .whitespacesAndNewlines)
            let data = isSourceURL(text) ? try await fetchBytes(text) : Data(text.utf8)
            let items: [Rule]
            if let array = try? JSONDecoder().decode([Rule].self, from: data) { items = array }
            else { items = [try JSONDecoder().decode(Rule.self, from: data)] }
            for item in items { try item.validate() }
            for item in items {
                if let i = rules.firstIndex(where: { $0.id == item.id }) { rules[i] = item } else { rules.append(item) }
            }
            importing = false; importText = ""
        } catch { self.error = sourceErrorMessage(error) }
    }
}

struct DictionaryLookupView: View {
    let word: String
    @ObservedObject private var library = ReaderRuleLibrary.shared
    @State private var output = ""
    @State private var loading = false
    @State private var error = ""
    var body: some View {
        VStack {
            if loading { ProgressView("正在查词…") }
            if !error.isEmpty { Text(error).foregroundStyle(.red).padding() }
            if !output.isEmpty { FeedHTMLView(html: output, baseURL: "", type: 0) }
            List {
                Button("系统词典") { output = ""; SystemDictionaryPresenter.present(word) }
                ForEach(library.dictionaries.filter(\.enabled).sorted { $0.sortNumber < $1.sortNumber }) { rule in
                    Button(rule.name) {
                        Task {
                            loading = true; error = ""
                            do { output = try await rule.lookup(word) } catch { self.error = sourceErrorMessage(error) }
                            loading = false
                        }
                    }
                }
            }.frame(maxHeight: output.isEmpty ? .infinity : 180)
        }.navigationTitle(word)
    }
}

enum SystemDictionaryPresenter {
    @MainActor static func present(_ word: String) {
        guard var controller = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = controller.presentedViewController { controller = presented }
        controller.present(UIReferenceLibraryViewController(term: word), animated: true)
    }
}
