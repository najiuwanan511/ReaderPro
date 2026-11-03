import XCTest

final class SourceImportLoginUITests: XCTestCase {
    func testDiscoveryLongPressLoginSwitchesInterfaceAndKeepsSelection() {
        continueAfterFailure = false; executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--source-login-fixture"]
        app.launch(); app.tabBars.buttons["发现"].tap()
        let source = app.buttons["登录接口测试源"]
        XCTAssertTrue(source.waitForExistence(timeout: 15)); source.tap()
        XCTAssertTrue(app.buttons["接口一分类"].waitForExistence(timeout: 15))
        source.press(forDuration: 1)
        XCTAssertTrue(app.buttons["登录"].waitForExistence(timeout: 10)); app.buttons["登录"].tap()
        let select = app.buttons["login-select-接口"]
        XCTAssertTrue(select.waitForExistence(timeout: 20)); select.tap(); app.buttons["接口二"].tap()
        XCTAssertTrue(app.buttons["当前接口：接口二"].waitForExistence(timeout: 20))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "发现长按登录与接口切换"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["接口二分类"].waitForExistence(timeout: 20))
        source.press(forDuration: 1); app.buttons["登录"].tap()
        XCTAssertTrue(app.buttons["当前接口：接口二"].waitForExistence(timeout: 20))
        let account = app.textFields["login-field-账号"]
        account.tap(); account.typeText("reader")
        let password = app.secureTextFields["login-field-密码"]
        password.tap(); password.typeText("test-secret")
        app.buttons["sourceLoginSubmit"].tap()
        XCTAssertTrue(app.staticTexts["登录成功"].waitForExistence(timeout: 20))
        app.navigationBars.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["接口二分类"].waitForExistence(timeout: 20))
        app.terminate(); app.launchArguments = ["--source-ui-fixture", "--source-login-fixture"]
        app.launch(); app.tabBars.buttons["发现"].tap()
        XCTAssertTrue(source.waitForExistence(timeout: 15)); source.tap()
        XCTAssertTrue(app.buttons["接口二分类"].waitForExistence(timeout: 20))
        source.press(forDuration: 1); app.buttons["登录"].tap()
        XCTAssertTrue(app.buttons["当前接口：接口二"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.textFields["login-field-账号"].value as? String, "reader")
    }

    func testWebLoginSharesCookieWithSearchEngine() {
        continueAfterFailure = false; executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--source-web-login-fixture"]
        app.launch(); app.tabBars.buttons["发现"].tap()
        let source = app.buttons["网页登录测试源"]
        XCTAssertTrue(source.waitForExistence(timeout: 15)); source.press(forDuration: 1); app.buttons["登录"].tap()
        let link = app.webViews.links["确认登录测试账号"]
        XCTAssertTrue(link.waitForExistence(timeout: 30)); link.tap()
        XCTAssertTrue(app.webViews.staticTexts["网页登录完成"].waitForExistence(timeout: 20))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "网页登录与Cookie会话"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars.buttons["关闭"].tap()
        app.tabBars.buttons["搜索"].tap()
        let field = app.textFields["bookSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("登录")
        app.buttons["submitBookSearch"].tap()
        XCTAssertTrue(app.staticTexts["已登录可搜索小说"].waitForExistence(timeout: 40))
    }

    func testImportCanCancelAndImmediatelyImport1500WithoutFreezing() {
        continueAfterFailure = false; executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture"]
        app.launch(); app.buttons["导入书源"].tap(); app.buttons["网络链接"].tap()
        let field = app.textFields["sourceNetworkImportURL"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("http://127.0.0.1:8765/packs/import-slow")
        app.buttons["拉取并导入"].tap()
        XCTAssertTrue(app.buttons["cancelSourceImport"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["sourceImportProgress"].exists)
        app.buttons["cancelSourceImport"].tap()
        XCTAssertTrue(app.staticTexts["已取消导入"].waitForExistence(timeout: 5))
        field.tap()
        let text = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count) + "http://127.0.0.1:8765/packs/large")
        app.buttons["拉取并导入"].tap()
        let result = app.staticTexts["sourceNetworkImportResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 20)); XCTAssertTrue(result.label.contains("1500"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "1500书源批量导入完成"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars.buttons["关闭"].tap()
        let search = app.textFields["sourceSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("cancelled-import")
        XCTAssertFalse(app.staticTexts["cancelled-import"].exists, "A cancelled response must never be merged later")
    }
}
