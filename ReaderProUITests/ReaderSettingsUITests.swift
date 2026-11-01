import XCTest

final class ReaderSettingsUITests: XCTestCase {
    func testInterfaceAndReadingSettingsAreSeparateAndPersist() {
        continueAfterFailure = false
        executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture"]
        app.launch()
        app.tabBars.buttons["发现"].tap()
        app.buttons["回归测试书源"].tap()
        let category = app.buttons["分类"]
        XCTAssertTrue(category.waitForExistence(timeout: 15)); category.tap()
        let book = app.buttons.containing(.staticText, identifier: "测试小说").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
        XCTAssertTrue(app.staticTexts["目录 · 6 章"].waitForExistence(timeout: 20))
        app.swipeUp()
        let chapter = app.buttons["chapter-0"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 10)); chapter.tap()
        let page = app.textViews["readerPage"]
        XCTAssertTrue(page.waitForExistence(timeout: 20))
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let interface = app.buttons["界面"]
        XCTAssertTrue(interface.waitForExistence(timeout: 10)); interface.tap()
        XCTAssertTrue(app.navigationBars["界面"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["字距"].exists)
        XCTAssertFalse(app.switches["阅读时保持屏幕常亮"].exists)
        app.buttons["完成"].tap()

        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 10))
        let awake = app.switches["阅读时保持屏幕常亮"]
        XCTAssertTrue(awake.waitForExistence(timeout: 10))
        let initial = awake.value as? String
        awake.tap()
        let changed = awake.value as? String
        XCTAssertNotEqual(initial, changed)
        XCTAssertFalse(app.staticTexts["字距"].exists)
        app.buttons["完成"].tap()
        app.buttons["设置"].tap()
        XCTAssertTrue(awake.waitForExistence(timeout: 10))
        XCTAssertEqual(awake.value as? String, changed)
        awake.tap() // Restore the user's prior preference in this test sandbox.
    }
}
