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

private enum ReaderChapterLanding {
    case start, end, offset(Int), page(Int)
}

// Scroll offsets change every frame. Keep the latest offset in a stable
// reference so a drag does not invalidate the entire SwiftUI reader tree.
private final class ReaderScrollProgress {
    var offset = 0
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
    @State private var showMoreMenu = false
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
    @State private var chapterLanding: ReaderChapterLanding = .start
    @State private var scrollProgress = ReaderScrollProgress()
    @State private var pageDragStartIndex: Int?
    @State private var initialBrightness: CGFloat = 0.5
    @State private var initialIdleTimerDisabled = false

    // These are reader behaviour preferences, distinct from the appearance
    // controls in the interface panel. AppStorage keeps them across launches.
    @AppStorage("reader.hideStatusBar") private var hideStatusBar = false
    @AppStorage("reader.keepScreenAwake") private var keepScreenAwake = false
    @AppStorage("reader.justifyText") private var justifyText = true
    @AppStorage("reader.letterSpacing") private var letterSpacing = 0.0
    @AppStorage("reader.paragraphIndent") private var paragraphIndent = 0.0

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
        "\(store.fontSize)|\(store.lineSpacing)|\(store.paragraphSpacing)|\(store.pagePaddingH)|\(store.pagePaddingV)|\(store.fontName)|\(store.theme)|\(store.showHeader)|\(store.showFooter)|\(store.pageTurn)|\(justifyText)|\(letterSpacing)|\(paragraphIndent)|\(Int(size.width))|\(Int(size.height))"
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
                if store.pageTurn == 1 || store.pageTurn == 4 { jumpToken += 1 }
            }
        }
        .background(Color(uiColor: theme.background).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(hideStatusBar && !showMenu)
        .onChange(of: showMenu) { _, visible in
            if !visible { showMoreMenu = false }
        }
        .preferredColorScheme(themeBrightness())
        .onChange(of: keepScreenAwake) { _, enabled in
            UIApplication.shared.isIdleTimerDisabled = enabled || initialIdleTimerDisabled
        }
        .onDisappear {
            if !loading && chapter?.text.hasPrefix("__URL__") != true { saveProgress() }
            cancelChapterLoad()
            let minutes = max(0, Int(Date().timeIntervalSince(readingStart) / 60))
            if minutes > 0, var b = store.books.first(where: { $0.id == bookId }) {
                b.totalMinutes += minutes
                store.updateBook(b)
            }
            speech.stop()
            autoTimer?.invalidate()
            UIScreen.main.brightness = initialBrightness
            UIApplication.shared.isIdleTimerDisabled = initialIdleTimerDisabled
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
        // A TabView's underlying scroll view consumes edge swipes on iOS 17,
        // so a simultaneous SwiftUI gesture cannot reliably turn the chapter.
        // Use real neighboring boundary controllers, as in the curl reader.
        pageControllerReader(size: size, animatedCurl: false)
    }

    // 无动画：直接显示当前页
    @ViewBuilder
    func noneReader(size: CGSize) -> some View {
        pageView(i: pageIndex, size: size)
            .frame(width: size.width, height: size.height)
            .simultaneousGesture(boundarySwipe(width: size.width, allPages: true))
    }

    // 仿真翻页（pageCurl 卷曲动画）
    @ViewBuilder
    func curlReader(size: CGSize) -> some View {
        pageControllerReader(size: size, animatedCurl: true)
    }

    @ViewBuilder
    private func pageControllerReader(size: CGSize, animatedCurl: Bool) -> some View {
        ZStack {
            CurlPageController(
                pages: pages,
                attributed: attributed,
                pageSize: pageSize,
                background: theme.background,
                startIndex: pageIndex,
                animatedCurl: animatedCurl,
                positionToken: jumpToken,
                hasPreviousChapter: chapterIndex > 0,
                hasNextChapter: chapterIndex < (book?.chapters.count ?? 0) - 1,
                onPageChange: { idx in
                    pageIndex = idx
                    saveProgress(page: idx)
                },
                onChapterBoundary: { forward in
                    if forward { goNext() } else { goPrev() }
                },
                onEdgeTap: { forward in
                    if forward { goNext() } else { goPrev() }
                    jumpToken += 1
                },
                onCenterTap: {
                    withAnimation(.easeInOut(duration: 0.15)) { showMenu.toggle() }
                }
            )
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .top) {
            if store.showHeader, let c = chapter {
                HStack {
                    Text(c.title).font(.system(size: CGFloat(max(store.fontSize - 5, 11)), weight: .medium))
                        .foregroundColor(Color(uiColor: theme.secondary)).lineLimit(1)
                    Spacer()
                }.padding(.horizontal, CGFloat(store.pagePaddingH))
                    .padding(.top, CGFloat(max(store.pagePaddingV * 0.35, 6)))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if store.showFooter {
                HStack { Text("第 \(pageIndex + 1) 页"); Spacer(); Text("共 \(max(pages.count, 1)) 页") }
                    .font(.system(size: CGFloat(max(store.fontSize - 6, 10))))
                    .foregroundColor(Color(uiColor: theme.secondary))
                    .padding(.horizontal, CGFloat(store.pagePaddingH))
                    .padding(.bottom, CGFloat(max(store.pagePaddingV * 0.35, 6)))
                    .allowsHitTesting(false)
            }
        }
        .id("page-controller-\(animatedCurl)")
    }

    // 覆盖：当前页 + 手势左滑盖入下一页
    @ViewBuilder
    func coverReader(size: CGSize) -> some View {
        let w = size.width
        ZStack {
            pageView(i: pageIndex, size: size, interactive: false)
            if pageIndex < pages.count - 1 {
                pageView(i: pageIndex + 1, size: size, interactive: false)
                    .frame(width: size.width, height: size.height)
                    .background(Color(uiColor: theme.background))
                    .offset(x: w + coverDrag)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        // A single parent recognizer handles both taps and horizontal drags.
        // On iOS 17 a parent drag + child tap gesture can swallow the menu.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if g.translation.width < 0 && abs(g.translation.width) > abs(g.translation.height) {
                        coverDrag = g.translation.width
                    }
                }
                .onEnded { g in
                    if g.translation.width < -w * 0.25 && abs(g.translation.width) > abs(g.translation.height) {
                        goNext()
                    } else if g.translation.width > w * 0.25 && abs(g.translation.width) > abs(g.translation.height) {
                        goPrev()
                    } else if abs(g.translation.width) < 10 && abs(g.translation.height) < 10 {
                        let fraction = g.location.x / max(w, 1)
                        if fraction < 1.0 / 3.0 { goPrev() }
                        else if fraction > 2.0 / 3.0 { goNext() }
                        else { withAnimation(.easeInOut(duration: 0.15)) { showMenu.toggle() } }
                    }
                    withAnimation(.easeOut(duration: store.pageTurnSpeed)) { coverDrag = 0 }
                }
        )
    }

    // 滚动：整章连续滚动
    @ViewBuilder
    func scrollReader(size: CGSize) -> some View {
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat(store.paragraphSpacing)) {
                Color.clear.frame(height: 1).id("reader-scroll-top")
                    .background(ReaderScrollBoundaryObserver(onBoundary: { forward in
                        if forward && chapterIndex < (book?.chapters.count ?? 0) - 1 {
                            openChapter(chapterIndex + 1)
                        } else if !forward && chapterIndex > 0 {
                            openChapter(chapterIndex - 1, atEnd: true)
                        }
                    }, restoreOffset: scrollRestoreOffset, restoreToken: jumpToken, onPosition: { offset, settled in
                        scrollProgress.offset = offset
                        if settled {
                            let visiblePage = pageIndex(for: offset)
                            if pageIndex != visiblePage { pageIndex = visiblePage }
                        }
                        #if DEBUG || READERPRO_TESTING
                        if settled && ProcessInfo.processInfo.arguments.contains("--reader-boundary-fixture") {
                            UserDefaults.standard.set(offset, forKey: "ReaderPro.test.visibleScrollOffset")
                        }
                        #endif
                        if settled { saveProgress() }
                    }))
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
                Color.clear.frame(height: 0).id("reader-scroll-bottom")
            }
            .padding(.horizontal, CGFloat(store.pagePaddingH))
            .padding(.vertical, CGFloat(store.pagePaddingV))
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showMenu.toggle() } }
        .onAppear {
            if isEndLanding {
                DispatchQueue.main.async { reader.scrollTo("reader-scroll-bottom", anchor: .bottom) }
            }
        }
        .onChange(of: jumpToken) { _, _ in
            if scrollRestoreOffset == nil {
                reader.scrollTo(isEndLanding ? "reader-scroll-bottom" : "reader-scroll-top", anchor: isEndLanding ? .bottom : .top)
            }
        }
        .onChange(of: loading) { _, active in
            if !active && scrollRestoreOffset == nil { reader.scrollTo(isEndLanding ? "reader-scroll-bottom" : "reader-scroll-top", anchor: isEndLanding ? .bottom : .top) }
        }
        }
    }

    // 单页 + 点按三区（左翻上页 / 中弹菜单 / 右翻下页）
    @ViewBuilder
    func pageView(i: Int, size: CGSize, interactive: Bool = true) -> some View {
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
            .overlay {
                if interactive {
                    HStack(spacing: 0) {
                        Color.clear.contentShape(Rectangle()).onTapGesture { goPrev() }
                        Color.clear.contentShape(Rectangle()).onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showMenu.toggle() } }
                        Color.clear.contentShape(Rectangle()).onTapGesture { goNext() }
                    }
                }
            }
    }

    // MARK: 翻页

    private var isEndLanding: Bool {
        if case .end = chapterLanding { return true }
        return false
    }

    private var scrollRestoreOffset: Int? {
        if case .offset = chapterLanding { return scrollProgress.offset }
        return nil
    }

    private func boundarySwipe(width: CGFloat, allPages: Bool = false) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { _ in if pageDragStartIndex == nil { pageDragStartIndex = pageIndex } }
            .onEnded { drag in
                defer { pageDragStartIndex = nil }
                guard let start = pageDragStartIndex,
                      abs(drag.translation.width) > max(50, width * 0.15),
                      abs(drag.translation.width) > abs(drag.translation.height) else { return }
                if drag.translation.width < 0 && (allPages || start >= pages.count - 1) { goNext() }
                if drag.translation.width > 0 && (allPages || start == 0) { goPrev() }
            }
    }

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
        guard let b = book, !b.chapters.isEmpty else { return }
        chapterIndex = max(0, min(i, b.chapters.count - 1))
        chapterLanding = atEnd ? .end : .start
        scrollProgress.offset = 0
        pageIndex = 0
        if b.chapters[chapterIndex].text.hasPrefix("__URL__") {
            // Do not paginate the URL placeholder or save the previous
            // chapter's page offsets while the new chapter is downloading.
            pages = []
            attributed = NSAttributedString(string: "")
            saveProgress(page: 0)
            loadChapterIfNeeded()
        } else {
            cancelChapterLoad()
            rebuild(size: lastSize, keepOffset: nil)
            pageIndex = atEnd ? max(pages.count - 1, 0) : 0
            if atEnd { scrollProgress.offset = pages.last?.location ?? 0 }
            saveProgress(page: pageIndex)
        }
        jumpToken += 1
    }

    // MARK: 分页与重排

    func baseAttributes() -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = CGFloat(store.lineSpacing)
        para.paragraphSpacing = CGFloat(store.paragraphSpacing)
        para.alignment = justifyText ? .justified : .natural
        para.firstLineHeadIndent = CGFloat(paragraphIndent * store.fontSize)
        para.lineBreakMode = .byCharWrapping
        para.hyphenationFactor = 0
        var attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: theme.text,
            .paragraphStyle: para,
            .kern: letterSpacing,
        ]
        if store.fontName.isEmpty {
            attrs[.font] = UIFont.systemFont(ofSize: CGFloat(store.fontSize))
        } else {
            attrs[.font] = UIFont(name: store.fontName, size: CGFloat(store.fontSize)) ?? UIFont.systemFont(ofSize: CGFloat(store.fontSize))
        }
        return attrs
    }

    func rebuild(size: CGSize, keepOffset: Int?) {
        lastSize = size
        guard let c = chapter, !c.text.hasPrefix("__URL__") else { return }
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
        if store.pageTurn == 2 { return min(max(scrollProgress.offset, 0), attributed.length) }
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
        chapterLanding = .offset(restored.offset)
        scrollProgress.offset = restored.offset
        initialBrightness = UIScreen.main.brightness
        initialIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake || initialIdleTimerDisabled
        applyBrightness()
        if b.chapters.indices.contains(chapterIndex), b.chapters[chapterIndex].text.hasPrefix("__URL__") {
            pages = []
            attributed = NSAttributedString(string: "")
            loadChapterIfNeeded()
        } else {
            rebuild(size: size, keepOffset: restored.offset)
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
        let scrollOffset = min(max(scrollProgress.offset, 0), attributed.length)
        let p = boundedReadingIndex(store.pageTurn == 2 ? pageIndex(for: scrollOffset) : (page ?? pageIndex), count: pages.count)
        b.chapterIndex = boundedReadingIndex(chapterIndex, count: b.chapters.count)
        b.paragraphIndex = p
        if store.pageTurn == 2 { b.charOffset = scrollOffset }
        else if pages.indices.contains(p) {
            b.charOffset = pages[p].location
        } else { b.charOffset = 0 }
        if !b.chapters.isEmpty {
            let pageCount = max(pages.count, 1)
            let frac = store.pageTurn == 2 && attributed.length > 0
                ? Double(scrollOffset) / Double(attributed.length) : Double(p) / Double(pageCount)
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
        let nextURL = b.chapters.indices.contains(idx + 1) ? b.chapters[idx + 1].url : nil
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
                switch chapterLanding {
                case .start: rebuild(size: lastSize, keepOffset: 0)
                case .end:
                    rebuild(size: lastSize, keepOffset: nil)
                    pageIndex = max(pages.count - 1, 0)
                    scrollProgress.offset = pages.indices.contains(pageIndex) ? pages[pageIndex].location : 0
                case .offset(let offset):
                    rebuild(size: lastSize, keepOffset: offset)
                    scrollProgress.offset = min(max(offset, 0), attributed.length)
                case .page(let savedPage):
                    // Old bookmarks contain a page number only. Resolve it
                    // after the network chapter has actually been paginated.
                    rebuild(size: lastSize, keepOffset: nil)
                    pageIndex = boundedReadingIndex(savedPage, count: pages.count)
                    scrollProgress.offset = pages.indices.contains(pageIndex) ? pages[pageIndex].location : 0
                    if store.pageTurn == 2 { chapterLanding = .offset(scrollProgress.offset) }
                }
                saveProgress(page: pageIndex)
                jumpToken += 1
            } catch {
                guard !Task.isCancelled, chapterLoadToken == token else { return }
                errorText = sourceErrorMessage(error)
            }
        }
    }

    // MARK: 朗读 / 书签

    func addBookmark() {
        guard let b = book, b.chapters.indices.contains(chapterIndex) else { return }
        let offset = currentCharOffset()
        let visiblePage = boundedReadingIndex(store.pageTurn == 2 ? pageIndex(for: offset) : pageIndex, count: pages.count)
        var snippet = ""
        if pages.indices.contains(visiblePage) {
            snippet = String(attributed.attributedSubstring(from: pages[visiblePage]).string.prefix(40))
        }
        store.addBookmark(Bookmark(bookId: b.id, chapterIndex: chapterIndex, paragraphIndex: visiblePage, snippet: snippet, charOffset: offset))
    }

    func jumpToBookmark(_ bm: Bookmark) {
        showBookmarks = false
        showMenu = false
        openChapter(bm.chapterIndex, atStart: true)
        if let offset = bm.charOffset {
            chapterLanding = .offset(max(0, offset))
            scrollProgress.offset = max(0, offset)
        } else {
            chapterLanding = .page(bm.paragraphIndex)
        }
        // For an unloaded web chapter, keep the target until loading and
        // pagination finish; pages is intentionally empty at this point.
        guard chapter?.text.hasPrefix("__URL__") != true else { return }
        if let offset = bm.charOffset {
            rebuild(size: lastSize, keepOffset: max(0, offset))
        } else {
            pageIndex = boundedReadingIndex(bm.paragraphIndex, count: pages.count)
            scrollProgress.offset = pages.indices.contains(pageIndex) ? pages[pageIndex].location : 0
            if store.pageTurn == 2 { chapterLanding = .offset(scrollProgress.offset) }
        }
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
        store.theme = isDarkReaderTheme() ? 0 : 5
        store.save()
    }

    func isDarkReaderTheme() -> Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard theme.background.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.5
    }

    func themeBrightness() -> ColorScheme? {
        isDarkReaderTheme() ? .dark : .light
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
        showMenu = false
        guard let src = store.sources.first(where: { $0.bookSourceName == r.sourceName && ($0.bookSourceUrl == r.sourceUrl || r.sourceUrl.isEmpty) }) ?? store.sources.first(where: { $0.bookSourceName == r.sourceName }) else {
            errorText = "找不到对应书源（可能已删除），请重新搜索"
            return
        }
        guard let previousBook = book, previousBook.chapters.indices.contains(chapterIndex) else { return }
        let previousIndex = chapterIndex
        let previousTitle = previousBook.chapters[previousIndex].title
        let previousOffset = currentCharOffset()
        // A pending request for the old source must not replace the new source
        // while its directory is being fetched.
        cancelChapterLoad()
        Task {
            do {
                try await store.reloadBookFromSource(bookId: bookId, source: src, sourceBook: r)
                await MainActor.run {
                    guard let updated = book, !updated.chapters.isEmpty else { return }
                    func normalized(_ title: String) -> String {
                        title.components(separatedBy: .whitespacesAndNewlines).joined().lowercased()
                    }
                    let name = normalized(previousTitle)
                    // Prefer the same chapter title when the sources have
                    // different directory offsets; otherwise keep the old
                    // position as closely as the new directory permits.
                    let matches = updated.chapters.indices.filter { !name.isEmpty && normalized(updated.chapters[$0].title) == name }
                    let target = matches.min(by: { abs($0 - previousIndex) < abs($1 - previousIndex) })
                        ?? min(previousIndex, updated.chapters.count - 1)
                    openChapter(target)
                    chapterLanding = .offset(previousOffset)
                    scrollProgress.offset = previousOffset
                    if !updated.chapters[target].text.hasPrefix("__URL__") {
                        rebuild(size: lastSize, keepOffset: previousOffset)
                        saveProgress(page: pageIndex)
                        jumpToken += 1
                    }
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
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                topBar
                Spacer()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if showMoreMenu { showMoreMenu = false }
                        else { withAnimation(.easeInOut(duration: 0.15)) { showMenu = false } }
                    }
                bottomBar
            }
            if showMoreMenu {
                moreActions
                    .padding(.top, 64)
                    .padding(.trailing, 8)
            }
        }
        .transition(.opacity)
    }

    var topBar: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
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
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            Button { showMoreMenu.toggle() } label: {
                Image(systemName: "ellipsis").font(.system(size: 20))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
                .accessibilityLabel("更多操作")

        }
        .foregroundColor(Color(uiColor: theme.text))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: theme.background).opacity(0.97))
    }

    // Keep actions in the reader's view tree. The iOS 17 native context menu
    // can stall its presentation animation and leave visible rows unable to
    // dispatch their actions. This also avoids presenting a sheet while a
    // separate UIKit menu controller is being dismissed.
    private var moreActions: some View {
        VStack(spacing: 0) {
            moreAction("搜索正文", icon: "magnifyingglass") { showSearch = true }
            moreAction("查看书签", icon: "bookmark") { showBookmarks = true }
            moreAction("切换书源", icon: "arrow.triangle.2.circlepath") { openSourceChange() }
            moreAction("缓存全书", icon: "arrow.down.circle") { startDownloadAll() }
            moreAction(autoPageEnabled ? "关闭自动翻页" : "自动翻页", icon: "play.circle") { toggleAutoPage(!autoPageEnabled) }
        }
        .frame(width: 250)
        .foregroundStyle(Color(uiColor: theme.text))
        .background(Color(uiColor: theme.background), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(uiColor: theme.secondary).opacity(0.2)))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .accessibilityIdentifier("readerMoreActions")
    }

    private func moreAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            showMoreMenu = false
            action()
        } label: {
            HStack(spacing: 12) {
                Text(title).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: icon).frame(width: 24)
            }
            .font(.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    if !editing && (store.pageTurn == 1 || store.pageTurn == 4) { jumpToken += 1 }
                }).disabled(store.pageTurn == 2 || pages.count < 2)
                    .accessibilityLabel("本章阅读进度")
                    .accessibilityIdentifier("readerProgressSlider")
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
                    styleSlider("字号", value: $store.fontSize, range: 12...45)
                    styleSlider("字距", value: $letterSpacing, range: 0...8)
                    styleSlider("行距", value: $store.lineSpacing, range: 0...24)
                    styleSlider("段距", value: $store.paragraphSpacing, range: 0...40)
                    styleSlider("缩进", value: $paragraphIndent, range: 0...4)
                    styleSlider("左右边距", value: $store.pagePaddingH, range: 8...48)
                    styleSlider("上下边距", value: $store.pagePaddingV, range: 8...48)
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
            Text(title).font(.system(size: 14)).frame(width: 60, alignment: .leading)
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
            if store.pageTurn == 2 {
                let match = (attributed.string as NSString).range(of: line)
                if match.location != NSNotFound { scrollProgress.offset = match.location; chapterLanding = .offset(match.location) }
            }
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
                if store.pageTurn == 2 {
                    let match = (attributed.string as NSString).range(of: line)
                    if match.location != NSNotFound { scrollProgress.offset = match.location; chapterLanding = .offset(match.location) }
                    jumpToken += 1
                }
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
                Section("阅读行为") {
                    Toggle("阅读时保持屏幕常亮", isOn: $keepScreenAwake)
                    Toggle("阅读时隐藏状态栏", isOn: $hideStatusBar)
                    Toggle("正文两端对齐", isOn: $justifyText)
                    Toggle("页眉（章节名）", isOn: $store.showHeader)
                        .onChange(of: store.showHeader) { _, _ in store.save() }
                    Toggle("页脚（页码）", isOn: $store.showFooter)
                        .onChange(of: store.showFooter) { _, _ in store.save() }
                }
                Section("屏幕亮度") {
                    Toggle("跟随系统亮度", isOn: Binding(
                        get: { store.brightness < 0 },
                        set: { followsSystem in
                            store.brightness = followsSystem ? -1 : Double(UIScreen.main.brightness)
                            store.save(); applyBrightness()
                        }
                    ))
                    if store.brightness >= 0 {
                        Slider(value: $store.brightness, in: 0.05...1.0)
                            .onChange(of: store.brightness) { _, _ in store.save(); applyBrightness() }
                            .accessibilityLabel("阅读亮度")
                    }
                }
                Section("翻页") {
                    sliderRow("翻页速度", value: $store.pageTurnSpeed, range: 0.1...0.8, step: 0.05)
                }
                Section("自动翻页") {
                    Toggle("自动翻页", isOn: Binding(get: { autoPageEnabled }, set: { toggleAutoPage($0) }))
                    if autoPageEnabled {
                        sliderRow("间隔（秒）", value: $autoPageInterval, range: 3...60, step: 1)
                            .onChange(of: autoPageInterval) { _, _ in toggleAutoPage(true) }
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
