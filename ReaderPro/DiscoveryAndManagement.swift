import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Discovery (Legado explore: category list from exploreUrl)


// MARK: - Source management (Settings): enable/disable, delete, network import, QR import

struct SourceManagementView: View {
    @ObservedObject var store: BookStore
    @StateObject private var importModel = SourceImportModel()
    @State private var showImportProgress = false
    @State private var showFileImport = false
    @State private var showFileResult = false
    @State private var fileImportMessage = ""
    @State private var importingFile = false
    @State private var showImportOptions = false
    @State private var showPaste = false
    @State private var pasteText = ""
    @State private var pasteError = ""
    @State private var pasteStatus = ""
    @State private var showNetwork = false
    @State private var networkURL = ""
    @State private var networkError = ""
    @State private var networkLoading = false
    @State private var networkResult = ""
    @State private var networkHasRssSources = false
    @State private var showQR = false
    @State private var qrResult = ""
    @State private var qrError = ""
    @State private var filterText = ""
    @FocusState private var sourceSearchFocused: Bool
    @State private var selectedSource: LegadoSource?
    // 多选 + 校验
    @State private var editing = false
    @State private var selected: Set<String> = []
    @State private var checking = false
    @StateObject private var validation = SourceValidationStore()
    @State private var checkingIDs: Set<String> = []
    @State private var statusFilter: SourceStatusFilter = .all
    @AppStorage("source.checkKeyword") private var checkKeyword = "我的"
    @State private var checkOptions = SourceValidationOptions.load()
    @State private var showCheckRules = false
    @State private var selectedReport: SourceValidationReport?
    @State private var checkTask: Task<Void, Never>?
    @State private var checkProgress = ""

    var textFiltered: [LegadoSource] {
        store.sources.filter { source in
            let report = validation.report(for: source)
            let text = [source.bookSourceName, source.bookSourceGroup, source.bookSourceUrl, report?.searchableText ?? ""].joined(separator: " ")
            return filterText.isEmpty || text.localizedCaseInsensitiveContains(filterText)
        }
    }
    var filtered: [LegadoSource] {
        textFiltered.filter { statusFilter.matches(report: validation.report(for: $0), checking: checkingIDs.contains($0.id)) }
    }
    func statusCount(_ filter: SourceStatusFilter) -> Int {
        textFiltered.filter { filter.matches(report: validation.report(for: $0), checking: checkingIDs.contains($0.id)) }.count
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
                        toolbarBtn(checking ? "取消校验" : "校验当前", icon: "checkmark.seal") {
                            if checking { checkTask?.cancel() } else { check(editing ? selectedSources : filtered) }
                        }
                        toolbarBtn("校验规则", icon: "questionmark.circle") { showCheckRules = true }
                        toolbarBtn("停用失败", icon: "xmark.circle", tint: .red) {
                            setEnabled(filtered.filter { validation.report(for: $0)?.status == .failed }, false)
                        }
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
                            Button { toggleSelect(src.id) } label: {
                                Image(systemName: selected.contains(src.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(src.id) ? AppTheme.accent : .secondary)
                            }.buttonStyle(.plain)
                        }
                        VStack(alignment: .leading) {
                            Text(src.bookSourceName).font(.headline)
                            Text(src.bookSourceUrl).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if !src.bookSourceGroup.isEmpty { Text("分组：\(src.bookSourceGroup)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if checkingIDs.contains(src.id) {
                            VStack { ProgressView(); Text("校验中").font(.caption2) }
                        } else if let report = validation.report(for: src) {
                            Button { sourceSearchFocused = false; selectedReport = report } label: {
                                VStack(alignment: .trailing, spacing: 3) {
                                    Label(report.status.title, systemImage: report.status == .passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                        .foregroundStyle(report.status == .passed ? Color.green : (report.status == .failed ? Color.red : Color.orange))
                                    Text(report.steps.first(where: { !$0.passed })?.stage ?? "首章通过").foregroundStyle(.secondary)
                                }.font(.caption2)
                            }.buttonStyle(.plain).accessibilityLabel("查看\(src.bookSourceName)校验报告")
                        } else { Text("未校验").font(.caption2).foregroundStyle(.secondary) }
                        if !editing {
                            Button { selectedSource = src } label: { Image(systemName: "info.circle").foregroundStyle(AppTheme.accent) }
                            Toggle("", isOn: Binding(get: { src.enabled }, set: { v in
                                if let i = store.sources.firstIndex(where: { $0.id == src.id }) { store.sources[i].enabled = v; store.save() }
                            })).labelsHidden()
                        }
                    }
                    .contentShape(Rectangle())
                }
                .onDelete { idx in
                    let snapshot = filtered
                    let ids = Set(idx.compactMap { snapshot.indices.contains($0) ? snapshot[$0].id : nil })
                    store.sources.removeAll { ids.contains($0.id) }
                    store.save()
                }
            } header: { Text("书源列表（全部 \(store.sources.count) 个，启用 \(store.enabledSources.count) 个）") }
        }
        .navigationTitle("书源管理")
        .onChange(of: importModel.message) { _, message in
            if !message.isEmpty { networkURL = ""; pasteText = "" }
        }
        .readerNavigationStyle()
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索书源、分组、网址或失败原因", text: $filterText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($sourceSearchFocused)
                        .onSubmit { sourceSearchFocused = false }
                        .accessibilityIdentifier("sourceSearch")
                    if !filterText.isEmpty { Button { filterText = "" } label: { Image(systemName: "xmark.circle.fill") } }
                }.padding(10).background(AppTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 8))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(SourceStatusFilter.allCases, id: \.self) { filter in
                            Button { statusFilter = filter } label: {
                                Text("\(filter.rawValue) \(statusCount(filter))").font(.caption)
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(statusFilter == filter ? AppTheme.accent.opacity(0.18) : AppTheme.surfaceMuted, in: Capsule())
                            }.buttonStyle(.plain).accessibilityIdentifier("sourceStatus-" + filter.rawValue)
                        }
                    }
                }
                if !validation.persistenceError.isEmpty { Text(validation.persistenceError).font(.caption).foregroundStyle(.red) }
            }.padding(.horizontal, 16).padding(.vertical, 8).background(AppTheme.surface)
        }
        .sheet(isPresented: $showCheckRules) {
            NavigationStack {
                Form {
                    Section("测试关键词") {
                        TextField("书名或作者", text: $checkKeyword)
                        Text("书源自带 checkKeyWord 时优先使用；没有结果记为未完整验证，不直接判死源。").font(.caption)
                    }
                    Section("校验项目") {
                        Stepper("每源超时：\(Int(checkOptions.timeout)) 秒", value: $checkOptions.timeout, in: 5...600, step: 5)
                        Toggle("搜索", isOn: $checkOptions.search)
                        Toggle("发现", isOn: $checkOptions.discovery)
                        Toggle("也校验关闭发现的书源", isOn: $checkOptions.disabledDiscovery).disabled(!checkOptions.discovery)
                        Toggle("详情", isOn: $checkOptions.info)
                        Toggle("目录", isOn: $checkOptions.catalog).disabled(!checkOptions.info)
                        Toggle("正文", isOn: $checkOptions.content).disabled(!checkOptions.info || !checkOptions.catalog)
                        Toggle("确认音视频可播放", isOn: $checkOptions.mediaPlayback).disabled(!checkOptions.info || !checkOptions.catalog || !checkOptions.content)
                        Button("使用安卓阅读的规则校验项目") {
                            checkOptions = SourceValidationOptions(); checkOptions.mediaPlayback = false; checkOptions.disabledDiscovery = true
                        }
                        Text("关闭媒体播放确认时，只检查规则能否返回播放地址；该模式的成功不等于已验证播放器。关闭详情后不检查目录和正文；关闭目录后不检查正文。文件书源检查下载地址，不要求在线章节目录。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.disabled(checking)
                    Section("成功标准") {
                        Text("按所选项目检查搜索、发现首个有效分类，以及各自样本书的详情、目录分页和首章正文。搜索和发现是不同书时分别验证阅读链路；全部所选项目通过才记成功。部分功能可用、没有结果、取消或脚本不兼容，记为未完整验证；全部入口请求失败才记失败。")
                        Text("漫画检查首章图片地址和首张图片响应。音频和原生视频检查首章媒体能否由播放器读取；网页视频仅解析成功仍记为未完整验证。支持 HTTP 与 WebView 规则；登录、验证码或脚本错误会显示具体阶段与原因。失败代表本次检查失败，不能据此认定书源永久失效，也不会自动停用书源。")
                    }
                    Section("结果范围") {
                        Text("封面或简介脚本失败会记录为附加信息警告，不会丢弃可阅读的书籍；成功仍以搜索、详情、目录和正文的抽样阅读链路为准。")
                        Text("成功仅代表校验时所选项目和这些样本通过，不代表每个分类、每本书和所有章节均可用。报告保存当次项目配置；规则或请求头变更后需重新校验。每批最多 4 个并发，支持取消。")
                    }
                }.navigationTitle("校验规则").toolbar { Button("完成") { showCheckRules = false } }
                    .onChange(of: checkOptions) { _, value in value.save() }
            }
        }
        .sheet(item: $selectedReport) { report in
            NavigationStack {
                List {
                    Section("\(report.status.title) · \(report.keyword)") {
                        Text(report.checkedAt.formatted(date: .abbreviated, time: .standard))
                        if let configuration = report.configuration { Text(configuration).font(.caption).foregroundStyle(.secondary) }
                        ForEach(Array(report.steps.enumerated()), id: \.offset) { _, step in
                            VStack(alignment: .leading, spacing: 5) {
                                Label(step.stage, systemImage: step.passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .foregroundStyle(step.passed ? .green : .red)
                                Text(step.detail).font(.footnote).textSelection(.enabled)
                            }
                        }
                    }
                }.navigationTitle("校验报告").toolbar { Button("关闭") { selectedReport = nil } }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editing ? "完成" : "编辑") {
                    editing.toggle()
                    if !editing { selected.removeAll() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImportOptions = true } label: {
                    if importModel.running { ProgressView() }
                    else {
                        Label("导入书源", systemImage: "square.and.arrow.down")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                }.disabled(importModel.running).accessibilityLabel("导入书源")
            }
        }
        .confirmationDialog("导入书源或订阅源", isPresented: $showImportOptions, titleVisibility: .visible) {
            Button("本地文件") { showFileImport = true }
            Button("粘贴书源") { showPaste = true }
            Button("网络链接") { showNetwork = true }
            Button("扫描二维码") { showQR = true }
            Button("取消", role: .cancel) {}
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
            NavigationStack { SourceDetailView(store: store, source: src) }
        }
        .sheet(isPresented: $showPaste) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    TextEditor(text: $pasteText).border(Color.gray.opacity(0.3))
                    SourceImportStatusView(model: importModel)
                    Button("导入") { importModel.start(pasteText, store: store) }
                        .disabled(importModel.running || pasteText.isEmpty)
                    Spacer()
                }.padding().navigationTitle("粘贴导入").toolbar { Button("关闭") { showPaste = false } }
            }
        }
        .sheet(isPresented: $showNetwork) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("https://… 书源或订阅源链接", text: $networkURL)
                            .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("sourceNetworkImportURL")
                        if !networkURL.isEmpty {
                            Button { networkURL = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .accessibilityLabel("清空链接").accessibilityIdentifier("clearSourceImportURL")
                                .disabled(importModel.running)
                        }
                    }
                    Button(importModel.running ? "导入中…" : "拉取并导入") { importModel.start(networkURL, store: store) }
                        .disabled(importModel.running || networkURL.isEmpty)
                    SourceImportStatusView(model: importModel)
                    if importModel.hasRssSources { NavigationLink("查看订阅源") { RssSourceManagementView(store: store) } }
                    Text("仅下载和解析书源文件，不逐个访问或校验书源网站。子合集会显示已处理数量，可随时取消。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }.padding().navigationTitle("网络导入").toolbar { Button("关闭") { showNetwork = false } }
            }
        }
        .sheet(isPresented: $showImportProgress) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) { SourceImportStatusView(model: importModel); Spacer() }.padding()
                    .navigationTitle("书源导入").toolbar { Button("关闭") { showImportProgress = false } }
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
        importModel.start(file: url, store: store); showImportProgress = true
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

    func check(_ targets: [LegadoSource]) {
        guard !checking, !targets.isEmpty else { return }
        checking = true
        let keyword = checkKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = keyword.isEmpty ? "我的" : keyword
        let options = checkOptions
        checkingIDs = Set(targets.map { $0.id })
        checkProgress = "开始校验 \(targets.count) 个书源 · \(options.summary)"
        checkTask = Task {
            var done = 0
            var index = 0
            while index < targets.count && !Task.isCancelled {
                let slice = Array(targets[index..<min(index + 4, targets.count)])
                await withTaskGroup(of: SourceValidationReport.self) { group in
                    for source in slice { group.addTask { await SourceValidation.run(source, keyword: key, options: options) } }
                    for await report in group {
                        if !Task.isCancelled { validation.set(report) }
                        checkingIDs.remove(report.id)
                        done += 1
                        checkProgress = "已校验 \(done)/\(targets.count) · 点击状态标签查看报告"
                    }
                }
                validation.save()
                index += slice.count
            }
            checkingIDs.removeAll()
            checking = false
            checkProgress = Task.isCancelled ? "已取消；完成的结果已保存" : "校验完成，可用状态筛选和搜索原因；「停用失败」仅影响失败项"
            validation.save()
            checkTask = nil
        }
    }

    func handleQR(_ code: String) {
        importModel.start(code, store: store); showImportProgress = true
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

// MARK: - 书源详情（查看规则 + 测试搜索）

struct SourceDetailView: View {
    @ObservedObject var store: BookStore
    @State var source: LegadoSource
    @State private var editorError = ""
    @State private var testKey = ""
    @State private var testResults: [SourceBook] = []
    @State private var testing = false
    @State private var testError = ""
    @State private var showBrowser = false
    @State private var showLogin = false
    @State private var showEditor = false
    @State private var sourceJSON = ""
    @State private var legacyCertificates = false

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
                if source.hasLogin { Button("登录 / 接口设置") { showLogin = true } }
                Button { sourceJSON = Self.prettyJSON(source); showEditor = true } label: {
                    Label("在代码编辑器打开（查看/改规则）", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                if !source.bookSourceUrl.isEmpty {
                    Button("在浏览器打开书源网站") { showBrowser = true }
                }
            }
            Section {
                Toggle("旧站点证书兼容", isOn: $legacyCertificates)
                    .onChange(of: legacyCertificates) { _, allowed in SourceTLS.setAllowed(allowed, for: source.bookSourceUrl) }
            } footer: {
                Text("默认关闭。仅影响本书源；开启后跳过 HTTPS 证书校验，可兼容部分 Android 能访问的旧站点。只为你信任的书源开启。")
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
        .onAppear { legacyCertificates = SourceTLS.isAllowed(source.bookSourceUrl) }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogin) { SourceLoginView(source: source) }
        .sheet(isPresented: $showBrowser) {
            NavigationStack { BrowserView(initialURL: source.bookSourceUrl) }
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                CodeEditorView(title: source.bookSourceName, code: $sourceJSON, onSave: {
                    do {
                        source = try store.saveEditedSource(sourceJSON, replacing: source.id)
                        showEditor = false
                    } catch { editorError = sourceErrorMessage(error) }
                })
                .alert("保存书源失败", isPresented: Binding(get: { !editorError.isEmpty }, set: { if !$0 { editorError = "" } })) {
                    Button("确定") { editorError = "" }
                } message: { Text(editorError) }
            }
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
                    Text("还没有订阅源。可导入阅读订阅源 JSON，或在订阅页面添加 RSS/Atom 地址。")
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
                        else { store.rssSources = mergeRssSources(store.rssSources, incoming: result.sources); store.save(); showPaste = false; pasteText = "" }
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
                                    else { store.rssSources = mergeRssSources(store.rssSources, incoming: arr); store.save(); showNetwork = false; networkURL = "" }
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
