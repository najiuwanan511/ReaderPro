import Foundation
import Combine

struct SourceSearchUpdate: Sendable {
    var sourceID: String
    var sourceName: String
    var books: [SourceBook]
    var error: String
    var page: Int = 1
}

// Refill a slot as soon as it finishes. A slow source must never hold back
// results or prevent the next source from starting.
func streamSourceSearch(_ sources: [LegadoSource], key: String, concurrency: Int = SourceConcurrency.search, timeout: Double = 25,
                        pages: [String: Int] = [:],
                        willSearch: (@Sendable (LegadoSource) async -> Void)? = nil,
                        update: @escaping @Sendable (SourceSearchUpdate) async -> Void) async {
    let searchable = sources.filter { !$0.searchUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    await streamConcurrentWork(searchable, concurrency: concurrency, operation: { source in
        await willSearch?(source)
        let page = pages[source.id] ?? 1
        do {
            let books = try await withTimeout(timeout) { try await source.search(key: key, page: page) }
            return .init(sourceID: source.id, sourceName: source.bookSourceName, books: books, error: "", page: page)
        } catch {
            return .init(sourceID: source.id, sourceName: source.bookSourceName, books: [], error: sourceErrorMessage(error), page: page)
        }
    }, update: update)
}

@MainActor final class SourceSearchController: ObservableObject {
    @Published private(set) var results: [SourceBook] = []
    @Published private(set) var allResults: [SourceBook] = []
    @Published private(set) var searching = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var errors: [String] = []
    @Published private(set) var keyword = ""
    @Published private(set) var cancelled = false
    @Published private(set) var hasMore = false
    @Published private(set) var page = 0
    @Published private(set) var concurrency = SourceConcurrency.search
    private var seen: Set<String> = []
    private var candidates: [SourceBook] = []
    private var matchMode: SearchMatchMode?
    private var seenURLs: [String: Set<String>] = [:]
    private var nextPages: [String: Int] = [:]
    private var sources: [LegadoSource] = []
    private var generation = UUID()
    private var task: Task<Void, Never>?

    func start(_ sources: [LegadoSource], key: String, matching mode: SearchMatchMode? = nil) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task?.cancel()
        let run = UUID(); generation = run
        results = []; allResults = []; errors = []; seen = []; candidates = []; matchMode = mode
        seenURLs = [:]; page = 0
        self.sources = sources.filter { !$0.searchUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        nextPages = Dictionary(self.sources.map { ($0.id, 1) }, uniquingKeysWith: { first, _ in first })
        keyword = trimmed; cancelled = false; searching = false
        loadMore(generation: run)
    }

    func setMatchingMode(_ mode: SearchMatchMode) {
        matchMode = mode
        results = candidates.filter { mode.matches($0, keyword: keyword) }
    }

    func loadMore() { loadMore(generation: generation) }

    private func loadMore(generation run: UUID) {
        guard !searching, !keyword.isEmpty else { return }
        let pending = sources.filter { nextPages[$0.id] != nil }
        completed = 0; total = pending.count; hasMore = !pending.isEmpty
        guard !pending.isEmpty else { return }
        let pages = nextPages, key = keyword
        concurrency = SourceConcurrency.search
        let limit = concurrency
        cancelled = false; searching = true; errors = []
        task = Task {
            await streamSourceSearch(pending, key: key, concurrency: limit, pages: pages) { [weak self] result in
                await self?.receive(result, generation: run)
            }
            guard generation == run else { return }
            searching = false; task = nil; hasMore = !nextPages.isEmpty
        }
    }

    private func receive(_ result: SourceSearchUpdate, generation run: UUID) {
        guard run == generation, !cancelled else { return }
        completed += 1
        if !result.error.isEmpty {
            // Keep this source's page for a manual retry without repeating
            // pages already completed by other sources.
            errors.append(result.sourceName + "：" + result.error)
            return
        }
        page = max(page, result.page)
        var urls = seenURLs[result.sourceID] ?? []
        let newBooks = result.books.filter { urls.insert($0.url).inserted }
        seenURLs[result.sourceID] = urls
        nextPages[result.sourceID] = newBooks.isEmpty ? nil : result.page + 1
        allResults.append(contentsOf: newBooks)
        // A single source can return hundreds of books. Publishing each append
        // causes SwiftUI to diff and copy the growing result list for every
        // row, multiplying main-thread work and transient memory use.
        let added = newBooks.filter { seen.insert(dedupeKey($0)).inserted }
        candidates.append(contentsOf: added)
        let visible = added.filter { matchMode?.matches($0, keyword: keyword) ?? true }
        if !visible.isEmpty { results.append(contentsOf: visible) }
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        searching = false; cancelled = true
    }
}
