import Foundation
import XCTest
@testable import ReaderPro

final class SourceRuleObjectTests: XCTestCase {
    func testRuleRoundTripRetainsAndroidFieldsNullsAndEdits() throws {
        let input: [String: Any] = [
            "bookSourceName": "rule fixture", "bookSourceUrl": "https://rules.invalid",
            "ruleSearch": ["bookList": "<js>s</js>", "name": "", "author": NSNull(), "updateTime": "today"],
            "ruleExplore": ["bookList": "<js>e</js>"],
            "ruleToc": ["chapterList": "<js>t</js>", "formatJs": NSNull(), "isVip": "vip-rule"],
            "ruleContent": ["content": "<js>c</js>", "webJs": "window.fixture=1", "sourceRegex": ""]
        ]
        let raw = try JSONSerialization.data(withJSONObject: [input])
        var source = try XCTUnwrap(importSourcesDetailed(String(decoding: raw, as: UTF8.self)).sources.first)
        source.ruleSearch.bookList = "<js>updated</js>"
        source.ruleSearch.name = "edited"
        let encoded = try JSONEncoder().encode(source)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let search = try XCTUnwrap(object["ruleSearch"] as? [String: Any])
        let toc = try XCTUnwrap(object["ruleToc"] as? [String: Any])
        let content = try XCTUnwrap(object["ruleContent"] as? [String: Any])
        XCTAssertEqual(search["bookList"] as? String, "<js>updated</js>")
        XCTAssertEqual(search["name"] as? String, "edited")
        XCTAssertTrue(search["author"] is NSNull)
        XCTAssertNil(search["wordCount"])
        XCTAssertEqual(search["updateTime"] as? String, "today")
        XCTAssertTrue(toc["formatJs"] is NSNull)
        XCTAssertEqual(toc["isVip"] as? String, "vip-rule")
        XCTAssertEqual(content["webJs"] as? String, "window.fixture=1")
        XCTAssertEqual(content["sourceRegex"] as? String, "")
        let restored = try JSONDecoder().decode(LegadoSource.self, from: encoded)
        XCTAssertEqual(restored, source)
        XCTAssertEqual(restored.ruleSearch.androidValue("wordCount"), nil)
        XCTAssertEqual(restored.ruleToc.androidValue("isVip"), "vip-rule")
    }

    func testKotlinDescriptionsAndComicRuleExtraction() async throws {
        let input: [String: Any] = [
            "bookSourceName": "rule fixture", "bookSourceUrl": "https://rules.invalid", "variableComment": "payload",
            "ruleSearch": ["bookList": "<js>s</js>", "name": "", "author": NSNull(), "updateTime": "today"],
            "ruleExplore": ["bookList": "<js>e</js>"],
            "ruleToc": ["chapterList": "<js>t</js>", "isVip": "vip-rule"],
            "ruleContent": ["content": "<js>c</js>", "webJs": "window.fixture=1"]
        ]
        let raw = try JSONSerialization.data(withJSONObject: [input])
        let source = try XCTUnwrap(importSourcesDetailed(String(decoding: raw, as: UTF8.self)).sources.first)
        let descriptions = try await source.withRules {
            LegadoJS.run("[source.ruleSearch, source.ruleExplore, source.ruleToc, source.ruleContent].map(String).join('\\n')",
                         input: "", baseUrl: source.bookSourceUrl, sourceKey: "", sourceUrl: source.bookSourceUrl)
        }
        XCTAssertEqual(descriptions, [
            "SearchRule(checkKeyWord=null, bookList=<js>s</js>, name=, author=null, intro=null, kind=null, lastChapter=null, updateTime=today, bookUrl=null, coverUrl=null, wordCount=null)",
            "ExploreRule(bookList=<js>e</js>, name=null, author=null, intro=null, kind=null, lastChapter=null, updateTime=null, bookUrl=null, coverUrl=null, wordCount=null)",
            "TocRule(preUpdateJs=null, chapterList=<js>t</js>, chapterName=null, chapterUrl=null, formatJs=null, isVolume=null, isVip=vip-rule, isPay=null, updateTime=null, nextTocUrl=null)",
            "ContentRule(content=<js>c</js>, subContent=null, title=null, nextContentUrl=null, webJs=window.fixture=1, sourceRegex=null, replaceRegex=null, imageStyle=null, imageDecode=null, payAction=null, callBackJs=null)"
        ].joined(separator: "\n"))
        let properties = try await source.withRules {
            LegadoJS.run("source.ruleSearch.name === '' && source.ruleSearch.author === null && source.ruleToc.isVip === 'vip-rule' && source.ruleContent.webJs === 'window.fixture=1' ? 'ok' : 'failed'",
                         input: "", baseUrl: source.bookSourceUrl, sourceKey: "", sourceUrl: source.bookSourceUrl)
        }
        XCTAssertEqual(properties, "ok")
        let extracted = try await source.withRules {
            LegadoJS.run(#"""
            [source.ruleSearch,source.ruleExplore,source.ruleToc].map(function(rule){
                return String(rule).replace(/[\s\S]*List=(<js>[\s\S]+?<\/js>)[\s\S]*/, '$1');
            }).join('|')+'|'+String(source.ruleContent).replace(/[\s\S]*content=(<js>[\s\S]+?<\/js>)[\s\S]*/, '$1')+'|'+source.variableComment;
            """#, input: "", baseUrl: source.bookSourceUrl, sourceKey: "", sourceUrl: source.bookSourceUrl)
        }
        XCTAssertEqual(extracted, "<js>s</js>|<js>e</js>|<js>t</js>|<js>c</js>|payload")
    }

    func testMissingAndNullRuleObjectsStayNull() async throws {
        let raw = #"[{"bookSourceName":"null fixture","bookSourceUrl":"https://null-rule.invalid","ruleSearch":null,"ruleExplore":{}}]"#
        var source = try XCTUnwrap(importSourcesDetailed(raw).sources.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        XCTAssertTrue(object["ruleSearch"] is NSNull)
        XCTAssertNil(object["ruleToc"])
        let result = try await source.withRules {
            LegadoJS.run("source.ruleSearch === null && source.ruleToc === null && source.ruleExplore !== null ? 'ok' : 'failed'",
                         input: "", baseUrl: source.bookSourceUrl, sourceKey: "", sourceUrl: source.bookSourceUrl)
        }
        XCTAssertEqual(result, "ok")
        source.ruleSearch.bookList = "class.item"
        let changed = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        XCTAssertEqual((changed["ruleSearch"] as? [String: Any])?["bookList"] as? String, "class.item")
        let restored = try JSONDecoder().decode(LegadoSource.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(restored, source)
    }

    func testOlderStoredEmptyValuesRemainEmpty() throws {
        let old = #"[{"bookSourceName":"old","bookSourceUrl":"https://old-rule.invalid","ruleSearch":{"bookList":"","name":"","author":""}}]"#
        let source = try XCTUnwrap(importSourcesDetailed(old).sources.first)
        XCTAssertEqual(source.ruleSearch.androidValue("bookList"), "")
        XCTAssertEqual(source.ruleSearch.androidValue("name"), "")
        XCTAssertNil(source.ruleSearch.androidValue("wordCount"))
        let restored = try JSONDecoder().decode(LegadoSource.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(restored, source)
        XCTAssertEqual(restored.ruleSearch.androidValue("name"), "")
    }
}
