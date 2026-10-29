import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Models

struct BookChapter: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var title: String
    var text: String
    init(id: String = UUID().uuidString, title: String, text: String) {
        self.id = id; self.title = title; self.text = text
    }
}

struct Bookmark: Identifiable, Codable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var bookId: String
    var chapterIndex: Int
    var paragraphIndex: Int
    var snippet: String
    var date: Date = Date()
}

struct ReplaceRule: Identifiable, Codable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var name: String = ""
    var pattern: String = ""
    var replacement: String = ""
    var enabled: Bool = true
    static var defaults: [ReplaceRule] {
        [
            ReplaceRule(name: "去“本章未完”", pattern: "本章未完，点击下一页继续阅读.*", replacement: ""),
            ReplaceRule(name: "去广告网址行", pattern: "https?://[^\\s\\n]+", replacement: ""),
            ReplaceRule(name: "去多余空行", pattern: "\\n{3,}", replacement: "\n\n")
        ]
    }
}

struct LocalBook: Identifiable, Codable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var title: String
    var author: String = ""
    var coverUrl: String = ""
    var sourceName: String = ""
    var sourceUrl: String = ""
    var fileName: String
    var kind: String // txt, epub, cbz, web
    var chapterIndex: Int = 0
    var paragraphIndex: Int = 0
    var progress: Double = 0
    var lastRead: Date = Date()
    var totalMinutes: Int = 0
    var chapters: [BookChapter] = []
    var imageNames: [String] = []
}

struct SourceBook: Identifiable, Codable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var title: String
    var author: String = ""
    var url: String
    var cover: String = ""
    var intro: String = ""
    var sourceName: String = ""
    var sourceUrl: String = ""
}

// MARK: - Pure Swift DEFLATE inflater (ZIP entries use raw deflate)

struct BitReader {
    var data: Data
    var bitPos: Int = 0
    mutating func bits(_ n: Int) -> Int {
        var v = 0
        for i in 0..<n {
            let byteIndex = bitPos / 8
            let bitIndex = bitPos % 8
            let bit = byteIndex < data.count ? (Int(data[byteIndex]) >> bitIndex) & 1 : 0
            v |= bit << i
            bitPos += 1
        }
        return v
    }
    mutating func alignByte() { bitPos = ((bitPos + 7) / 8) * 8 }
}

struct Huffman {
    var counts: [Int]
    var symbols: [Int]
    init(lengths: [Int]) {
        var counts = [Int](repeating: 0, count: 16)
        for l in lengths where l > 0 { counts[l] += 1 }
        counts[0] = 0
        var offs = [Int](repeating: 0, count: 16)
        for i in 1..<16 { offs[i] = offs[i - 1] + counts[i - 1] }
        var symbols = [Int](repeating: 0, count: lengths.filter { $0 > 0 }.count)
        for (sym, l) in lengths.enumerated() where l > 0 { symbols[offs[l]] = sym; offs[l] += 1 }
        self.counts = counts; self.symbols = symbols
    }
    func decode(_ r: inout BitReader) -> Int {
        var code = 0; var first = 0; var index = 0
        for len in 1..<16 {
            code |= r.bits(1)
            let count = counts[len]
            if code - first < count { return symbols[index + (code - first)] }
            index += count; first += count; first <<= 1; code <<= 1
        }
        return -1
    }
}

let lengthBase = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258]
let lengthExtra = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0]
let distBase = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577]
let distExtra = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13]

func inflate(_ input: Data) -> Data? {
    var r = BitReader(data: input)
    var out = Data()
    while true {
        let bfinal = r.bits(1)
        let btype = r.bits(2)
        if btype == 0 {
            r.alignByte()
            let p = r.bitPos / 8
            guard p + 4 <= input.count else { return nil }
            let len = Int(input[p]) | (Int(input[p + 1]) << 8)
            let start = p + 4
            guard start + len <= input.count else { return nil }
            out.append(input[start..<(start + len)]); r.bitPos = (start + len) * 8
        } else if btype == 1 || btype == 2 {
            var litHuff: Huffman
            var distHuff: Huffman
            if btype == 1 {
                var litLens = [Int](repeating: 0, count: 288)
                for i in 0..<144 { litLens[i] = 8 }
                for i in 144..<256 { litLens[i] = 9 }
                for i in 256..<280 { litLens[i] = 7 }
                for i in 280..<288 { litLens[i] = 8 }
                litHuff = Huffman(lengths: litLens)
                distHuff = Huffman(lengths: [Int](repeating: 5, count: 30))
            } else {
                let hlit = r.bits(5) + 257
                let hdist = r.bits(5) + 1
                let hclen = r.bits(4) + 4
                let order = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15]
                var clLens = [Int](repeating: 0, count: 19)
                for i in 0..<hclen { clLens[order[i]] = r.bits(3) }
                let clHuff = Huffman(lengths: clLens)
                var lens = [Int](repeating: 0, count: hlit + hdist)
                var i = 0
                while i < hlit + hdist {
                    let sym = clHuff.decode(&r)
                    if sym < 16 { lens[i] = sym; i += 1 }
                    else if sym == 16 {
                        guard i > 0 else { return nil }
                        let rep = r.bits(2) + 3
                        for _ in 0..<rep where i < lens.count { lens[i] = lens[i - 1]; i += 1 }
                    } else if sym == 17 {
                        let rep = r.bits(3) + 3; i += rep
                    } else if sym == 18 {
                        let rep = r.bits(7) + 11; i += rep
                    } else { return nil }
                }
                litHuff = Huffman(lengths: Array(lens[0..<hlit]))
                distHuff = Huffman(lengths: Array(lens[hlit..<(hlit + hdist)]))
            }
            while true {
                let sym = litHuff.decode(&r)
                if sym == 256 { break }
                if sym < 256 { out.append(UInt8(sym)); continue }
                if sym < 0 || sym > 285 { return nil }
                let li = sym - 257
                let length = lengthBase[li] + r.bits(lengthExtra[li])
                let dsym = distHuff.decode(&r)
                if dsym < 0 || dsym >= 30 { return nil }
                let dist = distBase[dsym] + r.bits(distExtra[dsym])
                guard dist <= out.count, dist > 0 else { return nil }
                for _ in 0..<length { out.append(out[out.count - dist]) }
            }
        } else { return nil }
        if bfinal == 1 { break }
    }
    return out
}

// MARK: - ZIP reader

struct ZipEntry { var name: String; var method: Int; var compressedSize: Int; var uncompressedSize: Int; var localOffset: Int }

func readZipEntries(_ data: Data) -> [ZipEntry] {
    guard data.count > 22 else { return [] }
    var eocd = -1
    var i = data.count - 22
    while i >= 0 {
        if data[i] == 0x50 && data[i+1] == 0x4B && data[i+2] == 0x05 && data[i+3] == 0x06 { eocd = i; break }
        if data.count - i > 70000 { break }
        i -= 1
    }
    guard eocd >= 0 else { return [] }
    func u16(_ o: Int) -> Int { Int(data[o]) | (Int(data[o+1]) << 8) }
    func u32(_ o: Int) -> Int { Int(data[o]) | (Int(data[o+1]) << 8) | (Int(data[o+2]) << 16) | (Int(data[o+3]) << 24) }
    let count = u16(eocd + 10)
    let cdOffset = u32(eocd + 16)
    var entries: [ZipEntry] = []
    var p = cdOffset
    for _ in 0..<count {
        guard p + 46 <= data.count, data[p] == 0x50, data[p+1] == 0x4B, data[p+2] == 0x01, data[p+3] == 0x02 else { break }
        let method = u16(p + 10)
        let cSize = u32(p + 20)
        let uSize = u32(p + 24)
        let nLen = u16(p + 28); let eLen = u16(p + 30); let cLen = u16(p + 32)
        let local = u32(p + 42)
        guard p + 46 + nLen <= data.count else { break }
        let nameData = data[(p+46)..<(p+46+nLen)]
        let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
        entries.append(ZipEntry(name: name, method: method, compressedSize: cSize, uncompressedSize: uSize, localOffset: local))
        p += 46 + nLen + eLen + cLen
    }
    return entries
}

func extractZipEntry(_ data: Data, _ entry: ZipEntry) -> Data? {
    let p = entry.localOffset
    guard p + 30 <= data.count else { return nil }
    func u16(_ o: Int) -> Int { Int(data[o]) | (Int(data[o+1]) << 8) }
    let nLen = u16(p + 26); let eLen = u16(p + 28)
    let start = p + 30 + nLen + eLen
    guard start + entry.compressedSize <= data.count else { return nil }
    let raw = data[start..<(start + entry.compressedSize)]
    if entry.method == 0 { return Data(raw) }
    if entry.method == 8 { return inflate(Data(raw)) }
    return nil
}

func unzipToMemory(_ data: Data) -> [String: Data] {
    var out: [String: Data] = [:]
    for e in readZipEntries(data) where !e.name.hasSuffix("/") {
        if let d = extractZipEntry(data, e) { out[e.name] = d }
    }
    return out
}

// MARK: - Text helpers

func stripHTML(_ html: String) -> String {
    var s = html
    s = s.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "</p>", with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "</div>", with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: "&nbsp;", with: " ")
    s = s.replacingOccurrences(of: "&amp;", with: "&")
    s = s.replacingOccurrences(of: "&lt;", with: "<")
    s = s.replacingOccurrences(of: "&gt;", with: ">")
    s = s.replacingOccurrences(of: "&quot;", with: "\"")
    return s
}

func decodeTextData(_ data: Data) -> String {
    if let s = String(data: data, encoding: .utf8), !s.contains("\u{FFFD}") { return s }
    if let s = String(data: data, encoding: .utf8) { return s }
    let cfEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
    if let s = String(data: data, encoding: String.Encoding(rawValue: cfEnc)) { return s }
    return String(data: data, encoding: .isoLatin1) ?? ""
}

func splitTxtChapters(_ text: String, bookTitle: String) -> [BookChapter] {
    let lines = text.components(separatedBy: .newlines)
    let pattern = #"^\s*(第[一二三四五六七八九十百千0-9０-９]+[章节回卷篇]|Chapter\s+\d+|序章|楔子|前言|正文|引子).{0,40}$"#
    let re = try? NSRegularExpression(pattern: pattern)
    var chapters: [BookChapter] = []
    var currentTitle = "正文"
    var currentLines: [String] = []
    func flush() {
        let t = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { chapters.append(BookChapter(title: currentTitle, text: t)) }
    }
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var isHead = false
        if let re = re, !trimmed.isEmpty {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            isHead = re.firstMatch(in: trimmed, range: range) != nil
        }
        if isHead && !currentLines.isEmpty {
            flush(); currentTitle = trimmed; currentLines = []
        } else if isHead && currentLines.isEmpty {
            currentTitle = trimmed
        } else {
            currentLines.append(line)
        }
    }
    flush()
    if chapters.isEmpty { return [BookChapter(title: bookTitle, text: text)] }
    if chapters.count == 1 { return chapters }
    return chapters
}

// MARK: - EPUB parsing (XMLParser delegates)

class ContainerParser: NSObject, XMLParserDelegate {
    var rootfile = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "rootfile", let p = attributeDict["full-path"] { rootfile = p }
    }
}

class OpfParser: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]
    var spine: [String] = []
    var title = ""
    var creator = ""
    var inTitle = false; var inCreator = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "item", let id = attributeDict["id"], let href = attributeDict["href"] { manifest[id] = href }
        if elementName == "itemref", let id = attributeDict["idref"] { spine.append(id) }
        if elementName.hasSuffix("title") { inTitle = true }
        if elementName.hasSuffix("creator") { inCreator = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { title += string }
        if inCreator { creator += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.hasSuffix("title") { inTitle = false }
        if elementName.hasSuffix("creator") { inCreator = false }
    }
}

func parseEpub(_ data: Data, fileName: String) -> LocalBook? {
    let files = unzipToMemory(data)
    guard let containerData = files["META-INF/container.xml"] else { return nil }
    let cp = ContainerParser()
    let xp = XMLParser(data: containerData); xp.delegate = cp; _ = xp.parse()
    guard !cp.rootfile.isEmpty, let opfData = files[cp.rootfile] else { return nil }
    let op = OpfParser()
    let xp2 = XMLParser(data: opfData); xp2.delegate = op; _ = xp2.parse()
    let base = (cp.rootfile as NSString).deletingLastPathComponent
    var chapters: [BookChapter] = []
    for id in op.spine {
        guard let href = op.manifest[id] else { continue }
        let path = base.isEmpty ? href : (base + "/" + href)
        guard let htmlData = files[path] else { continue }
        let html = decodeTextData(htmlData)
        let text = stripHTML(html).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        if !text.isEmpty { chapters.append(BookChapter(title: href, text: text)) }
    }
    if chapters.isEmpty { return nil }
    let title = op.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return LocalBook(title: title.isEmpty ? (fileName as NSString).deletingPathExtension : title, author: op.creator, fileName: fileName, kind: "epub", chapters: chapters)
}

func parseCbz(_ data: Data, fileName: String) -> (LocalBook, [String: Data])? {
    let files = unzipToMemory(data)
    let images = files.keys.filter { k in
        let l = k.lowercased(); return l.hasSuffix(".jpg") || l.hasSuffix(".jpeg") || l.hasSuffix(".png") || l.hasSuffix(".webp") || l.hasSuffix(".gif")
    }.sorted()
    if images.isEmpty { return nil }
    var book = LocalBook(title: (fileName as NSString).deletingPathExtension, fileName: fileName, kind: "cbz")
    book.imageNames = images
    return (book, files)
}

// MARK: - Store

class BookStore: ObservableObject {
    @Published var books: [LocalBook] = []
    @Published var bookmarks: [Bookmark] = []
    @Published var sources: [LegadoSource] = []
    @Published var replaceRules: [ReplaceRule] = []
    @Published var fontSize: Double = 19
    @Published var lineSpacing: Double = 8
    @Published var theme: Int = 0 // 0 white, 1 sepia, 2 night

    static let booksURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("books.json")
    }()
    static let metaURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("meta.json")
    }()
    static let filesDir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("BookFiles")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    struct Meta: Codable { var bookmarks: [Bookmark]; var sources: [LegadoSource]; var replaceRules: [ReplaceRule] = []; var fontSize: Double; var lineSpacing: Double; var theme: Int }

    init() { load() }

    func load() {
        // Bug fix (2026-10-29): the old code re-added the built-in Gutenberg source
        // every launch whenever sources was empty, so deleting it never stuck.
        // Now: no built-in source is ever injected, and the saved demo (if any) is
        // stripped once on load. Deleted sources stay deleted. Replace-rule defaults
        // are only added on a true first launch (no meta file yet), not when the
        // user has deliberately cleared them.
        let metaExists = FileManager.default.fileExists(atPath: Self.metaURL.path)
        if let d = try? Data(contentsOf: Self.booksURL), let b = try? JSONDecoder().decode([LocalBook].self, from: d) { books = b }
        if let d = try? Data(contentsOf: Self.metaURL), let m = try? JSONDecoder().decode(Meta.self, from: d) {
            bookmarks = m.bookmarks; sources = m.sources; replaceRules = m.replaceRules; fontSize = m.fontSize; lineSpacing = m.lineSpacing; theme = m.theme
        }
        let beforeCount = sources.count
        sources.removeAll { $0.bookSourceName.contains("Gutenberg") && $0.bookSourceUrl.contains("gutenberg.org") }
        if !metaExists && replaceRules.isEmpty { replaceRules = ReplaceRule.defaults }
        if metaExists && sources.count != beforeCount { save() }
    }
    func save() {
        if let d = try? JSONEncoder().encode(books) { try? d.write(to: Self.booksURL) }
        let m = Meta(bookmarks: bookmarks, sources: sources, replaceRules: replaceRules, fontSize: fontSize, lineSpacing: lineSpacing, theme: theme)
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: Self.metaURL) }
    }
    func updateBook(_ book: LocalBook) {
        if let i = books.firstIndex(where: { $0.id == book.id }) { books[i] = book } else { books.insert(book, at: 0) }
        save()
    }
    func deleteBook(_ book: LocalBook) {
        books.removeAll { $0.id == book.id }
        try? FileManager.default.removeItem(at: Self.filesDir.appendingPathComponent(book.fileName))
        save()
    }
    func addBookmark(_ bm: Bookmark) { bookmarks.insert(bm, at: 0); save() }
    func purify(_ text: String) -> String {
        var out = text
        for rule in replaceRules where rule.enabled && !rule.pattern.isEmpty {
            if let re = try? NSRegularExpression(pattern: rule.pattern, options: []) {
                let range = NSRange(out.startIndex..., in: out)
                out = re.stringByReplacingMatches(in: out, range: range, withTemplate: rule.replacement)
            }
        }
        return out
    }
    var enabledSources: [LegadoSource] { sources.filter { $0.enabled } }
}
