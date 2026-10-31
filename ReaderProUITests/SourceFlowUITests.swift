import XCTest

final class SourceFlowUITests: XCTestCase {
    func launch(reset: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture"] + (reset ? ["--reset-source-fixture"] : [])
        app.launch()
        return app
    }

    func testValidationSearchFiltersReportsAndPersistence() {
        let app = launch()
        XCTAssertTrue(app.textFields["sourceSearch"].waitForExistence(timeout: 10))
        app.buttons["校验当前"].tap()
        let good = app.buttons["查看回归测试书源校验报告"]
        let failed = app.buttons["查看失败测试书源校验报告"]
        XCTAssertTrue(good.waitForExistence(timeout: 45))
        XCTAssertTrue(failed.waitForExistence(timeout: 20))
        app.buttons["sourceStatus-失败"].tap()
        XCTAssertTrue(failed.exists)
        XCTAssertFalse(good.exists)
        let search = app.textFields["sourceSearch"]
        search.tap(); search.typeText("403")
        XCTAssertTrue(app.staticTexts["失败测试书源"].exists)
        failed.tap()
        XCTAssertTrue(app.navigationBars["校验报告"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "403")).firstMatch.exists)
        app.buttons["关闭"].tap()
        app.terminate()
        app.launchArguments = ["--source-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["查看失败测试书源校验报告"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["sourceSearch"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "校验状态与常驻搜索"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testDiscoveryOpensCompleteDirectoryAndChapterDirectly() {
        let app = launch()
        app.tabBars.buttons["发现"].tap()
        app.buttons["回归测试书源"].tap()
        let category = app.buttons["分类"]
        XCTAssertTrue(category.waitForExistence(timeout: 10)); category.tap()
        let book = app.buttons.containing(.staticText, identifier: "测试小说").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        XCTAssertTrue(app.staticTexts["目录 · 6 章"].waitForExistence(timeout: 15))
        app.swipeUp()
        let chapter = app.buttons["chapter-0"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 5)); chapter.tap()
        let page = app.textViews["readerPage"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        XCTAssertTrue(page.label.contains("第1章第1段"), page.label)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "分类到目录直接阅读"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testSearchOpensDirectory() {
        let app = launch()
        app.tabBars.buttons["搜索"].tap()
        let search = app.textFields["bookSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("测试")
        app.buttons["submitBookSearch"].tap()
        let book = app.buttons.containing(.staticText, identifier: "测试小说").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
        XCTAssertTrue(app.staticTexts["目录 · 6 章"].waitForExistence(timeout: 15))
    }
}
