import SwiftUI

extension LegadoJSCtx {
    @TaskLocal static var speakText = ""
    @TaskLocal static var speakSpeed = 10
}

struct HttpTTS: ManagedReaderRule {
    var id = Int64(Date().timeIntervalSince1970 * 1000)
    var name = "在线朗读"
    var url = ""
    var contentType: String? = nil
    var concurrentRate = "0"
    var loginUrl = ""
    var loginUi = ""
    var header = ""
    var jsLib = ""
    var enabledCookieJar = false
    var loginCheckJs = ""
    var lastUpdateTime: Int64 = 0
    var enabled = true
    var active: Bool { get { enabled } set { enabled = newValue } }
    static var empty: Self { Self() }
    enum CodingKeys: String, CodingKey { case id, name, url, contentType, concurrentRate, loginUrl, loginUi, header, jsLib, enabledCookieJar, loginCheckJs, lastUpdateTime, enabled }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try? c.decode(Int64.self, forKey: .id) { self.id = id }
        name = c.tolerantString(.name); url = c.tolerantString(.url); contentType = try? c.decode(String.self, forKey: .contentType)
        concurrentRate = c.tolerantString(.concurrentRate); loginUrl = c.tolerantString(.loginUrl); loginUi = c.tolerantString(.loginUi)
        header = c.tolerantString(.header); jsLib = c.tolerantString(.jsLib); loginCheckJs = c.tolerantString(.loginCheckJs)
        enabledCookieJar = c.tolerantBool(.enabledCookieJar, defaultValue: false); enabled = c.tolerantBool(.enabled, defaultValue: true)
        lastUpdateTime = (try? c.decode(Int64.self, forKey: .lastUpdateTime)) ?? 0
    }
    var ruleSource: LegadoSource {
        var source = LegadoSource(); source.bookSourceName = name; source.bookSourceUrl = "httpTts:\(id)"
        source.header = header; source.jsLib = jsLib; source.concurrentRate = concurrentRate
        source.loginUrl = loginUrl; source.loginUi = loginUi; source.enabledCookieJar = enabledCookieJar; source.loginCheckJs = loginCheckJs
        return source
    }
    func validate() throws {
        guard !name.isEmpty, !url.isEmpty else { throw SourceFailure(stage: "在线朗读", message: "名称和 URL 规则不能为空") }
    }
    func audio(text: String, speed: Int) async throws -> Data {
        try await withTimeout(45) {
            try await ruleSource.withRules {
                try await LegadoJSCtx.$speakText.withValue(text) {
                    try await LegadoJSCtx.$speakSpeed.withValue(speed) {
                        let request = try SourceHTTP.request(url, base: SourceHTTP.options(url).url, headers: ruleSource.requestHeaders)
                        let (data, response) = try await SourceTLS.data(for: request)
                        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                            throw SourceFailure(stage: "在线朗读", message: "朗读接口未返回音频", url: request.url?.absoluteString ?? "")
                        }
                        if !loginCheckJs.isEmpty {
                            _ = try ruleSource.checkedLoginResponse(SourcePage(text: SourceHTTP.decode(data, response: response), url: response.url?.absoluteString ?? url, status: http.statusCode), stage: "在线朗读")
                        }
                        if let contentType, !contentType.isEmpty, !(http.mimeType ?? "").localizedCaseInsensitiveContains(contentType) {
                            throw SourceFailure(stage: "在线朗读", message: "返回的音频类型与规则配置不符：" + (http.mimeType ?? "未知"))
                        }
                        return data
                    }
                }
            }
        }
    }
}

struct SpeechEngineSettingsView: View {
    @ObservedObject private var library = ReaderRuleLibrary.shared
    @AppStorage("speech.engineID") private var engine = "system"
    @State private var sample = "这是在线朗读测试。"
    @StateObject private var speech = SpeechController()
    var body: some View {
        Form {
            Picker("朗读引擎", selection: $engine) {
                Text("系统朗读").tag("system")
                ForEach(library.httpTts.filter(\.enabled)) { Text($0.name).tag(String($0.id)) }
            }
            NavigationLink("管理 / 导入 HTTP TTS 引擎") { ReaderRuleLibraryView(title: "在线朗读引擎", rules: $library.httpTts) }
            if let selected = library.httpTts.first(where: { String($0.id) == engine }), selected.ruleSource.hasLogin {
                NavigationLink("引擎登录") { SourceLoginView(source: selected.ruleSource) }
            }
            Section("试听") {
                TextField("试听文字", text: $sample)
                Button(speech.isSpeaking ? "停止" : "试听") {
                    if speech.isSpeaking { speech.stop() } else { speech.speak(segments: [sample], rate: 0.5, pitch: 1) }
                }
                if !speech.error.isEmpty { Text(speech.error).font(.caption).foregroundStyle(.red) }
            }
        }.navigationTitle("朗读引擎").onDisappear { speech.stop() }
    }
}
