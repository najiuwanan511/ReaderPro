import SwiftUI
import WebKit

extension BookStore {
    @MainActor func clearChapterCache(bookID: String) async {
        chapterCache.cancel(bookID: bookID)
        await mediaCache.clear(bookID: bookID)
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        var book = books[index]
        if book.kind == "web" {
            for chapter in book.chapters.indices where book.chapters[chapter].url != nil {
                book.chapters[chapter].text = "__URL__" + (book.chapters[chapter].url ?? "")
            }
        }
        MangaImageStore.shared.clear(bookID: book.id)
        if book.kind == "comic" {
            for chapter in book.chapters.indices { book.chapters[chapter].imageUrls = [] }
        }
        books[index] = book; saveBooks()
    }
    @MainActor func clearDownloadedCaches() async {
        for book in books { await clearChapterCache(bookID: book.id) }
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
    @AppStorage("media.preloadCount") private var mediaPreloadCount = 3
    @State private var mediaCounts: [String: Int] = [:]
    @State private var clearing = false
    @State private var downloadBook: LocalBook?
    var body: some View {
        List {
            Section("阅读预加载") {
                Stepper("提前缓存 \(preloadCount) 章", value: $preloadCount, in: 0...50)
                Text("默认为后 3 章；设为 0 关闭。已缓存的正文可以离线阅读。").font(.caption).foregroundStyle(.secondary)
                Stepper("音视频提前缓存 \(mediaPreloadCount) 章", value: $mediaPreloadCount, in: 0...50)
                Text("音视频文件较大，可设为 0 关闭自动下载；下载完成的章节支持离线播放。").font(.caption).foregroundStyle(.secondary)
            }
            Section("书籍缓存") {
                ForEach(store.books.filter { $0.kind == "web" || $0.isComicKind || $0.isAudio || $0.isVideo }) { book in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(book.title)
                        Text("\(book.isAudio || book.isVideo ? (mediaCounts[book.id] ?? 0) : book.chapters.filter { !$0.isVolume && !$0.text.isEmpty && !$0.text.hasPrefix("__URL__") }.count) / \(book.chapters.filter { !$0.isVolume }.count) 章已缓存").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if book.kind == "web" { Button("下载正文") { downloadBook = book } }
                            if book.isAudio || book.isVideo { Button("下载音视频") { downloadBook = book } }
                            Spacer()
                            Button("清除缓存", role: .destructive) { Task { await store.clearChapterCache(bookID: book.id); await refreshCounts() } }
                        }.buttonStyle(.borderless)
                    }
                }
            }
            Button(clearing ? "正在清理…" : "清理全部阅读缓存", role: .destructive) {
                Task { clearing = true; await store.clearDownloadedCaches(); await refreshCounts(); clearing = false }
            }.disabled(clearing)
        }.navigationTitle("缓存管理")
        .task { await refreshCounts() }
        .sheet(item: $downloadBook, onDismiss: { Task { await refreshCounts() } }) { book in NavigationStack { ChapterDownloadView(store: store, bookID: book.id) } }
    }
    private func refreshCounts() async { for book in store.books where book.isAudio || book.isVideo { mediaCounts[book.id] = await MediaDiskCache.shared.count(book: book) } }
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
        }.navigationTitle("章节下载")
        .onDisappear { task?.cancel() }
    }
    private func start() {
        guard let book = store.books.first(where: { $0.id == bookID }) else { return }
        let indices = book.chapters.indices.filter { !book.chapters[$0].isVolume && (book.isAudio || book.isVideo || book.chapters[$0].text.hasPrefix("__URL__")) }
        total = indices.count; completed = 0; failed = 0; failure = ""; running = true
        task = Task { @MainActor in
            for index in indices {
                if Task.isCancelled { break }
                do {
                    if book.isAudio || book.isVideo { _ = try await store.mediaCache.download(bookID: bookID, index: index) }
                    else { _ = try await store.chapterCache.content(bookID: bookID, index: index) }
                }
                catch { if !Task.isCancelled { failed += 1; failure = sourceErrorMessage(error) } }
                completed += 1
            }
            running = false
        }
    }
}
