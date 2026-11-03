import SwiftUI
import CryptoKit

enum SourceVariableStore {
    static func get(_ source: String) -> String { UserDefaults.standard.string(forKey: "ReaderPro.sourceVariable." + source) ?? "" }
    static func put(_ value: String, source: String) { UserDefaults.standard.set(value, forKey: "ReaderPro.sourceVariable." + source) }
}

extension LocalBook {
    var sourceBook: SourceBook {
        let original = chapters.compactMap(\.ruleBook).first
        var result = SourceBook(title: title, author: author, url: bookUrl.isEmpty ? original?.bookUrl ?? "" : bookUrl,
                                cover: coverUrl, sourceName: sourceName, sourceUrl: sourceUrl)
        result.tocUrl = tocUrl.isEmpty ? original?.tocUrl : tocUrl
        return result
    }
    func refreshingDirectory(_ chapters: [BookChapter]) -> LocalBook {
        var updated = self
        var cache: [String: BookChapter] = [:]
        for chapter in self.chapters { if let url = chapter.url, !url.isEmpty { cache[url] = chapter } }
        updated.chapters = chapters.map { chapter in
            var copy = chapter
            if let url = copy.url, let old = cache[url] {
                if !old.text.isEmpty && !old.text.hasPrefix("__URL__") { copy.text = old.text }
                if !old.imageUrls.isEmpty { copy.imageUrls = old.imageUrls }
            }
            return copy
        }
        let old = self.chapters.indices.contains(chapterIndex) ? self.chapters[chapterIndex] : nil
        let position = old?.url.flatMap { address in chapters.firstIndex { $0.url == address } }
            ?? old.flatMap { old in chapters.firstIndex { $0.title == old.title && !$0.isVolume } }
            ?? boundedReadingIndex(chapterIndex, count: chapters.count)
        updated.chapterIndex = chapters.readableIndex(from: position) ?? chapters.readableIndex(from: position, direction: -1) ?? 0
        return updated
    }
}

final class ShelfGroups: ObservableObject {
    static let shared = ShelfGroups()
    @Published var names: [String] { didSet { UserDefaults.standard.set(names, forKey: "shelf.groups") } }
    init() { names = UserDefaults.standard.stringArray(forKey: "shelf.groups") ?? [] }
}

struct ShelfGroupsView: View {
    @ObservedObject var store: BookStore
    @ObservedObject private var groups = ShelfGroups.shared
    @State private var name = ""
    @State private var rename = ""
    @State private var selected: String?
    private var names: [String] { Array(Set(groups.names + store.books.map(\.group).filter { !$0.isEmpty })).sorted() }
    var body: some View {
        List {
            HStack {
                TextField("新分组名称", text: $name)
                Button("创建") {
                    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty && !names.contains(value) { groups.names.append(value); name = "" }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(names, id: \.self) { group in
                HStack { Text(group); Spacer(); Text("\(store.books.filter { $0.group == group }.count) 本").foregroundStyle(.secondary) }
                    .contextMenu { Button("重命名") { rename = group; selected = group } }
            }.onDelete { offsets in
                let removed = Set(offsets.map { names[$0] })
                groups.names.removeAll { removed.contains($0) }
                for i in store.books.indices where removed.contains(store.books[i].group) { store.books[i].group = "" }
                store.saveBooks()
            }
        }.navigationTitle("书架分组")
        .alert("重命名分组", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            TextField("名称", text: $rename)
            Button("取消", role: .cancel) { selected = nil }
            Button("保存") {
                guard let old = selected else { return }
                let value = rename.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return }
                groups.names.removeAll { $0 == old }; if !groups.names.contains(value) { groups.names.append(value) }
                for i in store.books.indices where store.books[i].group == old { store.books[i].group = value }
                store.saveBooks(); selected = nil
            }
        }
    }
}

@MainActor final class ShelfRefreshModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var message = ""
    @Published private(set) var failures = ""
    private var task: Task<Void, Never>?
    func start(store: BookStore) {
        guard !running else { return }
        running = true; failures = ""
        let books = store.books.filter { !$0.sourceUrl.isEmpty && !$0.sourceBook.url.isEmpty }
        task = Task {
            defer { running = false }
            var added = 0
            var notified: [LegadoSource] = []
            var stopped = false
            for (index, book) in books.enumerated() {
                guard !Task.isCancelled else { stopped = true; break }
                guard let source = store.sourceForBook(book) else { continue }
                if source.eventListener && !notified.contains(where: { $0.bookSourceUrl == source.bookSourceUrl }) {
                    notified.append(source)
                    await Task.detached { await source.callSourceEvent("startShelfRefresh") }.value
                }
                message = "正在刷新 \(index + 1)/\(books.count)：\(book.title)"
                let worker = Task.detached { try await withTimeout(60) { try await source.fetchChapters(book: book.sourceBook) } }
                do {
                    let chapters = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    guard !chapters.isEmpty, let i = store.books.firstIndex(where: { $0.id == book.id }), store.books[i].sourceUrl == book.sourceUrl else { continue }
                    let current = store.books[i]
                    added += max(0, chapters.filter { !$0.isVolume }.count - current.chapters.filter { !$0.isVolume }.count)
                    store.books[i] = current.refreshingDirectory(chapters); store.saveBooks()
                } catch { if !Task.isCancelled { failures += (failures.isEmpty ? "" : "\n") + book.title + "：" + sourceErrorMessage(error) } }
            }
            for source in notified { await Task.detached { await source.callSourceEvent("endShelfRefresh") }.value }
            message = stopped || Task.isCancelled ? "已停止刷新" : "刷新完成，新增 \(added) 章" + (failures.isEmpty ? "" : "，部分书籍刷新失败")
        }
    }
    func cancel() { task?.cancel() }
}

struct BookInfoEditorView: View {
    @ObservedObject var store: BookStore
    @State var book: LocalBook
    @State private var variables = "{}"
    @State private var sourceVariables = ""
    @State private var error = ""
    @Environment(\.dismiss) private var dismiss
    private var variableKey: String { "ReaderPro.bookVariables." + SHA256.hash(data: Data((book.sourceUrl + "\n" + book.sourceBook.url).utf8)).map { String(format: "%02x", $0) }.joined() }
    var body: some View {
        Form {
            Section("书籍信息") {
                TextField("书名", text: $book.title); TextField("作者", text: $book.author)
                TextField("封面地址", text: $book.coverUrl).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("分组", text: $book.group)
                if !book.sourceUrl.isEmpty {
                    TextField("书籍地址", text: $book.bookUrl).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("目录地址", text: $book.tocUrl).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            if !book.sourceUrl.isEmpty {
                Section("书籍变量（字符串 JSON 字典）") { TextEditor(text: $variables).frame(minHeight: 110).font(.system(.footnote, design: .monospaced)) }
                Section("书源自定义变量") { TextEditor(text: $sourceVariables).frame(minHeight: 80).font(.system(.footnote, design: .monospaced)) }
            }
        }.navigationTitle("编辑书籍")
        .toolbar {
            Button("取消") { dismiss() }
            Button("保存") {
                do {
                    guard !book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceFailure(stage: "书籍", message: "书名不能为空") }
                    let values = try JSONDecoder().decode([String: String].self, from: Data(variables.utf8))
                    UserDefaults.standard.set(values, forKey: variableKey)
                    SourceVariableStore.put(sourceVariables, source: book.sourceUrl)
                    if !book.group.isEmpty && !ShelfGroups.shared.names.contains(book.group) { ShelfGroups.shared.names.append(book.group) }
                    store.updateBook(book); dismiss()
                } catch { self.error = sourceErrorMessage(error) }
            }
        }
        .onAppear {
            book.bookUrl = book.sourceBook.url; book.tocUrl = book.sourceBook.tocUrl ?? ""
            let values = UserDefaults.standard.dictionary(forKey: variableKey) as? [String: String] ?? [:]
            variables = (try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            sourceVariables = SourceVariableStore.get(book.sourceUrl)
        }
        .alert("保存失败", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) { Button("确定") { error = "" } } message: { Text(error) }
    }
}
