import SwiftUI
import UIKit

// MARK: - 阅读器（完整版）

struct FullSearchResult: Identifiable {
    var id: String { "\(chapterIndex)-\(lineIndex)" }
    let chapterIndex: Int
    let chapterTitle: String
    let line: String
    let lineIndex: Int
}

// Old backups may contain a negative or out-of-range position. Empty books
// keep the conventional zero position without attempting an array access.
func boundedReadingIndex(_ index: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(max(index, 0), count - 1)
}

func restoredReadingPosition(_ book: LocalBook) -> (chapter: Int, offset: Int) {
    guard !book.chapters.isEmpty else { return (0, 0) }
    let chapter = boundedReadingIndex(book.chapterIndex, count: book.chapters.count)
    return (chapter, chapter == book.chapterIndex ? max(0, book.charOffset) : 0)
}

struct ReaderView: View {
    @ObservedObject var store: BookStore
    let bookId: String
    @Environment(\.dismiss) private var dismiss

    // 章节 / 分页
    @State private var chapterIndex = 0
    @State private var pages: [NSRange] = []
    @State private var pageIndex = 0
    @State private var attributed: NSAttributedString = NSAttributedString(string: "")
    @State private var pageSize: CGSize = .zero
    @State private var lastSize: CGSize = .zero

    // 菜单 / 弹层
    @State private var showMenu = false
    @State private var showSettings = false
    @State private var showStyle = false
    @State private var showCatalog = false
    @State private var showSearch = false
    @State private var showBookmarks = false
    @State private var showSourceChange = false
    @State private var showDownloadAll = false
    @State private var searchText = ""
    @State private var searchScope = 0 // 0 本章, 1 全文
    @State private var fullResults: [FullSearchResult] = []
    @State private var searchingFull = false

    @State private var loading = false
    @State private var errorText = ""
    @State private var chapterLoadTask: Task<Void, Never>?
    @State private var chapterLoadToken = UUID()
    @State private var initialBrightness: CGFloat = 0.5

    // 仿真翻页跳转令牌（目录/书签/换章时强制重建 pageCurl）
    @State private var jumpToken = 0

    // 自动翻页
    @State private var autoPageEnabled = false
    @State private var autoPageInterval: Double = 10
    @State private var autoTimer: Timer?

    // 换源
    @State private var sourceChangeKey = ""
    @State private var sourceChangeResults: [SourceBook] = []
    @State private var sourceChangeLoading = false

    // 整本缓存
    @State private var downloadProgress: (Int, Int)?

    // 覆盖翻页手势偏移
    @State private var coverDrag: CGFloat = 0

    // 阅读时长
    @State private var readingStart = Date()

    @StateObject private var speech = SpeechController()

    var book: LocalBook? { store.books.first { $0.id == bookId } }
    var chapter: BookChapter? {
        guard let b = book, b.chapters.indices.contains(chapterIndex) else { return nil }
        return b.chapters[chapterIndex]
    }
    var theme: ReaderTheme { readerTheme(at: store.theme) }
    var bookBookmarks: [Bookmark] {
        guard let b = book else { return [] }
        return store.bookmarks.filter { $0.bookId == b.id }
    }

    // 排版参数签名：任一变化即重排
    func layoutSignature(_ size: CGSize) -> String {
        "\(store.fontSize)|\(store.lineSpacing)|\(store.paragraphSpacing)|\(store.pagePaddingH)|\(store.pagePaddingV)|\(store.fontName)|\(store.theme)|\(store.showHeader)|\(store.showFooter)|\(store.pageTurn)|\(Int(size.width))|\(Int(size.height))"
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                if loading {
                    VStack(spacing: 20) {
                        ProgressView("正在加载章节…")
                        Button("取消并返回") { cancelChapterLoad(); dismiss() }
                    }.foregroundColor(Color(uiColor: theme.secondary))
                } else if chapter?.text.hasPrefix("__URL__") == true {
                    VStack(spacing: 20) {
                        Text("章节尚未加载")
                        Button("重试") { loadChapterIfNeeded() }
                        Button("返回目录") { dismiss() }
                    }.foregroundColor(Color(uiColor: theme.secondary))
                } else if book != nil, chapter != nil {
                    readerContent(size: size)
                    if showMenu { menuOverlay }
                } else {
                    Text("没有章节").foregroundColor(Color(uiColor: theme.secondary))
                }
            }
            .frame(width: size.width, height: size.height)
            .onAppear {
                lastSize = size
                readingStart = Date()
                onAppear(size: size)
            }
            .onChange(of: layoutSignature(size)) { _, _ in
                rebuild(size: size, keepOffset: currentCharOffset())
            }
        }
        .background(Color(uiColor: theme.background).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .preferredColorScheme(themeBrightness())
        .onDisappear {
            cancelChapterLoad()
            saveProgress()
            let minutes = max(0, Int(Date().timeIntervalSince(readingStart) / 60))
            if minutes > 0, var b = store.books.first(where: { $0.id == bookId }) {
                b.totalMinutes += minutes
                store.updateBook(b)
            }
            speech.stop()
            autoTimer?.invalidate()
            UIScreen.main.brightness = initialBrightness
        }
        .sheet(isPresented: $showCatalog) { catalogSheet }
        .sheet(isPresented: $showSearch) { searchSheet }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showStyle) { styleSheet }
        .sheet(isPresented: $showBookmarks) { bookmarksSheet }
        .sheet(isPresented: $showSourceChange) { sourceChangeSheet }
        .sheet(isPresented: $showDownloadAll) { downloadSheet }
        .alert("加载失败", isPresented: .constant(!errorText.isEmpty)) {
            Button("重试") { errorText = ""; loadChapterIfNeeded() }
            Button("好") { errorText = "" }
        } message: { Text(errorText) }
    }

    // MARK: 阅读内容（按翻页模式分派）

    @ViewBuilder
    func readerContent(size: CGSize) -> some View {
        switch store.pageTurn {
        case 2: scrollReader(size: size)
        case 0: coverReader(size: size)
        case 3: noneReader(size: size)
        case 4: curlReader(size: size)
        default: pagedReader(size: size)
        }
    }

    // 平移（TabView .page）
    @ViewBuilder
    func pagedReader(size: CGSize) -> some View {
        TabView(selection: $pageIndex) {
            ForEach(pages.indices, id: \.self) { i in
                pageView(i: i, size: size).tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: pageIndex) { _, v in saveProgress(page: v) }
    }

    // 无动画：直接显示当前页
    @ViewBuilder
    func noneReader(size: CGSize) -> some View {
        pageView(i: pageIndex, size: size)
            .frame(width: size.width, height: size.height)
    }

    // 仿真翻页（pageCurl 卷曲动画）
    @ViewBuilder
    func curlReader(size: CGSize) -> some View {
        ZStack {
            CurlPageController(
                pages: pages,
                attributed: attributed,
                pageSize: pageSize,
                background: theme.background,
                startIndex: pageIndex,
                onPageChange: { idx in
                    pageIndex = idx
                    saveProgress(page: idx)
                }
            )
            // 中间 1/3 点击弹菜单，左右交给系统翻页
            HStack(spacing: 0) {
                Color.clear.frame(width: size.width / 3)
                Color.clear.frame(width: size.width / 3)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showMenu.toggle() } }
                Color.clear.frame(width: size.width / 3)
            }
        }
        .frame(width: size.width, height: size.height)
        .id("curl-\(jumpToken)")
    }

    // 覆盖：当前页 + 手势左滑盖入下一页
    @ViewBuilder
    func coverReader(size: CGSize) -> some View {
        let w = size.width
        ZStack {
            pageView(i: pageIndex, size: size)
            if pageIndex < pages.count - 1 {
                pageView(i: pageIndex + 1, size: size)
                    .frame(width: size.width, height: size.height)
                    .background(Color(uiColor: theme.background))
                    .offset(x: w + coverDrag)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .gesture(
            DragGesture()
                .onChanged { g in
                    if g.translation.width < 0 {
                        coverDrag = g.translation.width
                    }
                }
                .onEnded { g in
                    if g.translation.width < -w * 0.25 {
                        goNext()
                    }
                    withAnimation(.easeOut(duration: store.pageTurnSpeed)) { coverDrag = 0 }
                }
        )
    }

    // 滚动：整章连续滚动
    @ViewBuilder
    func scrollReader(size: CGSize) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat(store.paragraphSpacing)) {
                if let c = chapter, store.showHeader {
                    Text(c.title)
                        .font(.system(size: CGFloat(store.fontSize + 3), weight: .bold))
                        .foregroundColor(Color(uiColor: theme.text))
                        .padding(.bottom, 4)
                }
                FullTextReader(
                    attributed: attributed,
                    width: max(size.width - CGFloat(store.pagePaddingH * 2), 100)
                )
            }
            .padding(.horizontal, CGFloat(store.pagePaddingH))
            .padding(.vertical, CGFloat(store.pagePaddingV))
        }
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showMenu.toggle() } }
    }

    // 单页 + 点按三区（左翻上页 / 中弹菜单 / 右翻下页）
    @ViewBuilder
    func pageView(i: Int, size: CGSize) -> some View {
        let range = pages.indices.contains(i) ? pages[i] : NSRange(location: 0, length: 0)
        let sub = attributed.attributedSubstring(from: range)
        PageTextView(attributed: sub, pageSize: pageSize)
            .frame(width: pageSize.width, height: pageSize.height)
            .frame(width: size.width, height: size.height)
            .background(Color.clear)
            .overlay(alignment: .top) {
                if store.showHeader, let c = chapter {
                    HStack {
                        Text(c.title)
                            .font(.system(size: CGFloat(max(store.fontSize - 5, 11)), weight: .medium))
                            .foregroundColor(Color(uiColor: theme.secondary))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, CGFloat(store.pagePaddingH))
                    .padding(.top, CGFloat(max(store.pagePaddingV * 0.35, 6)))
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if store.showFooter {
                    HStack {
                        Text("第 \(i + 1) 页")
                        Spacer()
                        Text("共 \(max(pages.count, 1)) 页")
                    }
                    .font(.system(size: CGFloat(max(store.fontSize - 6, 10))))
                    .foregroundColor(Color(uiColor: theme.secondary))
                    .padding(.horizontal, CGFloat(store.pagePaddingH))
                    .padding(.bottom, CGFloat(max(store.pagePaddingV * 0.35, 6)))
                    .allowsHitTesting(false)
                }
            }
            .overlay(
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { goPrev() }
                    Color.clear.contentShape(Rectangle()).onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showMenu.toggle() } }
                    Color.clear.contentShape(Rectangle()).onTapGesture { goNext() }
                }
            )
    }

    // MARK: 翻页

    func goNext() {
        if pageIndex < pages.count - 1 {
            withAnimation(.easeOut(duration: store.pageTurnSpeed)) { pageIndex += 1 }
            saveProgress(page: pageIndex)
        } else if chapterIndex < (book?.chapters.count ?? 0) - 1 {
            openChapter(chapterIndex + 1, atStart: true)
        }
    }

    func goPrev() {
        if pageIndex > 0 {
            withAnimation(.easeOut(duration: store.pageTurnSpeed)) { pageIndex -= 1 }
            saveProgress(page: pageIndex)
        } else if chapterIndex > 0 {
            openChapter(chapterIndex - 1, atEnd: true)
        }
    }

    func openChapter(_ i: Int, atStart: Bool = true, atEnd: Bool = false) {
        guard let b = book else { return }
        chapterIndex = max(0, min(i, b.chapters.count - 1))
        loadChapterIfNeeded()
        rebuild(size: lastSize, keepOffset: nil)
        pageIndex = atEnd ? max(pages.count - 1, 0) : 0
        saveProgress(page: pageIndex)
        jumpToken += 1
    }

    // MARK: 分页与重排

    func baseAttributes() -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = CGFloat(store.lineSpacing)
        para.paragraphSpacing = CGFloat(store.paragraphSpacing)
        para.alignment = .justified
        para.lineBreakMode = .byCharWrapping
        para.hyphenationFactor = 0
        var attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: theme.text,
            .paragraphStyle: para,
        ]
        if store.fontName.isEmpty {
            attrs[.font] = UIFont.systemFont(ofSize: CGFloat(store.fontSize))
        } else {
            attrs[.font] = UIFont(name: store.fontName, size: CGFloat(store.fontSize)) ?? UIFont.systemFont(ofSize: CGFloat(store.fontSize))
        }
        return attrs
    }

    func rebuild(size: CGSize, keepOffset: Int?) {
        guard let c = chapter else { return }
        lastSize = size
        let text = NSAttributedString(string: store.purify(c.text), attributes: baseAttributes())
        attributed = text
        // Reserve the real overlay height. A fixed 20pt allowance is enough at
        // the default size but lets large fonts collide with the header/footer.
        let headerSpace: CGFloat = store.showHeader
            ? CGFloat(max(store.fontSize - 5, 11) + max(store.pagePaddingV * 0.35, 6) + 4)
            : 0
        let footerSpace: CGFloat = store.showFooter
            ? CGFloat(max(store.fontSize - 6, 10) + max(store.pagePaddingV * 0.35, 6) + 4)
            : 0
        let newPageSize = CGSize(
            width: max(size.width - CGFloat(store.pagePaddingH * 2), 100),
            height: max(size.height - CGFloat(store.pagePaddingV * 2) - headerSpace - footerSpace, 100)
        )
        pageSize = newPageSize
        pages = Paginator.paginate(text, pageSize: newPageSize)
        if let off = keepOffset {
            pageIndex = pageIndex(for: off)
        } else {
            pageIndex = max(min(pageIndex, pages.count - 1), 0)
        }
    }

    func currentCharOffset() -> Int {
        guard pages.indices.contains(pageIndex) else { return 0 }
        return pages[pageIndex].location
    }

    func pageIndex(for offset: Int) -> Int {
        var idx = 0
        for (i, r) in pages.enumerated() where r.location <= offset { idx = i }
        return idx
    }

    func onAppear(size: CGSize) {
        guard let b = book else { return }
        let restored = restoredReadingPosition(b)
        chapterIndex = restored.chapter
        initialBrightness = UIScreen.main.brightness
        applyBrightness()
        loadChapterIfNeeded()
        rebuild(size: size, keepOffset: restored.offset)
        if store.pageTurn != 2 {
            pageIndex = pageIndex(for: restored.offset)
        }
    }

    func applyBrightness() {
        if store.brightness < 0 {
            UIScreen.main.brightness = initialBrightness
        } else {
            UIScreen.main.brightness = CGFloat(store.brightness)
        }
    }

    // MARK: 进度

    func saveProgress(page: Int? = nil) {
        guard var b = book else { return }
        let p = boundedReadingIndex(page ?? pageIndex, count: pages.count)
        b.chapterIndex = boundedReadingIndex(chapterIndex, count: b.chapters.count)
        b.paragraphIndex = p
        if pages.indices.contains(p) {
            b.charOffset = pages[p].location
        }
        if !b.chapters.isEmpty {
            let pageCount = max(pages.count, 1)
            let frac = Double(p) / Double(pageCount)
            b.progress = (Double(b.chapterIndex) + min(frac, 1.0)) / Double(b.chapters.count)
        }
        b.lastRead = Date()
        store.updateBook(b)
    }

    // MARK: 章节懒加载（web 源）

    func cancelChapterLoad() {
        chapterLoadToken = UUID()
        chapterLoadTask?.cancel()
        chapterLoadTask = nil
        loading = false
    }

    func loadChapterIfNeeded() {
        cancelChapterLoad()
        guard let b = book, b.chapters.indices.contains(chapterIndex) else { return }
        let ch = b.chapters[chapterIndex]
        guard ch.text.hasPrefix("__URL__") else { return }
        guard let src = store.sourceForBook(b) else {
            errorText = "这本书的书源已删除或未启用，无法拉取在线章节"
            return
        }
        loading = true
        let idx = chapterIndex
        let token = chapterLoadToken
        let nextURL = b.chapters.indices.contains(idx + 1) ? b.chapters[idx + 1].url : b.chapters.first?.url
        chapterLoadTask = Task { @MainActor in
            defer {
                if chapterLoadToken == token { loading = false; chapterLoadTask = nil }
            }
            do {
                // One deadline covers all pagination and synchronous JS retries.
                let content = try await withTimeout(45) { try await src.fetchChapterContent(ch, nextChapterUrl: nextURL) }
                guard !Task.isCancelled, chapterLoadToken == token, chapterIndex == idx,
                      var nb = store.books.first(where: { $0.id == bookId }),
                      nb.chapters.indices.contains(idx), nb.chapters[idx].id == ch.id else { return }
                nb.chapters[idx].text = content
                store.updateBook(nb)
                rebuild(size: lastSize, keepOffset: 0)
            } catch {
                guard !Task.isCancelled, chapterLoadToken == token else { return }
                errorText = sourceErrorMessage(error)
            }
        }
    }

    // MARK: 朗读 / 书签

    func addBookmark() {
        guard let b = book, b.chapters.indices.contains(chapterIndex) else { return }
        var snippet = ""
        if pages.indices.contains(pageIndex) {
            snippet = String(attributed.attributedSubstring(from: pages[pageIndex]).string.prefix(40))
        }
        store.addBookmark(Bookmark(bookId: b.id, chapterIndex: chapterIndex, paragraphIndex: pageIndex, snippet: snippet))
    }

    func jumpToBookmark(_ bm: Bookmark) {
        showBookmarks = false
        openChapter(bm.chapterIndex, atStart: true)
        pageIndex = boundedReadingIndex(bm.paragraphIndex, count: pages.count)
        saveProgress(page: pageIndex)
        jumpToken += 1
    }

    func toggleSpeech() {
        if speech.isSpeaking {
            speech.stop()
            return
        }
        guard let currentChapter = chapter else { return }
        var segments: [String] = []
        if store.pageTurn == 2 {
            segments = paragraphs(currentChapter)
        } else {
            for i in min(max(pageIndex, 0), pages.count)..<pages.count {
                segments.append(attributed.attributedSubstring(from: pages[i]).string)
            }
        }
        speech.speak(segments: segments, rate: Float(store.ttsRate), pitch: Float(store.ttsPitch))
    }

    func paragraphs(_ c: BookChapter) -> [String] {
        store.purify(c.text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func cycleTheme() {
        let t = theme
        var w: CGFloat = 0; var a: CGFloat = 0
        t.background.getWhite(&w, alpha: &a)
        store.theme = w < 0.5 ? 0 : 5
        store.save()
    }

    func themeBrightness() -> ColorScheme? {
        let t = theme
        var w: CGFloat = 0; var a: CGFloat = 0
        t.background.getWhite(&w, alpha: &a)
        return w < 0.5 ? .dark : .light
    }

    // MARK: 自动翻页

    func toggleAutoPage(_ on: Bool) {
        autoPageEnabled = on
        autoTimer?.invalidate()
        autoTimer = nil
        if on {
            autoTimer = Timer.scheduledTimer(withTimeInterval: autoPageInterval, repeats: true) { _ in
                DispatchQueue.main.async { goNext() }
            }
        }
    }

    // MARK: 换源

    func openSourceChange() {
        sourceChangeKey = book?.title ?? ""
        sourceChangeResults = []
        sourceChangeLoading = false
        showSourceChange = true
    }

    func searchForChangeSource() {
        guard !sourceChangeKey.isEmpty else { return }
        sourceChangeLoading = true
        let enabled = store.enabledSources
        let key = sourceChangeKey
        Task {
            let raw = await searchAllRawSources(enabled, key: key)
            var seen = Set<String>(); var deduped: [SourceBook] = []
            for b in raw {
                let k = dedupeKey(b)
                if seen.contains(k) { continue }
                seen.insert(k); deduped.append(b)
            }
            await MainActor.run { sourceChangeResults = deduped; sourceChangeLoading = false }
        }
    }

    func changeSource(to r: SourceBook) {
        showSourceChange = false
        guard let src = store.sources.first(where: { $0.bookSourceName == r.sourceName && ($0.bookSourceUrl == r.sourceUrl || r.sourceUrl.isEmpty) }) ?? store.sources.first(where: { $0.bookSourceName == r.sourceName }) else {
            errorText = "找不到对应书源（可能已删除），请重新搜索"
            return
        }
        Task {
            do {
                try await store.reloadBookFromSource(bookId: bookId, source: src, sourceBook: r)
                await MainActor.run {
                    chapterIndex = 0
                    pageIndex = 0
                    rebuild(size: lastSize, keepOffset: 0)
                    jumpToken += 1
                }
            } catch {
                await MainActor.run { errorText = "换源失败：\(sourceErrorMessage(error))" }
            }
        }
    }

    // MARK: 整本缓存

    func startDownloadAll() {
        guard let b = book else { return }
        let pending = b.chapters.filter { $0.text.hasPrefix("__URL__") }.count
        guard pending > 0 else {
            errorText = "这本书没有需要缓存的在线章节（本地书或已全部缓存）"
            return
        }
        downloadProgress = (0, pending)
        showDownloadAll = true
        Task {
            await store.downloadAllChapters(bookId: bookId) { done, total in
                downloadProgress = (done, total)
                if done >= total {
                    rebuild(size: lastSize, keepOffset: currentCharOffset())
                }
            }
        }
    }

    // MARK: 菜单

    var menuOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showMenu = false } }
            bottomBar
        }
        .transition(.opacity)
    }

    var topBar: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(book?.title ?? "").font(.headline).lineLimit(1)
                if let c = chapter, store.showHeader {
                    Text(c.title).font(.caption).foregroundColor(Color(uiColor: theme.secondary)).lineLimit(1)
                }
            }
            Spacer()
            Button { addBookmark() } label: {
                Image(systemName: "bookmark").font(.system(size: 18))
            }
            Menu {
                Button("搜索正文", systemImage: "magnifyingglass") { showSearch = true }
                Button("查看书签", systemImage: "bookmark") { showBookmarks = true }
                Button("切换书源", systemImage: "arrow.triangle.2.circlepath") { openSourceChange() }
                Button("缓存全书", systemImage: "arrow.down.circle") { startDownloadAll() }
                Button(autoPageEnabled ? "关闭自动翻页" : "自动翻页", systemImage: "play.circle") { toggleAutoPage(!autoPageEnabled) }
            } label: { Image(systemName: "ellipsis").font(.system(size: 20)) }

        }
        .foregroundColor(Color(uiColor: theme.text))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: theme.background).opacity(0.97))
    }

    var bottomBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                Spacer()
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索正文")
                Button { toggleAutoPage(!autoPageEnabled) } label: {
                    Image(systemName: autoPageEnabled ? "pause.circle" : "play.circle")
                }.accessibilityLabel("自动翻页")
                Button { cycleTheme() } label: { Image(systemName: "moon") }.accessibilityLabel("切换阅读背景")
            }
            .font(.system(size: 20)).padding(.bottom, 16)
            HStack(spacing: 14) {
                Button("上一章") { openChapter(chapterIndex - 1) }.disabled(chapterIndex == 0)
                Slider(value: Binding(
                    get: { Double(pageIndex) },
                    set: { pageIndex = Int($0); saveProgress(page: pageIndex) }
                ), in: 0...Double(max(pages.count - 1, 1)), step: 1, onEditingChanged: { editing in
                    if !editing && store.pageTurn == 4 { jumpToken += 1 }
                }).disabled(store.pageTurn == 2 || pages.count < 2)
                    .accessibilityLabel("本章阅读进度")
                Button("下一章") { openChapter(chapterIndex + 1) }
                    .disabled(chapterIndex >= (book?.chapters.count ?? 0) - 1)
            }.font(.system(size: 13))
            HStack {
                Spacer()
                Text("\(chapterIndex + 1)/\(book?.chapters.count ?? 0) 章 · \(pageIndex + 1)/\(max(pages.count, 1)) 页")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Color(uiColor: theme.secondary))
                Spacer()
            }.padding(.top, 2).padding(.bottom, 12)
            Divider()
            HStack(spacing: 0) {
                readerMenuButton("目录", icon: "list.bullet") { showCatalog = true }
                readerMenuButton(speech.isSpeaking ? "停止" : "朗读", icon: "headphones") { toggleSpeech() }
                readerMenuButton("界面", icon: "textformat.size") { showStyle = true }
                readerMenuButton("设置", icon: "gearshape") { showSettings = true }
            }.padding(.top, 14).padding(.bottom, 8)
        }
        .foregroundStyle(Color(uiColor: theme.text))
        .padding(.horizontal, 16).padding(.top, 12)
        .background(Color(uiColor: theme.background).opacity(0.98))
    }

    func readerMenuButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 22, weight: .regular))
                Text(title).font(.system(size: 12))
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // Compact typography panel, matching the separate “界面” entry in the reference.
    var styleSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    HStack {
                        Text("字体").font(.system(size: 14))
                        Spacer()
                        Picker("字体", selection: $store.fontName) {
                            ForEach(allFonts) { font in Text(font.display).tag(font.name) }
                        }.labelsHidden().onChange(of: store.fontName) { _, _ in store.save() }
                    }
                    styleSlider("字号", value: $store.fontSize, range: 12...32)
                    styleSlider("行距", value: $store.lineSpacing, range: 0...24)
                    styleSlider("段距", value: $store.paragraphSpacing, range: 0...40)
                    HStack(spacing: 6) {
                        ForEach([0, 1, 4, 2, 3], id: \.self) { mode in
                            Button {
                                store.pageTurn = mode; store.save()
                            } label: {
                                Text(["覆盖", "平移", "滚动", "无", "仿真"][mode])
                                    .font(.system(size: 13)).frame(maxWidth: .infinity).padding(.vertical, 9)
                                    .background(store.pageTurn == mode ? AppTheme.accentSoft : AppTheme.surfaceMuted,
                                                in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(store.pageTurn == mode ? AppTheme.accent : .primary)
                            }.buttonStyle(.plain)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(readerThemes) { readerTheme in
                                Button { store.theme = readerTheme.id; store.save() } label: {
                                    VStack(spacing: 6) {
                                        Text("阅").font(.system(size: 21, design: .serif))
                                            .frame(width: 50, height: 66)
                                            .background(Color(uiColor: readerTheme.background))
                                            .foregroundStyle(Color(uiColor: readerTheme.text))
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(store.theme == readerTheme.id ? AppTheme.accent : AppTheme.divider, lineWidth: 2))
                                        Text(readerTheme.name).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }.padding(2)
                    }
                }.padding(16)
            }
            .navigationTitle("界面").readerNavigationStyle()
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showStyle = false } } }
        }.presentationDetents([.height(440), .large]).presentationDragIndicator(.visible)
    }

    func styleSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 14)).frame(width: 32)
            Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1); store.save() } label: {
                Image(systemName: "minus").frame(width: 30, height: 30)
            }.accessibilityLabel("减少" + title)
            Slider(value: value, in: range, step: 1).onChange(of: value.wrappedValue) { _, _ in store.save() }
            Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + 1); store.save() } label: {
                Image(systemName: "plus").frame(width: 30, height: 30)
            }.accessibilityLabel("增加" + title)
            Text("\(Int(value.wrappedValue))").font(.caption).monospacedDigit().frame(width: 24)
        }
    }

    // MARK: 目录

    var catalogSheet: some View {
        NavigationStack {
            List {
                ForEach(Array((book?.chapters ?? []).enumerated()), id: \.offset) { entry in
                    Button {
                        showCatalog = false
                        guard let current = book, current.chapters.indices.contains(entry.offset),
                              current.chapters[entry.offset].id == entry.element.id else { return }
                        openChapter(entry.offset, atStart: true)
                    } label: {
                        HStack {
                            Text(entry.element.title)
                                .foregroundColor(entry.offset == chapterIndex ? Color.accentColor : .primary)
                            Spacer()
                            if entry.offset == chapterIndex { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { showCatalog = false } } }
        }
    }

    // MARK: 书内搜索（本章 / 全文）

    var searchSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("搜索关键词", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    Button("搜索") { runSearch() }.disabled(searchText.isEmpty)
                }.padding()
                Picker("范围", selection: $searchScope) {
                    Text("本章").tag(0); Text("全文").tag(1)
                }.pickerStyle(.segmented).padding(.horizontal)
                if searchScope == 0 {
                    List(searchResults(), id: \.self) { line in
                        Button(line) { jumpToLine(line) }
                    }
                } else {
                    if searchingFull { ProgressView("全文搜索中…").padding() }
                    List(fullResults) { r in
                        Button {
                            jumpToChapter(r.chapterIndex, locateLine: r.line)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.chapterTitle).font(.caption).foregroundStyle(.secondary)
                                Text(r.line).lineLimit(2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("书内搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { showSearch = false } } }
        }
    }

    func runSearch() {
        guard !searchText.isEmpty else { return }
        if searchScope == 1 {
            searchingFull = true
            fullResults = []
            let key = searchText
            Task {
                let r = await fullSearch(key: key)
                await MainActor.run { fullResults = r; searchingFull = false }
            }
        }
    }

    func fullSearch(key: String) async -> [FullSearchResult] {
        guard let b = book else { return [] }
        var out: [FullSearchResult] = []
        for (i, ch) in b.chapters.enumerated() {
            if ch.text.hasPrefix("__URL__") { continue }
            let paras = store.purify(ch.text).components(separatedBy: .newlines)
            for (j, p) in paras.enumerated() where p.contains(key) {
                out.append(FullSearchResult(chapterIndex: i, chapterTitle: ch.title, line: p, lineIndex: j))
            }
        }
        return out
    }

    func searchResults() -> [String] {
        guard let c = chapter, !searchText.isEmpty else { return [] }
        return paragraphs(c).filter { $0.contains(searchText) }
    }

    func locate(_ line: String) -> Int? {
        let full = attributed.string as NSString
        let r = full.range(of: line)
        if r.location == NSNotFound { return nil }
        for (i, pr) in pages.enumerated() where NSLocationInRange(r.location, pr) { return i }
        return nil
    }

    func jumpToLine(_ line: String) {
        if let idx = locate(line) {
            pageIndex = idx
            saveProgress(page: idx)
            jumpToken += 1
        }
        showSearch = false
    }

    func jumpToChapter(_ i: Int, locateLine line: String) {
        showSearch = false
        openChapter(i, atStart: true)
        jumpToken += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let idx = locate(line) {
                pageIndex = idx
                saveProgress(page: idx)
            }
        }
    }

    // MARK: 书签列表

    var bookmarksSheet: some View {
        NavigationStack {
            List {
                if bookBookmarks.isEmpty {
                    Text("这本书还没有书签。阅读中点右上角书签按钮添加。").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(bookBookmarks) { bm in
                    Button { jumpToBookmark(bm) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bm.snippet).lineLimit(2)
                            Text("第 \(bm.chapterIndex + 1) 章").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { showBookmarks = false } } }
        }
    }

    // MARK: 换源

    var sourceChangeSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("搜书名（换源）", text: $sourceChangeKey)
                        .textFieldStyle(.roundedBorder)
                    Button("搜索") { searchForChangeSource() }.disabled(sourceChangeKey.isEmpty || sourceChangeLoading)
                }.padding()
                if sourceChangeLoading { ProgressView("多源搜索中…") }
                List(sourceChangeResults) { r in
                    Button { changeSource(to: r) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.title).font(.headline)
                            HStack {
                                if !r.author.isEmpty { Text(r.author).font(.caption).foregroundStyle(.secondary) }
                                if !r.sourceName.isEmpty { Text(r.sourceName).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(AppTheme.accentSoft).cornerRadius(6) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("换源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { showSourceChange = false } } }
        }
    }

    // MARK: 整本缓存

    var downloadSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let p = downloadProgress {
                    ProgressView(value: Double(p.0), total: Double(max(p.1, 1)))
                    Text("已缓存 \(p.0) / \(p.1) 章")
                } else {
                    ProgressView("准备缓存…")
                }
            }
            .padding()
            .navigationTitle("缓存全书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { showDownloadAll = false } } }
        }
    }

    // MARK: 设置面板

    var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("背景") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(readerThemes) { t in
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(Color(uiColor: t.background))
                                        .frame(width: 42, height: 42)
                                        .overlay(Circle().stroke(store.theme == t.id ? Color.accentColor : Color.clear, lineWidth: 2))
                                    Text(t.name).font(.caption2)
                                }
                                .onTapGesture { store.theme = t.id; store.save() }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("字体") {
                    Picker("字体", selection: $store.fontName) {
                        ForEach(allFonts) { f in Text(f.display).tag(f.name) }
                    }
                    .onChange(of: store.fontName) { _, _ in store.save() }
                }
                Section("排版") {
                    sliderRow("字号", value: $store.fontSize, range: 12...32, step: 1)
                    sliderRow("行距", value: $store.lineSpacing, range: 0...24, step: 1)
                    sliderRow("段距", value: $store.paragraphSpacing, range: 0...40, step: 1)
                    sliderRow("左右边距", value: $store.pagePaddingH, range: 8...48, step: 1)
                    sliderRow("上下边距", value: $store.pagePaddingV, range: 8...48, step: 1)
                    Picker("翻页动画", selection: $store.pageTurn) {
                        Text("覆盖").tag(0); Text("平移").tag(1); Text("滚动").tag(2); Text("无").tag(3); Text("仿真").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: store.pageTurn) { _, _ in store.save() }
                    sliderRow("翻页速度", value: $store.pageTurnSpeed, range: 0.1...0.8, step: 0.05)
                }
                Section("显示") {
                    Toggle("页眉（章节名）", isOn: $store.showHeader)
                        .onChange(of: store.showHeader) { _, _ in store.save() }
                    Toggle("页脚（页码）", isOn: $store.showFooter)
                        .onChange(of: store.showFooter) { _, _ in store.save() }
                    HStack {
                        Text("亮度")
                        Spacer()
                        if store.brightness < 0 {
                            Button("跟随系统") { store.brightness = 0.5; store.save(); applyBrightness() }
                        } else {
                            Slider(value: $store.brightness, in: 0.05...1.0)
                                .onChange(of: store.brightness) { _, _ in store.save(); applyBrightness() }
                            Button("跟随系统") { store.brightness = -1; store.save(); applyBrightness() }
                        }
                    }
                }
                Section("自动翻页") {
                    Toggle("自动翻页", isOn: Binding(get: { autoPageEnabled }, set: { toggleAutoPage($0) }))
                    if autoPageEnabled {
                        sliderRow("间隔（秒）", value: $autoPageInterval, range: 3...60, step: 1)
                    }
                }
                Section("朗读") {
                    sliderRow("语速", value: $store.ttsRate, range: 0.1...1.0, step: 0.05)
                    sliderRow("音色", value: $store.ttsPitch, range: 0.5...2.0, step: 0.05)
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { showSettings = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(step < 1 ? String(format: "%.2f", value.wrappedValue) : "\(Int(value.wrappedValue))").font(.caption).foregroundColor(.secondary)
        }
        Slider(value: value, in: range, step: step)
            .onChange(of: value.wrappedValue) { _, _ in store.save() }
    }
}
