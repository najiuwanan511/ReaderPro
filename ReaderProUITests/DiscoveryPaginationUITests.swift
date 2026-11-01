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
}

private extension XCUIElement {
    func clearAndEnterText(_ text: String) {
        let current = value as? String ?? ""
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
}
