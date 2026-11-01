import SwiftUI
import Foundation
import WebKit

// MARK: - RSS 文章与解析（标准 RSS 2.0 / Atom）

struct RssArticle: Identifiable {
    let id = UUID()
    var title: String
    var link: String
    var pubDate: String
    var summary: String
    var content: String
    var image: String = ""
}

final class RssParser: NSObject, XMLParserDelegate {
    var articles: [RssArticle] = []
    private var inItem = false
    private var inTitle = false, inLink = false, inPubDate = false, inDesc = false, inContent = false
    private var curTitle = "", curLink = "", curPubDate = "", curDesc = "", curContent = "", curImage = ""
    private var linkHref = ""

    private func reset() {
        curTitle = ""; curLink = ""; curPubDate = ""; curDesc = ""; curContent = ""; curImage = ""; linkHref = ""
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "item", "entry":
            inItem = true; reset()
        case "title":
            if inItem { inTitle = true }
        case "link":
            if inItem { inLink = true; if let h = attributeDict["href"] { linkHref = h } }
        case "enclosure", "media:content", "media:thumbnail":
            // Ignore audio/video enclosures. Media thumbnails are images even
            // when their optional MIME type is omitted.
            let type = attributeDict["type"]?.lowercased() ?? ""
            let medium = attributeDict["medium"]?.lowercased() ?? ""
            if inItem && curImage.isEmpty && (elementName == "media:thumbnail" || type.hasPrefix("image/") || medium == "image") {
                curImage = attributeDict["url"] ?? ""
            }
        case "pubDate", "published", "updated":
            if inItem { inPubDate = true }
        case "description", "summary":
            if inItem { inDesc = true }
        case "content:encoded", "encoded", "content":
            if inItem { inContent = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        if inTitle { curTitle += string }
        if inLink { curLink += string }
        if inPubDate { curPubDate += string }
        if inDesc { curDesc += string }
        if inContent { curContent += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "item", "entry":
            inItem = false
            let link = (curLink.isEmpty ? linkHref : curLink).trimmingCharacters(in: .whitespacesAndNewlines)
            if !curTitle.isEmpty || !curDesc.isEmpty {
                articles.append(RssArticle(title: curTitle.isEmpty ? "（无标题）" : curTitle, link: link, pubDate: curPubDate, summary: curDesc, content: curContent.isEmpty ? curDesc : curContent, image: curImage))
            }
        case "title": inTitle = false
        case "link": inLink = false
        case "pubDate", "published", "updated": inPubDate = false
        case "description", "summary": inDesc = false
        case "content:encoded", "encoded", "content": inContent = false
        default: break
        }
    }
}

func parseRssXML(_ data: Data) -> [RssArticle] {
    let p = RssParser()
    let xp = XMLParser(data: data); xp.delegate = p
    _ = xp.parse()
    return p.articles
}

// MARK: - 订阅

struct RssSubscribeView: View {
    @ObservedObject var store: BookStore
    @State private var showManage = false
    @State private var addURL = ""
    @State private var addName = ""
    @State private var showAdd = false
    @State private var addLoading = false
    @State private var addError = ""
    @State private var feedSource: RssSource?

    var feeds: [RssSource] { store.rssSources.filter { $0.enabled } }

    var body: some View {
        NavigationStack {
            List {
                if feeds.isEmpty {
                    Text("还没有启用的订阅源。可添加 RSS/Atom 地址，或导入阅读的订阅源 JSON 链接。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(feeds) { src in
                    Button { feedSource = src } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(src.sourceName.isEmpty ? src.sourceUrl : src.sourceName).font(.headline).lineLimit(1)
                                Text(src.sourceUrl).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = Set(offsets.map { feeds[$0].id })
                    store.rssSources.removeAll { ids.contains($0.id) }
                    store.save()
                }
            }
            .navigationTitle("订阅")
            .readerNavigationStyle()
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppTheme.surface)
            .toolbar {
                Button { showAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("添加订阅")
                Button { showManage = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("订阅源管理")
            }
            .sheet(isPresented: $showManage) {
                NavigationStack { RssSourceManagementView(store: store) }
            }
            .sheet(isPresented: $showAdd) {
                NavigationStack {
                    Form {
                        Section("添加订阅或导入订阅源") {
                            TextField("名称（普通 RSS 可选）", text: $addName)
                            TextField("RSS/Atom 或阅读订阅源 JSON 链接", text: $addURL)
                                .autocapitalization(.none).keyboardType(.URL)
                                .textInputAutocapitalization(.never).accessibilityIdentifier("rssImportURL")
                            if !addError.isEmpty { Text(addError).foregroundStyle(.red).font(.footnote) }
                        }
                        Button(addLoading ? "正在识别…" : "添加 / 导入") { addSubscription() }
                            .disabled(addLoading || addURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .navigationTitle("添加订阅")
                    .toolbar { Button("关闭") { showAdd = false } }
                }
            }
            .sheet(item: $feedSource) { src in
                NavigationStack {
                    if src.singleUrl { BrowserView(initialURL: src.sourceUrl) }
                    else { FeedReaderView(source: src) }
                }
            }
        }
    }

    @MainActor private func addSubscription() {
        let url = addURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = addName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else {
            addError = "请输入完整的 HTTP 或 HTTPS 链接。"; return
        }
        addLoading = true; addError = ""
        Task {
            do {
                // Detail pages on the source repository need conversion to their JSON API.
                let candidates = yckceoRssJSONCandidates(url) + [url]
                var imported: [RssSource] = []
                var feedData: Data?
                var lastError: Error?
                for candidate in candidates {
                    do {
                        let data = try await fetchBytes(candidate)
                        let decoded = decodeTextData(data)
                        let sources = importRssSourcesDetailed(decoded).sources
                        if !sources.isEmpty { imported = sources; break }
                        if !parseRssXML(data).isEmpty || decoded.range(of: "<(rss|feed|rdf:RDF)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                            feedData = data; break
                        }
                    } catch { lastError = error }
                }
                if !imported.isEmpty {
                    // Remove an old mistaken raw JSON-link entry created by older versions.
                    store.rssSources.removeAll { $0.sourceUrl == url && !imported.contains(where: { $0.sourceUrl == url }) && $0.ruleArticles.isEmpty }
                    store.rssSources = mergeRssSources(store.rssSources, incoming: imported)
                } else if feedData != nil {
                    var src = RssSource(); src.sourceName = name.isEmpty ? url : name
                    src.sourceUrl = url; src.singleUrl = false
                    store.rssSources = mergeRssSources(store.rssSources, incoming: [src])
                } else {
                    addError = lastError.map { "获取失败：" + sourceErrorMessage($0) } ?? "未识别到 RSS/Atom 或阅读订阅源 JSON，请检查链接。"
                    addLoading = false; return
                }
                store.save(); addLoading = false; addName = ""; addURL = ""; showAdd = false
            }
        }
    }
}

// The source can contain several categories; selecting one runs its own URL and rules.
struct FeedReaderView: View {
    let source: RssSource
    @State private var categories: [ExploreCategory] = []
    @State private var error = ""
    @State private var loading = true

    var body: some View {
        Group {
            if loading { ProgressView("正在加载分类…") }
            else if !error.isEmpty {
                VStack { Text(error).font(.footnote).multilineTextAlignment(.center); Button("重试") { Task { await load() } } }.padding()
            } else if categories.count == 1, let category = categories.first {
                FeedArticlesView(source: source, category: category)
            } else {
                List(Array(categories.enumerated()), id: \.offset) { entry in
                    NavigationLink(entry.element.title) { FeedArticlesView(source: source, category: entry.element) }
                }
            }
        }
        .navigationTitle(source.sourceName.isEmpty ? "订阅阅读" : source.sourceName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @MainActor private func load() async {
        loading = true; error = ""
        do { categories = try await source.categories(); loading = false }
        catch { loading = false; self.error = "分类加载失败：" + sourceErrorMessage(error) }
    }
}

struct FeedArticlesView: View {
    let source: RssSource
    let category: ExploreCategory
    @State private var articles: [RssArticle] = []
    @State private var nextURL: String?
    @State private var page = 1
    @State private var loading = false
    @State private var error = ""
    @State private var selected: RssArticle?

    var body: some View {
        Group {
            if loading && articles.isEmpty { ProgressView("正在拉取订阅…") }
            else if !error.isEmpty && articles.isEmpty {
                VStack { Text(error).font(.footnote).multilineTextAlignment(.center); Button("重试") { Task { await load() } } }.padding()
            } else if articles.isEmpty { Text("没有解析到文章，请检查订阅规则或站点状态。").font(.footnote).padding() }
            else {
                List {
                    ForEach(articles) { article in
                        Button { selected = article } label: {
                            HStack(alignment: .top, spacing: 12) {
                                if let imageURL = URL(string: article.image), ["http", "https"].contains(imageURL.scheme?.lowercased() ?? ""), imageURL.host != nil {
                                    AsyncImage(url: imageURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        RoundedRectangle(cornerRadius: 4).fill(AppTheme.surfaceMuted)
                                    }
                                    .frame(width: 76, height: 64).clipped().cornerRadius(4)
                                    .accessibilityLabel("文章封面")
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(article.title).font(.headline).lineLimit(2)
                                    if !article.pubDate.isEmpty { Text(article.pubDate).font(.caption2).foregroundStyle(.secondary) }
                                    if !article.summary.isEmpty { Text(stripHTML(article.summary)).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                }
                            }
                        }
                    }
                    if nextURL != nil {
                        Button(loading ? "正在加载…" : "加载更多") { Task { await loadMore() } }.disabled(loading)
                    }
                    if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle(category.title == "全部" ? source.sourceName : category.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $selected) { article in
            NavigationStack {
                if source.isRssRuleSource && source.ruleContent.isEmpty && source.type == 0 && !article.link.isEmpty {
                    BrowserView(initialURL: article.link)
                } else { FeedArticleView(source: source, article: article) }
            }
        }
    }

    @MainActor private func load() async {
        loading = true; error = ""; page = 1
        do {
            let result = try await source.articles(at: category.url)
            articles = result.articles; nextURL = result.nextURL; loading = false
        } catch { loading = false; self.error = "拉取失败：" + sourceErrorMessage(error) }
    }
    @MainActor private func loadMore() async {
        guard let url = nextURL else { return }
        loading = true; error = ""
        do {
            let result = try await source.articles(at: url, page: page + 1)
            articles.append(contentsOf: result.articles); page += 1; nextURL = result.nextURL; loading = false
        } catch { loading = false; self.error = "加载更多失败：" + sourceErrorMessage(error) }
    }
}

struct FeedArticleView: View {
    let source: RssSource
    let article: RssArticle
    @State private var content = ""
    @State private var loading = true
    @State private var error = ""

    var body: some View {
        Group {
            if loading { ProgressView("正在加载正文…") }
            else if !error.isEmpty { Text(error).font(.footnote).padding() }
            else if content.isEmpty && !article.link.isEmpty && source.type == 0 { BrowserView(initialURL: article.link) }
            else { FeedHTMLView(html: content.isEmpty ? article.link : content, baseURL: article.link, type: source.type) }
        }
        .navigationTitle(article.title).navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                if source.type != 0 && source.ruleContent.isEmpty { content = article.link }
                else { content = try await source.articleContent(article) }
                loading = false
            }
            catch { self.error = "正文加载失败：" + sourceErrorMessage(error); loading = false }
        }
    }
}

struct FeedHTMLView: UIViewRepresentable {
    let html: String
    let baseURL: String
    let type: Int
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        var rendered = html
        if (type == 1 || type == 2), let url = URL(string: trimmed),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            let safeURL = trimmed.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
            rendered = type == 1
                ? "<meta name='viewport' content='width=device-width'><img style='max-width:100%' src=\"\(safeURL)\">"
                : "<meta name='viewport' content='width=device-width'><video style='max-width:100%' controls playsinline src=\"\(safeURL)\"></video>"
        }
        view.loadHTMLString(rendered, baseURL: URL(string: baseURL))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

// 与书源请求共用 Cookie、超时和系统证书校验。
func fetchBytes(_ urlString: String) async throws -> Data {
    guard let url = URL(string: urlString) else { throw URLError(.badURL) }
    var req = URLRequest(url: url)
    req.timeoutInterval = 60
    req.setValue(sourceUA, forHTTPHeaderField: "User-Agent")
    let (data, resp) = try await SourceHTTP.session.data(for: req)
    if let http = resp as? HTTPURLResponse, http.statusCode >= 400 { throw URLError(.badServerResponse) }
    return data
}
