import SwiftUI

struct SavedRssArticle: Identifiable, Codable {
    var source: RssSource
    var article: RssArticle
    var date: Date = Date()
    var id: String { source.sourceUrl + "|" + (article.link.isEmpty ? article.title : article.link) }
}

final class RssReadingStore: ObservableObject {
    static let shared = RssReadingStore()
    @Published private(set) var favorites: [SavedRssArticle] = []
    @Published private(set) var history: [SavedRssArticle] = []
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = Self.read("rss.favorites", defaults: defaults)
        history = Self.read("rss.history", defaults: defaults)
    }
    private static func read(_ key: String, defaults: UserDefaults) -> [SavedRssArticle] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedRssArticle].self, from: data)) ?? []
    }
    private func save() {
        defaults.set(try? JSONEncoder().encode(favorites), forKey: "rss.favorites")
        defaults.set(try? JSONEncoder().encode(history), forKey: "rss.history")
    }
    func isFavorite(_ item: SavedRssArticle) -> Bool { favorites.contains { $0.id == item.id } }
    func toggle(_ item: SavedRssArticle) {
        if isFavorite(item) { favorites.removeAll { $0.id == item.id } } else { favorites.insert(item, at: 0) }
        save()
    }
    func record(_ item: SavedRssArticle) {
        history.removeAll { $0.id == item.id }; history.insert(item, at: 0)
        history = Array(history.prefix(500)); save()
    }
    func delete(_ ids: Set<String>, favorites mode: Bool) {
        if mode { favorites.removeAll { ids.contains($0.id) } } else { history.removeAll { ids.contains($0.id) } }
        save()
    }
}

struct SavedRssArticlesView: View {
    @ObservedObject var store: BookStore
    let favorites: Bool
    @ObservedObject private var reading = RssReadingStore.shared
    private var items: [SavedRssArticle] { favorites ? reading.favorites : reading.history }
    var body: some View {
        List {
            if items.isEmpty { Text(favorites ? "还没有收藏文章" : "还没有阅读记录").foregroundStyle(.secondary) }
            ForEach(items) { item in
                NavigationLink {
                    FeedArticleView(store: store, source: item.source, article: item.article)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.article.title)
                        Text(item.source.sourceName + " · " + item.date.formatted()).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.onDelete { offsets in reading.delete(Set(offsets.map { items[$0].id }), favorites: favorites) }
        }.navigationTitle(favorites ? "订阅收藏" : "订阅阅读记录")
    }
}

struct RssSourceEditorView: View {
    @ObservedObject var store: BookStore
    let source: RssSource
    @State private var code = ""
    @State private var error = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        CodeEditorView(title: "编辑订阅源", code: $code, onSave: {
            do {
                var edited = try JSONDecoder().decode(RssSource.self, from: Data(code.utf8))
                guard !edited.sourceName.isEmpty, isSourceURL(edited.sourceUrl) else { throw SourceFailure(stage: "订阅源", message: "请填写名称和有效地址") }
                guard let index = store.rssSources.firstIndex(where: { $0.id == source.id }) else { throw SourceFailure(stage: "订阅源", message: "订阅源已被删除") }
                guard !store.rssSources.contains(where: { $0.id != source.id && $0.sourceUrl == edited.sourceUrl }) else { throw SourceFailure(stage: "订阅源", message: "订阅源地址重复") }
                edited.id = source.id; store.rssSources[index] = edited; store.save(); dismiss()
            } catch { self.error = sourceErrorMessage(error) }
        })
        .onAppear {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            code = (try? encoder.encode(source)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
        .alert("保存失败", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) { Button("确定") { error = "" } } message: { Text(error) }
    }
}
