import SwiftUI

// Script workers must not synchronously wait on the main thread to read UI
// preferences. Keep only scalar reading values here, never the source library.
enum SourceScriptConfiguration {
    private static let lock = NSLock()
    private static var reading: [String: Any] = [
        "textSize": 19.0, "lineSpacingExtra": 8.0, "paragraphSpacing": 10.0,
        "paddingLeft": 18.0, "paddingRight": 18.0, "paddingTop": 14.0, "paddingBottom": 14.0,
        "textFont": "", "pageAnim": 1
    ]
    private static var readingTheme = 0
    private static var systemDark = false

    static func updateReading(_ store: BookStore) {
        let values: [String: Any] = [
            "textSize": store.fontSize, "lineSpacingExtra": store.lineSpacing,
            "paragraphSpacing": store.paragraphSpacing,
            "paddingLeft": store.pagePaddingH, "paddingRight": store.pagePaddingH,
            "paddingTop": store.pagePaddingV, "paddingBottom": store.pagePaddingV,
            "textFont": store.fontName,
            // Android: cover=0, slide=1, simulation=2, scroll=3, none=4.
            "pageAnim": [0, 1, 3, 4, 2][max(0, min(4, store.pageTurn))]
        ]
        lock.lock(); reading = values; readingTheme = store.theme; lock.unlock()
    }

    static func updateAppearance(dark: Bool) { lock.lock(); systemDark = dark; lock.unlock() }

    static func themeMode(defaults: UserDefaults = .standard) -> String {
        switch defaults.string(forKey: "appThemeMode") {
        case "light": return "1"
        case "dark": return "2"
        default: return "0"
        }
    }

    static func readConfig() -> [String: Any] {
        lock.lock(); var config = reading; let themeIndex = readingTheme; lock.unlock()
        let theme = readerTheme(at: themeIndex), defaults = UserDefaults.standard
        config["name"] = theme.name
        config["bgStr"] = "#" + theme.background.rgbHex
        config["bgType"] = 0
        // Android exposes a percentage (0...100), not an 8-bit alpha.
        // This snapshot describes the solid reading color (bgType = 0).
        config["bgAlpha"] = 100
        config["textColor"] = "#" + theme.text.rgbHex
        // Android TextPaint.letterSpacing is in em; TextKit's kern is in
        // points. Keep existing saved spacing intact and convert at the bridge.
        let fontSize = (config["textSize"] as? Double) ?? 19
        config["letterSpacing"] = defaults.double(forKey: "reader.letterSpacing") / max(1, fontSize)
        let weight = defaults.integer(forKey: "reader.textBold")
        config["textBold"] = (0...2).contains(weight) ? weight : 0
        let indent = max(0, min(4, defaults.double(forKey: "reader.paragraphIndent")))
        config["paragraphIndent"] = String(repeating: "　", count: Int(indent.rounded()))
        return config
    }

    static func themeConfig() -> [String: Any] {
        lock.lock(); let automaticDark = systemDark; lock.unlock()
        let mode = themeMode(), dark = mode == "2" || (mode == "0" && automaticDark)
        if !UserDefaults.standard.bool(forKey: "ui.customColors"), let selected = LegadoTheme.selected(dark: dark),
           let data = try? JSONEncoder().encode(selected), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var fields = object
            fields["backgroundImgPath"] = (selected.backgroundImgPath as Any?) ?? NSNull()
            return fields
        }
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        func hex(_ color: Color) -> String { "#" + UIColor(color).resolvedColor(with: traits).rgbHex }
        return [
            "themeName": dark ? "深色" : "浅色", "isNightTheme": dark,
            "primaryColor": hex(AppTheme.accent), "accentColor": hex(AppTheme.accent),
            "backgroundColor": hex(AppTheme.background), "bottomBackground": hex(AppTheme.surface),
            "transparentNavBar": false, "backgroundImgPath": NSNull(), "backgroundImgBlur": 0
        ]
    }

    static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct ScriptAppearanceObserver: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.onAppear { SourceScriptConfiguration.updateAppearance(dark: scheme == .dark) }
            .onChange(of: scheme) { _, value in SourceScriptConfiguration.updateAppearance(dark: value == .dark) }
    }
}
