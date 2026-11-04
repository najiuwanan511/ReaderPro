import SwiftUI

extension View {
    func readerNavigationStyle() -> some View {
        navigationBarTitleDisplayMode(.inline)
            .modifier(LegadoThemeNavigation())
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

struct RemoteBookCover: View {
    let title: String
    let url: String
    var width: CGFloat = 68
    var source: LegadoSource? = nil
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { BookCover(title: title, width: width) }
        }
        .frame(width: width, height: width * 1.42).clipped()
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .task(id: url + "|" + (source?.coverDecodeJs ?? "")) {
            image = nil
            guard !url.isEmpty, let data = try? await SourceImagePipeline.load(url, source: source, cover: true), !Task.isCancelled else { return }
            image = UIImage(data: data)
        }
    }
}

struct SourceBookRow: View {
    let book: SourceBook
    var source: LegadoSource? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteBookCover(title: book.title, url: book.cover, source: source)
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
    @State private var previewBookID: String?
    @State private var editingBook: LocalBook?
    @State private var downloadURLs: [String] = []
    @State private var downloadingFile = false
    @State private var actionRunning = false
    @State private var actionMessage = ""
    @State private var actionBrowser: SourceLoginBrowser?
    @State private var browserStatus = ""
    @State private var detailSearch: ReaderSelectedText?
    @State private var shareBook: ReaderSelectedText?

    private var choices: [SourceBook] { [result] + alternatives.filter { $0.id != result.id } }
    private var selected: SourceBook { choices[min(sourceIndex, choices.count - 1)] }
    private var displayBook: SourceBook { info ?? selected }
    private var source: LegadoSource? {
        store.sources.first { $0.bookSourceUrl == selected.sourceUrl && $0.bookSourceName == selected.sourceName }
            ?? store.sources.first { $0.bookSourceName == selected.sourceName }
    }
    private var existingBook: LocalBook? {
        store.books.first { $0.id == previewBookID || ($0.title == selected.title && $0.author == selected.author && $0.sourceUrl == selected.sourceUrl && $0.sourceName == selected.sourceName) }
    }
    private var downloadedFileBook: LocalBook? {
        guard source?.isFile == true else { return nil }
        return existingBook ?? previewBookID.flatMap { store.readingBook(id: $0) }
    }
    private var currentReadingBook: LocalBook? {
        existingBook ?? previewBookID.flatMap { store.readingBook(id: $0) }
    }
    private var chapterEntries: [(offset: Int, element: BookChapter)] {
        let entries = chapters.enumerated().filter { chapterQuery.isEmpty || $0.element.title.localizedCaseInsensitiveContains(chapterQuery) }
        return reversed ? Array(entries.reversed()) : entries
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
                            }.tint(AppTheme.accent).accessibilityIdentifier("detailSourcePicker")
                        } else {
                            Label(displayBook.sourceName, systemImage: "network").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let warnings = displayBook.ruleWarnings, !warnings.isEmpty {
                            DisclosureGroup("封面或简介规则警告（\(warnings.count)）") {
                                Text(warnings.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                            }.font(.footnote)
                        }
                        if !displayBook.intro.isEmpty { Text(displayBook.intro).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5) }
                        Divider()
                        if source?.isFile == true {
                            Text("文件下载").font(.headline)
                            ForEach(Array(downloadURLs.enumerated()), id: \.offset) { index, address in
                                Button("下载并阅读 · " + (URL(string: SourceHTTP.options(address).url)?.lastPathComponent.removingPercentEncoding ?? "文件 \(index + 1)")) {
                                    Task { await downloadFile(address) }
                                }.disabled(downloadingFile)
                            }
                            if downloadingFile { ProgressView("正在下载并解析文件…") }
                        }
                        HStack {
                            Text(source?.isVideo == true ? "选集 · \(chapters.count) 集" : "目录 · \(chapters.count) 章").font(.system(size: 16, weight: .medium))
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
                    // Lazy rows can outlive the array used to create them while
                    // a retry or source switch clears/replaces the directory.
                    // Capture the chapter itself so rendering an old row never
                    // subscripts the newly changed array.
                    ForEach(chapterEntries, id: \.offset) { entry in
                        Button { openChapter(entry.offset, expectedChapterID: entry.element.id) } label: {
                            HStack {
                                Text(entry.element.displayTitle).font(.system(size: 15)).foregroundStyle(.primary).lineLimit(2)
                                Spacer()
                                if existingBook?.chapterIndex == entry.offset { Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(AppTheme.accent) }
                            }.padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).disabled(entry.element.isVolume).accessibilityIdentifier("chapter-\(entry.offset)")
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(AppTheme.surface)
            .navigationTitle(source?.isVideo == true ? "视频详情" : "书籍详情")
            .readerNavigationStyle()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("编辑书籍信息 / 变量") {
                            let book = currentReadingBook ?? makeBook(); store.openForReading(book)
                            if existingBook == nil { previewBookID = book.id }
                            editingBook = book
                        }.disabled(loading)
                        Button("重新加载目录") { Task { await load() } }.disabled(loading)
                        Button("分享书籍") { bookEvent("clickShareBook", input: shareText) { shareBook = ReaderSelectedText(text: shareText, offset: 0) } }
                        Button("复制书籍地址") { copyAddress(displayBook.url, event: "clickCopyBookUrl") }
                        Button("复制目录地址") { copyAddress(displayBook.tocUrl ?? displayBook.url, event: "clickCopyTocUrl") }
                        if let existingBook {
                            Button("清除本书缓存", role: .destructive) {
                                bookEvent("clickClearCache") { Task { await store.clearChapterCache(bookID: existingBook.id); actionMessage = "本书缓存已清除" } }
                            }
                        }
                        if let source {
                            if source.hasLogin { NavigationLink("登录 / 接口设置") { SourceLoginView(source: source) } }
                            if source.customButton { NavigationLink("书源自定义按钮") { SourceCustomActionView(source: source, book: displayBook) } }
                            NavigationLink("书源日志") { SourceLogView(source: source.bookSourceUrl) }
                        }
                    } label: { Image(systemName: "ellipsis") }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // A covered native NavigationStack can retain this inset in
                // its accessibility tree even when the stack is hidden.
                // Unmount the detail's actions while its reader is presented.
                if readingBook == nil { actions }
            }
            .onChange(of: sourceIndex) { _, _ in
                discardPreview()
                chapters = []; info = nil; loading = true; chapterQuery = ""
            }
            .task(id: selected.id) { await load() }
            .sheet(item: $editingBook) { book in NavigationStack { BookInfoEditorView(store: store, book: book) } }
            .sheet(item: $detailSearch) { query in NavigationStack { SourceView(store: store, initialKeyword: query.text) } }
            .sheet(item: $shareBook) { ReaderShareSheet(text: $0.text) }
            .sheet(item: $actionBrowser) { page in
                if let source {
                    NavigationStack {
                        SourceLoginWebPage(source: source, page: page, revision: 0, status: $browserStatus)
                            .navigationTitle("书源网页").toolbar { Button("关闭") { actionBrowser = nil } }
                    }
                }
            }
            .alert("书源操作", isPresented: Binding(get: { !actionMessage.isEmpty }, set: { if !$0 { actionMessage = "" } })) {
                Button("确定") { actionMessage = "" }
            } message: { Text(actionMessage) }
        }
        // Present above the detail container. A pushed reader inside a sheet
        // inherits its top gap and the detail screen's bottom action inset.
        .fullScreenCover(item: $readingBook) { book in
            NavigationStack {
                if book.isVideo {
                    VideoPlayerView(book: book, source: source, store: store)
                } else if book.isAudio {
                    AudioPlayerView(book: book, store: store, source: source)
                } else if book.isComicKind {
                    MangaView(store: store, bookId: book.id)
                        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("返回目录") { readingBook = nil } } }
                }
                else { ReaderView(store: store, bookId: book.id) }
            }
        }
        .onDisappear { if readingBook == nil && editingBook == nil { discardPreview() } }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                AppTheme.surfaceMuted
                AsyncImage(url: URL(string: displayBook.cover)) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                    .blur(radius: 8).overlay(Color.black.opacity(0.25))
                BookDetailArc().fill(AppTheme.surface).frame(height: 78)
                RemoteBookCover(title: displayBook.title, url: displayBook.cover, width: 110, source: source)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4).padding(.bottom, 20)
            }.frame(height: 204).clipped()
            VStack(spacing: 8) {
                SourceEventButton(action: { searchBookInfo(author: false, longClick: $0) }) {
                    Text(displayBook.title).font(.system(size: 21, weight: .semibold)).multilineTextAlignment(.center)
                }.accessibilityIdentifier("detailBookName")
                SourceEventButton(action: { searchBookInfo(author: true, longClick: $0) }) {
                    Text(displayBook.author.isEmpty ? "作者未知" : displayBook.author).font(.subheadline).foregroundStyle(.secondary)
                }.disabled(displayBook.author.isEmpty).accessibilityIdentifier("detailBookAuthor")
            }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.bottom, 20)
        }
    }

    private var shareText: String {
        let book = displayBook
        let fields = ["name": book.title, "author": book.author, "bookUrl": book.url, "tocUrl": book.tocUrl ?? book.url,
                      "origin": book.sourceUrl, "originName": book.sourceName, "coverUrl": book.cover, "intro": book.intro]
        return book.url + "#" + ((try? JSONSerialization.data(withJSONObject: fields)).map { String(decoding: $0, as: UTF8.self) } ?? "{}")
    }
    private func searchBookInfo(author: Bool, longClick: Bool) {
        let text = author ? displayBook.author : displayBook.title
        bookEvent((longClick ? "longClick" : "click") + (author ? "Author" : "BookName"), input: text, longClick: longClick) {
            detailSearch = ReaderSelectedText(text: text, offset: 0)
        }
    }
    private func copyAddress(_ address: String, event: String) {
        bookEvent(event, input: address) { UIPasteboard.general.string = address; actionMessage = "已复制" }
    }
    private func bookEvent(_ event: String, input: String? = nil, longClick: Bool = false, fallback: @escaping () -> Void) {
        guard !actionRunning else { return }
        guard let source else { fallback(); return }
        actionRunning = true; let target = selected.id, book = displayBook
        Task {
            defer { actionRunning = false }
            do {
                let result = try await source.performBookEvent(event, book: book, input: input, longClick: longClick)
                guard selected.id == target else { return }
                if let result {
                    if let text = result.copyText { UIPasteboard.general.string = text }
                    actionBrowser = result.browser
                    if result.browser == nil { actionMessage = result.message }
                    if sourceRuleBoolean(result.value) { return }
                }
                fallback()
            } catch { actionMessage = sourceErrorMessage(error) }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                if source?.isFile == true, downloadedFileBook == nil, let address = downloadURLs.first {
                    Task { await downloadFile(address, addToShelf: true) }
                } else { store.addToShelf(currentReadingBook ?? makeBook()) }
            } label: {
                Text(existingBook == nil ? "加入书架" : "已在书架").frame(maxWidth: .infinity, minHeight: 46)
            }.buttonStyle(.bordered).disabled(existingBook != nil || loading || downloadingFile || (source?.isFile == true ? downloadURLs.isEmpty && downloadedFileBook == nil : chapters.isEmpty))
            Button {
                if let book = downloadedFileBook { readingBook = book }
                else if source?.isFile == true, let address = downloadURLs.first { Task { await downloadFile(address) } }
                else { openChapter(nil) }
            } label: {
                Text(source?.isVideo == true ? (existingBook == nil ? "开始播放" : "继续播放") : (existingBook == nil ? "开始阅读" : "继续阅读")).frame(maxWidth: .infinity, minHeight: 46)
            }.buttonStyle(.borderedProminent).disabled(loading || downloadingFile || (source?.isFile == true ? downloadURLs.isEmpty : chapters.isEmpty))
        }.font(.system(size: 15)).padding(.horizontal, 16).padding(.vertical, 8)
            .background(AppTheme.surface.shadow(color: .black.opacity(0.07), radius: 4, y: -2))
    }

    @MainActor private func load() async {
        loading = true; errorText = ""; chapters = []; info = nil; downloadURLs = []
        let target = selected
        guard let source else { errorText = "书源已被删除，请重新搜索。"; loading = false; return }
        do {
            let fetched = try await withTimeout(30) { try await source.fetchBookInfo(book: target) }
            if source.isFile {
                let addresses = try await withTimeout(30) { try await source.fileDownloadURLs(book: fetched) }
                guard !Task.isCancelled, selected.id == target.id else { return }
                info = fetched; downloadURLs = addresses; loading = false; return
            }
            let fetchedChapters = try await withTimeout(120) { try await source.fetchChapters(book: fetched) }
            guard !Task.isCancelled, selected.id == target.id else { return }
            info = fetched; chapters = fetchedChapters; loading = false
            if chapters.isEmpty { errorText = "该书源没有返回目录，请切换书源或重试。" }
        } catch {
            guard !Task.isCancelled, selected.id == target.id else { return }
            loading = false; errorText = "目录加载失败：\(sourceErrorMessage(error))"
        }
    }

    @MainActor private func downloadFile(_ address: String, addToShelf: Bool = false) async {
        guard !downloadingFile, let source else { return }
        downloadingFile = true; errorText = ""
        defer { downloadingFile = false }
        let target = displayBook, rules = ReaderRuleLibrary.shared.txtRules
        do {
            let worker = Task.detached { try await source.downloadBookFile(address, book: target, txtRules: rules) }
            let local = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, selected.id == target.id else { return }
            if addToShelf { store.addToShelf(local); previewBookID = local.id }
            else { store.openForReading(local); previewBookID = local.id; readingBook = local }
        } catch { errorText = sourceErrorMessage(error) }
    }

    private func makeBook() -> LocalBook {
        if let downloadedFileBook { return downloadedFileBook }
        let preview = previewBookID.flatMap { store.readingBook(id: $0) }
        var book = existingBook ?? preview ?? LocalBook(title: selected.title, author: selected.author, coverUrl: displayBook.cover,
            sourceName: selected.sourceName, sourceUrl: selected.sourceUrl,
            fileName: selected.title + ".web", kind: source?.localBookKind ?? "web")
        if book.sourceUrl != selected.sourceUrl || book.sourceName != selected.sourceName {
            book.chapterIndex = 0; book.charOffset = 0; book.paragraphIndex = 0; book.progress = 0
        }
        book.sourceUrl = selected.sourceUrl; book.sourceName = selected.sourceName
        if let source { book.kind = source.localBookKind }
        book.bookUrl = displayBook.url; book.tocUrl = displayBook.tocUrl ?? ""
        // Refresh the directory without discarding already downloaded content.
        let oldChapters = book.chapters
        book.chapters = chapters.map { chapter in
            guard let url = chapter.url, let old = oldChapters.first(where: { $0.url == url }) else { return chapter }
            var updated = chapter
            if !old.text.isEmpty && !old.text.hasPrefix("__URL__") { updated.text = old.text }
            if !old.imageUrls.isEmpty { updated.imageUrls = old.imageUrls }
            return updated
        }
        let bounded = max(0, min(book.chapterIndex, chapters.count - 1))
        book.chapterIndex = chapters.readableIndex(from: bounded) ?? chapters.readableIndex(from: bounded, direction: -1) ?? 0
        return book
    }

    private func openChapter(_ index: Int?, expectedChapterID: String? = nil) {
        guard !chapters.isEmpty else { return }
        if let index {
            guard chapters.indices.contains(index), !chapters[index].isVolume,
                  expectedChapterID == nil || chapters[index].id == expectedChapterID else { return }
        }
        var book = (index == nil ? currentReadingBook : nil) ?? makeBook()
        if let index { book.chapterIndex = index; book.charOffset = 0; book.paragraphIndex = 0 }
        store.openForReading(book)
        if existingBook == nil { previewBookID = book.id }
        readingBook = book
    }

    private func discardPreview() {
        if let previewBookID { store.discardReadingPreview(id: previewBookID) }
        previewBookID = nil
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
