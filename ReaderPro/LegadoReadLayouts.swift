import SwiftUI
import UniformTypeIdentifiers
import ImageIO

// ReadBookConfig.Config and BgTextConfigDialog.exportConfig in legado-E.
// Keep the original document and assets; preview never changes live settings.
struct LegadoReadLayout {
    let configuration: Data
    let assets: [String: Data]
    var fields: [String: Any] { (try? JSONSerialization.jsonObject(with: configuration)) as? [String: Any] ?? [:] }
    var name: String { let value = fields["name"] as? String ?? ""; return value.isEmpty ? "未命名排版" : value }
    func number(_ key: String, _ fallback: Double) -> Double { (fields[key] as? NSNumber)?.doubleValue ?? fallback }
    func string(_ key: String, _ fallback: String = "") -> String { fields[key] as? String ?? fallback }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 * 1024 else { throw failure("排版文件超过 64 MB") }
        var configuration = data, assets: [String: Data] = [:]
        if data.starts(with: [0x50, 0x4b]) {
            let entries = readZipEntries(data)
            guard !entries.isEmpty, entries.count <= 128,
                  entries.reduce(Int64(0), { $0 + Int64($1.uncompressedSize) }) <= 128 * 1024 * 1024 else { throw failure("排版压缩包无效或解压后过大") }
            var seen = Set<String>()
            for entry in entries {
                let path = entry.name.replacingOccurrences(of: "\\", with: "/")
                guard !path.hasPrefix("/"), !path.contains(":"), !path.contains("\0"),
                      !path.split(separator: "/").contains(".."), seen.insert(path).inserted else { throw failure("排版包包含无效或重复路径") }
                if path.hasSuffix("/") { continue }
                guard entry.uncompressedSize <= 32 * 1024 * 1024,
                      let bytes = extractZipEntry(data, entry), bytes.count == entry.uncompressedSize else { throw failure("无法解压排版资源：" + path) }
                assets[path] = bytes
            }
            guard let json = assets.removeValue(forKey: "readConfig.json") else { throw failure("排版包缺少 readConfig.json") }
            configuration = json
        }
        guard let fields = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              ["textSize", "bgStr", "lineSpacingExtra", "textFont", "paragraphIndent"].contains(where: { fields[$0] != nil }) else { throw failure("不是开源阅读排版配置") }
        let value = Self(configuration: configuration, assets: assets)
        for (key, range, fallback) in [("textSize", 8.0...100.0, 20.0), ("textBold", 0.0...2.0, 0.0),
            ("letterSpacing", -0.5...2.0, 0.1), ("lineSpacingExtra", 0.0...100.0, 12.0),
            ("paragraphSpacing", 0.0...100.0, 2.0), ("bgAlpha", 0.0...100.0, 100.0), ("pageAnim", 0.0...4.0, 0.0)] {
            let number = value.number(key, fallback)
            guard (fields[key] == nil || fields[key] is NSNumber), number.isFinite, range.contains(number) else { throw failure("排版参数无效：" + key) }
        }
        for key in ["paddingLeft", "paddingRight", "paddingTop", "paddingBottom"] {
            guard (fields[key] == nil || fields[key] is NSNumber), (0...200).contains(value.number(key, 16)) else { throw failure("页边距无效：" + key) }
        }
        for (key, fallback, range) in [("textBold", 0.0, 0.0...2.0), ("pageAnim", 0.0, 0.0...4.0), ("pageAnimEInk", 4.0, 0.0...4.0)] {
            let number = value.number(key, fallback)
            guard (fields[key] == nil || fields[key] is NSNumber), number.isFinite, range.contains(number), number.rounded() == number else { throw failure("排版枚举无效：" + key) }
        }
        for (suffix, background, text) in [("", "#EEEEEE", "#3E3D3B"), ("Night", "#000000", "#ADADAD"), ("EInk", "#FFFFFF", "#000000")] {
            let type = value.number("bgType" + suffix, 0)
            guard (fields["bgType" + suffix] == nil || fields["bgType" + suffix] is NSNumber), type.isFinite, type.rounded() == type, (0...2).contains(type), LegadoTheme.color(value.string("textColor" + suffix, text)) != nil else { throw failure("排版文字颜色或背景类型无效") }
            if value.number("bgType" + suffix, 0) == 0, LegadoTheme.color(value.string("bgStr" + suffix, background)) == nil { throw failure("排版背景颜色无效") }
        }
        return value
    }
    static func failure(_ message: String) -> SourceFailure { SourceFailure(stage: "排版导入", message: message) }
    func asset(_ path: String) -> Data? {
        assets[path] ?? assets[(path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent]
    }
    var warnings: [String] {
        var output = ["标题位置、标题字号、下划线、页眉页脚提示及分隔线、安卓状态栏、颜色透明度和九宫格背景图尚未完整映射，原始配置会保留。"]
        if number("paddingLeft", 16) != number("paddingRight", 16) || number("paddingTop", 6) != number("paddingBottom", 6) {
            output.append("当前阅读器使用对称页边距，左右及上下分别取平均值。")
        }
        let font = string("textFont")
        if !font.isEmpty && asset(font) == nil { output.append("包内缺少字体文件，应用后使用系统字体。") }
        if string("paragraphIndent", "　　").contains(where: { $0 != "　" }) { output.append("自定义段首文字尚未映射，仅使用全角空格缩进。") }
        output.append("昼间、夜间和墨水屏配色可分别选择应用；不会自动随系统切换。字体度量仍由 iOS 排版。")
        return output
    }

    @MainActor func apply(store: BookStore, variant: Int, defaults: UserDefaults = .standard) throws {
        guard (0...2).contains(variant) else { throw Self.failure("未知排版配色") }
        let suffix = variant == 1 ? "Night" : (variant == 2 ? "EInk" : "")
        let text = LegadoTheme.color(string("textColor" + suffix, variant == 0 ? "#3E3D3B" : (variant == 1 ? "#ADADAD" : "#000000")))!
        let type = Int(number("bgType" + suffix, 0))
        let background = string("bgStr" + suffix, variant == 0 ? "#EEEEEE" : (variant == 1 ? "#000000" : "#FFFFFF"))
        var backgroundName = "", fontName = ""
        // Validate every requested resource before changing live preferences.
        var backgroundData: Data?
        if type != 0 {
            guard let bytes = asset(background), let image = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
                  let data = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.9) else { throw Self.failure("包内缺少可读取的背景图：" + background) }
            backgroundData = data
        }
        let fontPath = string("textFont")
        if !fontPath.isEmpty, let bytes = asset(fontPath) {
            let ext = (fontPath as NSString).pathExtension.lowercased()
            guard ["ttf", "otf", "ttc"].contains(ext) else { throw Self.failure("不支持此字体格式：" + ext) }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try bytes.write(to: temporary, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporary) }
            fontName = try ReaderAssets.importFont(temporary)
        }
        if let backgroundData {
            backgroundName = UUID().uuidString + ".jpg"
            try backgroundData.write(to: ReaderAssets.directory.appendingPathComponent(backgroundName), options: .atomic)
        }
        let fontSize = number("textSize", 20), weight = Int(number("textBold", 0))
        let font = ReaderTypography.font(name: fontName, size: CGFloat(fontSize), weight: weight)
        store.fontName = fontName; store.fontSize = fontSize
        // Android lineSpacingExtra is a line-height multiplier / 10, while
        // TextKit's lineSpacing is additional points between successive lines.
        store.lineSpacing = Double(font.lineHeight) * (number("lineSpacingExtra", 12) / 10 - 1)
        store.paragraphSpacing = Double(font.lineHeight) * number("paragraphSpacing", 2) / 10
        store.pagePaddingH = (number("paddingLeft", 16) + number("paddingRight", 16)) / 2
        store.pagePaddingV = (number("paddingTop", 6) + number("paddingBottom", 6)) / 2
        store.pageTurn = [0, 1, 4, 2, 3][Int(number(variant == 2 ? "pageAnimEInk" : "pageAnim", variant == 2 ? 4 : 0))]
        defaults.set(weight, forKey: "reader.textBold")
        defaults.set(number("letterSpacing", 0.1) * fontSize, forKey: "reader.letterSpacing")
        defaults.set(Double(string("paragraphIndent", "　　").filter { $0 == "　" }.count), forKey: "reader.paragraphIndent")
        defaults.set(text.rgbHex, forKey: "reader.customText")
        defaults.set(type == 0 ? LegadoTheme.color(background)!.rgbHex : "FFFFFF", forKey: "reader.customBackground")
        defaults.set(backgroundName, forKey: "reader.backgroundImage")
        defaults.set(number("bgAlpha", 100) / 100, forKey: "reader.backgroundOpacity")
        store.theme = 100; store.save()
    }
}

@MainActor final class LegadoReadLayoutLibrary: ObservableObject {
    struct Entry: Codable, Identifiable { let id: String; let name: String }
    static let shared = LegadoReadLayoutLibrary()
    @Published private(set) var entries: [Entry]
    let directory: URL
    init(directory: URL = ReaderAssets.directory.appendingPathComponent("Layouts", isDirectory: true)) {
        self.directory = directory
        entries = (try? Data(contentsOf: directory.appendingPathComponent("index.json"))).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }
    func load(_ entry: Entry) throws -> LegadoReadLayout {
        try LegadoReadLayout.decode(Data(contentsOf: directory.appendingPathComponent(entry.id).appendingPathExtension("zip")))
    }
    func merge(_ data: Data) throws {
        let layout = try LegadoReadLayout.decode(data)
        let entry = Entry(id: UUID().uuidString, name: layout.name)
        let old = entries.first { $0.name == layout.name }
        var updated = entries
        if let index = updated.firstIndex(where: { $0.name == layout.name }) { updated[index] = entry } else { updated.append(entry) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(entry.id).appendingPathExtension("zip")
        try data.write(to: file, options: .atomic)
        do { try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("index.json"), options: .atomic) }
        catch { try? FileManager.default.removeItem(at: file); throw error }
        entries = updated
        if let old { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.id).appendingPathExtension("zip")) }
    }
    func remove(_ entry: Entry) throws {
        let updated = entries.filter { $0.id != entry.id }
        try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        entries = updated
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.id).appendingPathExtension("zip"))
    }
}

struct LegadoReadLayoutsView: View {
    @ObservedObject var store: BookStore
    @ObservedObject private var library = LegadoReadLayoutLibrary.shared
    @State private var input = ""
    @State private var importingFile = false
    @State private var loading = false
    @State private var preview: Data?
    @State private var selected: LegadoReadLayout?
    @State private var error = ""
    @State private var result = ""
    var body: some View {
        List {
            Section("导入排版") {
                TextField("粘贴排版包网址或一键导入链接", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("layoutImportURL")
                Button(loading ? "正在读取…" : "预览导入") {
                    loading = true; error = ""; result = ""
                    Task {
                        defer { loading = false }
                        do {
                            let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
                            var link: LegadoAppLink?
                            if let url = URL(string: raw), LegadoAppLink.accepts(url) { link = try LegadoAppLink.parse(url) }
                            let document = try await LegadoLinkDocument.load(link ?? LegadoAppLink(kind: .readConfig, source: raw))
                            guard case .readLayout(let data) = document else { throw LegadoReadLayout.failure("链接不是排版包") }
                            preview = data
                        } catch { self.error = sourceErrorMessage(error) }
                    }
                }.disabled(loading).accessibilityIdentifier("layoutPreview")
                Button("从文件导入 ZIP / JSON") { importingFile = true }
            }
            if let preview, let layout = try? LegadoReadLayout.decode(preview) {
                Section("导入预览：" + layout.name) {
                    ForEach(layout.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    Button("确认导入") { perform { try library.merge(preview); self.preview = nil; result = "已保存排版，请选择应用" } }.accessibilityIdentifier("layoutConfirmImport")
                }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            if !result.isEmpty { Text(result).accessibilityIdentifier("layoutResult") }
            Section("已保存排版") {
                ForEach(library.entries) { entry in
                    Button(entry.name) { perform { selected = try library.load(entry); result = "" } }
                        .swipeActions { Button("删除", role: .destructive) { perform { try library.remove(entry) } } }
                }
            }
            if let selected {
                Section("应用：" + selected.name) {
                    ForEach(Array(["昼间", "夜间", "墨水屏"].enumerated()), id: \.offset) { index, name in
                        Button("应用" + name + "排版") { perform { try selected.apply(store: store, variant: index); result = "已应用" + name + "排版" } }.accessibilityIdentifier("layoutApply-\(index)")
                    }
                    ForEach(selected.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle("阅读排版").readerNavigationStyle()
        .scrollContentBackground(.hidden).background(LegadoThemeBackground())
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.zip, .json]) { response in
            do {
                let file = try response.get(), access = file.startAccessingSecurityScopedResource()
                defer { if access { file.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: file); _ = try LegadoReadLayout.decode(data); preview = data
            } catch { self.error = sourceErrorMessage(error) }
        }
    }
    private func perform(_ operation: () throws -> Void) { do { error = ""; try operation() } catch { self.error = sourceErrorMessage(error) } }
}
