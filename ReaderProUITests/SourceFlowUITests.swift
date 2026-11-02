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
        app.navigationBars["校验报告"].buttons["关闭"].tap()
        app.terminate()
        app.launchArguments = ["--source-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["查看失败测试书源校验报告"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["sourceSearch"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "校验状态与常驻搜索"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func openPipelineNovel() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--source-switch-fixture"]
        app.launch()
        app.tabBars.buttons["发现"].tap(); app.buttons["回归测试书源"].tap()
        let category = app.buttons["分类"]
        XCTAssertTrue(category.waitForExistence(timeout: 15)); category.tap()
        let book = app.buttons.containing(.staticText, identifier: "测试小说").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
        let start = app.buttons["开始阅读"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed); start.tap()
        XCTAssertTrue(app.textViews["readerPage"].waitForExistence(timeout: 30))
        return app
    }

    func testDiscoveryReaderPreloadsThreeAndShowsAlternativeDirectories() {
        let app = openPipelineNovel()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["目录"].tap()
        let fourth = app.buttons["readerChapter-3"]
        XCTAssertTrue(fourth.waitForExistence(timeout: 15))
        let prefetched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已缓存"), object: fourth)
        XCTAssertEqual(XCTWaiter.wait(for: [prefetched], timeout: 30), .completed)
        XCTAssertEqual(app.buttons["readerChapter-1"].value as? String, "已缓存")
        XCTAssertEqual(app.buttons["readerChapter-2"].value as? String, "已缓存")
        XCTAssertEqual(app.buttons["readerChapter-4"].value as? String, "未缓存", "读第一章时应只向后预加载三章")
        app.buttons["readerChapter-1"].tap()
        XCTAssertTrue(app.textViews["readerPage"].label.contains("第2章第1段"))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["更多操作"].tap(); app.buttons["切换书源"].tap()
        let original = app.buttons["changeSource-回归测试书源"]
        let alternate = app.buttons["changeSource-备用测试书源"]
        XCTAssertTrue(original.waitForExistence(timeout: 30)); XCTAssertTrue(alternate.waitForExistence(timeout: 30))
        let directory = app.buttons["查看备用测试书源目录"]
        XCTAssertTrue(directory.waitForExistence(timeout: 30))
        let sources = XCTAttachment(screenshot: app.screenshot()); sources.name = "换源显示各源目录与最新章节"; sources.lifetime = .keepAlways; add(sources)
        directory.tap()
        XCTAssertTrue(app.navigationBars["备用测试书源目录"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sourceDirectoryChapter-0"].exists)
        XCTAssertFalse(app.buttons["sourceDirectoryChapter-1"].exists)
        let snapshot = XCTAttachment(screenshot: app.screenshot()); snapshot.name = "换源前查看各源实际目录"; snapshot.lifetime = .keepAlways; add(snapshot)
        app.buttons["sourceDirectoryChapter-0"].tap()
        XCTAssertTrue(app.textViews["readerPage"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.textViews["readerPage"].label.contains("第1章第1段"))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); app.buttons["目录"].tap()
        XCTAssertTrue(app.buttons["readerChapter-0"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["readerChapter-1"].exists, "目录切换后应使用所选源的一章目录")
    }

    func testReaderReplacementEntryEditsSavesAndRestoresRawContent() {
        // iOS 17's menu accessibility animation monitoring can spend several
        // minutes waiting for idle after a valid tap (see run 41468048090).
        // Keep every UI/content assertion and allow the complete round trip.
        executionTimeAllowance = 600
        let app = openPipelineNovel()
        let page = app.textViews["readerPage"]
        XCTAssertTrue(page.label.contains("完整正文"))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["更多操作"].tap(); app.buttons["替换净化"].tap()
        XCTAssertTrue(app.navigationBars["替换净化"].waitForExistence(timeout: 10))
        app.buttons["添加替换规则"].tap()
        let name = app.textFields["replacementRuleName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("阅读回归净化")
        let pattern = app.textViews["replacementRulePattern"]
        pattern.tap(); pattern.typeText("完整正文")
        let hideKeyboard = app.buttons["收起键盘"]
        XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 5)); hideKeyboard.tap()
        let replacement = app.textViews["replacementRuleReplacement"]
        // A full-screen fling can skip the replacement row in a lazy Form.
        // Dismiss the keyboard, then make bounded drags inside the editor.
        let form = app.collectionViews["replacementRuleEditorForm"]
        for _ in 0..<4 {
            if replacement.exists && replacement.isHittable { break }
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        }
        XCTAssertTrue(replacement.exists && replacement.isHittable)
        replacement.tap(); replacement.typeText("净化正文")
        XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 5)); hideKeyboard.tap()
        // iOS 17 can incorrectly ask a visible SwiftUI toolbar Menu to scroll
        // into view. Use the actual touch point and still require its action
        // and the real full-screen text editor to appear and preserve text.
        let fullScreen = app.buttons["全屏编辑"]
        XCTAssertTrue(fullScreen.waitForExistence(timeout: 5))
        fullScreen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["替换内容"].waitForExistence(timeout: 5)); app.buttons["替换内容"].tap()
        let fullEditor = app.textViews["replacementRuleFullEditor"]
        XCTAssertTrue(fullEditor.waitForExistence(timeout: 10))
        XCTAssertEqual(fullEditor.value as? String, "完整正文")
        let editorShot = XCTAttachment(screenshot: app.screenshot()); editorShot.name = "替换规则全屏编辑"; editorShot.lifetime = .keepAlways; add(editorShot)
        app.navigationBars["替换内容"].buttons["完成"].tap()
        app.buttons["保存替换规则"].tap()
        XCTAssertTrue(app.navigationBars["替换净化"].waitForExistence(timeout: 10))
        let managerShot = XCTAttachment(screenshot: app.screenshot()); managerShot.name = "替换规则管理按钮与保存结果"; managerShot.lifetime = .keepAlways; add(managerShot)
        app.navigationBars["替换净化"].buttons["完成"].tap()
        let purified = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "净化正文"), object: page)
        XCTAssertEqual(XCTWaiter.wait(for: [purified], timeout: 10), .completed)
        app.buttons["更多操作"].tap(); app.buttons["替换净化"].tap()
        let ruleMenu = app.buttons["更多阅读回归净化"]
        XCTAssertTrue(ruleMenu.waitForExistence(timeout: 5))
        ruleMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 5)); app.buttons["删除"].tap()
        app.navigationBars["替换净化"].buttons["完成"].tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "完整正文"), object: page)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed, "删除净化规则后应恢复缓存原文")
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
        assertReaderUsesFullScreen(app)
        XCTAssertTrue(page.label.contains("第1章第1段"), page.label)
        XCTAssertTrue(page.label.contains("第1章第7段"), "Must load all seven content pages before displaying the short fixture chapter")
        Thread.sleep(forTimeInterval: 1) // Wait for the presentation and TextKit drawing before visual evidence.
        let body = XCTAttachment(screenshot: page.screenshot()); body.name = "正文像素"; body.lifetime = .keepAlways; add(body)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "分类到目录直接阅读"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testDiscoveryStartReadingUsesFullScreenAndReturnsToDirectory() {
        let app = launch()
        app.tabBars.buttons["发现"].tap()
        app.buttons["回归测试书源"].tap()
        let category = app.buttons["分类"]
        XCTAssertTrue(category.waitForExistence(timeout: 15)); category.tap()
        let book = app.buttons.containing(.staticText, identifier: "测试小说").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
        XCTAssertTrue(app.staticTexts["目录 · 6 章"].waitForExistence(timeout: 15))
        let start = app.buttons["开始阅读"]
        XCTAssertTrue(start.waitForExistence(timeout: 5)); start.tap()
        let page = app.textViews["readerPage"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        XCTAssertTrue(page.label.contains("第1章第1段"))
        assertReaderUsesFullScreen(app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "发现开始阅读全屏无弹窗留白"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let back = app.buttons["返回"]
        XCTAssertTrue(back.waitForExistence(timeout: 10)); back.tap()
        XCTAssertTrue(app.staticTexts["目录 · 6 章"].waitForExistence(timeout: 10))
        app.navigationBars["书籍详情"].buttons["关闭"].tap()
        XCTAssertTrue(app.navigationBars["分类"].waitForExistence(timeout: 10))
    }

    private func assertReaderUsesFullScreen(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let viewport = app.otherElements["readerViewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 5), file: file, line: line)
        let screen = app.frame
        // Allow the device's status/sensor area, but no sheet's exposed top
        // strip or inherited detail navigation/action bars above the body.
        XCTAssertLessThan(viewport.frame.minY - screen.minY, 70, file: file, line: line)
        XCTAssertGreaterThan(viewport.frame.height, screen.height - 120, file: file, line: line)
        XCTAssertFalse(app.buttons["加入书架"].exists, file: file, line: line)
        // UIKit may retain the covered detail in the accessibility tree.
        // Require it to be inaccessible while the reader fills the screen.
        let detailCovered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.navigationBars["书籍详情"].isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [detailCovered], timeout: 5), .completed, file: file, line: line)
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
            // On a cold iOS 17 simulator the request can be scheduled more
            // than 30 seconds after navigation. Still require the actual
            // category-specific book, rather than only the loading screen.
            XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 60), "Category \(index) must navigate to its own URL")
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
        app.buttons["开始阅读"].tap()
        XCTAssertTrue(app.textViews["readerPage"].waitForExistence(timeout: 15))
        assertReaderUsesFullScreen(app)
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
        app.navigationBars["书籍详情"].buttons["关闭"].tap()

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
        XCTAssertGreaterThanOrEqual(cancel.frame.width, 44, "停止按钮需要足够的触摸宽度")
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44, "停止按钮需要足够的触摸高度")
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
