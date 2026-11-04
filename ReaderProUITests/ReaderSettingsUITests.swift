import XCTest

final class ReaderSettingsUITests: XCTestCase {
    func testSourceConcurrencySettingsPersistAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture"]
        func openSettings() {
            app.tabBars.buttons["我的"].tap()
            let other = app.buttons.containing(.staticText, identifier: "其他设置").firstMatch
            XCTAssertTrue(other.waitForExistence(timeout: 10))
            if !other.isHittable { app.swipeUp() }
            other.tap()
            app.buttons.containing(.staticText, identifier: "搜索与校验并发").firstMatch.tap()
            XCTAssertTrue(app.navigationBars["搜索与校验并发"].waitForExistence(timeout: 10))
        }
        app.launch(); openSettings()
        app.buttons["恢复默认并发数"].tap()
        for name in ["searchConcurrency", "validationConcurrency", "webConcurrency"] {
            let stepper = app.steppers[name]
            XCTAssertTrue(stepper.exists)
            stepper.buttons.element(boundBy: 1).tap()
        }
        app.terminate()
        app.launchArguments = ["--source-ui-fixture"]
        app.launch(); openSettings()
        XCTAssertTrue(app.staticTexts["搜索并发数：33"].exists)
        XCTAssertTrue(app.staticTexts["校验并发数：33"].exists)
        XCTAssertTrue(app.staticTexts["网页并发数：5"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "搜索校验网页并发设置重启持久化"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["恢复默认并发数"].tap()
    }

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
        let weight = app.buttons["readerFontWeight"]
        XCTAssertTrue(weight.exists); weight.tap(); app.buttons["粗体"].tap()
        XCTAssertFalse(app.switches["阅读时保持屏幕常亮"].exists)
        app.buttons["完成"].tap()
        app.buttons["界面"].tap()
        XCTAssertTrue(weight.waitForExistence(timeout: 10)); XCTAssertTrue(weight.label.contains("粗体"))
        weight.tap(); app.buttons["普通"].tap()
        app.buttons["完成"].tap()

        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 10))
        let awake = app.switches["阅读时保持屏幕常亮"]
        XCTAssertTrue(awake.waitForExistence(timeout: 10))
        guard let initial = awake.value as? String, initial == "0" || initial == "1" else {
            return XCTFail("常亮开关应报告打开或关闭状态")
        }
        let changed = initial == "0" ? "1" : "0"
        // In a SwiftUI Form, the accessibility switch frame covers the full
        // row. Its centre is the text label, while the native switch is on
        // the right; tapping the row centre does not reliably change it.
        awake.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let changedValue = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", changed), object: awake)
        XCTAssertEqual(XCTWaiter.wait(for: [changedValue], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts["字距"].exists)
        app.buttons["完成"].tap()
        app.buttons["设置"].tap()
        XCTAssertTrue(awake.waitForExistence(timeout: 10))
        XCTAssertEqual(awake.value as? String, changed)
        awake.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() // Restore the previous setting.
    }
}
