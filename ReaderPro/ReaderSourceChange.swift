import SwiftUI

struct ReaderSourceCandidate: Identifiable {
    var book: SourceBook
    var chapters: [BookChapter]?
    var chapterCount: Int?
    var latestChapter = ""
    var error = ""
    var id: String { [book.sourceUrl, book.sourceName, book.url].joined(separator: "\u{1f}") }
    var directorySummary: String {
        if !error.isEmpty { return "目录加载失败：\(error)" }
        if let count = chapterCount ?? chapters?.count { return "目录 · \(count) 章" }
        return "正在读取目录…"
    }
}

@MainActor final class ReaderSourceChangeModel: ObservableObject {
    @Published var rows: [ReaderSourceCandidate] = []
    @Published var searching = false
    @Published var completed = 0
    @Published var total = 0
    @Published var searchErrors = 0
    private var generation = UUID()
    private var searchTask: Task<Void, Never>?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var pending: [String] = []
    private var sources: [LegadoSource] = []
    private var directoryCallbacks: [String: (ReaderSourceCandidate) -> Void] = [:]

    static func matches(_ found: SourceBook, title: String, author: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.components(separatedBy: .whitespacesAndNewlines).joined().lowercased()
        }
        return normalized(found.title) == normalized(title)
            && (author.isEmpty || normalized(found.author).contains(normalized(author)))
    }

    func start(sources: [LegadoSource], title: String, author: String) {
        cancel(); rows = []; pending = []; self.sources = sources
        completed = 0; searchErrors = 0
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { total = 0; return }
        total = sources.filter { !$0.searchUrl.isEmpty }.count
        searching = total > 0
        let run = generation
        searchTask = Task {
            await streamSourceSearch(sources, key: title) { [weak self] update in
                await self?.receive(update, title: title, author: author, run: run)
            }
            guard generation == run else { return }
            searching = false
        }
    }

    private func receive(_ update: SourceSearchUpdate, title: String, author: String, run: UUID) {
        guard generation == run else { return }
        completed += 1
        if !update.error.isEmpty { searchErrors += 1 }
        for book in update.books where Self.matches(book, title: title, author: author) {
            let row = ReaderSourceCandidate(book: book)
            // A novel from different sources must never be deduplicated by
            // title/author. That was hiding nearly all alternative sources.
            guard !rows.contains(where: { $0.id == row.id }) else { continue }
            rows.append(row); pending.append(row.id)
        }
        pump(run: run)
    }

    func retry(_ row: ReaderSourceCandidate) {
        guard tasks[row.id] == nil else { return }
        if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index].error = "" }
        if !pending.contains(row.id) { pending.append(row.id) }
        pump(run: generation)
    }

    func withDirectory(_ row: ReaderSourceCandidate, action: @escaping (ReaderSourceCandidate) -> Void) {
        if row.chapters?.isEmpty == false { action(row); return }
        directoryCallbacks[row.id] = action
        retry(row)
    }

    private func pump(run: UUID) {
        while tasks.count < 3, !pending.isEmpty {
            let id = pending.removeFirst()
            guard let row = rows.first(where: { $0.id == id }),
                  let source = sources.first(where: { $0.bookSourceName == row.book.sourceName && $0.bookSourceUrl == row.book.sourceUrl }) else { continue }
            tasks[id] = Task { @MainActor in
                do {
                    let info = try await withTimeout(30) { try await source.fetchBookInfo(book: row.book) }
                    let chapters = try await withTimeout(120) { try await source.fetchChapters(book: info) }
                    try Task.checkCancellation()
                    guard generation == run, let index = rows.firstIndex(where: { $0.id == id }) else { return }
                    guard !chapters.isEmpty else { throw SourceFailure(stage: "目录", message: "没有返回章节") }
                    rows[index].book = info; rows[index].chapters = chapters
                    rows[index].chapterCount = chapters.count; rows[index].latestChapter = chapters.last?.title ?? ""
                    // Match Legado's directory cache budget. Keep row metadata
                    // after eviction and fetch the full list again on demand.
                    while rows.reduce(0, { $0 + ($1.chapters?.count ?? 0) }) > 30_000,
                          let victim = rows.indices.first(where: { $0 != index && rows[$0].chapters != nil }) {
                        rows[victim].chapters = nil
                    }
                    let ready = rows[index]
                    directoryCallbacks.removeValue(forKey: id)?(ready)
                } catch {
                    if generation == run, !Task.isCancelled, let index = rows.firstIndex(where: { $0.id == id }) {
                        rows[index].error = sourceErrorMessage(error)
                        directoryCallbacks[id] = nil
                    }
                }
                if generation == run { tasks[id] = nil; pump(run: run) }
            }
        }
    }

    func cancel() {
        generation = UUID(); searchTask?.cancel(); searchTask = nil
        tasks.values.forEach { $0.cancel() }; tasks = [:]; pending = []; searching = false
        directoryCallbacks = [:]
    }
}

@MainActor struct ReaderSourceChangeView: View {
    @ObservedObject var store: BookStore
    let current: LocalBook
    let select: (ReaderSourceCandidate, Int?) -> Void
    @StateObject private var model = ReaderSourceChangeModel()
    @State private var query = ""
    @State private var directory: ReaderSourceCandidate?
    @State private var sourceFilter = ""
    @AppStorage("reader.changeSourceCheckAuthor") private var checkAuthor = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("书名", text: $query).textFieldStyle(.roundedBorder)
                        .onSubmit { search() }.accessibilityIdentifier("changeSourceSearch")
                    Button(model.searching ? "停止" : "搜索") { if model.searching { model.cancel() } else { search() } }
                }.padding()
                TextField("筛选书源名称或网址", text: $sourceFilter).textFieldStyle(.roundedBorder).padding(.horizontal).padding(.bottom, 8)
                HStack {
                    Text("已搜索 \(model.completed)/\(model.total) · 找到 \(model.rows.count) 个来源")
                    Spacer()
                    if model.searching { ProgressView() }
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 8)
                List {
                    Section("当前来源") {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(current.sourceName)
                                Text("目录 · \(current.chapters.count) 章").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "checkmark").foregroundStyle(AppTheme.accent)
                        }
                    }
                    Section("可切换来源") {
                        ForEach(model.rows.filter { sourceFilter.isEmpty || $0.book.sourceName.localizedCaseInsensitiveContains(sourceFilter) || $0.book.sourceUrl.localizedCaseInsensitiveContains(sourceFilter) }) { row in
                            HStack(spacing: 12) {
                                Button { model.withDirectory(row) { select($0, nil) } } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(row.book.sourceName).font(.body)
                                            Spacer()
                                            Text(row.book.author).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Text(row.directorySummary).font(.caption).foregroundStyle(row.error.isEmpty ? Color.secondary : Color.red)
                                        if !row.latestChapter.isEmpty { Text("最新：\(row.latestChapter)").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled((row.chapterCount ?? row.chapters?.count ?? 0) == 0 || !row.error.isEmpty)
                                    .accessibilityIdentifier("changeSource-\(row.book.sourceName)")
                                if (row.chapterCount ?? row.chapters?.count ?? 0) > 0 && row.error.isEmpty {
                                    Button("目录") { model.withDirectory(row) { directory = $0 } }.buttonStyle(.bordered)
                                        .accessibilityLabel("查看\(row.book.sourceName)目录")
                                } else if !row.error.isEmpty {
                                    Button("重试") { model.retry(row) }.buttonStyle(.bordered)
                                } else { ProgressView() }
                            }.padding(.vertical, 4)
                        }
                        if !model.searching && model.rows.isEmpty { Text("未找到同书名的来源，可修改书名后重试。").foregroundStyle(.secondary) }
                    }
                }.listStyle(.plain)
            }
            .navigationTitle("换源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("校验作者", isOn: $checkAuthor)
                        Button("刷新列表") { search() }
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("换源更多操作")
                }
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
            .onChange(of: checkAuthor) { _, _ in search() }
            .task { query = current.title; search() }
            .onDisappear { model.cancel() }
            .sheet(item: $directory) { row in
                NavigationStack {
                    List(Array((row.chapters ?? []).enumerated()), id: \.element.id) { index, chapter in
                        Button(chapter.displayTitle) { directory = nil; select(row, index) }.disabled(chapter.isVolume)
                            .accessibilityIdentifier("sourceDirectoryChapter-\(index)")
                    }
                    .navigationTitle("\(row.book.sourceName)目录")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { directory = nil } } }
                }
            }
        }
    }
    private func search() { model.start(sources: store.enabledSources, title: query.trimmingCharacters(in: .whitespacesAndNewlines), author: checkAuthor ? current.author : "") }
}
