import SwiftUI

// MARK: - 发现页（legado-E 对标：搜索框 + 按书源分组的分类宫格 + 快速/通常/正版筛选）
// 阅读Sigma 发现页 = 顶部搜索框 + 每个书源一张分组卡片：
// 头部「书源名 + 分类数」，下方是分类按钮的 flex 换行宫格（FlexboxLayout）。
// 点分类进该源的分类书籍列表（ExploreShowActivity）。

struct DiscoveryView: View {
    @ObservedObject var store: BookStore
    @State private var searchText = ""
    @State private var filterMode = 0 // 0 全部, 1 快速, 2 通常, 3 正版
    @State private var exploreTarget: ExploreTarget?

    // 快速 = 分组含 ⚡/快；正版 = 分组含 🏷/正版；其余归通常；无标记默认通常（沿用 legado-E 分组约定）
    var sources: [LegadoSource] {
        var list = store.enabledSources
        if !searchText.isEmpty {
            list = list.filter {
                $0.bookSourceName.localizedCaseInsensitiveContains(searchText)
                    || $0.bookSourceGroup.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch filterMode {
        case 1: list = list.filter { $0.bookSourceGroup.contains("⚡") || $0.bookSourceGroup.contains("快") }
        case 2: list = list.filter { !($0.bookSourceGroup.contains("⚡") || $0.bookSourceGroup.contains("快") || $0.bookSourceGroup.contains("🏷") || $0.bookSourceGroup.contains("正版")) }
        case 3: list = list.filter { $0.bookSourceGroup.contains("🏷") || $0.bookSourceGroup.contains("正版") }
        default: break
        }
        return list
    }
    // 只有带发现分类的书源才出现（legado-E 行为：无 exploreUrl 的源不展示）
    var sourcesWithCategories: [LegadoSource] {
        sources.filter { !$0.exploreCategories().isEmpty }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.enabledSources.isEmpty {
                    emptyState(icon: "safari", title: "没有启用的书源",
                               msg: "去「我的 → 书源管理」导入并启用书源，发现页会按书源展示各自的分类。")
                } else if sourcesWithCategories.isEmpty {
                    emptyState(icon: "magnifyingglass",
                               title: searchText.isEmpty && filterMode == 0 ? "已启用的书源都没有发现分类" : "没有匹配的书源",
                               msg: searchText.isEmpty && filterMode == 0 ? "这些书源的 exploreUrl 为空或暂不支持，可去「书源」用搜索直接找书。" : "换个关键词或筛选试试。")
                } else {
                    LazyVStack(spacing: 12) {
                        // 统计说明：让用户明白「为什么 10 个源只显示 4 个」——发现页只展示带发现分类(exploreUrl)的源
                        HStack(spacing: 5) {
                            Image(systemName: "info.circle").font(.caption2)
                            Text("\(store.enabledSources.count) 个启用源，\(sourcesWithCategories.count) 个带发现分类（其余源无发现规则，去「搜索」直接找书）")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(sourcesWithCategories) { src in
                            SourceExploreCard(source: src) { cat in
                                exploreTarget = ExploreTarget(source: src, category: cat)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("发现")
            .searchable(text: $searchText, prompt: "搜书源名 / 分组")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SourceView(store: store)
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("多源搜索")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("全部书源") { filterMode = 0 }
                        Button("快速书源 ⚡") { filterMode = 1 }
                        Button("通常书源 📂") { filterMode = 2 }
                        Button("正版书源 🏷") { filterMode = 3 }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .navigationDestination(item: $exploreTarget) { t in
                ExploreListView(store: store, source: t.source, category: t.category)
            }
        }
    }

    func emptyState(icon: String, title: String, msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(msg).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 90)
        .padding(.horizontal, 30)
    }
}

// 发现页跳转目标（source + category 一起传递）
struct ExploreTarget: Identifiable, Hashable {
    let id = UUID()
    let source: LegadoSource
    let category: ExploreCategory

    static func == (l: ExploreTarget, r: ExploreTarget) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// legado-E 发现分组卡片：书源名头部 + 分类按钮 flex 换行宫格
struct SourceExploreCard: View {
    let source: LegadoSource
    let onTapCategory: (ExploreCategory) -> Void
    var categories: [ExploreCategory] { source.exploreCategories() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AppTheme.accent))
                Text(source.bookSourceName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(categories.count) 个分类").font(.caption2).foregroundStyle(.secondary)
            }
            // flex 换行宫格（legado-E 用 FlexboxLayout；这里用自适应网格等价实现）
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(categories) { cat in
                    Button { onTapCategory(cat) } label: {
                        Text(cat.title)
                            .font(.footnote)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppTheme.accentSoft))
                            .foregroundStyle(AppTheme.accentDeep)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.card))
    }
}

// legado-E 分类书籍列表（点分类进入，对标 ExploreShowActivity）
struct ExploreListView: View {
    @ObservedObject var store: BookStore
    let source: LegadoSource
    let category: ExploreCategory
    @State private var results: [SourceBook] = []
    @State private var loading = true
    @State private var errorText = ""
    @State private var selectedResult: SourceBook?
    @State private var detailChapters: [BookChapter] = []
    @State private var loadingDetail = false
    @State private var detailIsComic = false
    @State private var readingBook: LocalBook?

    var body: some View {
        Group {
            if loading {
                VStack { ProgressView("正在加载分类…") }
            } else if !errorText.isEmpty {
                VStack(spacing: 10) {
                    Text(errorText).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试") { load() }
                }.padding()
            } else if results.isEmpty {
                VStack(spacing: 10) {
                    Text("这个分类下没有结果").font(.headline)
                    Text("该源的发现规则可能为空或本站拒绝访问，换个分类或换源试试。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 14) {
                        ForEach(results) { r in
                            Button { selectedResult = r; loadDetail(r) } label: {
                                ShelfGridCell(title: r.title, coverUrl: r.cover, unreadCount: 0, selecting: false, selected: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if results.isEmpty { load() } }
        .sheet(item: $selectedResult) { r in
            NavigationStack {
                List {
                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            if !r.cover.isEmpty, let url = URL(string: r.cover) {
                                AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                                    .frame(width: 90, height: 124).cornerRadius(8).clipped()
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(r.title).font(.title3).bold()
                                if !r.author.isEmpty { Text(r.author).foregroundStyle(.secondary) }
                                if !r.sourceName.isEmpty { Text("书源：\(r.sourceName)").font(.caption).foregroundStyle(.secondary) }
                                if !r.intro.isEmpty { Text(r.intro).font(.footnote).lineLimit(5) }
                            }
                        }
                        Button("加入书架") {
                            var book = makeBook(from: r)
                            book.chapters = detailChapters
                            store.updateBook(book)
                            selectedResult = nil
                        }.buttonStyle(.borderedProminent).disabled(detailChapters.isEmpty)
                    }
                    Section {
                        if loadingDetail {
                            ProgressView("正在拉取目录…")
                        } else if detailChapters.isEmpty {
                            Text("目录为空：请换一个源，或检查这个源的目录规则。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(detailChapters.prefix(300).enumerated()), id: \.offset) { index, chapter in
                                Button {
                                    openChapter(index, result: r)
                                } label: {
                                    HStack(spacing: 10) {
                                        Text(chapter.title).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(loadingDetail ? "目录" : "目录（\(detailChapters.count) 章，点击即可阅读）")
                    }
                }
                .navigationTitle("书籍详情")
                .toolbar { Button("关闭") { selectedResult = nil } }
                .navigationDestination(item: $readingBook) { book in
                    ReaderView(store: store, bookId: book.id)
                }
            }
        }
    }

    func load() {
        loading = true; results = []; errorText = ""
        Task {
            do {
                let res = try await source.discover(category: category)
                await MainActor.run { results = res; loading = false }
            } catch {
                await MainActor.run { results = []; loading = false; errorText = "加载失败（\(source.bookSourceName)）：\(error.localizedDescription)" }
            }
        }
    }

    func loadDetail(_ r: SourceBook) {
        loadingDetail = true; detailChapters = []
        detailIsComic = source.isComic
        Task {
            do {
                let chs = try await source.fetchChapters(book: r)
                await MainActor.run { detailChapters = chs; loadingDetail = false }
            } catch {
                await MainActor.run { loadingDetail = false }
            }
        }
    }

    func makeBook(from result: SourceBook) -> LocalBook {
        LocalBook(title: result.title, author: result.author, coverUrl: result.cover,
                  sourceName: result.sourceName, sourceUrl: result.sourceUrl,
                  fileName: result.title + ".web", kind: detailIsComic ? "comic" : "web")
    }

    func openChapter(_ index: Int, result: SourceBook) {
        guard detailChapters.indices.contains(index) else { return }
        var book = makeBook(from: result)
        book.chapters = detailChapters
        book.chapterIndex = index
        store.updateBook(book)
        readingBook = book
    }
}
