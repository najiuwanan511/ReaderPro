import SwiftUI

@main
struct ReaderProApp: App {
    // 主题模式：system 跟随系统 / light 浅色 / dark 深色（对标开源阅读「主题模式」设置）
    @AppStorage("appThemeMode") private var themeMode = "system"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(scheme)
        }
    }

    private var scheme: ColorScheme? {
        switch themeMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
