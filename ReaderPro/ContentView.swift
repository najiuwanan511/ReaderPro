import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
    @StateObject private var store = BookStore()
    @EnvironmentObject private var network: NetworkBootstrap
    var body: some View {
        TabView {
            BookshelfView(store: store)
                .tabItem { Label("书架", systemImage: "books.vertical.fill") }
            DiscoveryView(store: store)
                .tabItem { Label("发现", systemImage: "safari") }
            RssSubscribeView(store: store)
                .tabItem { Label("订阅", systemImage: "bookmark") }
            SettingsView(store: store)
                .tabItem { Label("我的", systemImage: "person.fill") }
        }
        .tint(AppTheme.accent)
        .toolbarBackground(AppTheme.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .overlay(alignment: .top) { networkBanner }
    }

    // 启动即联网检测：断网时在顶部给出提示（联网后自动消失）
    @ViewBuilder
    private var networkBanner: some View {
        if network.status == .offline {
            VStack {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                    Text("未连接网络，书源与搜索暂不可用")
                        .font(.footnote)
                    Spacer()
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.95))
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: network.status)
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
    @State private var selectedAudio: LocalBook?
    @State private var selectedVideo: LocalBook?
    @State private var exportURL: URL?
    @State private var showExport = false
    @State private var searchText = ""
    @State private var sourceResults: [SourceBook] = []
    @State private var sourceSearching = false
    @State private var sourceSearchedKey = ""
    @AppStorage("shelfSortMode") private var sortMode = 0 // 0 最近阅读, 1 书名, 2 进度
    @AppStorage("shelfViewMode") private var viewMode = 2 // 0 封面叠字, 1 列表, 2 封面下方书名
    @State private var selectedGroup = 0
    @State private var shelfResult: SourceBook?
    @State private var selecting = false
    @State private var selectedIds: Set<String> = []

    var filteredBooks: [LocalBook] {
        var list = store.books
        if selectedGroup == 1 { list = list.filter { $0.favorite } }
        else if selectedGroup >= 2, groups.indices.contains(selectedGroup) {
            list = list.filter { $0.group == groups[selectedGroup] }
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

    private var groups: [String] {
        ["全部", "收藏"] + Set(store.books.map(\.group).filter { !$0.isEmpty }).sorted()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.books.isEmpty {
                    emptyShelf
                }
                if selecting && !selectedIds.isEmpty {
                    HStack {
                        Text("已选 \(selectedIds.count) 本").font(.subheadline).bold()
                        Spacer()
                        Button("删除所选", role: .destructive) {
                            for id in selectedIds { if let b = store.books.first(where: { $0.id == id }) { store.deleteBook(b) } }
                            selectedIds.removeAll(); selecting = false
                        }
                    }.padding(.horizontal, 12).padding(.top, 12)
                }
                if viewMode == 1 {
                    bookListView
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 14) {
                    ForEach(filteredBooks) { book in
                        Button {
                            if selecting {
                                if selectedIds.contains(book.id) { selectedIds.remove(book.id) } else { selectedIds.insert(book.id) }
                            } else { openBook(book) }
                        } label: {
                            ShelfGridCell(title: book.title, coverUrl: book.coverUrl, unreadCount: book.unreadCount, selecting: selecting, selected: selectedIds.contains(book.id), titleBelow: viewMode == 2)
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
                    }
                }.padding(.horizontal)
                }
                if filteredBooks.isEmpty && !store.books.isEmpty {
                    Text("没有匹配的书，换个关键词试试。").font(.footnote).foregroundStyle(.secondary).padding()
                }
                // Search results share the directory and direct reading flow with discovery.
                if !searchText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            sourceSearching = true; sourceResults = []; sourceSearchedKey = searchText
                            let k = searchText
                            Task {
                                let res = await searchAllSources(store.enabledSources, key: k)
                                await MainActor.run { sourceResults = res; sourceSearching = false }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "magnifyingglass")
                                Text("在书源中搜 “\(searchText)”（\(store.enabledSources.count) 个启用源）")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }.padding().background(Color.gray.opacity(0.12)).cornerRadius(12)
                        }.buttonStyle(.plain).disabled(sourceSearching)
                        if sourceSearching { ProgressView("正在多源搜索…") }
                        else if !sourceSearchedKey.isEmpty {
                            Text("源搜索结果 \(sourceResults.count) 本（只留标题/作者含关键词的）").font(.caption).foregroundStyle(.secondary)
                            ForEach(sourceResults) { result in
                                Button { shelfResult = result } label: { SourceBookRow(book: result) }.buttonStyle(.plain)
                                Divider()
                            }
                            if sourceResults.isEmpty {
                                Text("这个关键词在启用源里没搜到书：换个书名/作者，或者去设置 → 书源管理确认源已启用。").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.horizontal)
                }
            }
            .sheet(isPresented: $showExport) { if let url = exportURL { ShareLink("导出", item: url) } }
            .navigationTitle("书架")
            .readerNavigationStyle()
            .background(AppTheme.background.ignoresSafeArea())
            .searchable(text: $searchText, prompt: "搜索书架")
            .safeAreaInset(edge: .top, spacing: 0) {
                ReaderTabStrip(titles: groups, selection: $selectedGroup)
            }
            .sheet(item: $shelfResult) { SourceBookDetailView(store: store, result: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SourceView(store: store) } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("搜索书籍")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("导入本地书籍", systemImage: "square.and.arrow.down") { importing = true }
                        Button(selecting ? "结束多选" : "多选管理", systemImage: "checkmark.circle") { selecting.toggle(); selectedIds.removeAll() }
                        Picker("书架布局", selection: $viewMode) { Text("封面下方书名").tag(2); Text("封面叠字").tag(0); Text("列表").tag(1) }
                        Picker("排序", selection: $sortMode) { Text("最近阅读").tag(0); Text("书名").tag(1); Text("阅读进度").tag(2) }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("书架菜单")
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .data, .audio, .movie, .audiovisualContent]) { result in
                switch result {
                case .success(let url): importFile(url)
                case .failure(let e): errorText = e.localizedDescription; showError = true
                }
            }
            .alert("导入失败", isPresented: $showError) { Button("好", role: .cancel) {} } message: { Text(errorText) }
            .navigationDestination(item: $selectedBook) { book in ReaderView(store: store, bookId: book.id) }
            .navigationDestination(item: $selectedManga) { book in MangaView(store: store, bookId: book.id) }
            .navigationDestination(item: $selectedAudio) { book in AudioPlayerView(book: book) }
            .navigationDestination(item: $selectedVideo) { book in VideoPlayerView(book: book) }
        }
    }

    private var emptyShelf: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text("书架还空着").font(.title3.weight(.semibold))
            Text("从本地导入书籍，或使用书源搜索添加第一本书。")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { importing = true } label: {
                Label("导入本地书籍", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
        .padding(.horizontal, 24)
    }

    func openBook(_ book: LocalBook) {
        if book.isAudio { selectedAudio = book }
        else if book.isVideo { selectedVideo = book }
        else if book.isComicKind { selectedManga = book }
        else { selectedBook = book }
    }

    @ViewBuilder
    var bookListView: some View {
        // Legado-E 书架行（对标截图）：左封面，右标题/作者/当前章/最新章，右上角灰色数字角标 = 总章数。
        VStack(spacing: 0) {
            ForEach(filteredBooks) { book in
                Button {
                    if selecting {
                        if selectedIds.contains(book.id) { selectedIds.remove(book.id) } else { selectedIds.insert(book.id) }
                    } else { openBook(book) }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        if !book.coverUrl.isEmpty, let url = URL(string: book.coverUrl) {
                            AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { BookCover(title: book.title, width: 62) }
                                .frame(width: 62, height: 88).clipped().cornerRadius(6)
                        } else {
                            BookCover(title: book.title, width: 62)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(book.title).font(.headline).lineLimit(1)
                            if !book.author.isEmpty {
                                Label(book.author, systemImage: "person").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if book.chapterIndex < book.chapters.count {
                                Label(book.chapters[book.chapterIndex].title, systemImage: "clock").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if let last = book.chapters.last {
                                Label(last.title, systemImage: "safari").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if book.isAudio { Text("音频").font(.caption2).foregroundStyle(AppTheme.unreadBadge) }
                            if book.isVideo { Text("视频").font(.caption2).foregroundStyle(AppTheme.unreadBadge) }
                        }
                        Spacer()
                        if selecting {
                            Image(systemName: selectedIds.contains(book.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(AppTheme.accent)
                        } else if !book.chapters.isEmpty {
                            Text("\(book.chapters.count)")
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.gray.opacity(0.15)))
                        } else if book.favorite {
                            Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                        }
                    }
                    .padding(.vertical, 8)
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
        } else if ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"].contains(ext) {
            // 音频书（对标阅读Sigma 带歌词音频播放）
            var book = LocalBook(title: (fileName as NSString).deletingPathExtension, fileName: fileName, kind: "audio")
            book.chapters = [BookChapter(title: book.title, text: "")]
            store.updateBook(book)
        } else if ["mp4", "mov", "m4v", "mkv", "m3u8"].contains(ext) {
            // 视频书（对标阅读Sigma 带弹幕视频播放）
            let fileURL = dest.absoluteString
            var book = LocalBook(title: (fileName as NSString).deletingPathExtension, fileName: fileName, kind: "video")
            book.chapters = [BookChapter(title: "第 1 集", text: "__URL__" + fileURL)]
            store.updateBook(book)
        } else if ext == "lrc" {
            // 歌词：匹配同名音频书，把歌词挂上去
            let base = (fileName as NSString).deletingPathExtension
            let lyricText = decodeTextData(data)
            if let i = store.books.firstIndex(where: { $0.isAudio && ($0.fileName as NSString).deletingPathExtension == base }) {
                store.books[i].lyrics = lyricText
                store.save()
            } else if let i = store.books.firstIndex(where: { $0.isAudio }) {
                store.books[i].lyrics = lyricText
                store.save()
            } else {
                errorText = "没找到同名音频书来挂歌词，请先导入音频再导入同名 .lrc"
                showError = true
            }
        } else {
            errorText = "支持 TXT、EPUB、DOCX、FB2、MOBI、AZW3、PDF、CBZ（ZIP 漫画包）、音频（MP3/M4A/FLAC）、视频（MP4/M3U8）、歌词（LRC）"; showError = true
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
    @State private var importStatus = ""
    @State private var selectedResult: SourceBook?
    var body: some View {
        VStack {
            HStack {
                TextField("书名 / 作者", text: $key).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("bookSearch")
                    .submitLabel(.search).onSubmit { if !searching { search() } }
                Button { search() } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .disabled(key.isEmpty || searching)
                .accessibilityIdentifier("submitBookSearch")
            }.padding(.horizontal)
            HStack(spacing: 8) {
                Label("\(store.enabledSources.count) 个启用源", systemImage: "checkmark.seal.fill")
                Text("·")
                Text("\(store.sources.count) 个已导入")
                Spacer()
            }
            .font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
            if searching {
                ProgressView("正在搜索 \(store.enabledSources.count) 个书源…")
            } else if searchedCount > 0 {
                Text("找到 \(results.count) 本书 · 点击查看详情与目录").font(.caption).foregroundStyle(.secondary)
            }
            List(results) { r in
                Button {
                    selectedResult = r
                } label: {
                    SourceBookRow(book: r)
                }
            }
            .listStyle(.plain)
            if results.isEmpty && !searching {
                Text(store.enabledSources.isEmpty ? "还没有启用的书源，请先导入书源。" : (searchedCount > 0 ? "没有找到相关书籍，试试其他书名或作者。" : "输入书名或作者，搜索已启用的书源。"))
                    .font(.footnote).foregroundStyle(.secondary).padding()
            }
        }
        .navigationTitle("搜索")
        .readerNavigationStyle()
        .background(AppTheme.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .toolbar {
            Button { showImport = true } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("导入书源")
        }
        .sheet(isPresented: $showImport) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text("粘贴 Legado JSON 书源：单个对象、整个数组、订阅链接都可以；数组里个别格式不对的条目会跳过，不会整批失败。导入的书源默认全部启用。").font(.footnote).foregroundStyle(.secondary)
                    TextEditor(text: $importText).border(Color.gray.opacity(0.3))
                    if !importError.isEmpty { Text(importError).foregroundStyle(.red).font(.footnote) }
                    if !importStatus.isEmpty { Text(importStatus).foregroundStyle(AppTheme.accentDeep).font(.footnote) }
                    Button("导入") { importSource() }
                    Spacer()
                }.padding()
                .navigationTitle("导入书源")
                .toolbar { Button("关闭") { showImport = false } }
            }
        }
        .sheet(item: $selectedResult) { result in
            SourceBookDetailView(store: store, result: result,
                alternatives: allResults.filter { dedupeKey($0) == dedupeKey(result) })
        }
    }
    func search() {
        guard !searching, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
    func importSource() {
        let trimmed = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        importError = ""
        importStatus = ""
        if trimmed.hasPrefix("http") {
            importStatus = "正在拉取链接…"
            Task {
                do {
                    let result = try await importSourcePacksFromURL(trimmed)
                    let arr = result.sources
                    await MainActor.run {
                        if arr.isEmpty { importError = "这个链接里没有解析到书源：请确认它是返回 Legado 书源 JSON 的直链（GitHub blob 页已自动转 raw，仍失败就换 raw 链接）" }
                        else {
                            let enabled = arr.map { var x = $0; x.enabled = true; return x }
                            let merge = store.mergeSources(enabled)
                            importText = ""
                            importStatus = "解析到 \(arr.count) 个：新增 \(merge.added)，更新 \(merge.updated)，重复 \(merge.duplicates)\n" + result.diagnostics
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
            let merge = store.mergeSources(enabled)
            importText = ""
            importStatus = "解析到 \(enabled.count) 个：新增 \(merge.added)，更新 \(merge.updated)，重复 \(merge.duplicates)"
            if result.skipped > 0 { importStatus += "，跳过 \(result.skipped) 个格式不对的条目" }
        }
    }
}

// MARK: - Settings


// MARK: - 代码编辑器演示（书源代码，对标阅读Sigma 代码编辑页）

struct CodeEditorDemoView: View {
    @State private var code = sampleLegadoSourceJSON
    var body: some View {
        CodeEditorView(title: "书源代码", code: $code)
    }
}

let sampleLegadoSourceJSON = """
{
  "bookSourceUrl": "https://example.com",
  "bookSourceName": "示例书源",
  "bookSourceGroup": "测试分组",
  "bookSourceType": 0,
  "searchUrl": "https://example.com/search?key={{key}}",
  "ruleSearch": {
    "bookList": "class.book-item",
    "name": "tag.h3.0@text",
    "author": "tag.p.author@text",
    "bookUrl": "tag.a.0@href",
    "coverUrl": "tag.img.0@src",
    "intro": "tag.p.intro@text"
  },
  "ruleToc": {
    "chapterList": "id.chapter-list@tag.li",
    "chapterName": "tag.a@text",
    "chapterUrl": "tag.a@href"
  },
  "ruleContent": {
    "content": "id.content@textNodes",
    "nextContentUrl": "text.下一页@href",
    "replaceRegex": "##广告##"
  },
  "enabled": true
}
"""

// MARK: - 网络音频/视频直链播放（对标阅读Sigma 音视频）

struct AddMediaView: View {
    @State private var url = ""
    @State private var name = ""
    @State private var type = 0 // 0 视频 1 音频
    @State private var playVideo: LocalBook?
    @State private var playAudio: LocalBook?

    var body: some View {
        Form {
            Section("网络媒体播放") {
                Picker("类型", selection: $type) {
                    Text("视频（含弹幕）").tag(0)
                    Text("音频（含歌词）").tag(1)
                }.pickerStyle(.segmented)
                TextField("名称（可选）", text: $name)
                TextField("直链地址 m3u8 / mp4 / mp3 等", text: $url)
                    .keyboardType(.URL).autocapitalization(.none).textInputAutocapitalization(.never)
            }
            Section {
                Button("播放") {
                    let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !u.isEmpty else { return }
                    var book = LocalBook(title: name.isEmpty ? "在线媒体" : name, fileName: "", kind: type == 0 ? "video" : "audio")
                    if type == 0 {
                        book.chapters = [BookChapter(title: "第 1 集", text: "__URL__" + u)]
                        playVideo = book
                    } else {
                        book.audioUrl = u
                        book.chapters = [BookChapter(title: book.title, text: "")]
                        playAudio = book
                    }
                }.disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("视频会进入带弹幕的播放器；音频进入带歌词的播放器。多集/换源请用书架里导入的本地视频书，或后续接书源。").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("网络媒体")
        .navigationDestination(item: $playVideo) { VideoPlayerView(book: $0) }
        .navigationDestination(item: $playAudio) { AudioPlayerView(book: $0) }
    }
}
