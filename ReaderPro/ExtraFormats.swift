import Foundation
import PDFKit
import Vision
import CoreImage
import UIKit

// MARK: - CRC32 (for stored ZIP writer)

let crcTable: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        table[i] = c
    }
    return table
}()

func crc32(_ data: Data) -> UInt32 {
    var c: UInt32 = 0xFFFFFFFF
    for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFFFFFF
}

func appendU16(_ data: inout Data, _ v: Int) {
    data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF))
}
func appendU32(_ data: inout Data, _ v: UInt32) {
    data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF)); data.append(UInt8((v >> 16) & 0xFF)); data.append(UInt8((v >> 24) & 0xFF))
}

// Stored (method 0) ZIP writer, readable by the app's own ZIP reader and by system unzip.
func writeStoredZip(_ files: [(name: String, data: Data)]) -> Data {
    var out = Data()
    var centrals = Data()
    for f in files {
        let nameData = f.name.data(using: .utf8) ?? Data()
        let offset = UInt32(out.count)
        let crc = crc32(f.data)
        appendU32(&out, 0x04034b50); appendU16(&out, 20); appendU16(&out, 0x0800); appendU16(&out, 0)
        appendU16(&out, 0); appendU16(&out, 0); appendU32(&out, crc)
        appendU32(&out, UInt32(f.data.count)); appendU32(&out, UInt32(f.data.count))
        appendU16(&out, nameData.count); appendU16(&out, 0)
        out.append(nameData); out.append(f.data)
        appendU32(&centrals, 0x02014b50); appendU16(&centrals, 20); appendU16(&centrals, 20)
        appendU16(&centrals, 0x0800); appendU16(&centrals, 0); appendU16(&centrals, 0); appendU16(&centrals, 0)
        appendU32(&centrals, crc); appendU32(&centrals, UInt32(f.data.count)); appendU32(&centrals, UInt32(f.data.count))
        appendU16(&centrals, nameData.count); appendU16(&centrals, 0); appendU16(&centrals, 0); appendU16(&centrals, 0); appendU16(&centrals, 0); appendU32(&centrals, 0)
        appendU32(&centrals, offset); centrals.append(nameData)
    }
    let cdOffset = UInt32(out.count)
    out.append(centrals)
    appendU32(&out, 0x06054b50); appendU16(&out, 0); appendU16(&out, 0)
    appendU16(&out, files.count); appendU16(&out, files.count)
    appendU32(&out, UInt32(centrals.count)); appendU32(&out, cdOffset); appendU16(&out, 0)
    return out
}

// MARK: - PalmDoc decompression (MOBI compression type 2)

func palmDocDecompress(_ data: Data) -> Data {
    var out = Data()
    var i = 0
    while i < data.count {
        let c = Int(data[i]); i += 1
        if c >= 0xC0 {
            out.append(0x20); out.append(UInt8(c ^ 0x80))
        } else if c >= 0x80 {
            guard i < data.count else { break }
            let v = (c << 8) | Int(data[i]); i += 1
            let length = (v & 0x07) + 3
            let distance = (v >> 3) & 0x07FF
            guard distance > 0, distance <= out.count else { continue }
            for _ in 0..<length { out.append(out[out.count - distance]) }
        } else {
            out.append(UInt8(c))
        }
    }
    return out
}

// MARK: - MOBI / AZW3 (basic: MOBI v6/7 fully via text records; KF8/AZW3 via text-record fallback + HTML scan)

func u32BE(_ data: Data, _ off: Int) -> Int {
    guard off + 4 <= data.count else { return 0 }
    return (Int(data[off]) << 24) | (Int(data[off + 1]) << 16) | (Int(data[off + 2]) << 8) | Int(data[off + 3])
}
func u16BE(_ data: Data, _ off: Int) -> Int {
    guard off + 2 <= data.count else { return 0 }
    return (Int(data[off]) << 8) | Int(data[off + 1])
}

func parseMobi(_ data: Data, fileName: String) -> LocalBook? {
    guard data.count > 100 else { return nil }
    let numRecords = u16BE(data, 76)
    guard numRecords > 1 else { return nil }
    var offsets: [Int] = []
    for r in 0..<numRecords {
        let p = 78 + r * 8
        guard p + 4 <= data.count else { break }
        offsets.append(u32BE(data, p))
    }
    func record(_ i: Int) -> Data {
        guard i < offsets.count else { return Data() }
        let start = offsets[i]
        let end = (i + 1 < offsets.count) ? offsets[i + 1] : data.count
        guard start < end, end <= data.count else { return Data() }
        return data[start..<end]
    }
    let rec0 = record(0)
    guard rec0.count > 16 else { return nil }
    // MOBI header starts after 16-byte PalmDoc header inside record 0
    let mobiStart = 16
    guard rec0.count > mobiStart + 4, String(data: rec0[mobiStart..<(mobiStart + 4)], encoding: .ascii) == "MOBI" else { return nil }
    let compression = u16BE(rec0, mobiStart + 0) // not used; PalmDoc header compression is at rec0 offset 0
    _ = compression
    let palmCompression = u16BE(rec0, 0)
    let encoding = u32BE(rec0, mobiStart + 12)
    let firstNonBook = u32BE(rec0, mobiStart + 0x40)
    let firstImage = u32BE(rec0, mobiStart + 0x5C)
    let fullNameOff = u32BE(rec0, mobiStart + 0x44)
    let fullNameLen = u32BE(rec0, mobiStart + 0x48)
    var title = (fileName as NSString).deletingPathExtension
    if fullNameOff > 0, fullNameLen > 0, mobiStart + fullNameOff + fullNameLen <= rec0.count {
        let tData = rec0[(mobiStart + fullNameOff)..<(mobiStart + fullNameOff + fullNameLen)]
        let enc: String.Encoding = encoding == 65001 ? .utf8 : .windowsCP1252
        if let t = String(data: tData, encoding: enc), !t.trimmingCharacters(in: .whitespaces).isEmpty { title = t }
    }
    var textEnd = firstNonBook > 0 ? firstNonBook : numRecords
    if firstImage > 0, firstImage < textEnd { textEnd = firstImage }
    textEnd = min(textEnd, numRecords)
    var raw = Data()
    for i in 1..<textEnd {
        let rec = record(i)
        if palmCompression == 2 { raw.append(palmDocDecompress(rec)) }
        else if palmCompression == 1 { raw.append(rec) }
        else { raw.append(rec) }
    }
    let enc: String.Encoding = encoding == 65001 ? .utf8 : .windowsCP1252
    var text = String(data: raw, encoding: enc) ?? decodeTextData(raw)
    text = stripHTML(text)
    // KF8/AZW3 fallback: if the record walk gave almost nothing, scan all records for HTML text
    if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 500 {
        var scanned = ""
        for i in 1..<numRecords {
            let rec = record(i)
            let d = palmCompression == 2 ? palmDocDecompress(rec) : rec
            if let s = String(data: d, encoding: enc), s.contains("<") {
                let t = stripHTML(s).trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count > 20 { scanned += t + "\n" }
            }
        }
        if scanned.count > text.count { text = scanned }
    }
    text = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    if text.count < 50 { return nil }
    var book = LocalBook(title: title, fileName: fileName, kind: "mobi")
    book.chapters = splitTxtChapters(text, bookTitle: title)
    return book
}

// MARK: - PDF (PDFKit text extraction, one chapter per page)

func parsePdf(_ data: Data, fileName: String) -> LocalBook? {
    guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { return nil }
    var chapters: [BookChapter] = []
    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i), let s = page.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        chapters.append(BookChapter(title: "第 \(i + 1) 页", text: s))
    }
    if chapters.isEmpty { return nil }
    var book = LocalBook(title: (fileName as NSString).deletingPathExtension, fileName: fileName, kind: "pdf")
    if let attrs = doc.documentAttributes, let a = attrs[PDFDocumentAttribute.authorAttribute] as? String { book.author = a }
    if let attrs = doc.documentAttributes, let t = attrs[PDFDocumentAttribute.titleAttribute] as? String, !t.isEmpty { book.title = t }
    book.chapters = chapters
    return book
}

// MARK: - OCR (Vision, on-device, Chinese + English)

func ocrImage(_ image: UIImage) async throws -> String {
    guard let cg = image.cgImage else { throw NSError(domain: "ocr", code: 1, userInfo: [NSLocalizedDescriptionKey: "图片无法识别"]) }
    return try await withCheckedThrowingContinuation { cont in
        let req = VNRecognizeTextRequest { request, error in
            if let e = error { cont.resume(throwing: e); return }
            let lines = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { $0.topCandidates(1).first?.string }
            cont.resume(returning: lines.joined(separator: "\n"))
        }
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { cont.resume(throwing: error) }
    }
}

// MARK: - Manga enhancement (CoreImage filters, not an AI model)

func enhancedImage(_ image: UIImage) -> UIImage {
    guard let ci = CIImage(image: image) else { return image }
    var out = ci
    if let f = CIFilter(name: "CIColorControls") {
        f.setValue(out, forKey: kCIInputImageKey)
        f.setValue(1.25, forKey: kCIInputContrastKey)
        f.setValue(0.05, forKey: kCIInputBrightnessKey)
        f.setValue(1.0, forKey: kCIInputSaturationKey)
        if let v = f.outputImage { out = v }
    }
    if let f = CIFilter(name: "CISharpenLuminance") {
        f.setValue(out, forKey: kCIInputImageKey)
        f.setValue(0.6, forKey: kCIInputSharpnessKey)
        if let v = f.outputImage { out = v }
    }
    if let f = CIFilter(name: "CILanczosScaleTransform") {
        f.setValue(out, forKey: kCIInputImageKey)
        f.setValue(1.5, forKey: kCIInputScaleKey)
        f.setValue(1.0, forKey: kCIInputAspectRatioKey)
        if let v = f.outputImage { out = v }
    }
    let ctx = CIContext()
    guard let cg = ctx.createCGImage(out, from: out.extent) else { return image }
    return UIImage(cgImage: cg)
}
