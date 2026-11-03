import Foundation

func sourceScriptBody(_ value: String) -> String {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("@js:") { return String(value.dropFirst(4)) }
    if value.hasPrefix("<js>"), value.hasSuffix("</js>") { return String(value.dropFirst(4).dropLast(5)) }
    return value
}

func sourceJSONString(_ value: String) -> String {
    (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
}

extension LegadoSource {
    func checkedLoginResponse(_ response: SourcePage, stage: String) throws -> SourcePage {
        guard !loginCheckJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return response }
        let text = LegadoJS.run(sourceScriptBody(loginCheckJs), input: response.text, baseUrl: response.url,
                                sourceKey: LegadoJSCtx.key, sourceUrl: bookSourceUrl, book: LegadoJSCtx.book, response: response)
        try LegadoJSCtx.failures?.check()
        guard let data = text.data(using: .utf8), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = value["text"] as? String, let address = value["url"] as? String else {
            throw SourceFailure(stage: "登录检测", message: "脚本没有返回有效响应", url: response.url)
        }
        let status = value["status"] as? Int ?? 200
        guard (200..<300).contains(status) else { throw SourceFailure(stage: stage, message: "HTTP \(status)：登录检测后请求仍未成功", url: address) }
        let bytes = (value["bytesBase64"] as? String).flatMap { Data(base64Encoded: $0) }
        return SourcePage(text: body, url: address, status: status, headers: value["headers"] as? [String: String] ?? [:], bytes: bytes)
    }

    func chapterWebPage(_ response: SourcePage) async throws -> SourcePage {
        guard let script = ruleContent.androidValue("webJs"), !script.isEmpty else { return response }
        let request = try SourceHTTP.request(response.url, base: bookSourceUrl, headers: requestHeaders)
        return try await SourceWebLoader.load(request, html: response.text, script: sourceScriptBody(script))
    }
}

func sourceRuleBoolean(_ value: String) -> Bool {
    ["true", "1"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
}

extension LegadoSource {
    func preparedDirectoryBook(_ input: SourceBook) throws -> SourceBook {
        guard let script = ruleToc.androidValue("preUpdateJs"), !script.isEmpty else { return input }
        let wrapped = "eval(" + sourceJSONString(sourceScriptBody(script)) + "); JSON.stringify({bookUrl:book.bookUrl,tocUrl:book.tocUrl})"
        let output = LegadoJS.run(wrapped, input: "", baseUrl: input.url, sourceKey: input.title,
                                  sourceUrl: bookSourceUrl, book: LegadoJSCtx.book)
        try LegadoJSCtx.failures?.check()
        guard let data = output.data(using: .utf8), let fields = try JSONSerialization.jsonObject(with: data) as? [String: String] else { return input }
        var book = input
        if let address = fields["bookUrl"], isSourceURL(address) { book.url = address }
        if let address = fields["tocUrl"], !address.isEmpty { book.tocUrl = resolveUrl(address, base: book.url) }
        return book
    }

    func formattedChapterTitles(_ chapters: [BookChapter], book: SourceBook) throws -> [BookChapter] {
        guard let script = ruleToc.androidValue("formatJs"), !script.isEmpty else { return chapters }
        let values: [[String: Any]] = chapters.enumerated().map { index, chapter in
            ["title": chapter.title, "url": chapter.url ?? "", "index": index,
             "isVolume": chapter.isVolume, "isVip": chapter.isVip, "isPay": chapter.isPay]
        }
        // One JS context for the whole TOC preserves the reference's gInt
        // counter across chapters. Global index is one-based, chapter.index zero-based.
        let wrapper = "var _rows=result; var gInt=0; _rows.forEach(function(chapter,offset){var index=offset+1,title=chapter.title;var value=eval(" + sourceJSONString(sourceScriptBody(script)) + ");if(value!=null)chapter.title=String(value);});_rows"
        let output = LegadoJS.run(wrapper, input: "", baseUrl: book.tocUrl ?? book.url, sourceKey: book.title,
                                  sourceUrl: bookSourceUrl, book: LegadoJSCtx.book, structuredResult: values)
        try LegadoJSCtx.failures?.check()
        guard let data = output.data(using: .utf8), let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], values.count == chapters.count else {
            throw SourceFailure(stage: "目录格式化", message: "formatJs 没有返回完整章节标题")
        }
        return chapters.enumerated().map { index, original in
            var chapter = original
            if let title = values[index]["title"] as? String, !title.isEmpty { chapter.title = title }
            return chapter
        }
    }
}

extension Array where Element == BookChapter {
    func readableIndex(from proposed: Int, direction: Int = 1) -> Int? {
        guard indices.contains(proposed) else { return nil }
        var index = proposed
        while indices.contains(index) {
            if !self[index].isVolume { return index }
            index += direction < 0 ? -1 : 1
        }
        return nil
    }
}
