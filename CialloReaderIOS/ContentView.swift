import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
    @StateObject private var store = BookStore()
    var body: some View {
        TabView {
            BookshelfView(store: store)
                .tabItem { Label("书架", systemImage: "books.vertical") }
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
            List {
                if store.books.isEmpty {
                    Section {
                        Text("书架是空的。点右上角 + 导入 TXT / EPUB / CBZ，也可以先载入示例书测试阅读器。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("载入示例书") { addSample() }
                    }
                }
                ForEach(store.books) { book in
                    Button {
                        if book.kind == "cbz" { selectedManga = book } else { selectedBook = book }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title).font(.headline).lineLimit(2)
                            HStack {
                                Text(book.kind.uppercased()).font(.caption).foregroundStyle(.secondary)
                                if !book.author.isEmpty { Text(book.author).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Text("\(book.chapters.count) 章 · \(Int(book.progress * 100))%").font(.caption).foregroundStyle(.secondary)
                            }
                            ProgressView(value: book.progress)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.deleteBook(book) } label: { Label("删除", systemImage: "trash") }
                        Button { exportBook(book) } label: { Label("导出TXT", systemImage: "square.and.arrow.up") }
                    }
                    .sheet(isPresented: $showExport) { if let url = exportURL { ShareLink("导出 TXT", item: url) } }
                }
            }
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
        } else if ext == "cbz" || ext == "zip" {
            if let (book, files) = parseCbz(data, fileName: fileName) {
                let dir = BookStore.filesDir.appendingPathComponent(book.id)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (name, d) in files { try? d.write(to: dir.appendingPathComponent((name as NSString).lastPathComponent)) }
                store.updateBook(book)
            } else { errorText = "这个 CBZ 里没有找到图片"; showError = true }
        } else {
            errorText = "只支持 TXT、EPUB、CBZ（ZIP 漫画包）"; showError = true
        }
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
    private let speaker = AVSpeechSynthesizer()

    var book: LocalBook? { store.books.first { $0.id == bookId } }
    var chapter: BookChapter? {
        guard let b = book, chapterIndex < b.chapters.count else { return nil }
        return b.chapters[chapterIndex]
    }
    var paragraphs: [String] {
        guard let c = chapter else { return [] }
        return c.text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                ProgressView("正在加载章节…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let b = book, let c = chapter {
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
                Button { showSettings = true } label: { Image(systemName: "textformat.size") }
                Button { addBookmark() } label: { Image(systemName: "bookmark") }
            }
        }
        .onAppear {
            if let b = book { chapterIndex = b.chapterIndex; paragraphIndex = b.paragraphIndex; loadChapterIfNeeded() }
        }
        .onDisappear { saveProgress(); speaker.stopSpeaking(at: .immediate) }
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
    var book: LocalBook? { store.books.first { $0.id == bookId } }
    func image(_ name: String) -> UIImage? {
        guard let b = book else { return nil }
        let url = BookStore.filesDir.appendingPathComponent(b.id).appendingPathComponent((name as NSString).lastPathComponent)
        guard let d = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: d)
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
                                Image(uiImage: ui).resizable().scaledToFit().tag(i)
                            }
                        }
                    }.tabViewStyle(.page(indexDisplayMode: .automatic))
                }
                HStack {
                    Text("\(page + 1) / \(b.imageNames.count)").font(.caption)
                    Spacer()
                    Button(stripMode ? "单页模式" : "条漫模式") { stripMode.toggle() }
                }.padding()
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
                    ForEach(store.sources.indices, id: \.self) { i in Text(store.sources[i].bookSourceName).tag(i) }
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
                        Text("粘贴 Legado JSON 书源（bookSourceName、searchUrl、ruleSearch 等字段）").font(.footnote).foregroundStyle(.secondary)
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
                            var book = LocalBook(title: r.title, author: r.author, fileName: r.title + ".web", kind: "web")
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
        guard selectedSourceIndex < store.sources.count else { return }
        searching = true
        let src = store.sources[selectedSourceIndex]
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
        guard selectedSourceIndex < store.sources.count else { return }
        loadingDetail = true; detailChapters = []
        let src = store.sources[selectedSourceIndex]
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
        guard let data = importText.data(using: .utf8) else { return }
        if let src = try? JSONDecoder().decode(LegadoSource.self, from: data) {
            store.sources.append(src); store.save(); showImport = false; importText = ""
        } else {
            importError = "这个 JSON 解析失败：请确认是单个 Legado 书源对象（含 bookSourceName、searchUrl）"
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var store: BookStore
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
                Section("说明") {
                    Text("自用版，不上架。TXT / EPUB / CBZ 本地阅读、书内搜索、书签、朗读、进度记忆、Legado 书源搜索与目录拉取、整本导出 TXT 已实现；MOBI / AZW3、PDF、OCR、画质增强、互传备份暂未实现，导入这类文件会提示不支持。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
}
