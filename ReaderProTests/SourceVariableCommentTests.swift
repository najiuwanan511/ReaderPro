import Foundation
import XCTest
@testable import ReaderPro

final class SourceVariableCommentTests: XCTestCase {
    func testImportExportAndDecryptVariableComment() async throws {
        // Synthetic fixture encrypted with the same AES mode and key as the
        // 1329 comic library; it defines a harmless local user_Check function.
        let encrypted = "ZOCaSfdn66zA1wsKUJ8KFDFU/q4oNGPNWiyeKwJEb55AND6rtdpfuvwGALXzt2Lw"
        let json = try JSONSerialization.data(withJSONObject: [[
            "bookSourceName": "variable fixture", "bookSourceUrl": "https://variable-fixture.invalid",
            "variableComment": encrypted
        ]])
        let source = try XCTUnwrap(importSourcesDetailed(String(decoding: json, as: UTF8.self)).sources.first)
        XCTAssertEqual(source.variableComment, encrypted)
        let exported = try JSONEncoder().encode(source)
        let restored = try JSONDecoder().decode(LegadoSource.self, from: exported)
        XCTAssertEqual(restored.variableComment, encrypted)

        let result = try await restored.withRules {
            LegadoJS.run(#"""
            eval(String(java.createSymmetricCrypto('AES/ECB/PKCS7Padding', '####xiao-han&&&&', '').decryptStr(source.variableComment)));
            user_Check();
            """#, input: "", baseUrl: restored.bookSourceUrl, sourceKey: "", sourceUrl: restored.bookSourceUrl)
        }
        XCTAssertEqual(result, "fixture-ok")

        var absent = restored
        absent.variableComment = nil
        let nullResult = try await absent.withRules {
            LegadoJS.run("source.variableComment === null ? 'null' : 'wrong'", input: "",
                         baseUrl: absent.bookSourceUrl, sourceKey: "", sourceUrl: absent.bookSourceUrl)
        }
        XCTAssertEqual(nullResult, "null")
    }
}
