import Foundation

// A chapter rule may hand its player page to java.startBrowser instead of
// returning a URL. Keep that handoff inside this episode's playback task.
final class SourceMediaCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var address: String?
    private var auxiliary = ""
    func set(_ value: String) { lock.lock(); address = value; lock.unlock() }
    func setAuxiliary(_ value: String) { lock.lock(); auxiliary = value; lock.unlock() }
    var subContent: String { lock.lock(); defer { lock.unlock() }; return auxiliary }
    var value: String? { lock.lock(); defer { lock.unlock() }; return address }
}

extension LegadoJSCtx {
    @TaskLocal static var mediaCapture: SourceMediaCapture?
}

enum SourceVideoResource {
    case native(URLRequest)
    case web(URLRequest)
    case html(String, URLRequest)

    static func isMediaURL(_ raw: String) -> Bool {
        let path = URLComponents(string: SourceHTTP.options(raw).url)?.path.lowercased() ?? ""
        return ["m3u8", "mp4", "m4v", "mov", "mpd", "webm"].contains((path as NSString).pathExtension)
    }

    static func make(_ raw: String, base: String, headers: [String: String], forceWeb: Bool = false) throws -> Self {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SourceFailure(stage: "视频解析", message: "章节规则未返回播放地址，请检查登录状态或播放线路", url: base) }
        if let file = URL(string: text), file.isFileURL {
            guard FileManager.default.isReadableFile(atPath: file.path) else {
                throw SourceFailure(stage: "本地视频", message: "视频文件不存在或无法读取，请重新导入", url: file.lastPathComponent)
            }
            return .native(URLRequest(url: file))
        }
        if text.hasPrefix("<") {
            if text.range(of: "<MPD", options: .caseInsensitive) != nil {
                throw SourceFailure(stage: "视频格式", message: "此线路返回 DASH/MPD，系统播放器不支持，请选择 m3u8 或 MP4 线路", url: base)
            }
            // Do not run text cleanup on media HTML or signed URLs.
            let addresses = cssExtractAll(text, "video@src") + cssExtractAll(text, "video source@src")
            if let address = addresses.first(where: { !$0.isEmpty }) {
                return try make(address, base: base, headers: headers)
            }
            let request = try SourceHTTP.request(base, base: base, headers: headers)
            return .html(text, request)
        }
        let transport = SourceHTTP.options(text).url
        guard transport.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              transport.contains("/") || transport.contains("?") else {
            throw SourceFailure(stage: "视频解析", message: "章节规则返回了提示文本，未返回播放地址", url: base)
        }
        let address = resolveUrl(text.replacingOccurrences(of: "&amp;", with: "&"), base: base)
        guard isSourceURL(address) else { throw SourceFailure(stage: "视频解析", message: "章节规则未返回有效视频地址", url: base) }
        var request = try SourceHTTP.request(address, base: base, headers: headers)
        if request.value(forHTTPHeaderField: "Referer") == nil { request.setValue(SourceHTTP.options(base).url, forHTTPHeaderField: "Referer") }
        if request.value(forHTTPHeaderField: "Cookie") == nil, let url = request.url {
            let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
            for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: key) }
        }
        let path = request.url?.path.lowercased() ?? ""
        if forceWeb || (!isMediaURL(address) && (["html", "htm", "php"].contains((path as NSString).pathExtension) || path.contains("/player") || path.contains("/embed"))) {
            return .web(request)
        }
        if path.hasSuffix(".mpd") {
            throw SourceFailure(stage: "视频格式", message: "此线路返回 DASH/MPD，系统播放器不支持，请选择 m3u8 或 MP4 线路", url: request.url?.absoluteString ?? "")
        }
        return .native(request)
    }
}

extension LegadoSource {
    func fetchChapterVideo(_ chapter: BookChapter) async throws -> SourceVideoResource {
        try await withChapterRules(chapter) {
            let capture = LegadoJSCtx.mediaCapture ?? SourceMediaCapture()
            return try await LegadoJSCtx.$mediaCapture.withValue(capture) {
                let initial = chapter.url ?? videoURLFromChapter(chapter.text)
                let headers = try SourceHTTP.request(initial, base: bookSourceUrl, headers: requestHeaders).allHTTPHeaderFields ?? requestHeaders
                if !chapter.text.hasPrefix("__URL__"), !chapter.text.isEmpty {
                    return try SourceVideoResource.make(chapter.text, base: initial, headers: headers)
                }
                guard !ruleContent.content.isEmpty else {
                    return try SourceVideoResource.make(initial, base: initial, headers: headers, forceWeb: !SourceVideoResource.isMediaURL(initial))
                }
                let response: SourcePage
                if SourceVideoResource.isMediaURL(initial) {
                    // Never download an entire stream just to evaluate a rule
                    // such as the pack's `result = baseUrl`.
                    response = SourcePage(text: "", url: SourceHTTP.options(initial).url)
                } else {
                    do { response = try await loadPage(initial, stage: "视频章节") }
                    catch let failure as SourceFailure {
                        guard failure.message.hasPrefix("HTTP "), SourceScript.loadsOwnContent(ruleContent.content) else { throw failure }
                        response = SourcePage(text: "", url: SourceHTTP.options(initial).url)
                    }
                }
                var input = response.text
                if let webJS = ruleContent.androidValue("webJs"), !webJS.isEmpty {
                    let request = try SourceHTTP.request(initial, base: bookSourceUrl, headers: requestHeaders)
                    input = try await SourceWebLoader.load(request, html: input, script: webJS).text
                }
                let optionalFailures = RuleFailures()
                if let auxiliary = try? await LegadoJSCtx.$failures.withValue(optionalFailures, operation: {
                    try await chapterAuxiliaryContent(input, base: response.url)
                }) { capture.setAuxiliary(auxiliary) }
                var result = applyContentRule(input, ruleContent.content, base: response.url).joined(separator: "\n")
                try LegadoJSCtx.failures?.check()
                if let target = capture.value, !target.isEmpty {
                    return try SourceVideoResource.make(target, base: response.url, headers: headers, forceWeb: !SourceVideoResource.isMediaURL(target))
                }
                if !ruleContent.replaceRegex.isEmpty { result = applyRuleReplace(result, replaceRegex: ruleContent.replaceRegex) }
                return try SourceVideoResource.make(result, base: response.url, headers: headers)
            }
        }
    }
}

struct SourceVideoDetails {
    let resource: SourceVideoResource
    let subContent: String
}
extension LegadoSource {
    func fetchChapterVideoDetails(_ chapter: BookChapter) async throws -> SourceVideoDetails {
        let capture = SourceMediaCapture()
        let resource = try await LegadoJSCtx.$mediaCapture.withValue(capture) { try await fetchChapterVideo(chapter) }
        return SourceVideoDetails(resource: resource, subContent: capture.subContent.isEmpty ? chapter.subContent : capture.subContent)
    }
}
extension SourceVideoResource {
    var request: URLRequest {
        switch self { case .native(let request), .web(let request), .html(_, let request): return request }
    }
}
