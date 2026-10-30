import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
    @StateObject private var store = BookStore()
    var body: some View {
        TabView {
            BookshelfView(store: store)
                .tabItem { Label("书架", systemImage: "books.vertical.fill") }
            DiscoveryView(store: store)
                .tabItem { Label("发现", systemImage: "sparkles") }
            SourceView(store: store)
                .tabItem { Label("书源", systemImage: "magnifyingglass") }
            SettingsView(store: store)
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(AppTheme.accent)
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
    @State private var searchText = ""
    @State private var sortMode = 0 // 0 最近阅读, 1 书名, 2 进度
    @State private var viewMode = 0 // 0 网格, 1 列表
    @State private var showFavoritesOnly = false
    @State private var selecting = false
    @State private var selectedIds: Set<String> = []

    var filteredBooks: [LocalBook] {
        var list = store.books
        if showFavoritesOnly {
            list = list.filter { $0.favorite }
        }
        if !searchText.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.author.localizedCaseInsensitiveContains(searchText) || $0.sourceName.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortMode {
        case 1: list.sort { $0.title < $1.title }
        case 2: list.sort { $0.progress > $1.progress }
        default: list.sort { $0.lastRead > $1.lastRead }
        }
        return list
    }

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
                if selecting && !selectedIds.isEmpty {
                    HStack {
                        Text("已选 \(selectedIds.count) 本").font(.subheadline).bold()
                        Spacer()
                        Button("删除所选", role: .destructive) {
                            for id in selectedIds { if let b = store.books.first(where: { $0.id == id }) { store.deleteBook(b) } }
                            selectedIds.removeAll(); selecting = false
                        }
                    }.padding(.horizontal)
                }
                Picker("排序", selection: $sortMode) {
                    Text("最近阅读").tag(0); Text("书名").tag(1); Text("进度").tag(2)
                }.pickerStyle(.segmented).padding(.horizontal)
                if let current = store.books.max(by: { $0.lastRead < $1.lastRead }) {
                    Button {
                        if current.kind == "cbz" || current.kind == "comic" { selectedManga = current } else { selectedBook = current }
                    } label: {
                        HStack(spacing: 14) {
                            if !current.coverUrl.isEmpty, let url = URL(string: current.coverUrl) {
                                AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { BookCover(title: current.title, width: 70) }
                                    .frame(width: 70, height: 99).clipped().cornerRadius(10)
                            } else {
                                BookCover(title: current.title, width: 70)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("继续阅读").font(.caption).foregroundStyle(.secondary)
                                Text(current.title).font(.headline).lineLimit(2)
                                if !current.author.isEmpty { Text(current.author).font(.caption).foregroundStyle(.secondary) }
                                if current.chapterIndex < current.chapters.count { Text(current.chapters[current.chapterIndex].title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                ProgressView(value: current.progress)
                                Text("已读 \(Int(current.progress * 100))% · \(current.chapters.count) 章").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding().background(.ultraThinMaterial).cornerRadius(16)
                    }.buttonStyle(.plain).padding(.horizontal)
                }
                if viewMode == 1 {
                    bookListView
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    ForEach(filteredBooks) { book in
                        Button {
                            if selecting {
                                if selectedIds.contains(book.id) { selectedIds.remove(book.id) } else { selectedIds.insert(book.id) }
                            } else if book.kind == "cbz" || book.kind == "comic" { selectedManga = book } else { selectedBook = book }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .topTrailing) {
                                    if !book.coverUrl.isEmpty, let url = URL(string: book.coverUrl) {
                                        AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { gridCover(book.title) }
                                            .frame(height: 150).clipped().cornerRadius(10)
                                    } else {
                                        gridCover(book.title)
                                    }
                                    if selecting {
                                        Image(systemName: selectedIds.contains(book.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedIds.contains(book.id) ? AppTheme.accent : .white).padding(4)
                                            .background(Circle().fill(Color.black.opacity(0.3)))
                                    }
                                }
                                Text(book.title).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                                if !book.author.isEmpty { Text(book.author).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                                if book.chapterIndex < book.chapters.count { Text(book.chapters[book.chapterIndex].title).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                                Text(book.sourceName.isEmpty ? "\(book.kind.uppercased()) · \(Int(book.progress * 100))%" : "\(book.sourceName) · \(Int(book.progress * 100))%").font(.caption2).foregroundStyle(.secondary)
                                ProgressView(value: book.progress)
                            }
                        }
                        .contextMenu {
                            Button(book.favorite ? "取消收藏" : "收藏") {
                                if let i = store.books.firstIndex(where: { $0.id == book.id }) { store.books[i].favorite.toggle(); store.save() }
                            }
                            Button("导出 TXT") { exportBook(book) }
                            Button("导出 EPUB") { exportEpubBook(book) }
                            Button(role: .destructive) { store.deleteBook(book) } label: { Text("删除") }
                        }
                    }
                }.padding()
                }
                if filteredBooks.isEmpty && !store.books.isEmpty {
                    Text("没有匹配的书，换个关键词试试。").font(.footnote).foregroundStyle(.secondary).padding()
                }
            }
            .sheet(isPresented: $showExport) { if let url = exportURL { ShareLink("导出", item: url) } }
            .navigationTitle("书架")
            .searchable(text: $searchText, prompt: "搜本地书架（书名 / 作者 / 书源）")
            .toolbar {
                if selecting {
                    Button("取消") { selecting = false; selectedIds.removeAll() }
                } else {
                    Button("多选") { selecting = true }
                    Button { showFavoritesOnly.toggle() } label: {
                        Image(systemName: showFavoritesOnly ? "star.fill" : "star")
                    }
                    Button { viewMode = viewMode == 0 ? 1 : 0 } label: {
                        Image(systemName: viewMode == 0 ? "list.bullet" : "square.grid.2x2")
                    }
                }
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

    @ViewBuilder
    var bookListView: some View {
        VStack(spacing: 0) {
            ForEach(filteredBooks) { book in
                Button {
                    if selecting {
                        if selectedIds.contains(book.id) { selectedIds.remove(book.id) } else { selectedIds.insert(book.id) }
                    } else if book.kind == "cbz" || book.kind == "comic" { selectedManga = book } else { selectedBook = book }
                } label: {
                    HStack(spacing: 12) {
                        if !book.coverUrl.isEmpty, let url = URL(string: book.coverUrl) {
                            AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { BookCover(title: book.title, width: 46) }
                                .frame(width: 46, height: 65).clipped().cornerRadius(6)
                        } else {
                            BookCover(title: book.title, width: 46)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title).font(.subheadline).lineLimit(1)
                            if !book.author.isEmpty { Text(book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            HStack(spacing: 6) {
                                if book.totalMinutes > 0 { Text("读 \(book.totalMinutes) 分钟").font(.caption2).foregroundStyle(.secondary) }
                                Text("\(Int(book.progress * 100))%").font(.caption2).foregroundStyle(.secondary)
                            }
                            ProgressView(value: book.progress)
                        }
                        Spacer()
                        if selecting {
                            Image(systemName: selectedIds.contains(book.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(.blue)
                        } else if book.favorite {
                            Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(book.favorite ? "取消收藏" : "收藏") {
                        if let i = store.books.firstIndex(where: { $0.id == book.id }) { store.books[i].favorite.toggle(); store.save() }
                    }
                    Button("导出 TXT") { exportBook(book) }
                    Button("导出 EPUB") { exportEpubBook(book) }
                    Button(role: .destructive) { store.deleteBook(book) } label: { Text("删除") }
                }
                Divider()
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    func gridCover(_ title: String) -> some View {
        GridBookCover(title: title)
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
        var book = LocalBook(title: "示例书", author: "ReaderPro", fileName: "sample.txt", kind: "txt")
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


// MARK: - Manga（已迁移到 MangaView.swift）

// MARK: - Sources (Legado-style multi-source search)

struct SourceView: View {
    @ObservedObject var store: BookStore
    @State private var key = ""
    @State private var results: [SourceBook] = []
    @State private var allResults: [SourceBook] = []
    @State private var searching = false
    @State private var searchedCount = 0
    @State private var showImport = false
    @State private var importText = ""
    @State private var importError = ""
    @State private var selectedResult: SourceBook?
    @State private var detailChapters: [BookChapter] = []
    @State private var loadingDetail = false
    @State private var detailError = ""
    @State private var detailAlternatives: [SourceBook] = []
    @State private var detailAltIndex = 0
    @State private var detailIsComic = false

    var body: some View {
        NavigationStack {
            VStack {
                HStack {
                    TextField("搜书名 / 作者（多源并发）", text: $key).textFieldStyle(.roundedBorder)
                    Button("搜索") { search() }.disabled(key.isEmpty || searching)
                }.padding(.horizontal)
                Text("书源库：\(store.sources.count) 个，启用 \(store.enabledSources.count) 个。导入后先看这个数：1000 个的包导入完这里就该是 1000 左右，不是 18。").font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
                if searching {
                    ProgressView("正在多源搜索… 已搜 \(store.enabledSources.count) 个启用源")
                } else if searchedCount > 0 {
                    Text("共 \(searchedCount) 个启用源，\(results.count) 本（只留标题/作者含关键词的，点开可换源）").font(.caption).foregroundStyle(.secondary)
                }
                List(results) { r in
                    Button {
                        selectedResult = r; loadDetail(r)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.title).font(.headline)
                            HStack {
                                if !r.author.isEmpty { Text(r.author).font(.caption).foregroundStyle(.secondary) }
                                if !r.sourceName.isEmpty { Text(r.sourceName).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(Color.blue.opacity(0.15)).cornerRadius(6) }
                            }
                            if !r.intro.isEmpty { Text(r.intro).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                        }
                    }
                }
                if results.isEmpty && !searching {
                    Text("没有自带书源。点右上角导入你自己的 Legado JSON 书源（单个、数组或订阅链接都行，导入即启用），然后在这里一次搜全部启用源；删掉的书源不会再自动回来。")
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
                        Text("粘贴 Legado JSON 书源：单个对象、整个数组、订阅链接都可以；数组里个别格式不对的条目会跳过，不会整批失败。导入的书源默认全部启用。").font(.footnote).foregroundStyle(.secondary)
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
                        if !r.cover.isEmpty, let url = URL(string: r.cover) {
                            AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                                .frame(width: 110, height: 150).cornerRadius(10).clipped()
                        }
                        Text(r.title).font(.title2).bold()
                        if !r.author.isEmpty { Text(r.author).foregroundStyle(.secondary) }
                        if !r.sourceName.isEmpty { Text("书源：\(r.sourceName)").font(.caption).foregroundStyle(.secondary) }
                        if !r.intro.isEmpty { Text(r.intro).font(.body) }
                        if detailAlternatives.count > 1 {
                            Picker("换源", selection: $detailAltIndex) {
                                ForEach(detailAlternatives.indices, id: \.self) { i in Text(detailAlternatives[i].sourceName.isEmpty ? "源 \(i + 1)" : detailAlternatives[i].sourceName).tag(i) }
                            }.pickerStyle(.menu)
                            .onChange(of: detailAltIndex) { _, v in
                                if v < detailAlternatives.count { selectedResult = detailAlternatives[v]; loadDetail(detailAlternatives[v]) }
                            }
                        }
                        if loadingDetail { ProgressView("正在拉取目录…") }
                        else { Text("目录 \(detailChapters.count) 章").font(.caption).foregroundStyle(.secondary) }
                        if !detailError.isEmpty { Text(detailError).font(.footnote).foregroundStyle(.red) }
                        if detailChapters.isEmpty && !loadingDetail {
                            Text("目录为空时：先点“换源”换一个同名结果再试——原书源的目录规则可能用了本版不支持的 JS/XPath，或该站拒绝了手机访问；换源后仍为空，把书名+书源名发我，我按那个源的真规则修。").font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("加入书架") {
                            var book = LocalBook(title: r.title, author: r.author, coverUrl: r.cover, sourceName: r.sourceName, sourceUrl: r.sourceUrl, fileName: r.title + ".web", kind: detailIsComic ? "comic" : "web")
                            book.chapters = detailChapters
                            store.updateBook(book)
                            selectedResult = nil
                        }.buttonStyle(.borderedProminent).disabled(detailChapters.isEmpty)
                        List(detailChapters.prefix(100)) { c in Text(c.title).font(.caption) }
                    }.padding()
                    .navigationTitle("书籍详情")
                    .toolbar { Button("关闭") { selectedResult = nil } }
                }
            }
        }
    }
    func search() {
        let enabled = store.enabledSources
        guard !enabled.isEmpty else { results = []; allResults = []; return }
        searching = true; searchedCount = 0
        let k = key
        Task {
            let raw = await searchAllRawSources(enabled, key: k)
            var seen = Set<String>(); var deduped: [SourceBook] = []
            for b in raw {
                let kk = dedupeKey(b)
                if seen.contains(kk) { continue }
                seen.insert(kk); deduped.append(b)
            }
            await MainActor.run { allResults = raw; results = deduped; searchedCount = enabled.count; searching = false }
        }
    }
    func loadDetail(_ r: SourceBook) {
        loadingDetail = true; detailChapters = []; detailError = ""
        detailAlternatives = allResults.filter { dedupeKey($0) == dedupeKey(r) }
        if detailAlternatives.isEmpty { detailAlternatives = [r] }
        detailAltIndex = detailAlternatives.firstIndex(where: { $0.url == r.url && $0.sourceName == r.sourceName }) ?? 0
        guard let src = store.sources.first(where: { $0.bookSourceName == r.sourceName && ($0.bookSourceUrl == r.sourceUrl || r.sourceUrl.isEmpty) }) ?? store.sources.first(where: { $0.bookSourceName == r.sourceName }) else {
            loadingDetail = false; detailError = "找不到这个书源（可能已被删除），请重新搜索。"; return
        }
        detailIsComic = src.isComic
        Task {
            do {
                var info = r
                // BookInfo: fetch richer detail when the source provides it, but never lose the search result
                if let fetched = try? await src.fetchBookInfo(book: r) { info = fetched }
                let chs = try await src.fetchChapters(book: info)
                await MainActor.run {
                    detailChapters = chs; loadingDetail = false
                    if chs.isEmpty { detailError = "该源返回了 0 章：目录规则不匹配或该站拒绝访问，点“换源”换一个同名结果再试。" }
                }
            } catch {
                await MainActor.run { loadingDetail = false; detailError = "拉取目录失败：\(error.localizedDescription)，换源或换个网络再试。" }
            }
        }
    }
    func importSource() {
        let trimmed = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http") {
            importError = "正在拉取链接…"
            Task {
                do {
                    let arr = try await importSourcesFromURL(trimmed)
                    await MainActor.run {
                        if arr.isEmpty { importError = "这个链接里没有解析到书源：请确认它是返回 Legado 书源 JSON 的直链（GitHub blob 页已自动转 raw，仍失败就换 raw 链接）" }
                        else {
                            let enabled = arr.map { var x = $0; x.enabled = true; return x }
                            store.sources.append(contentsOf: enabled); store.save(); showImport = false; importText = ""; importError = ""
                        }
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
            let enabled = result.sources.map { var x = $0; x.enabled = true; return x }
            store.sources.append(contentsOf: enabled); store.save(); showImport = false; importText = ""
            if result.skipped > 0 { importError = "已导入 \(enabled.count) 个，跳过 \(result.skipped) 个格式不对的条目" }
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
    @State private var webdavWorking = false
    @State private var webdavMessage = ""
    var body: some View {
        NavigationStack {
            List {
                Section("阅读") {
                    HStack { Text("字号"); Spacer(); Text("\(Int(store.fontSize))") }
                    Slider(value: $store.fontSize, in: 12...32, step: 1) { _ in store.save() }
                    Picker("主题", selection: $store.theme) {
                        ForEach(readerThemes) { t in Text(t.name).tag(t.id) }
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
                Section("内置浏览器") {
                    NavigationLink("打开浏览器（看网页 / 在线视频小窗）") { BrowserView() }
                }
                Section("书源") {
                    NavigationLink("书源管理（启用/删除/网络导入/扫码导入）") { SourceManagementView(store: store) }
                    NavigationLink("订阅源管理（源仓库导航/网络导入）") { RssSourceManagementView(store: store) }
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
                Section("WebDAV 云同步") {
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
                    if webdavWorking {
                        ProgressView()
                    }
                    HStack {
                        Button("备份到云端") { backupToWebDAV() }.disabled(webdavWorking || store.webdavURL.isEmpty)
                        Button("从云端恢复") { restoreFromWebDAV() }.disabled(webdavWorking || store.webdavURL.isEmpty)
                    }
                    if !webdavMessage.isEmpty {
                        Text(webdavMessage).font(.footnote).foregroundStyle(webdavMessage.contains("成功") || webdavMessage.contains("完成") ? Color.secondary : Color.red)
                    }
                    Text("地址填 WebDAV 根地址（如坚果云 https://dav.jianguoyun.com/dav/ 或 Nextcloud https://你的域名/remote.php/dav/files/用户名/），远程路径如 /ReaderPro/backup.ciallo。备份就是一个 .ciallo 文件上传到该路径。")
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
