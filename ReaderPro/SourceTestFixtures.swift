#if DEBUG || READERPRO_TESTING
import SwiftUI

// Compiled out of the Release IPA. Tests run the production views/engine with
// an isolated simulator sandbox and a local deterministic HTTP server.
enum SourceTestFixtures {
    static func login() -> LegadoSource {
        var source = html(); source.id = "fixture-login"
        source.bookSourceName = "登录接口测试源"
        source.loginUrl = #"""
        function applyRoute(){source.setVariable(result.get('接口'));java.upLoginData({'当前接口':'当前接口：'+result.get('接口')});java.reLoginView();java.refreshExplore();java.toast('接口已切换')}
        function login(){var info=source.getLoginInfoMap();if(!info.get('账号')||!info.get('密码'))throw Error('请输入账号和密码');source.putLoginHeader(JSON.stringify({'X-Login-Fixture':info.get('账号')}));java.toast('登录成功')}
        """#
        source.loginUi = #"""
        [{"name":"账号","type":"text","style":{"layout_flexBasisPercent":1}},
         {"name":"密码","type":"password","style":{"layout_flexBasisPercent":1}},
         {"name":"接口","type":"select","chars":["接口一","接口二"],"default":"接口一","action":"applyRoute()","style":{"layout_flexBasisPercent":1}},
         {"name":"当前接口","type":"button","viewName":"'当前接口：'+(source.getVariable()||'接口一')","style":{"layout_flexBasisPercent":1}}]
        """#
        source.exploreUrl = "@js:(source.getVariable()||'接口一')+'分类::/library/categories/fiction'"
        return source
    }
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
    // Content and directory rules copied unchanged from source 112 of the
    // user-provided 1330 pack; fixture pages contain only synthetic videos.
    static func video() -> LegadoSource {
        var source = LegadoSource()
        source.id = "fixture-video"; source.bookSourceType = 4
        source.bookSourceName = "短剧视频测试源"; source.bookSourceUrl = base
        source.exploreUrl = "短剧分类::/video/list"
        source.header = #"{"X-Video":"ReaderPro","Referer":"http://127.0.0.1:8765/video/book"}"#
        source.ruleExplore.bookList = "a.drama"
        source.ruleExplore.name = "text"; source.ruleExplore.bookUrl = "href"
        source.ruleBookInfo.name = "h1@text"
        source.ruleToc.chapterList = "a.dm-ep"
        source.ruleToc.chapterName = #"""
        @js:(function(){
          var html=String(result||'');
          var freeM=html.match(/data-ep-free="(\d+)"/);
          var titleM=html.match(/title="(\d+)/);
          var n=titleM?titleM[1]:'';
          var name=n?('第'+n+'集'):'';
          if(freeM&&freeM[1]==='0')name+=' 🔒';
          return name;
        })()
        """#
        source.ruleToc.chapterUrl = "@href"
        source.ruleContent.content = #"""
        @js:(function(){
          var html=String(result||'');
          var ep='';var em=String(baseUrl||'').match(/[?&]ep=(\d+)/);
          if(em)ep=em[1];
          var src='';
          if(ep){
            var re=new RegExp('data-ep="'+ep+'"[^>]*data-ep-src="([^"]+)"');
            var m=html.match(re);
            if(m)src=m[1];
          }
          if(!src){var m3=html.match(/data-ep-src="([^"]+)"/);if(m3)src=m3[1];}
          if(!src){var m4=html.match(/data-video-src="([^"]+)"/);if(m4)src=m4[1];}
          if(src&&src.indexOf('http')<0)src='https://huangdoudj.com'+src;
          return src;
        })()
        """#
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
        let fixtureStore = BookStore()
        // The boundary fixture deliberately exercises every page mode and
        // persists progress. Other UI fixtures expect the normal page reader.
        if ProcessInfo.processInfo.arguments.contains("--reset-source-fixture") {
            fixtureStore.pageTurn = 1
        }
        _store = StateObject(wrappedValue: fixtureStore)
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
        }.modifier(SourceAppLinkReceiver(store: store)).task {
            guard !loaded else { return }; loaded = true
            var source = SourceTestFixtures.html(); source.id = "fixture-html"
            if ProcessInfo.processInfo.arguments.contains("--source-login-fixture") { source = SourceTestFixtures.login() }
            if ProcessInfo.processInfo.arguments.contains("--source-web-login-fixture") {
                source.loginUrl = "/login/web"; source.bookSourceName = "网页登录测试源"
                source.searchUrl = "/login/protected?key={{key}}"
            }
            if ProcessInfo.processInfo.arguments.contains("--source-verification-fixture") {
                source.bookSourceName = "等待验证测试源"
                source.searchUrl = "@js:java.startBrowserAwait(source.bookSourceUrl+'/login/web','搜索验证',false);source.bookSourceUrl+'/login/protected?key='+key"
            }
            if ProcessInfo.processInfo.arguments.contains("--reset-source-fixture") &&
                (ProcessInfo.processInfo.arguments.contains("--source-login-fixture") || ProcessInfo.processInfo.arguments.contains("--source-web-login-fixture")) {
                try? SourceLoginInfo.remove(source.bookSourceUrl); try? SourceLoginHeaders.remove(source.bookSourceUrl)
                UserDefaults.standard.removeObject(forKey: "ReaderPro.sourceVariable." + source.bookSourceUrl)
                for cookie in HTTPCookieStorage.shared.cookies ?? [] { HTTPCookieStorage.shared.deleteCookie(cookie) }
            }
            if ProcessInfo.processInfo.arguments.contains("--discovery-pages-fixture") {
                source.exploreUrl = "分页分类::/discovery/pages?page={{page}}"
            }
            if ProcessInfo.processInfo.arguments.contains("--app-link-ui-fixture") {
                var link = URLComponents(string: "legado://import/bookSource")!
                link.queryItems = [URLQueryItem(name: "src", value: #"{"bookSourceName":"一键导入测试源","bookSourceUrl":"https://app-link.test","exploreUrl":"分类::/list"}"#)]
                source.exploreUrl = "[{\"title\":\"一键导入\",\"type\":\"button\",\"action\":" + sourceJSONString("java.openUrl(" + sourceJSONString(link.url!.absoluteString) + ")") + "}]"
            }
            if ProcessInfo.processInfo.arguments.contains("--theme-link-ui-fixture") {
                var link = URLComponents(string: "legado://import/theme")!
                link.queryItems = [URLQueryItem(name: "src", value: ##"{"themeName":"主题导入样例","isNightTheme":false,"primaryColor":"#3949AB","accentColor":"#00897B","backgroundColor":"#F4F1E8","bottomBackground":"#E8E2D3","transparentNavBar":false,"backgroundImgPath":null,"backgroundImgBlur":0}"##)]
                source.exploreUrl = "[{\"title\":\"导入主题\",\"type\":\"button\",\"action\":" + sourceJSONString("java.openUrl(" + sourceJSONString(link.url!.absoluteString) + ")") + "}]"
            }
            if ProcessInfo.processInfo.arguments.contains("--duplicate-category-fixture") {
                source.exploreUrl = "重复分类::/library/categories/fiction\n重复分类::/library/categories/fiction\n重复分类::/library/categories/alternate"
            }
            if ProcessInfo.processInfo.arguments.contains("--discovery-controls-fixture") {
                source.bookSourceGroup = "小说,测试"; source.customOrder = 1
                source.exploreUrl = #"""
                @js:
                var channel=infoMap.get('频道') || '小说';
                [
                  {title:'频道分类',style:{layout_flexBasisPercent:1}},
                  {title:'关键词',type:'text',action:'infoMap.save()'},
                  {title:'模式',type:'toggle',chars:['关','开'],default:'关',action:'infoMap.save();java.refreshExplore()'},
                  {title:'频道',type:'select',chars:['小说','其他'],default:'小说',action:'infoMap.save();java.refreshExplore()'},
                  {title:'更新',type:'button',viewName:"'刷新参数'",action:"java.longToast('发现参数已更新');infoMap.put('更新次数',String(Number(infoMap.get('更新次数')||0)+1));infoMap.save();java.refreshExplore()"},
                  {title:'打开'+channel,url:channel==='小说'?'/library/categories/fiction':'/library/categories/alternate',style:{layout_wrapBefore:true}},
                  {title:'更新次数'+(infoMap.get('更新次数')||'0')},
                  {title:'ERROR:分类说明',url:'请先登录并在接口设置中选择线路。'},
                  {title:'空名称',viewName:"String()"}
                ]
                """#
                _ = ExploreInfo.bridge(source.bookSourceUrl, "clear", "[]")
            }
            var failed = source; failed.id = "fixture-failed"; failed.bookSourceName = "失败测试书源"; failed.searchUrl = "/denied"; failed.exploreUrl = ""; failed.enabled = false
            var partial = SourceTestFixtures.json(); partial.id = "fixture-partial"; partial.bookSourceName = "无结果测试书源"; partial.searchUrl = "/json/noresults"; partial.enabled = false
            store.books = []; store.sources = [source, failed, partial]
            if ProcessInfo.processInfo.arguments.contains("--discovery-controls-fixture") {
                var alternate = SourceTestFixtures.html()
                alternate.id = "discovery-only-fixture"; alternate.bookSourceUrl += "/discover-only"
                alternate.bookSourceName = "仅发现书源"; alternate.enabled = false; alternate.enabledExplore = true
                alternate.bookSourceGroup = "漫画,测试"; alternate.customOrder = 2
                store.sources.append(alternate)
            }
            if ProcessInfo.processInfo.arguments.contains("--video-ui-fixture") {
                store.sources = [SourceTestFixtures.video()]
                if ProcessInfo.processInfo.arguments.contains("--video-script-fixture") {
                    store.sources[0].exploreUrl = #"[{"title":"脚本播放","type":"button","action":"java.openVideoPlayer(source.bookSourceUrl+'/video/episode1.mp4','脚本直达视频',true)"}]"#
                }
                if ProcessInfo.processInfo.arguments.contains("--video-error-fixture") { store.sources[0].ruleContent.content = "@js:''" }
                if ProcessInfo.processInfo.arguments.contains("--video-web-fixture") {
                    store.sources[0].ruleContent.content = "@js:java.startBrowser('/video/embed?ep='+(chapter.index+1),title); result='';"
                }
                if ProcessInfo.processInfo.arguments.contains("--video-hls-fixture") {
                    store.sources[0].ruleContent.content = "@js:'http://127.0.0.1:8765/video/hls/index.m3u8';"
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--discovery-scroll-fixture") {
                store.sources = (0..<40).map { index in
                    var item = SourceTestFixtures.html()
                    item.id = "scroll-\(index)"; item.bookSourceUrl += "/scroll-\(index)"
                    item.bookSourceName = "滚动书源\(index)"; item.customOrder = index
                    item.exploreUrl = (0..<80).map { "分类\($0)::/video/list" }.joined(separator: "\n")
                    return item
                }
            }
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
