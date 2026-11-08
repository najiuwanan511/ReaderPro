import XCTest

final class ReaderChapterPagingUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        executionTimeAllowance = 300
    }

    private func launch(mode: Int, startSecond: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--reader-boundary-fixture", "--reset-reader-boundary", "--reader-mode=\(mode)"]
        if startSecond { app.launchArguments.append("--reader-start-second") }
        app.launch()
        return app
    }

    func testLandscapeDoublePageKeepsBothColumnsAndCrossesChapterBoundary() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--reader-boundary-fixture", "--reset-reader-boundary", "--reader-mode=3", "--reader-double-page"]
        app.launch()
        XCTAssertTrue(page(app, containing: "第一章分页内容").waitForExistence(timeout: 30))
        let columns = app.textViews.matching(identifier: "readerPage")
        XCTAssertGreaterThanOrEqual(columns.count, 2)
        let first = columns.element(boundBy: 0).frame, second = columns.element(boundBy: 1).frame
        XCTAssertGreaterThan(abs(first.midX - second.midX), 100)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let slider = app.sliders["readerProgressSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10)); slider.adjust(toNormalizedSliderPosition: 1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(page(app, containing: "第一章末尾标记").waitForExistence(timeout: 10))
        app.swipeLeft()
        XCTAssertTrue(page(app, containing: "第二章正文标记").waitForExistence(timeout: 20))
    }

    private func page(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.textViews.matching(identifier: "readerPage")
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func openCatalog(_ app: XCUIApplication) {
        let button = app.buttons["目录"]
        if !button.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 10)); button.tap()
        XCTAssertTrue(app.navigationBars["目录"].waitForExistence(timeout: 10))
    }

    private func assertCatalogStarts(at index: Int, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let catalog = app.descendants(matching: .any).matching(identifier: "readerCatalog").firstMatch
        let row = app.buttons["readerChapter-\(index)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), file: file, line: line)
        let aligned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let top = max(catalog.frame.minY, app.navigationBars["目录"].frame.maxY)
            return row.isHittable && row.frame.minY >= top - 2 && row.frame.minY <= top + 40
        }, object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [aligned], timeout: 10), .completed,
                       "当前阅读章节应位于目录顶部：\(row.frame)，目录：\(catalog.frame)", file: file, line: line)
        let next = app.buttons["readerChapter-\(index + 1)"]
        let afterNext = app.buttons["readerChapter-\(index + 2)"]
        XCTAssertTrue(next.isHittable && afterNext.isHittable, file: file, line: line)
        XCTAssertLessThan(row.frame.minY, next.frame.minY, file: file, line: line)
        XCTAssertLessThan(next.frame.minY, afterNext.frame.minY, file: file, line: line)
        if index > 0 { XCTAssertFalse(app.buttons["readerChapter-\(index - 1)"].isHittable, file: file, line: line) }
    }

    func testCatalogStartsAtCurrentChapterAndFollowsJumpAfterReopenAndRelaunch() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--reader-boundary-fixture", "--reset-reader-boundary", "--reader-mode=0", "--reader-catalog-position-fixture"]
        app.launch()
        XCTAssertTrue(page(app, containing: "目录定位第70章正文标记").waitForExistence(timeout: 20))
        openCatalog(app)
        assertCatalogStarts(at: 69, in: app)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "目录打开定位第70章并按70-71-72显示"; shot.lifetime = .keepAlways; add(shot)

        // Earlier chapters remain available; closing and reopening must locate
        // the reading position again, rather than keep this manual scroll.
        app.swipeDown()
        XCTAssertTrue(app.buttons["readerChapter-68"].isHittable)
        app.buttons["关闭"].tap()
        openCatalog(app)
        assertCatalogStarts(at: 69, in: app)
        app.buttons["readerChapter-71"].tap()
        XCTAssertTrue(page(app, containing: "目录定位第72章正文标记").waitForExistence(timeout: 20))
        openCatalog(app)
        assertCatalogStarts(at: 71, in: app)
        app.buttons["关闭"].tap()
        app.terminate()

        app.launchArguments = ["--reader-boundary-fixture", "--reader-mode=0", "--reader-catalog-position-fixture"]
        app.launch()
        XCTAssertTrue(page(app, containing: "目录定位第72章正文标记").waitForExistence(timeout: 20))
        openCatalog(app)
        assertCatalogStarts(at: 71, in: app)
    }

    func testCatalogKeepsFirstAndLastChaptersReachable() {
        for number in [1, 120] {
            let app = XCUIApplication()
            app.launchArguments = ["--reader-boundary-fixture", "--reset-reader-boundary", "--reader-mode=0", "--reader-catalog-position-fixture", "--reader-catalog-start=\(number)"]
            app.launch()
            XCTAssertTrue(page(app, containing: "目录定位第\(number)章正文标记").waitForExistence(timeout: 20))
            openCatalog(app)
            let row = app.buttons["readerChapter-\(number - 1)"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            XCTAssertTrue(row.isHittable, "首章和末章都应在打开目录时可见")
            row.tap()
            XCTAssertTrue(page(app, containing: "目录定位第\(number)章正文标记").waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    private func exercisePagedMode(_ mode: Int) {
        let app = launch(mode: mode)
        XCTAssertTrue(page(app, containing: "第一章分页内容").waitForExistence(timeout: 30))
        // The first swipe back at the beginning must not leave chapter one.
        app.swipeRight()
        XCTAssertTrue(page(app, containing: "第一章分页内容").exists)
        if mode == 1 {
            // The native scroll controller must retain edge tapping without
            // double-advancing when its own recognizers also see the tap.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertTrue(app.staticTexts["第 2 页"].waitForExistence(timeout: 10))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
            XCTAssertTrue(app.staticTexts["第 1 页"].waitForExistence(timeout: 10))
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let slider = app.sliders["readerProgressSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        slider.adjust(toNormalizedSliderPosition: 1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(page(app, containing: "第一章末尾标记").waitForExistence(timeout: 10))
        app.swipeLeft()
        XCTAssertTrue(page(app, containing: "第二章正文标记").waitForExistence(timeout: 20))
        app.swipeRight()
        XCTAssertTrue(page(app, containing: "第一章末尾标记").waitForExistence(timeout: 20))
        app.swipeLeft()
        XCTAssertTrue(page(app, containing: "第二章正文标记").waitForExistence(timeout: 20))
        app.swipeLeft()
        XCTAssertTrue(page(app, containing: "第三章正文标记").waitForExistence(timeout: 20))
        app.swipeLeft()
        XCTAssertTrue(page(app, containing: "第三章正文标记").exists, "最后一章不能越界")
        app.terminate()
        app.launchArguments = ["--reader-boundary-fixture", "--reader-mode=\(mode)"]
        app.launch()
        XCTAssertTrue(page(app, containing: "第三章正文标记").waitForExistence(timeout: 20), "跨章进度应在重启后恢复")
    }

    func testCoverSwipeAcrossChapterBoundaries() { exercisePagedMode(0) }
    func testCoverUsesConfiguredTapRegionsAndEditedContentSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--reader-boundary-fixture", "--reset-reader-boundary", "--reader-mode=0", "--reader-start-second", "--reader-custom-cover-tap"]
        app.launch()
        XCTAssertTrue(page(app, containing: "第二章正文标记").waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["目录"].waitForExistence(timeout: 10), "覆盖翻页必须使用已配置的九宫格动作")
        app.buttons["关闭"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let more = app.buttons["更多操作"]
        XCTAssertTrue(more.waitForExistence(timeout: 10)); more.tap()
        let edit = app.buttons["编辑正文"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10)); edit.tap()
        let editor = app.textViews["readerContentEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.tap(); editor.typeText("离线编辑持久标记")
        app.buttons["保存"].tap()
        XCTAssertTrue(page(app, containing: "离线编辑持久标记").waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["--reader-boundary-fixture", "--reader-mode=0"]
        app.launch()
        XCTAssertTrue(page(app, containing: "离线编辑持久标记").waitForExistence(timeout: 20))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "覆盖翻页与编辑正文持久化"; shot.lifetime = .keepAlways; add(shot)
    }

    func testCoverLongPressCanCopyTextWithoutTurningPage() {
        let app = launch(mode: 0)
        let text = page(app, containing: "第一章分页内容")
        XCTAssertTrue(text.waitForExistence(timeout: 30))
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.04)).press(forDuration: 1)
        let copy = app.menuItems["复制"].firstMatch
        let button = app.buttons["复制"].firstMatch
        let appeared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in copy.exists || button.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [appeared], timeout: 10), .completed)
        if copy.exists { copy.tap() } else { button.tap() }
        XCTAssertTrue(app.staticTexts["第 1 页"].exists, "选择正文不应触发翻页")
        XCTAssertTrue(text.exists)
    }
    func testSlideSwipeAcrossChapterBoundaries() { exercisePagedMode(1) }
    func testNoAnimationSwipeAcrossChapterBoundaries() { exercisePagedMode(3) }
    func testCurlSwipeAcrossChapterBoundaries() { exercisePagedMode(4) }

    func testCurlTapTurnsBothDirectionsThenSwipesAndCrossesChapters() {
        let app = launch(mode: 4)
        XCTAssertTrue(page(app, containing: "第一章分页内容").waitForExistence(timeout: 30))
        let next = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let previous = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        for _ in 0..<3 {
            next.tap()
            XCTAssertTrue(app.staticTexts["第 2 页"].waitForExistence(timeout: 10))
            previous.tap()
            XCTAssertTrue(app.staticTexts["第 1 页"].waitForExistence(timeout: 10))
        }
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["第 2 页"].waitForExistence(timeout: 10))
        previous.tap()
        XCTAssertTrue(app.staticTexts["第 1 页"].waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let slider = app.sliders["readerProgressSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10)); slider.adjust(toNormalizedSliderPosition: 1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(page(app, containing: "第一章末尾标记").waitForExistence(timeout: 10))
        next.tap()
        XCTAssertTrue(page(app, containing: "第二章正文标记").waitForExistence(timeout: 20))
        previous.tap()
        XCTAssertTrue(page(app, containing: "第一章末尾标记").waitForExistence(timeout: 20))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "仿真点按与滑动混合翻页及跨章"; shot.lifetime = .keepAlways; add(shot)
    }

    func testCurlCanReverseDirectionRepeatedlyAcrossChapters() {
        let app = launch(mode: 4, startSecond: true)
        XCTAssertTrue(page(app, containing: "第二章正文标记").waitForExistence(timeout: 20))
        for _ in 0..<4 {
            app.swipeRight()
            XCTAssertTrue(page(app, containing: "第一章末尾标记").waitForExistence(timeout: 30))
            app.swipeLeft()
            XCTAssertTrue(page(app, containing: "第二章正文标记").waitForExistence(timeout: 20))
            app.swipeLeft()
            XCTAssertTrue(page(app, containing: "第三章正文标记").waitForExistence(timeout: 20))
            app.swipeRight()
            XCTAssertTrue(page(app, containing: "第二章正文标记").waitForExistence(timeout: 20))
        }
    }

    func testPreviousOnlineChapterLoadsAtItsLastPage() {
        let app = launch(mode: 0, startSecond: true)
        XCTAssertTrue(page(app, containing: "第二章正文标记").waitForExistence(timeout: 20))
        app.swipeRight()
        XCTAssertTrue(page(app, containing: "第一章末尾标记").waitForExistence(timeout: 30), "网络章节完成加载后应停在上一章末页")
    }

    func testChangingOnlineSourceKeepsChapterAndLoadsContent() {
        let app = XCUIApplication()
        app.launchArguments = ["--reader-boundary-fixture", "--reset-reader-boundary", "--reader-mode=0", "--reader-start-second", "--reader-source-change-fixture"]
        app.launch()
        XCTAssertTrue(page(app, containing: "第二章正文标记").waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let more = app.buttons["更多操作"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(more.frame.height, 40, "阅读菜单按钮不能被裁切，需保留可触摸区域")
        // SwiftUI Menu can report isHittable=false to XCTest even while its
        // visible 44pt label is on screen. Send the physical tap and require
        // the actual menu action to appear and work.
        more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let changeSource = app.buttons["切换书源"]
        XCTAssertTrue(changeSource.waitForExistence(timeout: 10)); changeSource.tap()
        XCTAssertTrue(app.navigationBars["换源"].waitForExistence(timeout: 10))
        let result = app.buttons["changeSource-回归测试书源"]
        XCTAssertTrue(result.waitForExistence(timeout: 30), "打开换源后应自动查找同书名来源")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed, "读取完整目录后才能切换")
        result.tap()
        XCTAssertTrue(page(app, containing: "第2章第1段").waitForExistence(timeout: 30), "换源后应加载对应章节，而非回到第一章或停在未加载状态")
    }

    func testLegacyAndCharacterBookmarksRestoreAfterOnlineLoad() {
        let app = XCUIApplication()
        app.launchArguments = ["--reader-boundary-fixture", "--reset-reader-boundary", "--reader-mode=0", "--reader-start-second", "--reader-bookmark-fixture"]
        app.launch()
        XCTAssertTrue(page(app, containing: "第二章正文标记").waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let more = app.buttons["更多操作"]
        XCTAssertTrue(more.waitForExistence(timeout: 10)); more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["查看书签"].waitForExistence(timeout: 10)); app.buttons["查看书签"].tap()
        let old = app.buttons.containing(.staticText, identifier: "旧网络书签").firstMatch
        XCTAssertTrue(old.waitForExistence(timeout: 10)); old.tap()
        XCTAssertTrue(page(app, containing: "第一章分页内容").waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["第 3 页"].waitForExistence(timeout: 15), "旧版页码书签必须在网络章节完成加载后定位")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["下一章"].waitForExistence(timeout: 10)); app.buttons["下一章"].tap()
        XCTAssertTrue(page(app, containing: "第二章正文标记").waitForExistence(timeout: 15))
        XCTAssertTrue(more.waitForExistence(timeout: 10)); more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["查看书签"].waitForExistence(timeout: 10)); app.buttons["查看书签"].tap()
        let current = app.buttons.containing(.staticText, identifier: "新网络书签").firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 10)); current.tap()
        XCTAssertTrue(page(app, containing: "第一章末尾标记").waitForExistence(timeout: 30), "字符书签应回到同一正文位置")
    }

    func testCharacterBookmarkScrollsToItsPositionAfterOnlineLoad() {
        let app = XCUIApplication()
        app.launchArguments = ["--reader-boundary-fixture", "--reset-reader-boundary", "--reader-mode=2", "--reader-start-second", "--reader-bookmark-fixture", "--reader-scroll-position-fixture"]
        app.launch()
        XCTAssertTrue(app.textViews["readerFullText"].waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let more = app.buttons["更多操作"]
        XCTAssertTrue(more.waitForExistence(timeout: 10)); more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["查看书签"].waitForExistence(timeout: 10)); app.buttons["查看书签"].tap()
        let bookmark = app.buttons.containing(.staticText, identifier: "新网络书签").firstMatch
        XCTAssertTrue(bookmark.waitForExistence(timeout: 10)); bookmark.tap()
        let visible = app.staticTexts["readerVisibleScrollOffset"]
        let scrolled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (Int(visible.label) ?? 0) > 1000
        }, object: visible)
        XCTAssertEqual(XCTWaiter.wait(for: [scrolled], timeout: 30), .completed, "滚动模式应回到书签对应的正文位置")
    }

    func testMoreActionsCanOpenAndCloseBookmarksRepeatedly() {
        for mode in [2, 4] {
            let app = XCUIApplication()
            app.launchArguments = ["--reader-boundary-fixture", "--reset-reader-boundary", "--reader-mode=\(mode)", "--reader-start-second", "--reader-bookmark-fixture"]
            app.launch()
            let text = mode == 2 ? app.textViews["readerFullText"] : page(app, containing: "第二章正文标记")
            XCTAssertTrue(text.waitForExistence(timeout: 20))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            for _ in 0..<3 {
                let more = app.buttons["更多操作"]
                XCTAssertTrue(more.waitForExistence(timeout: 10))
                more.tap()
                let bookmarks = app.buttons["查看书签"]
                XCTAssertTrue(bookmarks.waitForExistence(timeout: 10))
                XCTAssertGreaterThanOrEqual(bookmarks.frame.height, 44)
                bookmarks.tap()
                XCTAssertTrue(app.navigationBars["书签"].waitForExistence(timeout: 10))
                XCTAssertTrue(app.buttons.containing(.staticText, identifier: "新网络书签").firstMatch.exists)
                app.buttons["关闭"].tap()
                XCTAssertTrue(text.waitForExistence(timeout: 10))
                XCTAssertFalse(bookmarks.exists, "关闭书签后，不应残留操作菜单")
            }
            app.terminate()
        }
    }

    func testScrollContinuesBetweenChaptersAtBothEnds() {
        let app = launch(mode: 2, startSecond: true)
        let text = app.textViews["readerFullText"]
        XCTAssertTrue(text.waitForExistence(timeout: 15))
        XCTAssertTrue(text.label.contains("第二章正文标记"))
        app.swipeUp()
        let third = app.textViews.matching(identifier: "readerFullText").matching(NSPredicate(format: "label CONTAINS %@", "第三章正文标记")).firstMatch
        XCTAssertTrue(third.waitForExistence(timeout: 20))
        app.swipeUp()
        XCTAssertTrue(third.exists, "最后一章不能越界")
        app.swipeDown()
        let second = app.textViews.matching(identifier: "readerFullText").matching(NSPredicate(format: "label CONTAINS %@", "第二章正文标记")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 20))
    }

    func testScrollRestoresVisiblePositionAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--reader-boundary-fixture", "--reset-reader-boundary", "--reader-mode=2", "--reader-scroll-position-fixture"]
        app.launch()
        XCTAssertTrue(app.textViews["readerFullText"].waitForExistence(timeout: 30))
        let visible = app.staticTexts["readerVisibleScrollOffset"]
        let saved = app.staticTexts["readerSavedScrollOffset"]
        XCTAssertTrue(visible.waitForExistence(timeout: 10)); XCTAssertTrue(saved.exists)
        app.swipeUp(); app.swipeUp()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let position = Int(visible.label), let stored = Int(saved.label) else { return false }
            return position > 100 && abs(position - stored) < 5
        }, object: saved)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed, "等待当前可见位置保存完成")
        let savedOffset = Int(saved.label) ?? 0
        XCTAssertGreaterThan(savedOffset, 100, "滚动后必须保存章内字符位置")
        app.terminate()
        app.launchArguments = ["--reader-boundary-fixture", "--reader-mode=2", "--reader-scroll-position-fixture"]
        app.launch()
        XCTAssertTrue(app.textViews["readerFullText"].waitForExistence(timeout: 30))
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != '0'"), object: visible)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 15), .completed)
        let restoredOffset = Int(visible.label) ?? 0
        XCTAssertLessThan(abs(restoredOffset - savedOffset), 100, "重新打开应恢复到同一段正文")
    }
}
