import XCTest
import Combine
@testable import ReaderPro

final class SourceImportLoginTests: XCTestCase {
    func testImportRetainsAndroidLoginUIAndCheckScript() throws {
        let raw = #"[{"bookSourceName":"登录源","bookSourceUrl":"https://login.invalid","loginUi":[{"name":"接口","type":"select","chars":["接口一","接口二"]}],"loginCheckJs":"result"}]"#
        // Real packs use a JSON string for loginUi; tolerate an actual JSON
        // array too, as Android exporters can emit both representations.
        let source = try XCTUnwrap(importSourceDocument(raw).sources.first)
        let restored = try JSONDecoder().decode(LegadoSource.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(restored.loginUi, source.loginUi); XCTAssertEqual(restored.loginCheckJs, "result")
        XCTAssertEqual(try SourceLoginRow.parse(restored.loginUi).first?.choices, ["接口一", "接口二"])
    }

    func testLoginFormChangesRouteAndRefreshesDiscoveryUsingPersistedValues() async throws {
        var source = SourceTestFixtures.login()
        source.bookSourceUrl += "/route-" + UUID().uuidString
        defer { try? SourceLoginInfo.remove(source.bookSourceUrl) }
        let first = try await Task.detached { try await source.loginSnapshot() }.value
        XCTAssertEqual(first.values["接口"], "接口一")
        var values = first.values; values["接口"] = "接口二"
        let second = try await Task.detached { try await source.loginSnapshot(values: values, action: "applyRoute()") }.value
        XCTAssertEqual(second.values["接口"], "接口二")
        XCTAssertTrue(second.rows.contains { $0.displayName == "当前接口：接口二" })
        XCTAssertEqual(SourceLoginInfo.map(source.bookSourceUrl)["接口"], "接口二")
        let categories = try await source.resolvedExploreCategories()
        XCTAssertEqual(categories.first?.title, "接口二分类")
        let reopened = try await Task.detached { try await source.loginSnapshot() }.value
        XCTAssertEqual(reopened.values["接口"], "接口二")
    }

    func testLoginUsesJavaMapAndStoredCredentialsAndHeaders() async throws {
        var source = SourceTestFixtures.login(); source.bookSourceUrl += "/auth-" + UUID().uuidString
        defer { try? SourceLoginInfo.remove(source.bookSourceUrl); try? SourceLoginHeaders.remove(source.bookSourceUrl) }
        let snapshot = try await Task.detached {
            try await source.loginSnapshot(values: ["账号":"reader", "密码":"test-secret", "接口":"接口二"], action: "login()")
        }.value
        XCTAssertEqual(snapshot.message, "登录成功")
        XCTAssertEqual(SourceLoginHeaders.map(source.bookSourceUrl)?["X-Login-Fixture"], "reader")
        let json = try XCTUnwrap(SourceLoginInfo.get(source.bookSourceUrl))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String:String])?["账号"], "reader")
        let output = try await Task.detached {
            try await source.withRules {
                LegadoJS.run("source.getLoginInfoMap().get('接口')", input: "", baseUrl: source.bookSourceUrl, sourceKey: "", sourceUrl: source.bookSourceUrl)
            }
        }.value
        XCTAssertEqual(output, "接口二")
    }

    func testDynamicRowsUpdatesAndLongClickAreExecuted() async throws {
        var source = SourceTestFixtures.login(); source.bookSourceUrl += "/dynamic-" + UUID().uuidString
        source.loginUi = "@js:JSON.stringify([{name:'显示',type:'button',viewName:\"'当前：'+(source.getVariable()||'初始')\",action:'change()'}, {name:'值',type:'text',default:'原值'}])"
        source.loginUrl = "function change(){source.setVariable(isLongClick?'长按':'点击');java.upLoginData({'值':'新值'});java.reLoginView(true)}"
        defer { try? SourceLoginInfo.remove(source.bookSourceUrl) }
        let output = try await Task.detached { try await source.loginSnapshot(action: "change()", longClick: true) }.value
        XCTAssertEqual(output.values["值"], "新值")
        XCTAssertEqual(output.rows.first?.displayName, "当前：长按")
    }

    func testBadDisplayNameDoesNotDiscardControlsAndActionFailureIsReported() async throws {
        var source = SourceTestFixtures.login(); source.bookSourceUrl += "/error-" + UUID().uuidString
        source.loginUi = #"[{"name":"接口","type":"select","chars":["一","二"],"viewName":"throw Error('label')"}]"#
        defer { try? SourceLoginInfo.remove(source.bookSourceUrl) }
        let output = try await Task.detached { try await source.loginSnapshot() }.value
        XCTAssertEqual(output.rows.first?.displayName, "err"); XCTAssertEqual(output.rows.first?.choices, ["一","二"])
        do { _ = try await Task.detached { try await source.loginSnapshot(action: "throw Error('接口连接失败')") }.value; XCTFail("An action error must reach the UI") }
        catch { XCTAssertTrue(sourceErrorMessage(error).contains("接口连接失败")) }
    }

    func testWebLoginResolvesRelativeURLAndDoesNotTreatScriptAsWebsite() {
        var source = LegadoSource(); source.bookSourceUrl = "https://example.org/"; source.loginUrl = "/login"
        XCTAssertEqual(source.webLoginURL, "https://example.org/login")
        source.loginUrl = "<js>function login(){return true}</js>"; XCTAssertNil(source.webLoginURL)
        source.loginUrl = "function login(){return true}"; XCTAssertNil(source.webLoginURL)
    }

    @MainActor func testLargeImportPublishesOnceAndReimportPreservesIDs() throws {
        let store = BookStore(); store.sources = []
        let incoming = (0..<1500).map { i -> LegadoSource in
            var source = LegadoSource(); source.bookSourceUrl = "https://batch-\(i).invalid"; source.bookSourceName = "源\(i)"; return source
        }
        var notifications = 0
        let subscription = store.$sources.dropFirst().sink { _ in notifications += 1 }
        defer { subscription.cancel() }
        XCTAssertEqual(store.mergeSources(incoming, persist: false).added, 1500)
        XCTAssertEqual(notifications, 1, "A large collection must publish one update, not 1500 complete array snapshots")
        let ids = store.sources.map(\.id)
        XCTAssertEqual(store.mergeSources(incoming, persist: false).updated, 1500)
        XCTAssertEqual(store.sources.map(\.id), ids); XCTAssertEqual(notifications, 2)
    }

    func testFullSized1500SourceDocumentImportBudgetAndNoRuleExecution() async throws {
        let start = Date()
        let document = try await Task.detached { () throws -> SourcePackImportResult in
            let padding = String(repeating: "这是保留的原始脚本注释\\n", count: 500)
            let rows = (0..<1500).map { i in
                ["bookSourceName":"性能源\(i)", "bookSourceUrl":"https://perf-\(i).invalid", "bookSourceComment":padding,
                 "loginUrl":"throw Error('导入不可执行登录脚本')", "exploreUrl":"@js:while(true){}",
                 "ruleContent":["content":"@js:throw Error('不可校验')"]] as [String:Any]
            }
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["data": rows]), as: UTF8.self)
            let parsedAt = Date(); let document = importSourceDocument(raw)
            print("IMPORT_PERF_JSON_BYTES=\(raw.utf8.count) PARSE_SECONDS=\(Date().timeIntervalSince(parsedAt))")
            return document
        }.value
        let elapsed = Date().timeIntervalSince(start)
        print("IMPORT_PERF_1500_TOTAL_SECONDS=\(elapsed)")
        XCTAssertEqual(document.sources.count, 1500); XCTAssertEqual(document.skipped, 0)
        XCTAssertLessThan(elapsed, 15, "Local parsing must finish in seconds; it must not execute source scripts or validate websites")
    }
}
