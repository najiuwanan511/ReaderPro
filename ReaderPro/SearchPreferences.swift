import SwiftUI

enum SearchMatchMode: String, CaseIterable, Identifiable {
    case exact, fuzzy
    static let storageKey = "ReaderPro.searchMatchMode"
    var id: String { rawValue }
    var title: String { self == .exact ? "精确搜索" : "模糊搜索" }
    static var saved: Self { Self(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .fuzzy }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { !$0.isWhitespace && !"《》〈〉".contains($0) }
    }
    func matches(_ book: SourceBook, keyword: String) -> Bool {
        let key = normalized(keyword)
        guard !key.isEmpty else { return false }
        let title = normalized(book.title), author = normalized(book.author)
        switch self {
        case .exact: return title == key || author == key
        case .fuzzy: return title.contains(key) || author.contains(key)
        }
    }
}

enum SearchHistory {
    static let storageKey = "ReaderPro.searchHistory"
    static var values: [String] { UserDefaults.standard.stringArray(forKey: storageKey) ?? [] }
    static func record(_ keyword: String) {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        UserDefaults.standard.set(Array(([value] + values.filter { $0 != value }).prefix(30)), forKey: storageKey)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: storageKey) }
}

struct SearchScopePicker: View {
    let sources: [LegadoSource]
    @Binding var selection: Set<String>?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Set<String> = []
    @State private var query = ""
    private var visible: [LegadoSource] {
        sources.filter { query.isEmpty || ($0.bookSourceName + " " + $0.bookSourceGroup).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Menu("按分组选择") {
                        ForEach(Array(Set(sources.flatMap { ExploreSources.groupNames($0.bookSourceGroup) })).sorted(), id: \.self) { group in
                            Button(group) { draft = Set(sources.filter { ExploreSources.groupNames($0.bookSourceGroup).contains(group) }.map(\.id)) }
                        }
                    }
                    Button("选择当前列表") { draft.formUnion(visible.map(\.id)) }
                    Button("取消当前列表") { draft.subtract(visible.map(\.id)) }
                }
                Section("已选 \(draft.count) / \(sources.count) 个书源") {
                    ForEach(visible) { source in
                        Button {
                            if !draft.insert(source.id).inserted { draft.remove(source.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(source.bookSourceName)
                                    if !source.bookSourceGroup.isEmpty { Text(source.bookSourceGroup).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Image(systemName: draft.contains(source.id) ? "checkmark.circle.fill" : "circle")
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索书源或分组")
            .navigationTitle("搜索范围")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { selection = draft.count == sources.count ? nil : draft; dismiss() }
                }
            }
            .onAppear { draft = selection ?? Set(sources.map(\.id)) }
        }
    }
}
