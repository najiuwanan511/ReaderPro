import Foundation
import XCTest
@testable import ReaderPro

// Bounded offline reproduction of the common shape shared by the user-pack
// 晋江 and 17K rules: turn a list of HTML nodes into books while fetching
// each detail page synchronously through java.ajax and calling Jsoup bridges.
private final class JSBridgeStressProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var slowStarts = 0
    private let stateLock = NSLock()
    private var work: DispatchWorkItem?
    private var stopped = false

    static func resetStarts() { lock.lock(); slowStarts = 0; lock.unlock() }
    static func starts() -> Int { lock.lock(); defer { lock.unlock() }; return slowStarts }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bridge-stress.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let isSlow = url.path.hasPrefix("/slow/item/")
        if isSlow {
            Self.lock.lock(); Self.slowStarts += 1; Self.lock.unlock()
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.lock(); let active = !self.stopped; self.stateLock.unlock()
            guard active else { return }
            let body: String
            if url.path.hasSuffix("/search") {
                let mode = url.path.hasPrefix("/slow/") ? "slow" : "fast"
                let rows = (0..<10).map { "<li><a href='/\(mode)/item/\($0)'>书\($0)</a></li>" }.joined()
                body = "<ul class='results'>\(rows)</ul>"
            } else {
                body = "<div id='summary'>测试简介</div><span class='author'>测试作者</span>"
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        stateLock.lock()
        if stopped { item.cancel() } else { work = item }
        stateLock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + (isSlow ? 2.5 : 0.001), execute: item)
    }

    override func stopLoading() {
        stateLock.lock(); stopped = true; work?.cancel(); work = nil; stateLock.unlock()
    }
}

final class JSBridgeStressTests: XCTestCase {
    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JSBridgeStressProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func source(slow: Bool) -> LegadoSource {
        var source = LegadoSource()
        source.bookSourceName = "同步列表脚本回归"
        source.bookSourceUrl = "https://bridge-stress.test"
        source.searchUrl = slow ? "/slow/search" : "/fast/search"
        source.ruleSearch.bookList = #"""
        class.results@tag.a
        <js>
        result.toArray().map(function(item) {
          var path=String(item.attr('href'));
          var html=String(java.ajax(path,5000));
          java.setContent(html);
          var doc=org.jsoup.Jsoup.parse(html);
          return {name:String(item.text()),url:path,author:String(doc.select('.author').text()),
                  intro:String(java.getElement('id.summary').text())};
        });
        </js>
        """#
        source.ruleSearch.name = "$.name"
        source.ruleSearch.bookUrl = "$.url"
        source.ruleSearch.author = "$.author"
        source.ruleSearch.intro = "$.intro"
        return source
    }

    func testConcurrentMultiItemAjaxAndSelectorBridges() async throws {
        executionTimeAllowance = 120
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let failures = await SourceHTTP.$testSession.withValue(session) {
            await withTaskGroup(of: String.self, returning: [String].self) { group in
                for worker in 0..<8 {
                    group.addTask {
                        for round in 0..<2 {
                            do {
                                let books = try await withTimeout(30) { try await Self.source(slow: false).search(key: "测试") }
                                guard books.count == 10, books.first?.author == "测试作者",
                                      books.first?.intro == "测试简介" else {
                                    return "worker \(worker) round \(round): \(books.count) books or wrong extracted fields"
                                }
                            } catch { return "worker \(worker) round \(round): \(sourceErrorMessage(error))" }
                        }
                        return ""
                    }
                }
                var errors: [String] = []
                for await error in group where !error.isEmpty { errors.append(error) }
                return errors
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testBatchAjaxDeadlineCancellationAndSubsequentRecovery() async throws {
        executionTimeAllowance = 60
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        JSBridgeStressProtocol.resetStarts()
        let outcomes = await SourceHTTP.$testSession.withValue(session) {
            await withTaskGroup(of: String.self, returning: [String].self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        do {
                            _ = try await withTimeout(1.0) { try await Self.source(slow: true).search(key: "测试") }
                            return "slow request unexpectedly completed"
                        } catch {
                            let message = sourceErrorMessage(error)
                            return message.contains("超时") || message.contains("取消") ? "" : "unexpected error: \(message)"
                        }
                    }
                }
                var errors: [String] = []
                for await error in group where !error.isEmpty { errors.append(error) }
                return errors
            }
        }
        XCTAssertTrue(outcomes.isEmpty, outcomes.joined(separator: "\n"))
        XCTAssertGreaterThan(JSBridgeStressProtocol.starts(), 0, "At least one deadline must occur inside an actual ajax callback")

        JSBridgeStressProtocol.resetStarts()
        let task = Task.detached {
            try await SourceHTTP.$testSession.withValue(session) { try await Self.source(slow: true).search(key: "测试") }
        }
        let deadline = Date().addingTimeInterval(10)
        while JSBridgeStressProtocol.starts() == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let didStart = JSBridgeStressProtocol.starts() > 0
        task.cancel()
        do { _ = try await task.value; XCTFail("The running ajax script must stop when cancelled") }
        catch { XCTAssertTrue(error is CancellationError || sourceErrorMessage(error).contains("取消"), sourceErrorMessage(error)) }
        XCTAssertTrue(didStart, "Cancellation must occur after the bridge starts a network request")

        let recovered = try await SourceHTTP.$testSession.withValue(session) { try await Self.source(slow: false).search(key: "测试") }
        XCTAssertEqual(recovered.count, 10, "Timed-out/cancelled contexts must not poison the next source")
    }
}
