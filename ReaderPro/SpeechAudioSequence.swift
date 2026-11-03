import Foundation

enum ReaderSpeechText {
    struct Paragraph { let text: String; let offset: Int }
    static func paragraphs(_ text: String, from offset: Int) -> [Paragraph] {
        let content = text as NSString
        let start = min(max(0, offset), content.length)
        let rest = content.substring(from: start)
        var paragraphs: [Paragraph] = []
        rest.enumerateSubstrings(in: rest.startIndex..<rest.endIndex, options: .byLines) { line, range, _, _ in
            guard let line else { return }
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { paragraphs.append(Paragraph(text: value, offset: start + NSRange(range, in: rest).location)) }
        }
        return paragraphs
    }
}

enum SpeechAudioSequence {
    static func parts(_ segments: [String], limit: Int = 400) -> [String] {
        let count = max(1, limit)
        return segments.flatMap { segment -> [String] in
            var rest = segment[...], result: [String] = []
            while !rest.isEmpty {
                let part = String(rest.prefix(count)); result.append(part); rest = rest.dropFirst(part.count)
            }
            return result
        }
    }
    // Keep just the next segment in flight while the current one plays.
    // Both cancellation and playback failure cancel that pending request.
    static func run(parts: [String], fetch: @escaping @Sendable (String) async throws -> Data,
                    onStart: @escaping @MainActor (Int) -> Void = { _ in },
                    play: @escaping @MainActor (Data) async throws -> Void) async throws {
        guard let first = parts.first else { return }
        var pending = Task.detached { try await fetch(first) }
        defer { pending.cancel() }
        for index in parts.indices {
            let current = pending
            let data = try await withTaskCancellationHandler { try await current.value } onCancel: { current.cancel() }
            try Task.checkCancellation()
            if index + 1 < parts.count {
                let next = parts[index + 1]
                pending = Task.detached { try await fetch(next) }
            }
            await onStart(index)
            try await play(data)
            try Task.checkCancellation()
        }
    }
}
