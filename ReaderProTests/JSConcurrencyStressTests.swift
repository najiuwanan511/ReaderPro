import XCTest
@testable import ReaderPro

// The original audit exercised many unrelated websites concurrently. This
// bounded, offline regression isolates JavaScriptCore, including nested
// contexts and watchdog cleanup, so a failure has a much smaller scope.
final class JSConcurrencyStressTests: XCTestCase {
    func testConcurrentScriptsTimeoutCancellationAndRecovery() async throws {
        executionTimeAllowance = 60
        let base = "https://example.invalid"
        let started = Date()
        let cancelSources = (0..<2).map { _ in base + "/js-stress/" + UUID().uuidString }

        // A source-local marker is set by JavaScript itself. Waiting for it
        // proves cancellation happens after each VM actually began evaluation.
        let cancellationTasks = cancelSources.map { source in
            Task.detached { () -> (String, String) in
                let failures = RuleFailures()
                let output = LegadoJSCtx.$deadline.withValue(Date().addingTimeInterval(10)) {
                    LegadoJSCtx.$failures.withValue(failures) {
                        LegadoJS.run("java.put('started','yes'); while(true){}", input: "", baseUrl: base,
                                     sourceKey: "", sourceUrl: source)
                    }
                }
                do { try failures.check(); return (output, "") }
                catch { return (output, sourceErrorMessage(error)) }
            }
        }

        // Together with the two cancellation tasks, six workers make eight
        // concurrently active tasks. Four repeatedly create nested contexts;
        // the other two exercise independently expiring watchdogs.
        let workers = Task.detached { () -> [String] in
            await withTaskGroup(of: String.self, returning: [String].self) { group in
                for worker in 0..<4 {
                    group.addTask {
                        for round in 0..<8 {
                            let key = "\(worker)-\(round)"
                            let failures = RuleFailures()
                            let result = LegadoJSCtx.$failures.withValue(failures) {
                                LegadoJS.run("java.getString('@js:result.toUpperCase()', 'nested-\(key)') + '|' + (1+1)",
                                             input: "", baseUrl: base, sourceKey: key, sourceUrl: base)
                            }
                            do { try failures.check() }
                            catch { return "nested worker \(worker), round \(round): \(sourceErrorMessage(error))" }
                            if result != "NESTED-\(key)|2" {
                                return "nested worker \(worker), round \(round): unexpected \(result)"
                            }
                        }
                        return ""
                    }
                }
                for worker in 0..<2 {
                    group.addTask {
                        let source = base + "/timeout/" + UUID().uuidString
                        let failures = RuleFailures()
                        let output = LegadoJSCtx.$deadline.withValue(Date().addingTimeInterval(1)) {
                            LegadoJSCtx.$failures.withValue(failures) {
                                LegadoJS.run("java.put('started','yes'); while(true){try{throw Error('retry')}catch(e){}}", input: "",
                                             baseUrl: base, sourceKey: "", sourceUrl: source)
                            }
                        }
                        let began = LegadoJSCtx.$sourceUrl.withValue(source) { LegadoJS.variable("started") == "yes" }
                        do { try failures.check(); return "timeout worker \(worker) did not report a deadline" }
                        catch {
                            let message = sourceErrorMessage(error)
                            return began && output.isEmpty && message.contains("超时") ? "" : "timeout worker \(worker): started=\(began), \(message)"
                        }
                    }
                }
                var failures: [String] = []
                for await result in group where !result.isEmpty { failures.append(result) }
                return failures
            }
        }

        let startDeadline = Date().addingTimeInterval(8)
        func running(_ source: String) -> Bool {
            LegadoJSCtx.$sourceUrl.withValue(source) { LegadoJS.variable("started") == "yes" }
        }
        while !cancelSources.allSatisfy(running), Date() < startDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let allStarted = cancelSources.allSatisfy(running)
        cancellationTasks.forEach { $0.cancel() }
        var cancellationResults: [(String, String)] = []
        for task in cancellationTasks { cancellationResults.append(await task.value) }
        let workerFailures = await workers.value

        XCTAssertTrue(allStarted, "Both scripts must enter their VM before cancellation")
        XCTAssertTrue(workerFailures.isEmpty, workerFailures.joined(separator: "\n"))
        for (output, message) in cancellationResults {
            XCTAssertEqual(output, "")
            XCTAssertTrue(message.contains("取消"), "Expected cancellation, received: \(message)")
        }
        let recovery = await Task.detached {
            LegadoJS.run("1+1", input: "", baseUrl: base, sourceKey: "", sourceUrl: base)
        }.value
        XCTAssertEqual(recovery, "2", "A cancelled VM must not poison later evaluations")
        XCTAssertLessThan(Date().timeIntervalSince(started), 40, "Stress run must remain bounded")
    }
}
