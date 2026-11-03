import Foundation

@MainActor final class ReaderMediaCache {
    private weak var store: BookStore?
    private var preloads: [String: Task<Void, Never>] = [:]
    init(store: BookStore) { self.store = store }
    func download(bookID: String, index: Int) async throws -> CachedChapterMedia {
        guard let store, let book = store.books.first(where: { $0.id == bookID }), book.chapters.indices.contains(index) else { throw CancellationError() }
        let chapter = book.chapters[index]
        if let cached = try await MediaDiskCache.shared.cached(book: book, chapter: chapter) { return cached }
        guard let source = store.sourceForBook(book) else { throw SourceFailure(stage: "媒体缓存", message: "书源已删除，无法下载") }
        return try await source.withRules {
            if book.isAudio {
                let value = try await source.fetchChapterAudio(chapter)
                return try await MediaDiskCache.shared.download(book: book, chapter: chapter, request: value.request, auxiliary: value.lyrics)
            }
            let value = try await source.fetchChapterVideoDetails(chapter)
            guard case .native(let request) = value.resource else { throw SourceFailure(stage: "媒体缓存", message: "此章节使用网页播放器，未提供可下载的媒体地址") }
            return try await MediaDiskCache.shared.download(book: book, chapter: chapter, request: request, auxiliary: value.subContent)
        }
    }
    func preload(bookID: String, from index: Int) {
        preloads[bookID]?.cancel()
        let count = max(0, min(50, UserDefaults.standard.object(forKey: "media.preloadCount") as? Int ?? 3))
        guard count > 0, let book = store?.books.first(where: { $0.id == bookID }), book.isAudio || book.isVideo else { return }
        let upcoming = Array(book.chapters.indices.dropFirst(max(0, index)).filter { !book.chapters[$0].isVolume }.prefix(count + 1))
        preloads[bookID] = Task { @MainActor [weak self] in
            for next in upcoming {
                guard !Task.isCancelled, let self else { return }
                _ = try? await self.download(bookID: bookID, index: next)
            }
        }
    }
    func clear(bookID: String) async {
        preloads.removeValue(forKey: bookID)?.cancel()
        await MediaDiskCache.shared.clear(bookID: bookID)
    }
}
