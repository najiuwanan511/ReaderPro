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

final class SourcePackAuditTests: XCTestCase {
    func testSearchEverySourceInUserPackAndExportIndividualResults() async throws {
        let raw = try await fetchText(urlString: SourceTestFixtures.base + "/packs/user")
        let sources = importSourcesDetailed(raw).sources
        XCTAssertEqual(sources.count, 1466)
        struct Configuration: Decodable { var start: Int; var count: Int; var concurrency: Int }
        let configText = try await fetchText(urlString: SourceTestFixtures.base + "/packs/audit-config")
        let config = try JSONDecoder().decode(Configuration.self, from: Data(configText.utf8))
        let start = max(0, min(config.start, sources.count))
        let end = config.count > 0 ? min(sources.count, start + config.count) : sources.count
        let selected = Array(sources[start..<end])
        print("SOURCE_AUDIT_SCOPE start=\(start) end=\(end) concurrency=\(config.concurrency)")
        let audit = PackSearchAudit()
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
        let compatibility = PackSearchAudit(checkpointName: "source-pack-certificate-audit-progress.json")
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
        attachment.name = "1466-source-search-audit.json"; attachment.lifetime = .keepAlways; add(attachment)
        try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("source-pack-search-audit.json"))
    }
}
