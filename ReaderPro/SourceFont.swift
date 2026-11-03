import Foundation
import JavaScriptCore
import CryptoKit

// TrueType table reader for Legado's queryTTF/replaceFont contract. Compare
// relative contour coordinates, not glyph IDs (obfuscated fonts remap IDs).
final class SourceFont {
    private struct Reader {
        let data: [UInt8]
        var offset: Int
        var end: Int
        mutating func uint(_ size: Int) throws -> Int {
            guard size > 0, offset >= 0, offset + size <= end, end <= data.count else { throw SourceFailure(stage: "字体规则", message: "字体表越界或已损坏") }
            var value = 0
            for _ in 0..<size { value = (value << 8) | Int(data[offset]); offset += 1 }
            return value
        }
        mutating func signed(_ size: Int) throws -> Int {
            let value = try uint(size), bits = size * 8
            return value & (1 << (bits - 1)) == 0 ? value : value - (1 << bits)
        }
        mutating func skip(_ size: Int) throws { guard size >= 0, offset + size <= end else { throw SourceFailure(stage: "字体规则", message: "字体表长度无效") }; offset += size }
    }
    private(set) var ids: [Int: Int] = [:]
    private(set) var outlines: [Int: String] = [:]
    private(set) var reverse: [String: Int] = [:]
    private var glyphs: [Int: String] = [:]

    init(_ bytes: Data) throws {
        guard bytes.count <= 32 * 1024 * 1024 else { throw SourceFailure(stage: "字体规则", message: "字体超过大小限制") }
        let data = Array(bytes)
        var reader = Reader(data: data, offset: 0, end: data.count)
        let version = try reader.uint(4)
        guard version == 0x00010000 || version == 0x74727565 else { throw SourceFailure(stage: "字体规则", message: "queryTTF 需要包含 glyf 表的 TrueType 字体") }
        let count = try reader.uint(2); try reader.skip(6)
        var tables: [String: Range<Int>] = [:]
        for _ in 0..<count {
            let tag = try reader.uint(4); try reader.skip(4)
            let start = try reader.uint(4), length = try reader.uint(4)
            guard start <= data.count, length <= data.count - start else { throw SourceFailure(stage: "字体规则", message: "字体目录长度无效") }
            let name = String(bytes: [UInt8((tag >> 24) & 255), UInt8((tag >> 16) & 255), UInt8((tag >> 8) & 255), UInt8(tag & 255)], encoding: .ascii) ?? ""
            tables[name] = start..<(start + length)
        }
        func table(_ name: String) throws -> Reader {
            guard let range = tables[name] else { throw SourceFailure(stage: "字体规则", message: "缺少字体表：" + name) }
            return Reader(data: data, offset: range.lowerBound, end: range.upperBound)
        }
        var head = try table("head"); try head.skip(50); let longOffsets = try head.uint(2) == 1
        var maxp = try table("maxp"); try maxp.skip(4); let glyphCount = try maxp.uint(2)
        var loca = try table("loca"), offsets: [Int] = []
        for _ in 0...glyphCount { offsets.append(try loca.uint(longOffsets ? 4 : 2) * (longOffsets ? 1 : 2)) }
        let glyf = try table("glyf")
        for index in 0..<glyphCount {
            try Task.checkCancellation()
            let start = offsets[index], end = offsets[index + 1]
            guard start <= end, end <= glyf.end - glyf.offset else { throw SourceFailure(stage: "字体规则", message: "字形偏移无效") }
            if start == end { continue }
            var glyph = Reader(data: data, offset: glyf.offset + start, end: glyf.offset + end)
            let contours = try glyph.signed(2); try glyph.skip(8)
            if contours == 0 { continue }
            if contours > 0 {
                var pointCount = 0
                for _ in 0..<contours { pointCount = try glyph.uint(2) + 1 }
                let instructions = try glyph.uint(2); try glyph.skip(instructions)
                var flags: [Int] = []
                while flags.count < pointCount {
                    let flag = try glyph.uint(1), repeats = flag & 8 == 0 ? 0 : try glyph.uint(1)
                    guard flags.count + repeats + 1 <= pointCount else { throw SourceFailure(stage: "字体规则", message: "字形标志长度无效") }
                    flags.append(contentsOf: repeatElement(flag, count: repeats + 1))
                }
                var xs: [Int] = [], ys: [Int] = []
                for flag in flags {
                    if flag & 2 != 0 { xs.append(try glyph.uint(1) * (flag & 16 == 0 ? -1 : 1)) }
                    else { xs.append(flag & 16 != 0 ? 0 : try glyph.signed(2)) }
                }
                for flag in flags {
                    if flag & 4 != 0 { ys.append(try glyph.uint(1) * (flag & 32 == 0 ? -1 : 1)) }
                    else { ys.append(flag & 32 != 0 ? 0 : try glyph.signed(2)) }
                }
                glyphs[index] = zip(xs, ys).map { pair in "\(pair.0),\(pair.1)" }.joined(separator: "|")
            } else {
                var components: [String] = []
                while true {
                    let flags = try glyph.uint(2), id = try glyph.uint(2), size = flags & 1 == 0 ? 1 : 2
                    let arg1 = flags & 2 == 0 ? try glyph.uint(size) : try glyph.signed(size)
                    let arg2 = flags & 2 == 0 ? try glyph.uint(size) : try glyph.signed(size)
                    var x: Float = 0, y: Float = 0, xy: Float = 0, yx: Float = 0
                    switch flags & 0xc8 {
                    case 8: x = Float(try glyph.uint(2)) / 16384; y = x
                    case 64: x = Float(try glyph.uint(2)) / 16384; y = Float(try glyph.uint(2)) / 16384
                    case 128:
                        x = Float(try glyph.uint(2)) / 16384; xy = Float(try glyph.uint(2)) / 16384
                        yx = Float(try glyph.uint(2)) / 16384; y = Float(try glyph.uint(2)) / 16384
                    default: break
                    }
                    components.append("{flags:\(flags),glyphIndex:\(id),arg1:\(arg1),arg2:\(arg2),xScale:\(x),scale01:\(xy),scale10:\(yx),yScale:\(y)}")
                    if flags & 32 == 0 { break }
                }
                glyphs[index] = "[" + components.joined(separator: ",") + "]"
            }
        }
        let cmap = try table("cmap"); var header = cmap; try header.skip(2); let recordCount = try header.uint(2)
        var visited: Set<Int> = []
        for _ in 0..<recordCount {
            try Task.checkCancellation()
            try header.skip(4); let offset = try header.uint(4)
            guard visited.insert(offset).inserted else { continue }
            var map = Reader(data: data, offset: cmap.offset + offset, end: cmap.end)
            let format = try map.uint(2)
            switch format {
            case 0:
                let length = try map.uint(2); try map.skip(2)
                for code in 0..<max(0, min(256, length - 6)) { let id = try map.uint(1); if id != 0 { ids[code] = id } }
            case 4:
                let start = map.offset - 2, length = try map.uint(2); try map.skip(2)
                let segments = try map.uint(2) / 2; try map.skip(6)
                var ends: [Int] = [], starts: [Int] = [], deltas: [Int] = [], ranges: [(Int, Int)] = []
                for _ in 0..<segments { ends.append(try map.uint(2)) }; try map.skip(2)
                for _ in 0..<segments { starts.append(try map.uint(2)) }
                for _ in 0..<segments { deltas.append(try map.signed(2)) }
                for _ in 0..<segments { let at = map.offset; ranges.append((at, try map.uint(2))) }
                for segment in 0..<segments where starts[segment] <= ends[segment] {
                    try Task.checkCancellation()
                    for code in starts[segment]...ends[segment] {
                        var id = (code + deltas[segment]) & 65535
                        if ranges[segment].1 != 0 {
                            let at = ranges[segment].0 + ranges[segment].1 + (code - starts[segment]) * 2
                            guard at + 2 <= start + length else { continue }
                            var glyph = Reader(data: data, offset: at, end: min(cmap.end, start + length))
                            id = (try glyph.uint(2) + deltas[segment]) & 65535
                        }
                        if id != 0 { ids[code] = id }
                    }
                }
            case 6:
                try map.skip(4); let first = try map.uint(2), count = try map.uint(2)
                for index in 0..<count { let id = try map.uint(2); if id != 0 { ids[first + index] = id } }
            case 12, 13:
                try map.skip(10); let groups = try map.uint(4)
                guard groups <= 100000 else { throw SourceFailure(stage: "字体规则", message: "字符映射数量无效") }
                for _ in 0..<groups {
                    try Task.checkCancellation()
                    let first = try map.uint(4), last = try map.uint(4), id = try map.uint(4)
                    guard first <= last, last <= 0x10ffff else { throw SourceFailure(stage: "字体规则", message: "Unicode 范围无效") }
                    for code in first...last { ids[code] = format == 13 ? id : id + code - first }
                }
            default: continue
            }
        }
        for code in ids.keys.sorted() {
            if let id = ids[code], let outline = glyphs[id] { outlines[code] = outline; reverse[outline] = code }
        }
    }
    static func blank(_ code: Int) -> Bool { [0x9,0x20,0xa0,0x2002,0x2003,0x2007,0x200a,0x200b,0x200c,0x200d,0x202f,0x205f].contains(code) }
    private static let cache: NSCache<NSString, SourceFont> = { let value = NSCache<NSString, SourceFont>(); value.countLimit = 8; value.totalCostLimit = 32 * 1024 * 1024; return value }()
    static func install(_ java: JSValue, context: JSContext, base: String) {
        let query: @convention(block) (JSValue, Bool) -> JSValue? = { input, useCache in
            guard let context = JSContext.current() else { return nil }
            if input.isNull || input.isUndefined { return JSValue(nullIn: context) }
            do {
                let data: Data
                if input.isArray { data = SourceCrypto.bytes(input) }
                else {
                    let value = input.toString() ?? ""
                    if isSourceURL(value) { data = try SourceFiles.bytes(value, base: base) }
                    else if let decoded = SourceCrypto.base64(value) { data = decoded }
                    else { data = try Data(contentsOf: SourceFiles.file(value)) }
                }
                let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() as NSString
                let font: SourceFont
                if useCache, let saved = cache.object(forKey: key) { font = saved }
                else { font = try SourceFont(data); if useCache { cache.setObject(font, forKey: key, cost: data.count) } }
                let object = JSValue(newObjectIn: context)!
                let id: @convention(block) (Int) -> Int = { font.ids[$0] ?? 0 }
                let outline: @convention(block) (Int) -> JSValue? = { code in
                    guard let current = JSContext.current() else { return nil }
                    return font.outlines[code].map { JSValue(object: $0, in: current) } ?? JSValue(nullIn: current)
                }
                let byID: @convention(block) (Int) -> JSValue? = { id in
                    guard let current = JSContext.current() else { return nil }
                    return font.glyphs[id].map { JSValue(object: $0, in: current) } ?? JSValue(nullIn: current)
                }
                let reverse: @convention(block) (String) -> Int = { font.reverse[$0] ?? 0 }
                let blank: @convention(block) (Int) -> Bool = { Self.blank($0) }
                object.setObject(id, forKeyedSubscript: "getGlyfIdByUnicode" as NSString)
                object.setObject(outline, forKeyedSubscript: "getGlyfByUnicode" as NSString)
                object.setObject(byID, forKeyedSubscript: "getGlyfById" as NSString)
                object.setObject(reverse, forKeyedSubscript: "getUnicodeByGlyf" as NSString)
                object.setObject(blank, forKeyedSubscript: "isBlankUnicode" as NSString)
                return object
            } catch { context.exception = JSValue(newErrorFromMessage: sourceErrorMessage(error), in: context); return JSValue(nullIn: context) }
        }
        java.setObject(query, forKeyedSubscript: "_queryTTF" as NSString)
        context.evaluateScript(#"""
        java.queryTTF=function(data,useCache){return java._queryTTF(data,useCache!==false);};
        java.replaceFont=function(text,errorFont,correctFont,filter){
          if(errorFont==null||correctFont==null)return String(text);
          return Array.from(String(text)).map(function(c){var code=c.codePointAt(0);if(errorFont.isBlankUnicode(code))return c;
            var outline=errorFont.getGlyfIdByUnicode(code)===0?null:errorFont.getGlyfByUnicode(code);
            if(outline==null)return filter?'':c;var replacement=correctFont.getUnicodeByGlyf(outline);return replacement?String.fromCodePoint(replacement):c;
          }).join('');
        };
        """#)
    }
}
