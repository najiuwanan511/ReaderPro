import XCTest

final class RssSourceUITests: XCTestCase {
    func testImportUserCollectionFromSubscriptionPlusButton() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--rss-ui-fixture"]
        app.launch()
        app.tabBars.buttons["订阅"].tap()
        app.buttons["添加订阅"].tap()
        let url = app.textFields["rssImportURL"]
        XCTAssertTrue(url.waitForExistence(timeout: 10))
        url.tap(); url.typeText("http://127.0.0.1:8765/packs/rss203")
        app.buttons["添加 / 导入"].tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: url)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 60), .completed, "导入后应关闭添加界面")
        let manage = app.buttons["订阅源管理"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        manage.tap()
        XCTAssertTrue(app.staticTexts["订阅源列表（共 71 个）"].waitForExistence(timeout: 20))
    }
}
