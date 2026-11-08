import XCTest
@testable import ReaderPro

private actor PackSearchAudit {
    var rows: [[String: String]] = []
    var active: [String: String] = [:]
    let checkpointName: String
    let checkpoint: URL
    init(checkpointName: String = "source-pack-search-audit-progress.json") {
        self.checkpointName = checkpointName
        checkpoint = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(checkpointName)
    }
    func start(_ source: LegadoSource) {
        active[source.id] = source.bookSourceName + " [" + source.bookSourceUrl + "]"
        print("SOURCE_AUDIT_START id=\(source.id) name=\(source.bookSourceName) url=\(source.bookSourceUrl)")
        saveCheckpoint()
    }
    func saveCheckpoint() {
        if let data = try? JSONSerialization.data(withJSONObject: ["completed": rows.count, "results": rows, "active": active], options: [.sortedKeys]) {
            try? data.write(to: checkpoint, options: .atomic)
        }
    }
    func add(_ update: SourceSearchUpdate) {
        active.removeValue(forKey: update.sourceID)
        print("SOURCE_AUDIT_DONE id=\(update.sourceID) books=\(update.books.count)")
        rows.append(["id": update.sourceID, "name": update.sourceName,
                     "books": String(update.books.count), "error": update.error,
                     "metadataWarnings": Array(Set(update.books.flatMap { $0.ruleWarnings ?? [] })).sorted().joined(separator: "\n")])
        if rows.count % 100 == 0 { print("USER_PACK_AUDIT completed=\(rows.count)") }
        if rows.count % 25 == 0,
           let data = try? JSONSerialization.data(withJSONObject: ["completed": rows.count, "results": rows], options: [.sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(checkpointName), options: .atomic)
        }
        saveCheckpoint()
    }
}

private func runPackSearchAudit(_ sources: [LegadoSource], reportPrefix: String, test: XCTestCase) async throws {
        struct Configuration: Decodable { var start: Int; var count: Int; var concurrency: Int }
        let configText = try await fetchText(urlString: SourceTestFixtures.base + "/packs/audit-config")
        let config = try JSONDecoder().decode(Configuration.self, from: Data(configText.utf8))
        let start = max(0, min(config.start, sources.count))
        let end = config.count > 0 ? min(sources.count, start + config.count) : sources.count
        let selected = Array(sources[start..<end])
        print("SOURCE_AUDIT_SCOPE start=\(start) end=\(end) concurrency=\(config.concurrency)")
        let audit = PackSearchAudit(checkpointName: reportPrefix + "-search-audit-progress.json")
        // Exercise every entry with the production engine. A failed remote
        // request is evidence to report, not an assertion that a source is dead.
        await streamSourceSearch(selected, key: "斗罗大陆", concurrency: config.concurrency, timeout: 18,
                                 willSearch: { await audit.start($0) }) { await audit.add($0) }
        var rows = await audit.rows
        for index in rows.indices {
            rows[index]["url"] = sources.first(where: { $0.id == rows[index]["id"] })?.bookSourceUrl
        }
        let expected = selected.filter { !$0.searchUrl.isEmpty }.count
        XCTAssertEqual(rows.count, expected, "Every configured search must finish or report a timeout")
        // Separately measure the certificate policy used by the Android
        // reference, without silently enabling it in the shipping app.
        let tlsIDs = Set(rows.filter { ($0["error"] ?? "").contains("TLS") }.compactMap { $0["id"] })
        let tlsSources = selected.filter { tlsIDs.contains($0.id) }
        let previous = Dictionary(uniqueKeysWithValues: tlsSources.map { ($0.bookSourceUrl, SourceTLS.isAllowed($0.bookSourceUrl)) })
        for source in tlsSources { SourceTLS.setAllowed(true, for: source.bookSourceUrl) }
        defer { for (url, allowed) in previous { SourceTLS.setAllowed(allowed, for: url) } }
        // Keep the strict and certificate-compatibility progress separate;
        // previously the second pass overwrote the first pass's checkpoint.
        let compatibility = PackSearchAudit(checkpointName: reportPrefix + "-certificate-audit-progress.json")
        await streamSourceSearch(tlsSources, key: "斗罗大陆", concurrency: 24, timeout: 18) { await compatibility.add($0) }
        let legacyRows = await compatibility.rows
        let legacyByID = Dictionary(uniqueKeysWithValues: legacyRows.compactMap { row -> (String, [String: String])? in
            guard let id = row["id"] else { return nil }; return (id, row)
        })
        for index in rows.indices {
            if let id = rows[index]["id"], let legacy = legacyByID[id] {
                rows[index]["legacyCertificateBooks"] = legacy["books"]
                rows[index]["legacyCertificateError"] = legacy["error"]
            }
        }
        let errors = rows.filter { !($0["error"] ?? "").isEmpty }.count
        let matches = rows.filter { (Int($0["books"] ?? "0") ?? 0) > 0 }.count
        let legacyMatches = legacyRows.filter { (Int($0["books"] ?? "0") ?? 0) > 0 }.count
        let summary = "USER_PACK_AUDIT total=\(selected.count) searched=\(rows.count) matched=\(matches) errors=\(errors) noSearch=\(selected.count-expected) certificateRetried=\(legacyRows.count) certificateMatched=\(legacyMatches)"
        print(summary)
        let data = try JSONSerialization.data(withJSONObject: ["summary": summary, "keyword": "斗罗大陆", "perSourceTimeoutSeconds": 18, "results": rows], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "\(sources.count)-source-search-audit.json"; attachment.lifetime = .keepAlways; test.add(attachment)
        try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(reportPrefix + "-search-audit.json"))
}

final class SourcePackAuditTests: XCTestCase {
    func testEvery1332SourceCategoriesListsDetailsAndReadingChain() async throws {
        let raw = try await fetchText(urlString: SourceTestFixtures.base + "/packs/user")
        let sources = importSourcesDetailed(raw).sources
        XCTAssertEqual(sources.count, 82)
        let configText = try await fetchText(urlString: SourceTestFixtures.base + "/packs/audit-config")
        struct Config: Decodable { var start: Int; var count: Int; var concurrency: Int }
        let config = try JSONDecoder().decode(Config.self, from: Data(configText.utf8))
        let start = max(0, min(config.start, sources.count))
        let end = config.count > 0 ? min(sources.count, start + config.count) : sources.count
        let inputs = Array(sources.enumerated())[start..<end].map { ($0.offset, $0.element) }
        let audit = Pack1332FlowAudit()
        print("SOURCE_1332_SCOPE start=\(start) end=\(end) concurrency=\(min(8, max(1, config.concurrency)))")
        await streamConcurrentWork(inputs, concurrency: min(8, max(1, config.concurrency)), operation: { index, source in
            await audit.start(index, source)
            var categories: [ExploreCategory] = []
            var categoryError = ""
            if !source.effectiveDiscoverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do { categories = try await source.resolvedExploreCategories() }
                catch { categoryError = sourceErrorMessage(error) }
            }
            var options = SourceValidationOptions()
            options.timeout = 75
            options.mediaPlayback = false
            let report = await SourceValidation.run(source, keyword: source.isComic ? "一" : "我", options: options)
            return Pack1332FlowRow(index: index, name: source.bookSourceName, sourceType: source.bookSourceType,
                                   categoryCount: categories.count, navigableCategoryCount: categories.filter(\.canNavigate).count,
                                   categoryError: categoryError, report: report)
        }, update: { await audit.add($0) })
        let rows = await audit.rows.sorted { $0.index < $1.index }
        XCTAssertEqual(rows.count, inputs.count, "Every requested source needs a report, including failures")
        XCTAssertEqual(Set(rows.map(\.index)).count, inputs.count)
        let data = try JSONEncoder().encode(rows)
        try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("source-pack-1332-flow-audit.json"), options: .atomic)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "source-pack-1332-flow-audit.json"; attachment.lifetime = .keepAlways; add(attachment)
        print("SOURCE_1332_COMPLETE total=\(rows.count) passed=\(rows.filter { $0.report.status == .passed }.count) partial=\(rows.filter { $0.report.status == .partial }.count) failed=\(rows.filter { $0.report.status == .failed }.count)")
    }

    func testSearchEverySourceInUserPackAndExportIndividualResults() async throws {
        let raw = try await fetchText(urlString: SourceTestFixtures.base + "/packs/user")
        let sources = importSourcesDetailed(raw).sources
        XCTAssertEqual(sources.count, 1466)
        try await runPackSearchAudit(sources, reportPrefix: "source-pack", test: self)
    }
}

private struct Pack1332FlowRow: Codable, Sendable {
    var index: Int
    var name: String
    var sourceType: Int
    var categoryCount: Int
    var navigableCategoryCount: Int
    var categoryError: String
    var report: SourceValidationReport
}

private actor Pack1332FlowAudit {
    var rows: [Pack1332FlowRow] = []
    var active: [Int: String] = [:]
    private let checkpoint = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("source-pack-1332-flow-audit-progress.json")
    func start(_ index: Int, _ source: LegadoSource) {
        active[index] = source.bookSourceName
        print("SOURCE_1332_START index=\(index) type=\(source.bookSourceType) name=\(source.bookSourceName)")
        save()
    }
    func add(_ row: Pack1332FlowRow) {
        active.removeValue(forKey: row.index)
        rows.append(row)
        print("SOURCE_1332_DONE index=\(row.index) categories=\(row.categoryCount) status=\(row.report.status.rawValue)")
        save()
    }
    private func save() {
        struct Progress: Encodable { var completed: Int; var active: [Int: String]; var results: [Pack1332FlowRow] }
        if let data = try? JSONEncoder().encode(Progress(completed: rows.count, active: active, results: rows)) {
            try? data.write(to: checkpoint, options: .atomic)
        }
    }
}

// This separate class is run only by the dedicated 1329 workflow. The regular
// release and 1325 diagnostics continue to execute their existing audit only.
final class SourcePack1329AuditTests: XCTestCase {
    func testSearchEverySourceIn1329PackAndExportIndividualResults() async throws {
        let raw = try await fetchText(urlString: SourceTestFixtures.base + "/packs/user")
        let sources = importSourcesDetailed(raw).sources
        XCTAssertEqual(sources.count, 320)
        try await runPackSearchAudit(sources, reportPrefix: "source-pack-1329", test: self)
    }
}
