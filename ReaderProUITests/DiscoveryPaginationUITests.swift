import XCTest

final class DiscoveryPaginationUITests: XCTestCase {
    func testDiscoveryLoadsNextPageAndCanJumpBack() {
        continueAfterFailure = false
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--discovery-pages-fixture"]
        app.launch()
        app.tabBars.buttons["发现"].tap()
        XCTAssertTrue(app.buttons["回归测试书源"].waitForExistence(timeout: 15))
        app.buttons["回归测试书源"].tap()
        let category = app.buttons["分页分类"]
        XCTAssertTrue(category.waitForExistence(timeout: 15)); category.tap()
        XCTAssertTrue(app.staticTexts["发现第1页小说"].waitForExistence(timeout: 30))
        let more = app.buttons["discoveryLoadMore"]
        XCTAssertTrue(more.waitForExistence(timeout: 10)); more.tap()
        XCTAssertTrue(app.staticTexts["发现第2页小说"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["发现第1页小说"].exists)
        app.swipeUp()
        XCTAssertTrue(more.waitForExistence(timeout: 10)); more.tap()
        XCTAssertTrue(app.staticTexts["没有更多了"].waitForExistence(timeout: 30))
        app.buttons["discoveryPagePicker"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        field.clearAndEnterText("1")
        app.alerts.buttons["跳转"].tap()
        XCTAssertTrue(app.staticTexts["发现第1页小说"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["发现第2页小说"].exists)
    }
    func testDiscoveryControlsRefreshCategoriesAndNavigateToSelectedChannel() {
        continueAfterFailure = false
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--discovery-controls-fixture"]
        app.launch()
        app.tabBars.buttons["发现"].tap()
        let source = app.buttons["回归测试书源"]
        XCTAssertTrue(source.waitForExistence(timeout: 15)); source.tap()
        XCTAssertTrue(app.staticTexts["频道分类"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["explore-category-0"].exists, "A section heading must not navigate")
        let input = app.textFields["explore-input-1"]
        XCTAssertTrue(input.exists); input.tap(); input.typeText("测试")
        app.buttons["explore-toggle-2"].tap()
        XCTAssertTrue(app.buttons["开模式"].waitForExistence(timeout: 15))
        app.buttons["explore-select-3"].tap()
        app.buttons["其他"].tap()
        XCTAssertTrue(app.buttons["打开其他"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.textFields["explore-input-1"].value as? String, "测试")
        app.buttons["explore-button-4"].tap()
        XCTAssertTrue(app.staticTexts["更新次数1"].waitForExistence(timeout: 15))
        app.buttons["explore-button-4"].tap()
        XCTAssertTrue(app.staticTexts["更新次数2"].waitForExistence(timeout: 15))
        // Match the original source-header long-press refresh entry.
        source.press(forDuration: 1)
        let refresh = app.buttons["刷新发现分类"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10)); refresh.tap()
        XCTAssertTrue(app.buttons["打开其他"].waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "发现分类控件与分区"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["打开其他"].tap()
        XCTAssertTrue(app.staticTexts["另一本小说"].waitForExistence(timeout: 60))
    }

    func testDiscoveryRealGroupsAndOnlyOneExpandedSource() {
        continueAfterFailure = false
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--discovery-controls-fixture"]
        app.launch()
        app.tabBars.buttons["发现"].tap()
        let first = app.buttons["回归测试书源"]
        let second = app.buttons["仅发现书源"]
        XCTAssertTrue(second.waitForExistence(timeout: 15), "Discovery must remain available when search is disabled")
        first.tap()
        XCTAssertTrue(app.staticTexts["频道分类"].waitForExistence(timeout: 15))
        second.tap()
        XCTAssertTrue(app.buttons["分类"].waitForExistence(timeout: 15))
        XCTAssertEqual(first.value as? String, "已折叠")
        XCTAssertFalse(app.staticTexts["频道分类"].exists)
        app.buttons["发现书源分组"].tap()
        let group = app.buttons["小说"]
        XCTAssertTrue(group.waitForExistence(timeout: 10)); group.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 10)); XCTAssertFalse(second.exists)
        app.buttons["发现书源分组"].tap()
        app.buttons["全部分组"].tap()
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "发现书源与真实分组"; shot.lifetime = .keepAlways; add(shot)
    }

}

private extension XCUIElement {
    func clearAndEnterText(_ text: String) {
        let current = value as? String ?? ""
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
}
