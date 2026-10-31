import SwiftUI
import Foundation

// MARK: - RSS 文章与解析（标准 RSS 2.0 / Atom）

struct RssArticle: Identifiable {
    let id = UUID()
    var title: String
    var link: String
    var pubDate: String
    var summary: String
    var content: String
}

final class RssParser: NSObject, XMLParserDelegate {
    var articles: [RssArticle] = []
    private var inItem = false
    private var inTitle = false, inLink = false, inPubDate = false, inDesc = false, inContent = false
    private var curTitle = "", curLink = "", curPubDate = "", curDesc = "", curContent = ""
    private var linkHref = ""

    private func reset() {
        curTitle = ""; curLink = ""; curPubDate = ""; curDesc = ""; curContent = ""; linkHref = ""
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "item", "entry":
            inItem = true; reset()
        case "title":
            if inItem { inTitle = true }
        case "link":
            if inItem { inLink = true; if let h = attributeDict["href"] { linkHref = h } }
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

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "item", "entry":
            inItem = false
            let link = (curLink.isEmpty ? linkHref : curLink).trimmingCharacters(in: .whitespacesAndNewlines)
            if !curTitle.isEmpty || !curDesc.isEmpty {
                articles.append(RssArticle(title: curTitle.isEmpty ? "（无标题）" : curTitle, link: link, pubDate: curPubDate, summary: curDesc, content: curContent.isEmpty ? curDesc : curContent))
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

// MARK: - 订阅 tab（对标阅读Sigma「订阅」：RSS 阅读）

struct RssSubscribeView: View {
    @ObservedObject var store: BookStore
    @State private var showManage = false
    @State private var addURL = ""
    @State private var addName = ""
    @State private var showAdd = false
    @State private var feedSource: RssSource?

    var feeds: [RssSource] { store.rssSources }

    var body: some View {
        NavigationStack {
            List {
                if feeds.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有订阅源。订阅源可以是一个 RSS/Atom 地址，也可以是 Legado rssSource JSON。").font(.footnote).foregroundStyle(.secondary)
                        Text("点右上角 + 直接加一个 RSS 地址，或去管理页导入订阅源包。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(feeds) { src in
                    Button {
                        feedSource = src
                    } label: {
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
                .onDelete { idx in
                    for i in idx.sorted(by: >) { if i < store.rssSources.count { store.rssSources.remove(at: i) } }
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
                Button { showManage = true } label: { Image(systemName: "slider.horizontal.3") }
            }
            .sheet(isPresented: $showManage) {
                NavigationStack { RssSourceManagementView(store: store) }
            }
            .sheet(isPresented: $showAdd) {
                NavigationStack {
                    Form {
                        Section("添加 RSS 订阅") {
                            TextField("订阅名称（可选）", text: $addName)
                            TextField("RSS/Atom 地址", text: $addURL).autocapitalization(.none).keyboardType(.URL)
                        }
                        Button("添加") {
                            let url = addURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !url.isEmpty else { return }
                            var src = RssSource()
                            src.sourceName = addName.isEmpty ? url : addName
                            src.sourceUrl = url
                            src.singleUrl = false
                            store.rssSources.append(src); store.save()
                            addName = ""; addURL = ""; showAdd = false
                        }.disabled(addURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .navigationTitle("添加订阅")
                    .toolbar { Button("关闭") { showAdd = false } }
                }
            }
            .sheet(item: $feedSource) { src in
                NavigationStack { FeedReaderView(store: store, source: src) }
            }
        }
    }
}

// MARK: - 订阅源文章列表 + 阅读

struct FeedReaderView: View {
    @ObservedObject var store: BookStore
    let source: RssSource
    @State private var articles: [RssArticle] = []
    @State private var loading = false
    @State private var errText = ""
    @State private var selected: RssArticle?

    var body: some View {
        Group {
            if loading {
                ProgressView("正在拉取订阅…")
            } else if !errText.isEmpty {
                VStack(spacing: 8) {
                    Text(errText).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试") { load() }
                }.padding()
            } else if articles.isEmpty {
                Text("没有解析到文章。这个地址可能不是标准 RSS/Atom，或用浏览器打开订阅源网站。").font(.footnote).foregroundStyle(.secondary).padding()
            } else {
                List(articles) { a in
                    Button { selected = a } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(a.title).font(.headline).lineLimit(2)
                            if !a.pubDate.isEmpty { Text(a.pubDate).font(.caption2).foregroundStyle(.secondary) }
                            if !a.summary.isEmpty { Text(stripHTML(a.summary)).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        }
                    }
                }
            }
        }
        .navigationTitle(source.sourceName.isEmpty ? "订阅阅读" : source.sourceName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if articles.isEmpty { load() } }
        .sheet(item: $selected) { a in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(a.title).font(.title2).bold()
                        if !a.pubDate.isEmpty { Text(a.pubDate).font(.caption).foregroundStyle(.secondary) }
                        Divider()
                        Text(stripHTML(a.content.isEmpty ? a.summary : a.content)).font(.body).lineSpacing(6)
                    }.padding()
                }
                .navigationTitle("文章")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("关闭") { selected = nil } }
            }
        }
    }

    func load() {
        loading = true; errText = ""; articles = []
        let url = source.sourceUrl
        Task {
            do {
                let data = try await fetchBytes(url)
                let parsed = parseRssXML(data)
                await MainActor.run {
                    articles = parsed; loading = false
                    if parsed.isEmpty { errText = "没有解析到文章（可能不是 RSS/Atom，或需要登录）" }
                }
            } catch {
                await MainActor.run { loading = false; errText = "拉取失败：\(error.localizedDescription)" }
            }
        }
    }
}

// 与书源请求共用 Cookie、超时和系统证书校验。
func fetchBytes(_ urlString: String) async throws -> Data {
    guard let url = URL(string: urlString) else { throw URLError(.badURL) }
    var req = URLRequest(url: url)
    req.timeoutInterval = 60
    req.setValue(sourceUA, forHTTPHeaderField: "User-Agent")
    let (data, resp) = try await SourceHTTP.session.data(for: req)
    if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
        throw URLError(.badServerResponse)
    }
    return data
}
