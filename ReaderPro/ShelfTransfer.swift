import SwiftUI
import UniformTypeIdentifiers

// Legado exports a list of name/author/intro maps. Extra online addresses
// allow ReaderPro to reopen a shared list without another global search.
struct ShelfListEntry: Codable, Equatable {
    var name: String
    var author = ""
    var intro = ""
    var bookUrl = ""
    var origin = ""
    var coverUrl = ""
    enum CodingKeys: String, CodingKey { case name, author, intro, bookUrl, origin, coverUrl }
    init(name: String, author: String = "", bookUrl: String = "", origin: String = "", coverUrl: String = "") {
        self.name = name; self.author = author; self.bookUrl = bookUrl; self.origin = origin; self.coverUrl = coverUrl
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.tolerantString(.name); author = c.tolerantString(.author); intro = c.tolerantString(.intro)
        bookUrl = c.tolerantString(.bookUrl); origin = c.tolerantString(.origin); coverUrl = c.tolerantString(.coverUrl)
    }
}

enum ShelfTransfer {
    static func decode(_ data: Data) throws -> [ShelfListEntry] {
        guard data.count <= 10 * 1024 * 1024 else { throw SourceFailure(stage: "书架清单", message: "清单超过 10 MB") }
        let entries = try JSONDecoder().decode([ShelfListEntry].self, from: data)
        guard entries.count <= 10000 else { throw SourceFailure(stage: "书架清单", message: "清单超过 10000 本，请分批导入") }
        return entries.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    static func encode(_ books: [LocalBook]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(books.map { book in
            ShelfListEntry(name: book.title, author: book.author, bookUrl: book.sourceUrl.isEmpty ? "" : book.sourceBook.url,
                           origin: book.sourceUrl, coverUrl: book.coverUrl)
        })
    }
    static func matchingSources(for address: String, sources: [LegadoSource], origin: String = "") -> [LegadoSource] {
        let parsed = SourceHTTP.options(address)
        let specified = origin.isEmpty ? parsed.options["origin"] as? String ?? "" : origin
        let host = URL(string: parsed.url)?.host?.lowercased()
        func matches(_ source: LegadoSource) -> Bool {
            guard !source.bookUrlPattern.isEmpty, let regex = try? NSRegularExpression(pattern: source.bookUrlPattern) else { return false }
            let range = NSRange(address.startIndex..., in: address)
            return regex.firstMatch(in: address, range: range)?.range == range
        }
        let enabled = sources.filter(\.enabled).sorted { $0.customOrder < $1.customOrder }
        if !specified.isEmpty { return enabled.filter { $0.bookSourceUrl == specified } }
        let sameHost = enabled.filter { host != nil && URL(string: SourceHTTP.options($0.bookSourceUrl).url)?.host?.lowercased() == host }
        let patterned = enabled.filter(matches)
        var seen = Set<String>()
        return (sameHost + patterned).filter { seen.insert($0.id).inserted }
    }
    static func resolveURL(_ address: String, sources: [LegadoSource], origin: String = "") async throws -> (LegadoSource, SourceBook) {
        guard isSourceURL(SourceHTTP.options(address).url) else { throw SourceFailure(stage: "添加网址", message: "请输入 http 或 https 书籍网址") }
        let candidates = matchingSources(for: address, sources: sources, origin: origin)
        guard !candidates.isEmpty else { throw SourceFailure(stage: "添加网址", message: "没有匹配的启用书源，请先导入对应网站书源", url: address) }
        var failures: [String] = []
        for source in candidates {
            try Task.checkCancellation()
            do {
                let input = SourceBook(title: "", url: address, sourceName: source.bookSourceName, sourceUrl: source.bookSourceUrl)
                let info = try await withTimeout(30) { try await source.fetchBookInfo(book: input) }
                guard !info.title.isEmpty else { throw SourceFailure(stage: "添加网址", message: "书名规则未匹配") }
                return (source, info)
            } catch { failures.append(source.bookSourceName + "：" + sourceErrorMessage(error)) }
        }
        try Task.checkCancellation()
        throw SourceFailure(stage: "添加网址", message: failures.joined(separator: "\n"), url: address)
    }
    static func preciseSearch(_ entry: ShelfListEntry, sources: [LegadoSource]) async throws -> (LegadoSource, SourceBook) {
        let searchable = sources.filter { $0.enabled && !$0.searchUrl.isEmpty }
        let match: (LegadoSource, SourceBook)? = await withTaskGroup(of: (LegadoSource, SourceBook)?.self) { group in
            var cursor = 0
            func enqueue(_ source: LegadoSource) {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let books = try? await withTimeout(25) { try await source.search(key: entry.name) }
                    guard !Task.isCancelled, let book = books?.first(where: {
                        $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == entry.name.trimmingCharacters(in: .whitespacesAndNewlines) &&
                        (entry.author.isEmpty || $0.author.trimmingCharacters(in: .whitespacesAndNewlines) == entry.author.trimmingCharacters(in: .whitespacesAndNewlines))
                    }) else { return nil }
                    return (source, book)
                }
            }
            while cursor < min(8, searchable.count) { enqueue(searchable[cursor]); cursor += 1 }
            for await result in group {
                if let result { group.cancelAll(); return result }
                if Task.isCancelled { group.cancelAll(); break }
                if cursor < searchable.count { enqueue(searchable[cursor]); cursor += 1 }
            }
            return nil
        }
        try Task.checkCancellation()
        guard let match else { throw SourceFailure(stage: "书架清单", message: "启用书源中没有找到同名同作者的书：" + entry.name) }
        return match
    }
    static func makeBook(source: LegadoSource, info: SourceBook, txtRules: [TxtTocRule] = []) async throws -> LocalBook {
        if source.isFile {
            let addresses = try await source.fileDownloadURLs(book: info)
            guard let address = addresses.first else { throw SourceFailure(stage: "文件书源", message: "没有可下载的文件") }
            return try await source.downloadBookFile(address, book: info, txtRules: txtRules)
        }
        var book = LocalBook(title: info.title, author: info.author, coverUrl: info.cover,
                             sourceName: source.bookSourceName, sourceUrl: source.bookSourceUrl,
                             fileName: UUID().uuidString + ".web", kind: source.localBookKind)
        book.bookUrl = info.url; book.tocUrl = info.tocUrl ?? ""
        if !source.isFile {
            book.chapters = try await withTimeout(60) { try await source.fetchChapters(book: info) }
            guard !book.chapters.isEmpty else { throw SourceFailure(stage: "添加书籍", message: "未取得目录") }
            book.chapterIndex = book.chapters.readableIndex(from: 0) ?? 0
        }
        return book
    }
}

@MainActor final class ShelfTransferModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published private(set) var failures: [String] = []
    private var task: Task<Void, Never>?
    func start(text: String, list: Bool, group: String, store: BookStore) {
        guard !running else { return }
        running = true; failures = []; status = "正在读取…"
        let sources = store.sources, txtRules = ReaderRuleLibrary.shared.txtRules
        task = Task {
            defer { running = false; task = nil }
            do {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let entries: [ShelfListEntry]
                if list {
                    let worker = Task.detached {
                        var data = Data(trimmed.utf8)
                        if isSourceURL(trimmed) {
                            let request = try SourceHTTP.request(trimmed, base: trimmed)
                            let (body, response) = try await SourceTLS.data(for: request)
                            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                            data = body
                        }
                        return try ShelfTransfer.decode(data)
                    }
                    entries = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                } else {
                    entries = trimmed.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { ShelfListEntry(name: "", bookUrl: $0) }
                }
                var added = 0, skipped = 0
                for (index, entry) in entries.enumerated() {
                    try Task.checkCancellation()
                    status = "正在添加 \(index + 1)/\(entries.count)：" + (entry.name.isEmpty ? entry.bookUrl : entry.name)
                    if store.books.contains(where: { (!entry.bookUrl.isEmpty && $0.sourceBook.url == entry.bookUrl) || (!entry.name.isEmpty && $0.title == entry.name && $0.author == entry.author) }) { skipped += 1; continue }
                    do {
                        let worker = Task.detached { () async throws -> LocalBook in
                            let pair: (LegadoSource, SourceBook)
                            if !entry.bookUrl.isEmpty { pair = try await ShelfTransfer.resolveURL(entry.bookUrl, sources: sources, origin: entry.origin) }
                            else { pair = try await ShelfTransfer.preciseSearch(entry, sources: sources) }
                            return try await ShelfTransfer.makeBook(source: pair.0, info: pair.1, txtRules: txtRules)
                        }
                        var book = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                        try Task.checkCancellation(); book.group = group
                        if !store.books.contains(where: { $0.sourceBook.url == book.bookUrl && $0.sourceUrl == book.sourceUrl }) { store.updateBook(book); added += 1 }
                        else { skipped += 1 }
                    } catch { if Task.isCancelled { throw CancellationError() }; failures.append((entry.name.isEmpty ? entry.bookUrl : entry.name) + "：" + sourceErrorMessage(error)) }
                }
                status = "添加完成：成功 \(added) 本，已存在 \(skipped) 本，失败 \(failures.count) 本"
            } catch { status = Task.isCancelled ? "已停止" : sourceErrorMessage(error) }
        }
    }
    func cancel() { task?.cancel() }
}

struct ShelfTransferView: View {
    @ObservedObject var store: BookStore
    @StateObject private var model = ShelfTransferModel()
    @State private var isList = false
    @State private var text = ""
    @State private var group = ""
    @State private var importing = false
    @State private var exportURL: URL?
    @State private var error = ""
    var body: some View {
        Form {
            Section {
                Picker("添加方式", selection: $isList) { Text("书籍网址").tag(false); Text("书架清单").tag(true) }.disabled(model.running)
                TextEditor(text: $text).frame(minHeight: 150).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.running)
                Text(isList ? "粘贴开源阅读导出的 JSON 书单或清单网址；按书名与作者在启用书源中查找。" : "每行一个书籍网址，自动匹配网站或书源的网址规则。").font(.caption).foregroundStyle(.secondary)
                TextField("加入分组（选填）", text: $group).disabled(model.running)
                if isList { Button("选择清单文件") { importing = true }.disabled(model.running) }
                Button(model.running ? "停止添加" : "开始添加") {
                    if model.running { model.cancel() } else { model.start(text: text, list: isList, group: group, store: store) }
                }.disabled(!model.running && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !model.status.isEmpty {
                Section("结果") {
                    if model.running { ProgressView() }
                    Text(model.status)
                    ForEach(Array(model.failures.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.red) }
                }
            }
            Section("导出书架清单") {
                Text("导出书名、作者和在线书籍地址，可在开源阅读中按名称导入。书籍文件与缓存不包含在清单内。").font(.caption).foregroundStyle(.secondary)
                Button("生成清单（\(store.books.count) 本）") {
                    do {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("books-" + UUID().uuidString + ".json")
                        try ShelfTransfer.encode(store.books).write(to: url, options: .atomic); exportURL = url
                    } catch { self.error = sourceErrorMessage(error) }
                }
                if let exportURL { ShareLink("分享书架清单", item: exportURL) }
            }
        }.navigationTitle("添加网址 / 书架清单").onDisappear { model.cancel() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in
            do {
                let url = try result.get(), access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url, options: .mappedIfSafe); _ = try ShelfTransfer.decode(data)
                text = String(decoding: data, as: UTF8.self)
            } catch { self.error = sourceErrorMessage(error) }
        }
        .alert("清单错误", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) { Button("确定") { error = "" } } message: { Text(error) }
    }
}
