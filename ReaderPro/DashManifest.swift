import Foundation

// Static, unencrypted ISO-BMFF DASH can be represented as HLS without
// transcoding its audio/video bytes. AVPlayer reads the original fMP4 segments.
struct DashManifest {
    let playlists: [String: String]
    private final class Node {
        let name: String, attributes: [String: String]
        var children: [Node] = [], text = ""
        init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
        func first(_ name: String) -> Node? { children.first { $0.name == name } }
        func all(_ name: String) -> [Node] { children.filter { $0.name == name } }
    }
    private final class Parser: NSObject, XMLParserDelegate {
        var root: Node?, stack: [Node] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            guard stack.count < 32 else { parser.abortParsing(); return }
            let node = Node(elementName.components(separatedBy: ":").last ?? elementName, attributeDict)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if !stack.isEmpty { stack.removeLast() } }
    }
    private struct Track {
        let name: String, mime: String, codec: String, language: String, bandwidth: Int, width: Int, height: Int, playlist: String
        var audio: Bool { mime.hasPrefix("audio/") || codec.hasPrefix("mp4a") || codec.hasPrefix("ac-3") || codec.hasPrefix("ec-3") }
    }
    init(data: Data, url: URL) throws {
        guard data.count <= 4 * 1024 * 1024 else { throw Self.failure("MPD 清单过大") }
        let delegate = Parser(), parser = XMLParser(data: data)
        parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = delegate.root, root.name == "MPD" else { throw Self.failure("MPD 清单解析失败") }
        guard root.attributes["type"] != "dynamic" else { throw Self.failure("暂不支持动态 DASH 直播清单") }
        let periods = root.all("Period")
        guard periods.count == 1, let period = periods.first else { throw Self.failure("暂不支持多时段 DASH 清单") }
        let seconds = Self.duration(period.attributes["duration"]) ?? Self.duration(root.attributes["mediaPresentationDuration"])
        var tracks: [Track] = []
        for adaptation in period.all("AdaptationSet") {
            for representation in adaptation.all("Representation") {
                try Task.checkCancellation()
                let chain = [root, period, adaptation, representation]
                guard !chain.contains(where: { $0.first("ContentProtection") != nil }) else { throw Self.failure("此 DASH 线路含 DRM 加密，需要站点授权播放器") }
                func inherited(_ name: String) -> String { chain.reversed().compactMap { $0.attributes[name] }.first ?? "" }
                let mime = inherited("mimeType"), codec = inherited("codecs")
                // The reference player can use software codecs that AVPlayer
                // cannot. Do not offer those representations as working tracks.
                guard mime.hasSuffix("/mp4"), ["avc1", "avc3", "hvc1", "hev1", "mp4a", "ac-3", "ec-3"].contains(where: { codec.hasPrefix($0) }) else { continue }
                var base = url
                for node in chain {
                    if let value = node.first("BaseURL")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                        base = try Self.address(value, base: base)
                    }
                }
                let templates = chain.compactMap { $0.first("SegmentTemplate") }, lists = chain.compactMap { $0.first("SegmentList") }
                let name = "track\(tracks.count).m3u8", playlist: String
                if !templates.isEmpty {
                    playlist = try Self.template(templates, representation: representation, base: base, seconds: seconds)
                } else if !lists.isEmpty {
                    playlist = try Self.list(lists, base: base, seconds: seconds)
                } else { continue }
                tracks.append(Track(name: name, mime: mime, codec: codec, language: inherited("lang"),
                    bandwidth: max(1, Int(inherited("bandwidth")) ?? 1), width: Int(inherited("width")) ?? 0,
                    height: Int(inherited("height")) ?? 0, playlist: playlist))
            }
        }
        guard !tracks.isEmpty else { throw Self.failure("此 DASH 清单没有可播放的 MP4 分段线路") }
        let audio = tracks.filter(\.audio), video = tracks.filter { !$0.audio }
        var master = "#EXTM3U\n#EXT-X-VERSION:7\n"
        for (index, track) in audio.enumerated() where !video.isEmpty {
            master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"音轨\(index + 1)\",DEFAULT=\(index == 0 ? "YES" : "NO"),AUTOSELECT=YES"
            if !track.language.isEmpty { master += ",LANGUAGE=\"\(Self.quoted(track.language))\"" }
            master += ",URI=\"\(track.name)\"\n"
        }
        for track in video.isEmpty ? audio : video {
            let audioTrack = video.isEmpty ? nil : audio.first
            master += "#EXT-X-STREAM-INF:BANDWIDTH=\(track.bandwidth + (audioTrack?.bandwidth ?? 0)),CODECS=\"\(Self.quoted(track.codec + (audioTrack.map { "," + $0.codec } ?? "")))\""
            if track.width > 0, track.height > 0 { master += ",RESOLUTION=\(track.width)x\(track.height)" }
            if audioTrack != nil { master += ",AUDIO=\"audio\"" }
            master += "\n\(track.name)\n"
        }
        var playlists = Dictionary(uniqueKeysWithValues: tracks.map { ($0.name, $0.playlist) })
        playlists["master.m3u8"] = master; self.playlists = playlists
    }
    private static func failure(_ message: String) -> SourceFailure { SourceFailure(stage: "DASH 视频", message: message) }
    private static func quoted(_ value: String) -> String { value.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "") }
    private static func address(_ value: String, base: URL) throws -> URL {
        guard !value.contains("\r"), !value.contains("\n"), let url = URL(string: value, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw failure("DASH 分段地址无效") }
        return url
    }
    private static func duration(_ value: String?) -> Double? {
        guard let value, let regex = try? NSRegularExpression(pattern: #"^P(?:(\d+(?:\.\d+)?)D)?T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?$"#),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let text = value as NSString
        let seconds = zip(1...4, [86400.0, 3600.0, 60.0, 1.0]).reduce(0.0) { result, pair in
            let range = match.range(at: pair.0)
            return result + (range.location == NSNotFound ? 0 : (Double(text.substring(with: range)) ?? 0) * pair.1)
        }
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
    private static func attributes(_ nodes: [Node]) -> [String: String] { nodes.reduce(into: [:]) { $0.merge($1.attributes) { _, new in new } } }
    private static func timings(_ nodes: [Node], attributes: [String: String], seconds: Double?) throws -> [(Int64, Int64)] {
        let scale = Int64(attributes["timescale"] ?? "1") ?? 0
        guard scale > 0, scale <= 1_000_000_000 else { throw failure("DASH 时间刻度无效") }
        var result: [(Int64, Int64)] = []
        if let timeline = nodes.reversed().compactMap({ $0.first("SegmentTimeline") }).first {
            let entries = timeline.all("S"); var cursor: Int64 = 0
            for (index, entry) in entries.enumerated() {
                if let t = entry.attributes["t"] { guard let value = Int64(t), value >= 0 else { throw failure("DASH 分段时间无效") }; cursor = value }
                guard let d = Int64(entry.attributes["d"] ?? ""), d > 0, d <= scale * 86400 else { throw failure("DASH 分段时长无效") }
                var repeats = Int64(entry.attributes["r"] ?? "0") ?? 0
                if repeats == -1 {
                    let end = index + 1 < entries.count ? Double(entries[index + 1].attributes["t"] ?? "") : seconds.map { $0 * Double(scale) + Double(Int64(attributes["presentationTimeOffset"] ?? "0") ?? 0) }
                    guard let end, end.isFinite, end > Double(cursor), end < Double(Int64.max) else { throw failure("DASH 重复分段缺少结束时间") }
                    repeats = Int64(ceil((end - Double(cursor)) / Double(d))) - 1
                }
                guard repeats >= 0, repeats < 100_000, result.count + Int(repeats) < 100_000 else { throw failure("DASH 分段数量超限") }
                for _ in 0...repeats {
                    result.append((cursor, d)); let sum = cursor.addingReportingOverflow(d)
                    guard !sum.overflow else { throw failure("DASH 时间溢出") }; cursor = sum.partialValue
                }
            }
        } else {
            guard let d = Int64(attributes["duration"] ?? ""), d > 0, d <= scale * 86400, let seconds else { throw failure("DASH 清单缺少分段时长") }
            let count = ceil(seconds * Double(scale) / Double(d))
            guard count.isFinite, count > 0, count <= 100_000 else { throw failure("DASH 分段数量超限") }
            for index in 0..<Int64(count) {
                let t = index.multipliedReportingOverflow(by: d)
                guard !t.overflow else { throw failure("DASH 时间溢出") }; result.append((t.partialValue, d))
            }
        }
        guard !result.isEmpty else { throw failure("DASH 清单没有分段") }; return result
    }
    private static func expanded(_ template: String, id: String, bandwidth: String, number: Int64, time: Int64) throws -> String {
        var value = template.replacingOccurrences(of: "$$", with: "\u{1}").replacingOccurrences(of: "$RepresentationID$", with: id)
        value = value.replacingOccurrences(of: "$Bandwidth$", with: bandwidth)
        let regex = try NSRegularExpression(pattern: #"\$(Number|Time)(?:%0(\d{1,2})d)?\$"#)
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            let ns = value as NSString, token = ns.substring(with: match.range(at: 1))
            let n = token == "Number" ? number : time
            let width = match.range(at: 2).location == NSNotFound ? 0 : min(20, Int(ns.substring(with: match.range(at: 2))) ?? 0)
            let text = String(n), padding = String(repeating: "0", count: max(0, width - text.count))
            value = ns.replacingCharacters(in: match.range, with: padding + text)
        }
        guard !value.contains("$") else { throw failure("DASH 模板包含不支持的变量") }
        return value.replacingOccurrences(of: "\u{1}", with: "$")
    }
    private static func template(_ nodes: [Node], representation: Node, base: URL, seconds: Double?) throws -> String {
        let attr = attributes(nodes)
        guard let media = attr["media"], let initialization = attr["initialization"] else { throw failure("DASH 缺少媒体或初始化模板") }
        let scale = Double(attr["timescale"] ?? "1") ?? 1, start = Int64(attr["startNumber"] ?? "1") ?? 1
        guard start >= 0 else { throw failure("DASH 起始分段编号无效") }
        let times = try timings(nodes, attributes: attr, seconds: seconds), id = representation.attributes["id"] ?? "", bandwidth = representation.attributes["bandwidth"] ?? ""
        let initial = try address(expanded(initialization, id: id, bandwidth: bandwidth, number: start, time: times[0].0), base: base)
        var segments: [(Double, String, String?)] = []
        for (index, timing) in times.enumerated() {
            let number = start.addingReportingOverflow(Int64(index)); guard !number.overflow else { throw failure("DASH 分段编号溢出") }
            let url = try address(expanded(media, id: id, bandwidth: bandwidth, number: number.partialValue, time: timing.0), base: base)
            segments.append((Double(timing.1) / scale, url.absoluteString, nil))
        }
        return playlist(initial: initial.absoluteString, range: nil, segments: segments)
    }
    private static func byteRange(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let parts = value.split(separator: "-")
        guard parts.count == 2, let a = Int64(parts[0]), let b = Int64(parts[1]), a >= 0, b >= a, b < Int64.max else { throw failure("DASH 字节范围无效") }
        return "\(b - a + 1)@\(a)"
    }
    private static func list(_ nodes: [Node], base: URL, seconds: Double?) throws -> String {
        let attr = attributes(nodes), scale = Double(attr["timescale"] ?? "1") ?? 1
        guard let list = nodes.reversed().first(where: { !$0.all("SegmentURL").isEmpty }),
              let initialization = nodes.reversed().compactMap({ $0.first("Initialization") }).first else { throw failure("DASH 缺少初始化分段") }
        let urls = list.all("SegmentURL"), times = try timings(nodes, attributes: attr, seconds: seconds)
        guard urls.count == times.count else { throw failure("DASH 分段与时间列表数量不一致") }
        let initial = try address(initialization.attributes["sourceURL"] ?? "", base: base)
        var segments: [(Double, String, String?)] = []
        for (index, node) in urls.enumerated() {
            let url = try address(node.attributes["media"] ?? "", base: base)
            segments.append((Double(times[index].1) / scale, url.absoluteString, try byteRange(node.attributes["mediaRange"])))
        }
        return playlist(initial: initial.absoluteString, range: try byteRange(initialization.attributes["range"]), segments: segments)
    }
    private static func playlist(initial: String, range: String?, segments: [(Double, String, String?)]) -> String {
        let maxDuration = Int(ceil(segments.map { $0.0 }.max() ?? 1))
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(maxDuration)\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"\(quoted(initial))\""
        if let range { text += ",BYTERANGE=\"\(range)\"" }; text += "\n"
        for (duration, url, range) in segments {
            text += "#EXTINF:" + String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), duration) + ",\n"
            if let range { text += "#EXT-X-BYTERANGE:\(range)\n" }; text += url + "\n"
        }
        return text + "#EXT-X-ENDLIST\n"
    }
}
