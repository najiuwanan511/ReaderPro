import XCTest

final class RssSourceUITests: XCTestCase {
    func testSubscriptionStylesCycleAndPersistPerSource() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--rss-ui-fixture", "--rss-style-ui-fixture"]
        app.launch()
        app.tabBars.buttons["订阅"].tap()
        let feed = app.buttons.containing(.staticText, identifier: "订阅样式测试").firstMatch
        XCTAssertTrue(feed.waitForExistence(timeout: 10)); feed.tap()
        // A cold iOS 17 simulator can schedule the fixture request more than
        // 20 seconds after opening the feed. Still require the parsed item.
        XCTAssertTrue(app.staticTexts["样本文章1"].waitForExistence(timeout: 60))
        let style = app.buttons["订阅列表样式"]
        XCTAssertTrue(style.waitForExistence(timeout: 10))
        XCTAssertEqual(style.value as? String, "样式 0")
        for index in 1...4 {
            style.tap()
            let value = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "样式 \(index)"), object: style)
            XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 5), .completed)
            XCTAssertTrue(app.staticTexts["样本文章1"].waitForExistence(timeout: 5))
            if index >= 2 {
                let second = app.staticTexts["样本文章2"]
                XCTAssertTrue(second.waitForExistence(timeout: 5))
                let firstFrame = app.staticTexts["样本文章1"].frame
                XCTAssertGreaterThan(abs(firstFrame.midX - second.frame.midX), 20, "网格或瀑布流应至少有两列")
            }
        }
        style.tap() // 4 -> 0
        style.tap() // 0 -> 1
        style.tap() // 1 -> 2
        let secondStyle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "样式 2"), object: style)
        XCTAssertEqual(XCTWaiter.wait(for: [secondStyle], timeout: 5), .completed)
        app.terminate()
        app.launchArguments = ["--source-ui-fixture", "--rss-ui-fixture", "--rss-style-ui-fixture"]
        app.launch()
        app.tabBars.buttons["订阅"].tap()
        XCTAssertTrue(feed.waitForExistence(timeout: 10)); feed.tap()
        XCTAssertTrue(style.waitForExistence(timeout: 20))
        XCTAssertEqual(style.value as? String, "样式 2")
    }

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
