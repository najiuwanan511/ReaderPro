import SwiftUI
import Network
import Darwin

struct LocalWebRequest {
    let method: String
    let target: URLComponents
    let body: Data
    static func parse(_ data: Data) throws -> Self? {
        guard data.count <= 64 * 1024 * 1024 else { throw SourceFailure(stage: "Web服务", message: "上传文件超过 64 MB") }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 32768 { throw SourceFailure(stage: "Web服务", message: "请求头过大") }; return nil
        }
        guard let header = String(data: data[..<end.lowerBound], encoding: .utf8) else { throw URLError(.badServerResponse) }
        let lines = header.components(separatedBy: "\r\n"), start = (lines.first ?? "").split(separator: " ")
        guard start.count == 3, let target = URLComponents(string: String(start[1])), target.scheme == nil, target.host == nil else { throw URLError(.badURL) }
        var lengths: [Int] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw URLError(.badServerResponse) }
            let name = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                guard let length = Int(value), (0...64 * 1024 * 1024).contains(length) else { throw URLError(.dataLengthExceedsMaximum) }; lengths.append(length)
            }
            if name == "transfer-encoding" { throw SourceFailure(stage: "Web服务", message: "不支持分块上传") }
        }
        guard lengths.count <= 1 else { throw URLError(.badServerResponse) }
        let count = lengths.first ?? 0
        guard data.count >= end.upperBound + count else { return nil }
        return Self(method: String(start[0]), target: target, body: Data(data[end.upperBound..<(end.upperBound + count)]))
    }
    func value(_ name: String) -> String { target.queryItems?.first(where: { $0.name == name })?.value ?? "" }
}

@MainActor final class LocalWebService: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var addresses: [String] = []
    @Published private(set) var status = "服务未启动"
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private let queue = DispatchQueue(label: "ReaderPro.LocalWebService")
    private var token = ""
    private weak var store: BookStore?
    var loopbackAddress: URL? {
        guard running, let port = listener?.port?.rawValue else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/?key=\(token)")
    }
    func start(store: BookStore) {
        stop(); self.store = store; token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        do {
            let server = try NWListener(using: .tcp, on: .any)
            server.service = NWListener.Service(name: "ReaderPro", type: "_http._tcp")
            listener = server; status = "正在启动…"
            server.stateUpdateHandler = { [weak self, weak server] state in
                Task { @MainActor in
                    guard let self, let server, self.listener === server else { return }
                    switch state {
                    case .ready:
                        self.running = true; self.status = "已启动，请保持应用在前台"
                        let port = server.port?.rawValue ?? 0
                        self.addresses = Self.localAddresses().map { "http://\($0):\(port)/?key=\(self.token)" }
                        if self.addresses.isEmpty { self.status = "已启动，请连接 Wi-Fi 后重新启动服务" }
                    case .failed(let error): self.stop(); self.status = sourceErrorMessage(error)
                    default: break
                    }
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            server.start(queue: queue)
        } catch { status = sourceErrorMessage(error) }
    }
    func stop() {
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll(); timeouts.values.forEach { $0.cancel() }; timeouts.removeAll()
        running = false; addresses = []; status = "服务未启动"
    }
    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel(); timeouts.removeValue(forKey: id)?.cancel() }
    private func accept(_ connection: NWConnection) {
        guard listener != nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        timeouts[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }; self?.close(id)
        }
        receive(id, data: Data())
    }
    private func receive(_ id: UUID, data: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var buffer = data; if let bytes { buffer.append(bytes) }
                do {
                    if let request = try LocalWebRequest.parse(buffer) { await self.respond(id, request: request); return }
                    if complete || error != nil { self.close(id) } else { self.receive(id, data: buffer) }
                } catch { self.send(id, code: 400, mime: "text/plain; charset=utf-8", data: Data(sourceErrorMessage(error).utf8)) }
            }
        }
    }
    private func respond(_ id: UUID, request: LocalWebRequest) async {
        guard !token.isEmpty, request.value("key") == token, let store else { send(id, code: 403, data: Data("访问地址已失效，请使用手机显示的完整地址".utf8)); return }
        do {
            let path = request.target.path
            if request.method == "GET", path == "/" { send(id, mime: "text/html; charset=utf-8", data: Data(Self.page.utf8)); return }
            if request.method == "GET", path == "/books" {
                let books = store.books.map { ["id": $0.id, "title": $0.title, "author": $0.author, "progress": "\(Int($0.progress * 100))%"] }
                send(id, mime: "application/json; charset=utf-8", data: try JSONSerialization.data(withJSONObject: books)); return
            }
            if request.method == "POST", path == "/file" {
                let bytes = request.body, name = request.value("name"), rules = ReaderRuleLibrary.shared.txtRules
                let parsed = try await Task.detached { try BookFileImporter.parse(bytes, name: name, txtRules: rules) }.value
                try store.applyFileImport(parsed); send(id, data: Data("文件已导入书架".utf8)); return
            }
            if request.method == "POST", path == "/rules" {
                let bytes = request.body
                let parsed = await Task.detached { importSourceDocument(String(decoding: bytes, as: UTF8.self)) }.value
                guard !parsed.isEmpty else { throw SourceFailure(stage: "Web服务", message: "未识别出书源或订阅源") }
                let result = store.mergeImportedSources(parsed); send(id, data: Data(result.utf8)); return
            }
            if request.method == "GET", path == "/content", let book = store.books.first(where: { $0.id == request.value("id") }) {
                let text = book.chapters.filter { !$0.text.hasPrefix("__URL__") }.map { $0.title + "\n" + $0.text }.joined(separator: "\n\n")
                send(id, data: Data(text.utf8)); return
            }
            send(id, code: 404, data: Data("没有找到此地址".utf8))
        } catch { send(id, code: 400, data: Data(sourceErrorMessage(error).utf8)) }
    }
    private func send(_ id: UUID, code: Int = 200, mime: String = "text/plain; charset=utf-8", data: Data) {
        guard let connection = connections[id] else { return }
        let header = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Frame-Options: DENY\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { [weak self] _ in Task { @MainActor in self?.close(id) } })
    }
    private static func localAddresses() -> [String] {
        var result: [String] = [], interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }; defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { result.append(String(cString: host)) }
        }
        return Array(Set(result)).sorted()
    }
    private static let page = #"""
    <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>阅读Pro · Web服务</title><style>body{font:16px system-ui;max-width:800px;margin:36px auto;padding:0 20px;background:#f5f6f8;color:#202124}button,input{font:inherit;padding:8px;margin:6px 0}section,article{background:white;padding:16px;border-radius:12px;margin:16px 0}#status{white-space:pre-wrap}a{color:#176940}</style>
    <h1>阅读Pro</h1><p>手机和电脑连接同一网络，手机保持应用在前台。</p>
    <section><h2>传书</h2><input id="file" type="file" multiple><button onclick="upload('file')">上传书籍</button></section>
    <section><h2>导入规则</h2><input id="rules" type="file" accept=".json" multiple><button onclick="upload('rules')">导入书源 / 订阅源</button></section>
    <p id="status" role="status"></p><h2>书架</h2><button onclick="load()">刷新</button><div id="books"></div>
    <script>
    var key=new URLSearchParams(location.search).get('key');
    function url(path){return path+(path.includes('?')?'&':'?')+'key='+encodeURIComponent(key);}
    async function upload(kind){var status=document.getElementById('status');try{for(var f of document.getElementById(kind).files){status.textContent='正在上传：'+f.name;var r=await fetch(url('/'+kind+'?name='+encodeURIComponent(f.name)),{method:'POST',body:f});var text=await r.text();if(!r.ok)throw Error(text);status.textContent=text;}await load();}catch(e){status.textContent=e.message;}}
    async function load(){try{var r=await fetch(url('/books'));if(!r.ok)throw Error(await r.text());var books=await r.json(),list=document.getElementById('books');list.replaceChildren();books.forEach(function(b){var card=document.createElement('article'),title=document.createElement('strong'),info=document.createElement('p'),link=document.createElement('a');title.textContent=b.title;info.textContent=b.author+' · '+b.progress;link.textContent='查看已缓存正文';link.href=url('/content?id='+encodeURIComponent(b.id));link.target='_blank';card.append(title,info,link);list.append(card);});}catch(e){document.getElementById('status').textContent=e.message;}}load();
    </script></html>
    """#
}

struct LocalWebServiceView: View {
    @ObservedObject var store: BookStore
    @StateObject private var service = LocalWebService()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Form {
            Section {
                Toggle("启用 Web 服务", isOn: Binding(get: { service.running }, set: { if $0 { service.start(store: store) } else { service.stop() } }))
                Text(service.status).font(.footnote).foregroundStyle(.secondary)
            }
            if !service.addresses.isEmpty {
                Section("在电脑浏览器打开") {
                    ForEach(service.addresses, id: \.self) { address in
                        Text(address).font(.footnote).textSelection(.enabled)
                        ShareLink("分享地址", item: address)
                    }
                }
            }
            Section { Text("可上传本地书籍、导入书源和订阅源、查看书架与已缓存正文。每次启动生成新的访问地址；离开此页面或应用进入后台会停止服务。").font(.footnote) }
        }.navigationTitle("Web服务")
        .onDisappear { service.stop() }
        .onChange(of: phase) { _, value in if value == .background { service.stop() } }
    }
}
