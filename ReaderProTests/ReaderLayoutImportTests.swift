import XCTest
import UIKit
@testable import ReaderPro

extension RuleManagementParityTests {
    private func layoutFixture() async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: URL(string: SourceTestFixtures.base + "/parity/read-layout.zip")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return data
    }

    func testAndroidLayoutZIPPreservesOriginalConfigurationAndEmbeddedAssets() async throws {
        let data = try await layoutFixture(), layout = try LegadoReadLayout.decode(data)
        XCTAssertEqual(layout.name, "排版导入样例")
        XCTAssertEqual(layout.number("letterSpacing", 0), -0.05)
        XCTAssertEqual((layout.fields["unmappedFutureField"] as? [String: Bool])?["retain"], true)
        XCTAssertNotNil(UIImage(data: try XCTUnwrap(layout.asset("/android/storage/bg/paper.png"))))
        XCTAssertGreaterThan(try XCTUnwrap(layout.asset("fixture.ttf")).count, 500)
        XCTAssertTrue(layout.warnings.contains { $0.contains("标题位置") })
        for kind in [LegadoAppLink.Kind.readConfig, .automatic] {
            let document = try LegadoLinkDocument.decode(data, kind: kind)
            XCTAssertEqual(document.names, ["排版导入样例"])
            XCTAssertFalse(document.warnings.isEmpty)
        }
        let link = LegadoAppLink(kind: .readConfig, source: SourceTestFixtures.base + "/parity/read-layout.zip#requestWithoutUA")
        let loaded = try await LegadoLinkDocument.load(link)
        XCTAssertEqual(loaded.names, ["排版导入样例"])
    }

    @MainActor func testAndroidLayoutPreviewMergeReloadUpdateAndDeleteKeepPackageBytes() async throws {
        let data = try await layoutFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LegadoReadLayoutLibrary(directory: directory)
        _ = try LegadoLinkDocument.decode(data, kind: .readConfig)
        XCTAssertTrue(library.entries.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try library.merge(data)
        XCTAssertEqual(library.entries.count, 1)
        let first = try XCTUnwrap(library.entries.first)
        let reloaded = LegadoReadLayoutLibrary(directory: directory)
        XCTAssertEqual(try reloaded.load(first).assets["fixture.ttf"], try LegadoReadLayout.decode(data).assets["fixture.ttf"])
        let layout = try reloaded.load(first)
        var config = layout.fields; config["textSize"] = 28
        let updated = writeStoredZip([(name: "readConfig.json", data: try JSONSerialization.data(withJSONObject: config))] + layout.assets.map { (name: $0.key, data: $0.value) })
        try reloaded.merge(updated)
        XCTAssertEqual(reloaded.entries.count, 1)
        let replacement = try XCTUnwrap(reloaded.entries.first)
        XCTAssertNotEqual(first.id, replacement.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(first.id).appendingPathExtension("zip").path))
        XCTAssertEqual(try reloaded.load(replacement).number("textSize", 0), 28)
        try reloaded.remove(replacement)
        XCTAssertTrue(LegadoReadLayoutLibrary(directory: directory).entries.isEmpty)
    }

    @MainActor func testAndroidLayoutAppliesFontImagesUnitsAndEveryPageAnimationWithoutTruncation() async throws {
        let data = try await layoutFixture(), layout = try LegadoReadLayout.decode(data)
        let suite = "ReaderPro.LayoutTest." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let oldMeta = try? Data(contentsOf: BookStore.metaURL), oldBooks = try? Data(contentsOf: BookStore.booksURL)
        let originalAssets = Set((try? FileManager.default.contentsOfDirectory(at: ReaderAssets.directory, includingPropertiesForKeys: nil)) ?? [])
        defer {
            for (file, bytes) in [(BookStore.metaURL, oldMeta), (BookStore.booksURL, oldBooks)] {
                if let bytes { try? bytes.write(to: file, options: .atomic) } else { try? FileManager.default.removeItem(at: file) }
            }
            let currentAssets = Set((try? FileManager.default.contentsOfDirectory(at: ReaderAssets.directory, includingPropertiesForKeys: nil)) ?? [])
            for file in currentAssets.subtracting(originalAssets) { try? FileManager.default.removeItem(at: file) }
            defaults.removePersistentDomain(forName: suite); _ = BookStore()
        }
        let store = BookStore()
        try layout.apply(store: store, variant: 0, defaults: defaults)
        XCTAssertEqual(store.fontName, "ReaderProLayoutFixture-Regular")
        XCTAssertEqual(store.fontSize, 24); XCTAssertEqual(store.pageTurn, 4)
        XCTAssertEqual(defaults.integer(forKey: "reader.textBold"), 1)
        XCTAssertEqual(defaults.double(forKey: "reader.letterSpacing"), -1.2, accuracy: 0.0001)
        XCTAssertEqual(defaults.double(forKey: "reader.backgroundOpacity"), 1)
        XCTAssertEqual(defaults.string(forKey: "reader.customText"), "243648")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ReaderAssets.directory.appendingPathComponent(try XCTUnwrap(defaults.string(forKey: "reader.backgroundImage"))).path))
        let font = ReaderTypography.font(name: store.fontName, size: 24, weight: 1)
        XCTAssertEqual(store.lineSpacing, Double(font.lineHeight) * 0.2, accuracy: 0.001)
        XCTAssertEqual(store.paragraphSpacing, Double(font.lineHeight) * 0.6, accuracy: 0.001)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = store.lineSpacing; paragraph.paragraphSpacing = store.paragraphSpacing
        let text = NSAttributedString(string: String(repeating: "导入排版后的中文分页需要完整保留。\n", count: 120), attributes: [.font: font, .paragraphStyle: paragraph, .kern: -1.2])
        let size = CGSize(width: 300, height: 500), pages = Paginator.paginate(text, pageSize: size)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.map { text.attributedSubstring(from: $0).string }.joined(), text.string)
        for page in pages {
            let view = makeReaderTextView(attributed: text.attributedSubstring(from: page), size: size)
            view.layoutManager.ensureLayout(for: view.textContainer)
            XCTAssertLessThanOrEqual(view.layoutManager.usedRect(for: view.textContainer).maxY, size.height + 1)
        }
        try layout.apply(store: store, variant: 1, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "reader.customBackground"), "102030")
        XCTAssertEqual(defaults.string(forKey: "reader.customText"), "C0D0E0")
        XCTAssertEqual(defaults.string(forKey: "reader.backgroundImage"), "")
        for (animation, expected) in [0, 1, 4, 2, 3].enumerated() {
            var config = layout.fields; config["pageAnim"] = animation; config["textFont"] = ""; config["bgType"] = 0; config["bgStr"] = "#EEEEEE"
            let candidate = try LegadoReadLayout.decode(JSONSerialization.data(withJSONObject: config))
            try candidate.apply(store: store, variant: 0, defaults: defaults)
            XCTAssertEqual(store.pageTurn, expected)
        }
    }

    @MainActor func testMissingLayoutBackgroundDoesNotMutateLiveSettings() throws {
        let layout = try LegadoReadLayout.decode(Data(##"{"name":"缺图","bgType":2,"bgStr":"missing.png","textSize":30}"##.utf8))
        let store = BookStore(), oldSize = store.fontSize, oldTheme = store.theme
        XCTAssertThrowsError(try layout.apply(store: store, variant: 0))
        XCTAssertEqual(store.fontSize, oldSize); XCTAssertEqual(store.theme, oldTheme)
    }

    func testLayoutRejectsInvalidArchivesAndOutOfRangeEnums() throws {
        for config in ["{}", "[]", #"{"textSize":900}"#, #"{"textSize":24,"pageAnim":2.5}"#, #"{"textSize":24,"pageAnimEInk":-1}"#, #"{"textSize":24,"bgTypeNight":0.5}"#, #"{"textSize":24,"letterSpacing":"bad"}"#] {
            XCTAssertThrowsError(try LegadoReadLayout.decode(Data(config.utf8)), config)
        }
        let json = Data(#"{"textSize":24}"#.utf8)
        for files in [[(name: "other.json", data: json)], [(name: "readConfig.json", data: json), (name: "../bad", data: json)], [(name: "readConfig.json", data: json), (name: "readConfig.json", data: json)]] {
            XCTAssertThrowsError(try LegadoReadLayout.decode(writeStoredZip(files)))
        }
    }
}
