import SwiftUI

enum ReaderTapAction: String, CaseIterable, Identifiable {
    case previous = "上一页", next = "下一页", menu = "菜单", bookmark = "书签", speech = "朗读", previousChapter = "上一章", nextChapter = "下一章", none = "无操作"
    case previousParagraph = "朗读上一段", nextParagraph = "朗读下一段", editContent = "编辑正文", toggleReplace = "切换替换净化", catalog = "目录", search = "搜索正文", pauseSpeech = "暂停 / 继续朗读"
    var id: String { rawValue }
}
enum ReaderInteraction {
    static func key(_ row: Int, _ column: Int) -> String { "reader.tap.\(row).\(column)" }
    static func defaultAction(column: Int) -> ReaderTapAction { column == 0 ? .previous : (column == 2 ? .next : .menu) }
    static func action(at point: CGPoint, size: CGSize, defaults: UserDefaults = .standard) -> ReaderTapAction {
        let column = min(2, max(0, Int(point.x / max(1, size.width) * 3)))
        let row = min(2, max(0, Int(point.y / max(1, size.height) * 3)))
        return defaults.string(forKey: key(row, column)).flatMap(ReaderTapAction.init(rawValue:)) ?? defaultAction(column: column)
    }
}
struct ReaderInteractionSettingsView: View {
    @AppStorage("reader.landscapeDoublePage") private var doublePage = false
    @AppStorage("reader.keyboardPage") private var keyboardPage = true
    @AppStorage("reader.selectionEnabled") private var selectionEnabled = true
    @AppStorage("reader.swipeDistance") private var swipeDistance = 50.0
    @State private var revision = 0
    var body: some View {
        Form {
            Toggle("横屏双页", isOn: $doublePage)
            Text("横屏时并排显示两页；滚动模式使用连续排版。").font(.caption).foregroundStyle(.secondary)
            Toggle("允许长按选择正文", isOn: $selectionEnabled)
            Toggle("外接键盘翻页", isOn: $keyboardPage)
            Text("方向键、Page Up / Down 和空格翻页，Esc 打开阅读菜单。").font(.caption).foregroundStyle(.secondary)
            Stepper("滑动触发距离：\(Int(swipeDistance)) 点", value: $swipeDistance, in: 20...150, step: 5)
            Section("点击区域") {
                ForEach(0..<3, id: \.self) { row in
                    HStack {
                        ForEach(0..<3, id: \.self) { column in
                            Picker("\(["上", "中", "下"][row])\(["左", "中", "右"][column])", selection: Binding(get: {
                                UserDefaults.standard.string(forKey: ReaderInteraction.key(row, column)).flatMap(ReaderTapAction.init(rawValue:)) ?? ReaderInteraction.defaultAction(column: column)
                            }, set: {
                                UserDefaults.standard.set($0.rawValue, forKey: ReaderInteraction.key(row, column)); revision += 1
                            })) { ForEach(ReaderTapAction.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
                        }
                    }
                }
                Button("恢复默认点击区域") {
                    for row in 0..<3 { for column in 0..<3 { UserDefaults.standard.removeObject(forKey: ReaderInteraction.key(row,column)) } }; revision += 1
                }
            }.id(revision)
        }.navigationTitle("阅读操作")
    }
}
