import Foundation
import AVFoundation
import UIKit
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
    var configuration: String? = nil
    var summary: String { steps.first(where: { !$0.passed })?.detail ?? steps.last?.detail ?? "未完成" }
    var searchableText: String { ([status.title, keyword, configuration ?? ""] + steps.map { $0.stage + " " + $0.detail }).joined(separator: " ") }
}

struct SourceValidationOptions: Codable, Equatable, Sendable {
    var timeout = 180.0
    var search = true
    var discovery = true
    var info = true
    var catalog = true
    var content = true
    var mediaPlayback = true
    var disabledDiscovery = false
    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "source.validationOptions"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(defaults: UserDefaults = .standard) { if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "source.validationOptions") } }
    var summary: String {
        var stages: [String] = []
        if search { stages.append("搜索") }; if discovery { stages.append("发现") }
        if info { stages.append("详情"); if catalog { stages.append("目录"); if content { stages.append("正文") } } }
        return "超时 \(Int(timeout)) 秒；" + stages.joined(separator: "、") + (mediaPlayback ? "；检查媒体可播放性" : "；媒体仅检查规则取流")
    }
}

enum SourceValidation {
    // UI-only enable/group changes do not invalidate the parsing result.
    static func fingerprint(_ source: LegadoSource) -> String {
        var source = source
        source.id = ""; source.enabled = true; source.bookSourceGroup = ""
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var data = Data("source-engine-20261103-v14".utf8)
        data.append(SourceTLS.isAllowed(source.bookSourceUrl) ? 1 : 0)
        data.append((try? encoder.encode(source)) ?? Data())
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verifyMedia(_ request: URLRequest) async throws {
        guard let url = request.url else { throw SourceFailure(stage: "媒体校验", message: "播放地址无效") }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": request.allHTTPHeaderFields ?? [:]])
        guard try await asset.load(.isPlayable) else { throw SourceFailure(stage: "媒体校验", message: "播放器无法读取媒体，可能是登录页、错误地址或不支持的格式", url: url.absoluteString) }
    }

    static func run(_ source: LegadoSource, keyword: String, options: SourceValidationOptions = .init()) async -> SourceValidationReport {
        let key = source.ruleSearch.checkKeyWord.isEmpty ? keyword : source.ruleSearch.checkKeyWord
        var report = SourceValidationReport(id: source.id, fingerprint: fingerprint(source), checkedAt: Date(),
                                            keyword: key, status: .partial, steps: [], configuration: options.summary)
        func ok(_ stage: String, _ detail: String) { report.steps.append(.init(stage: stage, passed: true, detail: detail)) }
        func fail(_ stage: String, _ error: Error) { report.steps.append(.init(stage: stage, passed: false, detail: sourceErrorMessage(error))) }
        var samples: [(String, SourceBook)] = []
        let deadline = Date().addingTimeInterval(max(1, min(600, options.timeout)))
        func remaining() -> Double { max(0.05, deadline.timeIntervalSinceNow) }
        var failed = false
        var incomplete = false
        var incompatible = false
        func recordFailure(_ stage: String, _ error: Error) {
            fail(stage, error)
            if error is CancellationError || (error as? SourceFailure)?.stage.contains("兼容性") == true || (error as? SourceFailure)?.stage == "网页脚本" {
                incompatible = true
            } else { failed = true }
        }
        let checksDiscovery = options.discovery && (source.enabledExplore || options.disabledDiscovery) && !source.effectiveDiscoverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if (!options.search || source.searchUrl.isEmpty) && !checksDiscovery {
            report.status = .failed
            fail("规则配置", SourceFailure(stage: "规则配置", message: "已选校验项目没有可用的搜索或发现入口"))
            return report
        }
        if options.search && !source.searchUrl.isEmpty {
            do {
                let books = try await withTimeout(remaining()) { try await source.search(key: key) }
                if books.isEmpty {
                    incomplete = true
                    report.steps.append(.init(stage: "搜索", passed: false, detail: "关键词「\(key)」未匹配书籍，无法据此认定书源永久失效"))
                } else {
                    if let first = books.first { samples.append(("搜索", first)) }
                    ok("搜索", "「\(key)」返回 \(books.count) 本书")
                }
            } catch { recordFailure("搜索", error) }
        }
        if !Task.isCancelled && checksDiscovery {
            do {
                let books = try await withTimeout(remaining()) { try await source.discover() }
                if let first = books.first { samples.append(("发现", first)); ok("发现", "首个分类返回 \(books.count) 本书") }
                else { incomplete = true; report.steps.append(.init(stage: "发现", passed: false, detail: "首个分类没有返回书籍，无法验证发现阅读链路")) }
            } catch { recordFailure("发现", error) }
        }
        var checkedBooks = Set<String>()
        for (origin, sample) in samples where !Task.isCancelled && options.info {
            guard checkedBooks.insert(sample.url).inserted else { continue }
            let prefix = checkedBooks.count > 1 ? origin : ""
            var stage = prefix + "详情"
            do {
                let book = try await withTimeout(remaining()) { try await source.fetchBookInfo(book: sample) }
                ok(stage, book.title)
                let warnings = Array(Set((sample.ruleWarnings ?? []) + (book.ruleWarnings ?? []))).sorted()
                if !warnings.isEmpty { ok("附加信息警告", warnings.joined(separator: "\n")) }
                guard options.catalog else { continue }
                if source.isFile {
                    stage = prefix + "文件地址"
                    let addresses = try await withTimeout(remaining()) { try await source.fileDownloadURLs(book: book) }
                    guard !addresses.isEmpty else { throw SourceFailure(stage: stage, message: "未解析到下载地址") }
                    ok(stage, "解析到 \(addresses.count) 个文件下载地址；文件书源没有在线章节目录")
                    continue
                }
                stage = prefix + "目录"
                let chapters = try await withTimeout(remaining()) { try await source.fetchChapters(book: book) }
                guard let first = chapters.first(where: { !$0.isVolume }) else { throw SourceFailure(stage: stage, message: "目录为空") }
                ok(stage, "\(chapters.count) 章（遍历目录分页）")
                guard options.content else { continue }
                stage = prefix + "正文"
                let nextURL = chapters.drop(while: { $0.id != first.id }).dropFirst().first(where: { !$0.isVolume })?.url ?? first.url
                if source.isAudio {
                    stage = prefix + "音频"
                    let media = try await withTimeout(remaining()) { try await source.fetchChapterAudio(first) }
                    if options.mediaPlayback {
                        try await withTimeout(remaining()) { try await SourceValidation.verifyMedia(media.request) }
                    }
                    ok(stage, options.mediaPlayback ? "首章音频已解析，系统播放器确认可播放" : "首章音频规则已返回取流地址，未检查播放器可播放性")
                } else if source.isVideo {
                    stage = prefix + "视频"
                    let resource = try await withTimeout(remaining()) { try await source.fetchChapterVideoDetails(first).resource }
                    if case .native(let request) = resource {
                        if options.mediaPlayback {
                            try await withTimeout(remaining()) { try await SourceValidation.verifyMedia(request) }
                        }
                        ok(stage, options.mediaPlayback ? "首集已解析，系统播放器确认可播放" : "首集规则已返回取流地址，未检查播放器可播放性")
                    } else {
                        incomplete = true
                        report.steps.append(.init(stage: stage, passed: false, detail: "已解析网页播放器；尚未确认网页内媒体能播放，不能标记完整成功"))
                    }
                } else if source.isComic {
                    let images = try await withTimeout(remaining()) { try await source.fetchChapterImages(first, nextChapterUrl: nextURL) }
                    guard let address = images.first else { throw SourceFailure(stage: stage, message: "图片列表为空") }
                    let bytes = try await withTimeout(remaining()) { try await SourceImagePipeline.load(address, source: source, cover: false) }
                    guard UIImage(data: bytes) != nil else { throw SourceFailure(stage: stage, message: "首张图片下载或解密后仍不是有效图片", url: address) }
                    ok(stage, "首章 \(images.count) 张图片，首张响应正常")
                } else {
                    let text = try await withTimeout(remaining()) { try await source.fetchChapterContent(first, nextChapterUrl: nextURL) }
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceFailure(stage: stage, message: "首章正文为空") }
                    ok(stage, "首章「\(first.title)」读取 \(text.count) 字")
                }
            } catch { recordFailure(stage, error) }
        }
        if Task.isCancelled || samples.isEmpty {
            incomplete = true
            report.steps.append(.init(stage: "阅读链路", passed: false, detail: Task.isCancelled ? "已取消，未完成验证" : "没有样本书，详情、目录和正文未验证"))
        }
        // A working search/discovery capability or an unsupported script does
        // not establish that the entire source is dead. Keep its stage report.
        report.status = incompatible || (failed && !samples.isEmpty) ? .partial : (failed ? .failed : (incomplete ? .partial : .passed))
        return report
    }
}

@MainActor final class SourceValidationStore: ObservableObject {
    @Published private(set) var reports: [String: SourceValidationReport] = [:]
    private let url: URL
    private var fingerprints: [String: (LegadoSource, Bool, String)] = [:]
    @Published private(set) var persistenceError = ""
    init(url: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("source-validation.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: SourceValidationReport].self, from: data) { reports = saved }
    }
    func report(for source: LegadoSource) -> SourceValidationReport? {
        guard let report = reports[source.id] else { return nil }
        let fingerprint: String
        let tlsAllowed = SourceTLS.isAllowed(source.bookSourceUrl)
        if let cached = fingerprints[source.id], cached.0 == source, cached.1 == tlsAllowed { fingerprint = cached.2 }
        else { fingerprint = SourceValidation.fingerprint(source); fingerprints[source.id] = (source, tlsAllowed, fingerprint) }
        guard report.fingerprint == fingerprint else { return nil }
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
