import SwiftUI

enum SourceScriptVideo {
    static func book(url: String, title: String, base: String) -> LocalBook {
        let address = resolveUrl(url, base: base)
        var book = LocalBook(title: title.isEmpty ? "视频" : title, fileName: "", kind: "video")
        // Raw resolved content bypasses the source's chapter extraction rules;
        // request headers, proxy, cookies and playback transport still apply.
        book.chapters = [BookChapter(title: book.title, text: address, url: address)]
        return book
    }

    @MainActor static func open(url: String, title: String, base: String, source: LegadoSource?) throws {
        let book = book(url: url, title: title, base: base)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        guard var presenter = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
            throw SourceFailure(stage: "脚本视频", message: "请在应用前台打开播放器")
        }
        while let next = presenter.presentedViewController { presenter = next }
        let controller = UIHostingController(rootView: VideoPlayerView(book: book, source: source))
        // Keep the requesting reader/search task alive while displaying media.
        controller.modalPresentationStyle = .overFullScreen
        presenter.present(controller, animated: true)
    }
}
