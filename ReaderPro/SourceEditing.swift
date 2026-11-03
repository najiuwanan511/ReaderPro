import Foundation

extension BookStore {
    @discardableResult func saveEditedSource(_ text: String, replacing id: String) throws -> LegadoSource {
        guard let data = text.data(using: .utf8) else { throw SourceFailure(stage: "书源编辑", message: "规则不是有效的 UTF-8 文本") }
        var edited = try JSONDecoder().decode(LegadoSource.self, from: data)
        guard !edited.bookSourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isSourceURL(edited.bookSourceUrl) else {
            throw SourceFailure(stage: "书源编辑", message: "请填写书源名称和有效的 HTTP/HTTPS 书源地址")
        }
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            throw SourceFailure(stage: "书源编辑", message: "书源已被删除，请重新导入")
        }
        guard !sources.contains(where: { $0.id != id && $0.bookSourceUrl == edited.bookSourceUrl }) else {
            throw SourceFailure(stage: "书源编辑", message: "该地址已存在另一个书源，请先处理重复书源")
        }
        edited.id = id
        sources[index] = edited
        save()
        return edited
    }
}
