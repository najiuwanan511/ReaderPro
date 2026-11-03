import XCTest

// Keep these flows in the existing test class so both CI configurations run
// them, including the iPhone 14 Pro Max / iOS 17 Release configuration.
extension SourceFlowUITests {
    private func openVideo(_ app: XCUIApplication, error: Bool = false) {
        continueAfterFailure = false
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--video-ui-fixture"] + (error ? ["--video-error-fixture"] : [])
        app.launch()
        app.tabBars.buttons["发现"].tap()
        let source = app.buttons["短剧视频测试源"]
        XCTAssertTrue(source.waitForExistence(timeout: 15)); source.tap()
        let category = app.buttons["短剧分类"]
        XCTAssertTrue(category.waitForExistence(timeout: 15)); category.tap()
        let book = app.staticTexts["测试短剧"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30)); book.tap()
        XCTAssertTrue(app.buttons["chapter-1"].waitForExistence(timeout: 30))
        app.buttons["chapter-1"].tap()
        XCTAssertTrue(app.staticTexts["videoEpisodeTitle"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["videoEpisodeTitle"].label, "第2集")
    }

    func testDiscoveryVideoChapterActuallyPlaysAndSwitchesEpisodes() {
        let app = XCUIApplication()
        openVideo(app)
        let time = app.staticTexts["videoPlaybackTime"]
        let advanced = NSPredicate(format: "label MATCHES %@", "已播放 ([2-9]|[1-9][0-9]+) 秒")
        XCTAssertTrue(time.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: advanced, object: time)], timeout: 30), .completed, app.staticTexts["videoPlaybackStatus"].label)
        let firstShot = XCTAttachment(screenshot: app.screenshot()); firstShot.name = "发现短剧第二集实际播放"; firstShot.lifetime = .keepAlways; add(firstShot)
        app.buttons["video-episode-0"].tap()
        XCTAssertEqual(app.staticTexts["videoEpisodeTitle"].label, "第1集")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: advanced, object: time)], timeout: 30), .completed)
        app.buttons["videoNextEpisode"].tap()
        XCTAssertEqual(app.staticTexts["videoEpisodeTitle"].label, "第2集")
        app.buttons["返回目录"].tap()
        XCTAssertTrue(app.buttons["chapter-1"].waitForExistence(timeout: 10))
        app.buttons["chapter-2"].tap()
        XCTAssertTrue(app.staticTexts["videoEpisodeTitle"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["videoEpisodeTitle"].label, "第3集")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: advanced, object: time)], timeout: 30), .completed)
    }

    func testVideoFailureShowsReasonAndRetryInsteadOfBlankReader() {
        let app = XCUIApplication()
        openVideo(app, error: true)
        let status = app.staticTexts["videoPlaybackStatus"]
        let failed = NSPredicate(format: "label CONTAINS %@", "未返回播放地址")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: failed, object: status)], timeout: 15), .completed)
        XCTAssertTrue(app.buttons["videoRetry"].isHittable)
        app.buttons["videoRetry"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: failed, object: status)], timeout: 15), .completed)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "视频解析失败原因与重试"; shot.lifetime = .keepAlways; add(shot)
    }
}
