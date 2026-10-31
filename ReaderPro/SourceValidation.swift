import Foundation
import CryptoKit
import Combine

final class RuleFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func add(_ message: String) { lock.lock(); defer { lock.unlock() }; messages.append(message) }
    func check() throws {
        lock.lock(); let message = messages.first; lock.unlock()
        if let message { throw SourceFailure(stage: "脚本兼容性", message: message) }
    }
}

enum SourceValidationStatus: String, Codable, CaseIterable {
    case passed, failed, partial
    var title: String {
        switch self { case .passed: return "成功"; case .failed: return "失败"; case .partial: return "未完整验证" }
    }
}

struct SourceValidationStep: Codable, Equatable {
    var stage: String
    var passed: Bool
    var detail: String
}

struct SourceValidationReport: Codable, Identifiable, Equatable {
    var id: String
    var fingerprint: String
    var checkedAt: Date
    var keyword: String
    var status: SourceValidationStatus
    var steps: [SourceValidationStep]
    var summary: String { steps.first(where: { !$0.passed })?.detail ?? steps.last?.detail ?? "未完成" }
    var searchableText: String { ([status.title, keyword] + steps.map { $0.stage + " " + $0.detail }).joined(separator: " ") }
}

enum SourceValidation {
    // UI-only enable/group changes do not invalidate the parsing result.
    static func fingerprint(_ source: LegadoSource) -> String {
        var source = source
        source.id = ""; source.enabled = true; source.bookSourceGroup = ""
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: (try? encoder.encode(source)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    static func run(_ source: LegadoSource, keyword: String) async -> SourceValidationReport {
        let key = source.ruleSearch.checkKeyWord.isEmpty ? keyword : source.ruleSearch.checkKeyWord
        var report = SourceValidationReport(id: source.id, fingerprint: fingerprint(source), checkedAt: Date(),
                                            keyword: key, status: .partial, steps: [])
        func ok(_ stage: String, _ detail: String) { report.steps.append(.init(stage: stage, passed: true, detail: detail)) }
        func fail(_ stage: String, _ error: Error) { report.steps.append(.init(stage: stage, passed: false, detail: sourceErrorMessage(error))) }
        var samples: [SourceBook] = []
        var failed = false
        var incomplete = false
        if source.searchUrl.isEmpty && source.effectiveDiscoverUrl.isEmpty {
            report.status = .failed
            fail("规则配置", SourceFailure(stage: "规则配置", message: "既没有搜索地址，也没有发现入口"))
            return report
        }
        if !source.searchUrl.isEmpty {
            do {
                let books = try await withTimeout(35) { try await source.search(key: key) }
                if books.isEmpty {
                    incomplete = true
                    report.steps.append(.init(stage: "搜索", passed: false, detail: "关键词「\(key)」未匹配书籍，无法据此认定书源永久失效"))
                } else { samples += books; ok("搜索", "「\(key)」返回 \(books.count) 本书") }
            } catch { failed = true; fail("搜索", error) }
        }
        if !Task.isCancelled && !source.effectiveDiscoverUrl.isEmpty {
            do {
                let books = try await withTimeout(35) { try await source.discover() }
                samples += books; ok("发现", "首个分类返回 \(books.count) 本书")
            } catch { failed = true; fail("发现", error) }
        }
        if !Task.isCancelled, let sample = samples.first {
            var stage = "详情"
            do {
                let book = try await withTimeout(30) { try await source.fetchBookInfo(book: sample) }
                ok(stage, book.title)
                stage = "目录"
                let chapters = try await withTimeout(90) { try await source.fetchChapters(book: book) }
                guard let first = chapters.first else { throw SourceFailure(stage: stage, message: "目录为空") }
                ok(stage, "\(chapters.count) 章（遍历目录分页）")
                stage = "正文"
                if source.isComic {
                    let images = try await withTimeout(45) { try await source.fetchChapterImages(first) }
                    guard let address = images.first else { throw SourceFailure(stage: stage, message: "图片列表为空") }
                    let request = try SourceHTTP.request(address, base: first.url ?? book.url, headers: source.requestHeaders)
                    let (_, response) = try await (SourceHTTP.testSession ?? SourceHTTP.session).data(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          http.mimeType?.hasPrefix("image/") == true else {
                        throw SourceFailure(stage: stage, message: "首张图片未返回可用图片响应", url: address)
                    }
                    ok(stage, "首章 \(images.count) 张图片，首张响应正常")
                } else {
                    let text = try await withTimeout(45) { try await source.fetchChapterContent(first) }
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceFailure(stage: stage, message: "首章正文为空") }
                    ok(stage, "首章「\(first.title)」读取 \(text.count) 字")
                }
            } catch { failed = true; fail(stage, error) }
        } else {
            incomplete = true
            report.steps.append(.init(stage: "阅读链路", passed: false, detail: Task.isCancelled ? "已取消，未完成验证" : "没有样本书，详情、目录和正文未验证"))
        }
        report.status = failed ? .failed : (incomplete ? .partial : .passed)
        return report
    }
}

@MainActor final class SourceValidationStore: ObservableObject {
    @Published private(set) var reports: [String: SourceValidationReport] = [:]
    private let url: URL
    @Published private(set) var persistenceError = ""
    init(url: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("source-validation.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: SourceValidationReport].self, from: data) { reports = saved }
    }
    func report(for source: LegadoSource) -> SourceValidationReport? {
        guard let report = reports[source.id], report.fingerprint == SourceValidation.fingerprint(source) else { return nil }
        return report
    }
    func set(_ report: SourceValidationReport) { reports[report.id] = report }
    func save() {
        do { try JSONEncoder().encode(reports).write(to: url, options: .atomic); persistenceError = "" }
        catch { persistenceError = "校验记录保存失败：\(error.localizedDescription)" }
    }
}

enum SourceStatusFilter: String, CaseIterable {
    case all = "全部", passed = "成功", failed = "失败", partial = "未完整验证", unchecked = "未校验", checking = "校验中"
    func matches(report: SourceValidationReport?, checking: Bool) -> Bool {
        switch self {
        case .all: return true
        case .checking: return checking
        case .unchecked: return report == nil && !checking
        case .passed: return !checking && report?.status == .passed
        case .failed: return !checking && report?.status == .failed
        case .partial: return !checking && report?.status == .partial
        }
    }
}
