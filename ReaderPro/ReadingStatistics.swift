import Foundation
import Combine

final class ReadingStatistics: ObservableObject {
    struct Entry: Codable, Identifiable {
        var id: String { bookID + "|" + day }
        let bookID: String
        var title: String
        let day: String
        var seconds: Double
    }
    static let shared = ReadingStatistics()
    @Published private(set) var entries: [Entry]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: "reader.dailyStatistics").flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }
    // Return newly completed minutes, carrying sub-minute sessions forward.
    @discardableResult func record(bookID: String, title: String, from start: Date, to end: Date, calendar: Calendar = .current) -> Int {
        guard end > start else { return 0 }
        let previous = entries.filter { $0.bookID == bookID }.reduce(0) { $0 + $1.seconds }
        var cursor = start
        while cursor < end {
            let stop = min(end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor)) ?? end)
            guard stop > cursor else { break }
            let parts = calendar.dateComponents([.year,.month,.day], from: cursor)
            let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            let seconds = stop.timeIntervalSince(cursor)
            if let index = entries.firstIndex(where: { $0.bookID == bookID && $0.day == day }) { entries[index].seconds += seconds; entries[index].title = title }
            else { entries.append(Entry(bookID: bookID, title: title, day: day, seconds: seconds)) }
            cursor = stop
        }
        defaults.set(try? JSONEncoder().encode(entries), forKey: "reader.dailyStatistics")
        let current = entries.filter { $0.bookID == bookID }.reduce(0) { $0 + $1.seconds }
        return max(0, Int(current / 60) - Int(previous / 60))
    }
    var dailyTotals: [(day: String, seconds: Double)] {
        Dictionary(grouping: entries, by: \.day).map { (day: $0.key, seconds: $0.value.reduce(0) { $0 + $1.seconds }) }.sorted { $0.day > $1.day }
    }
}
