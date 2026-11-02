import SwiftUI
import UIKit
import AVFoundation
import ObjectiveC

// MARK: - 阅读主题

struct ReaderTheme: Identifiable {
    let id: Int
    let name: String
    let background: UIColor
    let text: UIColor
    let secondary: UIColor
}

extension UIColor {
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

let readerThemes: [ReaderTheme] = [
    ReaderTheme(id: 0, name: "纸白",   background: UIColor(hex: 0xF5F1E8), text: UIColor(hex: 0x3A3A3A), secondary: UIColor(hex: 0x9E9E9E)),
    ReaderTheme(id: 1, name: "羊皮纸", background: UIColor(hex: 0xEFE3C3), text: UIColor(hex: 0x5B4636), secondary: UIColor(hex: 0x9A8666)),
    ReaderTheme(id: 2, name: "纯白",   background: UIColor(hex: 0xFFFFFF), text: UIColor(hex: 0x1A1A1A), secondary: UIColor(hex: 0xB0B0B0)),
    ReaderTheme(id: 3, name: "护眼绿", background: UIColor(hex: 0xC8E6C9), text: UIColor(hex: 0x2E4D2E), secondary: UIColor(hex: 0x5C8A5C)),
    ReaderTheme(id: 4, name: "灰色",   background: UIColor(hex: 0xDEDEDE), text: UIColor(hex: 0x333333), secondary: UIColor(hex: 0x8A8A8A)),
    ReaderTheme(id: 5, name: "深色",   background: UIColor(hex: 0x1E1E1E), text: UIColor(hex: 0xB8B8B8), secondary: UIColor(hex: 0x666666)),
    ReaderTheme(id: 6, name: "夜间绿", background: UIColor(hex: 0x0F1B12), text: UIColor(hex: 0x8FA98F), secondary: UIColor(hex: 0x4A6A4A)),
    ReaderTheme(id: 7, name: "夜间蓝", background: UIColor(hex: 0x101828), text: UIColor(hex: 0xA8B6C8), secondary: UIColor(hex: 0x4A5A70)),
]

func readerTheme(at index: Int) -> ReaderTheme {
    let i = max(0, min(index, readerThemes.count - 1))
    return readerThemes[i]
}

// MARK: - 精确分页（TextKit / NSLayoutManager，与渲染同一套排版）

enum Paginator {
    static func paginate(_ attributed: NSAttributedString, pageSize: CGSize) -> [NSRange] {
        guard attributed.length > 0 else { return [NSRange(location: 0, length: 0)] }
        guard pageSize.width > 0, pageSize.height > 0 else { return [] }
        var ranges: [NSRange] = []
        var offset = 0
        while offset < attributed.length {
            // Rendered pages are standalone substrings. Lay out each remaining
            // substring the same way: paragraph indents/spacing at a page break
            // otherwise differ from a multi-container continuation and overflow.
            let rest = attributed.attributedSubstring(from: NSRange(location: offset, length: attributed.length - offset))
            let storage = NSTextStorage(attributedString: rest)
            let layoutManager = NSLayoutManager()
            layoutManager.usesFontLeading = true
            storage.addLayoutManager(layoutManager)
            let container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            container.lineBreakMode = .byCharWrapping
            container.maximumNumberOfLines = 0
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
            let glyphRange = layoutManager.glyphRange(for: container)
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            // A viewport smaller than one glyph cannot display a page. Never
            // put all remaining text into a single overflowing fallback page.
            guard charRange.location == 0, charRange.length > 0 else { return [] }
            let end = min(attributed.length, offset + NSMaxRange(charRange))
            let pageRange = NSRange(location: offset, length: end - offset)
            ranges.append(pageRange)
            offset = end
        }
        return ranges
    }
}

// MARK: - 单页渲染（与分页同一套 TextKit 属性，保证不溢出、不错位）

private var readerSourceTextKey: UInt8 = 0

func makeReaderTextView(attributed: NSAttributedString, size: CGSize) -> UITextView {
    let storage = NSTextStorage(attributedString: attributed)
    let manager = NSLayoutManager(); manager.usesFontLeading = true
    storage.addLayoutManager(manager)
    let container = NSTextContainer(size: size)
    container.lineFragmentPadding = 0
    container.lineBreakMode = .byCharWrapping
    container.maximumNumberOfLines = 0
    manager.addTextContainer(container)
    let view = UITextView(frame: CGRect(origin: .zero, size: size), textContainer: container)
    view.backgroundColor = .clear
    view.isEditable = false; view.isSelectable = false
    view.isScrollEnabled = false; view.isUserInteractionEnabled = false
    view.textContainerInset = .zero
    container.widthTracksTextView = false; container.heightTracksTextView = false
    view.attributedText = attributed
    objc_setAssociatedObject(view, &readerSourceTextKey, attributed.copy() as? NSAttributedString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return view
}

// Reassigning identical text invalidates TextKit layout. SwiftUI can update
// the wrapper for unrelated settings, so leave the storage intact in that case.
func setReaderTextIfChanged(_ view: UITextView, _ attributed: NSAttributedString) {
    // UITextView can normalize attributes on assignment, so its textStorage
    // is not necessarily equal to the original source even when unchanged.
    // Compare the last requested source instead of the normalized storage.
    if let source = objc_getAssociatedObject(view, &readerSourceTextKey) as? NSAttributedString,
       source.isEqual(to: attributed) { return }
    view.textStorage.setAttributedString(attributed)
    objc_setAssociatedObject(view, &readerSourceTextKey, attributed.copy() as? NSAttributedString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

struct PageTextView: UIViewRepresentable {
    let attributed: NSAttributedString
    let pageSize: CGSize

    func makeUIView(context: Context) -> UITextView {
        let tv = makeReaderTextView(attributed: attributed, size: pageSize)
        tv.isAccessibilityElement = true
        tv.accessibilityIdentifier = "readerPage"
        tv.accessibilityLabel = attributed.string
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.textContainer.size = pageSize
        tv.attributedText = attributed
        tv.layoutManager.ensureLayout(for: tv.textContainer)
        tv.setNeedsDisplay()
        tv.accessibilityLabel = attributed.string
    }
}

// MARK: - 全文渲染（滚动模式用，不可滚动、高度自适应）

struct FullTextReader: UIViewRepresentable {
    let attributed: NSAttributedString
    let width: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let tv = makeReaderTextView(attributed: attributed, size: CGSize(width: width, height: 1))
        tv.isAccessibilityElement = true
        tv.accessibilityIdentifier = "readerFullText"
        tv.accessibilityLabel = attributed.string
        tv.backgroundColor = .clear
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.isUserInteractionEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byCharWrapping
        tv.textContainer.widthTracksTextView = false
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        setReaderTextIfChanged(tv, attributed)
        if tv.accessibilityLabel != attributed.string { tv.accessibilityLabel = attributed.string }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let fittingWidth = max(proposal.width ?? width, 1)
        uiView.textContainer.size = CGSize(width: fittingWidth, height: .greatestFiniteMagnitude)
        setReaderTextIfChanged(uiView, attributed)
        uiView.layoutManager.ensureLayout(for: uiView.textContainer)
        return CGSize(width: fittingWidth, height: ceil(uiView.layoutManager.usedRect(for: uiView.textContainer).maxY))
    }
}

// Observe the native scroll view's existing pan recognizer rather than adding
// a competing SwiftUI gesture. iOS 17 can let UIScrollView consume the latter,
// especially when a short chapter does not fill the viewport.
struct ReaderScrollBoundaryObserver: UIViewRepresentable {
    var onBoundary: (Bool) -> Void
    var restoreOffset: Int?
    var restoreToken: Int
    var onPosition: (Int, Bool) -> Void

    func makeUIView(context: Context) -> ReaderScrollBoundaryProbe {
        let view = ReaderScrollBoundaryProbe()
        view.isUserInteractionEnabled = false
        view.onBoundary = onBoundary
        view.onPosition = onPosition
        view.restoreOffset = restoreOffset
        view.restoreToken = restoreToken
        return view
    }

    func updateUIView(_ view: ReaderScrollBoundaryProbe, context: Context) {
        view.onBoundary = onBoundary
        view.onPosition = onPosition
        view.restoreOffset = restoreOffset
        view.restoreToken = restoreToken
        view.scheduleAttach()
    }

    static func dismantleUIView(_ view: ReaderScrollBoundaryProbe, coordinator: ()) {
        view.detach()
    }
}

final class ReaderScrollBoundaryProbe: UIView {
    var onBoundary: ((Bool) -> Void)?
    var onPosition: ((Int, Bool) -> Void)?
    var restoreOffset: Int?
    var restoreToken = 0
    private weak var observedScroll: UIScrollView?
    private weak var observedText: UITextView?
    private var observation: NSKeyValueObservation?
    private var settleWork: DispatchWorkItem?
    private var restoreRetryWork: DispatchWorkItem?
    private var retryToken: Int?
    private var restoreAttempts = 0
    private var restoredToken: Int?
    private var restoring = false
    private var lastPosition: Int?
    private var startedAtTop = false
    private var startedAtBottom = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleAttach()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        scheduleAttach()
    }

    func scheduleAttach() {
        DispatchQueue.main.async { [weak self] in self?.attachIfNeeded() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if observedText == nil || (restoreOffset != nil && restoredToken != restoreToken) { scheduleAttach() }
    }

    private func attachIfNeeded() {
        var parent = superview
        while let view = parent, !(view is UIScrollView) { parent = view.superview }
        guard let scroll = parent as? UIScrollView else { return }
        if scroll !== observedScroll {
            detach()
            observedScroll = scroll
            scroll.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
            observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.publishPosition() }
            }
        }
        if observedText == nil { observedText = findText(in: scroll) }
        restoreIfNeeded()
    }

    func detach() {
        settleWork?.cancel(); settleWork = nil
        restoreRetryWork?.cancel(); restoreRetryWork = nil
        observation?.invalidate(); observation = nil
        observedScroll?.panGestureRecognizer.removeTarget(self, action: #selector(handlePan(_:)))
        observedScroll = nil
        observedText = nil
        restoredToken = nil; retryToken = nil; restoreAttempts = 0; lastPosition = nil
    }

    private func findText(in view: UIView) -> UITextView? {
        if let text = view as? UITextView, text.accessibilityIdentifier == "readerFullText" { return text }
        for child in view.subviews { if let result = findText(in: child) { return result } }
        return nil
    }

    private func restoreIfNeeded() {
        guard let offset = restoreOffset, restoredToken != restoreToken,
              let scroll = observedScroll, let text = observedText,
              text.bounds.width > 0, text.bounds.height > 0, text.textStorage.length > 0 else { return }
        text.layoutManager.ensureLayout(for: text.textContainer)
        let index = min(max(offset, 0), text.textStorage.length - 1)
        let glyph = text.layoutManager.glyphIndexForCharacter(at: index)
        guard glyph < text.layoutManager.numberOfGlyphs else { return }
        let line = text.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let target = text.convert(CGPoint(x: 0, y: line.minY + text.textContainerInset.top), to: scroll).y
        // SwiftUI can lay out the text view before updating the enclosing
        // scroll view's contentSize. Clamping against that temporary size
        // would mark an offset as restored even though it was forced to 0.
        // Short chapters are ready too: they only need to fit within the
        // scroll view's reported content, not to exceed the viewport.
        let textBottom = text.convert(CGPoint(x: 0, y: text.bounds.maxY), to: scroll).y
        guard scroll.bounds.height > 0, scroll.contentSize.height + 1 >= max(0, textBottom) else {
            scheduleRestoreRetry()
            return
        }
        let top = -scroll.adjustedContentInset.top
        let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        restoring = true
        let targetY = offset <= 0 ? top : min(max(target - scroll.adjustedContentInset.top, top), bottom)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: targetY), animated: false)
        restoredToken = restoreToken
        restoreRetryWork?.cancel(); restoreRetryWork = nil
        restoring = false
        publishPosition()
    }

    private func scheduleRestoreRetry() {
        if retryToken != restoreToken { retryToken = restoreToken; restoreAttempts = 0 }
        guard restoreRetryWork == nil, restoreAttempts < 40 else { return }
        restoreAttempts += 1
        let work = DispatchWorkItem { [weak self] in
            self?.restoreRetryWork = nil
            self?.attachIfNeeded()
        }
        restoreRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func publishPosition() {
        guard !restoring, (restoreOffset == nil || restoredToken == restoreToken),
              let scroll = observedScroll, let text = observedText,
              text.textStorage.length > 0 else { return }
        text.layoutManager.ensureLayout(for: text.textContainer)
        guard text.layoutManager.numberOfGlyphs > 0 else { return }
        let visible = text.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.minY + scroll.adjustedContentInset.top), from: scroll)
        let point = CGPoint(x: 0, y: max(0, visible.y - text.textContainerInset.top))
        let glyph = min(text.layoutManager.glyphIndex(for: point, in: text.textContainer), text.layoutManager.numberOfGlyphs - 1)
        let offset = min(text.layoutManager.characterIndexForGlyph(at: glyph), text.textStorage.length)
        if offset != lastPosition { lastPosition = offset; onPosition?(offset, false) }
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onPosition?(offset, true) }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let scroll = observedScroll else { return }
        switch recognizer.state {
        case .began:
            // If the layout never became ready, the user's drag takes
            // precedence over a pending restore and permits saving again.
            if restoreOffset != nil && restoredToken != restoreToken {
                restoredToken = restoreToken
                restoreRetryWork?.cancel(); restoreRetryWork = nil
            }
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            startedAtTop = scroll.contentOffset.y <= top + 4
            startedAtBottom = scroll.contentOffset.y >= bottom - 4
        case .ended:
            let distance = recognizer.translation(in: scroll)
            guard abs(distance.y) > 60, abs(distance.y) > abs(distance.x) else { return }
            if startedAtBottom && distance.y < 0 { DispatchQueue.main.async { [weak self] in self?.onBoundary?(true) } }
            else if startedAtTop && distance.y > 0 { DispatchQueue.main.async { [weak self] in self?.onBoundary?(false) } }
        default: break
        }
    }

    deinit { detach() }
}

// MARK: - 朗读控制器（AVSpeechSynthesizer，逐段续读）

final class SpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking = false
    private let synth = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var rate: Float = 0.5
    private var pitch: Float = 1.0
    private var onDone: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(segments: [String], rate: Float, pitch: Float, onDone: @escaping () -> Void = {}) {
        queue = segments.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        self.rate = rate
        self.pitch = pitch
        self.onDone = onDone
        synth.stopSpeaking(at: .immediate)
        if queue.isEmpty {
            isSpeaking = false
            onDone()
            return
        }
        next()
    }

    private func next() {
        guard !queue.isEmpty else {
            isSpeaking = false
            onDone?()
            return
        }
        let text = queue.removeFirst()
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = rate
        u.pitchMultiplier = pitch
        isSpeaking = true
        synth.speak(u)
    }

    func stop() {
        queue.removeAll()
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.next() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.isSpeaking = false }
    }
}

// MARK: - 字体枚举

struct FontOption: Identifiable {
    var id: String { name }
    let name: String
    let display: String
}

func availableFonts() -> [FontOption] {
    var list: [FontOption] = [FontOption(name: "", display: "系统默认")]
    let presets: [(String, String)] = [
        ("PingFang SC", "苹方"),
        ("Songti SC", "宋体"),
        ("Kaiti SC", "楷体"),
        ("Heiti SC", "黑体"),
        ("Yuanti SC", "圆体"),
        ("Avenir Next", "Avenir Next"),
        ("Georgia", "Georgia"),
        ("Chalkboard SE", "粉笔体"),
    ]
    var seen = Set<String>([""])
    for p in presets {
        if let n = UIFont.fontNames(forFamilyName: p.0).first, !seen.contains(n) {
            seen.insert(n)
            list.append(FontOption(name: n, display: p.1))
        }
    }
    for fam in UIFont.familyNames.sorted() {
        for n in UIFont.fontNames(forFamilyName: fam) where !seen.contains(n) {
            seen.insert(n)
            list.append(FontOption(name: n, display: n))
        }
    }
    return list
}

let allFonts: [FontOption] = availableFonts()

final class PageHostController: UIViewController {
    var index: Int = 0
    var pageSize: CGSize = .zero
    private var textView: UITextView?

    override func viewDidLoad() {
        super.viewDidLoad()
        if let textView, textView.superview == nil {
            view.addSubview(textView)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = pageSize.width > 0 ? pageSize.width : view.bounds.width
        let h = pageSize.height > 0 ? pageSize.height : view.bounds.height
        textView?.frame = CGRect(x: (view.bounds.width - w) / 2, y: (view.bounds.height - h) / 2, width: w, height: h)
    }

    func configure(attributed: NSAttributedString, size: CGSize, background: UIColor, index: Int) {
        self.index = index
        self.pageSize = size
        if textView == nil {
            let tv = makeReaderTextView(attributed: attributed, size: size)
            tv.backgroundColor = .clear
            tv.isEditable = false
            tv.isSelectable = false
            tv.isScrollEnabled = false
            tv.isUserInteractionEnabled = false
            tv.isAccessibilityElement = true
            tv.accessibilityIdentifier = "readerPage"
            tv.textContainerInset = .zero
            tv.textContainer.widthTracksTextView = false
            tv.textContainer.heightTracksTextView = false
            textView = tv
        }
        view.backgroundColor = background
        textView?.textContainer.size = size
        textView?.attributedText = attributed
        textView?.accessibilityLabel = attributed.string
        view.setNeedsLayout()
    }
}

struct CurlPageController: UIViewControllerRepresentable {
    let pages: [NSRange]
    let attributed: NSAttributedString
    let pageSize: CGSize
    let background: UIColor
    var startIndex: Int
    var animatedCurl: Bool = true
    var positionToken: Int = 0
    var hasPreviousChapter: Bool
    var hasNextChapter: Bool
    var onPageChange: (Int) -> Void
    var onChapterBoundary: (Bool) -> Void
    var onEdgeTap: (Bool) -> Void
    var onCenterTap: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let vc = UIPageViewController(
            transitionStyle: animatedCurl ? .pageCurl : .scroll,
            navigationOrientation: .horizontal,
            options: animatedCurl ? [UIPageViewController.OptionsKey.spineLocation: UIPageViewController.SpineLocation.min.rawValue] : nil
        )
        vc.dataSource = context.coordinator
        vc.delegate = context.coordinator
        vc.view.backgroundColor = background
        vc.isDoubleSided = false
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.readerTapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        vc.view.addGestureRecognizer(tap)
        // The centre tap belongs to this same UIKit surface, not a transparent
        // SwiftUI sibling which can intercept the beginning of a page swipe.
        // Edge taps in curl mode still belong to the native curl recognizer.
        for recognizer in vc.gestureRecognizers where recognizer is UITapGestureRecognizer && recognizer !== tap {
            recognizer.require(toFail: tap)
        }
        if let start = context.coordinator.pageVC(for: startIndex) {
            vc.setViewControllers([start], direction: .forward, animated: false)
        }
        return vc
    }

    func updateUIViewController(_ vc: UIPageViewController, context: Context) {
        context.coordinator.update(vc, parent: self)
    }

    static func dismantleUIViewController(_ vc: UIPageViewController, coordinator: Coordinator) {
        coordinator.isActive = false
        vc.delegate = nil
        vc.dataSource = nil
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: CurlPageController
        private var displayed: CurlPageController
        private var transitioning = false
        private var finishing = false
        private var needsRefresh = false
        var isActive = true
        init(_ p: CurlPageController) {
            parent = p
            displayed = p
        }

        @objc func readerTapped(_ tap: UITapGestureRecognizer) {
            guard tap.state == .ended, let view = tap.view, view.bounds.width > 0 else { return }
            let fraction = tap.location(in: view).x / view.bounds.width
            if fraction < 1.0 / 3.0 { parent.onEdgeTap(false) }
            else if fraction > 2.0 / 3.0 { parent.onEdgeTap(true) }
            else { parent.onCenterTap() }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            guard parent.animatedCurl, let view = gestureRecognizer.view, view.bounds.width > 0 else { return true }
            let fraction = touch.location(in: view).x / view.bounds.width
            return fraction >= 1.0 / 3.0 && fraction <= 2.0 / 3.0
        }

        func pageVC(for index: Int) -> PageHostController? {
            let sub: NSAttributedString
            // UIKit may ask for neighbours until its interactive animation
            // completes. All of them must belong to the same chapter snapshot.
            if displayed.pages.indices.contains(index) {
                let range = displayed.pages[index]
                sub = displayed.attributed.attributedSubstring(from: range)
            } else if index == -1 && displayed.hasPreviousChapter {
                sub = NSAttributedString(string: "正在打开上一章…")
            } else if index == displayed.pages.count && displayed.hasNextChapter {
                sub = NSAttributedString(string: "正在打开下一章…")
            } else { return nil }
            let host = PageHostController()
            host.configure(attributed: sub, size: displayed.pageSize, background: displayed.background, index: index)
            return host
        }

        func update(_ vc: UIPageViewController, parent: CurlPageController) {
            self.parent = parent
            needsRefresh = displayed.pages != parent.pages
                || !displayed.attributed.isEqual(to: parent.attributed)
                || displayed.pageSize != parent.pageSize
                || displayed.hasPreviousChapter != parent.hasPreviousChapter
                || displayed.hasNextChapter != parent.hasNextChapter
                || displayed.positionToken != parent.positionToken
            vc.view.backgroundColor = parent.background
            refreshIfNeeded(vc)
        }

        private func refreshIfNeeded(_ vc: UIPageViewController) {
            guard isActive, needsRefresh, !transitioning, !finishing else { return }
            needsRefresh = false
            displayed = parent
            if let start = pageVC(for: parent.startIndex) {
                vc.setViewControllers([start], direction: .forward, animated: false)
            }
        }

        func pageViewController(_ pvc: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            transitioning = true
            trace("begin", index: (pendingViewControllers.first as? PageHostController)?.index)
        }

        private func trace(_ event: String, index: Int?) {
            #if DEBUG || READERPRO_TESTING
            NSLog("ReaderPaging %@ %@ index=%ld count=%ld previous=%d next=%d", String(describing: ObjectIdentifier(self)), event,
                  index ?? Int.min, displayed.pages.count, displayed.hasPreviousChapter ? 1 : 0, displayed.hasNextChapter ? 1 : 0)
            #endif
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let host = vc as? PageHostController, host.index >= 0 else { return nil }
            trace("before", index: host.index)
            return pageVC(for: host.index - 1)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let host = vc as? PageHostController, host.index < displayed.pages.count else { return nil }
            trace("after", index: host.index)
            return pageVC(for: host.index + 1)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            transitioning = false
            guard isActive, !finishing else { return }
            finishing = true
            let index = (pvc.viewControllers?.first as? PageHostController)?.index
            trace(completed ? "completed" : "cancelled", index: index)
            // Defer the chapter/page state update until UIKit has finished
            // resetting its gesture recognizers (especially on iOS 17).
            DispatchQueue.main.async { [weak self, weak pvc] in
                guard let self, let pvc else { return }
                self.finishing = false
                guard self.isActive else { return }
                if self.needsRefresh {
                    self.refreshIfNeeded(pvc)
                    return
                }
                guard completed, let index else { return }
                if index < 0 { self.parent.onChapterBoundary(false) }
                else if index >= self.displayed.pages.count { self.parent.onChapterBoundary(true) }
                else { self.parent.onPageChange(index) }
            }
        }
    }
}
