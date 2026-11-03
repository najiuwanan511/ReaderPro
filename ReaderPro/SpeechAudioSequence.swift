import Foundation

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
            try await play(data)
            try Task.checkCancellation()
        }
    }
}
