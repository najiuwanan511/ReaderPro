import Foundation

struct SourceAudioResource {
    let request: URLRequest
    var lyrics = ""
}

extension LegadoSource {
    func chapterAuxiliaryContent(_ input: String, base: String) async throws -> String {
        guard let rule = ruleContent.androidValue("subContent"), !rule.isEmpty else { return "" }
        let value = applyContentRule(input, rule, base: base).joined(separator: "\n")
        try LegadoJSCtx.failures?.check()
        if isSourceURL(value) { return try await loadPage(value, base: base, stage: "章节副内容").text }
        return value
    }

    func fetchChapterAudio(_ chapter: BookChapter) async throws -> SourceAudioResource {
        try await withChapterRules(chapter) {
            let initial = chapter.url ?? videoURLFromChapter(chapter.text)
            let ext = URL(string: SourceHTTP.options(initial).url)?.pathExtension.lowercased() ?? ""
            let direct = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "m3u8"].contains(ext)
            let response: SourcePage
            if direct || ruleContent.content.isEmpty { response = SourcePage(text: "", url: initial) }
            else {
                let loaded = try await loadPage(initial, stage: "音频章节")
                response = try await chapterWebPage(loaded)
            }
            var value = ruleContent.content.isEmpty ? initial : applyContentRule(response.text, ruleContent.content, base: response.url).joined(separator: "\n")
            try LegadoJSCtx.failures?.check()
            if !ruleContent.replaceRegex.isEmpty { value = applyRuleReplace(value, replaceRegex: ruleContent.replaceRegex) }
            if value.contains("<audio") {
                value = (cssExtractAll(value, "audio@src") + cssExtractAll(value, "audio source@src")).first ?? ""
            }
            let resource = try SourceVideoResource.make(value, base: response.url, headers: requestHeaders)
            guard case .native(let request) = resource else {
                throw SourceFailure(stage: "音频解析", message: "音频规则需要返回音频地址，当前返回了网页", url: response.url)
            }
            let auxiliaryFailures = RuleFailures()
            // Lyrics are optional; a broken lyric endpoint must not prevent
            // the actual audio from playing, matching Android BookContent.
            let lyrics = try? await LegadoJSCtx.$failures.withValue(auxiliaryFailures) {
                try await chapterAuxiliaryContent(response.text, base: response.url)
            }
            return SourceAudioResource(request: request, lyrics: lyrics ?? chapter.subContent)
        }
    }
}
