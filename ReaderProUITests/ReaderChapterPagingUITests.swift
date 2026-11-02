import XCTest

final class ReaderChapterPagingUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        executionTimeAllowance = 300
    }

    private func launch(mode: Int, startSecond: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reader-boundary-fixture", "--reset-reader-boundary", "--reader-mode=\(mode)"]
        if startSecond { app.launchArguments.append("--reader-start-second") }
        app.launch()
        return app
    }

    private func page(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.textViews.matching(identifier: "readerPage")
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
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
    func testSlideSwipeAcrossChapterBoundaries() { exercisePagedMode(1) }
    func testNoAnimationSwipeAcrossChapterBoundaries() { exercisePagedMode(3) }
    func testCurlSwipeAcrossChapterBoundaries() { exercisePagedMode(4) }

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
        app.buttons["搜索"].tap()
        let result = app.buttons.containing(.staticText, identifier: "测试小说").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30)); result.tap()
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
