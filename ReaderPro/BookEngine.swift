import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Models

struct BookChapter: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var title: String
    var text: String
    var imageUrls: [String] = []
    var url: String? = nil
    var ruleBook: LegadoJS.BookCtx? = nil
    var ruleIndex: Int? = nil
    init(id: String = UUID().uuidString, title: String, text: String, imageUrls: [String] = [], url: String? = nil) {
        self.id = id; self.title = title; self.text = text; self.imageUrls = imageUrls; self.url = url
    }
    var isComic: Bool { !imageUrls.isEmpty }
    enum CodingKeys: String, CodingKey { case id, title, text, imageUrls, url, ruleBook, ruleIndex }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        imageUrls = (try? c.decode([String].self, forKey: .imageUrls)) ?? []
        url = (try? c.decode(String.self, forKey: .url)) ?? (text.hasPrefix("__URL__") ? String(text.dropFirst(7)) : nil)
        ruleBook = try? c.decode(LegadoJS.BookCtx.self, forKey: .ruleBook)
        ruleIndex = try? c.decode(Int.self, forKey: .ruleIndex)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title); try c.encode(text, forKey: .text); try c.encode(imageUrls, forKey: .imageUrls); try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(ruleBook, forKey: .ruleBook); try c.encodeIfPresent(ruleIndex, forKey: .ruleIndex)
    }
}

struct Bookmark: Identifiable, Codable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var bookId: String
    var chapterIndex: Int
    var paragraphIndex: Int
    var snippet: String
    // New bookmarks keep a UTF-16 character position independent of font
    // size and page layout. Older saved bookmarks have no such field.
    var charOffset: Int? = nil
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
    var kind: String // txt, epub, cbz, web, comic, audio, video
    var chapterIndex: Int = 0
    var paragraphIndex: Int = 0
    var charOffset: Int = 0
    var progress: Double = 0
    var lastRead: Date = Date()
    var totalMinutes: Int = 0
    var favorite: Bool = false
    var group: String = ""
    var chapters: [BookChapter] = []
    var imageNames: [String] = []
    // 音频/视频书（对标阅读Sigma）：歌词 LRC 文本、音频网络地址、视频选集源
    var lyrics: String = ""
    var audioUrl: String = ""
    var videoUrls: [String] = []

    var isAudio: Bool { kind == "audio" }
    var isVideo: Bool { kind == "video" }
    var isComicKind: Bool { kind == "cbz" || kind == "comic" }

    /// 未读章节数（书架封面右上角角标，对标阅读Sigma）
    var unreadCount: Int {
        guard chapters.count > 1 else { return 0 }
        let current = min(max(chapterIndex, 0), chapters.count - 1)
        return chapters.count - current - 1
    }

    enum CodingKeys: String, CodingKey {
        case id, title, author, coverUrl, sourceName, sourceUrl, fileName, kind, chapterIndex, paragraphIndex, charOffset, progress, lastRead, totalMinutes, favorite, group, chapters, imageNames, lyrics, audioUrl, videoUrls
    }

    init(title: String, author: String = "", coverUrl: String = "", sourceName: String = "", sourceUrl: String = "", fileName: String, kind: String = "txt") {
        self.title = title; self.author = author; self.coverUrl = coverUrl
        self.sourceName = sourceName; self.sourceUrl = sourceUrl
        self.fileName = fileName; self.kind = kind
    }

    // 向后兼容：旧书架数据没有新字段（lyrics/audioUrl/videoUrls）也不会 decode 失败
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id), !s.isEmpty { id = s }
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        author = (try? c.decode(String.self, forKey: .author)) ?? ""
        coverUrl = (try? c.decode(String.self, forKey: .coverUrl)) ?? ""
        sourceName = (try? c.decode(String.self, forKey: .sourceName)) ?? ""
        sourceUrl = (try? c.decode(String.self, forKey: .sourceUrl)) ?? ""
        fileName = (try? c.decode(String.self, forKey: .fileName)) ?? ""
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "txt"
        chapterIndex = (try? c.decode(Int.self, forKey: .chapterIndex)) ?? 0
        paragraphIndex = (try? c.decode(Int.self, forKey: .paragraphIndex)) ?? 0
        charOffset = (try? c.decode(Int.self, forKey: .charOffset)) ?? 0
        progress = (try? c.decode(Double.self, forKey: .progress)) ?? 0
        lastRead = (try? c.decode(Date.self, forKey: .lastRead)) ?? Date()
        totalMinutes = (try? c.decode(Int.self, forKey: .totalMinutes)) ?? 0
        favorite = (try? c.decode(Bool.self, forKey: .favorite)) ?? false
        group = (try? c.decode(String.self, forKey: .group)) ?? ""
        chapters = (try? c.decode([BookChapter].self, forKey: .chapters)) ?? []
        imageNames = (try? c.decode([String].self, forKey: .imageNames)) ?? []
        lyrics = (try? c.decode(String.self, forKey: .lyrics)) ?? ""
        audioUrl = (try? c.decode(String.self, forKey: .audioUrl)) ?? ""
        videoUrls = (try? c.decode([String].self, forKey: .videoUrls)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title)
        try c.encode(author, forKey: .author); try c.encode(coverUrl, forKey: .coverUrl)
        try c.encode(sourceName, forKey: .sourceName); try c.encode(sourceUrl, forKey: .sourceUrl)
        try c.encode(fileName, forKey: .fileName); try c.encode(kind, forKey: .kind)
        try c.encode(chapterIndex, forKey: .chapterIndex); try c.encode(paragraphIndex, forKey: .paragraphIndex)
        try c.encode(charOffset, forKey: .charOffset); try c.encode(progress, forKey: .progress)
        try c.encode(lastRead, forKey: .lastRead); try c.encode(totalMinutes, forKey: .totalMinutes)
        try c.encode(favorite, forKey: .favorite); try c.encode(group, forKey: .group)
        try c.encode(chapters, forKey: .chapters); try c.encode(imageNames, forKey: .imageNames)
        try c.encode(lyrics, forKey: .lyrics); try c.encode(audioUrl, forKey: .audioUrl)
        try c.encode(videoUrls, forKey: .videoUrls)
    }
}

struct SourceBook: Identifiable, Codable, Equatable, Hashable {
    var ruleWarnings: [String]? = nil
    var tocUrl: String? = nil
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
    var book = LocalBook(title: title.isEmpty ? (fileName as NSString).deletingPathExtension : title, author: op.creator, fileName: fileName, kind: "epub")
    book.chapters = chapters
    return book
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

struct SourceMergeResult {
    var added: Int = 0
    var updated: Int = 0
    var duplicates: Int = 0
}

class BookStore: ObservableObject {
    @Published var books: [LocalBook] = []
    @Published var bookmarks: [Bookmark] = []
    @Published var sources: [LegadoSource] = []
    @Published var rssSources: [RssSource] = []
    @Published var replaceRules: [ReplaceRule] = []
    @Published var fontSize: Double = 19
    @Published var lineSpacing: Double = 8
    @Published var paragraphSpacing: Double = 10
    @Published var pagePaddingH: Double = 18
    @Published var pagePaddingV: Double = 14
    @Published var brightness: Double = -1 // -1 跟随系统
    @Published var pageTurn: Int = 1 // 0 覆盖, 1 平移, 2 滚动, 3 无, 4 仿真
    @Published var pageTurnSpeed: Double = 0.25
    @Published var fontName: String = ""
    @Published var showHeader: Bool = true
    @Published var showFooter: Bool = true
    @Published var ttsRate: Double = 0.5
    @Published var ttsPitch: Double = 1.0
    @Published var theme: Int = 0 // 阅读主题索引（见 ReaderCore.readerThemes）
    // WebDAV 云备份
    @Published var webdavURL: String = ""
    @Published var webdavUser: String = ""
    @Published var webdavPassword: String = ""
    @Published var webdavPath: String = "/ReaderPro/backup.ciallo"

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

    struct Meta: Codable {
        var bookmarks: [Bookmark]
        var sources: [LegadoSource]
        var rssSources: [RssSource] = []
        var replaceRules: [ReplaceRule] = []
        var fontSize: Double
        var lineSpacing: Double
        var paragraphSpacing: Double = 10
        var pagePaddingH: Double = 18
        var pagePaddingV: Double = 14
        var brightness: Double = -1
        var pageTurn: Int = 1
        var pageTurnSpeed: Double = 0.25
        var fontName: String = ""
        var showHeader: Bool = true
        var showFooter: Bool = true
        var ttsRate: Double = 0.5
        var ttsPitch: Double = 1.0
        var theme: Int
        var webdavURL: String = ""
        var webdavUser: String = ""
        var webdavPassword: String = ""
        var webdavPath: String = "/ReaderPro/backup.ciallo"
    }

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
            bookmarks = m.bookmarks; sources = m.sources; rssSources = m.rssSources; replaceRules = m.replaceRules
            fontSize = m.fontSize; lineSpacing = m.lineSpacing; paragraphSpacing = m.paragraphSpacing
            pagePaddingH = m.pagePaddingH; pagePaddingV = m.pagePaddingV; brightness = m.brightness
            pageTurn = m.pageTurn; fontName = m.fontName; showHeader = m.showHeader; showFooter = m.showFooter
            ttsRate = m.ttsRate; ttsPitch = m.ttsPitch; theme = m.theme
            pageTurnSpeed = m.pageTurnSpeed
            webdavURL = m.webdavURL; webdavUser = m.webdavUser; webdavPassword = m.webdavPassword; webdavPath = m.webdavPath
        }
        let beforeCount = sources.count
        sources.removeAll { $0.bookSourceName.contains("Gutenberg") && $0.bookSourceUrl.contains("gutenberg.org") }
        if !metaExists && replaceRules.isEmpty { replaceRules = ReplaceRule.defaults }
        if metaExists && sources.count != beforeCount { save() }
    }
    func save() {
        if let d = try? JSONEncoder().encode(books) { try? d.write(to: Self.booksURL) }
        let m = Meta(bookmarks: bookmarks, sources: sources, rssSources: rssSources, replaceRules: replaceRules,
                     fontSize: fontSize, lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing,
                     pagePaddingH: pagePaddingH, pagePaddingV: pagePaddingV, brightness: brightness,
                     pageTurn: pageTurn, pageTurnSpeed: pageTurnSpeed, fontName: fontName, showHeader: showHeader, showFooter: showFooter,
                     ttsRate: ttsRate, ttsPitch: ttsPitch, theme: theme,
                     webdavURL: webdavURL, webdavUser: webdavUser, webdavPassword: webdavPassword, webdavPath: webdavPath)
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

    /// Merge by Legado's full source URL. Re-importing a pack updates
    /// its rules instead of creating hundreds of duplicate rows.
    @discardableResult
    func mergeSources(_ incoming: [LegadoSource]) -> SourceMergeResult {
        var result = SourceMergeResult()
        var seen = Set<String>()
        var indices: [String: Int] = [:]
        for (index, source) in sources.enumerated() { indices[sourceIdentityKey(source)] = index }
        for source in incoming {
            let k = sourceIdentityKey(source)
            guard seen.insert(k).inserted else { result.duplicates += 1; continue }
            if let index = indices[k] {
                var updated = source
                updated.id = sources[index].id
                sources[index] = updated
                result.updated += 1
            } else {
                indices[k] = sources.count
                sources.append(source)
                result.added += 1
            }
        }
        save()
        return result
    }

    func sourceForBook(_ b: LocalBook) -> LegadoSource? {
        if let exact = sources.first(where: { $0.bookSourceUrl == b.sourceUrl && $0.bookSourceName == b.sourceName }) { return exact }
        if !b.sourceUrl.isEmpty, let s = sources.first(where: { $0.bookSourceUrl == b.sourceUrl }) { return s }
        if !b.sourceName.isEmpty, let s = sources.first(where: { $0.bookSourceName == b.sourceName }) { return s }
        return nil
    }

    // MARK: 备份（.ciallo 内容）

    func exportBackupData() -> Data {
        var files: [(name: String, data: Data)] = []
        if let d = try? JSONEncoder().encode(books) { files.append((name: "books.json", data: d)) }
        let m = Meta(bookmarks: bookmarks, sources: sources, rssSources: rssSources, replaceRules: replaceRules,
                     fontSize: fontSize, lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing,
                     pagePaddingH: pagePaddingH, pagePaddingV: pagePaddingV, brightness: brightness,
                     pageTurn: pageTurn, pageTurnSpeed: pageTurnSpeed, fontName: fontName, showHeader: showHeader, showFooter: showFooter,
                     ttsRate: ttsRate, ttsPitch: ttsPitch, theme: theme,
                     webdavURL: webdavURL, webdavUser: webdavUser, webdavPassword: webdavPassword, webdavPath: webdavPath)
        if let d = try? JSONEncoder().encode(m) { files.append((name: "meta.json", data: d)) }
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: Self.filesDir, includingPropertiesForKeys: nil) {
            for url in items {
                if url.hasDirectoryPath {
                    if let subs = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                        for s in subs { if let d = try? Data(contentsOf: s) { files.append((name: "files/\(url.lastPathComponent)/\(s.lastPathComponent)", data: d)) } }
                    }
                } else if let d = try? Data(contentsOf: url) { files.append((name: "files/\(url.lastPathComponent)", data: d)) }
            }
        }
        return writeStoredZip(files)
    }

    /// 导入备份内容，返回 nil 表示成功，否则返回错误信息
    func importBackupData(_ data: Data) -> String? {
        let files = unzipToMemory(data)
        guard let booksData = files["books.json"], let decoded = try? JSONDecoder().decode([LocalBook].self, from: booksData) else {
            return "这不是有效的 .ciallo 备份（里面没有 books.json）"
        }
        if let d = try? JSONEncoder().encode(decoded) { try? d.write(to: Self.booksURL) }
        if let metaData = files["meta.json"] { try? metaData.write(to: Self.metaURL) }
        for (name, d) in files where name.hasPrefix("files/") {
            let rel = String(name.dropFirst(6))
            let dest = Self.filesDir.appendingPathComponent(rel)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: dest)
        }
        load()
        return nil
    }

    // MARK: 整本下载（在线书缓存全部章节）

    func downloadAllChapters(bookId: String, onProgress: @escaping (Int, Int) -> Void) async {
        guard let book = books.first(where: { $0.id == bookId }),
              let src = sourceForBook(book) else { return }
        let pending = book.chapters.enumerated().filter { $0.element.text.hasPrefix("__URL__") }
        let total = pending.count
        guard total > 0 else { return }
        var done = 0
        var index = 0
        while index < pending.count {
            let batch = Array(pending[index..<min(index + 8, pending.count)])
            index += batch.count
            await withTaskGroup(of: (Int, String).self) { group in
                for (i, ch) in batch {
                    group.addTask {
                        let nextURL = book.chapters.indices.contains(i + 1) ? book.chapters[i + 1].url : book.chapters.first?.url
                        if let c = try? await src.fetchChapterContent(ch, nextChapterUrl: nextURL) {
                            return (i, c.isEmpty ? "（本章没有正文）" : c)
                        }
                        return (i, "")
                    }
                }
                var updates: [Int: String] = [:]
                for await (i, c) in group { updates[i] = c }
                await MainActor.run {
                    if let bi = self.books.firstIndex(where: { $0.id == bookId }) {
                        for (i, c) in updates where i < self.books[bi].chapters.count && !c.isEmpty {
                            self.books[bi].chapters[i].text = c
                        }
                    }
                    done += batch.count
                    onProgress(min(done, total), total)
                }
            }
        }
        save()
    }

    // MARK: 换源（用新书源重新拉目录，保留书）

    func reloadBookFromSource(bookId: String, source: LegadoSource, sourceBook: SourceBook) async throws {
        let chapters = try await source.fetchChapters(book: sourceBook)
        await MainActor.run {
            if var nb = books.first(where: { $0.id == bookId }) {
                nb.sourceName = source.bookSourceName
                nb.sourceUrl = source.bookSourceUrl
                nb.chapters = chapters
                nb.chapterIndex = 0
                nb.charOffset = 0
                nb.progress = 0
                updateBook(nb)
            }
        }
    }
}
