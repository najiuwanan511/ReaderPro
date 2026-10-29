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
    @State private var discoverError = ""
    let fallbackCategories = ["热门", "玄幻", "言情", "科幻", "历史", "悬疑", "武侠", "都市"]

    var sources: [LegadoSource] { store.enabledSources }
    var body: some View {
        NavigationStack {
            VStack {
                if sources.isEmpty {
                    Text("没有启用的书源，去“设置 → 书源管理”启用或导入一个。").font(.footnote).foregroundStyle(.secondary).padding()
                } else {
                    Text("发现一次只看一个源：当前第 \(selectedSourceIndex + 1) / \(sources.count) 个启用源，换源请点下面菜单；某源没分类或没结果时点“下一个源”继续试。").font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
                    HStack {
                        Picker("书源", selection: $selectedSourceIndex) {
                            ForEach(sources.indices, id: \.self) { i in Text(sources[i].bookSourceName).tag(i) }
                        }.pickerStyle(.menu)
                        Button("下一个源") {
                            selectedSourceIndex = (selectedSourceIndex + 1) % sources.count
                            refreshCategories(); load()
                        }.buttonStyle(.bordered)
                    }.padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            if categories.isEmpty {
                                ForEach(fallbackCategories, id: \.self) { c in
                                    Button(c) { loadFallback(keyword: c) }
                                        .buttonStyle(.bordered)
                                }
                            } else {
                                ForEach(categories) { cat in
                                    Button(cat.title) { selectedCategory = cat; load() }
                                        .buttonStyle(.bordered)
                                        .tint(selectedCategory?.id == cat.id ? .blue : .gray)
                                }
                            }
                        }.padding(.horizontal)
                    }
                    if loading { ProgressView() }
                    if !discoverError.isEmpty { Text(discoverError).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(results) { r in
                                Button { selectedResult = r; loadDetail(r) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ZStack {
                                            if !r.cover.isEmpty, let url = URL(string: r.cover) {
                                                AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                                                    .frame(height: 150).clipped().cornerRadius(10)
                                            } else {
                                                RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(height: 150)
                                                    .overlay(Text(String(r.title.prefix(1))).font(.largeTitle).bold().foregroundStyle(.white))
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
                            var book = LocalBook(title: r.title, author: r.author, coverUrl: r.cover, sourceName: r.sourceName, sourceUrl: r.sourceUrl, fileName: r.title + ".web", kind: "web")
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
                let res = try await src.search(key: keyword)
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
    @State private var showQR = false
    @State private var qrResult = ""
    @State private var qrError = ""
    @State private var filterText = ""

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
                        networkLoading = true; networkError = ""
                        Task {
                            do {
                                let arr = try await importSourcesFromURL(networkURL)
                                await MainActor.run {
                                    networkLoading = false
                                    if arr.isEmpty { networkError = "这个链接里没有解析到书源" }
                                    else { store.sources.append(contentsOf: arr); store.save(); showNetwork = false; networkURL = "" }
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
