import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
    @StateObject private var store = BookStore()
    var body: some View {
        TabView {
            BookshelfView(store: store)
                .tabItem { Label("书架", systemImage: "books.vertical") }
            DiscoveryView(store: store)
                .tabItem { Label("发现", systemImage: "sparkles") }
            SourceView(store: store)
                .tabItem { Label("书源", systemImage: "magnifyingglass") }
            SettingsView(store: store)
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}

// MARK: - Bookshelf

struct BookshelfView: View {
    @ObservedObject var store: BookStore
    @State private var importing = false
    @State private var errorText = ""
    @State private var showError = false
    @State private var selectedBook: LocalBook?
    @State private var selectedManga: LocalBook?
    @State private var exportURL: URL?
    @State private var showExport = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.books.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("书架是空的。点右上角 + 导入 TXT / EPUB / MOBI / AZW3 / PDF / CBZ，也可以先载入示例书测试阅读器。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("载入示例书") { addSample() }
                    }.padding()
                }
                if let current = store.books.filter({ $0.progress > 0 }).max(by: { $0.progress < $1.progress }) ?? store.books.first {
                    Button {
                        if current.kind == "cbz" { selectedManga = current } else { selectedBook = current }
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                if !current.coverUrl.isEmpty, let url = URL(string: current.coverUrl) {
                                    AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color.blue.opacity(0.2) }
                                        .frame(width: 72, height: 100).clipped().cornerRadius(10)
                                } else {
                                    RoundedRectangle(cornerRadius: 10).fill(coverGradient(for: current.title)).frame(width: 72, height: 100)
                                        .overlay(Text(String(current.title.prefix(1))).font(.title).bold().foregroundStyle(.white))
                                }
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("继续阅读").font(.caption).foregroundStyle(.secondary)
                                Text(current.title).font(.headline).lineLimit(2)
                                if !current.author.isEmpty { Text(current.author).font(.caption).foregroundStyle(.secondary) }
                                ProgressView(value: current.progress)
                                Text("已读 \(Int(current.progress * 100))%").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding().background(.ultraThinMaterial).cornerRadius(16)
                    }.buttonStyle(.plain).padding(.horizontal)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    ForEach(store.books) { book in
                        Button {
                            if book.kind == "cbz" { selectedManga = book } else { selectedBook = book }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack {
                                    if !book.coverUrl.isEmpty, let url = URL(string: book.coverUrl) {
                                        AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color.blue.opacity(0.2) }
                                            .frame(height: 150).clipped().cornerRadius(8)
                                    } else {
                                        RoundedRectangle(cornerRadius: 8).fill(coverGradient(for: book.title)).frame(height: 150)
                                            .overlay(VStack(spacing: 4) { Text(String(book.title.prefix(1))).font(.largeTitle).bold().foregroundStyle(.white); Text(book.title).font(.caption2).foregroundStyle(.white.opacity(0.9)).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 4) })
                                    }
                                }
                                Text(book.title).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                                Text("\(book.kind.uppercased()) · \(Int(book.progress * 100))%").font(.caption2).foregroundStyle(.secondary)
                                ProgressView(value: book.progress)
                            }
                        }
                        .contextMenu {
                            Button("导出 TXT") { exportBook(book) }
                            Button("导出 EPUB") { exportEpubBook(book) }
                            Button(role: .destructive) { store.deleteBook(book) } label: { Text("删除") }
                        }
                    }
                }.padding()
            }
            .sheet(isPresented: $showExport) { if let url = exportURL { ShareLink("导出", item: url) } }
            .navigationTitle("书架")
            .toolbar {
                Button { importing = true } label: { Image(systemName: "plus") }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .data]) { result in
                switch result {
                case .success(let url): importFile(url)
                case .failure(let e): errorText = e.localizedDescription; showError = true
                }
            }
            .alert("导入失败", isPresented: $showError) { Button("好", role: .cancel) {} } message: { Text(errorText) }
            .navigationDestination(item: $selectedBook) { book in ReaderView(store: store, bookId: book.id) }
            .navigationDestination(item: $selectedManga) { book in MangaView(store: store, bookId: book.id) }
        }
    }

    func coverGradient(for title: String) -> LinearGradient {
        let palettes: [[Color]] = [[.blue, .purple], [.orange, .red], [.teal, .green], [.indigo, .blue], [.pink, .orange], [.brown, .orange]]
        let idx = abs(title.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % palettes.count
        return LinearGradient(colors: palettes[idx], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    func addSample() {
        let text = """
        第一章 初入书架
        这是一本示例书，用来测试阅读器：字号、主题、书签、朗读、进度记忆都可以在这里试。
        你可以从右上角导入自己的 TXT、EPUB 或 CBZ，导入后会出现在书架上。
        第二章 继续读下去
        阅读进度会在退出时保存，下次打开会回到上次的位置。
        第三章 尾声
        示例结束。去“书源”里可以搜索公版书，或者粘贴你自己的 Legado JSON 书源来导入。
        """
        var book = LocalBook(title: "示例书", author: "CialloReaderIOS", fileName: "sample.txt", kind: "txt")
        book.chapters = splitTxtChapters(text, bookTitle: "示例书")
        store.updateBook(book)
    }

    func importFile(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { errorText = "读不到这个文件"; showError = true; return }
        let ext = url.pathExtension.lowercased()
        let fileName = url.lastPathComponent
        let dest = BookStore.filesDir.appendingPathComponent(fileName)
        try? data.write(to: dest)
        if ext == "txt" {
            let text = decodeTextData(data)
            var book = LocalBook(title: (fileName as NSString).deletingPathExtension, fileName: fileName, kind: "txt")
            book.chapters = splitTxtChapters(text, bookTitle: book.title)
            store.updateBook(book)
        } else if ext == "epub" {
            if let book = parseEpub(data, fileName: fileName) { store.updateBook(book) }
            else { errorText = "这个 EPUB 解析失败（可能是加密或结构异常）"; showError = true }
        } else if ext == "mobi" || ext == "azw3" || ext == "azw" {
            if let book = parseMobi(data, fileName: fileName) { store.updateBook(book) }
            else { errorText = "这个 MOBI / AZW3 解析失败（可能是带 DRM 的加密文件，或 KF8 结构过于复杂）"; showError = true }
        } else if ext == "docx" {
            if let book = parseDocx(data, fileName: fileName) { store.updateBook(book) }
            else { errorText = "这个 DOCX 解析失败"; showError = true }
        } else if ext == "fb2" {
            if let book = parseFb2(data, fileName: fileName) { store.updateBook(book) }
            else { errorText = "这个 FB2 解析失败"; showError = true }
        } else if ext == "pdf" {
            if let book = parsePdf(data, fileName: fileName) { store.updateBook(book) }
            else { errorText = "这个 PDF 没有可提取的文字层（纯图片 PDF 请用漫画里的 OCR）"; showError = true }
        } else if ext == "cbz" || ext == "zip" {
            if let (book, files) = parseCbz(data, fileName: fileName) {
                let dir = BookStore.filesDir.appendingPathComponent(book.id)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (name, d) in files { try? d.write(to: dir.appendingPathComponent((name as NSString).lastPathComponent)) }
                store.updateBook(book)
            } else { errorText = "这个 CBZ 里没有找到图片"; showError = true }
        } else {
            errorText = "支持 TXT、EPUB、DOCX、FB2、MOBI、AZW3、PDF、CBZ（ZIP 漫画包）"; showError = true
        }
    }

    func exportEpubBook(_ book: LocalBook) {
        let data = exportEpubData(book)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(book.title).epub")
        try? data.write(to: url)
        exportURL = url
        showExport = true
    }
    func exportBook(_ book: LocalBook) {
        let text = book.chapters.map { $0.title + "\n" + $0.text }.joined(separator: "\n\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(book.title).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        exportURL = url
        showExport = true
    }
}

// MARK: - Reader

struct ReaderView: View {
    @ObservedObject var store: BookStore
    var bookId: String
    @State private var chapterIndex = 0
    @State private var paragraphIndex = 0
    @State private var showChapters = false
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var loading = false
    @State private var errorText = ""
    @State private var isSpeaking = false
    @State private var downloadingAll = false
    @State private var readStart: Date?
    @State private var translatedText = ""
    @State private var showTranslation = false
    @State private var translating = false
    @State private var pageMode = false
    @State private var pageIndex = 0
    var pages: [String] {
        var out: [String] = []; var cur = ""
        for p in paragraphs {
            if cur.count + p.count > 900 && !cur.isEmpty { out.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : "\n\n") + p
        }
        if !cur.isEmpty { out.append(cur) }
        return out.isEmpty ? [""] : out
    }
    private let speaker = AVSpeechSynthesizer()

    var book: LocalBook? { store.books.first { $0.id == bookId } }
    var chapter: BookChapter? {
        guard let b = book, chapterIndex < b.chapters.count else { return nil }
        return b.chapters[chapterIndex]
    }
    var paragraphs: [String] {
        guard let c = chapter else { return [] }
        let cleaned = store.purify(c.text)
        return cleaned.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                ProgressView("正在加载章节…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let b = book, let c = chapter {
                if pageMode {
                    TabView(selection: $pageIndex) {
                        ForEach(pages.indices, id: \.self) { i in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    if i == 0 { Text(c.title).font(.system(size: store.fontSize + 3, weight: .bold)).padding(.bottom, 8) }
                                    Text(pages[i]).font(.system(size: store.fontSize)).lineSpacing(store.lineSpacing)
                                    Spacer()
                                    Text("\(i + 1) / \(pages.count)").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                                }.padding()
                            }.tag(i)
                        }
                    }.tabViewStyle(.page(indexDisplayMode: .never))
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: CGFloat(store.lineSpacing)) {
                                Text(c.title).font(.system(size: store.fontSize + 3, weight: .bold)).padding(.bottom, 8)
                                ForEach(paragraphs.indices, id: \.self) { i in
                                    Text(paragraphs[i])
                                        .font(.system(size: store.fontSize))
                                        .lineSpacing(store.lineSpacing)
                                        .id(i)
                                        .onTapGesture { paragraphIndex = i; saveProgress() }
                                }
                            }
                            .padding()
                        }
                        .onChange(of: paragraphIndex) { _, v in withAnimation { proxy.scrollTo(v, anchor: .top) } }
                        .onAppear { proxy.scrollTo(min(paragraphIndex, max(paragraphs.count - 1, 0)), anchor: .top) }
                    }
                }
                VStack(spacing: 8) {
                    HStack {
                        Button("上一章") { prevChapter() }.disabled(chapterIndex == 0)
                        Spacer()
                        Text("\(chapterIndex + 1) / \(b.chapters.count)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("下一章") { nextChapter() }.disabled(chapterIndex >= b.chapters.count - 1)
                    }
                    Slider(value: Binding(get: { Double(paragraphIndex) }, set: { paragraphIndex = Int($0); saveProgress() }), in: 0...Double(max(paragraphs.count - 1, 0)), step: 1)
                }
                .padding(.horizontal).padding(.vertical, 8)
            } else {
                Text("没有章节").foregroundStyle(.secondary)
            }
        }
        .background(themeColor)
        .navigationTitle(book?.title ?? "阅读")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { showChapters = true } label: { Image(systemName: "list.bullet") }
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                Button { toggleSpeech() } label: { Image(systemName: isSpeaking ? "stop.circle" : "speaker.wave.2") }
                Button { pageMode.toggle(); pageIndex = 0 } label: { Image(systemName: pageMode ? "scroll" : "book.pages") }
                Button { showSettings = true } label: { Image(systemName: "textformat.size") }
                Button { addBookmark() } label: { Image(systemName: "bookmark") }
                Button { downloadAll() } label: { Image(systemName: downloadingAll ? "arrow.down.circle.fill" : "arrow.down.circle") }.disabled(downloadingAll || book?.kind != "web")
                Button { translateCurrent() } label: { Image(systemName: "translate") }.disabled(translating)
            }
        }
        .onAppear {
            readStart = Date()
            if let b = book { chapterIndex = b.chapterIndex; paragraphIndex = b.paragraphIndex; loadChapterIfNeeded() }
        }
        .onDisappear {
            if let start = readStart, var b = book {
                b.totalMinutes += max(0, Int(Date().timeIntervalSince(start) / 60))
                store.updateBook(b)
            }
            saveProgress(); speaker.stopSpeaking(at: .immediate)
        }
        .sheet(isPresented: $showChapters) {
            NavigationStack {
                List(book?.chapters.indices ?? 0..<0, id: \.self) { i in
                    Button(book?.chapters[i].title ?? "") { chapterIndex = i; paragraphIndex = 0; saveProgress(); loadChapterIfNeeded(); showChapters = false }
                }
                .navigationTitle("目录")
                .toolbar { Button("关闭") { showChapters = false } }
            }
        }
        .sheet(isPresented: $showSettings) {
            VStack(alignment: .leading, spacing: 16) {
                Text("字号：\(Int(store.fontSize))").font(.headline)
                Slider(value: $store.fontSize, in: 14...28, step: 1) { _ in store.save() }
                Text("行距：\(Int(store.lineSpacing))").font(.headline)
                Slider(value: $store.lineSpacing, in: 2...20, step: 1) { _ in store.save() }
                Picker("主题", selection: $store.theme) {
                    Text("白天").tag(0); Text("护眼").tag(1); Text("夜间").tag(2)
                }.pickerStyle(.segmented).onChange(of: store.theme) { _, _ in store.save() }
                Spacer()
            }.padding().presentationDetents([.medium])
        }
        .sheet(isPresented: $showTranslation) {
            NavigationStack {
                ScrollView { Text(translatedText).padding() }
                    .navigationTitle("翻译（本段）")
                    .toolbar { Button("关闭") { showTranslation = false } }
            }
        }
        .sheet(isPresented: $showSearch) {
            NavigationStack {
                VStack {
                    TextField("在本书里搜索", text: $searchText).textFieldStyle(.roundedBorder).padding()
                    List(searchResults, id: \.self) { line in
                        Button(line) {
                            if let i = paragraphs.firstIndex(of: line) { paragraphIndex = i; saveProgress() }
                            showSearch = false
                        }
                    }
                }
                .navigationTitle("书内搜索")
                .toolbar { Button("关闭") { showSearch = false } }
            }
        }
        .alert("加载失败", isPresented: .constant(!errorText.isEmpty)) {
            Button("好") { errorText = "" }
        } message: { Text(errorText) }
    }

    var themeColor: Color {
        switch store.theme { case 1: return Color(red: 0.98, green: 0.94, blue: 0.85); case 2: return Color(red: 0.12, green: 0.12, blue: 0.14); default: return Color.white }
    }
    var searchResults: [String] {
        guard !searchText.isEmpty else { return [] }
        return paragraphs.filter { $0.contains(searchText) }
    }
    func saveProgress() {
        guard var b = book else { return }
        b.chapterIndex = chapterIndex; b.paragraphIndex = paragraphIndex
        if !b.chapters.isEmpty { b.progress = Double(chapterIndex) / Double(b.chapters.count) }
        b.lastRead = Date()
        store.updateBook(b)
    }
    func loadChapterIfNeeded() {
        guard let b = book, chapterIndex < b.chapters.count else { return }
        let ch = b.chapters[chapterIndex]
        guard ch.text.hasPrefix("__URL__") else { return }
        loading = true
        Task {
            do {
                // find source by name stored in author field fallback: use first source
                let src = store.sources.first ?? LegadoSource.demoGutenberg
                let content = try await src.fetchChapterContent(ch)
                await MainActor.run {
                    if var nb = store.books.first(where: { $0.id == bookId }) {
                        nb.chapters[chapterIndex].text = content.isEmpty ? "（本章没有正文）" : content
                        store.updateBook(nb); loading = false
                    }
                }
            } catch {
                await MainActor.run { errorText = error.localizedDescription; loading = false }
            }
        }
    }
    func translateCurrent() {
        guard paragraphIndex < paragraphs.count else { return }
        translating = true
        let src = paragraphs[paragraphIndex]
        Task {
            do {
                let t = try await translateParagraph(src)
                await MainActor.run { translatedText = t; translating = false; showTranslation = true }
            } catch {
                await MainActor.run { translatedText = "翻译失败：\(error.localizedDescription)"; translating = false; showTranslation = true }
            }
        }
    }
    func downloadAll() {
        guard var b = book, b.kind == "web" else { return }
        downloadingAll = true
        let src = store.sources.first ?? LegadoSource.demoGutenberg
        Task {
            var updated = b
            for i in 0..<updated.chapters.count {
                if updated.chapters[i].text.hasPrefix("__URL__") {
                    if let content = try? await src.fetchChapterContent(updated.chapters[i]) {
                        updated.chapters[i].text = content.isEmpty ? "（本章没有正文）" : content
                    }
                }
            }
            await MainActor.run { store.updateBook(updated); downloadingAll = false }
            b = updated
        }
    }
    func prevChapter() { if chapterIndex > 0 { chapterIndex -= 1; paragraphIndex = 0; saveProgress(); loadChapterIfNeeded() } }
    func nextChapter() { if let b = book, chapterIndex < b.chapters.count - 1 { chapterIndex += 1; paragraphIndex = 0; saveProgress(); loadChapterIfNeeded() } }
    func addBookmark() {
        guard let b = book, chapterIndex < b.chapters.count, paragraphIndex < paragraphs.count else { return }
        store.addBookmark(Bookmark(bookId: b.id, chapterIndex: chapterIndex, paragraphIndex: paragraphIndex, snippet: String(paragraphs[paragraphIndex].prefix(40))))
    }
    func toggleSpeech() {
        if isSpeaking { speaker.stopSpeaking(at: .immediate); isSpeaking = false; return }
        guard let c = chapter else { return }
        let u = AVSpeechUtterance(string: c.title + "。" + c.text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.5
        speaker.speak(u); isSpeaking = true
    }
}

// MARK: - Manga

struct MangaView: View {
    @ObservedObject var store: BookStore
    var bookId: String
    @State private var page = 0
    @State private var stripMode = false
    @State private var enhanced = false
    @State private var ocrText = ""
    @State private var showOcr = false
    @State private var ocrRunning = false
    @State private var zoom: CGFloat = 1.0
    var book: LocalBook? { store.books.first { $0.id == bookId } }
    func image(_ name: String) -> UIImage? {
        guard let b = book else { return nil }
        let url = BookStore.filesDir.appendingPathComponent(b.id).appendingPathComponent((name as NSString).lastPathComponent)
        guard let d = try? Data(contentsOf: url), let ui = UIImage(data: d) else { return nil }
        return enhanced ? enhancedImage(ui) : ui
    }
    func runOcr() {
        guard let b = book, page < b.imageNames.count, let ui = image(b.imageNames[page]) else { return }
        ocrRunning = true
        Task {
            do {
                let t = try await ocrImage(ui)
                await MainActor.run { ocrText = t.isEmpty ? "（本页没有识别到文字）" : t; ocrRunning = false; showOcr = true }
            } catch {
                await MainActor.run { ocrText = "识别失败：\(error.localizedDescription)"; ocrRunning = false; showOcr = true }
            }
        }
    }
    var body: some View {
        VStack {
            if let b = book {
                if stripMode {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(b.imageNames, id: \.self) { name in
                                if let ui = image(name) { Image(uiImage: ui).resizable().scaledToFit() }
                            }
                        }
                    }
                } else {
                    TabView(selection: $page) {
                        ForEach(b.imageNames.indices, id: \.self) { i in
                            if let ui = image(b.imageNames[i]) {
                                Image(uiImage: ui).resizable().scaledToFit().scaleEffect(zoom).gesture(MagnificationGesture().onChanged { zoom = max(1.0, min(4.0, $0)) }).tag(i)
                            }
                        }
                    }.tabViewStyle(.page(indexDisplayMode: .automatic))
                }
                HStack {
                    Text("\(page + 1) / \(b.imageNames.count)").font(.caption)
                    Spacer()
                    Button(enhanced ? "原图" : "增强") { enhanced.toggle() }
                    Button(stripMode ? "单页模式" : "条漫模式") { stripMode.toggle() }
                    Button(ocrRunning ? "识别中…" : "本页 OCR") { runOcr() }.disabled(ocrRunning)
                }.padding()
            }
        }
        .sheet(isPresented: $showOcr) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView { Text(ocrText).padding() }
                    Button("存为 TXT 书") {
                        var nb = LocalBook(title: (book?.title ?? "OCR") + "（OCR）", fileName: "ocr.txt", kind: "txt")
                        nb.chapters = [BookChapter(title: "OCR 结果", text: ocrText)]
                        store.updateBook(nb); showOcr = false
                    }.buttonStyle(.borderedProminent)
                    Spacer()
                }
                .navigationTitle("OCR 结果")
                .toolbar { Button("关闭") { showOcr = false } }
            }
        }
        .navigationTitle(book?.title ?? "漫画")
        .onAppear { if let b = book { page = b.paragraphIndex } }
        .onDisappear { if var b = book { b.paragraphIndex = page; store.updateBook(b) } }
    }
}

// MARK: - Sources

struct SourceView: View {
    @ObservedObject var store: BookStore
    @State private var key = ""
    @State private var results: [SourceBook] = []
    @State private var searching = false
    @State private var selectedSourceIndex = 0
    @State private var showImport = false
    @State private var importText = ""
    @State private var importError = ""
    @State private var selectedResult: SourceBook?
    @State private var detailChapters: [BookChapter] = []
    @State private var loadingDetail = false

    var body: some View {
        NavigationStack {
            VStack {
                Picker("书源", selection: $selectedSourceIndex) {
                    ForEach(store.enabledSources.indices, id: \.self) { i in Text(store.enabledSources[i].bookSourceName).tag(i) }
                }.pickerStyle(.menu).padding(.horizontal)
                HStack {
                    TextField("搜书名 / 作者", text: $key).textFieldStyle(.roundedBorder)
                    Button("搜索") { search() }.disabled(key.isEmpty || searching)
                }.padding(.horizontal)
                if searching { ProgressView() }
                List(results) { r in
                    Button {
                        selectedResult = r; loadDetail(r)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.title).font(.headline)
                            if !r.author.isEmpty { Text(r.author).font(.caption).foregroundStyle(.secondary) }
                            if !r.intro.isEmpty { Text(r.intro).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                        }
                    }
                }
                if results.isEmpty && !searching {
                    Text("内置源是公版书 Gutenberg（可正常搜索英文公版书）。中文书源请点右上角导入你自己的 Legado JSON 书源，导入后即可搜索。")
                        .font(.footnote).foregroundStyle(.secondary).padding()
                }
            }
            .navigationTitle("书源")
            .toolbar {
                Button("导入书源") { showImport = true }
            }
            .sheet(isPresented: $showImport) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("粘贴 Legado JSON 书源：单个对象、整个数组、订阅链接都可以；数组里个别格式不对的条目会跳过，不会整批失败。").font(.footnote).foregroundStyle(.secondary)
                        TextEditor(text: $importText).border(Color.gray.opacity(0.3))
                        if !importError.isEmpty { Text(importError).foregroundStyle(.red).font(.footnote) }
                        Button("导入") { importSource() }
                        Spacer()
                    }.padding()
                    .navigationTitle("导入书源")
                    .toolbar { Button("关闭") { showImport = false } }
                }
            }
            .sheet(item: $selectedResult) { r in
                NavigationStack {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(r.title).font(.title2).bold()
                        if !r.author.isEmpty { Text(r.author).foregroundStyle(.secondary) }
                        if !r.intro.isEmpty { Text(r.intro).font(.body) }
                        if loadingDetail { ProgressView("正在拉取目录…") }
                        else { Text("目录 \(detailChapters.count) 章").font(.caption).foregroundStyle(.secondary) }
                        Button("加入书架") {
                            var book = LocalBook(title: r.title, author: r.author, coverUrl: r.cover, fileName: r.title + ".web", kind: "web")
                            book.chapters = detailChapters
                            store.updateBook(book)
                            selectedResult = nil
                        }.buttonStyle(.borderedProminent).disabled(detailChapters.isEmpty)
                        List(detailChapters.prefix(50)) { c in Text(c.title).font(.caption) }
                    }.padding()
                    .navigationTitle("书籍详情")
                    .toolbar { Button("关闭") { selectedResult = nil } }
                }
            }
        }
    }
    func search() {
        guard selectedSourceIndex < store.enabledSources.count else { return }
        searching = true
        let src = store.enabledSources[selectedSourceIndex]
        Task {
            do {
                let res = try await src.search(key: key)
                await MainActor.run { results = res; searching = false }
            } catch {
                await MainActor.run { results = []; searching = false }
            }
        }
    }
    func loadDetail(_ r: SourceBook) {
        guard selectedSourceIndex < store.enabledSources.count else { return }
        loadingDetail = true; detailChapters = []
        let src = store.enabledSources[selectedSourceIndex]
        Task {
            do {
                let chs = try await src.fetchChapters(book: r)
                await MainActor.run { detailChapters = chs; loadingDetail = false }
            } catch {
                await MainActor.run { loadingDetail = false }
            }
        }
    }
    func importSource() {
        let trimmed = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http") {
            // Pasted a subscription link, not JSON: fetch it like a network import.
            importError = "正在拉取链接…"
            Task {
                do {
                    let arr = try await importSourcesFromURL(trimmed)
                    await MainActor.run {
                        if arr.isEmpty { importError = "这个链接里没有解析到书源：请确认它是返回 Legado 书源 JSON 的直链（GitHub blob 页已自动转 raw，仍失败就换 raw 链接）" }
                        else { store.sources.append(contentsOf: arr); store.save(); showImport = false; importText = ""; importError = "" }
                    }
                } catch {
                    await MainActor.run { importError = "拉取失败：\(error.localizedDescription)" }
                }
            }
            return
        }
        let result = importSourcesDetailed(importText)
        if result.sources.isEmpty {
            importError = "这个内容解析失败：请粘贴单个 Legado 书源 JSON、书源数组，或者一个订阅链接；不是 JSON 的文本、只有网址的页面、带 HTML 的页面都会被自动提取 JSON，仍失败就是内容本身不是书源"
        } else {
            store.sources.append(contentsOf: result.sources); store.save(); showImport = false; importText = ""
            if result.skipped > 0 { importError = "已导入 \(result.sources.count) 个，跳过 \(result.skipped) 个格式不对的条目" }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var store: BookStore
    @State private var backupURL: URL?
    @State private var showBackup = false
    @State private var importingBackup = false
    @State private var backupError = ""
    @State private var showBackupError = false
    var body: some View {
        NavigationStack {
            List {
                Section("阅读") {
                    HStack { Text("字号"); Spacer(); Text("\(Int(store.fontSize))") }
                    Slider(value: $store.fontSize, in: 14...28, step: 1) { _ in store.save() }
                    Picker("主题", selection: $store.theme) {
                        Text("白天").tag(0); Text("护眼").tag(1); Text("夜间").tag(2)
                    }.onChange(of: store.theme) { _, _ in store.save() }
                }
                Section("书架统计") {
                    Text("本地书：\(store.books.count) 本")
                    Text("书签：\(store.bookmarks.count) 条")
                    Text("书源：\(store.sources.count) 个")
                }
                Section("书签") {
                    ForEach(store.bookmarks) { bm in
                        VStack(alignment: .leading) {
                            Text(bm.snippet).lineLimit(2)
                            Text("第 \(bm.chapterIndex + 1) 章").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in store.bookmarks.remove(atOffsets: idx); store.save() }
                }
                Section("书源") {
                    NavigationLink("书源管理（启用/删除/网络导入/扫码导入）") { SourceManagementView(store: store) }
                }
                Section("替换净化") {
                    ForEach(store.replaceRules) { rule in
                        NavigationLink {
                            ReplaceRuleEditorView(store: store, ruleId: rule.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(rule.name).font(.headline)
                                    Text(rule.pattern).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text("→ \(rule.replacement)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(get: { rule.enabled }, set: { v in
                                    if let i = store.replaceRules.firstIndex(where: { $0.id == rule.id }) { store.replaceRules[i].enabled = v; store.save() }
                                })).labelsHidden()
                            }
                        }
                    }
                    .onDelete { idx in store.replaceRules.remove(atOffsets: idx); store.save() }
                    Button("添加替换规则") {
                        store.replaceRules.append(ReplaceRule(name: "新规则", pattern: "", replacement: "")); store.save()
                    }
                    Text("替换规则是正则表达式，显示和下载正文时都会自动净化（去广告、去“本章未完”等）。规则名和正则可以在规则列表里直接改：点规则行进入编辑。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("备份（.ciallo）") {
                    Button("导出备份") { exportBackup() }
                    Button("导入备份") { importingBackup = true }
                    Text("备份是单个 .ciallo 文件（其实是 ZIP）：含书架、书签、书源和本地书文件，换机或重装后导入即可恢复。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("说明") {
                    Text("自用版，不上架。TXT / EPUB / DOCX / FB2 / MOBI / AZW3 / PDF / CBZ、书内搜索、书签、朗读、进度与阅读时长、Legado 书源、整本下载与导出 EPUB / TXT、漫画增强与缩放、图片 OCR、备份互传都已实现。注意：带 DRM 的加密书读不了；漫画增强是本机滤镜，不是 MangaJaNai AI 画质模型；在线翻译需要翻译服务接口，本版未接。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showBackup) { if let url = backupURL { ShareLink("导出备份", item: url) } }
            .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.data]) { result in
                switch result {
                case .success(let url): importBackup(url)
                case .failure(let e): backupError = e.localizedDescription; showBackupError = true
                }
            }
            .alert("导入备份失败", isPresented: $showBackupError) { Button("好", role: .cancel) {} } message: { Text(backupError) }
        }
    }
    func exportBackup() {
        var files: [(name: String, data: Data)] = []
        if let d = try? JSONEncoder().encode(store.books) { files.append((name: "books.json", data: d)) }
        let meta = BookStore.Meta(bookmarks: store.bookmarks, sources: store.sources, fontSize: store.fontSize, lineSpacing: store.lineSpacing, theme: store.theme)
        if let d = try? JSONEncoder().encode(meta) { files.append((name: "meta.json", data: d)) }
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: BookStore.filesDir, includingPropertiesForKeys: nil) {
            for url in items {
                if url.hasDirectoryPath {
                    if let subs = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                        for s in subs { if let d = try? Data(contentsOf: s) { files.append((name: "files/\(url.lastPathComponent)/\(s.lastPathComponent)", data: d)) } }
                    }
                } else if let d = try? Data(contentsOf: url) { files.append((name: "files/\(url.lastPathComponent)", data: d)) }
            }
        }
        let zip = writeStoredZip(files)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CialloReaderIOS-backup.ciallo")
        try? zip.write(to: url)
        backupURL = url; showBackup = true
    }
    func importBackup(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { backupError = "读不到备份文件"; showBackupError = true; return }
        let files = unzipToMemory(data)
        guard let booksData = files["books.json"], let books = try? JSONDecoder().decode([LocalBook].self, from: booksData) else {
            backupError = "这不是有效的 .ciallo 备份（里面没有 books.json）"; showBackupError = true; return
        }
        if let d = try? JSONEncoder().encode(books) { try? d.write(to: BookStore.booksURL) }
        if let metaData = files["meta.json"] { try? metaData.write(to: BookStore.metaURL) }
        for (name, d) in files where name.hasPrefix("files/") {
            let rel = String(name.dropFirst(6))
            let dest = BookStore.filesDir.appendingPathComponent(rel)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: dest)
        }
        store.load()
    }
}
