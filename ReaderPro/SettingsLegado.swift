import SwiftUI
import UniformTypeIdentifiers

// MARK: - 「我的」页（对标开源阅读 pref_main.xml 的分组结构）
// 顶部：书源管理 / TXT目录规则 / 替换净化 / 字典规则 / 主题模式 / Web服务
// 「设置」组：备份与恢复 / 主题设置 / 其他设置
// 「其他」组：书签 / 阅读记录 / 文件管理 / 关于 / 退出

struct SettingsView: View {
    @ObservedObject var store: BookStore
    @AppStorage("appThemeMode") private var themeMode = "system"
    @State private var showThemeMode = false
    @State private var showComingSoon = false
    @State private var comingSoonText = ""

    var body: some View {
        NavigationStack {
            List {
                // 顶部组（无标题）
                Section {
                    NavigationLink { SourceManagementView(store: store) } label: {
                        SettingRow(icon: "books.vertical", iconTint: .blue, title: "书源管理", summary: "管理书源、网络导入、扫码导入")
                    }
                    NavigationLink { SourceView(store: store) } label: {
                        SettingRow(icon: "magnifyingglass", iconTint: .indigo, title: "多源搜索", summary: "搜索书名、作者并查看目录")
                    }
                    Button { comingSoon("TXT目录规则") } label: {
                        SettingRow(icon: "list.bullet.indent", iconTint: .teal, title: "TXT目录规则", summary: "自定义 TXT 章节识别规则")
                    }.buttonStyle(.plain)
                    NavigationLink { ReplaceRuleView(store: store) } label: {
                        SettingRow(icon: "wand.and.stars", iconTint: .orange, title: "替换净化", summary: "正则替换规则，正文去广告净化")
                    }
                    Button { comingSoon("字典规则") } label: {
                        SettingRow(icon: "text.badge.plus", iconTint: .green, title: "字典规则", summary: "长按查词 / 翻译")
                    }.buttonStyle(.plain)
                    Button { showThemeMode = true } label: {
                        SettingRow(icon: "circle.lefthalf.filled", iconTint: .purple, title: "主题模式", summary: themeModeText)
                    }.buttonStyle(.plain)
                    Button { comingSoon("Web服务") } label: {
                        SettingRow(icon: "network", iconTint: .cyan, title: "Web服务", summary: "局域网浏览器传书 / 管理")
                    }.buttonStyle(.plain)
                }

                // 「设置」组
                Section {
                    NavigationLink { BackupSettingsView(store: store) } label: {
                        SettingRow(icon: "arrow.clockwise.icloud", iconTint: .blue, title: "备份与恢复", summary: "本地备份 + WebDAV 云同步")
                    }
                    NavigationLink { ThemeSettingsView(store: store) } label: {
                        SettingRow(icon: "paintbrush", iconTint: .purple, title: "主题设置", summary: "配色、阅读主题")
                    }
                    NavigationLink { OtherSettingsView(store: store) } label: {
                        SettingRow(icon: "gearshape", iconTint: .gray, title: "其他设置", summary: "通用与高级选项")
                    }
                } header: { SettingSectionHeader(title: "设置") }

                // 「其他」组
                Section {
                    NavigationLink { AllBookmarksView(store: store) } label: {
                        SettingRow(icon: "bookmark", iconTint: .yellow, title: "书签", summary: "全部书签")
                    }
                    NavigationLink { ReadRecordView(store: store) } label: {
                        SettingRow(icon: "clock", iconTint: .teal, title: "阅读记录", summary: "阅读时长与进度")
                    }
                    NavigationLink { FileManageView() } label: {
                        SettingRow(icon: "folder", iconTint: .orange, title: "文件管理", summary: "本地书籍文件")
                    }
                    NavigationLink { AboutView() } label: {
                        SettingRow(icon: "info.circle", iconTint: .gray, title: "关于")
                    }
                    Button { comingSoon("退出") } label: {
                        SettingRow(icon: "power", iconTint: .red, title: "退出")
                    }.buttonStyle(.plain)
                } header: { SettingSectionHeader(title: "其他") }
            }
            .navigationTitle("我的")
            .readerNavigationStyle()
            .listStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(AppTheme.background.ignoresSafeArea())
            .confirmationDialog("主题模式", isPresented: $showThemeMode, titleVisibility: .visible) {
                Button("跟随系统") { themeMode = "system" }
                Button("浅色") { themeMode = "light" }
                Button("深色") { themeMode = "dark" }
                Button("取消", role: .cancel) {}
            }
            .alert("本版暂未实现", isPresented: $showComingSoon) {
                Button("好", role: .cancel) {}
            } message: {
                Text(comingSoonText)
            }
        }
    }

    private var themeModeText: String {
        switch themeMode {
        case "light": return "浅色"
        case "dark": return "深色"
        default: return "跟随系统"
        }
    }

    private func comingSoon(_ name: String) {
        comingSoonText = "「\(name)」功能本版暂未实现，后续版本补齐。"
        showComingSoon = true
    }
}

// MARK: - 主题设置（对标 pref_config_theme.xml）

struct ThemeSettingsView: View {
    @ObservedObject var store: BookStore
    @AppStorage("appThemeMode") private var themeMode = "system"
    @State private var showThemeMode = false

    var body: some View {
        List {
            Section {
                Button { showThemeMode = true } label: {
                    SettingRow(icon: "circle.lefthalf.filled", iconTint: .purple, title: "主题模式", summary: themeModeText)
                }.buttonStyle(.plain)
            } header: { SettingSectionHeader(title: "外观") }

            Section {
                ForEach(readerThemes) { t in
                    Button {
                        store.theme = t.id; store.save()
                    } label: {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(t.background))
                                .frame(width: 30, height: 30)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(t.text).opacity(0.18), lineWidth: 1))
                                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                            Text(t.name).font(.body).foregroundStyle(.primary)
                            Spacer()
                            if store.theme == t.id {
                                Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.accent)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            } header: { SettingSectionHeader(title: "阅读主题") }
            footer: {
                Text("阅读主题是阅读正文页的背景配色，不影响界面外观。").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                SettingRow(icon: "paintpalette", iconTint: .indigo, title: "自定义配色", summary: "主色 / 强调色 / 背景色（本版暂未实现）")
                SettingRow(icon: "rectangle.stack", iconTint: .gray, title: "封面设置", summary: "封面样式（本版暂未实现）")
            } header: { SettingSectionHeader(title: "配色") }
        }
        .navigationTitle("主题设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("主题模式", isPresented: $showThemeMode, titleVisibility: .visible) {
            Button("跟随系统") { themeMode = "system" }
            Button("浅色") { themeMode = "light" }
            Button("深色") { themeMode = "dark" }
            Button("取消", role: .cancel) {}
        }
    }

    private var themeModeText: String {
        switch themeMode {
        case "light": return "浅色"
        case "dark": return "深色"
        default: return "跟随系统"
        }
    }
}

// MARK: - 阅读设置（对标 pref_config_read.xml，接 store 已有字段）

struct ReadSettingsView: View {
    @ObservedObject var store: BookStore
    private let pageTurns = ["覆盖", "平移", "滚动", "无动画", "仿真"]

    var body: some View {
        List {
            Section {
                VStack(spacing: 2) {
                    HStack { Text("字号").foregroundStyle(.primary); Spacer(); Text("\(Int(store.fontSize))").foregroundStyle(.secondary) }
                    Slider(value: $store.fontSize, in: 12...32, step: 1) { _ in store.save() }
                }.padding(.vertical, 4)
                VStack(spacing: 2) {
                    HStack { Text("行距").foregroundStyle(.primary); Spacer(); Text("\(Int(store.lineSpacing))").foregroundStyle(.secondary) }
                    Slider(value: $store.lineSpacing, in: 0...24, step: 1) { _ in store.save() }
                }.padding(.vertical, 4)
                VStack(spacing: 2) {
                    HStack { Text("段距").foregroundStyle(.primary); Spacer(); Text("\(Int(store.paragraphSpacing))").foregroundStyle(.secondary) }
                    Slider(value: $store.paragraphSpacing, in: 0...30, step: 1) { _ in store.save() }
                }.padding(.vertical, 4)
            } header: { SettingSectionHeader(title: "排版") }

            Section {
                Picker("翻页动画", selection: $store.pageTurn) {
                    ForEach(0..<pageTurns.count, id: \.self) { i in Text(pageTurns[i]).tag(i) }
                }.onChange(of: store.pageTurn) { _, _ in store.save() }
                SettingRow(icon: "rectangle.topthird.inset", iconTint: .blue, title: "显示页眉", isOn: Binding(get: { store.showHeader }, set: { store.showHeader = $0; store.save() }))
                SettingRow(icon: "rectangle.bottomthird.inset", iconTint: .blue, title: "显示页脚", isOn: Binding(get: { store.showFooter }, set: { store.showFooter = $0; store.save() }))
            } header: { SettingSectionHeader(title: "翻页") }

            Section {
                VStack(spacing: 2) {
                    HStack { Text("朗读语速").foregroundStyle(.primary); Spacer(); Text("\(Int(store.ttsRate * 100))%").foregroundStyle(.secondary) }
                    Slider(value: $store.ttsRate, in: 0.2...1.0, step: 0.05) { _ in store.save() }
                }.padding(.vertical, 4)
                VStack(spacing: 2) {
                    HStack { Text("朗读音调").foregroundStyle(.primary); Spacer(); Text("\(Int(store.ttsPitch * 100))%").foregroundStyle(.secondary) }
                    Slider(value: $store.ttsPitch, in: 0.5...1.5, step: 0.05) { _ in store.save() }
                }.padding(.vertical, 4)
            } header: { SettingSectionHeader(title: "朗读") }
        }
        .navigationTitle("阅读设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 其他设置（对标 pref_config_other.xml）

struct OtherSettingsView: View {
    @ObservedObject var store: BookStore
    @State private var showComingSoon = false
    @State private var comingSoonText = ""
    @State private var cacheCleared = false

    var body: some View {
        List {
            Section {
                Button { comingSoon("默认主页") } label: {
                    SettingRow(icon: "house", iconTint: .blue, title: "默认主页", summary: "启动时显示的书架 / 发现 / 订阅")
                }.buttonStyle(.plain)
                SettingRow(icon: "sparkles", iconTint: .purple, title: "显示发现", isOn: Binding(get: { true }, set: { _ in comingSoon("显示/隐藏底部标签") }))
                SettingRow(icon: "bookmark", iconTint: .orange, title: "显示订阅", isOn: Binding(get: { true }, set: { _ in comingSoon("显示/隐藏底部标签") }))
            } header: { SettingSectionHeader(title: "主界面") }

            Section {
                Button { comingSoon("用户代理") } label: {
                    SettingRow(icon: "network", iconTint: .teal, title: "用户代理", summary: "自定义请求 User-Agent")
                }.buttonStyle(.plain)
                Button {
                    clearCache()
                } label: {
                    SettingRow(icon: "trash", iconTint: .red, title: "清理缓存", summary: cacheCleared ? "缓存已清理" : "清理漫画图片缓存")
                }.buttonStyle(.plain)
            } header: { SettingSectionHeader(title: "其他设置") }

            Section {
                NavigationLink { CodeEditorDemoView() } label: {
                    SettingRow(icon: "chevron.left.forwardslash.chevron.right", iconTint: .indigo, title: "代码编辑器", summary: "书源 JSON 编辑（行号 + 高亮）")
                }
                NavigationLink { AddMediaView() } label: {
                    SettingRow(icon: "play.rectangle.on.rectangle", iconTint: .green, title: "音视频播放", summary: "填直链播放音频 / 视频")
                }
                NavigationLink { BrowserView() } label: {
                    SettingRow(icon: "safari", iconTint: .blue, title: "内置浏览器", summary: "网页浏览 + 在线视频小窗")
                }
            } header: { SettingSectionHeader(title: "实用工具") }

            Section {
                SettingRow(icon: "info", iconTint: .gray, title: "关于本版", summary: "自用版 · 不上架")
            } header: { SettingSectionHeader(title: "信息") }
        }
        .navigationTitle("其他设置")
        .navigationBarTitleDisplayMode(.inline)
        .alert("本版暂未实现", isPresented: $showComingSoon) {
            Button("好", role: .cancel) {}
        } message: {
            Text(comingSoonText)
        }
    }

    private func comingSoon(_ name: String) {
        comingSoonText = "「\(name)」功能本版暂未实现，后续版本补齐。"
        showComingSoon = true
    }

    private func clearCache() {
        let fm = FileManager.default
        var removed = 0
        if let books = try? fm.contentsOfDirectory(at: BookStore.filesDir, includingPropertiesForKeys: nil) {
            for b in books where b.hasDirectoryPath {
                let cache = b.appendingPathComponent("mangaCache")
                if let files = try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) {
                    for f in files { if (try? fm.removeItem(at: f)) != nil { removed += 1 } }
                }
            }
        }
        cacheCleared = true
    }
}

// MARK: - 备份与恢复（迁移旧 SettingsView 的备份 + WebDAV 逻辑）

struct BackupSettingsView: View {
    @ObservedObject var store: BookStore
    @State private var backupURL: URL?
    @State private var showBackup = false
    @State private var importingBackup = false
    @State private var backupError = ""
    @State private var showBackupError = false
    @State private var webdavWorking = false
    @State private var webdavMessage = ""

    var body: some View {
        List {
            Section {
                Button { exportBackup() } label: {
                    SettingRow(icon: "square.and.arrow.up", iconTint: .blue, title: "导出备份", summary: "生成 .ciallo 备份文件")
                }.buttonStyle(.plain)
                Button { importingBackup = true } label: {
                    SettingRow(icon: "square.and.arrow.down", iconTint: .green, title: "导入备份", summary: "从 .ciallo 恢复书架与设置")
                }.buttonStyle(.plain)
            } header: { SettingSectionHeader(title: "本地备份") }
            footer: {
                Text("备份是单个 .ciallo 文件（ZIP）：含书架、书签、书源、替换规则和本地书文件。").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("服务器地址", text: $store.webdavURL)
                    .keyboardType(.URL).autocapitalization(.none)
                    .onChange(of: store.webdavURL) { _, _ in store.save() }
                TextField("用户名", text: $store.webdavUser)
                    .autocapitalization(.none)
                    .onChange(of: store.webdavUser) { _, _ in store.save() }
                SecureField("密码 / 应用密码", text: $store.webdavPassword)
                    .onChange(of: store.webdavPassword) { _, _ in store.save() }
                TextField("远程路径", text: $store.webdavPath)
                    .autocapitalization(.none)
                    .onChange(of: store.webdavPath) { _, _ in store.save() }
                if webdavWorking { ProgressView() }
                HStack {
                    Button("备份到云端") { backupToWebDAV() }.disabled(webdavWorking || store.webdavURL.isEmpty)
                    Button("从云端恢复") { restoreFromWebDAV() }.disabled(webdavWorking || store.webdavURL.isEmpty)
                }
                if !webdavMessage.isEmpty {
                    Text(webdavMessage).font(.footnote)
                        .foregroundStyle(webdavMessage.contains("成功") || webdavMessage.contains("完成") ? Color.secondary : Color.red)
                }
            } header: { SettingSectionHeader(title: "WebDAV 云同步") }
            footer: {
                Text("地址填 WebDAV 根地址（如坚果云 https://dav.jianguoyun.com/dav/ 或 Nextcloud https://域名/remote.php/dav/files/用户名/），远程路径如 /ReaderPro/backup.ciallo。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("备份与恢复")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBackup) { if let url = backupURL { ShareLink("导出备份", item: url) } }
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): importBackup(url)
            case .failure(let e): backupError = e.localizedDescription; showBackupError = true
            }
        }
        .alert("导入备份失败", isPresented: $showBackupError) { Button("好", role: .cancel) {} } message: { Text(backupError) }
    }

    func exportBackup() {
        let zip = store.exportBackupData()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderPro-backup.ciallo")
        try? zip.write(to: url)
        backupURL = url; showBackup = true
    }
    func importBackup(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { backupError = "读不到备份文件"; showBackupError = true; return }
        if let err = store.importBackupData(data) { backupError = err; showBackupError = true }
    }
    func backupToWebDAV() {
        webdavWorking = true; webdavMessage = ""
        let client = WebDAVClient(baseURL: store.webdavURL, username: store.webdavUser, password: store.webdavPassword)
        let data = store.exportBackupData()
        let path = store.webdavPath
        Task {
            do {
                try await client.upload(data: data, to: path)
                await MainActor.run { webdavWorking = false; webdavMessage = "备份到云端成功（\(path)）" }
            } catch {
                await MainActor.run { webdavWorking = false; webdavMessage = "备份失败：\(error.localizedDescription)" }
            }
        }
    }
    func restoreFromWebDAV() {
        webdavWorking = true; webdavMessage = ""
        let client = WebDAVClient(baseURL: store.webdavURL, username: store.webdavUser, password: store.webdavPassword)
        let path = store.webdavPath
        Task {
            do {
                let data = try await client.download(from: path)
                if let err = store.importBackupData(data) {
                    await MainActor.run { webdavWorking = false; webdavMessage = "恢复失败：\(err)" }
                } else {
                    await MainActor.run { webdavWorking = false; webdavMessage = "从云端恢复完成" }
                }
            } catch {
                await MainActor.run { webdavWorking = false; webdavMessage = "恢复失败：\(error.localizedDescription)" }
            }
        }
    }
}

// MARK: - 替换净化（列表 + 开关 + 添加 + 进入编辑）

struct ReplaceRuleView: View {
    @ObservedObject var store: BookStore

    var body: some View {
        List {
            Section {
                ForEach(store.replaceRules) { rule in
                    HStack(spacing: 0) {
                        NavigationLink {
                            ReplaceRuleEditorView(store: store, ruleId: rule.id)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.name).font(.body).foregroundStyle(.primary)
                                    Text("\(rule.pattern) → \(rule.replacement)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        Toggle("", isOn: Binding(get: { rule.enabled }, set: { v in
                            if let i = store.replaceRules.firstIndex(where: { $0.id == rule.id }) { store.replaceRules[i].enabled = v; store.save() }
                        })).labelsHidden()
                    }
                }
                .onDelete { idx in store.replaceRules.remove(atOffsets: idx); store.save() }
                Button("添加替换规则") {
                    store.replaceRules.append(ReplaceRule(name: "新规则", pattern: "", replacement: "")); store.save()
                }
            } header: { SettingSectionHeader(title: "替换规则") }
            footer: {
                Text("替换规则是正则表达式，显示和下载正文时都会自动净化（去广告、去“本章未完”等）。点规则行进入编辑。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("替换净化")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 书签

struct AllBookmarksView: View {
    @ObservedObject var store: BookStore

    var body: some View {
        List {
            if store.bookmarks.isEmpty {
                Text("还没有书签。阅读时长按正文中间的右上角「书签」按钮添加。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(store.bookmarks) { bm in
                VStack(alignment: .leading, spacing: 4) {
                    if let book = store.books.first(where: { $0.id == bm.bookId }) {
                        Text(book.title).font(.caption).foregroundStyle(AppTheme.accent).lineLimit(1)
                    }
                    Text(bm.snippet).font(.subheadline).lineLimit(3)
                    Text("第 \(bm.chapterIndex + 1) 章 · \(bm.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .onDelete { idx in store.bookmarks.remove(atOffsets: idx); store.save() }
        }
        .navigationTitle("书签")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 阅读记录

struct ReadRecordView: View {
    @ObservedObject var store: BookStore

    private var totalMinutes: Int { store.books.reduce(0) { $0 + $1.totalMinutes } }
    private var sortedBooks: [LocalBook] { store.books.sorted { $0.lastRead > $1.lastRead } }

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("读过").font(.caption).foregroundStyle(.secondary)
                        Text("\(store.books.count) 本").font(.title2.bold()).foregroundStyle(.primary)
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("累计阅读").font(.caption).foregroundStyle(.secondary)
                        Text("\(totalMinutes / 60) 小时 \(totalMinutes % 60) 分").font(.title3.bold()).foregroundStyle(.primary)
                    }
                }
                .padding(.vertical, 6)
            } header: { SettingSectionHeader(title: "统计") }

            Section {
                ForEach(sortedBooks) { book in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title).font(.body).foregroundStyle(.primary).lineLimit(1)
                        HStack {
                            if book.totalMinutes > 0 { Text("读 \(book.totalMinutes) 分钟").font(.caption).foregroundStyle(.secondary) }
                            Text("\(Int(book.progress * 100))%").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(book.lastRead.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                        }
                        ProgressView(value: book.progress)
                    }
                    .padding(.vertical, 4)
                }
            } header: { SettingSectionHeader(title: "最近阅读") }
        }
        .navigationTitle("阅读记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 文件管理

struct FileManageView: View {
    @State private var files: [FileItem] = []
    @State private var refreshToken = 0

    struct FileItem: Identifiable {
        let id = UUID()
        let name: String
        let size: Int64
        let url: URL
        var sizeText: String {
            if size >= 1_048_576 { return String(format: "%.1f MB", Double(size) / 1_048_576) }
            if size >= 1024 { return String(format: "%.0f KB", Double(size) / 1024) }
            return "\(size) B"
        }
    }

    var body: some View {
        List {
            Section {
                if files.isEmpty {
                    Text("暂无本地文件。导入的书会存放在这里。").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(files) { f in
                    HStack {
                        Image(systemName: "doc").foregroundStyle(.secondary)
                        Text(f.name).font(.body).lineLimit(1)
                        Spacer()
                        Text(f.sizeText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete(perform: delete)
            } header: { SettingSectionHeader(title: "书籍文件") }
        }
        .navigationTitle("文件管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .id(refreshToken)
    }

    private func refresh() {
        var items: [FileItem] = []
        let fm = FileManager.default
        func walk(_ dir: URL) {
            guard let cs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return }
            for u in cs {
                if u.hasDirectoryPath { walk(u) }
                else {
                    let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    items.append(FileItem(name: u.lastPathComponent, size: Int64(size), url: u))
                }
            }
        }
        walk(BookStore.filesDir)
        files = items.sorted { $0.size > $1.size }
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets { try? FileManager.default.removeItem(at: files[i].url) }
        refreshToken += 1
    }
}

// MARK: - 关于

struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 52)).foregroundStyle(AppTheme.accent)
                    Text("阅读Pro").font(.title2.bold())
                    Text("v1.0 · 自用版").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
            Section {
                SettingRow(icon: "checkmark.seal", iconTint: .green, title: "本地阅读", summary: "TXT / EPUB / MOBI / AZW3 / DOCX / FB2 / PDF / CBZ")
                SettingRow(icon: "magnifyingglass", iconTint: .blue, title: "多源搜索", summary: "Legado 书源 + JS 书源引擎")
                SettingRow(icon: "headphones", iconTint: .purple, title: "音频 / 视频", summary: "带歌词音频 + 弹幕视频（选集/换源）")
                SettingRow(icon: "icloud", iconTint: .teal, title: "云备份", summary: "WebDAV 云同步")
            } header: { SettingSectionHeader(title: "功能") }
            Section {
                Text("本项目为个人自用学习用途，不上架。书源内容版权归原作者所有。").font(.footnote).foregroundStyle(.secondary)
            } header: { SettingSectionHeader(title: "声明") }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
