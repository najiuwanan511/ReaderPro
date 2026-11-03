import Foundation

// Match HtmlFormatter.formatKeepImg, used by java.htmlFormat. This deliberately
// preserves entities and image URL options instead of rendering HTML as text.
enum SourceHTMLFormatter {
    static func format(_ html: String) -> String {
        var text = html
        for (pattern, replacement) in [
            (#"(&nbsp;)+"#, " "), (#"(&ensp;|&emsp;)"#, " "),
            (#"(&thinsp;|&zwnj;|&zwj;|\u2009|\u200C|\u200D)"#, ""),
            (#"</?(?:div|p|br|hr|h\d|article|dd|dl)[^>]*>"#, "\n"),
            (#"<!--[^>]*-->"#, ""), (#"</?(?!img)[a-zA-Z]+(?=[ >])[^<>]*>"#, ""),
            (#"\s*\n+\s*"#, "\n　　"), (#"^[\n\s]+"#, "　　"), (#"[\n\s]+$"#, "")
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        let pattern = #"<img[^>]*\ssrc\s*=\s*['"]([^'"{>]*\{(?:[^{}]|\{[^}>]+\})+\})['"][^>]*>|<img[^>]*\sdata-(?:src|original|srcset)\s*=\s*['"]([^'">]+)['"][^>]*>|<img[^>]*\ssrc\s*=\s*"([^">]+)"[^>]*>|<img[^>]*\s(?:data-[^=>]*|src)=\s*['"]([^'">]*)['"][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let original = text as NSString
            let value = (1...4).first(where: { match.range(at: $0).location != NSNotFound }).map { original.substring(with: match.range(at: $0)) } ?? ""
            text = original.replacingCharacters(in: match.range, with: "<img src=\"" + value.trimmingCharacters(in: .whitespacesAndNewlines) + "\">")
        }
        return text
    }
}
