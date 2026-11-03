import XCTest
import AVFoundation
@testable import ReaderPro

final class MediaCacheTests: XCTestCase {
    @MainActor func testNativeHLSPlayerUsesProxyForManifestAndEverySegment() async throws {
        let target = "http://readerproxy.invalid/video/hls/index.m3u8"
        let request = try SourceHTTP.request(target, base: target, headers: [
            "proxy": "http://127.0.0.1:8765", "X-Video": "ReaderPro", "Referer": "http://127.0.0.1:8765/video/book"])
        let resource = try await SourceVideoResource.native(request).resolvedForPlayback()
        XCTAssertEqual(resource.request.url?.host, "127.0.0.1")
        let player = AVPlayer(url: try XCTUnwrap(resource.request.url))
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        player.play()
        let end = Date().addingTimeInterval(20)
        while player.currentTime().seconds < 0.4 && Date() < end && player.currentItem?.status != .failed { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNil(player.currentItem?.error)
        XCTAssertGreaterThan(player.currentTime().seconds, 0.3, player.currentItem?.error?.localizedDescription ?? "Proxied HLS never advanced")
    }

    func testNativeMediaRelayDoesNotFallBackWhenProxyIsBroken() async throws {
        let target = "http://127.0.0.1:8765/video/episode1.mp4"
        let request = try SourceHTTP.request(target, base: target, headers: ["proxy": "http://127.0.0.1:1"])
        let resource = try await SourceVideoResource.native(request).resolvedForPlayback()
        let response = try await URLSession.shared.data(for: resource.request)
        XCTAssertEqual((response.1 as? HTTPURLResponse)?.statusCode, 502)
        XCTAssertTrue(response.0.isEmpty)
    }
    private func fixture() -> (MediaDiskCache, LocalBook, BookChapter, URLRequest) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaCacheTest-" + UUID().uuidString)
        var book = LocalBook(title: "媒体离线测试", sourceUrl: "https://fixture.test", fileName: "offline.web", kind: "video")
        let chapter = BookChapter(title: "第一集", text: "__URL__http://127.0.0.1:8765/video/hls/index.m3u8", url: "http://127.0.0.1:8765/video/hls/index.m3u8")
        book.chapters = [chapter]
        var request = URLRequest(url: URL(string: chapter.url!)!)
        request.setValue("ReaderPro", forHTTPHeaderField: "X-Video")
        request.setValue("http://127.0.0.1:8765/video/book", forHTTPHeaderField: "Referer")
        return (MediaDiskCache(root: root), book, chapter, request)
    }
    @MainActor func testHLSCacheSurvivesNewCacheInstanceAndActuallyPlaysLocalSegments() async throws {
        let (cache, book, chapter, request) = fixture()
        addTeardownBlock { await cache.clear(bookID: book.id); try? FileManager.default.removeItem(at: cache.root) }
        _ = try await cache.download(book: book, chapter: chapter, request: request, auxiliary: "[00:01]离线歌词")
        let relaunched = MediaDiskCache(root: cache.root)
        let loaded = try await relaunched.cached(book: book, chapter: chapter)
        let media = try XCTUnwrap(loaded)
        XCTAssertEqual(media.auxiliary, "[00:01]离线歌词")
        let count = await relaunched.count(book: book); XCTAssertEqual(count, 1)
        let response = try await URLSession.shared.data(from: XCTUnwrap(media.request.url))
        let playlist = String(decoding: response.0, as: UTF8.self)
        XCTAssertFalse(playlist.contains("8765")); XCTAssertFalse(playlist.contains("http:"))
        let player = AVPlayer(url: try XCTUnwrap(media.request.url))
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        player.play()
        let end = Date().addingTimeInterval(15)
        while player.currentTime().seconds < 0.4 && Date() < end && player.currentItem?.status != .failed { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNil(player.currentItem?.error)
        XCTAssertGreaterThan(player.currentTime().seconds, 0.3, "Downloaded segments must actually play from local HTTP, not merely create a ready item")
        let segment = try XCTUnwrap(playlist.components(separatedBy: .newlines).first { !$0.isEmpty && !$0.hasPrefix("#") })
        let segmentURL = try XCTUnwrap(URL(string: segment, relativeTo: media.request.url))
        var range = URLRequest(url: segmentURL); range.setValue("bytes=1-31", forHTTPHeaderField: "Range")
        let ranged = try await URLSession.shared.data(for: range)
        XCTAssertEqual((ranged.1 as? HTTPURLResponse)?.statusCode, 206); XCTAssertEqual(ranged.0.count, 31)
        var switched = book; switched.sourceUrl = "https://different-source.test"
        let changed = try await relaunched.cached(book: switched, chapter: chapter); XCTAssertNil(changed)
        await cache.clear(bookID: book.id)
        let deleted = try await relaunched.cached(book: book, chapter: chapter); XCTAssertNil(deleted)
    }
    func testDirectMediaIsPersistedAndFailedTransferIsNeverMarkedComplete() async throws {
        let (cache, book, chapter, original) = fixture()
        addTeardownBlock { await cache.clear(bookID: book.id); try? FileManager.default.removeItem(at: cache.root) }
        var request = original; request.url = URL(string: "http://127.0.0.1:8765/video/episode1.mp4")
        let media = try await cache.download(book: book, chapter: chapter, request: request)
        XCTAssertTrue(media.request.url?.isFileURL == true)
        XCTAssertGreaterThan(try Data(contentsOf: XCTUnwrap(media.request.url)).count, 1000)
        await cache.clear(bookID: book.id)
        request.setValue(nil, forHTTPHeaderField: "X-Video")
        do { _ = try await cache.download(book: book, chapter: chapter, request: request); XCTFail("403 must not be saved as a video") } catch {}
        let missing = try await cache.cached(book: book, chapter: chapter); XCTAssertNil(missing)
    }
    func testClearingAnInflightTransferCannotRecreateTheCache() async throws {
        let (cache, book, chapter, _) = fixture()
        addTeardownBlock { await cache.clear(bookID: book.id); try? FileManager.default.removeItem(at: cache.root) }
        let request = URLRequest(url: URL(string: "http://127.0.0.1:8765/slow-search")!)
        let task = Task { try await cache.download(book: book, chapter: chapter, request: request) }
        try await Task.sleep(nanoseconds: 300_000_000)
        await cache.clear(bookID: book.id)
        do { _ = try await task.value; XCTFail("Cleared transfer must not complete") } catch {}
        let missing = try await cache.cached(book: book, chapter: chapter); XCTAssertNil(missing)
    }
    func testVideoRuleKeepsProxyMetadataWithoutLeakingProxyHeader() async throws {
        var source = LegadoSource(); source.bookSourceUrl = "http://127.0.0.1:8765"; source.bookSourceType = 4
        source.header = #"{"proxy":"socks5://127.0.0.1:8767","X-Video":"ReaderPro"}"#
        let resource = try await source.fetchChapterVideo(BookChapter(title: "代理视频", text: "", url: "https://media.test/a.mp4"))
        XCTAssertEqual(try SourceProxy.configuration(for: resource.request)?.kind, .socks5)
        XCTAssertNil(resource.request.value(forHTTPHeaderField: "proxy"))
        XCTAssertEqual(resource.request.value(forHTTPHeaderField: "X-Video"), "ReaderPro")
    }
}
