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

@MainActor struct ReaderView: View {
    @ObservedObject var store: BookStore
    let bookId: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    // 章节 / 分页
    @State private var chapterIndex = 0
    @State private var pages: [NSRange] = []
    @State private var pageIndex = 0
    @State private var attributed: NSAttributedString = NSAttributedString(string: "")
    @State private var speechAfterLoad = false
    @AppStorage("reader.landscapeDoublePage") private var landscapeDoublePage = false
    var usesDoublePage: Bool { landscapeDoublePage && lastSize.width > lastSize.height && store.pageTurn != 2 }
    var pageStep: Int { usesDoublePage ? 2 : 1 }
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
    @State private var selectedDictionary: ReaderSelectedText?
    @State private var selectedShare: ReaderSelectedText?
    @State private var selectedReplacement: ReplaceRule?
    @State private var sourceAction = false
    @State private var paymentAction = false
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
    @AppStorage("reader.customText") private var customText = "3A3A3A"
    @AppStorage("reader.customBackground") private var customBackground = "F5F1E8"
    @AppStorage("reader.backgroundImage") private var backgroundImage = ""
    @AppStorage("reader.backgroundOpacity") private var backgroundOpacity = 0.35
    @AppStorage("reader.keyboardPage") private var keyboardPage = true
    @AppStorage("reader.selectionEnabled") private var selectionEnabled = true
    @AppStorage("reader.swipeDistance") private var swipeDistance = 50.0
    @State private var editingContent = false
    @State private var contentDraft = ""

    // 仿真翻页跳转令牌（目录/书签/换章时强制重建 pageCurl）
    @State private var jumpToken = 0

    // 自动翻页
    @State private var autoPageEnabled = false
    @State private var autoPageInterval: Double = 10
    @State private var autoTimer: Timer?

    @State private var showReplaceRules = false

    // 整本缓存
    @State private var downloadProgress: (Int, Int)?

    // 覆盖翻页手势偏移
    @State private var coverDrag: CGFloat = 0

    // 阅读时长
    @State private var readingStart: Date?
    private let statisticsTick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

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
        "\(store.fontSize)|\(store.lineSpacing)|\(store.paragraphSpacing)|\(store.pagePaddingH)|\(store.pagePaddingV)|\(store.fontName)|\(store.theme)|\(store.showHeader)|\(store.showFooter)|\(store.pageTurn)|\(justifyText)|\(letterSpacing)|\(paragraphIndent)|\(Int(size.width))|\(Int(size.height))|\(customText)|\(customBackground)|\(backgroundImage)|\(backgroundOpacity)|\(landscapeDoublePage)|\(selectionEnabled)"
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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("readerViewport")
            .onAppear {
                lastSize = size
                if scenePhase == .active && readingStart == nil { readingStart = Date() }
                onAppear(size: size)
                if let book, let source = store.sourceForBook(book) { Task.detached { await source.callBookEvent("startRead", book: book) } }
            }
            .onChange(of: layoutSignature(size)) { _, _ in
                rebuild(size: size, keepOffset: currentCharOffset())
                if store.pageTurn == 1 || store.pageTurn == 4 { jumpToken += 1 }
            }
        }
        .background {
            ZStack {
                Color(uiColor: theme.background)
                if let image = ReaderAssets.backgroundImage { Image(uiImage: image).resizable().scaledToFill().opacity(backgroundOpacity) }
            }.ignoresSafeArea().clipped()
        }
        .toolbar(.hidden, for: .navigationBar)
        .background(ReaderKeyboard(enabled: keyboardPage && !showMenu && !showSearch && !showCatalog && !showSettings && !showStyle && !editingContent && !showBookmarks && !sourceAction && !showSourceChange && selectedDictionary == nil && selectedShare == nil && selectedReplacement == nil,
            previous: { if !loading { goPrev(); jumpToken += 1 } }, next: { if !loading { goNext(); jumpToken += 1 } },
            menu: { showMenu.toggle() }).allowsHitTesting(false))
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
            if let book, let source = store.sourceForBook(book) { Task.detached { await source.callBookEvent("endRead", book: book) } }
            store.chapterCache.cancel(bookID: bookId)
            if !loading && chapter?.text.hasPrefix("__URL__") != true { saveProgress() }
            cancelChapterLoad()
            recordReadingTime(resume: false)
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
        .sheet(isPresented: $editingContent) { contentEditor }
        .sheet(item: $selectedDictionary) { selection in NavigationStack { DictionaryLookupView(word: selection.text) } }
        .sheet(item: $selectedShare) { ReaderShareSheet(text: $0.text) }
        .sheet(item: $selectedReplacement) { rule in NavigationStack { ReplaceRuleEditorView(store: store, rule: rule) } }
        .sheet(isPresented: $sourceAction) {
            if let book, let source = store.sourceForBook(book) {
                NavigationStack {
                    SourceCustomActionView(source: source, book: book.sourceBook, chapter: chapter, payment: paymentAction, onPaymentSuccess: {
                        let address = chapter?.url
                        try await store.refreshPurchasedChapter(bookID: bookId, chapterURL: address)
                        cancelChapterLoad()
                        if let updated = self.book { chapterIndex = updated.chapterIndex }
                        chapterLanding = .offset(currentCharOffset()); pages = []; attributed = NSAttributedString(string: "")
                        loadChapterIfNeeded(); jumpToken += 1
                    })
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerSelectionAction)) { notification in
            guard let info = notification.userInfo, let action = info["action"] as? String,
                  let text = info["text"] as? String, !text.isEmpty else { return }
            let offset = info["offset"] as? Int ?? currentCharOffset()
            switch action {
            case "dictionary": selectedDictionary = ReaderSelectedText(text: text, offset: offset)
            case "share": selectedShare = ReaderSelectedText(text: text, offset: offset)
            case "replace":
                var rule = ReplaceRule(); rule.name = "选文替换"; rule.pattern = text; rule.isRegex = false; rule.scope = book?.title ?? ""
                selectedReplacement = rule
            case "speak": speech.stop(); speech.speak(segments: [text], rate: Float(store.ttsRate), pitch: Float(store.ttsPitch))
            case "search": searchText = text; showSearch = true
            case "bookmark":
                store.addBookmark(Bookmark(bookId: bookId, chapterIndex: chapterIndex, paragraphIndex: pageIndex(for: offset), snippet: text, charOffset: offset))
            default: break
            }
        }
        .sheet(isPresented: $showSourceChange) { sourceChangeSheet }
        .sheet(isPresented: $showReplaceRules) {
            NavigationStack { ReplaceRuleView(store: store, bookID: bookId) }
        }
        .onChange(of: book?.useReplaceRule) { _, _ in rebuild(size: lastSize, keepOffset: currentCharOffset()); jumpToken += 1 }
        .onChange(of: store.replaceRules) { _, _ in rebuild(size: lastSize, keepOffset: currentCharOffset()); jumpToken += 1 }
        .onChange(of: speech.error) { _, value in if !value.isEmpty { errorText = value } }
        .onReceive(statisticsTick) { _ in if readingStart != nil { recordReadingTime(resume: scenePhase == .active) } }
        .onChange(of: scenePhase) { _, value in
            if value == .active { if readingStart == nil { readingStart = Date() } }
            else { recordReadingTime(resume: false) }
        }
        .sheet(isPresented: $showDownloadAll) { downloadSheet }
        .alert("加载失败", isPresented: .constant(!errorText.isEmpty)) {
            Button("重试") { errorText = ""; loadChapterIfNeeded() }
            Button("好") { errorText = "" }
        } message: { Text(errorText) }
    }

    // MARK: 阅读内容（按翻页模式分派）

    @ViewBuilder
    func readerContent(size: CGSize) -> some View {
        if usesDoublePage {
            doublePageReader(size: size)
        } else {
        switch store.pageTurn {
        case 2: scrollReader(size: size)
        case 0: coverReader(size: size)
        case 3: noneReader(size: size)
        case 4: curlReader(size: size)
        default: pagedReader(size: size)
        }
        }
    }

    func doublePageReader(size: CGSize) -> some View {
        HStack(spacing: 0) {
            pageView(i: pageIndex, size: CGSize(width: size.width / 2, height: size.height), interactive: false)
            if pages.indices.contains(pageIndex + 1) { pageView(i: pageIndex + 1, size: CGSize(width: size.width / 2, height: size.height), interactive: false) }
            else { Color.clear.frame(width: size.width / 2, height: size.height) }
        }.simultaneousGesture(SpatialTapGesture().onEnded { handleTap($0.location, size: size) })
            .simultaneousGesture(boundarySwipe(width: size.width, allPages: true))
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
                },
                onTapPoint: { point, dimensions in handleTap(point, size: dimensions); jumpToken += 1 }
            )
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .top) {
            if store.showHeader, let c = chapter {
                HStack {
                    Text(store.purify(c.title, book: book, title: true)).font(.system(size: CGFloat(max(store.fontSize - 5, 11)), weight: .medium))
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
        // iOS 17's native page-curl controller retains directional neighbour
        // state after replacing a chapter. Reusing it can ask for the previous
        // page without ever beginning the next reverse animation. Chapter
        // boundaries are committed after didFinishAnimating, so recreate the
        // curl controller there; keep it stable for turns inside a chapter.
        .id(animatedCurl
            ? "curl-\(chapterIndex)-\(chapter?.id ?? "")-\(book?.sourceName ?? "")-\(book?.sourceUrl ?? "")"
            : "page-controller-false")
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
        // Both gestures belong to this surface. Waiting for real horizontal
        // movement leaves the text view's long press available for selection.
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { g in
                    if g.translation.width < 0 && abs(g.translation.width) > abs(g.translation.height) {
                        coverDrag = g.translation.width
                    }
                }
                .onEnded { g in
                    guard !ReaderSelectionDelegate.shared.hasSelection else { coverDrag = 0; return }
                    if g.translation.width < -max(20, swipeDistance) && abs(g.translation.width) > abs(g.translation.height) {
                        goNext()
                    } else if g.translation.width > max(20, swipeDistance) && abs(g.translation.width) > abs(g.translation.height) {
                        goPrev()
                    }
                    withAnimation(.easeOut(duration: store.pageTurnSpeed)) { coverDrag = 0 }
                }
        )
        .simultaneousGesture(SpatialTapGesture().onEnded { handleTap($0.location, size: size) })
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
                    Text(store.purify(c.title, book: book, title: true))
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
        // Short chapters leave most of the viewport outside the content
        // stack. Include that space in the menu tap target on iOS 17.
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
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
        PageTextView(attributed: sub, pageSize: pageSize, chapterOffset: range.location)
            .frame(width: pageSize.width, height: pageSize.height)
            .frame(width: size.width, height: size.height)
            .background(Color.clear)
            .overlay(alignment: .top) {
                if store.showHeader, let c = chapter {
                    HStack {
                        Text(store.purify(c.title, book: book, title: true))
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
            .simultaneousGesture(SpatialTapGesture().onEnded { event in
                if interactive { handleTap(event.location, size: size) }
            })
    }

    func handleTap(_ point: CGPoint, size: CGSize) {
        guard !ReaderSelectionDelegate.shared.hasSelection else { return }
        switch ReaderInteraction.action(at: point, size: size) {
        case .previous: goPrev()
        case .next: goNext()
        case .menu: withAnimation(.easeInOut(duration: 0.15)) { showMenu.toggle() }
        case .bookmark: addBookmark()
        case .speech: toggleSpeech()
        case .previousChapter: openChapter(chapterIndex - 1)
        case .nextChapter: openChapter(chapterIndex + 1)
        case .catalog: showCatalog = true
        case .search: showSearch = true
        case .editContent: openContentEditor()
        case .toggleReplace:
            if var current = book { current.useReplaceRule.toggle(); store.updateBook(current) }
        case .pauseSpeech: if speech.isSpeaking { speech.togglePause() } else { toggleSpeech() }
        case .previousParagraph: if !speech.isSpeaking { toggleSpeech() }; speech.skipParagraph(-1)
        case .nextParagraph: if !speech.isSpeaking { toggleSpeech() }; speech.skipParagraph(1)
        case .none: break
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
                      !ReaderSelectionDelegate.shared.hasSelection,
                      abs(drag.translation.width) > max(20, swipeDistance),
                      abs(drag.translation.width) > abs(drag.translation.height) else { return }
                if drag.translation.width < 0 && (allPages || start >= pages.count - 1) { goNext() }
                if drag.translation.width > 0 && (allPages || start == 0) { goPrev() }
            }
    }

    func goNext() {
        if pageIndex + pageStep < pages.count {
            withAnimation(.easeOut(duration: store.pageTurnSpeed)) { pageIndex += pageStep }
            saveProgress(page: pageIndex)
        } else if chapterIndex < (book?.chapters.count ?? 0) - 1 {
            openChapter(chapterIndex + 1, atStart: true)
        }
    }

    func goPrev() {
        if pageIndex > 0 {
            withAnimation(.easeOut(duration: store.pageTurnSpeed)) { pageIndex = max(0, pageIndex - pageStep) }
            saveProgress(page: pageIndex)
        } else if chapterIndex > 0 {
            openChapter(chapterIndex - 1, atEnd: true)
        }
    }

    func openChapter(_ i: Int, atStart: Bool = true, atEnd: Bool = false, continuingSpeech: Bool = false) {
        guard let b = book, !b.chapters.isEmpty else { return }
        guard let readable = b.chapters.readableIndex(from: i, direction: i < chapterIndex ? -1 : 1) else { return }
        speech.stop(); speechAfterLoad = continuingSpeech
        chapterIndex = readable
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
            pageIndex = atEnd ? max(0, (pages.count - 1) / pageStep * pageStep) : 0
            if atEnd { scrollProgress.offset = pages.last?.location ?? 0 }
            saveProgress(page: pageIndex)
            store.chapterCache.preload(bookID: bookId, after: chapterIndex)
            resumeSpeechIfNeeded()
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
        let text = NSAttributedString(string: store.purify(c.text, book: book), attributes: baseAttributes())
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
            width: max(size.width / (usesDoublePage ? 2 : 1) - CGFloat(store.pagePaddingH * 2), 100),
            height: max(size.height - CGFloat(store.pagePaddingV * 2) - headerSpace - footerSpace, 100)
        )
        pageSize = newPageSize
        pages = Paginator.paginate(text, pageSize: newPageSize)
        if let off = keepOffset {
            pageIndex = pageIndex(for: off)
        } else {
            pageIndex = max(min(pageIndex, pages.count - 1), 0) / pageStep * pageStep
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
        return idx / pageStep * pageStep
    }

    func onAppear(size: CGSize) {
        guard let b = book else { return }
        let restored = restoredReadingPosition(b)
        chapterIndex = b.chapters.readableIndex(from: restored.chapter) ?? b.chapters.readableIndex(from: restored.chapter, direction: -1) ?? 0
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
            store.chapterCache.preload(bookID: bookId, after: chapterIndex)
        }
    }

    func applyBrightness() {
        if store.brightness < 0 {
            UIScreen.main.brightness = initialBrightness
        } else {
            UIScreen.main.brightness = CGFloat(store.brightness)
        }
    }

    func recordReadingTime(resume: Bool) {
        let end = Date()
        if let start = readingStart, var current = book {
            let added = ReadingStatistics.shared.record(bookID: current.id, title: current.title, from: start, to: end)
            if added > 0 { current.totalMinutes += added; store.updateBook(current) }
        }
        readingStart = resume ? end : nil
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
        if let source = store.sourceForBook(b), source.eventListener {
            let current = chapter
            Task.detached { await source.callBookEvent("saveRead", book: b, chapter: current) }
        }
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
        guard store.sourceForBook(b) != nil else {
            errorText = "这本书的书源已删除或未启用，无法拉取在线章节"
            return
        }
        loading = true
        let idx = chapterIndex
        let token = chapterLoadToken
        chapterLoadTask = Task { @MainActor in
            defer {
                if chapterLoadToken == token { loading = false; chapterLoadTask = nil }
            }
            do {
                // One deadline covers all pagination and synchronous JS retries.
                let content = try await store.chapterCache.content(bookID: bookId, index: idx)
                guard !Task.isCancelled, chapterLoadToken == token, chapterIndex == idx,
                      var nb = store.books.first(where: { $0.id == bookId }),
                      nb.chapters.indices.contains(idx), nb.chapters[idx].id == ch.id else { return }
                nb.chapters[idx].text = content
                store.updateBook(nb)
                switch chapterLanding {
                case .start: rebuild(size: lastSize, keepOffset: 0)
                case .end:
                    rebuild(size: lastSize, keepOffset: nil)
                    pageIndex = max(0, (pages.count - 1) / pageStep * pageStep)
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
                store.chapterCache.preload(bookID: bookId, after: idx)
                resumeSpeechIfNeeded()
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
            speechAfterLoad = false
            speech.stop()
            return
        }
        guard let currentChapter = chapter else { return }
        let segments: [String]
        if attributed.length > 0 {
            let start = min(max(currentCharOffset(), 0), attributed.length)
            segments = attributed.attributedSubstring(from: NSRange(location: start, length: attributed.length - start)).string.components(separatedBy: .newlines)
        } else { segments = paragraphs(currentChapter) }
        let speakingChapter = chapterIndex
        speech.speak(segments: segments, rate: Float(store.ttsRate), pitch: Float(store.ttsPitch)) {
            guard chapterIndex == speakingChapter, let b = book,
                  let next = b.chapters.readableIndex(from: speakingChapter + 1) else { return }
            openChapter(next, continuingSpeech: true)
        }
    }

    func resumeSpeechIfNeeded() {
        guard speechAfterLoad else { return }
        speechAfterLoad = false; toggleSpeech()
    }

    func openContentEditor() {
        guard !loading, let chapter, !chapter.text.hasPrefix("__URL__") else { return }
        contentDraft = chapter.text; editingContent = true
    }
    var contentEditor: some View {
        NavigationStack {
            TextEditor(text: $contentDraft).font(.body).padding(8).accessibilityIdentifier("readerContentEditor")
                .navigationTitle("编辑正文").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { editingContent = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            guard var current = book, current.chapters.indices.contains(chapterIndex) else { return }
                            store.chapterCache.cancel(bookID: bookId); speech.stop()
                            let offset = currentCharOffset()
                            current.chapters[chapterIndex].text = contentDraft; store.updateBook(current)
                            rebuild(size: lastSize, keepOffset: offset); jumpToken += 1; editingContent = false
                        }
                    }
                }
        }
    }

    func paragraphs(_ c: BookChapter) -> [String] {
        store.purify(c.text, book: book)
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

    func openSourceChange() { showSourceChange = true }

    func changeSource(to candidate: ReaderSourceCandidate, chapter selectedChapter: Int?) {
        let r = candidate.book
        guard let chapters = candidate.chapters, !chapters.isEmpty,
              let src = store.sources.first(where: { $0.bookSourceUrl == r.sourceUrl && $0.bookSourceName == r.sourceName }),
              var updated = book else { return }
        let previousIndex = chapterIndex
        let previousTitle = chapter?.title ?? ""
        let previousOffset = selectedChapter == nil ? currentCharOffset() : 0
        cancelChapterLoad()
        store.chapterCache.cancel(bookID: bookId)
        updated.sourceName = src.bookSourceName; updated.sourceUrl = src.bookSourceUrl
        updated.bookUrl = r.url; updated.tocUrl = r.tocUrl ?? ""
        updated.chapters = chapters
        func normalized(_ title: String) -> String {
            title.components(separatedBy: .whitespacesAndNewlines).joined().lowercased()
        }
        let name = normalized(previousTitle)
        let matches = chapters.indices.filter { !name.isEmpty && normalized(chapters[$0].title) == name }
        let target = selectedChapter.map { boundedReadingIndex($0, count: chapters.count) }
            ?? matches.min(by: { abs($0 - previousIndex) < abs($1 - previousIndex) })
            ?? boundedReadingIndex(previousIndex, count: chapters.count)
        updated.chapterIndex = target; updated.charOffset = previousOffset
        updated.paragraphIndex = 0
        store.updateBook(updated)
        showSourceChange = false; showMenu = false
        openChapter(target)
        chapterLanding = .offset(previousOffset); scrollProgress.offset = previousOffset
        if !chapters[target].text.hasPrefix("__URL__") {
            rebuild(size: lastSize, keepOffset: previousOffset)
            saveProgress(page: pageIndex); jumpToken += 1
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
            }.accessibilityLabel("返回")
            VStack(alignment: .leading, spacing: 2) {
                Text(book?.title ?? "").font(.headline).lineLimit(1)
                if let c = chapter, store.showHeader {
                    Text(store.purify(c.title, book: book, title: true)).font(.caption).foregroundColor(Color(uiColor: theme.secondary)).lineLimit(1)
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
            moreAction("编辑正文", icon: "square.and.pencil") { openContentEditor() }
            moreAction("替换净化", icon: "wand.and.stars") { showReplaceRules = true }
            moreAction("切换书源", icon: "arrow.triangle.2.circlepath") { openSourceChange() }
            moreAction("缓存全书", icon: "arrow.down.circle") { startDownloadAll() }
            if let book, let source = store.sourceForBook(book) {
                if source.customButton { moreAction("书源自定义按钮", icon: "command") { paymentAction = false; sourceAction = true } }
                if !(source.ruleContent.androidValue("payAction") ?? "").isEmpty {
                    moreAction("购买 / 解锁本章", icon: "lock.open") { paymentAction = true; sourceAction = true }
                }
            }
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
                    set: { pageIndex = Int($0) / pageStep * pageStep; saveProgress(page: pageIndex) }
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
                    NavigationLink("导入字体 / 背景图片 / 自定义配色") { ReaderAppearanceView(store: store) }
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
                        showMenu = false
                        guard let current = book, current.chapters.indices.contains(entry.offset),
                              current.chapters[entry.offset].id == entry.element.id else { return }
                        openChapter(entry.offset, atStart: true)
                    } label: {
                        HStack {
                            Text(store.purify(entry.element.displayTitle, book: book, title: true))
                                .foregroundColor(entry.offset == chapterIndex ? Color.accentColor : .primary)
                            Spacer()
                            if entry.offset == chapterIndex { Image(systemName: "checkmark") }
                            if !entry.element.text.hasPrefix("__URL__") { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                        }
                    }
                    .accessibilityIdentifier("readerChapter-\(entry.offset)")
                    .accessibilityValue(entry.element.text.hasPrefix("__URL__") ? "未缓存" : "已缓存")
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
            let paras = store.purify(ch.text, book: book).components(separatedBy: .newlines)
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

    @ViewBuilder var sourceChangeSheet: some View {
        if let book {
            ReaderSourceChangeView(store: store, current: book) { candidate, index in
                changeSource(to: candidate, chapter: index)
            }
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
                    NavigationLink("点击区域 / 翻页操作") { ReaderInteractionSettingsView() }
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
