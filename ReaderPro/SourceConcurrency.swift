import SwiftUI

enum SourceConcurrency {
    static let searchKey = "source.searchConcurrency"
    static let validationKey = "source.validationConcurrency"
    static let webKey = "source.webConcurrency"
    static func limit(_ value: Int, maximum: Int = 64) -> Int { min(maximum, max(1, value)) }
    static func value(_ key: String, fallback: Int, maximum: Int = 64, defaults: UserDefaults = .standard) -> Int {
        limit(defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key), maximum: maximum)
    }
    static var search: Int { value(searchKey, fallback: 32) }
    static var validation: Int { value(validationKey, fallback: 32) }
    static var web: Int { value(webKey, fallback: 4, maximum: 8) }
}

// Keep every available slot busy. A slow item must not hold back the next
// batch, and cancellation must never enqueue another source.
func streamConcurrentWork<Input, Output: Sendable>(
    _ inputs: [Input], concurrency: Int,
    operation: @escaping @Sendable (Input) async -> Output,
    update: @escaping @Sendable (Output) async -> Void
) async {
    guard !Task.isCancelled else { return }
    await withTaskGroup(of: Output.self) { group in
        var next = 0
        func enqueue() {
            let input = inputs[next]; next += 1
            group.addTask { await operation(input) }
        }
        while next < min(SourceConcurrency.limit(concurrency), inputs.count), !Task.isCancelled { enqueue() }
        for await result in group {
            guard !Task.isCancelled else { group.cancelAll(); break }
            await update(result)
            if !Task.isCancelled, next < inputs.count { enqueue() }
        }
    }
}

struct SourceConcurrencySettingsView: View {
    @AppStorage(SourceConcurrency.searchKey) private var search = 32
    @AppStorage(SourceConcurrency.validationKey) private var validation = 32
    @AppStorage(SourceConcurrency.webKey) private var web = 4

    var body: some View {
        Form {
            Section("书源任务") {
                Stepper("搜索并发数：\(search)", value: $search, in: 1...64)
                    .accessibilityIdentifier("searchConcurrency")
                Stepper("校验并发数：\(validation)", value: $validation, in: 1...64)
                    .accessibilityIdentifier("validationConcurrency")
                Text("搜索和校验默认同时处理 32 个书源。完成一个立即补上下一个，结果陆续显示；修改后从下一次任务生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("网页脚本") {
                Stepper("网页并发数：\(web)", value: $web, in: 1...8)
                    .accessibilityIdentifier("webConcurrency")
                Text("需要网页执行脚本的书源另受此项限制，默认 4 个。网页越多，内存占用越高；普通网络书源仍按上方并发数运行。书源自身的请求间隔继续生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("恢复默认并发数") { search = 32; validation = 32; web = 4 }
        }
        .navigationTitle("搜索与校验并发")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            search = SourceConcurrency.search
            validation = SourceConcurrency.validation
            web = SourceConcurrency.web
        }
    }
}
