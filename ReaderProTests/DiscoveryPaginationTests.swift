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
        XCTAssertEqual(rows[0][1].1, 144, accuracy: 0.01)
        XCTAssertEqual(rows[1][0].1, 103.5, accuracy: 0.01)
        XCTAssertEqual(rows[1][1].1, 190.5, accuracy: 0.01)
        let long = ExploreFlowGeometry.widths(container: 200, sizes: [CGSize(width: 1200,height: 20)], styles: [ExploreStyle()])
        XCTAssertEqual(long[0][0].1, 200)
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
