import SwiftUI
import AVFoundation

// MARK: - Discovery (Legado explore: category list from exploreUrl)

struct DiscoveryView: View {
    @ObservedObject var store: BookStore
    @State private var selectedSourceIndex = 0
    @State private var results: [SourceBook] = []
    @State private var loading = false
    @State private var categories: [ExploreCategory] = []
    @State private var selectedCategory: ExploreCategory?
    @State private var selectedResult: SourceBook?
    @State private var detailChapters: [BookChapter] = []
    @State private var loadingDetail = false
    @State private var detailIsComic = false
    @State private var discoverError = ""
    @State private var sourceFilterText = ""
    @State private var sourceFilterMode = 0 // 0 全部, 1 快速, 2 通常, 3 正版
    let fallbackCategories = ["热门", "玄幻", "言情", "科幻", "历史", "悬疑", "武侠", "都市"]

    var sources: [LegadoSource] { store.enabledSources }
    // Legado-E 发现页的源列表 + 右上角筛选：按分组符号分流。
    // 快速 = 分组含 ⚡/快，正版 = 分组含 🏷/正版，其余归通常；没有分组标记的源默认通常。
    var filteredSources: [LegadoSource] {
        var list = sources
        if !sourceFilterText.isEmpty {
            list = list.filter { $0.bookSourceName.localizedCaseInsensitiveContains(sourceFilterText) }
        }
        switch sourceFilterMode {
        case 1: list = list.filter { $0.bookSourceGroup.contains("⚡") || $0.bookSourceGroup.contains("快") }
        case 2: list = list.filter { !($0.bookSourceGroup.contains("⚡") || $0.bookSourceGroup.contains("快") || $0.bookSourceGroup.contains("🏷") || $0.bookSourceGroup.contains("正版")) }
        case 3: list = list.filter { $0.bookSourceGroup.contains("🏷") || $0.bookSourceGroup.contains("正版") }
        default: break
        }
        return list
    }
    func sourceGroupIcon(_ src: LegadoSource) -> String {
        if src.bookSourceGroup.contains("⚡") { return "⚡📂" }
        if src.bookSourceGroup.contains("🏷") { return "🏷" }
        return "📂"
    }
    var body: some View {
        NavigationStack {
            VStack {
                if sources.isEmpty {
                    Text("没有启用的书源，去“设置 → 书源管理”启用或导入一个。").font(.footnote).foregroundStyle(.secondary).padding()
                } else {
                    // Legado-E 发现页顶部：筛选搜索栏 + 右上角快速/通常/正版筛选菜单
                    HStack {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("筛选发现源", text: $sourceFilterText)
                        }.padding(8).background(Color.gray.opacity(0.12)).cornerRadius(10)
                        Menu {
                            Button("快速书源 ⚡") { sourceFilterMode = 1 }
                            Button("通常书源 📂") { sourceFilterMode = 2 }
                            Button("正版书源 🏷") { sourceFilterMode = 3 }
                            Button("全部书源") { sourceFilterMode = 0 }
                        } label: { Image(systemName: "slider.horizontal.3").font(.title3) }
                    }.padding(.horizontal)
                    // 当前源卡片（对标截图顶部灰色卡片 + 下拉箭头）
                    if selectedSourceIndex < sources.count {
                        Button {
                            // 点卡片 = 展开源列表（下面就是源列表，点任意源即切换）
                        } label: {
                            HStack {
                                Text("📂 \(sources[selectedSourceIndex].bookSourceName)").font(.headline).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.down").foregroundStyle(.secondary)
                            }.padding().background(Color.gray.opacity(0.12)).cornerRadius(12)
                        }.buttonStyle(.plain).padding(.horizontal)
                    }
                    // 分类胶囊（对标截图：灰色圆角胶囊，自动换行，不再是横向滚动的 bordered 按钮）
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                        if categories.isEmpty {
                            ForEach(fallbackCategories, id: \.self) { c in
                                Button(c) { loadFallback(keyword: c) }
                                    .buttonStyle(.plain).font(.subheadline)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(Capsule().fill(Color.gray.opacity(0.15)))
                            }
                        } else {
                            ForEach(categories) { cat in
                                Button(cat.title) { selectedCategory = cat; load() }
                                    .buttonStyle(.plain).font(.subheadline)
                                    .foregroundStyle(selectedCategory?.id == cat.id ? .white : .primary)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(Capsule().fill(selectedCategory?.id == cat.id ? AppTheme.accent : Color.gray.opacity(0.15)))
                            }
                        }
                    }.padding(.horizontal)
                    // 源列表（对标截图：每行灰色卡片 + 分组符号 + 源名 + 右箭头，点即切换到该源的发现）
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(filteredSources) { src in
                                Button {
                                    if let i = sources.firstIndex(where: { $0.id == src.id }) {
                                        selectedSourceIndex = i; refreshCategories(); load()
                                    }
                                } label: {
                                    HStack {
                                        Text("\(sourceGroupIcon(src)) \(src.bookSourceName)").font(.subheadline).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                    }.padding().background(Color.gray.opacity(0.12)).cornerRadius(12)
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal)
                    }.frame(maxHeight: 220)
                    if loading { ProgressView() }
                    if !discoverError.isEmpty { Text(discoverError).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(results) { r in
                                Button { selectedResult = r; loadDetail(r) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ZStack {
                                            if !r.cover.isEmpty, let url = URL(string: r.cover) {
                                                AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { GridBookCover(title: r.title) }
                                                    .frame(height: 150).clipped().cornerRadius(10)
                                            } else {
                                                GridBookCover(title: r.title)
                                            }
                                        }
                                        Text(r.title).font(.subheadline).bold().lineLimit(2).multilineTextAlignment(.leading)
                                        if !r.author.isEmpty { Text(r.author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                        if !r.sourceName.isEmpty { Text(r.sourceName).font(.caption2).foregroundStyle(.secondary) }
                                        if !r.intro.isEmpty { Text(r.intro).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                                    }
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal)
                    }
                    if results.isEmpty && !loading {
                        Text(categories.isEmpty ? "这个书源没有发现分类（exploreUrl 为空或为 JS 规则，本版不支持 JS 发现），上面是按关键词搜索的分类，可直接搜；有 exploreUrl 的书源会显示它自己的分类。" : "这个分类下没有结果：可能该书源的发现规则（ruleExplore）为空或用了本版不支持的 JS/XPath，请换个分类或换源。")
                            .font(.footnote).foregroundStyle(.secondary).padding()
                    }
                }
            }
            .navigationTitle("发现")
            .toolbarBackground(AppTheme.headerBrown, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear { refreshCategories(); if !sources.isEmpty { load() } }
            .onChange(of: selectedSourceIndex) { _, _ in refreshCategories(); load() }
            .sheet(item: $selectedResult) { r in
                NavigationStack {
                    VStack(alignment: .leading, spacing: 12) {
                        if !r.cover.isEmpty, let url = URL(string: r.cover) {
                            AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                                .frame(width: 110, height: 150).cornerRadius(10).clipped()
                        }
                        Text(r.title).font(.title2).bold()
                        if !r.author.isEmpty { Text(r.author).foregroundStyle(.secondary) }
                        if !r.sourceName.isEmpty { Text("书源：\(r.sourceName)").font(.caption).foregroundStyle(.secondary) }
                        if !r.intro.isEmpty { Text(r.intro) }
                        if loadingDetail { ProgressView("正在拉取目录…") } else { Text("目录 \(detailChapters.count) 章").font(.caption).foregroundStyle(.secondary) }
                        Button("加入书架") {
                            var book = LocalBook(title: r.title, author: r.author, coverUrl: r.cover, sourceName: r.sourceName, sourceUrl: r.sourceUrl, fileName: r.title + ".web", kind: detailIsComic ? "comic" : "web")
                            book.chapters = detailChapters
                            store.updateBook(book); selectedResult = nil
                        }.buttonStyle(.borderedProminent).disabled(detailChapters.isEmpty)
                        List(detailChapters.prefix(100)) { c in Text(c.title).font(.caption) }
                    }.padding()
                    .navigationTitle("书籍详情")
                    .toolbar { Button("关闭") { selectedResult = nil } }
                }
            }
        }
    }
    func refreshCategories() {
        guard selectedSourceIndex < sources.count else { categories = []; selectedCategory = nil; return }
        categories = sources[selectedSourceIndex].exploreCategories()
        selectedCategory = categories.first
    }
    func load() {
        guard selectedSourceIndex < sources.count else { return }
        loading = true; results = []; discoverError = ""
        let src = sources[selectedSourceIndex]
        let cat = selectedCategory
        Task {
            do {
                var res: [SourceBook] = []
                if let cat = cat { res = try await src.discover(category: cat) }
                await MainActor.run { results = res; loading = false }
            } catch {
                await MainActor.run { results = []; loading = false; discoverError = "发现拉取失败：\(error.localizedDescription)" }
            }
        }
    }
    func loadFallback(keyword: String) {
        guard selectedSourceIndex < sources.count else { return }
        loading = true; results = []; discoverError = ""
        let src = sources[selectedSourceIndex]
        Task {
            do {
                let res = try await src.searchForDiscovery(key: keyword)
                await MainActor.run { results = res; loading = false }
            } catch {
                await MainActor.run { results = []; loading = false }
            }
        }
    }
    func loadDetail(_ r: SourceBook) {
        loadingDetail = true; detailChapters = []
        guard let src = store.sources.first(where: { $0.bookSourceName == r.sourceName && ($0.bookSourceUrl == r.sourceUrl || r.sourceUrl.isEmpty) }) ?? store.sources.first(where: { $0.bookSourceName == r.sourceName }) else {
            loadingDetail = false; return
        }
        detailIsComic = src.isComic
        Task {
            do {
                let chs = try await src.fetchChapters(book: r)
                await MainActor.run { detailChapters = chs; loadingDetail = false }
            } catch {
                await MainActor.run { loadingDetail = false }
            }
        }
    }
}

// MARK: - Source management (Settings): enable/disable, delete, network import, QR import

struct SourceManagementView: View {
    @ObservedObject var store: BookStore
    @State private var showPaste = false
    @State private var pasteText = ""
    @State private var pasteError = ""
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

    var body: some View {
        List {
            Section("书源列表（全部 \(store.sources.count) 个，启用 \(store.enabledSources.count) 个）") {
                TextField("按名字/分组过滤", text: $filterText).textFieldStyle(.roundedBorder)
                HStack {
                    Button("全部启用") { for i in store.sources.indices { store.sources[i].enabled = true }; store.save() }
                    Button("全部停用") { for i in store.sources.indices { store.sources[i].enabled = false }; store.save() }
                }
                ForEach(store.sources.filter { filterText.isEmpty || $0.bookSourceName.localizedCaseInsensitiveContains(filterText) || $0.bookSourceGroup.localizedCaseInsensitiveContains(filterText) }) { src in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(src.bookSourceName).font(.headline)
                            Text(src.bookSourceUrl).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if !src.bookSourceGroup.isEmpty { Text("分组：\(src.bookSourceGroup)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button { selectedSource = src } label: { Image(systemName: "info.circle").foregroundStyle(.blue) }
                        Toggle("", isOn: Binding(get: { src.enabled }, set: { v in
                            if let i = store.sources.firstIndex(where: { $0.id == src.id }) { store.sources[i].enabled = v; store.save() }
                        })).labelsHidden()
                    }
                }
                .onDelete { idx in
                    let filtered = store.sources.filter { filterText.isEmpty || $0.bookSourceName.localizedCaseInsensitiveContains(filterText) || $0.bookSourceGroup.localizedCaseInsensitiveContains(filterText) }
                    for i in idx { if i < filtered.count { store.sources.removeAll { $0.id == filtered[i].id } } }
                    store.save()
                }
            }
            Section("导入") {
                Button("粘贴 JSON 导入") { showPaste = true }
                Button("网络链接导入（订阅源）") { showNetwork = true }
                Button("扫二维码导入") { showQR = true }
                Text("网络导入：粘贴一个返回 Legado 书源 JSON 的链接（单个对象或数组，或含 sources 字段的对象），会自动批量导入。订阅源就是这种链接，换了新源重新拉一次即可。二维码里如果是链接就按网络导入，如果是 JSON 就直接导入。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("书源管理")
        .sheet(item: $selectedSource) { src in
            NavigationStack { SourceDetailView(source: src) }
        }
        .sheet(isPresented: $showPaste) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    TextEditor(text: $pasteText).border(Color.gray.opacity(0.3))
                    if !pasteError.isEmpty { Text(pasteError).foregroundStyle(.red).font(.footnote) }
                    Button("导入") {
                        let result = importSourcesDetailed(pasteText)
                        if result.sources.isEmpty { pasteError = "解析失败：请确认是单个或数组 Legado 书源 JSON，或一个订阅链接" }
                        else { store.sources.append(contentsOf: result.sources); store.save(); showPaste = false; pasteText = ""; if result.skipped > 0 { qrResult = "已导入 \(result.sources.count) 个，跳过 \(result.skipped) 个格式不对的条目" } }
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
                                    else { store.sources.append(contentsOf: arr); store.save(); networkResult = "已导入 \(arr.count) 个书源，可继续粘贴下一个合集或点关闭"; networkURL = "" }
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
    func handleQR(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http") {
            qrResult = "扫到链接，正在拉取…"
            Task {
                do {
                    let arr = try await importSourcesFromURL(trimmed)
                    await MainActor.run {
                        if arr.isEmpty { qrError = "这个链接里没有解析到书源" } else { store.sources.append(contentsOf: arr); store.save(); qrResult = "已导入 \(arr.count) 个书源" }
                    }
                } catch {
                    await MainActor.run { qrError = "拉取失败：\(error.localizedDescription)" }
                }
            }
        } else {
            let arr = importSourcesFromText(trimmed)
            if arr.isEmpty { qrError = "这个二维码不是书源 JSON 或链接" }
            else { store.sources.append(contentsOf: arr); store.save(); qrResult = "已导入 \(arr.count) 个书源" }
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
                            if src.isRssRuleSource { Text("RSS 规则源").font(.caption2).foregroundStyle(.blue) }
                        }
                        Spacer()
                        Button { openSource = src } label: { Image(systemName: "safari").foregroundStyle(.blue) }
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
