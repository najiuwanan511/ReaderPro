#if DEBUG
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

struct SourceFixtureRoot: View {
    @StateObject private var store = BookStore()
    @State private var loaded = false
    init() {
        if ProcessInfo.processInfo.arguments.contains("--reset-source-fixture") {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("source-validation.json")
            try? FileManager.default.removeItem(at: url)
        }
    }
    var body: some View {
        TabView {
            NavigationStack { SourceManagementView(store: store) }.tabItem { Label("管理", systemImage: "list.bullet") }
            DiscoveryView(store: store).tabItem { Label("发现", systemImage: "safari") }
            NavigationStack { SourceView(store: store) }.tabItem { Label("搜索", systemImage: "magnifyingglass") }
        }.task {
            guard !loaded else { return }; loaded = true
            var source = SourceTestFixtures.html(); source.id = "fixture-html"
            var failed = source; failed.id = "fixture-failed"; failed.bookSourceName = "失败测试书源"; failed.searchUrl = "/denied"; failed.exploreUrl = ""; failed.enabled = false
            var partial = SourceTestFixtures.json(); partial.id = "fixture-partial"; partial.bookSourceName = "无结果测试书源"; partial.searchUrl = "/json/noresults"; partial.enabled = false
            store.books = []; store.sources = [source, failed, partial]
        }
    }
}
#endif
