import Foundation

enum BookFileImportResult {
    case book(LocalBook)
    case lyrics(name: String, text: String)
}

enum BookFileImporter {
    static let extensions: Set<String> = ["txt", "epub", "mobi", "azw", "azw3", "docx", "fb2", "pdf", "cbz", "zip", "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "mp4", "mov", "m4v", "mkv", "m3u8", "lrc"]

    static func importURL(_ url: URL) async throws -> BookFileImportResult {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let rules = ReaderRuleLibrary.shared.txtRules
        let worker = Task.detached(priority: .userInitiated) {
            try parse(Data(contentsOf: url), name: url.lastPathComponent, txtRules: rules)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func parse(_ data: Data, name: String, txtRules: [TxtTocRule]) throws -> BookFileImportResult {
        try Task.checkCancellation()
        let name = (name as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let title = (name as NSString).deletingPathExtension
        guard extensions.contains(ext), !data.isEmpty else { throw SourceFailure(stage: "文件导入", message: "文件为空或格式不受支持：" + name) }
        if ext == "lrc" { return .lyrics(name: title, text: decodeTextData(data)) }
        let fileName = UUID().uuidString + "." + ext
        var parsed: LocalBook?
        var images: [(String, Data)] = []
        switch ext {
        case "txt":
            var book = LocalBook(title: title, fileName: fileName, kind: "txt")
            book.chapters = splitTxtChapters(decodeTextData(data), bookTitle: title, rules: txtRules); parsed = book
        case "epub": parsed = parseEpub(data, fileName: name)
        case "mobi", "azw", "azw3": parsed = parseMobi(data, fileName: name)
        case "docx": parsed = parseDocx(data, fileName: name)
        case "fb2": parsed = parseFb2(data, fileName: name)
        case "pdf": parsed = parsePdf(data, fileName: name)
        case "cbz", "zip":
            if let (original, files) = parseCbz(data, fileName: name) {
                var book = original
                // Archives may contain two directories with the same image
                // filename. Assign unique names and preserve directory ordering.
                book.imageNames = []
                for (index, path) in original.imageNames.enumerated() {
                    guard let image = files[path] else { continue }
                    let target = String(format: "%06d", index) + "." + (path as NSString).pathExtension
                    book.imageNames.append(target); images.append((target, image))
                }
                parsed = book
            }
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus":
            var book = LocalBook(title: title, fileName: fileName, kind: "audio")
            book.chapters = [BookChapter(title: title, text: "")]; parsed = book
        default:
            var book = LocalBook(title: title, fileName: fileName, kind: "video")
            book.chapters = [BookChapter(title: "第 1 集", text: "__URL__" + BookStore.filesDir.appendingPathComponent(fileName).absoluteString)]; parsed = book
        }
        guard var book = parsed else { throw SourceFailure(stage: "文件导入", message: "解析失败，文件可能已加密、损坏或没有可阅读内容：" + name) }
        book.fileName = fileName
        try Task.checkCancellation()
        let target = BookStore.filesDir.appendingPathComponent(fileName)
        let directory = BookStore.filesDir.appendingPathComponent(book.id)
        do {
            try data.write(to: target, options: .atomic)
            if !images.isEmpty {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for (name, bytes) in images { try Task.checkCancellation(); try bytes.write(to: directory.appendingPathComponent(name), options: .atomic) }
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            if !images.isEmpty { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
        return .book(book)
    }
}

extension BookStore {
    @MainActor @discardableResult func applyFileImport(_ result: BookFileImportResult) throws -> LocalBook? {
        switch result {
        case .book(let book): updateBook(book); return book
        case .lyrics(let name, let text):
            guard let index = books.firstIndex(where: { $0.isAudio && ($0.title == name || ($0.fileName as NSString).deletingPathExtension == name) }) else {
                throw SourceFailure(stage: "歌词导入", message: "没有找到同名音频书，请先导入对应音频")
            }
            books[index].lyrics = text; saveBooks(); return nil
        }
    }
}

extension LegadoSource {
    var isFile: Bool { bookSourceType == 3 }
    func fileDownloadURLs(book: SourceBook) async throws -> [String] {
        try await withRules(book: book) {
            guard let rule = ruleBookInfo.androidValue("downloadUrls"), !rule.isEmpty else {
                return [book.url]
            }
            let response: SourcePage
            if let cached = book.rulePage, cached.url == SourceHTTP.options(book.url).url { response = cached }
            else { response = try await loadPage(book.url, stage: "文件下载地址") }
            var input = response.text
            if !ruleBookInfo.initRule.isEmpty { input = applyRuleFirst(input, ruleBookInfo.initRule, base: response.url) }
            let addresses = ruleItems(input, rule: rule, base: response.url).map { resolveUrl($0, base: response.url) }.filter { !$0.isEmpty }
            try LegadoJSCtx.failures?.check()
            guard !addresses.isEmpty else { throw SourceFailure(stage: "文件书源", message: "下载地址规则没有返回文件链接", url: book.url) }
            return addresses
        }
    }
    func downloadBookFile(_ address: String, book: SourceBook, txtRules: [TxtTocRule]) async throws -> LocalBook {
        try await withTimeout(180) {
            try await withRules(book: book) {
                let request = try SourceHTTP.request(address, base: book.url, headers: requestHeaders)
                let (data, response) = try await SourceTLS.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw SourceFailure(stage: "文件下载", message: "文件请求失败", url: address)
                }
                var name = response.suggestedFilename ?? request.url?.lastPathComponent ?? ""
                if !BookFileImporter.extensions.contains((name as NSString).pathExtension.lowercased()),
                   let type = SourceHTTP.options(address).options["type"] as? String { name = book.title + "." + type }
                guard case .book(var local) = try BookFileImporter.parse(data, name: name, txtRules: txtRules) else {
                    throw SourceFailure(stage: "文件书源", message: "下载的文件不是书籍")
                }
                if !book.title.isEmpty { local.title = book.title }
                local.author = book.author; local.coverUrl = book.cover
                local.sourceUrl = bookSourceUrl; local.sourceName = bookSourceName; local.bookUrl = book.url
                return local
            }
        }
    }
}
