import XCTest

// Keep these flows in the existing test class so both CI configurations run
// them, including the iPhone 14 Pro Max / iOS 17 Release configuration.
extension SourceFlowUITests {
    func testDiscoveryScriptButtonOpensNativeVideoAndReturnsToCategories() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--source-ui-fixture", "--reset-source-fixture", "--video-ui-fixture", "--video-script-fixture"]
        app.launch(); app.tabBars.buttons["发现"].tap()
        let source = app.buttons["短剧视频测试源"]
        XCTAssertTrue(source.waitForExistence(timeout: 15)); source.tap()
        let category = app.buttons["脚本播放"]
        XCTAssertTrue(category.waitForExistence(timeout: 15)); category.tap()
        let time = app.staticTexts["videoPlaybackTime"]
        XCTAssertTrue(time.waitForExistence(timeout: 15))
        let advanced = NSPredicate(format: "label MATCHES %@", "已播放 ([2-9]|[1-9][0-9]+) 秒")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: advanced, object: time)], timeout: 30), .completed)
        app.buttons["返回目录"].tap()
        XCTAssertTrue(category.waitForExistence(timeout: 10))
    }

    private func openVideo(_ app: XCUIApplication, error: Bool = false, web: Bool = false, hls: Bool = false, reset: Bool = true) {
        continueAfterFailure = false
        app.launchArguments = ["--source-ui-fixture", "--video-ui-fixture"] + (reset ? ["--reset-source-fixture"] : []) + (error ? ["--video-error-fixture"] : []) + (web ? ["--video-web-fixture"] : [])
        if hls { app.launchArguments.append("--video-hls-fixture") }
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

    private func videoSeconds(_ app: XCUIApplication) -> Int {
        Int(app.staticTexts["videoPlaybackTime"].label.split(separator: " ").dropFirst().first ?? "") ?? 0
    }
    private func selectVideoRate(_ rate: String, app: XCUIApplication) {
        let menu = app.buttons["videoSpeedMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20)); menu.tap()
        let choice = app.buttons["video-rate-\(rate)"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
    }

    func testVideoSpeedSliderAndEpisodePickerPreserveSpeedAfterRelaunch() {
        let app = XCUIApplication()
        openVideo(app)
        let slider = app.sliders["videoSeekSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 20))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: slider)], timeout: 20), .completed)
        selectVideoRate("1.5", app: app)
        let pause = app.buttons["videoPlayPause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 15))
        XCTAssertEqual(pause.label, "暂停播放"); pause.tap()
        XCTAssertEqual(pause.label, "继续播放")
        let before = videoSeconds(app)
        slider.adjust(toNormalizedSliderPosition: 0.65)
        let sought = NSPredicate { _, _ in self.videoSeconds(app) > before + 2 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: sought, object: nil)], timeout: 15), .completed)
        XCTAssertEqual(pause.label, "继续播放")
        XCTAssertEqual(app.buttons["videoSpeedMenu"].value as? String, "1.5 倍")
        pause.tap()
        app.buttons["videoChooseEpisode"].tap()
        XCTAssertTrue(app.buttons["video-picker-episode-2"].waitForExistence(timeout: 10))
        app.buttons["video-picker-episode-2"].tap()
        XCTAssertEqual(app.staticTexts["videoEpisodeTitle"].label, "第3集")
        XCTAssertTrue(app.buttons["videoSpeedMenu"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.buttons["videoSpeedMenu"].value as? String, "1.5 倍")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "视频倍速进度条与选集"; shot.lifetime = .keepAlways; add(shot)
        app.terminate()
        openVideo(app, reset: false)
        XCTAssertTrue(app.buttons["videoSpeedMenu"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.buttons["videoSpeedMenu"].value as? String, "1.5 倍")
        selectVideoRate("1.0", app: app)
    }

    func testVideoHoldTemporarilyAcceleratesAndReleasesToPreferredRate() {
        let app = XCUIApplication()
        openVideo(app)
        selectVideoRate("0.5", app: app)
        let advanced = NSPredicate { _, _ in self.videoSeconds(app) >= 1 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: advanced, object: nil)], timeout: 20), .completed)
        let picture = app.otherElements["chapterVideoPlayer"].firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 10))
        let before = videoSeconds(app), start = Date()
        picture.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3)).press(forDuration: 4)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(Double(videoSeconds(app) - before), elapsed * 0.7, "A held 2x picture must advance faster than the preferred 0.5x rate")
        XCTAssertFalse(app.staticTexts["videoHoldIndicator"].exists)
        XCTAssertEqual(app.buttons["videoSpeedMenu"].value as? String, "0.5 倍")
        XCTAssertEqual(app.buttons["videoPlayPause"].label, "暂停播放")
        selectVideoRate("1.0", app: app)
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

    func testLegacyVideoRulePlaysAnEmbeddedIframeInsideTheApp() {
        let app = XCUIApplication()
        openVideo(app, web: true)
        let time = app.staticTexts["videoPlaybackTime"]
        let advanced = NSPredicate(format: "label MATCHES %@", "已播放 ([2-9]|[1-9][0-9]+) 秒")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: advanced, object: time)], timeout: 40), .completed, app.staticTexts["videoPlaybackStatus"].label)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "章节网页播放器识别并播放内嵌视频"; shot.lifetime = .keepAlways; add(shot)
    }

    func testHLSPlaybackSendsSourceHeadersToManifestAndSegments() {
        let app = XCUIApplication()
        openVideo(app, hls: true)
        let time = app.staticTexts["videoPlaybackTime"]
        let advanced = NSPredicate(format: "label MATCHES %@", "已播放 ([2-9]|[1-9][0-9]+) 秒")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: advanced, object: time)], timeout: 40), .completed, app.staticTexts["videoPlaybackStatus"].label)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "HLS分片携带书源请求头并实际播放"; shot.lifetime = .keepAlways; add(shot)
    }
}
