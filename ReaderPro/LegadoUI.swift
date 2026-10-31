import SwiftUI

extension View {
    func readerNavigationStyle() -> some View {
        navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppTheme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

struct ReaderTabStrip: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(titles.indices, id: \.self) { index in
                    Button { selection = index } label: {
                        Text(titles[index])
                            .font(.system(size: 15, weight: selection == index ? .semibold : .regular))
                            .foregroundStyle(selection == index ? AppTheme.accent : .secondary)
                            .padding(.vertical, 13)
                            .overlay(alignment: .bottom) {
                                if selection == index { Rectangle().fill(AppTheme.accent).frame(height: 2) }
                            }
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 16)
        }
        .background(AppTheme.surface)
        .overlay(alignment: .bottom) { AppTheme.divider.frame(height: 0.5) }
    }
}

/// Variable-width categories wrap in the same order as the source's Flexbox list.
struct CategoryFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(width: proposal.width ?? 320, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = positions(width: bounds.width, subviews: subviews)
        for (index, point) in layout.points.enumerated() {
            let size = subviews[index].sizeThatFits(.unspecified)
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                 proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
        }
    }

    private func positions(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            if x > 0 && x + itemWidth > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += itemWidth + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}

struct RemoteBookCover: View {
    let title: String
    let url: String
    var width: CGFloat = 76

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else { BookCover(title: title, width: width) }
        }
        .frame(width: width, height: width * 1.42)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct SourceBookRow: View {
    let book: SourceBook
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteBookCover(title: book.title, url: book.cover)
            VStack(alignment: .leading, spacing: 7) {
                Text(book.title).font(.system(size: 16, weight: .medium)).foregroundStyle(.primary).lineLimit(2)
                Text(book.author.isEmpty ? "作者未知" : book.author).font(.caption).foregroundStyle(.secondary)
                Text(book.sourceName).font(.caption2).foregroundStyle(AppTheme.accent).lineLimit(1)
                if !book.intro.isEmpty {
                    Text(book.intro).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 5).contentShape(Rectangle())
    }
}

/// The same detail and complete chapter list are used by search and discovery.
struct SourceBookDetailView: View {
    @ObservedObject var store: BookStore
    let result: SourceBook
    var alternatives: [SourceBook] = []
    @Environment(\.dismiss) private var dismiss
    @State private var sourceIndex = 0
    @State private var info: SourceBook?
    @State private var chapters: [BookChapter] = []
    @State private var loading = true
    @State private var errorText = ""
    @State private var reversed = false
    @State private var chapterQuery = ""
    @State private var readingBook: LocalBook?

    private var choices: [SourceBook] { [result] + alternatives.filter { $0.id != result.id } }
    private var selected: SourceBook { choices[min(sourceIndex, choices.count - 1)] }
    private var displayBook: SourceBook { info ?? selected }
    private var source: LegadoSource? {
        store.sources.first { $0.bookSourceUrl == selected.sourceUrl && $0.bookSourceName == selected.sourceName }
            ?? store.sources.first { $0.bookSourceName == selected.sourceName }
    }
    private var existingBook: LocalBook? {
        store.books.first { $0.title == selected.title && $0.author == selected.author && $0.sourceUrl == selected.sourceUrl && $0.sourceName == selected.sourceName }
    }
    private var chapterIndices: [Int] {
        let indices = chapters.indices.filter { chapterQuery.isEmpty || chapters[$0].title.localizedCaseInsensitiveContains(chapterQuery) }
        return reversed ? Array(indices.reversed()) : indices
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    hero
                    VStack(alignment: .leading, spacing: 16) {
                        if choices.count > 1 {
                            Picker("书源", selection: $sourceIndex) {
                                ForEach(choices.indices, id: \.self) { i in Text(choices[i].sourceName).tag(i) }
                            }.tint(AppTheme.accent)
                        } else {
                            Label(displayBook.sourceName, systemImage: "network").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if !displayBook.intro.isEmpty { Text(displayBook.intro).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5) }
                        Divider()
                        HStack {
                            Text("目录 · \(chapters.count) 章").font(.system(size: 16, weight: .medium))
                            Spacer()
                            Button { reversed.toggle() } label: { Label(reversed ? "倒序" : "正序", systemImage: "arrow.up.arrow.down") }.font(.caption)
                        }
                        if !chapters.isEmpty {
                            TextField("搜索章节", text: $chapterQuery).textFieldStyle(.roundedBorder)
                        }
                        if loading { ProgressView("正在加载目录…").frame(maxWidth: .infinity).padding() }
                        if !errorText.isEmpty {
                            Text(errorText).font(.footnote).foregroundStyle(.secondary)
                            Button("重新加载") { Task { await load() } }
                        }
                    }.padding(16)
                    ForEach(chapterIndices, id: \.self) { index in
                        Button { openChapter(index) } label: {
                            HStack {
                                Text(chapters[index].title).font(.system(size: 15)).foregroundStyle(.primary).lineLimit(2)
                                Spacer()
                                if existingBook?.chapterIndex == index { Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(AppTheme.accent) }
                            }.padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(AppTheme.surface)
            .navigationTitle("书籍详情")
            .readerNavigationStyle()
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } } }
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .onChange(of: sourceIndex) { _, _ in
                chapters = []; info = nil; loading = true; chapterQuery = ""
            }
            .task(id: selected.id) { await load() }
            .navigationDestination(item: $readingBook) { book in
                if book.isComicKind { MangaView(store: store, bookId: book.id) }
                else { ReaderView(store: store, bookId: book.id) }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                AppTheme.surfaceMuted
                AsyncImage(url: URL(string: displayBook.cover)) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                    .blur(radius: 8).overlay(Color.black.opacity(0.25))
                BookDetailArc().fill(AppTheme.surface).frame(height: 78)
                RemoteBookCover(title: displayBook.title, url: displayBook.cover, width: 110)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4).padding(.bottom, 20)
            }.frame(height: 204).clipped()
            VStack(spacing: 8) {
                Text(displayBook.title).font(.system(size: 21, weight: .semibold)).multilineTextAlignment(.center)
                Text(displayBook.author.isEmpty ? "作者未知" : displayBook.author).font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.bottom, 20)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { store.updateBook(makeBook()) } label: {
                Text(existingBook == nil ? "加入书架" : "已在书架").frame(maxWidth: .infinity, minHeight: 46)
            }.buttonStyle(.bordered).disabled(existingBook != nil || chapters.isEmpty || loading)
            Button { openChapter(nil) } label: {
                Text(existingBook == nil ? "开始阅读" : "继续阅读").frame(maxWidth: .infinity, minHeight: 46)
            }.buttonStyle(.borderedProminent).disabled(chapters.isEmpty || loading)
        }.font(.system(size: 15)).padding(.horizontal, 16).padding(.vertical, 8)
            .background(AppTheme.surface.shadow(color: .black.opacity(0.07), radius: 4, y: -2))
    }

    @MainActor private func load() async {
        loading = true; errorText = ""; chapters = []; info = nil
        let target = selected
        guard let source else { errorText = "书源已被删除，请重新搜索。"; loading = false; return }
        do {
            let fetched = (try? await source.fetchBookInfo(book: target)) ?? target
            let fetchedChapters = try await source.fetchChapters(book: fetched)
            guard !Task.isCancelled, selected.id == target.id else { return }
            info = fetched; chapters = fetchedChapters; loading = false
            if chapters.isEmpty { errorText = "该书源没有返回目录，请切换书源或重试。" }
        } catch {
            guard !Task.isCancelled, selected.id == target.id else { return }
            loading = false; errorText = "目录加载失败：\(error.localizedDescription)"
        }
    }

    private func makeBook() -> LocalBook {
        var book = existingBook ?? LocalBook(title: selected.title, author: selected.author, coverUrl: displayBook.cover,
            sourceName: selected.sourceName, sourceUrl: selected.sourceUrl,
            fileName: selected.title + ".web", kind: source?.isComic == true ? "comic" : "web")
        // Refresh the directory without discarding already downloaded content.
        let oldChapters = book.chapters
        book.chapters = chapters.enumerated().map { index, chapter in
            guard oldChapters.indices.contains(index), oldChapters[index].title == chapter.title else { return chapter }
            let old = oldChapters[index]
            if !old.text.isEmpty && !old.text.hasPrefix("__URL__") { return old }
            if !old.imageUrls.isEmpty { return old }
            return chapter
        }
        book.chapterIndex = min(book.chapterIndex, max(0, chapters.count - 1))
        return book
    }

    private func openChapter(_ index: Int?) {
        guard !chapters.isEmpty else { return }
        var book = makeBook()
        if let index { book.chapterIndex = index; book.charOffset = 0; book.paragraphIndex = 0 }
        store.updateBook(book); readingBook = book
    }
}

private struct BookDetailArc: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 36))
            path.addQuadCurve(to: CGPoint(x: rect.width, y: 36), control: CGPoint(x: rect.midX, y: -36))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: rect.height))
            path.closeSubpath()
        }
    }
}
