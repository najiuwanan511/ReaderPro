import SwiftUI
import Network

@main
struct ReaderProApp: App {
    // 主题模式：system 跟随系统 / light 浅色 / dark 深色（对标开源阅读「主题模式」设置）
    @AppStorage("appThemeMode") private var themeMode = "system"

    // 启动即初始化网络：检测联网状态 + 主动触发本地网络授权（iOS 14+）
    @StateObject private var network = NetworkBootstrap()

    var body: some Scene {
        WindowGroup {
            rootView
                .preferredColorScheme(scheme)
                .environmentObject(network)
        }
    }

    @ViewBuilder private var rootView: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--source-ui-fixture") {
            SourceFixtureRoot()
        } else { ContentView() }
        #else
        ContentView()
        #endif
    }

    private var scheme: ColorScheme? {
        switch themeMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

// MARK: - 网络启动引导

/// 联网状态（供界面实时感知）
enum NetworkStatus: Equatable {
    case checking   // 检测中
    case online     // 已联网
    case offline    // 未联网
}

/// App 打开后第一时间完成的网络初始化。
///
/// iOS 与安卓不同：**联网（公网 HTTP/HTTPS）无需任何授权**，系统默认放行，没有可申请的弹窗。
/// iOS 上唯一需要授权的网络能力是「本地网络」（iOS 14+）——只有访问局域网地址
/// （如 192.168.x.x 的书源、局域网 WebDAV 服务器）时系统才会弹一次授权框。
/// 这里在启动时主动触发一次，让系统把授权框提前弹出来，避免之后连局域网书源时被卡住。
final class NetworkBootstrap: ObservableObject {
    @Published private(set) var status: NetworkStatus = .checking

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.readerpro.network", qos: .utility)

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.status = (path.status == .satisfied) ? .online : .offline
            }
        }
        monitor.start(queue: queue)

        // 联网本身无需授权，但「本地网络」需要在首次访问局域网时授权。
        // 启动即主动探测一次，让授权框第一时间弹出，不拖到用户点进书源才发现。
        triggerLocalNetworkPermission()
    }

    deinit {
        monitor.cancel()
    }

    /// 主动触发 iOS 14+ 的「本地网络」授权弹窗。
    /// 通过启动一个 Bonjour 浏览（探测局域网 HTTP 服务）来让系统弹出授权框，
    /// 2 秒后自动关闭，不影响后续正常连接。
    private func triggerLocalNetworkPermission() {
        let browser = NWBrowser(
            for: .bonjour(type: "_http._tcp", domain: "local."),
            using: .tcp
        )
        browser.stateUpdateHandler = { _ in }
        browser.browseResultsChangedHandler = { _, _ in }
        browser.start(queue: queue)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            browser.cancel()
        }
    }
}
