import SwiftUI

struct SourceLogEntry: Identifiable { let id = UUID(); let date = Date(); let source: String; let message: String }
final class SourceExecutionLog: @unchecked Sendable {
    static let shared = SourceExecutionLog()
    private let lock = NSLock()
    private var items: [SourceLogEntry] = []
    func add(_ message: String, source: String) {
        lock.lock(); defer { lock.unlock() }
        items.append(SourceLogEntry(source: source, message: String(message.prefix(12000))))
        if items.count > 300 { items.removeFirst(items.count - 300) }
    }
    func entries(source: String?) -> [SourceLogEntry] { lock.lock(); defer { lock.unlock() }; return items.reversed().filter { source == nil || $0.source == source } }
    func clear(source: String?) { lock.lock(); defer { lock.unlock() }; items.removeAll { source == nil || $0.source == source } }
}

struct SourceLogView: View {
    var source: String? = nil
    @State private var entries: [SourceLogEntry] = []
    var body: some View {
        List(entries) { entry in
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.date.formatted() + " · " + entry.source).font(.caption).foregroundStyle(.secondary)
                Text(entry.message).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            }
        }.navigationTitle("书源日志")
        .onAppear { reload() }.refreshable { reload() }
        .toolbar { Button("清空") { SourceExecutionLog.shared.clear(source: source); reload() } }
    }
    private func reload() { entries = SourceExecutionLog.shared.entries(source: source) }
}

struct SourceActionResult {
    var value: String
    var browser: SourceLoginBrowser?
    var message: String
    var copyText: String?
}

extension LegadoSource {
    func performBookAction(script: String, book: SourceBook, chapter: BookChapter? = nil, event: String = "", input: String = "", longClick: Bool = false) async throws -> SourceActionResult {
        try await withTimeout(60) {
            try await self.withRules(key: book.title, book: book) {
                let login = SourceLoginContext(SourceLoginInfo.map(self.bookSourceUrl)); login.isLongClick = longClick
                return try LegadoJSCtx.$chapter.withValue(chapter) {
                    try LegadoJSCtx.$loginContext.withValue(login) {
                        let wrapped = "var event=" + sourceJSONString(event) + ";\n" + sourceScriptBody(script)
                        let output = LegadoJS.run(wrapped, input: input, baseUrl: chapter?.url ?? book.url,
                                                  sourceKey: book.title, sourceUrl: self.bookSourceUrl, book: LegadoJSCtx.book)
                        try LegadoJSCtx.failures?.check()
                        return SourceActionResult(value: output, browser: login.browser, message: login.message, copyText: login.copyText)
                    }
                }
            }
        }
    }
    func callBookEvent(_ event: String, book: LocalBook, chapter: BookChapter? = nil, input: String = "") async {
        guard eventListener, let script = ruleContent.androidValue("callBackJs"), !script.isEmpty else { return }
        do { _ = try await performBookAction(script: script, book: book.sourceBook, chapter: chapter, event: event, input: input) }
        catch { SourceExecutionLog.shared.add("事件 \(event)：" + sourceErrorMessage(error), source: bookSourceUrl) }
    }
}

struct SourceCustomActionView: View {
    let source: LegadoSource
    let book: SourceBook
    var chapter: BookChapter? = nil
    var payment = false
    var onPaymentSuccess: (() async throws -> Void)? = nil
    @State private var running = false
    @State private var message = ""
    @State private var browser: SourceLoginBrowser?
    @State private var confirmPayment = false
    @State private var revision = 0
    var body: some View {
        List {
            Text(payment ? "运行书源的章节购买操作，可能使用该站点账户余额。" : "运行该书源提供的自定义按钮事件。")
            if let chapter { Text(chapter.displayTitle) }
            if running { ProgressView("正在执行…") }
            if !message.isEmpty { Text(message).font(.footnote).textSelection(.enabled) }
            Button(payment ? "购买 / 解锁章节" : "执行自定义操作") { if payment { confirmPayment = true } else { execute() } }.disabled(running)
            NavigationLink("查看书源日志") { SourceLogView(source: source.bookSourceUrl) }
        }.navigationTitle(payment ? "章节购买" : "书源自定义按钮")
        .confirmationDialog("确认执行该书源的购买操作？", isPresented: $confirmPayment, titleVisibility: .visible) {
            Button("确认购买") { execute() }; Button("取消", role: .cancel) {}
        }
        .sheet(item: $browser) { target in NavigationStack { BrowserView(initialURL: target.url) } }
    }
    private func execute() {
        let script = source.ruleContent.androidValue(payment ? "payAction" : "callBackJs") ?? ""
        guard !script.isEmpty else { message = "书源未提供此操作规则"; return }
        running = true
        Task {
            do {
                let result = try await source.performBookAction(script: script, book: book, chapter: chapter, event: payment ? "" : "clickCustomButton")
                message = result.message.isEmpty ? result.value : result.message
                if let copy = result.copyText { UIPasteboard.general.string = copy; message = "已复制" }
                browser = result.browser
                if browser == nil && isSourceURL(result.value) { browser = SourceLoginBrowser(url: result.value) }
                if payment && sourceRuleBoolean(result.value) {
                    message = "购买成功，正在刷新目录和本章…"
                    if let onPaymentSuccess { try await onPaymentSuccess(); message = "购买成功，目录和本章已刷新" }
                    else { message = "书源返回购买成功" }
                }
            } catch { message = sourceErrorMessage(error); SourceExecutionLog.shared.add(message, source: source.bookSourceUrl) }
            running = false
        }
    }
}

extension BookStore {
    @MainActor func refreshPurchasedChapter(bookID: String, chapterURL: String?) async throws {
        guard let original = books.first(where: { $0.id == bookID }), let source = sourceForBook(original) else { throw CancellationError() }
        let worker = Task.detached { try await withTimeout(60) { try await source.fetchChapters(book: original.sourceBook) } }
        let chapters = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard !chapters.isEmpty else { throw SourceFailure(stage: "购买后刷新", message: "书源未返回目录，请重新加载") }
        guard let current = books.first(where: { $0.id == bookID }), current.sourceUrl == original.sourceUrl else { throw CancellationError() }
        chapterCache.cancel(bookID: bookID)
        var updated = current.refreshingDirectory(chapters)
        if let chapterURL, let index = updated.chapters.firstIndex(where: { $0.url == chapterURL }) {
            updated.chapters[index].text = "__URL__" + chapterURL
            updated.chapters[index].imageUrls = []
        }
        updateBook(updated)
    }
}
