import Foundation
import XCTest
@testable import ReaderPro

final class JSImportAndResponseTests: XCTestCase {
    func testRemoteImportReturnsEvaluableSourceAndReportsHTTPFailure() async {
        let result = await Task.detached { () -> (String, String) in
            let failures = RuleFailures()
            let result = LegadoJSCtx.$failures.withValue(failures) {
                LegadoJS.run(#"""
                var content = java.importScript(baseUrl+'/bridge-library');
                eval(String(content));
                var bad = false;
                try { java.importScript(baseUrl+'/denied'); } catch(e) { bad=String(e).indexOf('403')>=0; }
                var empty = false;
                try { java.importScript(baseUrl+'/empty'); } catch(e) { empty=String(e).indexOf('空')>=0; }
                remoteCategory()==='远程分类' && bad && empty ? 'ok' : 'failed';
                """#, input: "", baseUrl: "http://127.0.0.1:8765", sourceKey: "", sourceUrl: "http://127.0.0.1:8765")
            }
            do { try failures.check(); return (result, "") } catch { return (result, sourceErrorMessage(error)) }
        }.value
        XCTAssertEqual(result.1, "")
        XCTAssertEqual(result.0, "ok")
    }

    func testLocalImportUsesAppDocumentsAndRejectsEscape() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let name = "import-\(UUID().uuidString).js"
        let file = documents.appendingPathComponent(name)
        try Data("function localFixture(){return 42;}".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try SourceJSBridge.importScript(name, base: "https://example.invalid", headers: [:]),
                       "function localFixture(){return 42;}")
        XCTAssertThrowsError(try SourceJSBridge.importScript("/outside-app.js", base: "https://example.invalid", headers: [:]))
    }

    func testAuthenticatedImportsDoNotReuseCachedScript() async throws {
        let values = try await Task.detached { () throws -> (String, String) in
            let url = "http://127.0.0.1:8765/bridge-cookie"
            let first = try SourceJSBridge.importScript(url, base: url, headers: ["Cookie": "fixture=first"], source: "source-one")
            let second = try SourceJSBridge.importScript(url, base: url, headers: ["Cookie": "fixture=second"], source: "source-one")
            return (first, second)
        }.value
        XCTAssertTrue(values.0.contains("fixture=first"), values.0)
        XCTAssertTrue(values.1.contains("fixture=second"), values.1)
    }

    func testJsoupParserUnescapesEntities() {
        let failures = RuleFailures()
        let result = LegadoJSCtx.$failures.withValue(failures) {
            LegadoJS.run(#"Packages.org.jsoup.parser.Parser.unescapeEntities('A&amp;B&#x4e2d;&quot;',true)"#,
                         input: "", baseUrl: "https://example.invalid", sourceKey: "", sourceUrl: "https://example.invalid")
        }
        XCTAssertNoThrow(try failures.check())
        XCTAssertEqual(result, "A&B中\"")
    }

    func testRawResponseHeadersUsesCaseInsensitiveList() async {
        let result = await Task.detached { () -> (String, String) in
            let failures = RuleFailures()
            let result = LegadoJSCtx.$failures.withValue(failures) {
                LegadoJS.run(#"""
                var r=java.connect(baseUrl+'/bridge-special');
                var expected='quote'+String.fromCharCode(34)+'backslash'+String.fromCharCode(92)+'end';
                var headers=r.raw().headers('x-bridge-fixture');
                headers.length===1 && headers[0]===expected && headers.get(0)===expected &&
                    r.raw().headers('missing').length===0 && r.raw().request().url()===r.url() ? 'ok' : 'failed';
                """#, input: "", baseUrl: "http://127.0.0.1:8765", sourceKey: "", sourceUrl: "http://127.0.0.1:8765")
            }
            do { try failures.check(); return (result, "") } catch { return (result, sourceErrorMessage(error)) }
        }.value
        XCTAssertEqual(result.1, "")
        XCTAssertEqual(result.0, "ok")
    }
}
