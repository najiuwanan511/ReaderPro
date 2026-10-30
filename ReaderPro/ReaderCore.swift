import SwiftUI
import UIKit
import AVFoundation

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

func theme(at index: Int) -> ReaderTheme {
    let i = max(0, min(index, readerThemes.count - 1))
    return readerThemes[i]
}

// MARK: - 精确分页（TextKit / NSLayoutManager，与渲染同一套排版）

enum Paginator {
    static func paginate(_ attributed: NSAttributedString, pageSize: CGSize) -> [NSRange] {
        guard attributed.length > 0, pageSize.width > 0, pageSize.height > 0 else {
            return [NSRange(location: 0, length: attributed.length)]
        }
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        var ranges: [NSRange] = []
        var offset = 0
        while offset < attributed.length {
            let container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            let glyphRange = layoutManager.glyphRange(for: container)
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            if charRange.length == 0 { break }
            ranges.append(charRange)
            offset = NSMaxRange(charRange)
        }
        if ranges.isEmpty { ranges = [NSRange(location: 0, length: attributed.length)] }
        return ranges
    }
}

// MARK: - 单页渲染（与分页同一套 TextKit 属性，保证不溢出、不错位）

struct PageTextView: UIViewRepresentable {
    let attributed: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.isUserInteractionEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byCharWrapping
        tv.textContainer.widthTracksTextView = true
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.attributedText = attributed
    }
}

// MARK: - 全文渲染（滚动模式用，不可滚动、高度自适应）

struct FullTextReader: UIViewRepresentable {
    let attributed: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.isUserInteractionEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byCharWrapping
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.attributedText = attributed
    }
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
    let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byCharWrapping
        view.addSubview(textView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = pageSize.width > 0 ? pageSize.width : view.bounds.width
        let h = pageSize.height > 0 ? pageSize.height : view.bounds.height
        textView.frame = CGRect(x: (view.bounds.width - w) / 2, y: (view.bounds.height - h) / 2, width: w, height: h)
    }

    func configure(attributed: NSAttributedString, size: CGSize, background: UIColor, index: Int) {
        self.index = index
        self.pageSize = size
        view.backgroundColor = background
        textView.attributedText = attributed
        view.setNeedsLayout()
    }
}

struct CurlPageController: UIViewControllerRepresentable {
    let pages: [NSRange]
    let attributed: NSAttributedString
    let pageSize: CGSize
    let background: UIColor
    var startIndex: Int
    var onPageChange: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let vc = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [UIPageViewController.OptionsKey.spineLocation: 0]
        )
        vc.dataSource = context.coordinator
        vc.delegate = context.coordinator
        vc.view.backgroundColor = background
        vc.isDoubleSided = false
        if let start = context.coordinator.pageVC(for: startIndex) {
            vc.setViewControllers([start], direction: .forward, animated: false)
        }
        return vc
    }

    func updateUIViewController(_ vc: UIPageViewController, context: Context) {
        context.coordinator.update(vc, parent: self)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: CurlPageController
        var lastPages: [NSRange] = []
        init(_ p: CurlPageController) { parent = p }

        func pageVC(for index: Int) -> PageHostController? {
            guard parent.pages.indices.contains(index) else { return nil }
            let range = parent.pages[index]
            let sub = parent.attributed.attributedSubstring(from: range)
            let host = PageHostController()
            host.configure(attributed: sub, size: parent.pageSize, background: parent.background, index: index)
            return host
        }

        func update(_ vc: UIPageViewController, parent: CurlPageController) {
            let changed = lastPages != parent.pages
            lastPages = parent.pages
            vc.view.backgroundColor = parent.background
            if changed {
                if let start = pageVC(for: parent.startIndex) {
                    vc.setViewControllers([start], direction: .forward, animated: false)
                }
            }
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let host = vc as? PageHostController else { return nil }
            return pageVC(for: host.index - 1)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let host = vc as? PageHostController else { return nil }
            return pageVC(for: host.index + 1)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let host = pvc.viewControllers?.first as? PageHostController else { return }
            parent.onPageChange(host.index)
        }
    }
}
