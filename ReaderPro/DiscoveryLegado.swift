import SwiftUI

struct DiscoveryView: View {
    @ObservedObject var store: BookStore
    @State private var searchText = ""
    @State private var filterMode = 0
    @State private var exploreTarget: ExploreTarget?

    private var sources: [LegadoSource] {
        store.enabledSources.filter { source in
            guard source.enabledExplore else { return false }
            guard !source.effectiveDiscoverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard searchText.isEmpty || source.bookSourceName.localizedCaseInsensitiveContains(searchText)
                || source.bookSourceGroup.localizedCaseInsensitiveContains(searchText) else { return false }
            let group = source.bookSourceGroup
            let fast = group.contains("⚡") || group.contains("快")
            let official = group.contains("🏷") || group.contains("正版")
            switch filterMode {
            case 1: return fast
            case 2: return !fast && !official
            case 3: return official
            default: return true
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if sources.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "safari").font(.system(size: 36, weight: .light))
                            Text(store.enabledSources.isEmpty ? "还没有启用的书源" : "没有匹配的发现分类").font(.headline)
                            Text("导入带发现规则的书源后，点击源名称展开分类。也可以通过右上角搜索找书。")
                                .font(.footnote).multilineTextAlignment(.center)
                            NavigationLink("书源管理") { SourceManagementView(store: store) }
                        }.foregroundStyle(.secondary).padding(.horizontal, 32).padding(.top, 90)
                    }
                    ForEach(sources) { source in
                        SourceExploreCard(source: source) { category in
                            exploreTarget = ExploreTarget(source: source, category: category)
                        }
                    }
                }
            }
            .background(AppTheme.surface)
            .navigationTitle("发现")
            .readerNavigationStyle()
            .searchable(text: $searchText, prompt: "筛选书源 / 分组")
            .safeAreaInset(edge: .top, spacing: 0) {
                ReaderTabStrip(titles: ["全部", "快速", "通常", "正版"], selection: $filterMode)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SourceView(store: store) } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("搜索书籍")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SourceManagementView(store: store) } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("书源管理")
                }
            }
            .navigationDestination(item: $exploreTarget) { target in
                ExploreListView(store: store, source: target.source, category: target.category)
            }
        }
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
    let source: LegadoSource
    let onTapCategory: (ExploreCategory) -> Void
    @State private var expanded = false
    @State private var categories: [ExploreCategory] = []
    @State private var loadedRule: String?
    @State private var loading = false
    @State private var categoryError = ""
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Text(source.bookSourceName).font(.system(size: 15)).foregroundStyle(.primary).lineLimit(1)
                    Spacer()
                    if expanded && !categories.isEmpty { Text("\(categories.count)").font(.caption).foregroundStyle(.secondary) }
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).frame(minHeight: 48).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityIdentifier("source-explore-\(source.bookSourceUrl)")
                .accessibilityValue(expanded ? "已展开" : "已折叠")
            if expanded {
                if loading { ProgressView().frame(maxWidth: .infinity).padding(12) }
                else if categories.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(categoryError.isEmpty ? "未解析到分类，请尝试搜索该书源。" : categoryError)
                            .font(.caption).foregroundStyle(.secondary)
                        Button("重试加载分类") { retry += 1 }.font(.caption)
                    }.padding(16)
                }
                else {
                    CategoryFlow {
                        // Some real source packs contain repeated title+URL
                        // pairs. Category IDs are therefore not unique: use
                        // each row's position while preserving every entry.
                        ForEach(Array(categories.enumerated()), id: \.offset) { entry in
                            Button { onTapCategory(entry.element) } label: {
                                Text(entry.element.title).font(.system(size: 13)).lineLimit(1)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(AppTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(.primary)
                            }.buttonStyle(.plain).accessibilityIdentifier("explore-category-\(entry.offset)")
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
            Divider().padding(.leading, 16)
        }
        .task(id: expanded ? source.effectiveDiscoverUrl + "|\(retry)" : "") {
            guard expanded, loadedRule != source.effectiveDiscoverUrl else { return }
            loading = true; categoryError = ""; categories = []
            let snapshot = source
            do {
                let parsed = try await snapshot.fetchExploreCategories()
                guard !Task.isCancelled else { return }
                categories = parsed; loadedRule = snapshot.effectiveDiscoverUrl; loading = false
            } catch {
                guard !Task.isCancelled else { return }
                categoryError = sourceErrorMessage(error); loading = false
            }
        }
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

    var body: some View {
        Group {
            if loading { ProgressView("正在加载分类…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if !errorText.isEmpty {
                VStack(spacing: 12) {
                    Text(errorText).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试") { Task { await load() } }
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
                }
            } else {
                List(results) { result in
                    Button { selectedResult = result } label: { SourceBookRow(book: result) }.buttonStyle(.plain)
                }.listStyle(.plain)
            }
        }
        .background(AppTheme.surface)
        .navigationTitle(category.title)
        .readerNavigationStyle()
        .toolbar {
            Button { grid.toggle() } label: { Image(systemName: grid ? "list.bullet" : "square.grid.2x2") }
                .accessibilityLabel(grid ? "列表布局" : "网格布局")
        }
        .task { await load() }
        .sheet(item: $selectedResult) { SourceBookDetailView(store: store, result: $0) }
    }

    @MainActor private func load() async {
        loading = true; errorText = ""
        do {
            let books = try await withTimeout(45) { try await self.source.discover(category: self.category) }
            guard !Task.isCancelled else { return }
            results = books; loading = false
        } catch {
            guard !Task.isCancelled else { return }
            loading = false; errorText = "加载失败：\(sourceErrorMessage(error))"
        }
    }
}
