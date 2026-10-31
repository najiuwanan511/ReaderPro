import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Discovery (Legado explore: category list from exploreUrl)


// MARK: - Source management (Settings): enable/disable, delete, network import, QR import

enum SourceCheckState: Equatable { case checking, ok, fail }

struct SourceManagementView: View {
    @ObservedObject var store: BookStore
    @State private var showFileImport = false
    @State private var showFileResult = false
    @State private var fileImportMessage = ""
    @State private var importingFile = false
    @State private var showPaste = false
    @State private var pasteText = ""
    @State private var pasteError = ""
    @State private var pasteStatus = ""
    @State private var showNetwork = false
    @State private var networkURL = ""
    @State private var networkError = ""
    @State private var networkLoading = false
    @State private var networkResult = ""
    @State private var showQR = false
    @State private var qrResult = ""
    @State private var qrError = ""
    @State private var filterText = ""
    @State private var selectedSource: LegadoSource?
    // 多选 + 校验
    @State private var editing = false
    @State private var selected: Set<String> = []
    @State private var checking = false
    @State private var checkStates: [String: SourceCheckState] = [:]
    @State private var checkProgress = ""

    var filtered: [LegadoSource] {
        store.sources.filter { filterText.isEmpty || $0.bookSourceName.localizedCaseInsensitiveContains(filterText) || $0.bookSourceGroup.localizedCaseInsensitiveContains(filterText) }
    }

    var body: some View {
        List {
            Section {
                // 批量操作工具栏
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        toolbarBtn(editing ? (selected.count == filtered.count && !filtered.isEmpty ? "取消全选" : "全选") : "多选", icon: editing ? "checkmark.circle" : "checkmark.circle") {
                            if !editing { editing = true; selected = Set(filtered.map { $0.id }) }
                            else if selected.count == filtered.count && !filtered.isEmpty { selected.removeAll() }
                            else { selected = Set(filtered.map { $0.id }) }
                        }
                        toolbarBtn(checking ? "校验中…" : "校验全部", icon: "checkmark.seal") { check(editing ? selectedSources : filtered) }
                        toolbarBtn("全部启用", icon: "power") { setEnabled(editing ? selectedSources : filtered, true) }
                        toolbarBtn("全部停用", icon: "poweroff") { setEnabled(editing ? selectedSources : filtered, false) }
                        if editing {
                            toolbarBtn("删除选中", icon: "trash", tint: .red) {
                                store.sources.removeAll { selected.contains($0.id) }
                                selected.removeAll(); store.save()
                            }
                        }
                    }
                }.buttonStyle(.bordered)
                if !checkProgress.isEmpty { Text(checkProgress).font(.caption2).foregroundStyle(.secondary) }
                ForEach(filtered) { src in
                    HStack(spacing: 10) {
                        if editing {
                            Image(systemName: selected.contains(src.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(src.id) ? AppTheme.accent : .secondary)
                                .onTapGesture { toggleSelect(src.id) }
                        }
                        VStack(alignment: .leading) {
                            Text(src.bookSourceName).font(.headline)
                            Text(src.bookSourceUrl).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if !src.bookSourceGroup.isEmpty { Text("分组：\(src.bookSourceGroup)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if let st = checkStates[src.id] {
                            switch st {
                            case .checking: ProgressView().scaleEffect(0.7)
                            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            }
                        }
                        if !editing {
                            Button { selectedSource = src } label: { Image(systemName: "info.circle").foregroundStyle(AppTheme.accent) }
                            Toggle("", isOn: Binding(get: { src.enabled }, set: { v in
                                if let i = store.sources.firstIndex(where: { $0.id == src.id }) { store.sources[i].enabled = v; store.save() }
                            })).labelsHidden()
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if editing { toggleSelect(src.id) } }
                }
                .onDelete { idx in
                    for i in idx { if i < filtered.count { store.sources.removeAll { $0.id == filtered[i].id } } }
                    store.save()
                }
            } header: { Text("书源列表（全部 \(store.sources.count) 个，启用 \(store.enabledSources.count) 个）") }
        }
        .navigationTitle("书源管理")
        .readerNavigationStyle()
        .listStyle(.plain)
        .searchable(text: $filterText, prompt: "筛选书源 / 分组")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editing ? "完成" : "编辑") {
                    editing.toggle()
                    if !editing { selected.removeAll() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("本地文件", systemImage: "doc") { showFileImport = true }
                    Button("粘贴书源", systemImage: "doc.on.clipboard") { showPaste = true }
                    Button("网络链接", systemImage: "link") { showNetwork = true }
                    Button("扫描二维码", systemImage: "qrcode.viewfinder") { showQR = true }
                } label: {
                    if importingFile { ProgressView() }
                    else { Image(systemName: "square.and.arrow.down") }
                }.disabled(importingFile).accessibilityLabel("导入书源")
            }
        }
        .fileImporter(isPresented: $showFileImport, allowedContentTypes: [.json, .plainText, .data]) { result in
            switch result {
            case .success(let url): importSourceFile(url)
            case .failure(let error): fileImportMessage = error.localizedDescription; showFileResult = true
            }
        }
        .alert("书源导入", isPresented: $showFileResult) {
            Button("好", role: .cancel) {}
        } message: { Text(fileImportMessage) }
        .sheet(item: $selectedSource) { src in
            NavigationStack { SourceDetailView(source: src) }
        }
        .sheet(isPresented: $showPaste) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    TextEditor(text: $pasteText).border(Color.gray.opacity(0.3))
                    if !pasteError.isEmpty { Text(pasteError).foregroundStyle(.red).font(.footnote) }
                    if !pasteStatus.isEmpty { Text(pasteStatus).foregroundStyle(AppTheme.accentDeep).font(.footnote) }
                    Button("导入") {
                        pasteError = ""; pasteStatus = ""
                        let result = importSourcesDetailed(pasteText)
                        if result.sources.isEmpty { pasteError = "解析失败：请确认是单个或数组 Legado 书源 JSON，或一个订阅链接" }
                        else {
                            let merge = store.mergeSources(result.sources)
                            pasteText = ""
                            pasteStatus = "解析到 \(result.sources.count) 个：新增 \(merge.added)，更新 \(merge.updated)，重复 \(merge.duplicates)"
                            if result.skipped > 0 { pasteStatus += "，跳过 \(result.skipped) 个格式不对的条目" }
                        }
                    }
                    Spacer()
                }.padding().navigationTitle("粘贴导入").toolbar { Button("关闭") { showPaste = false } }
            }
        }
        .sheet(isPresented: $showNetwork) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("https://… 书源订阅链接", text: $networkURL).textFieldStyle(.roundedBorder).autocapitalization(.none)
                    if !networkError.isEmpty { Text(networkError).foregroundStyle(.red).font(.footnote) }
                    Button(networkLoading ? "拉取中…" : "拉取并导入") {
                        networkLoading = true; networkError = ""; networkResult = ""
                        Task {
                            do {
                                let arr = try await importSourcesFromURL(networkURL)
                                await MainActor.run {
                                    networkLoading = false
                                    if arr.isEmpty { networkError = "这个链接里没有解析到书源" }
                                    else {
                                        let merge = store.mergeSources(arr)
                                        networkResult = "解析到 \(arr.count) 个：新增 \(merge.added)，更新 \(merge.updated)，重复 \(merge.duplicates)"
                                        networkURL = ""
                                    }
                                }
                            } catch {
                                await MainActor.run { networkLoading = false; networkError = "拉取失败：\(error.localizedDescription)" }
                            }
                        }
                    }.disabled(networkLoading || networkURL.isEmpty)
                    if !networkResult.isEmpty { Text(networkResult).font(.footnote).foregroundStyle(AppTheme.accentDeep) }
                    Text("大合集（上千个书源）要从 CDN 下载十几 MB，可能需要几十秒，请耐心等待，不要重复点击。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }.padding().navigationTitle("网络导入").toolbar { Button("关闭") { showNetwork = false } }
            }
        }
        .sheet(isPresented: $showQR) {
            NavigationStack {
                VStack {
                    QRScannerView { code in
                        showQR = false
                        handleQR(code)
                    }.frame(height: 320).cornerRadius(12).padding()
                    if !qrResult.isEmpty { Text(qrResult).font(.footnote).foregroundStyle(.secondary).padding() }
                    if !qrError.isEmpty { Text(qrError).foregroundStyle(.red).font(.footnote).padding() }
                    Text("把二维码对准取景框。需要相机权限，拒绝后请到系统设置里打开。").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                }.navigationTitle("扫码导入").toolbar { Button("关闭") { showQR = false } }
            }
        }
    }
    private func importSourceFile(_ url: URL) {
        importingFile = true
        Task {
            let message = await Task.detached(priority: .userInitiated) { () -> ImportResult? in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return nil }
                return importSourcesDetailed(decodeTextData(data))
            }.value
            await MainActor.run {
                importingFile = false
                if let result = message, !result.sources.isEmpty {
                    let merge = store.mergeSources(result.sources)
                    fileImportMessage = "解析到 \(result.sources.count) 个书源：新增 \(merge.added)，更新 \(merge.updated)，重复 \(merge.duplicates)，跳过 \(result.skipped)。"
                } else {
                    fileImportMessage = "未能读取书源，请选择包含 Legado 书源 JSON 的文件。"
                }
                showFileResult = true
            }
        }
    }

    // 当前选中（编辑模式）对应的书源
    var selectedSources: [LegadoSource] { filtered.filter { selected.contains($0.id) } }

    func toggleSelect(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func setEnabled(_ targets: [LegadoSource], _ on: Bool) {
        let ids = Set(targets.map { $0.id })
        for i in store.sources.indices where ids.contains(store.sources[i].id) { store.sources[i].enabled = on }
        store.save()
    }

    @ViewBuilder
    func toolbarBtn(_ label: String, icon: String, tint: Color = AppTheme.accent, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon).font(.caption).labelStyle(.titleAndIcon).foregroundStyle(tint)
        }
    }

    // 校验书源可用性：探测 bookSourceUrl（为空则 searchUrl），能拿到内容即「可用」。
    func check(_ targets: [LegadoSource]) {
        guard !checking, !targets.isEmpty else { return }
        checking = true
        let total = targets.count
        for s in targets { checkStates[s.id] = .checking }
        checkProgress = "开始校验 \(total) 个书源…"
        Task {
            var done = 0
            let batch = 30
            var idx = 0
            while idx < targets.count {
                let slice = Array(targets[idx..<min(idx + batch, targets.count)])
                await withTaskGroup(of: (String, Bool).self) { group in
                    for s in slice {
                        group.addTask { (s.id, await Self.probe(s)) }
                    }
                    for await (id, ok) in group {
                        await MainActor.run {
                            checkStates[id] = ok ? .ok : .fail
                            done += 1
                            checkProgress = "已校验 \(done)/\(total)"
                        }
                    }
                }
                idx += batch
            }
            await MainActor.run {
                let ok = targets.filter { checkStates[$0.id] == .ok }.count
                checking = false
                checkProgress = "校验完成：\(ok) 可用 / \(total - ok) 失效（点「全部停用」停掉失效的，或手动关闭红叉源）"
            }
        }
    }

    static func probe(_ s: LegadoSource) async -> Bool {
        let url = s.bookSourceUrl.isEmpty ? s.searchUrl : s.bookSourceUrl
        guard !url.isEmpty else { return false }
        do {
            let html = try await fetchText(urlString: url)
            return !html.isEmpty
        } catch {
            return false
        }
    }

    func handleQR(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http") {
            qrResult = "扫到链接，正在拉取…"
            Task {
                do {
                    let arr = try await importSourcesFromURL(trimmed)
                    await MainActor.run {
                        if arr.isEmpty { qrError = "这个链接里没有解析到书源" } else {
                            let merge = store.mergeSources(arr)
                            qrResult = "解析到 \(arr.count) 个：新增 \(merge.added)，更新 \(merge.updated)，重复 \(merge.duplicates)"
                        }
                    }
                } catch {
                    await MainActor.run { qrError = "拉取失败：\(error.localizedDescription)" }
                }
            }
        } else {
            let arr = importSourcesFromText(trimmed)
            if arr.isEmpty { qrError = "这个二维码不是书源 JSON 或链接" }
            else {
                let merge = store.mergeSources(arr)
                qrResult = "解析到 \(arr.count) 个：新增 \(merge.added)，更新 \(merge.updated)，重复 \(merge.duplicates)"
            }
        }
    }
}

// MARK: - QR scanner (AVFoundation)

struct QRScannerView: UIViewControllerRepresentable {
    var onFound: (String) -> Void
    func makeUIViewController(context: Context) -> QRScannerController {
        let c = QRScannerController()
        c.onFound = onFound
        return c
    }
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
}

class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onFound: ((String) -> Void)?
    var session: AVCaptureSession?
    var found = false
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        self.session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.first?.frame = view.bounds
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !found, let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let code = obj.stringValue else { return }
        found = true
        session?.stopRunning()
        onFound?(code)
    }
}

struct ReplaceRuleEditorView: View {
    @ObservedObject var store: BookStore
    var ruleId: String
    @State private var name = ""
    @State private var pattern = ""
    @State private var replacement = ""
    var body: some View {
        Form {
            TextField("规则名", text: $name)
            TextField("正则表达式", text: $pattern).autocapitalization(.none)
            TextField("替换为（可用 $1）", text: $replacement).autocapitalization(.none)
            Button("保存") {
                if let i = store.replaceRules.firstIndex(where: { $0.id == ruleId }) {
                    store.replaceRules[i].name = name; store.replaceRules[i].pattern = pattern; store.replaceRules[i].replacement = replacement; store.save()
                }
            }
        }
        .navigationTitle("编辑替换规则")
        .onAppear {
            if let r = store.replaceRules.first(where: { $0.id == ruleId }) { name = r.name; pattern = r.pattern; replacement = r.replacement }
        }
    }
}

// MARK: - 书源详情（查看规则 + 测试搜索）

struct SourceDetailView: View {
    let source: LegadoSource
    @State private var testKey = ""
    @State private var testResults: [SourceBook] = []
    @State private var testing = false
    @State private var testError = ""
    @State private var showBrowser = false
    @State private var showEditor = false
    @State private var sourceJSON = ""

    var body: some View {
        List {
            Section("基本信息") {
                LabeledContent("名称", value: source.bookSourceName)
                LabeledContent("地址", value: source.bookSourceUrl.isEmpty ? "（空）" : source.bookSourceUrl)
                if !source.bookSourceGroup.isEmpty { LabeledContent("分组", value: source.bookSourceGroup) }
                LabeledContent("搜索地址", value: source.searchUrl.isEmpty ? "（空）" : source.searchUrl)
                LabeledContent("发现地址", value: source.effectiveDiscoverUrl.isEmpty ? "（空）" : source.effectiveDiscoverUrl)
            }
            Section("打开") {
                Button { sourceJSON = Self.prettyJSON(source); showEditor = true } label: {
                    Label("在代码编辑器打开（查看/改规则）", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                if !source.bookSourceUrl.isEmpty {
                    Button("在浏览器打开书源网站") { showBrowser = true }
                }
            }
            Section("搜索规则") {
                ruleRow("列表", source.ruleSearch.bookList)
                ruleRow("书名", source.ruleSearch.name)
                ruleRow("作者", source.ruleSearch.author)
                ruleRow("链接", source.ruleSearch.bookUrl)
                ruleRow("封面", source.ruleSearch.coverUrl)
                ruleRow("简介", source.ruleSearch.intro)
            }
            Section("目录规则") {
                ruleRow("章节列表", source.ruleToc.chapterList)
                ruleRow("章节名", source.ruleToc.chapterName)
                ruleRow("章节链接", source.ruleToc.chapterUrl)
                ruleRow("下一页目录", source.ruleToc.nextTocUrl)
            }
            Section("正文规则") {
                ruleRow("正文", source.ruleContent.content)
                ruleRow("下一页正文", source.ruleContent.nextContentUrl)
                ruleRow("净化", source.ruleContent.replaceRegex)
            }
            Section("测试搜索") {
                HStack {
                    TextField("关键词", text: $testKey).textFieldStyle(.roundedBorder)
                    Button("搜索") { test() }.disabled(testKey.isEmpty || testing)
                }
                if testing { ProgressView() }
                if !testError.isEmpty { Text(testError).font(.footnote).foregroundStyle(.red) }
                ForEach(testResults) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title).font(.subheadline).bold()
                        if !r.author.isEmpty { Text(r.author).font(.caption).foregroundStyle(.secondary) }
                        if !r.intro.isEmpty { Text(r.intro).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            }
        }
        .navigationTitle(source.bookSourceName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBrowser) {
            NavigationStack { BrowserView(initialURL: source.bookSourceUrl) }
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack { CodeEditorView(title: source.bookSourceName, code: $sourceJSON) }
        }
    }

    static func prettyJSON(_ source: LegadoSource) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(source), let s = String(data: d, encoding: .utf8) { return s }
        return "{}"
    }

    func ruleRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "（空）" : value).font(.footnote).textSelection(.enabled)
        }
    }

    func test() {
        testing = true; testError = ""; testResults = []
        let key = testKey
        Task {
            do {
                let r = try await source.search(key: key)
                await MainActor.run { testResults = r; testing = false }
            } catch {
                await MainActor.run { testError = error.localizedDescription; testing = false }
            }
        }
    }
}

// MARK: - 订阅源管理（Legado rssSource：源仓库导航 / RSS 订阅源）

struct RssSourceManagementView: View {
    @ObservedObject var store: BookStore
    @State private var showPaste = false
    @State private var pasteText = ""
    @State private var pasteError = ""
    @State private var showNetwork = false
    @State private var networkURL = ""
    @State private var networkError = ""
    @State private var networkLoading = false
    @State private var openSource: RssSource?

    var body: some View {
        List {
            Section("订阅源列表（共 \(store.rssSources.count) 个）") {
                if store.rssSources.isEmpty {
                    Text("还没有订阅源。订阅源是「源仓库导航书签」——导入后点右上的浏览器图标即可进源仓库找书源；带规则的源是 RSS 订阅源。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(store.rssSources) { src in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(src.sourceName.isEmpty ? "（未命名）" : src.sourceName).font(.headline)
                            Text(src.sourceUrl).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if !src.sourceGroup.isEmpty { Text("分组：\(src.sourceGroup)").font(.caption2).foregroundStyle(.secondary) }
                            if src.isRssRuleSource { Text("RSS 规则源").font(.caption2).foregroundStyle(AppTheme.accent) }
                        }
                        Spacer()
                        Button { openSource = src } label: { Image(systemName: "safari").foregroundStyle(AppTheme.accent) }
                        Toggle("", isOn: Binding(get: { src.enabled }, set: { v in
                            if let i = store.rssSources.firstIndex(where: { $0.id == src.id }) { store.rssSources[i].enabled = v; store.save() }
                        })).labelsHidden()
                    }
                }
                .onDelete { idx in
                    for i in idx.sorted(by: >) { if i < store.rssSources.count { store.rssSources.remove(at: i) } }
                    store.save()
                }
            }
            Section("导入") {
                Button("粘贴 JSON 导入") { showPaste = true }
                Button("网络链接导入") { showNetwork = true }
                Text("订阅源是 Legado rssSource JSON（sourceName/sourceUrl 字段）。yckceo 官方源仓库订阅：https://www.yckceo.com/yuedu/rss/json/id/193.json ，列表页：https://www.yckceo.com/yuedu/rss/index.html")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("订阅源管理")
        .sheet(item: $openSource) { src in
            NavigationStack { BrowserView(initialURL: src.sourceUrl.isEmpty ? "https://www.yckceo.com" : src.sourceUrl) }
        }
        .sheet(isPresented: $showPaste) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    TextEditor(text: $pasteText).border(Color.gray.opacity(0.3))
                    if !pasteError.isEmpty { Text(pasteError).foregroundStyle(.red).font(.footnote) }
                    Button("导入") {
                        let result = importRssSourcesDetailed(pasteText)
                        if result.sources.isEmpty { pasteError = "解析失败：请确认是 rssSource 订阅源 JSON（sourceName/sourceUrl 字段）" }
                        else { store.rssSources.append(contentsOf: result.sources); store.save(); showPaste = false; pasteText = "" }
                    }
                    Spacer()
                }.padding().navigationTitle("粘贴导入").toolbar { Button("关闭") { showPaste = false } }
            }
        }
        .sheet(isPresented: $showNetwork) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("https://… 订阅源链接", text: $networkURL).textFieldStyle(.roundedBorder).autocapitalization(.none)
                    if !networkError.isEmpty { Text(networkError).foregroundStyle(.red).font(.footnote) }
                    Button(networkLoading ? "拉取中…" : "拉取并导入") {
                        networkLoading = true; networkError = ""
                        Task {
                            do {
                                let arr = try await importRssSourcesFromURL(networkURL)
                                await MainActor.run {
                                    networkLoading = false
                                    if arr.isEmpty { networkError = "这个链接里没有解析到订阅源" }
                                    else { store.rssSources.append(contentsOf: arr); store.save(); showNetwork = false; networkURL = "" }
                                }
                            } catch {
                                await MainActor.run { networkLoading = false; networkError = "拉取失败：\(error.localizedDescription)" }
                            }
                        }
                    }.disabled(networkLoading || networkURL.isEmpty)
                    Spacer()
                }.padding().navigationTitle("网络导入").toolbar { Button("关闭") { showNetwork = false } }
            }
        }
    }
}
