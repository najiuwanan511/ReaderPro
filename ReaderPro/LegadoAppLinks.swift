import SwiftUI

// Android's OnLineImportActivity accepts both schemes and the older
// booksource/importonline, rsssource/importonline and replace/importonline URLs.
struct LegadoAppLink: Equatable {
    enum Kind: String {
        case automatic, bookSource, rssSource, replaceRule, textTocRule, httpTTS, dictRule, addToBookshelf
        var title: String {
            switch self {
            case .automatic: return "导入规则"
            case .bookSource: return "导入书源"
            case .rssSource: return "导入订阅源"
            case .replaceRule: return "导入替换规则"
            case .textTocRule: return "导入目录规则"
            case .httpTTS: return "导入在线朗读"
            case .dictRule: return "导入字典规则"
            case .addToBookshelf: return "添加书籍"
            }
        }
    }
    let kind: Kind
    let source: String

    static func accepts(_ url: URL) -> Bool { ["legado", "yuedu"].contains(url.scheme?.lowercased() ?? "") }
    static func parse(_ url: URL) throws -> Self {
        guard accepts(url), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let source = parts.queryItems?.first(where: { $0.name == "src" })?.value,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceFailure(stage: "一键导入", message: "导入链接缺少 src 参数")
        }
        let kind: Kind
        switch url.path.lowercased() {
        case "/booksource": kind = .bookSource
        case "/rsssource": kind = .rssSource
        case "/replacerule": kind = .replaceRule
        case "/texttocrule": kind = .textTocRule
        case "/httptts": kind = .httpTTS
        case "/dictrule": kind = .dictRule
        case "/addtobookshelf": kind = .addToBookshelf
        case "/theme", "/readconfig":
            // These Android archives need separate asset/configuration mapping;
            // never misreport an unsupported theme as a successful source import.
            throw SourceFailure(stage: "一键导入", message: "此链接是安卓主题或排版包，尚不能完整导入")
        case "/importonline":
            switch url.host?.lowercased() {
            case "booksource": kind = .bookSource
            case "rsssource": kind = .rssSource
            case "replace": kind = .replaceRule
            default: kind = .automatic
            }
        default: kind = .automatic
        }
        return Self(kind: kind, source: source)
    }
}

enum LegadoLinkDocument {
    case sources(SourcePackImportResult), replacements([ReplaceRule]), toc([TxtTocRule]), tts([HttpTTS]), dictionaries([DictRule])
    var names: [String] {
        switch self {
        case .sources(let value): return value.sources.map(\.bookSourceName) + value.rssSources.map(\.sourceName)
        case .replacements(let value): return value.map(\.name)
        case .toc(let value): return value.map(\.name)
        case .tts(let value): return value.map(\.name)
        case .dictionaries(let value): return value.map(\.name)
        }
    }
    static func rules<T: ManagedReaderRule>(_ type: T.Type, data: Data) throws -> [T] {
        let decoder = JSONDecoder()
        let values = data.first(where: { ![9, 10, 13, 32].contains($0) }) == 91
            ? try decoder.decode([T].self, from: data) : [try decoder.decode(T.self, from: data)]
        guard !values.isEmpty else { throw SourceFailure(stage: "一键导入", message: "规则文件为空") }
        for value in values { try value.validate() }
        return values
    }
    static func decode(_ data: Data, kind: LegadoAppLink.Kind) throws -> Self {
        var kind = kind
        if kind == .automatic {
            let object = try JSONSerialization.jsonObject(with: data)
            let first = (object as? [[String: Any]])?.first ?? object as? [String: Any] ?? [:]
            if first["pattern"] != nil { kind = .replaceRule }
            else if first["urlRule"] != nil { kind = .dictRule }
            else if first["rule"] != nil && first["name"] != nil { kind = .textTocRule }
            else if first["url"] != nil && first["name"] != nil { kind = .httpTTS }
        }
        switch kind {
        case .automatic, .bookSource, .rssSource:
            var value = importSourceDocument(decodeTextData(data))
            if kind == .bookSource { value.rssSources = [] }
            if kind == .rssSource { value.sources = [] }
            guard !value.isEmpty else { throw SourceFailure(stage: "一键导入", message: "文件没有包含对应类型的有效规则") }
            return .sources(value)
        case .replaceRule: return .replacements(try ReplacementRuleDocument.decode(data))
        case .textTocRule: return .toc(try rules(TxtTocRule.self, data: data))
        case .httpTTS: return .tts(try rules(HttpTTS.self, data: data))
        case .dictRule: return .dictionaries(try rules(DictRule.self, data: data))
        case .addToBookshelf: throw SourceFailure(stage: "添加书籍", message: "请通过书籍网址添加")
        }
    }
    static func load(_ link: LegadoAppLink) async throws -> Self {
        let raw = link.source.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSourceURL(raw) {
            let noUA = raw.hasSuffix("#requestWithoutUA")
            let address = noUA ? String(raw.dropLast("#requestWithoutUA".count)) : raw
            if [.automatic, .bookSource, .rssSource].contains(link.kind), !noUA {
                do {
                    let value = try await importSourcePacksFromURL(address)
                    var filtered = value
                    if link.kind == .bookSource { filtered.rssSources = [] }
                    if link.kind == .rssSource { filtered.sources = [] }
                    guard !filtered.isEmpty else { throw SourceFailure(stage: "一键导入", message: "文件没有包含对应类型的有效规则") }
                    return .sources(filtered)
                } catch {
                    try Task.checkCancellation()
                    if link.kind != .automatic { throw error }
                }
            }
            var request = try SourceHTTP.request(address, base: address)
            if noUA { request.setValue("", forHTTPHeaderField: "User-Agent") }
            let response = try await SourceHTTP.load(request, stage: "一键导入")
            return try decode(response.bytes ?? Data(response.text.utf8), kind: link.kind)
        }
        return try decode(Data(raw.utf8), kind: link.kind)
    }
    @MainActor func apply(store: BookStore, library: ReaderRuleLibrary = .shared) async throws -> String {
        func merge<T: ManagedReaderRule>(_ old: [T], _ incoming: [T]) -> [T] {
            var output = old
            for item in incoming {
                if let index = output.firstIndex(where: { $0.id == item.id }) { output[index] = item }
                else { output.append(item) }
            }
            return output
        }
        switch self {
        case .sources(let document):
            let result = store.mergeImportedSources(document, persist: false)
            try await store.saveAsync(); return result
        case .replacements(let rules): _ = try store.importReplaceRules(ReplacementRuleDocument.encode(rules))
        case .toc(let rules): library.txtRules = merge(library.txtRules, rules)
        case .tts(let rules): library.httpTts = merge(library.httpTts, rules)
        case .dictionaries(let rules): library.dictionaries = merge(library.dictionaries, rules)
        }
        return "已导入 \(names.count) 条规则"
    }
}

extension Notification.Name { static let sourceOpenAppURL = Notification.Name("ReaderPro.sourceOpenAppURL") }

enum SourceAppURL {
    // Only Swift strings cross from the rule worker; UI and app launching stay
    // on the main actor. startBrowser continues to use the source WebView.
    static func open(_ address: String, base: String) {
        let resolved = resolveUrl(address, base: base)
        Task { @MainActor in NotificationCenter.default.post(name: .sourceOpenAppURL, object: resolved) }
    }
    @MainActor static func present(_ url: URL, store: BookStore, external: Bool = false) {
        guard var controller = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = controller.presentedViewController { controller = presented }
        do {
            if LegadoAppLink.accepts(url) {
                let link = try LegadoAppLink.parse(url)
                controller.present(UIHostingController(rootView: LegadoLinkImportView(store: store, link: link)), animated: true)
            } else if external {
                let dialog = UIAlertController(title: "打开外部链接", message: url.absoluteString, preferredStyle: .alert)
                dialog.addAction(UIAlertAction(title: "取消", style: .cancel))
                dialog.addAction(UIAlertAction(title: "打开", style: .default) { _ in
                    UIApplication.shared.open(url, options: [:]) { success in
                        if !success { Task { @MainActor in SourceScriptToast.show("没有可打开此链接的应用", tag: "", long: true) } }
                    }
                })
                controller.present(dialog, animated: true)
            }
        } catch { SourceScriptToast.show(sourceErrorMessage(error), tag: "", long: true) }
    }
}

struct SourceAppLinkReceiver: ViewModifier {
    let store: BookStore
    func body(content: Content) -> some View {
        content.onOpenURL { SourceAppURL.present($0, store: store) }
            .onReceive(NotificationCenter.default.publisher(for: .sourceOpenAppURL)) { notification in
                if let value = notification.object as? String, let url = URL(string: value) {
                    SourceAppURL.present(url, store: store, external: true)
                }
            }
    }
}

struct LegadoLinkImportView: View {
    @ObservedObject var store: BookStore
    let link: LegadoAppLink
    @Environment(\.dismiss) private var dismiss
    @State private var document: LegadoLinkDocument?
    @State private var loading = true
    @State private var saving = false
    @State private var message = ""
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Group {
                if link.kind == .addToBookshelf { ShelfTransferView(store: store, initialText: link.source) }
                else {
                    List {
                        if loading { ProgressView("正在读取规则…") }
                        if !error.isEmpty { Text(error).foregroundStyle(.red) }
                        if !message.isEmpty { Text(message).accessibilityIdentifier("appLinkImportResult") }
                        if let document {
                            Section("共 \(document.names.count) 条") {
                                ForEach(Array(document.names.enumerated()), id: \.offset) { Text($0.element) }
                            }
                            if message.isEmpty {
                                Button(saving ? "正在保存…" : "确认导入") {
                                    saving = true
                                    Task { @MainActor in
                                        defer { saving = false }
                                        do { message = try await document.apply(store: store) }
                                        catch { self.error = sourceErrorMessage(error) }
                                    }
                                }.disabled(saving).accessibilityIdentifier("appLinkConfirmImport")
                            }
                        }
                    }
                }
            }.navigationTitle(link.kind.title)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() }.disabled(saving) } }
        }.interactiveDismissDisabled(saving)
        .task {
            guard link.kind != .addToBookshelf else { loading = false; return }
            let worker = Task.detached { try await withTimeout(90) { try await LegadoLinkDocument.load(link) } }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); document = value
            } catch { if !Task.isCancelled { self.error = sourceErrorMessage(error) } }
            loading = false
        }
    }
}
