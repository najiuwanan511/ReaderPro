import XCTest
import UIKit

final class SourceImportLoginUITests: XCTestCase {
    func testReadLayoutLinkPreservesPackageAppliesAndRendersAfterRestart() {
        continueAfterFailure = false; executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--layout-link-ui-fixture"]
        app.launch()
        defer {
            app.terminate(); app.launchArguments = ["--source-ui-fixture", "--restore-persistent-fixture"]; app.launch()
            XCTAssertTrue(app.staticTexts["持久化测试数据已恢复"].waitForExistence(timeout: 15))
            app.terminate()
        }
        app.tabBars.buttons["发现"].tap()
        let source = app.buttons["source-explore-http://127.0.0.1:8765"]
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.tap()
        XCTAssertTrue(app.buttons["导入排版"].waitForExistence(timeout: 10)); app.buttons["导入排版"].tap()
        let confirm = app.buttons["appLinkConfirmImport"]
        for _ in 0..<4 { if confirm.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(confirm.waitForExistence(timeout: 15)); confirm.tap()
        XCTAssertTrue(app.staticTexts["appLinkImportResult"].waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 20)); app.tabBars.buttons["我的"].tap()
        let settings = app.buttons.containing(.staticText, identifier: "主题设置").firstMatch
        if !settings.isHittable { app.swipeUp() }; settings.tap()
        let layouts = app.buttons.containing(.staticText, identifier: "阅读排版").firstMatch
        if !layouts.isHittable { app.swipeUp() }; XCTAssertTrue(layouts.waitForExistence(timeout: 10)); layouts.tap()
        let saved = app.buttons["排版导入样例"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); saved.tap()
        let apply = app.buttons["layoutApply-0"]
        for _ in 0..<3 { if apply.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(apply.waitForExistence(timeout: 10)); apply.tap()
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["已应用昼间排版"].waitForExistence(timeout: 10))
        let settingsShot = XCTAttachment(screenshot: app.screenshot()); settingsShot.name = "排版包保存与应用"; settingsShot.lifetime = .keepAlways; add(settingsShot)
        app.terminate(); app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture"]; app.launch()
        app.tabBars.buttons["发现"].tap(); app.buttons["回归测试书源"].tap()
        XCTAssertTrue(app.buttons["分类"].waitForExistence(timeout: 10)); app.buttons["分类"].tap()
        let book = app.buttons.containing(.staticText, identifier: "测试小说").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
        XCTAssertTrue(app.staticTexts["目录 · 6 章"].waitForExistence(timeout: 20)); app.swipeUp()
        app.buttons["chapter-0"].tap()
        let page = app.textViews["readerPage"]
        XCTAssertTrue(page.waitForExistence(timeout: 20)); XCTAssertGreaterThan(page.label.count, 20)
        let pixels = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let screen = app.frame
            return Self.pixel(app.screenshot().image, at: CGPoint(x: screen.minX + 4, y: screen.midY), in: screen, matches: 0xECDDBA)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pixels], timeout: 10), .completed, "重启后正文仍应绘制排版包内的背景图")
        let readerShot = XCTAttachment(screenshot: app.screenshot()); readerShot.name = "导入排版重启后正文与背景"; readerShot.lifetime = .keepAlways; add(readerShot)
    }

    func testThemeLinkImportsThenAppliesFromProductionSettings() {
        continueAfterFailure = false; executionTimeAllowance = 180
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--theme-link-ui-fixture"]
        app.launch(); app.tabBars.buttons["发现"].tap()
        let source = app.buttons["source-explore-http://127.0.0.1:8765"]
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.tap()
        let action = app.buttons["导入主题"]
        XCTAssertTrue(action.waitForExistence(timeout: 10)); action.tap()
        let confirm = app.buttons["appLinkConfirmImport"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15)); XCTAssertTrue(app.staticTexts["主题导入样例"].exists)
        confirm.tap(); XCTAssertTrue(app.staticTexts["appLinkImportResult"].waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = []; app.launch()
        let mine = app.tabBars.buttons["我的"]
        XCTAssertTrue(mine.waitForExistence(timeout: 20)); mine.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: mine)
        let selectionResult = XCTWaiter.wait(for: [selected], timeout: 5)
        if selectionResult != .completed {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "首次点击标签后的完整界面层级"; tree.lifetime = .keepAlways; add(tree)
        }
        XCTAssertEqual(selectionResult, .completed, "首次点击我的应保持该标签选中")
        let settings = app.buttons.containing(.staticText, identifier: "主题设置").firstMatch
        if !settings.isHittable { app.swipeUp() }
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let imported = app.buttons.containing(.staticText, identifier: "导入主题").firstMatch
        if !imported.isHittable { app.swipeUp() }
        XCTAssertTrue(imported.waitForExistence(timeout: 10)); imported.tap()
        let theme = app.buttons.containing(.staticText, identifier: "主题导入样例").firstMatch
        XCTAssertTrue(theme.waitForExistence(timeout: 10)); theme.tap()
        XCTAssertTrue(app.staticTexts["浅色"].exists)
        let colors = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let image = app.screenshot().image
            let bar = app.navigationBars["导入主题"].frame, screen = app.frame
            return Self.pixel(image, at: CGPoint(x: bar.maxX - 12, y: bar.midY), in: screen, matches: 0x3949AB)
                && Self.pixel(image, at: CGPoint(x: screen.midX, y: screen.midY + 40), in: screen, matches: 0xF4F1E8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [colors], timeout: 10), .completed, "导入主题的导航栏和页面背景必须实际绘制目标颜色")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "开源阅读主题导入与应用"; shot.lifetime = .keepAlways; add(shot)
        theme.swipeLeft(); app.buttons["删除"].tap()
        XCTAssertFalse(app.staticTexts["主题导入样例"].exists)
        for title in ["发现", "订阅", "书架", "我的"] {
            let tab = app.tabBars.buttons[title]; tab.tap()
            let selection = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: tab)
            XCTAssertEqual(XCTWaiter.wait(for: [selection], timeout: 5), .completed, "主题刷新后单次点击应切换到" + title)
        }
        XCTAssertTrue(app.navigationBars["导入主题"].exists, "切换标签应保留主题页面的导航进度")
    }

    private static func pixel(_ image: UIImage, at point: CGPoint, in screen: CGRect, matches hex: UInt32) -> Bool {
        guard let cg = image.cgImage, screen.width > 0, screen.height > 0 else { return false }
        let x = Int((point.x - screen.minX) / screen.width * CGFloat(cg.width))
        let y = Int((point.y - screen.minY) / screen.height * CGFloat(cg.height))
        guard let crop = cg.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return false }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
        }
        return drawn && zip(bytes.prefix(3), [Int((hex >> 16) & 255), Int((hex >> 8) & 255), Int(hex & 255)])
            .allSatisfy { abs(Int($0.0) - $0.1) <= 5 }
    }

    func testDiscoveryScriptAppLinkPreviewsThenPersistsImportedSource() {
        continueAfterFailure = false; executionTimeAllowance = 180
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--app-link-ui-fixture"]
        app.launch(); app.tabBars.buttons["发现"].tap()
        let source = app.buttons["source-explore-http://127.0.0.1:8765"]
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.tap()
        let action = app.buttons["一键导入"]
        XCTAssertTrue(action.waitForExistence(timeout: 10)); action.tap()
        let confirm = app.buttons["appLinkConfirmImport"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["一键导入测试源"].exists)
        confirm.tap()
        XCTAssertTrue(app.staticTexts["appLinkImportResult"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "发现脚本一键导入成功"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["关闭"].tap(); app.tabBars.buttons["管理"].tap()
        XCTAssertTrue(app.staticTexts["一键导入测试源"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testSearchRuleWaitsForVisibleVerificationAndResumesUsingCookies() {
        continueAfterFailure = false; executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--source-web-login-fixture", "--source-verification-fixture"]
        app.launch(); app.tabBars.buttons["搜索"].tap()
        let field = app.textFields["bookSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("登录")
        app.buttons["submitBookSearch"].tap()
        let link = app.webViews.links["确认登录测试账号"]
        XCTAssertTrue(link.waitForExistence(timeout: 20)); link.tap()
        XCTAssertTrue(app.webViews.staticTexts["网页登录完成"].waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "搜索规则等待可见验证"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["验证完成"].tap()
        XCTAssertTrue(app.staticTexts["已登录可搜索小说"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testCancellingVisibleVerificationAllowsAnotherSearch() {
        continueAfterFailure = false; executionTimeAllowance = 300
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--source-web-login-fixture", "--source-verification-fixture"]
        app.launch(); app.tabBars.buttons["搜索"].tap()
        let field = app.textFields["bookSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("登录")
        app.buttons["submitBookSearch"].tap()
        XCTAssertTrue(app.webViews.links["确认登录测试账号"].waitForExistence(timeout: 20))
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["submitBookSearch"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["cancelBookSearch"].waitForNonExistence(timeout: 10))
        app.buttons["submitBookSearch"].tap()
        let link = app.webViews.links["确认登录测试账号"]
        XCTAssertTrue(link.waitForExistence(timeout: 20)); link.tap()
        XCTAssertTrue(app.webViews.staticTexts["网页登录完成"].waitForExistence(timeout: 10))
        app.buttons["验证完成"].tap()
        XCTAssertTrue(app.staticTexts["已登录可搜索小说"].waitForExistence(timeout: 30))
    }

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
        app.buttons["clearSourceImportURL"].tap()
        field.tap(); field.typeText("http://127.0.0.1:8765/packs/large")
        XCTAssertEqual(field.value as? String, "http://127.0.0.1:8765/packs/large")
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
