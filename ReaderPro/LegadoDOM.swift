import Foundation
import Kanna

// Parse malformed HTML with libxml2 instead of treating HTML as a regular
// language. In particular, nested lists, sibling CSS combinators and XPath
// attributes must keep their real parent/child relationships.
enum LegadoDOM {
    static func element(_ node: XMLElement) -> HtmlEl {
        let full = node.toHTML ?? ""
        let open = full.firstIndex(of: ">").map { String(full[...$0]) } ?? ""
        return HtmlEl(open: open, inner: node.innerHTML ?? "", full: full)
    }

    static func css(_ html: String, _ selector: String) -> [HtmlEl] {
        guard let document = try? Kanna.HTML(html: html, encoding: .utf8) else { return [] }
        return document.css(selector).map(element)
    }

    static func xpath(_ html: String, _ expression: String) -> [String] {
        guard let document = try? Kanna.HTML(html: html, encoding: .utf8) else { return [] }
        let result = document.xpath(expression)
        switch result {
        case .String(let text): return text.isEmpty ? [] : [text]
        case .Number(let value): return [String(value)]
        case .Bool(let value): return [value ? "true" : "false"]
        case .NodeSet:
            return result.map { node in
                // Attribute/text nodes have no element markup.
                let html = node.toHTML ?? ""
                return html.hasPrefix("<") ? html : (node.text ?? html)
            }
        case .none: return []
        }
    }

    static func ownText(_ html: String) -> String {
        guard let document = try? Kanna.HTML(html: html, encoding: .utf8) else { return "" }
        let root = document.xpath("//body/*").first
        let nodes = root?.xpath("./text()") ?? document.xpath("//body/text()")
        return nodes.compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
