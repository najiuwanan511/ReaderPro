import SwiftUI
import Foundation

struct DanmakuEntry: Identifiable, Equatable {
    var id: Int
    var time: Double
    var text: String
    var mode = 1
    var color = 0xFFFFFF
}

private final class DanmakuXMLParser: NSObject, XMLParserDelegate {
    var entries: [DanmakuEntry] = []
    private var fields: [String]?
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "d" { fields = attributes["p"]?.components(separatedBy: ","); text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if fields != nil { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "d", let fields else { return }
        defer { self.fields = nil }
        guard let first = fields.first, let time = Double(first), time.isFinite, time >= 0, !text.isEmpty else { return }
        entries.append(DanmakuEntry(id: entries.count, time: time, text: text,
                                    mode: fields.count > 1 ? Int(fields[1]) ?? 1 : 1,
                                    color: fields.count > 3 ? Int(fields[3]) ?? 0xFFFFFF : 0xFFFFFF))
    }
}

func parseDanmaku(_ value: String) -> [DanmakuEntry] {
    guard let data = value.data(using: .utf8) else { return [] }
    if let object = try? JSONSerialization.jsonObject(with: data) {
        let rows = (object as? [[String: Any]]) ?? ((object as? [String: Any])?["danmaku"] as? [[String: Any]]) ?? []
        return rows.enumerated().compactMap { index, row in
            guard let text = (row["text"] ?? row["content"]) as? String, !text.isEmpty,
                  let time = Double(String(describing: row["time"] ?? row["t"] ?? "")), time.isFinite, time >= 0 else { return nil }
            return DanmakuEntry(id: index, time: time, text: text, mode: row["mode"] as? Int ?? 1, color: row["color"] as? Int ?? 0xFFFFFF)
        }.sorted { $0.time < $1.time }
    }
    let delegate = DanmakuXMLParser(), parser = XMLParser(data: data)
    parser.delegate = delegate; parser.shouldResolveExternalEntities = false
    return parser.parse() ? delegate.entries.sorted { $0.time < $1.time } : []
}

struct DanmakuOverlay: View {
    let entries: [DanmakuEntry]
    let currentTime: Double
    @AppStorage("video.danmakuFontSize") private var fontSize = 16.0
    @AppStorage("video.danmakuOpacity") private var opacity = 0.85
    @AppStorage("video.danmakuDuration") private var duration = 8.0
    var body: some View {
        GeometryReader { geometry in
            let lifetime = max(2, duration)
            let visible = entries.filter { currentTime >= $0.time && currentTime < $0.time + lifetime }.prefix(60)
            ZStack(alignment: .topLeading) {
                ForEach(Array(visible)) { entry in
                    let width = CGFloat(entry.text.count) * fontSize
                    let progress = min(1, max(0, (currentTime - entry.time) / lifetime))
                    let fixed = entry.mode == 4 || entry.mode == 5
                    Text(entry.text).font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(Color(red: Double((entry.color >> 16) & 255) / 255,
                                               green: Double((entry.color >> 8) & 255) / 255,
                                               blue: Double(entry.color & 255) / 255))
                        .shadow(color: .black, radius: 1).fixedSize()
                        .offset(x: fixed ? max(0, (geometry.size.width - width) / 2) : geometry.size.width - progress * (geometry.size.width + width),
                                y: entry.mode == 4 ? max(0, geometry.size.height - fontSize - 8) : CGFloat(entry.id % 5) * (fontSize + 5) + 4)
                }
            }.opacity(opacity).clipped()
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
