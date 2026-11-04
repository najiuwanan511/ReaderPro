import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
    @StateObject private var store = BookStore()
    @ObservedObject private var importedThemes = LegadoThemeLibrary.shared
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var network: NetworkBootstrap
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("ui.showDiscovery") private var showDiscovery = true
    @AppStorage("ui.showRss") private var showRss = true
    @State private var selectedTab = UserDefaults.standard.integer(forKey: "ui.homeTab")
    var body: some View {
        TabView(selection: $selectedTab) {
            // Conditional children in the tab builder can retain stale native
            // selection on a cold launch. Give every visible tab a stable ID,
            // and scope tab-bar preferences to its content, as UIKit expects.
            ForEach(visibleTabs, id: \.self) { tab in
                tabContent(tab)
                    .tabItem { Label(["书架", "发现", "订阅", "我的"][tab], systemImage: ["books.vertical.fill", "safari", "bookmark", "person.fill"][tab]) }
                    .tag(tab)
                    .toolbarBackground(tabBackground, for: .tabBar)
                    .toolbarBackground(.visible, for: .tabBar)
            }
        }
        .onAppear { validateSelectedTab() }
        .onChange(of: showDiscovery) { _, _ in validateSelectedTab() }
        .onChange(of: showRss) { _, _ in validateSelectedTab() }
        .tint(AppTheme.accent)
        .overlay(alignment: .top) { networkBanner }
        .task(id: scenePhase) { if scenePhase == .active { await RuleSubscriptionStore.shared.updateDue(store: store) } }
        .modifier(SourceAppLinkReceiver(store: store))
    }
    private var visibleTabs: [Int] { [0] + (showDiscovery ? [1] : []) + (showRss ? [2] : []) + [3] }
    @ViewBuilder private func tabContent(_ tab: Int) -> some View {
        switch tab {
        case 0: BookshelfView(store: store)
        case 1: DiscoveryView(store: store)
        case 2: RssSubscribeView(store: store)
        default: SettingsView(store: store)
        }
    }
    private var tabBackground: Color {
        guard !UserDefaults.standard.bool(forKey: "ui.customColors"),
              let theme = LegadoTheme.selected(dark: colorScheme == .dark),
              let color = LegadoTheme.color(theme.bottomBackground) else { return AppTheme.surface }
        return Color(uiColor: color)
    }
    private func validateSelectedTab() {
        if (selectedTab == 1 && !showDiscovery) || (selectedTab == 2 && !showRss) || !(0...3).contains(selectedTab) { selectedTab = 0 }
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
    @StateObject private var shelfSearch = SourceSearchController()
    @AppStorage("shelfSortMode") private var sortMode = 0 // 0 最近阅读, 1 书名, 2 进度
    @AppStorage("shelfViewMode") private var viewMode = 2 // 0 封面叠字, 1 列表, 2 封面下方书名
    @State private var selectedGroup = 0
    @State private var shelfResult: SourceBook?
    @State private var selecting = false
    @State private var selectedIds: Set<String> = []
    @State private var editingBook: LocalBook?
    @ObservedObject private var shelfGroups = ShelfGroups.shared
    @StateObject private var refresh = ShelfRefreshModel()

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
        ["全部", "收藏"] + Set(shelfGroups.names + store.books.map(\.group).filter { !$0.isEmpty }).sorted()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if !refresh.message.isEmpty {
                    HStack {
                        if refresh.running { ProgressView().controlSize(.small) }
                        Text(refresh.message).font(.caption)
                        Spacer()
                        if refresh.running { Button("停止") { refresh.cancel() } }
                    }.padding(.horizontal).padding(.top, 8)
                    if !refresh.failures.isEmpty { DisclosureGroup("刷新失败详情") { Text(refresh.failures).font(.caption) }.padding(.horizontal) }
                }
                if store.books.isEmpty {
                    emptyShelf
                }
                if selecting && !selectedIds.isEmpty {
                    HStack {
                        Text("已选 \(selectedIds.count) 本").font(.subheadline).bold()
                        Spacer()
                        Menu("分组") {
                            Button("未分组") { assignGroup("") }
                            ForEach(groups.dropFirst(2), id: \.self) { group in Button(group) { assignGroup(group) } }
                        }
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
                            ShelfGridCell(title: book.title, coverUrl: book.coverUrl, unreadCount: book.unreadCount, selecting: selecting, selected: selectedIds.contains(book.id), titleBelow: viewMode == 2, source: store.sourceForBook(book))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("编辑书籍信息") { editingBook = book }
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
                            shelfSearch.start(store.enabledSources, key: searchText)
                        } label: {
                            HStack {
                                Image(systemName: "magnifyingglass")
                                Text("在书源中搜 “\(searchText)”（\(store.enabledSources.count) 个启用源）")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }.padding().background(Color.gray.opacity(0.12)).cornerRadius(12)
                        }.buttonStyle(.plain).accessibilityIdentifier("shelfSearchSources")
                        if shelfSearch.searching {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("已搜索 \(shelfSearch.completed)/\(shelfSearch.total) · \(shelfSearch.concurrency) 路并发")
                                    .lineLimit(1).minimumScaleFactor(0.75)
                                Spacer()
                                Button { shelfSearch.cancel() } label: {
                                    Text("停止").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                                }
                            }
                        }
                        if !shelfSearch.keyword.isEmpty {
                            Text("源搜索结果 \(shelfSearch.results.count) 本 · “\(shelfSearch.keyword)” · \(shelfSearch.searching ? "搜索中" : (shelfSearch.cancelled ? "已停止" : "已完成"))")
                                .font(.caption).foregroundStyle(.secondary)
                            // Searches across a large source pack can return
                            // thousands of books. Create covers only as rows
                            // approach the visible region instead of eagerly
                            // constructing every row inside this ScrollView.
                            LazyVStack {
                                ForEach(shelfSearch.results) { result in
                                    Button { shelfResult = result } label: { SourceBookRow(book: result, source: store.sources.first { $0.bookSourceUrl == result.sourceUrl }) }.buttonStyle(.plain)
                                    Divider()
                                }
                            }
                            if shelfSearch.results.isEmpty && !shelfSearch.searching {
                                Text("这个关键词在启用源里没搜到书：换个书名/作者，或者去设置 → 书源管理确认源已启用。").font(.footnote).foregroundStyle(.secondary)
                            }
                            if shelfSearch.hasMore { Button(shelfSearch.searching ? "正在搜索下一页…" : "加载下一页") { shelfSearch.loadMore() }.disabled(shelfSearch.searching) }
                        }
                    }.padding(.horizontal)
                }
            }
            .onDisappear { if shelfSearch.searching { shelfSearch.cancel() } }
            .refreshable { refresh.start(store: store) }
            .sheet(item: $editingBook) { book in NavigationStack { BookInfoEditorView(store: store, book: book) } }
            .sheet(isPresented: $showExport) { if let url = exportURL { ShareLink("导出", item: url) } }
            .navigationTitle("书架")
            .readerNavigationStyle()
            .background(LegadoThemeBackground())
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
                        NavigationLink("添加网址 / 书架清单") { ShelfTransferView(store: store) }
                        NavigationLink("远程书库") { RemoteLibraryView(store: store) }
                        Button("刷新书架目录", systemImage: "arrow.clockwise") { refresh.start(store: store) }.disabled(refresh.running)
                        NavigationLink("分组管理") { ShelfGroupsView(store: store) }
                        NavigationLink("缓存管理") { CacheManagementView(store: store) }
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
            .navigationDestination(item: $selectedAudio) { book in AudioPlayerView(book: book, store: store, source: store.sourceForBook(book)) }
            .navigationDestination(item: $selectedVideo) { book in
                VideoPlayerView(book: book, source: store.sources.first { $0.bookSourceUrl == book.sourceUrl }, store: store)
            }
        }
    }
    private func assignGroup(_ group: String) {
        for index in store.books.indices where selectedIds.contains(store.books[index].id) { store.books[index].group = group }
        store.saveBooks()
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
        else if book.isVideo || store.sources.first(where: { $0.bookSourceUrl == book.sourceUrl })?.isVideo == true { selectedVideo = book }
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
                        RemoteBookCover(title: book.title, url: book.coverUrl, width: 62, source: store.sourceForBook(book))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(book.title).font(.headline).lineLimit(1)
                            if !book.author.isEmpty {
                                Label(book.author, systemImage: "person").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if book.chapters.indices.contains(book.chapterIndex) {
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
                    Button("编辑书籍信息") { editingBook = book }
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
        Task { @MainActor in
            do { try store.applyFileImport(await BookFileImporter.importURL(url)) }
            catch { errorText = sourceErrorMessage(error); showError = true }
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
    var initialSourceID: String? = nil
    var initialKeyword = ""
    var initialScope = ""
    @State private var initializedSearch = false
    @State private var sourceSelection: Set<String>? = nil
    @State private var showScope = false
    @State private var history = SearchHistory.values
    private var searchableSources: [LegadoSource] {
        store.enabledSources.filter { sourceSelection?.contains($0.id) ?? true }
    }
    @State private var key = ""
    @FocusState private var searchFocused: Bool
    @StateObject private var searchState = SourceSearchController()
    @State private var showSearchErrors = false
    @State private var showImport = false
    @StateObject private var importModel = SourceImportModel()
    @State private var importText = ""
    @State private var importError = ""
    @State private var importStatus = ""
    @State private var selectedResult: SourceBook?
    var body: some View {
        VStack {
            HStack {
                TextField("书名 / 作者", text: $key).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("bookSearch")
                    .focused($searchFocused)
                    .submitLabel(.search).onSubmit { search() }
                Button { search() } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("submitBookSearch")
            }.padding(.horizontal)
            HStack(spacing: 8) {
                Button { showScope = true } label: { Label("搜索范围：\(searchableSources.count) 个源", systemImage: "line.3.horizontal.decrease.circle") }
                Text("·")
                Text("\(store.sources.count) 个已导入")
                Spacer()
                NavigationLink { SourceConcurrencySettingsView() } label: {
                    Label("并发", systemImage: "arrow.triangle.branch")
                }
            }
            .font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
            if searchState.searching {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("已搜索 \(searchState.completed)/\(searchState.total) · \(searchState.concurrency) 路并发 · \(searchState.results.count) 本")
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Spacer()
                    Button { searchState.cancel() } label: {
                        Text("停止").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }.accessibilityIdentifier("cancelBookSearch")
                }.padding(.horizontal).font(.caption)
            } else if !searchState.keyword.isEmpty {
                Text("\(searchState.cancelled ? "已停止" : "搜索完成") · 已搜索 \(searchState.completed)/\(searchState.total) · 找到 \(searchState.results.count) 本")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !searchState.errors.isEmpty {
                Button("查看 \(searchState.errors.count) 个书源的错误原因") { showSearchErrors = true }.font(.caption)
            }
            List {
                if searchState.keyword.isEmpty && !history.isEmpty {
                    Section {
                        ForEach(history, id: \.self) { term in
                            Button { key = term; search() } label: { Label(term, systemImage: "clock") }
                        }
                        Button("清空搜索历史", role: .destructive) { SearchHistory.clear(); history = [] }
                    } header: { Text("搜索历史") }
                }
                ForEach(searchState.results) { r in
                    Button { selectedResult = r } label: { SourceBookRow(book: r, source: store.sources.first { $0.bookSourceUrl == r.sourceUrl }) }
                }
                if searchState.hasMore && !searchState.searching {
                    Button(searchState.errors.isEmpty ? "加载下一页" : "继续搜索 / 重试失败书源") { searchState.loadMore() }
                        .accessibilityIdentifier("loadMoreSearch")
                }
            }
            .listStyle(.plain)
            if searchState.results.isEmpty && !searchState.searching {
                Text(store.enabledSources.isEmpty ? "还没有启用的书源，请先导入书源。" : (!searchState.keyword.isEmpty ? "没有找到相关书籍，试试其他书名或作者。" : "输入书名或作者，搜索已启用的书源。"))
                    .font(.footnote).foregroundStyle(.secondary).padding()
            }
        }
        .navigationTitle("搜索")
        .onAppear {
            guard !initializedSearch else { return }; initializedSearch = true
            if let initialSourceID { sourceSelection = [initialSourceID] }
            else if !initialScope.isEmpty {
                sourceSelection = Set(store.enabledSources.filter { $0.bookSourceUrl == initialScope || ExploreSources.groupNames($0.bookSourceGroup).contains(initialScope) }.map(\.id))
            }
            if !initialKeyword.isEmpty { key = initialKeyword; search() }
        }
        .sheet(isPresented: $showScope) { SearchScopePicker(sources: store.enabledSources, selection: $sourceSelection) }
        .onChange(of: importModel.message) { _, message in if !message.isEmpty { importText = "" } }
        .readerNavigationStyle()
        .background(LegadoThemeBackground())
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
                    Text("粘贴 Legado 书源、订阅源 JSON 或网络链接。自动识别类型，订阅源保存到「订阅源管理」，可在「订阅」中查看。").font(.footnote).foregroundStyle(.secondary)
                    TextEditor(text: $importText).border(Color.gray.opacity(0.3))
                    SourceImportStatusView(model: importModel)
                    Button("导入") { importSource() }.disabled(importModel.running || importText.isEmpty)
                    Spacer()
                }.padding()
                .navigationTitle("导入书源")
                .toolbar { Button("关闭") { showImport = false } }
            }
        }
        .sheet(isPresented: $showSearchErrors) {
            NavigationStack {
                List(Array(searchState.errors.enumerated()), id: \.offset) { _, message in
                    Text(message).font(.footnote).textSelection(.enabled)
                }.navigationTitle("搜索错误").toolbar { Button("关闭") { showSearchErrors = false } }
            }
        }
        .onDisappear { searchState.cancel() }
        .sheet(item: $selectedResult) { result in
            SourceBookDetailView(store: store, result: result,
                alternatives: searchState.allResults.filter { dedupeKey($0) == dedupeKey(result) })
        }
    }
    func search() {
        searchFocused = false
        SearchHistory.record(key); history = SearchHistory.values
        searchState.start(searchableSources, key: key)
    }
    func importSource() { importModel.start(importText, store: store) }

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
