import SwiftUI
import UniformTypeIdentifiers

struct RemoteLibraryEntry: Identifiable, Equatable {
    var id: String { url.absoluteString }
    let url: URL
    let name: String
    let directory: Bool
    let bytes: Int64
}

struct RemoteLibraryClient {
    let root: URL
    var username = ""
    var password = ""
    init(address: String, username: String = "", password: String = "") throws {
        guard var url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw SourceFailure(stage: "远程书库", message: "请输入有效的 WebDAV 目录地址") }
        if !url.path.hasSuffix("/") { url.appendPathComponent("") }
        root = url; self.username = username; self.password = password
    }
    func contains(_ url: URL) -> Bool {
        func port(_ value: URL) -> Int { value.port ?? (value.scheme?.lowercased() == "https" ? 443 : 80) }
        guard url.scheme?.lowercased() == root.scheme?.lowercased(), url.host?.lowercased() == root.host?.lowercased(), port(url) == port(root),
              url.user == nil, url.password == nil else { return false }
        let base = (root.path as NSString).standardizingPath
        let path = (url.path as NSString).standardizingPath
        return base == "/" || path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
    func request(_ url: URL, method: String, body: Data? = nil) throws -> URLRequest {
        guard contains(url) else { throw SourceFailure(stage: "远程书库", message: "地址超出当前书库目录") }
        var request = URLRequest(url: url, timeoutInterval: 90); request.httpMethod = method; request.httpBody = body
        if !username.isEmpty { request.setValue("Basic " + Data((username + ":" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
        return request
    }
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await (SourceHTTP.testSession ?? SourceHTTP.session).data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SourceFailure(stage: "远程书库", message: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)：请检查账号和目录权限")
        }
        try Task.checkCancellation(); return data
    }
    func list(_ folder: URL) async throws -> [RemoteLibraryEntry] {
        var request = try request(folder, method: "PROPFIND", body: Data(#"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>"#.utf8))
        request.setValue("1", forHTTPHeaderField: "Depth"); request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        return try parse(try await send(request), folder: folder)
    }
    func parse(_ data: Data, folder: URL) throws -> [RemoteLibraryEntry] {
        guard data.count <= 8 * 1024 * 1024 else { throw SourceFailure(stage: "远程书库", message: "目录响应过大，请选择较小的目录") }
        let delegate = RemoteLibraryXML(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw SourceFailure(stage: "远程书库", message: "服务器没有返回有效的 WebDAV 目录") }
        var seen = Set<String>()
        return delegate.rows.compactMap { row -> RemoteLibraryEntry? in
            guard let url = URL(string: row.href, relativeTo: folder)?.absoluteURL, contains(url),
                  url.standardized.path != folder.standardized.path, seen.insert(url.absoluteString).inserted else { return nil }
            let name = row.name.isEmpty ? url.lastPathComponent : row.name
            guard row.directory || BookFileImporter.extensions.contains((name as NSString).pathExtension.lowercased()) else { return nil }
            return RemoteLibraryEntry(url: url, name: name, directory: row.directory, bytes: row.bytes)
        }.sorted { $0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func download(_ entry: RemoteLibraryEntry, txtRules: [TxtTocRule]) async throws -> BookFileImportResult {
        guard !entry.directory, entry.bytes <= 200 * 1024 * 1024 else { throw SourceFailure(stage: "远程书库", message: "请选择不超过 200 MB 的书籍文件") }
        let data = try await send(request(entry.url, method: "GET"))
        guard data.count <= 200 * 1024 * 1024 else { throw SourceFailure(stage: "远程书库", message: "文件超过 200 MB") }
        return try BookFileImporter.parse(data, name: entry.name, txtRules: txtRules)
    }
    func upload(_ data: Data, name: String, folder: URL) async throws {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent, name != ".", name != ".." else { throw SourceFailure(stage: "远程书库", message: "文件名无效") }
        _ = try await send(request(folder.appendingPathComponent(name), method: "PUT", body: data))
    }
    func delete(_ entry: RemoteLibraryEntry) async throws {
        guard !entry.directory else { throw SourceFailure(stage: "远程书库", message: "请在 WebDAV 服务端管理目录") }
        _ = try await send(request(entry.url, method: "DELETE"))
    }
}

private final class RemoteLibraryXML: NSObject, XMLParserDelegate {
    struct Row { var href = ""; var name = ""; var directory = false; var bytes: Int64 = 0 }
    var rows: [Row] = []
    private var row = Row(), properties = Row(), stack: [String] = [], text = "", status = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(name); text = ""
        if name == "response" { row = Row() }
        if name == "propstat" { properties = Row(); status = "" }
        if name == "collection" { properties.directory = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href": row.href = value
        case "displayname": properties.name = value
        case "getcontentlength": properties.bytes = Int64(value) ?? 0
        case "status": status = value
        case "propstat":
            if status.split(separator: " ").dropFirst().first == "200" {
                if !properties.name.isEmpty { row.name = properties.name }
                row.directory = row.directory || properties.directory; row.bytes = max(row.bytes, properties.bytes)
            }
        case "response": if !row.href.isEmpty { rows.append(row) }
        default: break
        }
        _ = stack.popLast(); text = ""
    }
}

struct RemoteLibraryView: View {
    @ObservedObject var store: BookStore
    @AppStorage("remoteLibrary.address") private var address = ""
    @State private var username = "", password = ""
    @State private var client: RemoteLibraryClient?
    @State private var folder: URL?
    @State private var entries: [RemoteLibraryEntry] = []
    @State private var query = "", error = "", status = ""
    @State private var loading = false, importing = false
    @State private var selectedDelete: RemoteLibraryEntry?
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    var body: some View {
        List {
            if client == nil {
                Section("WebDAV 书库") {
                    TextField("目录地址", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("账号", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码 / 应用密码", text: $password)
                    Button("连接书库") { connect() }
                }
            } else {
                Section {
                    Text(folder?.path.removingPercentEncoding ?? "").font(.caption).foregroundStyle(.secondary)
                    if let folder, let client, folder.standardized.path != client.root.standardized.path {
                        Button("上一级", systemImage: "arrow.up") { self.folder = folder.deletingLastPathComponent() }
                    }
                    Button("上传书籍到当前目录", systemImage: "square.and.arrow.up") { importing = true }.disabled(operation != nil)
                    Button("断开连接") { operationID = UUID(); operation?.cancel(); operation = nil; client = nil; folder = nil; entries = []; status = ""; loading = false }
                }
                if loading { ProgressView("正在读取目录…") }
                ForEach(entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { entry in
                    Button {
                        if entry.directory { folder = entry.url } else { download(entry) }
                    } label: {
                        HStack {
                            Image(systemName: entry.directory ? "folder" : "book")
                            VStack(alignment: .leading) {
                                Text(entry.name).foregroundStyle(.primary)
                                if !entry.directory { Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }.disabled(operation != nil || loading)
                    .contextMenu { if !entry.directory { Button("删除远程文件", role: .destructive) { selectedDelete = entry } } }
                }
            }
            if !status.isEmpty { Text(status).font(.footnote) }
            if operation != nil { Button("停止操作") { operation?.cancel() } }
            if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.red) }
        }.navigationTitle("远程书库").searchable(text: $query, prompt: "筛选文件名")
        .onAppear { restoreCredentials() }
        .onDisappear { operationID = UUID(); operation?.cancel(); operation = nil }
        .task(id: folder) { await reload() }
        .refreshable { await reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            do {
                let file = try result.get()
                run { client, folder in
                    let accessed = file.startAccessingSecurityScopedResource(); defer { if accessed { file.stopAccessingSecurityScopedResource() } }
                    try await client.upload(Data(contentsOf: file), name: file.lastPathComponent, folder: folder)
                    return nil
                }
            } catch { self.error = sourceErrorMessage(error) }
        }
        .confirmationDialog("确定删除远程文件“\(selectedDelete?.name ?? "")”？", isPresented: Binding(get: { selectedDelete != nil }, set: { if !$0 { selectedDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let entry = selectedDelete { run { client, _ in try await client.delete(entry); return nil } }; selectedDelete = nil }
            Button("取消", role: .cancel) { selectedDelete = nil }
        }
    }
    private func restoreCredentials() {
        if let text = SourceLoginHeaders.get("remoteLibrary." + address), let data = text.data(using: .utf8),
           let fields = try? JSONDecoder().decode([String: String].self, from: data) { username = fields["username"] ?? ""; password = fields["password"] ?? "" }
    }
    private func connect() {
        do {
            let value = try RemoteLibraryClient(address: address, username: username, password: password)
            let data = try JSONEncoder().encode(["username": username, "password": password])
            try SourceLoginHeaders.put(String(decoding: data, as: UTF8.self), source: "remoteLibrary." + address)
            client = value; folder = value.root; error = ""; status = ""
        } catch { self.error = sourceErrorMessage(error) }
    }
    @MainActor private func reload() async {
        guard let client, let folder else { return }
        loading = true; error = ""; entries = []
        do {
            let value = try await client.list(folder)
            guard !Task.isCancelled, self.folder == folder else { return }
            entries = value
        } catch { if !Task.isCancelled { self.error = sourceErrorMessage(error) } }
        if self.folder == folder { loading = false }
    }
    private func download(_ entry: RemoteLibraryEntry) {
        let rules = ReaderRuleLibrary.shared.txtRules
        run { client, _ in try await client.download(entry, txtRules: rules) }
    }
    private func run(_ work: @escaping @Sendable (RemoteLibraryClient, URL) async throws -> BookFileImportResult?) {
        guard operation == nil, let client, let folder else { return }
        let run = UUID(); operationID = run; error = ""; status = "正在处理…"
        operation = Task { @MainActor in
            defer { if operationID == run { operation = nil } }
            let worker = Task.detached { try await work(client, folder) }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard operationID == run, self.client != nil else { return }
                if let result {
                    switch result {
                    case .book(let book): store.updateBook(book); status = "已导入：" + book.title
                    case .lyrics: status = "请选择包含音频的书籍文件"
                    }
                } else { status = "操作完成" }
                await reload()
            } catch { if operationID == run { self.error = sourceErrorMessage(error); status = "" } }
        }
    }
}
