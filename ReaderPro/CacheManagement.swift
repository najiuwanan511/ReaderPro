import SwiftUI
import WebKit

extension BookStore {
    func clearChapterCache(bookID: String) {
        chapterCache.cancel(bookID: bookID)
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        var book = books[index]
        if book.kind == "web" {
            for chapter in book.chapters.indices where book.chapters[chapter].url != nil {
                book.chapters[chapter].text = "__URL__" + (book.chapters[chapter].url ?? "")
            }
        }
        let directory = Self.filesDir.appendingPathComponent(book.fileName).appendingPathComponent("mangaCache")
        try? FileManager.default.removeItem(at: directory)
        books[index] = book; saveBooks()
    }
    @MainActor func clearDownloadedCaches() async {
        for book in books { clearChapterCache(bookID: book.id) }
        SourceJSBridge.invalidateImportedScripts()
        URLCache.shared.removeAllCachedResponses()
        // Login cookies and persistent site storage are account data, not a
        // disposable chapter cache. Clear only WebKit's rendering caches.
        await WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache], modifiedSince: .distantPast)
    }
}

struct CacheManagementView: View {
    @ObservedObject var store: BookStore
    @AppStorage("reader.preloadCount") private var preloadCount = 3
    @State private var clearing = false
    @State private var downloadBook: LocalBook?
    var body: some View {
        List {
            Section("阅读预加载") {
                Stepper("提前缓存 \(preloadCount) 章", value: $preloadCount, in: 0...50)
                Text("默认为后 3 章；设为 0 关闭。已缓存的正文可以离线阅读。").font(.caption).foregroundStyle(.secondary)
            }
            Section("书籍缓存") {
                ForEach(store.books.filter { $0.kind == "web" || $0.isComicKind }) { book in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(book.title)
                        Text("\(book.chapters.filter { !$0.isVolume && !$0.text.isEmpty && !$0.text.hasPrefix("__URL__") }.count) / \(book.chapters.filter { !$0.isVolume }.count) 章正文").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if book.kind == "web" { Button("下载正文") { downloadBook = book } }
                            Spacer()
                            Button("清除缓存", role: .destructive) { store.clearChapterCache(bookID: book.id) }
                        }.buttonStyle(.borderless)
                    }
                }
            }
            Button(clearing ? "正在清理…" : "清理全部阅读缓存", role: .destructive) {
                Task { clearing = true; await store.clearDownloadedCaches(); clearing = false }
            }.disabled(clearing)
        }.navigationTitle("缓存管理")
        .sheet(item: $downloadBook) { book in NavigationStack { ChapterDownloadView(store: store, bookID: book.id) } }
    }
}

struct ChapterDownloadView: View {
    @ObservedObject var store: BookStore
    let bookID: String
    @State private var completed = 0
    @State private var failed = 0
    @State private var total = 0
    @State private var running = false
    @State private var task: Task<Void, Never>?
    @State private var failure = ""
    var body: some View {
        List {
            Text("已处理 \(completed) / \(total)，失败 \(failed)")
            if running { ProgressView(value: Double(completed), total: Double(max(1, total))) }
            if !failure.isEmpty { Text(failure).font(.caption).foregroundStyle(.red) }
            Button(running ? "取消" : "下载未缓存章节") {
                if running { task?.cancel() } else { start() }
            }
        }.navigationTitle("下载正文")
        .onDisappear { task?.cancel() }
    }
    private func start() {
        guard let book = store.books.first(where: { $0.id == bookID }) else { return }
        let indices = book.chapters.indices.filter { !book.chapters[$0].isVolume && book.chapters[$0].text.hasPrefix("__URL__") }
        total = indices.count; completed = 0; failed = 0; failure = ""; running = true
        task = Task { @MainActor in
            for index in indices {
                if Task.isCancelled { break }
                do { _ = try await store.chapterCache.content(bookID: bookID, index: index) }
                catch { if !Task.isCancelled { failed += 1; failure = sourceErrorMessage(error) } }
                completed += 1
            }
            running = false
        }
    }
}
