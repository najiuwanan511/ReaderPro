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

    func testPreviousOnlineChapterLoadsAtItsLastPage() {
        let app = launch(mode: 0, startSecond: true)
        XCTAssertTrue(page(app, containing: "第二章正文标记").waitForExistence(timeout: 20))
        app.swipeRight()
        XCTAssertTrue(page(app, containing: "第一章末尾标记").waitForExistence(timeout: 30), "网络章节完成加载后应停在上一章末页")
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
}
