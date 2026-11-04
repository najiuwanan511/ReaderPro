import XCTest
@testable import ReaderPro

final class SourceConcurrencyTests: XCTestCase {
    private actor Probe {
        var events: [String] = []
        var active = 0
        var maximum = 0
        var released = false
        var results: [Int] = []
        func work(_ index: Int, blockAll: Bool = false) async -> Int {
            active += 1; maximum = max(maximum, active); events.append("start\(index)")
            if index == 2 && !blockAll { released = true }
            while index == 1 && !blockAll && !events.contains("start0") && !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000) } catch { break }
            }
            while (index == 0 || blockAll) && !released && !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000) } catch { break }
            }
            active -= 1; events.append("finish\(index)")
            return index
        }
        func receive(_ result: Int) { results.append(result) }
        func snapshot() -> (Int, Int, [String], [Int]) { (active, maximum, events, results) }
    }

    func testRollingPoolRefillsBeforeSlowSourceCompletes() async throws {
        let probe = Probe()
        try await withTimeout(5) {
            await streamConcurrentWork(Array(0..<6), concurrency: 2, operation: { await probe.work($0) }, update: { await probe.receive($0) })
        }
        let (active, maximum, events, results) = await probe.snapshot()
        XCTAssertEqual(active, 0); XCTAssertEqual(maximum, 2)
        XCTAssertEqual(results.sorted(), Array(0..<6))
        let startNext = try XCTUnwrap(events.firstIndex(of: "start2"))
        let finishSlow = try XCTUnwrap(events.firstIndex(of: "finish0"))
        XCTAssertLessThan(startNext, finishSlow, "A slow first source must not block the next batch")
    }

    func testCancellingPoolStopsQueueAndDiscardsCancelledResults() async throws {
        let probe = Probe()
        let task = Task {
            await streamConcurrentWork(Array(0..<100), concurrency: 3, operation: { await probe.work($0, blockAll: true) }, update: { await probe.receive($0) })
        }
        let deadline = Date().addingTimeInterval(5)
        while await probe.snapshot().0 < 3 && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        let started = await probe.snapshot()
        XCTAssertEqual(started.0, 3)
        task.cancel(); await task.value
        let (active, maximum, events, results) = await probe.snapshot()
        XCTAssertEqual(active, 0); XCTAssertEqual(maximum, 3)
        XCTAssertEqual(events.filter { $0.hasPrefix("start") }.count, 3)
        XCTAssertTrue(results.isEmpty)
    }

    func testConcurrencyDefaultsPersistenceAndBounds() throws {
        let name = "ReaderPro.concurrency-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(SourceConcurrency.value(SourceConcurrency.searchKey, fallback: 32, defaults: defaults), 32)
        XCTAssertEqual(SourceConcurrency.value(SourceConcurrency.validationKey, fallback: 32, defaults: defaults), 32)
        defaults.set(12, forKey: SourceConcurrency.searchKey)
        XCTAssertEqual(SourceConcurrency.value(SourceConcurrency.searchKey, fallback: 32, defaults: defaults), 12)
        defaults.set(-1, forKey: SourceConcurrency.validationKey)
        XCTAssertEqual(SourceConcurrency.value(SourceConcurrency.validationKey, fallback: 32, defaults: defaults), 1)
        defaults.set(999, forKey: SourceConcurrency.webKey)
        XCTAssertEqual(SourceConcurrency.value(SourceConcurrency.webKey, fallback: 4, maximum: 8, defaults: defaults), 8)
    }

    func testConcurrentValidationPreservesEachSourcesReport() async {
        actor Reports {
            var rows: [SourceValidationReport] = []
            func add(_ report: SourceValidationReport) { rows.append(report) }
        }
        let sources = (0..<6).map { index -> LegadoSource in
            var source = SourceTestFixtures.json(); source.id = "concurrent-validation-\(index)"
            return source
        }
        var options = SourceValidationOptions()
        options.discovery = false; options.info = false; options.mediaPlayback = false
        let reports = Reports()
        await streamSourceValidation(sources, keyword: "测试", options: options, concurrency: 3) { await reports.add($0) }
        let rows = await reports.rows
        XCTAssertEqual(Set(rows.map(\.id)), Set(sources.map(\.id)))
        XCTAssertEqual(rows.count, sources.count)
        XCTAssertTrue(rows.allSatisfy { $0.status == .passed })
    }
}
