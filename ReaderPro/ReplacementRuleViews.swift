import SwiftUI
import UniformTypeIdentifiers
import UIKit

private struct ReplacementRuleFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ReplaceRuleView: View {
    @ObservedObject var store: BookStore
    var bookID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showSearch = false
    @State private var filter = "全部"
    @State private var selection = Set<String>()
    @State private var editing: ReplaceRule?
    @State private var importing = false
    @State private var importText = ""
    @State private var importFile = false
    @State private var busy = false
    @State private var exporting = false
    @State private var exportData = Data()
    @State private var message = ""

    private var visible: [ReplaceRule] {
        store.replaceRules.filter { rule in
            let matches = query.isEmpty || [rule.name, rule.group, rule.pattern, rule.scope].contains { $0.localizedCaseInsensitiveContains(query) }
            let group = filter == "全部" || (filter == "启用" && rule.enabled) || (filter == "禁用" && !rule.enabled)
                || (filter == "未分组" && rule.group.isEmpty) || filter == "分组：" + rule.group
            return matches && group
        }
    }
    private var selectedRules: [ReplaceRule] { selection.isEmpty ? store.replaceRules : store.replaceRules.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            if showSearch {
                TextField("搜索规则名称、分组、内容或范围", text: $query).textFieldStyle(.roundedBorder).padding()
                    .accessibilityIdentifier("replacementRuleSearch")
            }
            if let bookID {
                Toggle("本书启用替换净化", isOn: Binding(get: {
                    store.books.first { $0.id == bookID }?.useReplaceRule ?? true
                }, set: { enabled in
                    if var book = store.books.first(where: { $0.id == bookID }) { book.useReplaceRule = enabled; store.updateBook(book) }
                })).padding(.horizontal).padding(.vertical, 10)
            }
            List {
                ForEach(visible) { rule in ruleRow(rule) }
                .onMove { from, to in
                    guard query.isEmpty, filter == "全部" else { return }
                    store.replaceRules.move(fromOffsets: from, toOffset: to)
                    for i in store.replaceRules.indices { store.replaceRules[i].order = i }
                    store.save()
                }
                if visible.isEmpty { Text("暂无替换规则，点右上角 + 新建，或从菜单导入。").foregroundStyle(.secondary) }
            }.listStyle(.plain)
            if !selection.isEmpty { selectionBar }
        }
        .navigationTitle("替换净化")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showSearch.toggle(); if !showSearch { query = "" } } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索替换规则")
                Menu {
                    ForEach(["全部", "启用", "禁用", "未分组"] + Array(Set(store.replaceRules.map(\.group).filter { !$0.isEmpty })).sorted().map { "分组：" + $0 }, id: \.self) { group in
                        Button(group) { filter = group }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease") }.accessibilityLabel("筛选替换规则")
                Button {
                    var rule = ReplaceRule()
                    if let bookID { rule.scope = store.books.first { $0.id == bookID }?.title ?? "" }
                    editing = rule
                } label: { Image(systemName: "plus") }.accessibilityLabel("添加替换规则")
                Menu {
                    Button("本地导入") { importFile = true }
                    Button("网络导入") { importText = ""; importing = true }
                    Button("剪贴板导入") { loadImport(UIPasteboard.general.string ?? "") }
                    Button("导出规则") { exportRules() }
                    Button("复制规则") { copyRules(selectedRules) }
                    Button("全选当前列表") { selection = Set(visible.map(\.id)) }
                    Button("启用当前列表") { setEnabled(true, ids: Set(visible.map(\.id))) }
                    Button("禁用当前列表") { setEnabled(false, ids: Set(visible.map(\.id))) }
                    EditButton()
                } label: { Image(systemName: "ellipsis").rotationEffect(.degrees(90)) }.accessibilityLabel("替换规则更多操作")
                if bookID != nil { Button("完成") { dismiss() } }
            }
        }
        .sheet(item: $editing) { rule in NavigationStack { ReplaceRuleEditorView(store: store, rule: rule) } }
        .sheet(isPresented: $importing) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Text("粘贴开源阅读替换规则的 JSON 或网络链接")
                    TextEditor(text: $importText).font(.system(.body, design: .monospaced)).border(.secondary)
                        .accessibilityIdentifier("replacementRuleImport")
                    if busy { ProgressView("正在导入…") }
                    Button("导入") { loadImport(importText) }.buttonStyle(.borderedProminent).disabled(busy)
                }.padding().navigationTitle("导入替换规则")
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { importing = false } } }
            }
        }
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.json, .text, .data]) { result in
            do {
                let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let count = try store.importReplaceRules(Data(contentsOf: url))
                message = "已导入 \(count) 条替换规则"
            } catch { message = "导入失败：\(sourceErrorMessage(error))" }
        }
        .fileExporter(isPresented: $exporting, document: ReplacementRuleFile(data: exportData), contentType: .json, defaultFilename: "替换规则") { result in
            if case .failure(let error) = result { message = "导出失败：\(sourceErrorMessage(error))" }
        }
        .alert("替换规则", isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) {
            Button("确定") { message = "" }
        } message: { Text(message) }
    }

    private func ruleRow(_ rule: ReplaceRule) -> some View {
        HStack(spacing: 12) {
            Button { if !selection.insert(rule.id).inserted { selection.remove(rule.id) } } label: {
                Image(systemName: selection.contains(rule.id) ? "checkmark.square.fill" : "square").font(.title3)
            }.buttonStyle(.plain).accessibilityLabel("选择\(rule.name)")
            Button { editing = rule } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.group.isEmpty ? rule.name : "\(rule.name) (\(rule.group))").foregroundStyle(.primary)
                    Text("\(rule.pattern) → \(rule.replacement)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if !rule.scope.isEmpty { Text("范围：\(rule.scope)").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Toggle("启用\(rule.name)", isOn: Binding(get: { rule.enabled }, set: { setEnabled($0, ids: [rule.id]) })).labelsHidden()
            Button { editing = rule } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.plain).accessibilityLabel("编辑\(rule.name)")
            Menu {
                Button("复制规则") { copyRules([rule]) }
                Button("删除", role: .destructive) { store.replaceRules.removeAll { $0.id == rule.id }; selection.remove(rule.id); store.save() }
            } label: { Image(systemName: "ellipsis").rotationEffect(.degrees(90)) }
            .accessibilityLabel("更多\(rule.name)")
        }.padding(.vertical, 5)
    }
    private var selectionBar: some View {
        HStack {
            Button("取消 \(selection.count)") { selection = [] }
            Spacer()
            Button("启用") { setEnabled(true, ids: selection) }
            Button("禁用") { setEnabled(false, ids: selection) }
            Button("删除", role: .destructive) { store.replaceRules.removeAll { selection.contains($0.id) }; selection = []; store.save() }
        }.padding().background(AppTheme.surfaceMuted)
    }
    private func setEnabled(_ enabled: Bool, ids: Set<String>) {
        for i in store.replaceRules.indices where ids.contains(store.replaceRules[i].id) { store.replaceRules[i].enabled = enabled }
        store.save()
    }
    private func copyRules(_ rules: [ReplaceRule]) {
        do { UIPasteboard.general.string = String(data: try ReplacementRuleDocument.encode(rules), encoding: .utf8) }
        catch { message = sourceErrorMessage(error) }
    }
    private func exportRules() {
        do { exportData = try ReplacementRuleDocument.encode(selectedRules); exporting = true }
        catch { message = sourceErrorMessage(error) }
    }
    private func loadImport(_ value: String) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = isSourceURL(trimmed) ? try await withTimeout(30) { try await fetchText(urlString: trimmed) } : trimmed
                let count = try store.importReplaceRules(Data(text.utf8))
                importing = false; message = "已导入 \(count) 条替换规则"
            } catch { message = "导入失败：\(sourceErrorMessage(error))" }
        }
    }
}

struct ReplaceRuleEditorView: View {
    @ObservedObject var store: BookStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReplaceRule
    @State private var error = ""
    @State private var fullField = ""
    @State private var sample = ""
    @State private var output = ""
    init(store: BookStore, rule: ReplaceRule) { self.store = store; _draft = State(initialValue: rule) }

    var body: some View {
        Form {
            Section {
                TextField("规则说明", text: $draft.name).accessibilityIdentifier("replacementRuleName")
                TextField("分组", text: $draft.group)
                Toggle("启用", isOn: $draft.enabled)
            }
            Section("替换内容") {
                TextEditor(text: $draft.pattern).frame(minHeight: 80).font(.system(.body, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("replacementRulePattern")
                Toggle("使用正则表达式", isOn: $draft.isRegex)
            }
            Section("替换为") {
                TextEditor(text: $draft.replacement).frame(minHeight: 70).font(.system(.body, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("replacementRuleReplacement")
                Text("正则模式支持 $1、$2 等捕获组；普通文本模式按原文替换。").font(.caption).foregroundStyle(.secondary)
            }
            Section("作用范围") {
                Toggle("作用于标题", isOn: $draft.scopeTitle)
                Toggle("作用于正文", isOn: $draft.scopeContent)
                TextField("书名或书源链接，留空作用于全部", text: $draft.scope).textInputAutocapitalization(.never)
                TextField("排除范围（书名或书源链接）", text: $draft.excludeScope).textInputAutocapitalization(.never)
                TextField("超时时间（毫秒）", value: $draft.timeoutMillisecond, format: .number).keyboardType(.numberPad)
            }
            Section("测试替换") {
                TextEditor(text: $sample).frame(minHeight: 65).accessibilityIdentifier("replacementRuleSample")
                Button("测试替换") {
                    do { output = try draft.replacing(sample); error = "" }
                    catch { self.error = sourceErrorMessage(error) }
                }
                if !output.isEmpty { Text(output).textSelection(.enabled).accessibilityIdentifier("replacementRuleTestOutput") }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("编辑替换规则")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("替换内容") { fullField = "替换内容" }
                    Button("替换为") { fullField = "替换为" }
                    Button("作用范围") { fullField = "作用范围" }
                } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }.accessibilityLabel("全屏编辑")
                Button { save() } label: { Image(systemName: "square.and.arrow.down") }.accessibilityLabel("保存替换规则")
                Menu {
                    Button("复制规则") {
                        if let data = try? ReplacementRuleDocument.encode([draft]) { UIPasteboard.general.string = String(data: data, encoding: .utf8) }
                    }
                    Button("粘贴规则") {
                        do {
                            guard let rule = try ReplacementRuleDocument.decode(Data((UIPasteboard.general.string ?? "").utf8)).first else { return }
                            let id = draft.id; draft = rule; draft.id = id
                        } catch { self.error = "粘贴失败：\(sourceErrorMessage(error))" }
                    }
                } label: { Image(systemName: "ellipsis").rotationEffect(.degrees(90)) }.accessibilityLabel("规则编辑更多操作")
            }
        }
        .fullScreenCover(isPresented: Binding(get: { !fullField.isEmpty }, set: { if !$0 { fullField = "" } })) {
            NavigationStack {
                TextEditor(text: fullFieldBinding).font(.system(.body, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never).padding()
                    .navigationTitle(fullField).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { fullField = "" } } }
            }
        }
    }
    private var fullFieldBinding: Binding<String> {
        Binding(get: { fullField == "替换内容" ? draft.pattern : fullField == "替换为" ? draft.replacement : draft.scope }, set: { value in
            if fullField == "替换内容" { draft.pattern = value }
            else if fullField == "替换为" { draft.replacement = value }
            else { draft.scope = value }
        })
    }
    private func save() {
        do {
            try draft.validate()
            if draft.name.isEmpty { draft.name = String(draft.pattern.prefix(30)) }
            if let index = store.replaceRules.firstIndex(where: { $0.id == draft.id }) { store.replaceRules[index] = draft }
            else { draft.order = store.replaceRules.count; store.replaceRules.append(draft) }
            store.save(); dismiss()
        } catch { self.error = "保存失败：\(sourceErrorMessage(error))" }
    }
}
