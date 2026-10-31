import Foundation
import Kanna
import SwiftSoup

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
        // Android source rules use Jsoup selectors. Kanna's CSS converter both
        // lacks those extensions and traps on valid :nth-child(n+2) rules.
        // SwiftSoup implements the same selector dialect and throws on invalid
        // selectors, so one imported rule cannot crash the entire source audit.
        do {
            let document = try SwiftSoup.parse(html)
            return try document.select(selector).array().map { node in
                let full = try node.outerHtml()
                let open = full.firstIndex(of: ">").map { String(full[...$0]) } ?? ""
                return HtmlEl(open: open, inner: try node.html(), full: full)
            }
        } catch {
            LegadoJSCtx.failures?.add("CSS 规则解析失败：\(selector)：\(error.localizedDescription)")
            return []
        }
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
