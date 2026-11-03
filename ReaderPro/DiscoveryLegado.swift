import SwiftUI

struct DiscoveryView: View {
    @ObservedObject var store: BookStore
    @State private var searchText = ""
    @State private var showSourceSearch = false
    @FocusState private var sourceSearchFocused: Bool
    @State private var showGroups = false
    @State private var selectedGroup: String?
    @State private var expandedSourceID: String?
    @State private var exploreTarget: ExploreTarget?
    @State private var editingSource: LegadoSource?
    @State private var searchingSource: LegadoSource?

    private var sources: [LegadoSource] { ExploreSources.filter(store.sources, query: searchText, group: selectedGroup) }
    private var groups: [String] { ExploreSources.groups(store.sources) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if sources.isEmpty { emptyState }
                    ForEach(sources) { source in
                        SourceExploreCard(store: store, source: source, onEdit: { editingSource = source }, onSearch: { searchingSource = source }, expanded: Binding(
                            get: { expandedSourceID == source.id },
                            set: { expandedSourceID = $0 ? source.id : nil }
                        )) { category in
                            exploreTarget = ExploreTarget(source: source, category: category)
                        }.id(source.id)
                    }
                }.padding(.bottom, 12)
            }
            .sheet(item: $editingSource) { source in NavigationStack { SourceDetailView(store: store, source: source) } }
            .sheet(item: $searchingSource) { source in NavigationStack { SourceView(store: store, initialSourceID: source.id) } }
            .accessibilityIdentifier("discoverySourceScroll")
            .background(AppTheme.surface)
            .navigationTitle(selectedGroup ?? "发现")
            .readerNavigationStyle()
            .safeAreaInset(edge: .top, spacing: 0) {
                if showSourceSearch { searchBar }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSourceSearch = true; sourceSearchFocused = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("搜索发现书源")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showGroups = true } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("发现书源分组")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SourceManagementView(store: store) } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("书源管理")
                }
            }
            .confirmationDialog("发现书源分组", isPresented: $showGroups, titleVisibility: .visible) {
                Button("全部分组") { selectedGroup = nil }
                ForEach(groups, id: \.self) { group in
                    Button(group) { selectedGroup = group }.accessibilityIdentifier("discoveryGroup-\(group)")
                }
                Button("取消", role: .cancel) { }
            }
            .onChange(of: groups) { _, current in
                if let selectedGroup, !current.contains(selectedGroup) { self.selectedGroup = nil }
            }
            .navigationDestination(item: $exploreTarget) { target in
                ExploreListView(store: store, source: target.source, category: target.category)
            }
        }
    }
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "safari").font(.system(size: 36, weight: .light))
            Text("没有匹配的发现书源").font(.headline)
            Text("启用书源的发现功能后，点击源名称展开分类。右上角可搜索源名称和分组。")
                .font(.footnote).multilineTextAlignment(.center)
            NavigationLink("书源管理") { SourceManagementView(store: store) }
        }.foregroundStyle(.secondary).padding(.horizontal, 32).padding(.top, 90)
    }
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索发现书源 / 分组", text: $searchText)
                .focused($sourceSearchFocused).submitLabel(.search)
                .accessibilityIdentifier("discoverySourceSearch")
            Button("取消") { searchText = ""; showSourceSearch = false; sourceSearchFocused = false }
        }.padding(.horizontal, 16).padding(.vertical, 10).background(AppTheme.surface)
    }
}

struct ExploreTarget: Identifiable, Hashable {
    let id = UUID()
    let source: LegadoSource
    let category: ExploreCategory
    static func == (lhs: ExploreTarget, rhs: ExploreTarget) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SourceExploreCard: View {
    @ObservedObject var store: BookStore
    let source: LegadoSource
    var onEdit: () -> Void
    var onSearch: () -> Void
    @Binding var expanded: Bool
    let onTapCategory: (ExploreCategory) -> Void
    @State private var categories: [ExploreCategory] = []
    @State private var loadedKey: String?
    @State private var loading = false
    @State private var categoryError = ""
    @State private var actionError = ""
    @State private var retry = 0
    @State private var showLogin = false
    private var cacheKey: String { source.exploreCacheKey + "|\(retry)|\(ExploreInfo.revision(source.bookSourceUrl))" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(source.bookSourceName).font(.system(size: 15)).foregroundStyle(.primary).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(.secondary)
                }.padding(.horizontal, 10).padding(.vertical, 6).frame(minHeight: 36)
                    .background(AppTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 12)
                .accessibilityIdentifier("source-explore-\(source.bookSourceUrl)")
                .accessibilityValue(expanded ? "已展开" : "已折叠")
                .contextMenu {
                    if source.hasLogin { Button("登录") { showLogin = true } }
                    Button("编辑书源") { onEdit() }
                    Button("搜索此书源") { onSearch() }
                    Button("置顶") {
                        if let index = store.sources.firstIndex(where: { $0.id == source.id }) {
                            store.sources[index].customOrder = (store.sources.map(\.customOrder).min() ?? 0) - 1
                            store.save()
                        }
                    }
                    Button("刷新发现分类") { retry += 1; expanded = true }
                    Button("删除书源", role: .destructive) { store.sources.removeAll { $0.id == source.id }; store.save() }
                }
            if expanded { categoryContent }
        }
        .task(id: expanded ? cacheKey : "") {
            guard expanded else { loading = false; return }
            let key = cacheKey
            guard loadedKey != key else { loading = false; return }
            loading = true; categoryError = ""; actionError = ""; categories = []
            do {
                let parsed = try await source.resolvedExploreCategories()
                guard !Task.isCancelled else { return }
                categories = parsed; loadedKey = key; loading = false
                actionError = parsed.compactMap(\.displayError).joined(separator: "\n")
            } catch {
                guard !Task.isCancelled else { return }
                categoryError = sourceErrorMessage(error); loading = false
            }
        }
        .onChange(of: expanded) { _, open in if !open { ExploreInfo.savePending(source.bookSourceUrl) } }
        .onDisappear { ExploreInfo.savePending(source.bookSourceUrl) }
        .sheet(isPresented: $showLogin, onDismiss: { retry += 1 }) { SourceLoginView(source: source) }
    }
    @ViewBuilder private var categoryContent: some View {
        if loading { ProgressView().frame(maxWidth: .infinity).padding(12) }
        else if categories.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(categoryError.isEmpty ? "未解析到分类，请检查发现规则。" : categoryError).font(.caption).foregroundStyle(.secondary)
                Button("重试加载分类") { retry += 1 }.font(.caption)
            }.padding(16)
        } else {
            CategoryFlow {
                ForEach(Array(categories.enumerated()), id: \.offset) { entry in
                    ExploreCategoryControl(source: source, category: entry.element, index: entry.offset,
                                           onTapCategory: onTapCategory, onRefresh: { retry += 1 },
                                           onError: { actionError = $0 })
                        .id("\(entry.offset)|\(entry.element.title)|\(entry.element.type)")
                        .layoutValue(key: ExploreStyleKey.self, value: entry.element.style)
                }
            // Android's source card has 16 dp outer padding, then an 8 dp
            // frame inset. CategoryFlow includes Flexbox's own 3 dp padding.
            }.padding(.horizontal, 24).padding(.top, 8)
            if !actionError.isEmpty { Text(actionError).font(.caption).foregroundStyle(.red).padding(.horizontal, 16) }
        }
    }
}

private struct ExploreCategoryControl: View {
    let source: LegadoSource
    let category: ExploreCategory
    let index: Int
    let onTapCategory: (ExploreCategory) -> Void
    let onRefresh: () -> Void
    let onError: (String) -> Void
    @State private var value: String
    @State private var actionRequest = 0
    @State private var running = false
    @State private var showDiagnostic = false

    init(source: LegadoSource, category: ExploreCategory, index: Int, onTapCategory: @escaping (ExploreCategory) -> Void,
         onRefresh: @escaping () -> Void, onError: @escaping (String) -> Void) {
        self.source = source; self.category = category; self.index = index
        self.onTapCategory = onTapCategory; self.onRefresh = onRefresh; self.onError = onError
        _value = State(initialValue: ExploreInfo.value(source.bookSourceUrl, category.title))
    }
    private var name: String { category.displayTitle ?? category.title }
    private var stretches: Bool { category.style.alignSelf == "stretch" || category.style.alignSelf == "auto" }
    private var alignment: Alignment {
        switch category.style.justifySelf { case "flex_start": return .leading; case "flex_end": return .trailing; default: return .center }
    }
    private var textAlignment: TextAlignment {
        switch category.style.justifySelf { case "center": return .center; case "flex_end": return .trailing; default: return .leading }
    }
    var body: some View {
        control.font(.system(size: 14)).foregroundStyle(.primary)
            .alert("ERROR", isPresented: $showDiagnostic) {
                Button("确定", role: .cancel) { }
            } message: { Text(category.diagnosticMessage ?? "") }
            .task(id: actionRequest) {
                guard actionRequest > 0 else { return }
                do {
                    if category.type == "text" { try await Task.sleep(nanoseconds: 600_000_000) }
                    try Task.checkCancellation()
                    running = true; onError("")
                    let refresh = try await source.performExploreAction(category)
                    guard !Task.isCancelled else { return }
                    running = false
                    if refresh { onRefresh() }
                } catch {
                    guard !Task.isCancelled else { return }
                    running = false; onError("分类操作失败：" + sourceErrorMessage(error))
                }
            }
    }
    @ViewBuilder private var control: some View {
        switch category.type {
        case "text":
            TextField(name, text: $value).textInputAutocapitalization(.never).autocorrectionDisabled()
                .multilineTextAlignment(textAlignment).frame(minWidth: 96, maxHeight: stretches ? .infinity : nil)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(AppTheme.surfaceMuted, in: Capsule())
                .accessibilityIdentifier("explore-input-\(index)")
                .onChange(of: value) { _, new in
                    ExploreInfo.put(source.bookSourceUrl, category.title, new); actionRequest += 1
                }
        case "toggle":
            Button {
                let choices = category.choices
                guard !choices.isEmpty, !running else { return }
                let next = ((choices.firstIndex(of: value) ?? -1) + 1) % choices.count
                value = choices[next]; ExploreInfo.put(source.bookSourceUrl, category.title, value); actionRequest += 1
            } label: { pill(category.style.justifySelf == "right" ? name + value : value + name) }
                .buttonStyle(.plain).accessibilityIdentifier("explore-toggle-\(index)")
        case "select":
            Menu {
                ForEach(Array(category.choices.enumerated()), id: \.offset) { choice in
                    Button {
                        guard choice.element != value else { return }
                        value = choice.element; ExploreInfo.put(source.bookSourceUrl, category.title, value); actionRequest += 1
                    } label: { Label(choice.element, systemImage: value == choice.element ? "checkmark" : "circle") }
                }
            } label: { pill(name + " " + value + " ▾") }
                .disabled(running).accessibilityIdentifier("explore-select-\(index)")
        case "button":
            Button { if !running { actionRequest += 1 } } label: { pill(name) }
                .buttonStyle(.plain).accessibilityIdentifier("explore-button-\(index)")
        default:
            if category.diagnosticMessage != nil {
                Button { showDiagnostic = true } label: { pill(name) }
                    .buttonStyle(.plain).accessibilityIdentifier("explore-diagnostic-\(index)")
            } else if category.canNavigate {
                Button { onTapCategory(category) } label: { pill(name) }
                    .buttonStyle(.plain).accessibilityIdentifier("explore-category-\(index)")
            } else {
                pill(name).accessibilityIdentifier("explore-heading-\(index)")
            }
        }
    }
    private func pill(_ text: String) -> some View {
        Text(text).lineLimit(1).frame(maxWidth: .infinity, maxHeight: stretches ? .infinity : nil, alignment: alignment)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(AppTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ExploreListView: View {
    @ObservedObject var store: BookStore
    let source: LegadoSource
    let category: ExploreCategory
    @State private var results: [SourceBook] = []
    @State private var loading = true
    @State private var errorText = ""
    @State private var selectedResult: SourceBook?
    @State private var grid = false
    @State private var confirmLegacyCertificate = false
    @State private var page = 1
    @State private var loadingMore = false
    @State private var hasMore = true
    @State private var moreError = ""
    @State private var showPagePicker = false
    @State private var requestedPage = "1"
    @State private var requestID = UUID()

    var body: some View {
        Group {
            if loading { ProgressView("正在加载分类…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if !errorText.isEmpty {
                VStack(spacing: 12) {
                    Text(errorText).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试") { Task { await load() } }
                    if errorText.contains("TLS 连接失败") && !SourceTLS.isAllowed(source.bookSourceUrl) {
                        Button("旧站点证书兼容后重试") { confirmLegacyCertificate = true }
                    }
                }.padding()
            } else if results.isEmpty {
                Text("这个分类暂时没有书籍，请尝试其他分类或书源。").font(.footnote).foregroundStyle(.secondary).padding()
            } else if grid {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                        ForEach(results) { result in
                            Button { selectedResult = result } label: {
                                ShelfGridCell(title: result.title, coverUrl: result.cover, unreadCount: 0, selecting: false, selected: false, titleBelow: true)
                            }.buttonStyle(.plain)
                        }
                    }.padding(16)
                    moreControls
                }
            } else {
                List {
                    ForEach(results) { result in
                        Button { selectedResult = result } label: { SourceBookRow(book: result, source: store.sources.first { $0.bookSourceUrl == result.sourceUrl }) }.buttonStyle(.plain)
                    }
                    moreControls
                }.listStyle(.plain)
            }
        }
        .background(AppTheme.surface)
        .navigationTitle(category.title)
        .readerNavigationStyle()
        .toolbar {
            Button("第 \(page) 页") {
                requestedPage = String(page)
                showPagePicker = true
            }.accessibilityIdentifier("discoveryPagePicker")
            Button { grid.toggle() } label: { Image(systemName: grid ? "list.bullet" : "square.grid.2x2") }
                .accessibilityLabel(grid ? "列表布局" : "网格布局")
        }
        .task { await load() }
        .alert("跳转页码", isPresented: $showPagePicker) {
            TextField("页码", text: $requestedPage).keyboardType(.numberPad)
            Button("跳转") {
                if let selected = Int(requestedPage), selected > 0 { Task { await load(page: selected) } }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("请输入大于零的页码。") }
        .alert("信任此书源的旧证书？", isPresented: $confirmLegacyCertificate) {
            Button("开启并重试") {
                SourceTLS.setAllowed(true, for: source.bookSourceUrl)
                Task { await load() }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("开启后此书源的 HTTPS 连接将跳过证书校验，可能暴露传输内容。仅对信任的书源开启；可在书源详情中关闭。若服务器协议本身不兼容，开启后仍可能无法连接。")
        }
        .fullScreenCover(item: $selectedResult) { SourceBookDetailView(store: store, result: $0) }
    }

    @ViewBuilder private var moreControls: some View {
        VStack(spacing: 8) {
            if !moreError.isEmpty { Text(moreError).font(.footnote).foregroundStyle(.secondary) }
            if hasMore {
                Button(loadingMore ? "正在加载…" : (moreError.isEmpty ? "加载更多" : "重试加载更多")) {
                    Task { await loadMore() }
                }.disabled(loadingMore).accessibilityIdentifier("discoveryLoadMore")
            } else {
                Text("没有更多了").font(.footnote).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 12)
    }

    @MainActor private func load(page requested: Int = 1) async {
        let request = UUID(); requestID = request
        loading = true; errorText = ""; moreError = ""; loadingMore = false
        do {
            let books = try await withTimeout(45) { try await self.source.discover(category: self.category, page: requested) }
            guard !Task.isCancelled, requestID == request else { return }
            results = books; page = requested; hasMore = !books.isEmpty; loading = false
        } catch {
            guard !Task.isCancelled, requestID == request else { return }
            loading = false; errorText = "加载失败：\(sourceErrorMessage(error))"
        }
    }

    @MainActor private func loadMore() async {
        guard !loadingMore, hasMore else { return }
        loadingMore = true; moreError = ""
        let request = requestID
        let nextPage = page + 1
        do {
            let books = try await withTimeout(45) { try await self.source.discover(category: self.category, page: nextPage) }
            guard !Task.isCancelled, requestID == request else { return }
            var seen = Set(results.map(\.url))
            let newBooks = books.filter { seen.insert($0.url).inserted }
            results.append(contentsOf: newBooks)
            page = nextPage; hasMore = !newBooks.isEmpty; loadingMore = false
        } catch {
            guard !Task.isCancelled, requestID == request else { return }
            moreError = "加载失败：\(sourceErrorMessage(error))"; loadingMore = false
        }
    }
}
