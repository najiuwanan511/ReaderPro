import XCTest
import WebKit
import AVFoundation
import MediaPlayer
@testable import ReaderPro

final class MediaAndRssParityTests: XCTestCase {
    @MainActor func testOnlineSpeechPublishesLockScreenStatePausesForHeadphoneRemovalAndClearsOnStop() async throws {
        let defaults = UserDefaults.standard, library = ReaderRuleLibrary.shared
        let oldEngine = defaults.object(forKey: "speech.engineID"), oldList = library.httpTts
        let speech = SpeechController()
        XCTAssertFalse(speech.hasSystemSynthesizer)
        speech.stop(); speech.togglePause()
        XCTAssertFalse(speech.hasSystemSynthesizer)
        defer {
            speech.stop(); library.httpTts = oldList
            if let oldEngine { defaults.set(oldEngine, forKey: "speech.engineID") }
            else { defaults.removeObject(forKey: "speech.engineID") }
        }
        var engine = HttpTTS(); engine.id = -9876; engine.name = "锁屏朗读回归"
        engine.url = "http://127.0.0.1:8765/parity/tts?text={{speakText}}&speed={{speakSpeed}}"
        library.httpTts = [engine]; defaults.set(String(engine.id), forKey: "speech.engineID")
        let finished = expectation(description: "HTTP speech resumes and completes")
        speech.speak(segments: ["你好世界", "你好世界"], rate: 0.6, pitch: 1, title: "测试书 · 第一章", author: "作者") { finished.fulfill() }
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        XCTAssertTrue(speech.isPaused)
        XCTAssertFalse(speech.hasSystemSynthesizer, "HTTP speech must not initialize system voice assets")
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertTrue(speech.isSpeaking, "A paused HTTP segment must wait for resume instead of completing")
        XCTAssertEqual(speech.error, "")
        let info = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "测试书 · 第一章")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
        XCTAssertFalse(MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled)
        XCTAssertTrue(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
        speech.togglePause()
        await fulfillment(of: [finished], timeout: 15)
        XCTAssertFalse(speech.isSpeaking)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        speech.stop()
        XCTAssertFalse(speech.hasSystemSynthesizer)
        XCTAssertFalse(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
    }

    func testSpeechParagraphOffsetsSkipBlankLinesAndUseUTF16() {
        let text = "开头😀\n\n  第二段\n末段"
        let paragraphs = ReaderSpeechText.paragraphs(text, from: 2)
        XCTAssertEqual(paragraphs.map(\.text), ["😀", "第二段", "末段"])
        XCTAssertEqual(paragraphs.map(\.offset), [2, 6, 12])
    }

    @MainActor func testDashVideoActuallyPlaysSeparatedAudioAndVideoSegmentsWithHeaders() async throws {
        let request = URLRequest(url: URL(string: "http://127.0.0.1:8765/video/dash/manifest.mpd")!)
        var headers = request; headers.setValue("ReaderPro", forHTTPHeaderField: "X-Video")
        let resource = try await SourceVideoResource.dash(nil, headers).resolvedForPlayback()
        guard case .native(let playable) = resource else { return XCTFail("DASH did not resolve to native playback") }
        let response = try await URLSession.shared.data(from: XCTUnwrap(playable.url))
        let master = String(decoding: response.0, as: UTF8.self)
        XCTAssertTrue(master.contains("TYPE=AUDIO")); XCTAssertTrue(master.contains("avc1.64000c,mp4a.40.2"))
        let player = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: try XCTUnwrap(playable.url), options: ["AVURLAssetHTTPHeaderFieldsKey": playable.allHTTPHeaderFields ?? [:]])))
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        player.play()
        let end = Date().addingTimeInterval(20)
        while player.currentTime().seconds < 0.4 && Date() < end && player.currentItem?.status != .failed {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(player.currentItem?.error)
        XCTAssertGreaterThan(player.currentTime().seconds, 0.3, player.currentItem?.error?.localizedDescription ?? "DASH never advanced")
    }

    func testDashTemplateInheritanceTimeRepeatsAndUnsupportedEncryption() throws {
        let xml = #"""
        <MPD type="static" mediaPresentationDuration="PT6S"><BaseURL>https://cdn.test/root/</BaseURL><Period><AdaptationSet mimeType="video/mp4" codecs="avc1.64001f">
        <SegmentTemplate timescale="10" initialization="init-$RepresentationID$.mp4" media="$Time$-$Number%03d$.m4s" startNumber="7"><SegmentTimeline><S t="0" d="20" r="-1"/></SegmentTimeline></SegmentTemplate>
        <Representation id="HD" bandwidth="1000"><BaseURL>video/</BaseURL></Representation></AdaptationSet></Period></MPD>
        """#
        let manifest = try DashManifest(data: Data(xml.utf8), url: URL(string: "https://source.test/manifest.mpd")!)
        let playlist = try XCTUnwrap(manifest.playlists["track0.m3u8"])
        XCTAssertTrue(playlist.contains("https://cdn.test/root/video/init-HD.mp4"))
        for part in ["0-007.m4s", "20-008.m4s", "40-009.m4s"] { XCTAssertTrue(playlist.contains(part)) }
        XCTAssertEqual(playlist.components(separatedBy: "#EXTINF:").count - 1, 3)
        XCTAssertThrowsError(try DashManifest(data: Data(xml.replacingOccurrences(of: "<Representation", with: "<ContentProtection schemeIdUri='urn:mpeg:dash:mp4protection:2011'/><Representation").utf8), url: URL(string: "https://source.test/a.mpd")!))
        XCTAssertThrowsError(try DashManifest(data: Data(xml.replacingOccurrences(of: "type=\"static\"", with: "type=\"dynamic\"").utf8), url: URL(string: "https://source.test/a.mpd")!))
    }

    @MainActor func testMediaInterruptionsPauseAndCannotResumeAReplacementPlayer() {
        let controls = MediaPlaybackControls.shared, first = UUID(), second = UUID()
        var pauses = 0, plays = 0
        func activate(_ owner: UUID) {
            controls.activate(owner: owner, title: "测试", author: "", play: { plays += 1 }, pause: { pauses += 1 },
                              isPlaying: { true }, toggle: {}, seek: { _ in }, skip: { _ in })
        }
        activate(first)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        XCTAssertEqual(pauses, 1)
        activate(second)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                       AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        XCTAssertEqual(plays, 0, "An interruption from the previous episode must not start its replacement")
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        XCTAssertEqual(pauses, 2)
        controls.release(owner: second)
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        XCTAssertEqual(pauses, 2)
    }

    func testRssWebRequestsParseHeadersAndReturnBodyRatherThanResponseEnvelope() async throws {
        var source = RssSource(); source.sourceUrl = "http://127.0.0.1:8765"
        let headers = #"{"X-Login":"rss-bridge-token"}"#
        let result = try await RssWebBridge.evaluate(command: "getAwait", args: [source.sourceUrl + "/bridge-login-check", headers, "5000"], source: source, base: source.sourceUrl)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: String])
        XCTAssertEqual(value["custom"], "rss-bridge-token")
        let parsed = try await RssWebBridge.evaluate(command: "getStringAwait", args: ["p@text", "<p>网页解析结果</p>"], source: source, base: source.sourceUrl)
        XCTAssertEqual(parsed, "网页解析结果")
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "rsa-vector", withExtension: "json"))
        let vector = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String])
        let signed = try await RssWebBridge.evaluate(command: "createSignHexAwait", args: ["SHA256withRSA", try XCTUnwrap(vector["publicSPKI"]), try XCTUnwrap(vector["privatePKCS8"]), try XCTUnwrap(vector["message"])], source: source, base: source.sourceUrl)
        XCTAssertEqual(SourceCrypto.hex(signed)?.base64EncodedString(), vector["sha256"])
    }

    @MainActor func testRssWebPageRunsAsyncRulesSharesVariablesAndOpensBookSearch() async throws {
        var source = RssSource(); source.sourceName = "网页桥样例"; source.sourceUrl = "http://127.0.0.1:8765/rss-bridge-" + UUID().uuidString
        source.preloadJs = "// enable native bridge"
        let finished = expectation(description: "Web source invokes book search after real rule and HTTP requests")
        var received: RssWebAction?
        let bridge = RssWebBridge(source: source) { action in received = action; finished.fulfill() }
        let configuration = WKWebViewConfiguration(); bridge.install(configuration)
        let web = WKWebView(frame: .zero, configuration: configuration)
        defer {
            bridge.cancel(); web.stopLoading(); configuration.userContentController.removeScriptMessageHandler(forName: "readerRss", contentWorld: .page)
        }
        let html = #"""
        <html><body><script>
        (async function(){try{
          source.put('web-test','保存变量');
          var saved=await run("java.get('web-test')");
          var json=await ajaxAwait('http://127.0.0.1:8765/parity/search?page=1');
          if(saved!=='保存变量'||JSON.parse(json).books[0].title!=='分页小说1')throw Error('bridge values mismatch');
          java.searchBook('分页小说1','样例分组');
        }catch(e){java.toast('失败:'+String(e));}})();
        </script></body></html>
        """#
        web.loadHTMLString(html, baseURL: URL(string: source.sourceUrl))
        await fulfillment(of: [finished], timeout: 30)
        XCTAssertEqual(received?.command, "searchBook", received?.value ?? "No bridge response")
        XCTAssertEqual(received?.value, "分页小说1"); XCTAssertEqual(received?.scope, "样例分组")
        XCTAssertEqual(LegadoJS.persistentValues(source: source.sourceUrl)["web-test"], "保存变量")
    }

    func testImageDecodeAcceptsSignedAndroidBytesAndRejectsInvalidOutput() async throws {
        var source = LegadoSource(); source.bookSourceUrl = "https://image-decode.test"
        source.coverDecodeJs = "result.map(function(n){return n>127?n-256:n;})"
        let input = Data([0, 127, 128, 255])
        try await source.withRules {
            XCTAssertEqual(try SourceImagePipeline.decode(input, source: source, cover: true, url: source.bookSourceUrl), input)
        }
        source.coverDecodeJs = "[999]"
        do {
            _ = try await source.withRules { try SourceImagePipeline.decode(input, source: source, cover: true, url: source.bookSourceUrl) }
            XCTFail("Invalid bytes must fail")
        } catch { XCTAssertTrue(sourceErrorMessage(error).contains("字节")) }
    }

    func testSourceRateUsesAndroidMillisecondsAndRequestCount() {
        XCTAssertEqual(SourceRateLimiter.Rate("3/1000")?.count, 3)
        XCTAssertEqual(SourceRateLimiter.Rate("3/1000")?.interval, 1)
        XCTAssertEqual(SourceRateLimiter.Rate("500")?.count, 1)
        XCTAssertEqual(SourceRateLimiter.Rate("500")?.interval, 0.5)
        for invalid in ["", "0/1000", "2/0", "a/b", "1/2/3", "-1"] { XCTAssertNil(SourceRateLimiter.Rate(invalid)) }
    }

    func testRssWebBlacklistPrecedesWhitelistAndMatchesWholeRegexOrPrefix() {
        var source = RssSource()
        source.contentWhitelist = "https://allowed.test/"
        XCTAssertTrue(FeedWebRules.allows("https://allowed.test/image.jpg", source: source))
        XCTAssertFalse(FeedWebRules.allows("https://other.test/image.jpg", source: source))
        source.contentBlacklist = ".*\\.gif,https://ads.test/"
        XCTAssertFalse(FeedWebRules.allows("https://allowed.test/a.gif", source: source))
        XCTAssertFalse(FeedWebRules.allows("https://ads.test/a", source: source))
        XCTAssertTrue(FeedWebRules.allows("https://other.test/a.jpg", source: source))
        XCTAssertNotNil(FeedWebRules.contentRules(source))
    }

    func testRssFavoritesAndHistorySurviveRelaunchWithoutDuplicates() throws {
        let name = "RssParityTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var source = RssSource(); source.sourceName = "订阅"; source.sourceUrl = "https://rss.test"
        let first = SavedRssArticle(source: source, article: RssArticle(title: "文章", link: "https://rss.test/a", content: "正文"))
        let store = RssReadingStore(defaults: defaults)
        store.toggle(first); store.record(first); store.record(first)
        let loaded = RssReadingStore(defaults: defaults)
        XCTAssertEqual(loaded.favorites.count, 1); XCTAssertEqual(loaded.history.count, 1)
        XCTAssertEqual(loaded.history.first?.article.content, "正文")
        loaded.toggle(first)
        XCTAssertTrue(RssReadingStore(defaults: defaults).favorites.isEmpty)
    }

    func testDanmakuParsesTimedXmlAndJsonAndRejectsInvalidTimes() {
        let xml = "<i><d p='2.5,5,25,16711680'>甲&amp;乙</d><d p='-1,1'>丢弃</d><d p='1,1,25,16777215'>先显示</d></i>"
        let entries = parseDanmaku(xml)
        XCTAssertEqual(entries.map(\.text), ["先显示", "甲&乙"])
        XCTAssertEqual(entries.last?.mode, 5); XCTAssertEqual(entries.last?.color, 0xFF0000)
        XCTAssertEqual(parseDanmaku("[{\"time\":1,\"text\":\"字幕\"},{\"time\":-2,\"text\":\"忽略\"}]").map(\.text), ["字幕"])
    }

    func testOnlineAudioUsesChapterRuleAndPreservesHeaders() async throws {
        var source = LegadoSource(); source.bookSourceUrl = "https://audio.test"; source.bookSourceType = 1
        source.header = "{\"X-Audio\":\"token\"}"
        source.ruleContent.content = "@js:baseUrl"
        let resource = try await source.fetchChapterAudio(BookChapter(title: "第1集", text: "", url: "https://audio.test/1.mp3"))
        XCTAssertEqual(resource.request.url?.absoluteString, "https://audio.test/1.mp3")
        XCTAssertEqual(resource.request.value(forHTTPHeaderField: "X-Audio"), "token")
        XCTAssertEqual(source.localBookKind, "audio")
    }
}
