import XCTest

final class SearchAndPreviewUITests: XCTestCase {
    func testDiscoveryPreviewDoesNotAddUntilExplicitlyRequested() { checkPreview(fromSearch: false) }
    func testSearchPreviewDoesNotAddUntilExplicitlyRequested() { checkPreview(fromSearch: true) }

    private func checkPreview(fromSearch: Bool) {
        continueAfterFailure = false; executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--reading-preview-fixture"]
        app.launch()
        defer {
            app.terminate(); app.launchArguments = ["--source-ui-fixture", "--restore-persistent-fixture"]; app.launch()
            XCTAssertTrue(app.staticTexts["持久化测试数据已恢复"].waitForExistence(timeout: 15)); app.terminate()
        }
        let title = "测试小说"
        if fromSearch {
            app.tabBars.buttons["搜索"].tap()
            let field = app.textFields["bookSearch"]
            XCTAssertTrue(field.waitForExistence(timeout: 15)); field.tap(); field.typeText("测试")
            app.buttons["submitBookSearch"].tap()
        } else {
            app.tabBars.buttons["发现"].tap()
            XCTAssertTrue(app.buttons["回归测试书源"].waitForExistence(timeout: 15)); app.buttons["回归测试书源"].tap()
            XCTAssertTrue(app.buttons["分类"].waitForExistence(timeout: 15)); app.buttons["分类"].tap()
        }
        let result = app.buttons.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20)); result.tap()
        XCTAssertTrue(app.staticTexts["目录 · 6 章"].waitForExistence(timeout: 20))
        let start = app.buttons["开始阅读"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed); start.tap()
        XCTAssertTrue(app.textViews["readerPage"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.textViews["readerPage"].label.contains("第1章第1段"))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["返回"].waitForExistence(timeout: 10)); app.buttons["返回"].tap()
        XCTAssertTrue(app.buttons["加入书架"].waitForExistence(timeout: 10)); XCTAssertTrue(app.buttons["加入书架"].isEnabled)
        app.navigationBars["书籍详情"].buttons["关闭"].tap()
        app.tabBars.buttons["书架"].tap()
        XCTAssertTrue(app.staticTexts["书架还空着"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts[title].exists)
        let empty = XCTAttachment(screenshot: app.screenshot()); empty.name = fromSearch ? "搜索试读返回未入架" : "发现试读返回未入架"; empty.lifetime = .keepAlways; add(empty)
        // Restart into the production root: saving progress/cache must not
        // have put the preview in books.json either.
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.staticTexts["书架还空着"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts[title].exists)
        app.tabBars.buttons["发现"].tap()
        XCTAssertTrue(app.buttons["回归测试书源"].waitForExistence(timeout: 15)); app.buttons["回归测试书源"].tap()
        XCTAssertTrue(app.buttons["分类"].waitForExistence(timeout: 15)); app.buttons["分类"].tap()
        XCTAssertTrue(result.waitForExistence(timeout: 20)); result.tap()
        XCTAssertTrue(app.staticTexts["目录 · 6 章"].waitForExistence(timeout: 20))
        let addBook = app.buttons["加入书架"]
        let canAdd = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: addBook)
        XCTAssertEqual(XCTWaiter.wait(for: [canAdd], timeout: 10), .completed); addBook.tap()
        XCTAssertTrue(app.buttons["已在书架"].waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts.matching(identifier: title).count, 1)
    }

    func testExactAndFuzzySearchFilterNoiseAndPersistSelection() {
        continueAfterFailure = false; executionTimeAllowance = 180
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--search-match-fixture"]
        app.launch(); app.tabBars.buttons["搜索"].tap()
        let field = app.textFields["bookSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 15)); field.tap(); field.typeText("仙逆")
        app.buttons["submitBookSearch"].tap()
        XCTAssertTrue(app.staticTexts["仙逆"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["仙逆外传"].exists)
        XCTAssertFalse(app.staticTexts["仙路漫漫"].exists); XCTAssertFalse(app.staticTexts["逆天传"].exists)
        app.buttons["精确搜索"].tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["仙逆外传"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["仙逆"].exists)
        app.buttons["模糊搜索"].tap()
        XCTAssertTrue(app.staticTexts["仙逆外传"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "完整关键词匹配排除单字噪声"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["精确搜索"].tap()
        app.terminate(); app.launchArguments = ["--source-ui-fixture", "--search-match-fixture"]; app.launch()
        app.tabBars.buttons["搜索"].tap()
        XCTAssertTrue(app.buttons["精确搜索"].waitForExistence(timeout: 10)); XCTAssertTrue(app.buttons["精确搜索"].isSelected)
        app.buttons["模糊搜索"].tap()
    }
}
