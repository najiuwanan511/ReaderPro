import XCTest
@testable import ReaderPro

final class LegadoJSONPathRuleTests: XCTestCase {
    func testRealSourceFiltersAndNestedArrayIndices() {
        let json = #"""
        {"data":{"state":[
          {"dataName":"other","items":[{"name":"错误结果"}]},
          {"dataName":"novel_search_list","items":[{"name":"第一本"},{"name":"第二本"}]}
        ]},"role":[["作者","张三"],["译者","李四"]],"enabled":true,"number":1}
        """#
        // Verbatim bookList from the 1325 「松鹤阅读」 source.
        let books = jsonObjects(json, "$.data.state[?(@.dataName == 'novel_search_list')].items[*]")
        XCTAssertEqual(books.map { jsonExtract($0, "$.name").first ?? "" }, ["第一本", "第二本"])
        // Verbatim author rule used by 「多看阅读」 in both user packs.
        XCTAssertEqual(jsonExtract(json, "$.role[0][1]"), ["张三"])
        XCTAssertEqual(jsonExtract(json, "$.role[-1][1]"), ["李四"])
        XCTAssertEqual(jsonExtract(json, "$.enabled"), ["true"])
        XCTAssertEqual(jsonExtract(json, "$.number"), ["1"])
    }

    func testRootArrayPredicatesAndRecursiveFilter() {
        // Verbatim predicate shape from 1325 「追书神器」.
        let sources = #"[{"source":"other","_id":"1"},{"source":"xbiquge","_id":"2"}]"#
        XCTAssertEqual(jsonExtract(sources, #"$.[?(@.source=='xbiquge')]._id"#), ["2"])
        XCTAssertEqual(jsonExtract(sources, #"$.[?(@.source!='xbiquge')]._id"#), ["1"])
        XCTAssertEqual(jsonExtract(#"{"groups":[{"novels":[{"novelName":"小说"},{"other":1}]}]}"#,
                                   "$..[?(@.novelName)].novelName"), ["小说"])
        XCTAssertEqual(jsonExtract(#"{"a.b":{"value":2}}"#, #"$['a.b'].value"#), ["2"])
    }
}
