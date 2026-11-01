import Foundation
import Combine

struct SourceSearchUpdate: Sendable {
    var sourceID: String
    var sourceName: String
    var books: [SourceBook]
    var error: String
}

// Refill a slot as soon as it finishes. A slow source must never hold back
// results or prevent the next source from starting.
func streamSourceSearch(_ sources: [LegadoSource], key: String, concurrency: Int = 8, timeout: Double = 25,
                        willSearch: (@Sendable (LegadoSource) async -> Void)? = nil,
                        update: @escaping @Sendable (SourceSearchUpdate) async -> Void) async {
    let searchable = sources.filter { !$0.searchUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    await withTaskGroup(of: SourceSearchUpdate.self) { group in
        var next = 0
        func enqueue(_ source: LegadoSource) {
            group.addTask {
                await willSearch?(source)
                do {
                    let books = try await withTimeout(timeout) { try await source.search(key: key) }
                    return .init(sourceID: source.id, sourceName: source.bookSourceName, books: books, error: "")
                } catch {
                    return .init(sourceID: source.id, sourceName: source.bookSourceName, books: [], error: sourceErrorMessage(error))
                }
            }
        }
        while next < min(max(1, concurrency), searchable.count) { enqueue(searchable[next]); next += 1 }
        for await result in group {
            if Task.isCancelled { group.cancelAll(); break }
            await update(result)
            if next < searchable.count { enqueue(searchable[next]); next += 1 }
        }
    }
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
    private var seen: Set<String> = []
    private var generation = UUID()
    private var task: Task<Void, Never>?

    func start(_ sources: [LegadoSource], key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task?.cancel()
        let run = UUID(); generation = run
        results = []; allResults = []; errors = []; seen = []
        completed = 0; total = sources.filter { !$0.searchUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        keyword = trimmed; cancelled = false; searching = total > 0
        task = Task {
            await streamSourceSearch(sources, key: trimmed) { [weak self] result in
                await self?.receive(result, generation: run)
            }
            guard generation == run else { return }
            searching = false; task = nil
        }
    }

    private func receive(_ result: SourceSearchUpdate, generation run: UUID) {
        guard run == generation, !cancelled else { return }
        completed += 1
        if !result.error.isEmpty { errors.append(result.sourceName + "：" + result.error) }
        allResults.append(contentsOf: result.books)
        // A single source can return hundreds of books. Publishing each append
        // causes SwiftUI to diff and copy the growing result list for every
        // row, multiplying main-thread work and transient memory use.
        let added = result.books.filter { seen.insert(dedupeKey($0)).inserted }
        if !added.isEmpty { results.append(contentsOf: added) }
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        searching = false; cancelled = true
    }
}
