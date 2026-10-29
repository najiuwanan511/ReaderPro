import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("书架（占位）") {
                    Text("本地 TXT / EPUB 导入：待接")
                    Text("书源搜索：待接")
                    Text("漫画 CBZ：待接")
                }
                Section("说明") {
                    Text("这是 Windows + 云构建验证版：先跑通编译、打包、AltStore 安装，再往里面填阅读器功能。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Ciallo Reader iOS")
        }
    }
}
