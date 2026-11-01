import SwiftUI
import UIKit
import CryptoKit

// MARK: - 漫画图片缓存（内存 + 磁盘 + 带 UA 下载，规避部分防盗链）

final class MangaImageStore {
    static let shared = MangaImageStore()
    private let mem = NSCache<NSString, UIImage>()

    func image(for urlString: String, bookId: String) async -> UIImage? {
        if let m = mem.object(forKey: urlString as NSString) { return m }
        if let cached = readDisk(urlString, bookId: bookId) {
            mem.setObject(cached, forKey: urlString as NSString)
            return cached
        }
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(sourceUA, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await SourceHTTP.session.data(for: req)
            if let img = UIImage(data: data) {
                writeDisk(data, urlString, bookId: bookId)
                mem.setObject(img, forKey: urlString as NSString)
                return img
            }
        } catch { return nil }
        return nil
    }

    private func cacheURL(_ urlString: String, bookId: String) -> URL {
        let dir = BookStore.filesDir.appendingPathComponent(bookId).appendingPathComponent("mangaCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(urlString.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(digest + ".img")
    }
    private func readDisk(_ urlString: String, bookId: String) -> UIImage? {
        guard let d = try? Data(contentsOf: cacheURL(urlString, bookId: bookId)) else { return nil }
        return UIImage(data: d)
    }
    private func writeDisk(_ data: Data, _ urlString: String, bookId: String) {
        try? data.write(to: cacheURL(urlString, bookId: bookId))
    }
}

// MARK: - 单页漫画图（本地文件 / 远程 URL 统一）

struct MangaPageImage: View {
    let isRemote: Bool
    let ref: String          // 远程 URL 或本地文件名
    let bookId: String
    let enhanced: Bool
    @State private var ui: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let ui = ui {
                Image(uiImage: ui).resizable().scaledToFit()
            } else if failed {
                VStack(spacing: 6) {
                    Image(systemName: "photo").font(.largeTitle)
                    Text("加载失败").font(.caption)
                }.foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: "\(ref)|\(enhanced)") {
            ui = nil
            failed = false
            if isRemote {
                if let img = await MangaImageStore.shared.image(for: ref, bookId: bookId) {
                    ui = enhanced ? enhancedImage(img) : img
                } else { failed = true }
            } else {
                let url = BookStore.filesDir.appendingPathComponent(bookId).appendingPathComponent((ref as NSString).lastPathComponent)
                if let d = try? Data(contentsOf: url), let img = UIImage(data: d) {
                    ui = enhanced ? enhancedImage(img) : img
                } else { failed = true }
            }
        }
    }
}

// MARK: - Manga（本地 CBZ + 在线漫画书源）

struct MangaView: View {
    @ObservedObject var store: BookStore
    var bookId: String
    @State private var page = 0
    @State private var chapter = 0
    @State private var stripMode = false
    @State private var enhanced = false
    @State private var ocrText = ""
    @State private var showOcr = false
    @State private var ocrRunning = false
    @State private var zoom: CGFloat = 1.0
    @State private var loadingChapter = false
    @State private var loadError = ""

    var book: LocalBook? { store.books.first { $0.id == bookId } }
    var isOnline: Bool { book?.kind == "comic" }
    var displayImages: [String] {
        guard let b = book else { return [] }
        if isOnline {
            guard chapter >= 0 && chapter < b.chapters.count else { return [] }
            return b.chapters[chapter].imageUrls
        }
        return b.imageNames
    }
    var pageCount: Int { displayImages.count }

    var body: some View {
        VStack(spacing: 0) {
            if let b = book {
                if isOnline { onlineHeader(b) }
                content(b)
                controls(b)
            }
        }
        .sheet(isPresented: $showOcr) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView { Text(ocrText).padding() }
                    Button("存为 TXT 书") {
                        var nb = LocalBook(title: (book?.title ?? "OCR") + "（OCR）", fileName: "ocr.txt", kind: "txt")
                        nb.chapters = [BookChapter(title: "OCR 结果", text: ocrText)]
                        store.updateBook(nb); showOcr = false
                    }.buttonStyle(.borderedProminent)
                    Spacer()
                }
                .navigationTitle("OCR 结果")
                .toolbar { Button("关闭") { showOcr = false } }
            }
        }
        .navigationTitle(book?.title ?? "漫画")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let b = book {
                if isOnline {
                    chapter = min(b.chapterIndex, max(0, b.chapters.count - 1))
                    page = b.paragraphIndex
                    loadChapterImages(b)
                } else {
                    page = b.paragraphIndex
                }
            }
        }
        .onDisappear { saveProgress() }
    }

    @ViewBuilder
    func onlineHeader(_ b: LocalBook) -> some View {
        VStack(spacing: 4) {
            HStack {
                Button { changeChapter(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(chapter <= 0)
                Spacer()
                Text(b.chapters.isEmpty ? "无章节" : "\(chapter + 1)/\(b.chapters.count)  \(b.chapters[chapter].title)")
                    .font(.caption).lineLimit(1)
                Spacer()
                Button { changeChapter(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(chapter >= b.chapters.count - 1)
            }
            if loadingChapter {
                ProgressView().controlSize(.small)
            } else if !loadError.isEmpty {
                Text(loadError).font(.caption2).foregroundStyle(.orange).lineLimit(2).padding(.horizontal)
            }
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    @ViewBuilder
    func content(_ b: LocalBook) -> some View {
        if displayImages.isEmpty {
            VStack(spacing: 8) {
                if loadingChapter {
                    ProgressView("正在加载章节图片…")
                } else {
                    Text(isOnline ? "这一章还没有图片，点左右切换章节，或重新打开。" : "这本书没有图片。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if isOnline && !loadError.isEmpty {
                        Text(loadError).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if stripMode {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(displayImages.indices, id: \.self) { i in
                        MangaPageImage(isRemote: isOnline, ref: displayImages[i], bookId: b.id, enhanced: enhanced)
                    }
                }
            }
        } else {
            TabView(selection: $page) {
                ForEach(displayImages.indices, id: \.self) { i in
                    MangaPageImage(isRemote: isOnline, ref: displayImages[i], bookId: b.id, enhanced: enhanced)
                        .scaleEffect(zoom)
                        .gesture(MagnificationGesture().onChanged { zoom = max(1.0, min(4.0, $0)) })
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
        }
    }

    @ViewBuilder
    func controls(_ b: LocalBook) -> some View {
        HStack {
            Text(pageCount == 0 ? "0 / 0" : "\(page + 1) / \(pageCount)").font(.caption)
            Spacer()
            Button(enhanced ? "原图" : "增强") { enhanced.toggle() }
            Button(stripMode ? "单页模式" : "条漫模式") { stripMode.toggle() }
            Button(ocrRunning ? "识别中…" : "本页 OCR") { runOcr() }.disabled(ocrRunning || pageCount == 0)
        }.padding()
    }

    func loadChapterImages(_ b: LocalBook) {
        guard isOnline, chapter < b.chapters.count else { return }
        let ch = b.chapters[chapter]
        if !ch.imageUrls.isEmpty {
            page = min(page, max(0, ch.imageUrls.count - 1))
            return
        }
        guard let src = store.sourceForBook(b) else { loadError = "书源已删除，无法拉取"; return }
        loadingChapter = true; loadError = ""
        let chIndex = chapter
        let nextURL = b.chapters.indices.contains(chIndex + 1) ? b.chapters[chIndex + 1].url : nil
        Task {
            do {
                let imgs = try await src.fetchChapterImages(ch, nextChapterUrl: nextURL)
                await MainActor.run {
                    if var nb = store.books.first(where: { $0.id == bookId }), chIndex < nb.chapters.count {
                        nb.chapters[chIndex].imageUrls = imgs
                        store.updateBook(nb)
                    }
                    loadingChapter = false
                    if chIndex == chapter { page = 0 }
                    if imgs.isEmpty { loadError = "这一章没拉到图片（规则不匹配或该站拒绝）" }
                }
            } catch {
                await MainActor.run {
                    loadingChapter = false
                    loadError = "拉取失败：\(sourceErrorMessage(error))"
                }
            }
        }
    }

    func changeChapter(_ delta: Int) {
        guard let b = book, isOnline else { return }
        let nc = chapter + delta
        guard nc >= 0 && nc < b.chapters.count else { return }
        chapter = nc; page = 0; zoom = 1.0
        loadChapterImages(b)
    }

    func runOcr() {
        guard let b = book, page < displayImages.count else { return }
        let ref = displayImages[page]
        ocrRunning = true
        Task {
            var img: UIImage?
            if isOnline {
                img = await MangaImageStore.shared.image(for: ref, bookId: b.id)
            } else {
                let url = BookStore.filesDir.appendingPathComponent(b.id).appendingPathComponent((ref as NSString).lastPathComponent)
                if let d = try? Data(contentsOf: url) { img = UIImage(data: d) }
            }
            guard let ui = img else {
                await MainActor.run { ocrRunning = false; ocrText = "图片加载失败"; showOcr = true }
                return
            }
            do {
                let t = try await ocrImage(ui)
                await MainActor.run { ocrText = t.isEmpty ? "（本页没有识别到文字）" : t; ocrRunning = false; showOcr = true }
            } catch {
                await MainActor.run { ocrText = "识别失败：\(sourceErrorMessage(error))"; ocrRunning = false; showOcr = true }
            }
        }
    }

    func saveProgress() {
        guard var b = book else { return }
        if isOnline {
            b.chapterIndex = chapter
            b.paragraphIndex = page
            b.progress = b.chapters.isEmpty ? 0 : Double(chapter) / Double(b.chapters.count)
        } else {
            b.paragraphIndex = page
        }
        store.updateBook(b)
    }
}
