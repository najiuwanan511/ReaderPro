import SwiftUI

// Shared by network, paste, file, QR and search import entry points. Parsing
// never inherits MainActor, and a collection publishes only one merged array.
@MainActor final class SourceImportModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var phase = ""
    @Published private(set) var message = ""
    @Published private(set) var error = ""
    @Published private(set) var hasRssSources = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private(set) var started = Date()
    private(set) var canCancel = true

    func start(_ text: String, store: BookStore) {
        begin(store: store) { progress in
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("http://") || value.hasPrefix("https://") {
                return try await importSourcePacksFromURL(value, progress: progress)
            }
            progress("正在解析书源文件…")
            return importSourceDocument(value)
        }
    }
    func start(file: URL, store: BookStore) {
        begin(store: store) { progress in
            progress("正在读取书源文件…")
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: file)
            try Task.checkCancellation()
            progress("正在解析书源文件…")
            return importSourceDocument(decodeTextData(data))
        }
    }
    private func begin(store: BookStore, operation: @escaping @Sendable (@escaping @Sendable (String) -> Void) async throws -> SourcePackImportResult) {
        guard !running else { return }
        let id = UUID(); generation = id
        started = Date(); running = true; canCancel = true
        phase = "准备导入…"; message = ""; error = ""; hasRssSources = false
        task = Task {
            let worker = Task.detached(priority: .userInitiated) {
                try await operation { [weak self] status in
                    Task { @MainActor in
                        guard let self, self.generation == id, self.running, self.canCancel else { return }
                        self.phase = status
                    }
                }
            }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard !result.isEmpty else { throw SourceFailure(stage: "书源导入", message: "未找到有效书源或订阅源，请检查文件格式或链接。") }
                canCancel = false; phase = "已解析 \(result.sources.count) 个书源，正在合并并保存…"
                let summary = store.mergeImportedSources(result, persist: false)
                try await store.saveAsync()
                hasRssSources = !result.rssSources.isEmpty
                message = summary; phase = "导入完成"
            } catch {
                self.error = Task.isCancelled ? "已取消导入" : sourceErrorMessage(error)
                phase = ""
            }
            running = false; task = nil
        }
    }
    func cancel() { guard canCancel else { return }; task?.cancel() }
}

struct SourceImportStatusView: View {
    @ObservedObject var model: SourceImportModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.running {
                HStack(alignment: .top) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.phase).accessibilityIdentifier("sourceImportProgress")
                        TimelineView(.periodic(from: model.started, by: 1)) { context in
                            Text("已用时 \(max(0, Int(context.date.timeIntervalSince(model.started)))) 秒")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.canCancel { Button("取消导入") { model.cancel() }.accessibilityIdentifier("cancelSourceImport") }
                }
            }
            if !model.message.isEmpty {
                Text(model.message).foregroundStyle(AppTheme.accentDeep).accessibilityIdentifier("sourceNetworkImportResult")
            }
            if !model.error.isEmpty { Text(model.error).foregroundStyle(.red).accessibilityIdentifier("sourceImportError") }
        }.font(.footnote)
    }
}
