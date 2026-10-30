import SwiftUI
import UIKit

// MARK: - 代码编辑器（对标阅读Sigma的书源代码编辑器：行号 + 语法高亮 + 查找替换）

struct CodePalette {
    static func bg(_ dark: Bool) -> UIColor {
        dark ? UIColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 1) : UIColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1)
    }
    static func fg(_ dark: Bool) -> UIColor {
        dark ? UIColor(red: 0.85, green: 0.86, blue: 0.88, alpha: 1) : UIColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1)
    }
    static func gutter(_ dark: Bool) -> UIColor {
        dark ? UIColor(red: 0.45, green: 0.47, blue: 0.52, alpha: 1) : UIColor(red: 0.55, green: 0.56, blue: 0.60, alpha: 1)
    }
    static let key = UIColor(red: 0.98, green: 0.66, blue: 0.36, alpha: 1)      // 键名 橙
    static let string = UIColor(red: 0.68, green: 0.80, blue: 0.55, alpha: 1)   // 字符串 绿
    static let number = UIColor(red: 0.50, green: 0.78, blue: 0.85, alpha: 1)   // 数字 青
    static let keyword = UIColor(red: 0.76, green: 0.55, blue: 0.90, alpha: 1)  // true/false/null 紫
    static let punctuation = UIColor(red: 0.60, green: 0.62, blue: 0.66, alpha: 1)
}

final class CodeEditorCoordinator: NSObject, UITextViewDelegate {
    var textView: UITextView!
    var gutter: UILabel!
    var onTextChange: ((String) -> Void)?

    func textViewDidChange(_ tv: UITextView) {
        onTextChange?(tv.text)
        refreshGutter()
        applyHighlight()
    }
    func scrollViewDidScroll(_ sv: UIScrollView) {
        refreshGutter()
    }
    func refreshGutter() {
        guard let tv = textView, let gutter else { return }
        let lines = tv.text.components(separatedBy: "\n").count
        let numbers = (1...max(lines, 1)).map { "\($0)" }.joined(separator: "\n")
        gutter.text = numbers
        // 同步滚动（gutter 跟随 textView 的 contentOffset）
        let offset = tv.contentOffset.y
        gutter.transform = CGAffineTransform(translationX: 0, y: -offset)
    }
    func applyHighlight() {
        guard let tv = textView, tv.text.count < 300_000 else { return }
        let s = tv.text as NSString
        let full = NSRange(location: 0, length: s.length)
        let dark = (tv.backgroundColor ?? .white).isDark
        let attr = NSMutableAttributedString(string: tv.text)
        attr.addAttribute(.foregroundColor, value: CodePalette.fg(dark), range: full)
        attr.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular), range: full)

        // 字符串（含键名，绿色）
        if let re = try? NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#) {
            for m in re.matches(in: tv.text, range: full) {
                attr.addAttribute(.foregroundColor, value: CodePalette.string, range: m.range)
            }
        }
        // 键名（"xxx" 后紧跟冒号，橙色，覆盖字符串绿）
        if let re = try? NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"\s*:"#) {
            for m in re.matches(in: tv.text, range: full) {
                attr.addAttribute(.foregroundColor, value: CodePalette.key, range: m.range)
            }
        }
        // 数字
        if let re = try? NSRegularExpression(pattern: #"-?\b\d+(?:\.\d+)?\b"#) {
            for m in re.matches(in: tv.text, range: full) {
                attr.addAttribute(.foregroundColor, value: CodePalette.number, range: m.range)
            }
        }
        // 关键字
        if let re = try? NSRegularExpression(pattern: #"\b(true|false|null)\b"#) {
            for m in re.matches(in: tv.text, range: full) {
                attr.addAttribute(.foregroundColor, value: CodePalette.keyword, range: m.range)
            }
        }
        tv.attributedText = attr
        tv.selectedRange = NSRange(location: min(tv.selectedRange.location, s.length), length: 0)
    }
}

struct CodeEditorUI: UIViewRepresentable {
    @Binding var text: String
    var isDark: Bool = false

    func makeCoordinator() -> CodeEditorCoordinator { CodeEditorCoordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let dark = isDark

        let gutter = UILabel()
        gutter.numberOfLines = 0
        gutter.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        gutter.textColor = CodePalette.gutter(dark)
        gutter.textAlignment = .right
        gutter.backgroundColor = .clear

        let tv = UITextView()
        tv.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.textColor = CodePalette.fg(dark)
        tv.backgroundColor = CodePalette.bg(dark)
        tv.autocapitalizationType = .none
        tv.autocorrectionType = .no
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        tv.alwaysBounceVertical = true
        tv.delegate = context.coordinator

        container.addSubview(tv)
        container.addSubview(gutter)
        context.coordinator.textView = tv
        context.coordinator.gutter = gutter
        context.coordinator.onTextChange = { self.text = $0 }

        tv.translatesAutoresizingMaskIntoConstraints = false
        gutter.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            gutter.topAnchor.constraint(equalTo: container.topAnchor),
            gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gutter.widthAnchor.constraint(equalToConstant: 42),
            gutter.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tv.topAnchor.constraint(equalTo: container.topAnchor),
            tv.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            tv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        tv.text = text
        DispatchQueue.main.async {
            context.coordinator.refreshGutter()
            context.coordinator.applyHighlight()
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        if tv.text != text {
            tv.text = text
            context.coordinator.refreshGutter()
            context.coordinator.applyHighlight()
        }
    }
}

// MARK: - 查找替换面板

struct CodeEditorView: View {
    var title: String = "编辑代码"
    @Binding var code: String
    var onSave: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var showFind = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var useRegex = false
    @State private var matchCount = 0
    @State private var matches: [NSRange] = []
    @State private var matchIndex = -1

    var body: some View {
        VStack(spacing: 0) {
            CodeEditorUI(text: $code, isDark: true)
            if showFind {
                findPanel
            }
        }
        .background(Color(red: 0.11, green: 0.12, blue: 0.16))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { showFind.toggle() } label: { Image(systemName: "magnifyingglass") }
                if let onSave {
                    Button("保存") { onSave() }
                } else {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    var findPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Text("搜索结果：\(matches.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("正则").font(.caption).foregroundStyle(.secondary)
                Toggle("", isOn: $useRegex).labelsHidden().tint(.orange)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("查找", text: $findText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .onSubmit { runFind() }
                if !findText.isEmpty { Button { findText = ""; matches = [] } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
            }
            .padding(8).background(Color.white.opacity(0.08)).cornerRadius(8)
            HStack {
                Image(systemName: "arrow.2.squarepath").foregroundStyle(.secondary)
                TextField("替换", text: $replaceText).textFieldStyle(.plain).foregroundStyle(.white)
                if !replaceText.isEmpty { Button { replaceText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
            }
            .padding(8).background(Color.white.opacity(0.08)).cornerRadius(8)
            HStack {
                Button("上个") { stepMatch(-1) }.foregroundStyle(.white)
                Button("下个") { stepMatch(1) }.foregroundStyle(.white)
                Button("替换") { replaceOne() }.foregroundStyle(.white)
                Button("全部") { replaceAll() }.foregroundStyle(.white)
            }
        }
        .padding()
        .background(Color(red: 0.16, green: 0.17, blue: 0.21))
    }

    func runFind() {
        guard !findText.isEmpty else { matches = []; matchIndex = -1; return }
        do {
            let options: NSRegularExpression.Options = useRegex ? [] : []
            let pattern = useRegex ? findText : NSRegularExpression.escapedPattern(for: findText)
            let re = try NSRegularExpression(pattern: pattern, options: options)
            let ns = code as NSString
            matches = re.matches(in: code, range: NSRange(location: 0, length: ns.length)).map { $0.range }
            matchIndex = matches.isEmpty ? -1 : 0
        } catch {
            matches = []
        }
    }

    func stepMatch(_ dir: Int) {
        guard !matches.isEmpty else { runFind(); return }
        if matches.isEmpty { return }
        matchIndex = (matchIndex + dir + matches.count) % matches.count
    }

    func replaceOne() {
        guard !matches.isEmpty, matchIndex >= 0, matchIndex < matches.count else { runFind(); return }
        var ns = code as NSString
        code = ns.replacingCharacters(in: matches[matchIndex], with: replaceText)
        runFind()
    }

    func replaceAll() {
        guard !findText.isEmpty else { return }
        do {
            let pattern = useRegex ? findText : NSRegularExpression.escapedPattern(for: findText)
            let re = try NSRegularExpression(pattern: pattern)
            let ns = code as NSString
            code = re.stringByReplacingMatches(in: code, range: NSRange(location: 0, length: ns.length), withTemplate: replaceText)
            runFind()
        } catch {}
    }
}

extension UIColor {
    var isDark: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r + g + b) / 3 < 0.5
    }
}
