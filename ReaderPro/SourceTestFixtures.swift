#if DEBUG || READERPRO_TESTING
import SwiftUI

// Compiled out of the Release IPA. Tests run the production views/engine with
// an isolated simulator sandbox and a local deterministic HTTP server.
enum SourceTestFixtures {
    static let base = "http://127.0.0.1:8765"
    static func html() -> LegadoSource {
        var source = LegadoSource()
        source.bookSourceName = "回归测试书源"
        source.bookSourceUrl = base
        source.header = #"{"X-Fixture":"ReaderPro"}"#
        source.exploreUrl = "分类::/redirect"
        source.searchUrl = #"/search,{"method":"POST","body":"key={{key}}&n={{page}}"}"#
        source.ruleSearch.checkKeyWord = "测试"
        source.ruleSearch.bookList = "@css:ul.books > li"
        source.ruleSearch.name = "@css:a.name@text"
        source.ruleSearch.author = "tag.em@text"
        source.ruleSearch.bookUrl = "@css:a.name@href"
        source.ruleExplore = source.ruleSearch
        source.ruleBookInfo.name = "//h1/text()"
        source.ruleBookInfo.intro = "id.intro@text"
        source.ruleBookInfo.tocUrl = "@css:a.toc@href"
        source.ruleToc.chapterList = "@xpath://section[@id='chapters']/p/a"
        source.ruleToc.chapterName = "text"
        source.ruleToc.chapterUrl = "href"
        source.ruleToc.nextTocUrl = "@css:a.next@href"
        source.ruleContent.content = "@css:#content@html"
        source.ruleContent.nextContentUrl = "@css:a.next@href"
        return source
    }
    static func json() -> LegadoSource {
        var source = LegadoSource()
        source.bookSourceName = "JSON测试源"
        source.bookSourceUrl = base
        source.searchUrl = "/json/search"
        source.ruleSearch.bookList = "$.data"
        source.ruleSearch.name = "$.name"
        source.ruleSearch.bookUrl = "$.url"
        source.ruleBookInfo.name = "$.name"
        source.ruleBookInfo.tocUrl = "$.toc"
        source.ruleToc.chapterList = "$.chapters[*]"
        source.ruleToc.chapterName = "$.name"
        source.ruleToc.chapterUrl = "$.url"
        source.ruleContent.content = "$.text"
        return source
    }
}

// Preserve the simulator's existing app data across the test that restarts
// into the real ContentView. This helper is compiled only for test builds.
private enum PersistentSourceFixture {
    private struct Snapshot: Codable {
        var books: Data?
        var meta: Data?
        var validation: Data?
        var defaults: Data
    }
    private static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private static let validationURL = directory.appendingPathComponent("source-validation.json")
    private static let snapshotURL = directory.appendingPathComponent(".source-ui-test-snapshot.json")
    static var hasSnapshot: Bool { FileManager.default.fileExists(atPath: snapshotURL.path) }

    private static func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    static func saveSnapshot() throws {
        // SwiftUI can recreate its root value; never overwrite an existing
        // snapshot, which may also be left by an interrupted prior test.
        if FileManager.default.fileExists(atPath: snapshotURL.path) { return }
        guard let domain = Bundle.main.bundleIdentifier else {
            throw SourceFailure(stage: "测试准备", message: "缺少应用标识")
        }
        let defaults = try PropertyListSerialization.data(fromPropertyList: UserDefaults.standard.persistentDomain(forName: domain) ?? [:], format: .binary, options: 0)
        let saved = try Snapshot(books: read(BookStore.booksURL), meta: read(BookStore.metaURL),
                                 validation: read(validationURL), defaults: defaults)
        try JSONEncoder().encode(saved).write(to: snapshotURL, options: .atomic)
    }

    static func restore(removeSnapshot: Bool) throws {
        let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: snapshotURL))
        for (url, data) in [(BookStore.booksURL, saved.books), (BookStore.metaURL, saved.meta), (validationURL, saved.validation)] {
            if let data { try data.write(to: url, options: .atomic) }
            else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        guard let domain = Bundle.main.bundleIdentifier,
              let defaults = try PropertyListSerialization.propertyList(from: saved.defaults, options: [], format: nil) as? [String: Any] else {
            throw SourceFailure(stage: "测试清理", message: "无法恢复测试前设置")
        }
        UserDefaults.standard.setPersistentDomain(defaults, forName: domain)
        if removeSnapshot { try FileManager.default.removeItem(at: snapshotURL) }
    }
}

struct SourceFixtureRoot: View {
    @StateObject private var store: BookStore
    @State private var loaded = false
    @State private var persistenceStatus = ""
    init() {
        var status = ""
        if ProcessInfo.processInfo.arguments.contains("--seed-persistent-user-pack") {
            do { try PersistentSourceFixture.saveSnapshot() }
            catch { status = "测试备份失败：\(error.localizedDescription)" }
        }
        if ProcessInfo.processInfo.arguments.contains("--restore-persistent-fixture") {
            do {
                if PersistentSourceFixture.hasSnapshot { try PersistentSourceFixture.restore(removeSnapshot: false) }
                else { status = "持久化测试数据已恢复" }
            }
            catch { status = "测试恢复失败：\(error.localizedDescription)" }
        }
        _persistenceStatus = State(initialValue: status)
        _store = StateObject(wrappedValue: BookStore())
        if ProcessInfo.processInfo.arguments.contains("--reset-source-fixture") {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("source-validation.json")
            try? FileManager.default.removeItem(at: url)
        }
    }
    @ViewBuilder var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--restore-persistent-fixture") {
            Text(persistenceStatus).task {
                guard persistenceStatus.isEmpty else { return }
                do {
                    try PersistentSourceFixture.restore(removeSnapshot: true)
                    persistenceStatus = "持久化测试数据已恢复"
                } catch { persistenceStatus = "测试恢复失败：\(error.localizedDescription)" }
            }
        } else {
        TabView {
            if ProcessInfo.processInfo.arguments.contains("--source-stress-fixture") {
                BookshelfView(store: store).tabItem { Label("书架", systemImage: "books.vertical") }
            }
            if ProcessInfo.processInfo.arguments.contains("--rss-ui-fixture") {
                RssSubscribeView(store: store).tabItem { Label("订阅", systemImage: "bookmark") }
            }
            NavigationStack { SourceManagementView(store: store) }.tabItem { Label("管理", systemImage: "list.bullet") }
            DiscoveryView(store: store).tabItem { Label("发现", systemImage: "safari") }
            NavigationStack { SourceView(store: store) }.tabItem { Label("搜索", systemImage: "magnifyingglass") }
        }.task {
            guard !loaded else { return }; loaded = true
            var source = SourceTestFixtures.html(); source.id = "fixture-html"
            if ProcessInfo.processInfo.arguments.contains("--duplicate-category-fixture") {
                source.exploreUrl = "重复分类::/library/categories/fiction\n重复分类::/library/categories/fiction\n重复分类::/library/categories/alternate"
            }
            var failed = source; failed.id = "fixture-failed"; failed.bookSourceName = "失败测试书源"; failed.searchUrl = "/denied"; failed.exploreUrl = ""; failed.enabled = false
            var partial = SourceTestFixtures.json(); partial.id = "fixture-partial"; partial.bookSourceName = "无结果测试书源"; partial.searchUrl = "/json/noresults"; partial.enabled = false
            store.books = []; store.sources = [source, failed, partial]
            if ProcessInfo.processInfo.arguments.contains("--rss-ui-fixture") {
                if ProcessInfo.processInfo.arguments.contains("--rss-style-ui-fixture") {
                    if ProcessInfo.processInfo.arguments.contains("--reset-source-fixture") {
                        var rss = RssSource()
                        rss.id = "rss-style-fixture"
                        rss.sourceName = "订阅样式测试"
                        rss.sourceUrl = SourceTestFixtures.base
                        rss.header = #"{"X-Fixture":"RSS"}"#
                        rss.singleUrl = false
                        rss.sortUrl = "全部::/rss/style-list"
                        rss.ruleArticles = "@css:article"
                        rss.ruleTitle = "@css:a.title@text"
                        rss.ruleLink = "@css:a.title@href"
                        rss.ruleImage = "img@data-cover"
                        store.rssSources = [rss]
                    }
                } else { store.rssSources = [] }
            }
            if ProcessInfo.processInfo.arguments.contains("--source-switch-fixture") {
                var alternate = source
                alternate.id = "fixture-alternate"; alternate.bookSourceName = "备用测试书源"
                alternate.ruleToc.nextTocUrl = ""
                store.sources.insert(alternate, at: 1)
            }
            if ProcessInfo.processInfo.arguments.contains("--source-stress-fixture") {
                store.sources = (0..<16).map { index in
                    var stress = SourceTestFixtures.json()
                    stress.id = "stress-\(index)"
                    stress.bookSourceName = "压力源\(index)"
                    stress.searchUrl = "/json/many-books?batch=\(index)"
                    return stress
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--user-pack-ui-fixture") || ProcessInfo.processInfo.arguments.contains("--seed-persistent-user-pack") {
                guard persistenceStatus.isEmpty else { return }
                if let raw = try? await fetchText(urlString: SourceTestFixtures.base + "/packs/user") {
                    store.sources = importSourcesDetailed(raw).sources
                    if ProcessInfo.processInfo.arguments.contains("--seed-persistent-user-pack") {
                        do {
                            guard store.sources.count == 1466 else { throw SourceFailure(stage: "测试准备", message: "书源数量不符") }
                            store.save()
                            let saved = try JSONDecoder().decode(BookStore.Meta.self, from: Data(contentsOf: BookStore.metaURL))
                            guard saved.sources.count == 1466 else { throw SourceFailure(stage: "测试准备", message: "持久化的书源数量不符") }
                            persistenceStatus = "持久化书源准备完成"
                        } catch { persistenceStatus = "测试准备失败：\(error.localizedDescription)" }
                    }
                } else if ProcessInfo.processInfo.arguments.contains("--seed-persistent-user-pack") {
                    persistenceStatus = "测试准备失败：无法读取书源合集"
                }
            }
        }.overlay(alignment: .top) {
            if !persistenceStatus.isEmpty { Text(persistenceStatus).font(.caption).padding(6).background(.white) }
        }
        }
    }
}
#endif
