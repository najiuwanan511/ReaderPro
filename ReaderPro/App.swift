import SwiftUI

@main
struct ReaderProApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)  // 对标开源阅读：默认深色 Material 风
        }
    }
}
