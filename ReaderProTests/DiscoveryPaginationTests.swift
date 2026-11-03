import Foundation
import SwiftUI
import XCTest
@testable import ReaderPro

private final class DiscoveryPageProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "discover-pages.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value ?? "1"
        let body = page == "1" ? #"{"items":[{"name":"第一页","url":"/book/1"}]}"#
            : page == "2" ? #"{"items":[{"name":"第二页","url":"/book/2"}]}"# : #"{"items":[]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class DiscoveryPaginationTests: XCTestCase {
    func testDiscoveryScriptsCanReadSourceNameAndNotificationTag() async throws {
        var source = LegadoSource()
        source.bookSourceUrl = "https://discovery-tag.test"
        source.bookSourceName = "回归测试书源"
        try await source.withRules {
            let value = LegadoJS.run("[source.bookSourceName,java.getSource().bookSourceName,java.getTag()].join('|')",
                                     input: "", baseUrl: source.bookSourceUrl, sourceKey: "", sourceUrl: source.bookSourceUrl)
            try LegadoJSCtx.failures?.check()
            XCTAssertEqual(value, "回归测试书源|回归测试书源|回归测试书源")
        }
    }

    func testDiscoveryExpandsRequestedPageAndEndsOnEmptyLaterPage() async throws {
        var source = LegadoSource()
        source.bookSourceUrl = "https://discover-pages.test"
        source.ruleExplore.bookList = "$.items[*]"
        source.ruleExplore.name = "$.name"
        source.ruleExplore.bookUrl = "$.url"
        let category = ExploreCategory(title: "分类", url: "/list?page={{page}}")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryPageProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        try await SourceHTTP.$testSession.withValue(session) {
            let first = try await source.discover(category: category)
            let second = try await source.discover(category: category, page: 2)
            let end = try await source.discover(category: category, page: 3)
            XCTAssertEqual(first.map(\.title), ["第一页"])
            XCTAssertEqual(second.map(\.title), ["第二页"])
            XCTAssertTrue(end.isEmpty)
        }
    }
    func testJSONCategoriesPreserveHeadingsControlsAndSourceStylesBeforeTextSeparators() throws {
        let text = #"""
        [
          {title:'分区::标题',style:{layout_flexBasisPercent:1,layout_wrapBefore:true}},
          {title:'重复',url:'/list?q=a&&tag=b::c'},
          {title:'重复',url:'/list?q=a&&tag=b::c'},
          {title:'输入',type:'text',action:'infoMap.save()'},
          {title:'开关',type:'toggle',chars:[null,'关','开'],default:'开',viewName:"'模式'",
           style:{layout_flexGrow:2,layout_flexShrink:0,layout_alignSelf:'center',layout_justifySelf:'right'}},
          {title:'选择',type:'select',chars:['甲','乙']},
          {title:'刷新',type:'button',action:'java.refreshExplore()'}
        ]
        """#
        let categories = ExploreCategory.parse(text)
        XCTAssertEqual(categories.count, 7)
        XCTAssertEqual(categories[0].title, "分区::标题")
        XCTAssertFalse(categories[0].canNavigate)
        XCTAssertEqual(categories[0].style.basisPercent, 1)
        XCTAssertTrue(categories[0].style.wrapBefore)
        XCTAssertEqual(categories[1].url, "/list?q=a&&tag=b::c")
        XCTAssertEqual(categories[1], categories[2])
        XCTAssertEqual(categories[3].type, "text")
        XCTAssertEqual(categories[4].choices, ["关", "开"])
        XCTAssertEqual(categories[4].defaultValue, "开")
        XCTAssertEqual(categories[4].style.grow, 2)
        XCTAssertEqual(categories[4].style.shrink, 0)
        XCTAssertEqual(categories[4].style.alignSelf, "center")
        XCTAssertEqual(categories[4].style.justifySelf, "right")
        XCTAssertEqual(categories[5].type, "select")
        XCTAssertEqual(categories[6].action, "java.refreshExplore()")
    }

    func testTextCategoriesKeepSectionHeadingsAndRepeatedItems() {
        let result = ExploreCategory.parse("男频\n玄幻::/x&&仙侠::/y\n女频::\n言情::/z\n言情::/z")
        XCTAssertEqual(result.map(\.title), ["男频", "玄幻", "仙侠", "女频", "言情", "言情"])
        XCTAssertEqual(result.filter(\.canNavigate).count, 4)
        XCTAssertEqual(ExploreCategory.parse("https://example.test/list").first?.url, "https://example.test/list")
    }

    func testInteractiveCategoriesShareInfoMapAndRefreshIntoNewURLs() async throws {
        var source = LegadoSource()
        source.bookSourceUrl = "https://explore-map.test/" + UUID().uuidString
        source.jsLib = "function channel(){return infoMap.get('频道') || '甲';}"
        source.exploreUrl = #"""
        @js: [
          {title:'频道',type:'select',chars:['甲','乙'],default:'甲',action:"infoMap.save();java.refreshExplore();"},
          {title:'模式',type:'toggle',chars:['关','开'],default:'开'},
          {title:'提示',url:'/list/'+channel(),viewName:"'当前'+channel()"},
          {title:'文字',type:'text',viewName:"'输入关键词'"}
        ]
        """#
        let initial = try await source.resolvedExploreCategories()
        XCTAssertEqual(initial[2].url, "/list/甲")
        XCTAssertEqual(initial[2].displayTitle, "当前甲")
        XCTAssertEqual(initial[3].displayTitle, "输入关键词")
        XCTAssertEqual(ExploreInfo.value(source.bookSourceUrl, "模式"), "开")
        ExploreInfo.put(source.bookSourceUrl, "频道", "乙")
        let refreshed = try await source.performExploreAction(initial[0])
        XCTAssertTrue(refreshed)
        let updated = try await source.resolvedExploreCategories()
        XCTAssertEqual(updated[2].url, "/list/乙")
        XCTAssertEqual(updated[2].displayTitle, "当前乙")
        ExploreInfo.savePending(source.bookSourceUrl)
        let record = UserDefaults.standard.dictionary(forKey: "explore.info." + source.bookSourceUrl)
        XCTAssertEqual((record?["map"] as? [String:String])?["频道"], "乙")
        UserDefaults.standard.removeObject(forKey: "explore.info." + source.bookSourceUrl)
    }

    func testInfoMapOperationsRemainIsolatedAndDoNotFireActionsOnInitialization() async throws {
        var source = LegadoSource()
        source.bookSourceUrl = "https://explore-isolation.test/" + UUID().uuidString
        source.exploreUrl = #"""
        @js:
        infoMap.putAll({a:'1',b:'2'});
        var old = infoMap.put('a','3');
        var removed = infoMap.remove('b');
        var keys = infoMap.keySet().toArray().join(',');
        if (old!=='1' || removed!=='2' || infoMap.size()!==1 || keys!=='a' || !infoMap.containsKey('a') || !infoMap.containsValue('3')) throw Error('map contract');
        [{title:'默认',type:'toggle',chars:['甲','乙'],action:"throw Error('initial action must not run')"}]
        """#
        let categories = try await source.resolvedExploreCategories()
        XCTAssertEqual(categories.count, 1)
        XCTAssertEqual(ExploreInfo.value(source.bookSourceUrl, "默认"), "甲")
        XCTAssertEqual(ExploreInfo.value(source.bookSourceUrl + "other", "a"), "")
        var broken = ExploreCategory(title: "错误", url: "", type: "button")
        broken.action = "throw Error('action failure is visible')"
        do { _ = try await source.performExploreAction(broken); XCTFail("Script failures must propagate") }
        catch { XCTAssertTrue(sourceErrorMessage(error).contains("action failure is visible")) }
    }

    func testBrokenDynamicNameDoesNotDiscardWorkingCategoryLinks() async throws {
        var source = LegadoSource()
        source.bookSourceUrl = "https://explore-name.test/" + UUID().uuidString
        source.exploreUrl = #"[{title:'可读分类',url:'/working',viewName:"throw Error('broken display name')"}]"#
        let result = try await source.resolvedExploreCategories()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].url, "/working")
        XCTAssertTrue(result[0].canNavigate)
        XCTAssertEqual(result[0].displayTitle, "err")
        XCTAssertTrue(result[0].displayError?.contains("broken display name") == true)
    }

    func testDiscoveryLoginRefreshCallbackRebuildsCategoriesWithoutChangingLoginData() async throws {
        var source = LegadoSource()
        source.bookSourceUrl = "https://explore-login-callback.test/" + UUID().uuidString
        source.exploreUrl = #"@js: [{title:infoMap.get('频道')||'甲',url:'/list'}]"#
        let initial = try await source.resolvedExploreCategories()
        XCTAssertEqual(initial.map(\.title), ["甲"])
        for call in ["java.reLoginView()", "java.reLoginView(true)", "java.reUiView(false)"] {
            let action = ExploreCategory(title: "切换", url: "", type: "button",
                action: "infoMap.put('频道','乙');java.upLoginData({'频道':'不能写入登录表单'});" + call)
            let revision = ExploreInfo.revision(source.bookSourceUrl)
            let refreshed = try await source.performExploreAction(action)
            XCTAssertTrue(refreshed)
            XCTAssertEqual(ExploreInfo.revision(source.bookSourceUrl), revision + 1)
            let updated = try await source.resolvedExploreCategories()
            XCTAssertEqual(updated.map(\.title), ["乙"])
            XCTAssertNil(SourceLoginInfo.map(source.bookSourceUrl)["频道"])
        }
    }

    func testAndroidDiagnosticCategoryIsNotARequestAndEmptyDynamicNamesShowNull() async throws {
        let diagnostic = ExploreCategory(title: "ERROR:需要登录", url: "请先登录并选择接口")
        XCTAssertEqual(diagnostic.diagnosticMessage, "请先登录并选择接口")
        XCTAssertFalse(diagnostic.canNavigate)
        var source = LegadoSource()
        source.bookSourceUrl = "https://explore-diagnostic.test"
        source.exploreUrl = #"[{title:'空名称',viewName:"String()"},{title:'ERROR:说明',url:'这是一条书源提示'},{title:'正常分类',url:'/working'}]"#
        let categories = try await source.resolvedExploreCategories()
        XCTAssertEqual(categories[0].displayTitle, "null")
        XCTAssertEqual(categories.filter(\.canNavigate).map(\.title), ["正常分类"])
        do {
            _ = try await source.discover(category: diagnostic)
            XCTFail("Diagnostic text must never become an HTTP request")
        } catch {
            XCTAssertTrue(sourceErrorMessage(error).contains("没有书籍列表地址"))
        }
    }

    func testDiscoverySourceGroupsOrderAndIndependentEnableSwitch() throws {
        var first = LegadoSource(); first.id = "a"; first.bookSourceName = "源甲"; first.exploreUrl = "/list"
        first.enabled = false; first.enabledExplore = true; first.customOrder = 3; first.bookSourceGroup = "小说, 测试"
        var second = first; second.id = "b"; second.bookSourceName = "源乙"; second.bookSourceGroup = "轻小说，测试"; second.customOrder = 1
        var hidden = first; hidden.id = "c"; hidden.enabledExplore = false; hidden.bookSourceGroup = "隐藏"
        XCTAssertEqual(ExploreSources.filter([first,second,hidden]).map(\.id), ["b","a"])
        XCTAssertEqual(ExploreSources.filter([first,second], group: "小说").map(\.id), ["a"])
        XCTAssertEqual(ExploreSources.filter([first,second], query: "轻小说").map(\.id), ["b"])
        XCTAssertEqual(Set(ExploreSources.groups([first,second,hidden])), Set(["小说","轻小说","测试"]))
        let decoded = try JSONDecoder().decode(LegadoSource.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(decoded.customOrder, 3)
        var changed = first; changed.jsLib = "changed"
        XCTAssertNotEqual(changed.exploreCacheKey, first.exploreCacheKey)
        changed = first; changed.header = "changed"
        XCTAssertNotEqual(changed.exploreCacheKey, first.exploreCacheKey)
    }

    func testFlexPercentGrowWrapAndLongLabels() {
        let sizes = Array(repeating: CGSize(width: 60, height: 26), count: 4)
        var first = ExploreStyle(); first.basisPercent = 0.5
        var second = ExploreStyle(); second.grow = 1
        var third = ExploreStyle(); third.wrapBefore = true; third.grow = 1
        var fourth = ExploreStyle(); fourth.grow = 3
        let rows = ExploreFlowGeometry.widths(container: 300, sizes: sizes, styles: [first,second,third,fourth])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][0].1, 150, accuracy: 0.01)
        XCTAssertEqual(rows[0][1].1, 124, accuracy: 0.01)
        XCTAssertEqual(rows[1][0].1, 98.5, accuracy: 0.01)
        XCTAssertEqual(rows[1][1].1, 175.5, accuracy: 0.01)
        let long = ExploreFlowGeometry.widths(container: 200, sizes: [CGSize(width: 1200,height: 20)], styles: [ExploreStyle()])
        XCTAssertEqual(long[0][0].1, 188)
        var full = ExploreStyle(); full.basisPercent = 1
        XCTAssertEqual(ExploreFlowGeometry.widths(container: 200, sizes: [.zero], styles: [full])[0][0].1, 188)
        full.shrink = 0
        XCTAssertEqual(ExploreFlowGeometry.widths(container: 200, sizes: [.zero], styles: [full])[0][0].1, 200)
    }

    func testAndroidCategoryDividersChangeWrappingAndPercentWidth() {
        // Three 60 dp controls require: 6 padding + 18 margins + 16
        // middle dividers + 180 content = 220 dp, matching Android XML.
        let sizes = Array(repeating: CGSize(width: 60, height: 26), count: 3)
        let styles = Array(repeating: ExploreStyle(), count: 3)
        XCTAssertEqual(ExploreFlowGeometry.widths(container: 220, sizes: sizes, styles: styles).count, 1)
        XCTAssertEqual(ExploreFlowGeometry.widths(container: 219, sizes: sizes, styles: styles).count, 2)
        var half = ExploreStyle(); half.basisPercent = 0.5
        let rows = ExploreFlowGeometry.widths(container: 220, sizes: sizes, styles: [half, half, half])
        XCTAssertEqual(rows.map(\.count), [1, 1, 1], "Percent widths include margins and must wrap as on Android")
        XCTAssertEqual(rows[0][0].1, 110)
    }

    func testDefaultDiscoverySkipsSectionLabelsAndNeverRequestsControlURLs() async throws {
        var source = LegadoSource()
        source.bookSourceUrl = "https://discover-pages.test"
        source.exploreUrl = "分区标题\n分类::/list?page={{page}}"
        source.ruleExplore.bookList = "$.items[*]"; source.ruleExplore.name = "$.name"; source.ruleExplore.bookUrl = "$.url"
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DiscoveryPageProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        try await SourceHTTP.$testSession.withValue(session) {
            let books = try await source.discover()
            XCTAssertEqual(books.map(\.title), ["第一页"])
        }
        do { _ = try await source.discover(category: ExploreCategory(title: "标题", url: "")); XCTFail("Headings must not open the source homepage") }
        catch { XCTAssertTrue(sourceErrorMessage(error).contains("没有书籍列表地址")) }
    }

}
