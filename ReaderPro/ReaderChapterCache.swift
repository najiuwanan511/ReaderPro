import Foundation

/// Foreground reading and background preloading share the same request and raw
/// chapter cache. Cached text is never purified, so editing a rule is reversible.
@MainActor final class ReaderChapterCache {
    typealias Fetch = @MainActor (LegadoSource, BookChapter, String?) async throws -> String
    private weak var store: BookStore?
    private let fetch: Fetch
    private struct Request {
        let token: UUID
        let bookID: String
        let task: Task<String, Error>
    }
    private var requests: [String: Request] = [:]
    private var preloadTasks: [String: Task<Void, Never>] = [:]

    init(store: BookStore, fetch: @escaping Fetch = { source, chapter, next in
        try await withTimeout(45) { try await source.fetchChapterContent(chapter, nextChapterUrl: next) }
    }) {
        self.store = store; self.fetch = fetch
    }

    func content(bookID: String, index: Int) async throws -> String {
        guard let store, let book = store.books.first(where: { $0.id == bookID }), book.chapters.indices.contains(index) else {
            throw CancellationError()
        }
        let chapter = book.chapters[index]
        if !chapter.text.hasPrefix("__URL__") { return chapter.text }
        guard let source = store.sourceForBook(book) else {
            throw SourceFailure(stage: "正文", message: "这本书的书源已删除，无法加载章节")
        }
        let key = [bookID, book.sourceUrl, book.sourceName, chapter.id, chapter.url ?? ""].joined(separator: "\u{1f}")
        if let request = requests[key] { return try await request.task.value }
        let token = UUID(), fetch = self.fetch
        let next = book.chapters.readableIndex(from: index + 1).flatMap { book.chapters[$0].url }
        let task = Task { @MainActor [weak self] () async throws -> String in
            let text = try await fetch(source, chapter, next)
            try Task.checkCancellation()
            guard let self, let store = self.store,
                  var current = store.books.first(where: { $0.id == bookID }),
                  current.sourceUrl == book.sourceUrl, current.sourceName == book.sourceName,
                  current.chapters.indices.contains(index), current.chapters[index].id == chapter.id,
                  current.chapters[index].url == chapter.url else { throw CancellationError() }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SourceFailure(stage: "正文", message: "该章节没有返回正文")
            }
            current.chapters[index].text = text
            guard let bookIndex = store.books.firstIndex(where: { $0.id == bookID }) else { throw CancellationError() }
            store.books[bookIndex] = current
            // A background chapter does not change sources or preferences.
            // Avoid serializing a large source collection three times per turn.
            store.saveBooks()
            return text
        }
        requests[key] = Request(token: token, bookID: bookID, task: task)
        defer { if requests[key]?.token == token { requests[key] = nil } }
        return try await task.value
    }

    /// A moving window: chapter 1 loads 2, 3, 4; chapter 2 loads 3, 4, 5.
    /// Serial background fetching preserves source variables and leaves network
    /// capacity for a reader jump. An in-flight next chapter is reused on a turn.
    func preload(bookID: String, after index: Int, count requested: Int? = nil) {
        let count = requested ?? (UserDefaults.standard.object(forKey: "reader.preloadCount") as? Int ?? 3)
        preloadTasks[bookID]?.cancel()
        guard let book = store?.books.first(where: { $0.id == bookID }),
              book.kind == "web", book.chapters.indices.contains(index), count > 0 else { return }
        let upcoming = Array(book.chapters.indices.dropFirst(index + 1).filter { !book.chapters[$0].isVolume }.prefix(count))
        guard !upcoming.isEmpty else { return }
        preloadTasks[bookID] = Task { @MainActor [weak self] in
            for next in upcoming {
                guard !Task.isCancelled, let self else { return }
                // A failed prefetch must not obscure the chapter being read;
                // opening that chapter will retry and show its actual error.
                _ = try? await self.content(bookID: bookID, index: next)
            }
        }
    }

    func cancel(bookID: String) {
        preloadTasks.removeValue(forKey: bookID)?.cancel()
        for key in requests.keys.filter({ requests[$0]?.bookID == bookID }) {
            requests.removeValue(forKey: key)?.task.cancel()
        }
    }
}
