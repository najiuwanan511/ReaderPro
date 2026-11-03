import Foundation

/// Legado concurrentRate is requests per milliseconds, not a maximum number
/// of currently active requests. A single integer means one request per interval.
final class SourceRateLimiter: @unchecked Sendable {
    static let shared = SourceRateLimiter()
    struct Rate: Equatable {
        let count: Int
        let interval: TimeInterval
        init?(_ text: String) {
            let parts = text.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard (1...2).contains(parts.count), let last = parts.last, let ms = last, ms > 0,
                  let count = parts.count == 1 ? 1 : parts[0], count > 0 else { return nil }
            self.count = count; interval = Double(ms) / 1000
        }
    }
    private struct Window { var rate: Rate; var start: Date; var count: Int }
    private var windows: [String: Window] = [:]
    private let lock = NSLock()

    private func delay(source: String, rate: Rate) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        var window = windows[source] ?? Window(rate: rate, start: now, count: 0)
        if window.rate != rate || now.timeIntervalSince(window.start) >= rate.interval {
            window = Window(rate: rate, start: now, count: 0)
        }
        if window.count < rate.count {
            window.count += 1; windows[source] = window; return 0
        }
        return max(0, rate.interval - now.timeIntervalSince(window.start))
    }

    func wait() async throws {
        guard let source = LegadoJSCtx.ruleSource, let rate = Rate(source.concurrentRate) else { return }
        while true {
            try Task.checkCancellation()
            let pause = delay(source: source.bookSourceUrl, rate: rate)
            if pause <= 0 { return }
            if let deadline = LegadoJSCtx.deadline, Date().addingTimeInterval(pause) > deadline { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: UInt64(min(pause, 1) * 1_000_000_000))
        }
    }

    func waitBlocking() throws {
        guard let source = LegadoJSCtx.ruleSource, let rate = Rate(source.concurrentRate) else { return }
        while true {
            try Task.checkCancellation()
            let pause = delay(source: source.bookSourceUrl, rate: rate)
            if pause <= 0 { return }
            if let deadline = LegadoJSCtx.deadline, Date().addingTimeInterval(pause) > deadline { throw URLError(.timedOut) }
            Thread.sleep(forTimeInterval: min(pause, 0.05))
        }
    }
}
