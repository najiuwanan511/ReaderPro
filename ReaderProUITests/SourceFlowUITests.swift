import XCTest

final class SourceFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        // A cold simulator can spend over a minute establishing the first
        // accessibility session. Keep all per-screen waits and assertions;
        // allow the full discovery/reader flow and XCTest teardown to finish.
        executionTimeAllowance = 300
    }

    func launch(reset: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture"] + (reset ? ["--reset-source-fixture"] : [])
        app.launch()
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, 350, "The app must use the native device layout, not legacy 320-point compatibility mode")
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
        XCTAssertTrue(page.label.contains("第1章第7段"), "Must load all seven content pages before displaying the short fixture chapter")
        Thread.sleep(forTimeInterval: 1) // Wait for the presentation and TextKit drawing before visual evidence.
        let body = XCTAttachment(screenshot: page.screenshot()); body.name = "正文像素"; body.lifetime = .keepAlways; add(body)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "分类到目录直接阅读"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testDiscoveryKeepsDuplicateCategoriesIndependentlySelectable() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--duplicate-category-fixture"]
        app.launch()
        app.tabBars.buttons["发现"].tap()
        app.buttons["回归测试书源"].tap()
        for index in 0..<3 {
            let category = app.buttons["explore-category-\(index)"]
            XCTAssertTrue(category.waitForExistence(timeout: 15), "Duplicate category \(index) must stay visible")
            category.tap()
            let expected = index < 2 ? "测试小说" : "另一本小说"
            XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 15), "Category \(index) must navigate to its own URL")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    func testDiscoverySearchFiltersOnlyDiscoverableSources() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--source-switch-fixture"]
        app.launch()
        app.tabBars.buttons["发现"].tap()
        XCTAssertTrue(app.buttons["回归测试书源"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["备用测试书源"].exists)
        app.buttons["搜索发现书源"].tap()
        let search = app.textFields["discoverySourceSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("备用")
        XCTAssertTrue(app.buttons["备用测试书源"].exists)
        XCTAssertFalse(app.buttons["回归测试书源"].exists)
        XCTAssertFalse(app.textFields["bookSearch"].exists)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["回归测试书源"].waitForExistence(timeout: 5))
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

    func testSwitchingSourcesReplacesVisibleDirectorySafely() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--source-switch-fixture"]
        app.launch()
        app.tabBars.buttons["搜索"].tap()
        let search = app.textFields["bookSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("测试")
        app.buttons["submitBookSearch"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "搜索完成")).firstMatch.waitForExistence(timeout: 25))
        let book = app.buttons.containing(.staticText, identifier: "测试小说").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        let picker = app.buttons["detailSourcePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        for _ in 0..<2 {
            picker.tap(); app.buttons["回归测试书源"].tap()
            XCTAssertTrue(app.staticTexts["目录 · 6 章"].waitForExistence(timeout: 15))
            picker.tap(); app.buttons["备用测试书源"].tap()
            XCTAssertTrue(app.staticTexts["目录 · 1 章"].waitForExistence(timeout: 15))
        }
        app.swipeUp()
        XCTAssertTrue(app.buttons["chapter-0"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["chapter-5"].exists)
    }

    func testLargeSearchResultsAndBookshelfRemainResponsive() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--source-stress-fixture"]
        app.launch()
        app.tabBars.buttons["搜索"].tap()
        let search = app.textFields["bookSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 15)); search.tap(); search.typeText("stress")
        app.buttons["submitBookSearch"].tap()
        let completed = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "搜索完成")).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 120), "All 16 sources must finish without terminating the app")
        XCTAssertTrue(completed.label.replacingOccurrences(of: ",", with: "").contains("6400"), completed.label)
        let book = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "批量书籍")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10)); book.tap()
        XCTAssertTrue(app.staticTexts["目录 · 1 章"].waitForExistence(timeout: 20))
        app.buttons["关闭"].tap()

        app.tabBars.buttons["书架"].tap()
        app.swipeDown()
        let shelfSearch = app.searchFields.firstMatch
        XCTAssertTrue(shelfSearch.waitForExistence(timeout: 10)); shelfSearch.tap(); shelfSearch.typeText("stress")
        let submit = app.buttons["shelfSearchSources"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10)); submit.tap()
        let results = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "源搜索结果")).firstMatch
        let fullResults = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            results.exists && results.label.replacingOccurrences(of: ",", with: "").contains("6400")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [fullResults], timeout: 120), .completed, "Bookshelf must render the large result set without terminating")
        app.swipeUp()
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testSearchWithRealUserPackCanBeCancelled() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--user-pack-ui-fixture"]
        app.launch()
        app.tabBars.buttons["搜索"].tap()
        let sourceCount = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "个已导入")).firstMatch
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            sourceCount.exists && sourceCount.label.replacingOccurrences(of: ",", with: "").contains("1466")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 40), .completed)
        let search = app.textFields["bookSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("斗罗大陆")
        app.buttons["submitBookSearch"].tap()
        let cancel = app.buttons["cancelBookSearch"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 12) // Keep the actual multi-source workers and result view active.
        XCTAssertEqual(app.state, .runningForeground)
        cancel.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已停止")).firstMatch.waitForExistence(timeout: 10))
    }

    func testDiscoveryOpensStaticAndScriptCategoriesFromRealUserPack() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--user-pack-ui-fixture"]
        app.launch()
        app.tabBars.buttons["发现"].tap()

        let first = app.buttons["source-explore-https://m.cuoceng.org/"]
        XCTAssertTrue(first.waitForExistence(timeout: 50), "The real user pack must load its first discovery source")
        first.tap()
        let fiction = app.buttons.matching(NSPredicate(format: "label == %@", "玄幻")).firstMatch
        XCTAssertTrue(fiction.waitForExistence(timeout: 20), "A real static category must render without terminating")
        XCTAssertEqual(app.state, .runningForeground)
        first.tap()

        let scripted = app.buttons["source-explore-https://www.huangjinwu.org/"]
        XCTAssertTrue(scripted.waitForExistence(timeout: 15))
        scripted.tap()
        let ranking = app.buttons.matching(NSPredicate(format: "label == %@", "总点击")).firstMatch
        XCTAssertTrue(ranking.waitForExistence(timeout: 30), "A real JavaScript category must render without terminating")
        XCTAssertEqual(app.state, .runningForeground)
        scripted.tap()

        // This source has no header/jsLib and its category is static JSON;
        // displaying it exercises the SwiftUI path without web or JS work.
        let staticOnly = app.buttons["source-explore-https://www.gulongwang.com"]
        for _ in 0..<8 {
            if staticOnly.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(staticOnly.waitForExistence(timeout: 15))
        staticOnly.tap()
        let classic = app.buttons.matching(NSPredicate(format: "label == %@", "古龙全集")).firstMatch
        XCTAssertTrue(classic.waitForExistence(timeout: 20), "A static category without scripts or a network request must render")
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testPersistedRealPackThroughProductionRootSearchAndDiscovery() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["--source-ui-fixture", "--seed-persistent-user-pack"]
        app.launch()
        // Restore the prior app files and settings even when an assertion fails
        // or the production-root application terminates during this test.
        addTeardownBlock {
            if app.state != .notRunning { app.terminate() }
            app.launchArguments = ["--source-ui-fixture", "--restore-persistent-fixture"]
            app.launch()
            XCTAssertTrue(app.staticTexts["持久化测试数据已恢复"].waitForExistence(timeout: 30))
            app.terminate()
        }
        XCTAssertTrue(app.staticTexts["持久化书源准备完成"].waitForExistence(timeout: 60), "All 1466 sources must be saved and read back first")
        app.terminate()

        // No fixture argument: the app initializes the actual ContentView,
        // BookStore and bookshelf navigation from the saved files.
        app.launchArguments = []
        app.launch()
        let searchEntry = app.buttons["搜索书籍"]
        XCTAssertTrue(searchEntry.waitForExistence(timeout: 25))
        searchEntry.tap()
        let sourceCount = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "个已导入")).firstMatch
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            sourceCount.exists && sourceCount.label.replacingOccurrences(of: ",", with: "").contains("1466")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 45), .completed)
        let search = app.textFields["bookSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("斗罗大陆")
        app.buttons["submitBookSearch"].tap()
        let cancel = app.buttons["cancelBookSearch"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 12)
        XCTAssertEqual(app.state, .runningForeground)
        cancel.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已停止")).firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.tabBars.buttons["发现"].tap()
        let source = app.buttons["source-explore-https://m.cuoceng.org/"]
        XCTAssertTrue(source.waitForExistence(timeout: 30))
        source.tap()
        let fiction = app.buttons.matching(NSPredicate(format: "label == %@", "玄幻")).firstMatch
        XCTAssertTrue(fiction.waitForExistence(timeout: 20), "The persisted original source must expand its static categories")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
