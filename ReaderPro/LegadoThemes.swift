import SwiftUI

// ThemeConfig.Config from Android. Keep the complete document when importing;
// choosing a theme is a separate operation, as it is in the Android theme list.
struct LegadoTheme: Codable, Equatable, Identifiable {
    var themeName: String
    var isNightTheme: Bool
    var primaryColor: String
    var accentColor: String
    var backgroundColor: String
    var bottomBackground: String
    var transparentNavBar: Bool
    var backgroundImgPath: String?
    var backgroundImgBlur: Int
    var id: String { themeName }

    static func color(_ value: String) -> UIColor? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let names: [String: String] = ["black":"000000", "white":"FFFFFF", "red":"FF0000", "green":"00FF00", "blue":"0000FF", "gray":"888888", "grey":"888888", "transparent":"00000000", "yellow":"FFFF00", "cyan":"00FFFF", "magenta":"FF00FF", "darkgray":"444444", "darkgrey":"444444", "lightgray":"CCCCCC", "lightgrey":"CCCCCC", "aqua":"00FFFF", "fuchsia":"FF00FF", "lime":"00FF00", "maroon":"800000", "navy":"000080", "olive":"808000", "purple":"800080", "silver":"C0C0C0", "teal":"008080"]
        let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : names[raw.lowercased()] ?? ""
        guard [6, 8].contains(hex.count), let number = UInt32(hex, radix: 16) else { return nil }
        return UIColor(red: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255,
                       blue: CGFloat(number & 255) / 255, alpha: hex.count == 8 ? CGFloat(number >> 24) / 255 : 1)
    }
    func validate() throws {
        guard !themeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [primaryColor, accentColor, backgroundColor, bottomBackground].allSatisfy({ Self.color($0) != nil }),
              (0...100).contains(backgroundImgBlur) else {
            throw SourceFailure(stage: "主题导入", message: "主题名称、颜色或背景模糊参数无效")
        }
    }
    static func decode(_ data: Data) throws -> [Self] {
        let decoder = JSONDecoder()
        let themes = data.first(where: { ![9, 10, 13, 32].contains($0) }) == 91
            ? try decoder.decode([Self].self, from: data) : [try decoder.decode(Self.self, from: data)]
        guard !themes.isEmpty else { throw SourceFailure(stage: "主题导入", message: "主题列表为空") }
        for theme in themes { try theme.validate() }
        return themes
    }
    static func selected(dark: Bool, defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: dark ? "ui.legadoTheme.dark" : "ui.legadoTheme.light") else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    static func dynamicColor(_ field: KeyPath<Self, String>, fallback: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            guard let theme = selected(dark: traits.userInterfaceStyle == .dark), let color = Self.color(theme[keyPath: field]),
                  !UserDefaults.standard.bool(forKey: "ui.customColors") else { return fallback.resolvedColor(with: traits) }
            return color
        })
    }
}

@MainActor final class LegadoThemeLibrary: ObservableObject {
    static let shared = LegadoThemeLibrary()
    @Published private(set) var themes: [LegadoTheme]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        themes = defaults.data(forKey: "ui.legadoThemes").flatMap { try? JSONDecoder().decode([LegadoTheme].self, from: $0) } ?? []
    }
    func merge(_ incoming: [LegadoTheme]) throws {
        for theme in incoming { try theme.validate() }
        var updated = themes
        for theme in incoming {
            if let index = updated.firstIndex(where: { $0.themeName == theme.themeName }) { updated[index] = theme }
            else { updated.append(theme) }
        }
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: "ui.legadoThemes"); themes = updated
    }
    func apply(_ theme: LegadoTheme) throws {
        try theme.validate()
        if let path = theme.backgroundImgPath, !path.isEmpty, !isSourceURL(path) {
            throw SourceFailure(stage: "主题设置", message: "此主题的背景图位于安卓本机，请将背景图地址改为可访问的网址")
        }
        let data = try JSONEncoder().encode(theme)
        defaults.set(data, forKey: theme.isNightTheme ? "ui.legadoTheme.dark" : "ui.legadoTheme.light")
        defaults.set(false, forKey: "ui.customColors")
        defaults.set(theme.isNightTheme ? "dark" : "light", forKey: "appThemeMode")
        objectWillChange.send()
    }
    func remove(_ theme: LegadoTheme) throws {
        let updated = themes.filter { $0.id != theme.id }
        let data = try JSONEncoder().encode(updated)
        for dark in [false, true] where LegadoTheme.selected(dark: dark, defaults: defaults)?.id == theme.id {
            defaults.removeObject(forKey: dark ? "ui.legadoTheme.dark" : "ui.legadoTheme.light")
        }
        defaults.set(data, forKey: "ui.legadoThemes"); themes = updated
    }
}

struct LegadoThemeBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            AppTheme.background
            if !UserDefaults.standard.bool(forKey: "ui.customColors"), let theme = LegadoTheme.selected(dark: scheme == .dark),
               let path = theme.backgroundImgPath, let url = URL(string: path), isSourceURL(path) {
                GeometryReader { geometry in
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height)
                            .blur(radius: CGFloat(theme.backgroundImgBlur)).clipped()
                    } placeholder: { Color.clear }
                }
            }
        }.ignoresSafeArea()
    }
}

struct LegadoThemeNavigation: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        if !UserDefaults.standard.bool(forKey: "ui.customColors"), let theme = LegadoTheme.selected(dark: scheme == .dark) {
            content.toolbarBackground(Color(uiColor: LegadoTheme.color(theme.primaryColor) ?? .clear), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else { content }
    }
}

struct LegadoThemeListView: View {
    @ObservedObject var store: BookStore
    @ObservedObject private var library = LegadoThemeLibrary.shared
    @State private var input = ""
    @State private var preview: [LegadoTheme] = []
    @State private var error = ""
    @State private var loading = false
    var body: some View {
        List {
            Section("导入主题") {
                TextField("粘贴主题 JSON 或网址", text: $input, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(loading ? "正在读取…" : "预览导入") {
                    loading = true; error = ""; preview = []
                    Task {
                        defer { loading = false }
                        do {
                            let link = LegadoAppLink(kind: .theme, source: input)
                            let result = try await LegadoLinkDocument.load(link)
                            if case .themes(let themes) = result { preview = themes }
                        } catch { self.error = sourceErrorMessage(error) }
                    }
                }.disabled(loading || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            if !preview.isEmpty {
                Section("待导入 \(preview.count) 个主题") {
                    ForEach(preview) { Text($0.themeName) }
                    Button("确认导入") {
                        do { try library.merge(preview); preview = []; input = "" }
                        catch { self.error = sourceErrorMessage(error) }
                    }
                }
            }
            Section("已导入主题") {
                ForEach(library.themes) { theme in
                    Button {
                        do { try library.apply(theme); store.objectWillChange.send(); error = "" }
                        catch { self.error = sourceErrorMessage(error) }
                    } label: {
                        HStack {
                            Circle().fill(Color(uiColor: LegadoTheme.color(theme.accentColor) ?? .clear)).frame(width: 22, height: 22)
                            Text(theme.themeName).foregroundStyle(.primary)
                            Spacer(); Text(theme.isNightTheme ? "深色" : "浅色").foregroundStyle(.secondary)
                            if LegadoTheme.selected(dark: theme.isNightTheme)?.id == theme.id { Image(systemName: "checkmark") }
                        }
                    }.swipeActions { Button("删除", role: .destructive) { do { try library.remove(theme); store.objectWillChange.send() } catch { self.error = sourceErrorMessage(error) } } }
                }
            }
        }.navigationTitle("导入主题").navigationBarTitleDisplayMode(.inline)
            .readerNavigationStyle()
            .scrollContentBackground(.hidden)
            .background(LegadoThemeBackground())
    }
}
