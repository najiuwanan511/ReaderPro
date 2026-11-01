import XCTest
@testable import ReaderPro

// The original audit exercised many unrelated websites concurrently. This
// bounded, offline regression isolates JavaScriptCore, including nested
// contexts and watchdog cleanup, so a failure has a much smaller scope.
final class JSConcurrencyStressTests: XCTestCase {
    func testConcurrentRepeatedAjaxAndListBridges() async throws {
        executionTimeAllowance = 120
        let base = "http://127.0.0.1:8765"
        let script = #"""
        var expected='中文😀'+String.fromCharCode(34,92,10,13,9,0)+'end';
        var header='quote'+String.fromCharCode(34)+'backslash'+String.fromCharCode(92)+'end';
        for(var i=0;i<12;i++) {
            var r=java.connect(baseUrl+'/bridge-special');
            if(r.body()!==expected || r.code()!==200 || r.statusCode()!==200) throw Error('response body or status '+i);
            if(r.header('X-Bridge-Fixture')!==header || r.headers('X-Bridge-Fixture').get(0)!==header) throw Error('response header '+i);
            if(!r.url().endsWith('/bridge-special') || r.raw().request().url()!==r.url()) throw Error('response URL '+i);
            if(java.ajax(baseUrl+'/bridge-special')!==expected) throw Error('ajax '+i);
            var denied=java.get(baseUrl+'/denied',{});
            if(denied.code()!==403 || denied.body()!=='login required') throw Error('HTTP status '+i);
            var threw=false; try { java.ajax('data:broken'); } catch(e) { threw=String(e).indexOf('data')>=0; }
            if(!threw) throw Error('request error '+i);
            var nodes=org.jsoup.Jsoup.parse('<div><p><a>中文😀 " \\</a></p><p><a>二</a></p></div>').select('p');
            if(nodes.select('a').size()!==2 || nodes.select('missing').size()!==0) throw Error('multi-parent selection '+i);
            if(nodes.select('a').get(0).text().indexOf('中文😀')<0) throw Error('unicode selection '+i);
            var strings=java.getStringList('$.items[*]', '["unused"]');
            var list=java.getStringList('$.items[*]', '{"items":["甲😀","quote\\\"slash\\\\","line\\nnext"]}');
            if(strings.size()!==0 || list.size()!==3 || list.get(0)!=='甲😀' ||
               list.get(1)!=='quote'+String.fromCharCode(34)+'slash'+String.fromCharCode(92) ||
               list.get(2)!=='line\nnext') throw Error('string list '+i);
            if(java.getString('@js:result.toUpperCase()', 'nested')!=='NESTED') throw Error('nested JS '+i);
        }
        'ok';
        """#
        let failures = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for worker in 0..<8 {
                group.addTask {
                    let errors = RuleFailures()
                    let result = LegadoJSCtx.$failures.withValue(errors) {
                        LegadoJS.run(script, input: "", baseUrl: base, sourceKey: "", sourceUrl: base + "/bridge-\(worker)")
                    }
                    do { try errors.check() } catch { return "worker \(worker): \(sourceErrorMessage(error))" }
                    return result == "ok" ? "" : "worker \(worker): \(result)"
                }
            }
            var errors: [String] = []
            for await error in group where !error.isEmpty { errors.append(error) }
            return errors
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testAjaxTimeoutCancellationAndRecovery() async throws {
        executionTimeAllowance = 30
        let base = "http://127.0.0.1:8765"
        let timeoutResult = await Task.detached {
            let errors = RuleFailures()
            let result = LegadoJSCtx.$failures.withValue(errors) {
                LegadoJS.run("var timedOut=false;try{java.ajax(baseUrl+'/slow-search',100)}catch(e){timedOut=true}; timedOut && java.ajax(baseUrl+'/health')==='ready' ? 'ok' : 'failed'",
                             input: "", baseUrl: base, sourceKey: "", sourceUrl: base)
            }
            do { try errors.check(); return result } catch { return sourceErrorMessage(error) }
        }.value
        XCTAssertEqual(timeoutResult, "ok")

        let source = base + "/ajax-cancel/" + UUID().uuidString
        let task = Task.detached { () -> (String, String) in
            let errors = RuleFailures()
            let output = LegadoJSCtx.$failures.withValue(errors) {
                LegadoJS.run("java.put('started','yes');java.ajax(baseUrl+'/slow-search',10000)",
                             input: "", baseUrl: base, sourceKey: "", sourceUrl: source)
            }
            do { try errors.check(); return (output, "") } catch { return (output, sourceErrorMessage(error)) }
        }
        let deadline = Date().addingTimeInterval(5)
        func started() -> Bool { LegadoJSCtx.$sourceUrl.withValue(source) { LegadoJS.variable("started") == "yes" } }
        while !started(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(started(), "Network script must start before cancellation")
        task.cancel()
        let (output, error) = await task.value
        XCTAssertTrue(output.isEmpty)
        XCTAssertTrue(error.contains("取消"), error)
    }

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
