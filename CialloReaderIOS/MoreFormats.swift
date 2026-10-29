import Foundation

// MARK: - DOCX (ZIP + word/document.xml, <w:t> text, <w:p> paragraph)

func parseDocx(_ data: Data, fileName: String) -> LocalBook? {
    let files = unzipToMemory(data)
    guard let xmlData = files["word/document.xml"] else { return nil }
    let xml = decodeTextData(xmlData)
    var text = xml
    text = text.replacingOccurrences(of: "</w:p>", with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: "&amp;", with: "&")
    text = text.replacingOccurrences(of: "&lt;", with: "<")
    text = text.replacingOccurrences(of: "&gt;", with: ">")
    text = text.replacingOccurrences(of: "&quot;", with: "\"")
    text = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    if text.count < 20 { return nil }
    var book = LocalBook(title: (fileName as NSString).deletingPathExtension, fileName: fileName, kind: "docx")
    book.chapters = splitTxtChapters(text, bookTitle: book.title)
    return book
}

// MARK: - FB2 (XML, <section><title><p> as chapter heading, <p> as paragraph)

class Fb2Parser: NSObject, XMLParserDelegate {
    var chapters: [BookChapter] = []
    var currentTitle = "正文"
    var currentLines: [String] = []
    var inTitle = false
    var inP = false
    var currentText = ""
    func flush() {
        let t = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { chapters.append(BookChapter(title: currentTitle, text: t)) }
        currentLines = []
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "title" { inTitle = true; currentText = "" }
        if elementName == "p" { inP = true; currentText = "" }
        if elementName == "section" {
            // new section = new chapter, flush previous
            if !currentLines.isEmpty || chapters.isEmpty == false { flush() }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle || inP { currentText += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "title" {
            inTitle = false
            let t = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                if !currentLines.isEmpty { flush() }
                currentTitle = t
            }
        }
        if elementName == "p" {
            inP = false
            let t = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { currentLines.append(t) }
        }
    }
}

func parseFb2(_ data: Data, fileName: String) -> LocalBook? {
    let p = Fb2Parser()
    let xp = XMLParser(data: data); xp.delegate = p; _ = xp.parse()
    p.flush()
    if p.chapters.isEmpty { return nil }
    var book = LocalBook(title: (fileName as NSString).deletingPathExtension, fileName: fileName, kind: "fb2")
    book.chapters = p.chapters
    return book
}

// MARK: - Translation (free MyMemory API, no key, paragraph at a time)

func translateParagraph(_ text: String) async throws -> String {
    let snippet = String(text.prefix(450))
    guard let q = snippet.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://api.mymemory.translated.net/get?q=\(q)&langpair=auto|zh-CN") else {
        throw NSError(domain: "translate", code: 1)
    }
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.setValue("CialloReaderIOS/1.0", forHTTPHeaderField: "User-Agent")
    let (data, _) = try await URLSession.shared.data(for: req)
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let resp = obj["responseData"] as? [String: Any],
          let t = resp["translatedText"] as? String, !t.isEmpty else {
        throw NSError(domain: "translate", code: 2, userInfo: [NSLocalizedDescriptionKey: "翻译服务没有返回结果（免费额度可能用完，稍后再试）"])
    }
    return t.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
}

// MARK: - EPUB export (for any book in the shelf, including web books after download)

func escapeXML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

func exportEpubData(_ book: LocalBook) -> Data {
    var files: [(name: String, data: Data)] = []
    files.append((name: "mimetype", data: "application/epub+zip".data(using: .utf8)!))
    let container = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    """
    files.append((name: "META-INF/container.xml", data: container.data(using: .utf8)!))
    var manifest = ""
    var spine = ""
    for (i, ch) in book.chapters.enumerated() {
        manifest += "<item id=\"ch\(i)\" href=\"ch\(i).xhtml\" media-type=\"application/xhtml+xml\"/>\n"
        spine += "<itemref idref=\"ch\(i)\"/>\n"
    }
    let opf = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\(escapeXML(book.title))</dc:title><dc:creator>\(escapeXML(book.author))</dc:creator><dc:language>zh</dc:language><dc:identifier id="bookid">\(book.id)</dc:identifier></metadata><manifest>\(manifest)</manifest><spine toc="ncx">\(spine)</spine></package>
    """
    files.append((name: "OEBPS/content.opf", data: opf.data(using: .utf8)!))
    for (i, ch) in book.chapters.enumerated() {
        let paras = ch.text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { "<p>\(escapeXML($0))</p>" }.joined(separator: "\n")
        let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(escapeXML(ch.title))</title></head><body><h2>\(escapeXML(ch.title))</h2>\(paras)</body></html>
        """
        files.append((name: "OEBPS/ch\(i).xhtml", data: xhtml.data(using: .utf8)!))
    }
    return writeStoredZip(files)
}
