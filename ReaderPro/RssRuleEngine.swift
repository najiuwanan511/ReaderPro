import Foundation

// Legado RSS sources share the same URL, header, JavaScript and selector rules
// as book sources. Keep their source identity and request context isolated.
extension RssSource {
    var ruleSource: LegadoSource {
        var source = LegadoSource()
        source.bookSourceName = sourceName
        source.bookSourceUrl = sourceUrl
        source.header = header
        source.jsLib = jsLib
        source.loginUrl = loginUrl
        source.bookSourceComment = sourceComment
        source.exploreUrl = sortUrl
        return source
    }

    func categories() async throws -> [ExploreCategory] {
        guard !sortUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [ExploreCategory(title: "全部", url: sourceUrl)]
        }
        return try await withTimeout(30) {
            try await self.ruleSource.withRules {
                let categories = self.ruleSource.exploreCategories()
                try LegadoJSCtx.failures?.check()
                return categories.isEmpty ? [ExploreCategory(title: "全部", url: self.sourceUrl)] : categories
            }
        }
    }

    func articles(at address: String, page: Int = 1) async throws -> RssArticlePage {
        try await withTimeout(45) {
            let engine = self.ruleSource
            return try await engine.withRules {
                let response = try await engine.loadPage(address, page: page, stage: "订阅列表")
                guard !self.ruleArticles.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    let articles = parseRssXML(Data(response.text.utf8)).map { item -> RssArticle in
                        var item = item
                        if !item.link.isEmpty { item.link = resolveUrl(item.link, base: response.url) }
                        return item
                    }
                    return RssArticlePage(articles: articles, nextURL: nil)
                }
                let rule = self.ruleArticles
                let reverse = rule.hasPrefix("-")
                let blocks = engine.ruleItems(response.text, rule: reverse ? String(rule.dropFirst()) : rule, base: response.url)
                func field(_ block: String, _ rule: String) -> String {
                    guard !rule.isEmpty else { return "" }
                    return applyRuleFirst(block, rule, base: response.url)
                }
                var items: [RssArticle] = []
                for block in blocks {
                    try Task.checkCancellation()
                    let title = field(block, self.ruleTitle)
                    let address = field(block, self.ruleLink)
                    try LegadoJSCtx.failures?.check()
                    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let link = address.isEmpty ? "" : resolveUrl(address, base: response.url)
                    items.append(RssArticle(title: title, link: link, pubDate: field(block, self.rulePubDate), summary: field(block, self.ruleDescription), content: ""))
                    try LegadoJSCtx.failures?.check()
                }
                if reverse { items.reverse() }
                var next: String?
                if self.ruleNextPage.uppercased() == "PAGE" { next = address }
                else if !self.ruleNextPage.isEmpty {
                    let raw = field(response.text, self.ruleNextPage)
                    if !raw.isEmpty { next = resolveUrl(raw, base: response.url) }
                }
                try LegadoJSCtx.failures?.check()
                return RssArticlePage(articles: items, nextURL: next)
            }
        }
    }

    func articleContent(_ article: RssArticle) async throws -> String {
        guard !ruleContent.isEmpty else { return article.content.isEmpty ? article.summary : article.content }
        guard !article.link.isEmpty else { throw SourceFailure(stage: "订阅正文", message: "文章没有链接") }
        return try await withTimeout(45) {
            let engine = self.ruleSource
            return try await engine.withRules {
                let response = try await engine.loadPage(article.link, stage: "订阅正文")
                let result = applyRule(response.text, self.ruleContent, base: response.url).joined(separator: "\n")
                try LegadoJSCtx.failures?.check()
                guard !result.isEmpty else { throw SourceFailure(stage: "订阅正文", message: "正文规则没有匹配内容", url: response.url) }
                return result
            }
        }
    }
}

struct RssArticlePage {
    var articles: [RssArticle]
    var nextURL: String?
}

// A repeated import updates the existing source instead of adding duplicate rows.
func mergeRssSources(_ existing: [RssSource], incoming: [RssSource]) -> [RssSource] {
    var result = existing
    for var source in incoming {
        if let index = result.firstIndex(where: { !$0.sourceUrl.isEmpty && $0.sourceUrl == source.sourceUrl }) {
            source.id = result[index].id
            source.enabled = result[index].enabled
            result[index] = source
        } else { result.append(source) }
    }
    return result
}
