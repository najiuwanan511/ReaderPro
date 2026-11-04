import SwiftUI
import CoreText
import UniformTypeIdentifiers
import ImageIO

enum ReaderTypography {
    static func font(name: String, size: CGFloat, weight: Int) -> UIFont {
        let selected: UIFont.Weight = weight == 1 ? .bold : (weight == 2 ? .light : .regular)
        guard !name.isEmpty, let base = UIFont(name: name, size: size) else {
            return UIFont.systemFont(ofSize: size, weight: selected)
        }
        // Retain the imported family's descriptor, including italic/width
        // traits. CoreText selects its nearest available weight face.
        guard weight == 1 || weight == 2 else { return base }
        var traits = base.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any] ?? [:]
        traits[.weight] = selected.rawValue
        return UIFont(descriptor: base.fontDescriptor.addingAttributes([.traits: traits]), size: size)
    }
}

enum ReaderAssets {
    private static let images = NSCache<NSString, UIImage>()
    static var directory: URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ReaderAssets", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    static func registerSavedFonts() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) { CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil) }
    }
    static func importFont(_ file: URL) throws -> String {
        let access = file.startAccessingSecurityScopedResource(); defer { if access { file.stopAccessingSecurityScopedResource() } }
        guard ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first, let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String else {
            throw SourceFailure(stage: "字体导入", message: "请选择有效的 TTF、OTF 或 TTC 字体文件")
        }
        let target = directory.appendingPathComponent(UUID().uuidString + "." + file.pathExtension.lowercased())
        try FileManager.default.copyItem(at: file, to: target)
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(target as CFURL, .process, &error) || UIFont(name: name, size: 16) != nil else {
            try? FileManager.default.removeItem(at: target)
            throw SourceFailure(stage: "字体导入", message: error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "字体注册失败")
        }
        return name
    }
    static var backgroundImage: UIImage? {
        guard let name = UserDefaults.standard.string(forKey: "reader.backgroundImage"), !name.isEmpty else { return nil }
        if let cached = images.object(forKey: name as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent((name as NSString).lastPathComponent).path) else { return nil }
        images.setObject(image, forKey: name as NSString); return image
    }
}

extension UIColor {
    var rgbHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
    static func storedColor(_ key: String, fallback: UInt32) -> UIColor {
        UIColor(hex: UserDefaults.standard.string(forKey: key).flatMap { UInt32($0, radix: 16) } ?? fallback)
    }
}

struct ReaderAppearanceView: View {
    @ObservedObject var store: BookStore
    @AppStorage("reader.customText") private var customText = "3A3A3A"
    @AppStorage("reader.customBackground") private var customBackground = "F5F1E8"
    @AppStorage("reader.backgroundImage") private var backgroundImage = ""
    @AppStorage("reader.backgroundOpacity") private var backgroundOpacity = 0.35
    @State private var importFont = false
    @State private var importBackground = false
    @State private var error = ""
    var body: some View {
        Form {
            Section("字体") {
                Picker("字体", selection: $store.fontName) { ForEach(allFonts) { Text($0.display).tag($0.name) } }.onChange(of: store.fontName) { _, _ in store.save() }
                Button("导入字体文件（TTF / OTF / TTC）") { importFont = true }
            }
            Section("自定义阅读主题") {
                ColorPicker("正文颜色", selection: color($customText), supportsOpacity: false)
                ColorPicker("背景颜色", selection: color($customBackground), supportsOpacity: false)
                Button(store.theme == 100 ? "正在使用自定义配色" : "使用此配色") { store.theme = 100; store.save() }
                Text("可继续在阅读界面调整字号、字距、行距和边距。").font(.caption).foregroundStyle(.secondary)
            }
            Section("背景图片") {
                Button("选择背景图片") { importBackground = true }
                if let image = ReaderAssets.backgroundImage { Image(uiImage: image).resizable().scaledToFit().frame(height: 150) }
                Slider(value: $backgroundOpacity, in: 0...1) { Text("图片不透明度") }
                Button("移除背景图片", role: .destructive) { backgroundImage = "" }
            }
        }.navigationTitle("字体与背景")
        .fileImporter(isPresented: $importFont, allowedContentTypes: [UTType(filenameExtension: "ttf") ?? .data, UTType(filenameExtension: "otf") ?? .data, UTType(filenameExtension: "ttc") ?? .data]) { result in
            do { store.fontName = try ReaderAssets.importFont(result.get()); store.save() } catch { self.error = sourceErrorMessage(error) }
        }
        .fileImporter(isPresented: $importBackground, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get(), access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
                      let data = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85) else { throw SourceFailure(stage: "背景", message: "无法读取图片") }
                let name = UUID().uuidString + ".jpg"; try data.write(to: ReaderAssets.directory.appendingPathComponent(name), options: .atomic)
                backgroundImage = name
            } catch { self.error = sourceErrorMessage(error) }
        }
        .alert("导入失败", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) { Button("确定") { error = "" } } message: { Text(error) }
    }
    private func color(_ value: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(uiColor: UIColor(hex: UInt32(value.wrappedValue, radix: 16) ?? 0)) }, set: { value.wrappedValue = UIColor($0).rgbHex })
    }
}

struct InterfaceAppearanceView: View {
    @ObservedObject var store: BookStore
    @AppStorage("ui.accentHex") private var accent = "E53935"
    @AppStorage("ui.backgroundHex") private var background = "F5F5FA"
    @AppStorage("ui.customColors") private var customColors = false
    @AppStorage("ui.coverCorner") private var coverCorner = 3.0
    @AppStorage("ui.coverAspect") private var coverAspect = 0.72
    var body: some View {
        Form {
            Section("界面配色") {
                Toggle("使用自定义配色", isOn: $customColors)
                ColorPicker("主色", selection: color($accent), supportsOpacity: false)
                ColorPicker("背景色", selection: color($background), supportsOpacity: false)
            }
            Section("封面设置") {
                Text("圆角 \(Int(coverCorner))"); Slider(value: $coverCorner, in: 0...20, step: 1)
                Text("宽高比 \(coverAspect, specifier: "%.2f")"); Slider(value: $coverAspect, in: 0.5...1, step: 0.01)
                RoundedRectangle(cornerRadius: coverCorner).fill(Color(uiColor: UIColor(hex: UInt32(accent, radix: 16) ?? 0xE53935))).aspectRatio(coverAspect, contentMode: .fit).frame(height: 160)
            }
        }.navigationTitle("配色与封面")
        .onChange(of: "\(accent)|\(background)|\(customColors)|\(coverCorner)|\(coverAspect)") { _, _ in store.objectWillChange.send() }
    }
    private func color(_ value: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(uiColor: UIColor(hex: UInt32(value.wrappedValue, radix: 16) ?? 0)) }, set: { value.wrappedValue = UIColor($0).rgbHex })
    }
}
