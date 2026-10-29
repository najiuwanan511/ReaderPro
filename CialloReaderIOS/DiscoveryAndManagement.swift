import SwiftUI
import AVFoundation

// MARK: - Discovery (open-reading style: recommendations + categories, per enabled source)

struct DiscoveryView: View {
    @ObservedObject var store: BookStore
    @State private var selectedSourceIndex = 0
    @State private var results: [SourceBook] = []
    @State private var loading = false
    @State private var category = "热门"
    @State private var selectedResult: SourceBook?
    @State private var detailChapters: [BookChapter] = []
    @State private var loadingDetail = false
    let categories = ["热门", "玄幻", "言情", "科幻", "历史", "悬疑", "武侠", "都市"]

    var sources: [LegadoSource] { store.enabledSources }
    var body: some View {
        NavigationStack {
            VStack {
                if sources.isEmpty {
                    Text("没有启用的书源，去“设置 → 书源管理”启用或导入一个。").font(.footnote).foregroundStyle(.secondary).padding()
                } else {
                    Picker("书源", selection: $selectedSourceIndex) {
                        ForEach(sources.indices, id: \.self) { i in Text(sources[i].bookSourceName).tag(i) }
                    }.pickerStyle(.menu).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(categories, id: \.self) { c in
                                Button(c) { category = c; load() }
                                    .buttonStyle(.bordered)
                                    .tint(category == c ? .blue : .gray)
                            }
                        }.padding(.horizontal)
                    }
                    if loading { ProgressView() }
                    List(results) { r in
                        Button { selectedResult = r; loadDetail(r) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                if !r.cover.isEmpty, let url = URL(string: r.cover) {
                                    AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                                        .frame(width: 44, height: 60).cornerRadius(6).clipped()
                                } else {
                                    RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.2)).frame(width: 44, height: 60)
                                        .overlay(Text(String(r.title.prefix(1))).font(.headline))
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(r.title).font(.headline).lineLimit(2)
                                    if !r.author.isEmpty { Text(r.author).font(.caption).foregroundStyle(.secondary) }
                                    if !r.intro.isEmpty { Text(r.intro).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    if results.isEmpty && !loading {
                        Text("这个书源没有发现规则时，发现会按分类关键词搜索；有 discoverUrl 的书源会直接拉取推荐列表。")
                            .font(.footnote).foregroundStyle(.secondary).padding()
                    }
                }
            }
            .navigationTitle("发现")
            .onAppear { if !sources.isEmpty { load() } }
            .onChange(of: selectedSourceIndex) { _, _ in load() }
            .sheet(item: $selectedResult) { r in
                NavigationStack {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(r.title).font(.title2).bold()
                        if !r.author.isEmpty { Text(r.author).foregroundStyle(.secondary) }
                        if !r.intro.isEmpty { Text(r.intro) }
                        if loadingDetail { ProgressView("正在拉取目录…") } else { Text("目录 \(detailChapters.count) 章").font(.caption).foregroundStyle(.secondary) }
                        Button("加入书架") {
                            var book = LocalBook(title: r.title, author: r.author, coverUrl: r.cover, fileName: r.title + ".web", kind: "web")
                            book.chapters = detailChapters
                            store.updateBook(book); selectedResult = nil
                        }.buttonStyle(.borderedProminent).disabled(detailChapters.isEmpty)
                        List(detailChapters.prefix(50)) { c in Text(c.title).font(.caption) }
                    }.padding()
                    .navigationTitle("书籍详情")
                    .toolbar { Button("关闭") { selectedResult = nil } }
                }
            }
        }
    }
    func load() {
        guard selectedSourceIndex < sources.count else { return }
        loading = true; results = []
        let src = sources[selectedSourceIndex]
        Task {
            do {
                var res: [SourceBook] = []
                if !src.discoverUrl.isEmpty { res = try await src.discover() }
                if res.isEmpty { res = try await src.search(key: category) }
                await MainActor.run { results = res; loading = false }
            } catch {
                await MainActor.run { results = []; loading = false }
            }
        }
    }
    func loadDetail(_ r: SourceBook) {
        guard selectedSourceIndex < sources.count else { return }
        loadingDetail = true; detailChapters = []
        let src = sources[selectedSourceIndex]
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

    var body: some View {
        List {
            Section("书源列表") {
                ForEach(store.sources) { src in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(src.bookSourceName).font(.headline)
                            Text(src.bookSourceUrl).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { src.enabled }, set: { v in
                            if let i = store.sources.firstIndex(where: { $0.id == src.id }) { store.sources[i].enabled = v; store.save() }
                        })).labelsHidden()
                    }
                }
                .onDelete { idx in store.sources.remove(atOffsets: idx); store.save() }
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
                        let arr = importSourcesFromText(pasteText)
                        if arr.isEmpty { pasteError = "解析失败：请确认是单个或数组 Legado 书源 JSON" }
                        else { store.sources.append(contentsOf: arr); store.save(); showPaste = false; pasteText = "" }
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
