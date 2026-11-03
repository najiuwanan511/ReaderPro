import SwiftUI
import UIKit
import CryptoKit

// MARK: - 漫画图片缓存（内存 + 磁盘 + 带 UA 下载，规避部分防盗链）

final class MangaImageStore {
    static let shared = MangaImageStore()
    private let mem = NSCache<NSString, UIImage>()
    private let generationLock = NSLock()
    private var generation: UInt64 = 0
    private func cacheGeneration() -> UInt64 { generationLock.lock(); defer { generationLock.unlock() }; return generation }
    func clear(bookID: String) {
        generationLock.lock(); generation &+= 1; generationLock.unlock()
        mem.removeAllObjects()
        try? FileManager.default.removeItem(at: BookStore.filesDir.appendingPathComponent(bookID).appendingPathComponent("mangaCache"))
    }

    func image(for urlString: String, bookId: String, source: LegadoSource? = nil) async -> UIImage? {
        let token = cacheGeneration()
        let cacheKey = bookId + "|" + urlString + "|" + (source.map(SourceValidation.fingerprint) ?? "")
        if let m = mem.object(forKey: cacheKey as NSString) { return m }
        if let cached = readDisk(cacheKey, bookId: bookId) {
            mem.setObject(cached, forKey: cacheKey as NSString)
            return cached
        }
        do {
            let data = try await SourceImagePipeline.load(urlString, source: source, cover: false)
            guard !Task.isCancelled, cacheGeneration() == token else { return nil }
            if let img = UIImage(data: data) {
                writeDisk(data, cacheKey, bookId: bookId)
                mem.setObject(img, forKey: cacheKey as NSString)
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
    var source: LegadoSource? = nil
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
                if let img = await MangaImageStore.shared.image(for: ref, bookId: bookId, source: source) {
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
    @State private var chapterTask: Task<Void, Never>?
    @State private var prefetchTask: Task<Void, Never>?
    @State private var loadToken = UUID()
    @AppStorage("manga.brightness") private var imageBrightness = 0.0
    @AppStorage("manga.contrast") private var imageContrast = 1.0
    @AppStorage("manga.saturation") private var imageSaturation = 1.0
    @AppStorage("manga.showFooter") private var showFooter = true
    @State private var showImageSettings = false
    @State private var showSourceAction = false
    @State private var paymentAction = false
    @State private var landAtEnd = false

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
                    let proposed = min(max(0, b.chapterIndex), max(0, b.chapters.count - 1))
                    chapter = b.chapters.readableIndex(from: proposed) ?? b.chapters.readableIndex(from: proposed, direction: -1) ?? 0
                    page = b.paragraphIndex
                    loadChapterImages(b)
                } else {
                    page = b.paragraphIndex
                }
            }
        }
        .onDisappear { saveProgress(); chapterTask?.cancel(); prefetchTask?.cancel(); loadToken = UUID() }
        .toolbar {
            Button { showImageSettings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("漫画设置")
            if let book, let source = store.sourceForBook(book) {
                Menu {
                    if source.customButton { Button("书源自定义按钮") { paymentAction = false; showSourceAction = true } }
                    if !(source.ruleContent.androidValue("payAction") ?? "").isEmpty { Button("购买 / 解锁本章") { paymentAction = true; showSourceAction = true } }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .sheet(isPresented: $showSourceAction) {
            if let book, let source = store.sourceForBook(book) {
                NavigationStack {
                    SourceCustomActionView(source: source, book: book.sourceBook,
                        chapter: book.chapters.indices.contains(chapter) ? book.chapters[chapter] : nil, payment: paymentAction,
                        onPaymentSuccess: {
                            chapterTask?.cancel(); prefetchTask?.cancel(); loadToken = UUID()
                            try await store.refreshPurchasedChapter(bookID: bookId, chapterURL: book.chapters.indices.contains(chapter) ? book.chapters[chapter].url : nil)
                            MangaImageStore.shared.clear(bookID: bookId)
                            if let current = self.book { chapter = current.chapterIndex; loadChapterImages(current) }
                        })
                }
            }
        }
        .sheet(isPresented: $showImageSettings) {
            NavigationStack {
                Form {
                    Toggle("显示页脚", isOn: $showFooter)
                    Section("图片") {
                        Text("亮度"); Slider(value: $imageBrightness, in: -0.5...0.5)
                        Text("对比度"); Slider(value: $imageContrast, in: 0.5...2)
                        Text("饱和度"); Slider(value: $imageSaturation, in: 0...2)
                        Button("还原图片设置") { imageBrightness = 0; imageContrast = 1; imageSaturation = 1 }
                    }
                }.navigationTitle("漫画设置").toolbar { Button("完成") { showImageSettings = false } }
            }
        }
    }

    @ViewBuilder
    func onlineHeader(_ b: LocalBook) -> some View {
        VStack(spacing: 4) {
            HStack {
                Button { changeChapter(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(b.chapters.readableIndex(from: chapter - 1, direction: -1) == nil)
                Spacer()
                Text(b.chapters.isEmpty ? "无章节" : "\(chapter + 1)/\(b.chapters.count)  \(b.chapters[chapter].title)")
                    .font(.caption).lineLimit(1)
                Spacer()
                Button { changeChapter(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(b.chapters.readableIndex(from: chapter + 1) == nil)
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
                    ForEach(Array(displayImages.enumerated()), id: \.offset) { _, address in
                        MangaPageImage(isRemote: isOnline, ref: address, bookId: b.id, enhanced: enhanced, source: store.sourceForBook(b))
                            .brightness(imageBrightness).contrast(imageContrast).saturation(imageSaturation)
                    }
                    if isOnline, b.chapters.readableIndex(from: chapter + 1) != nil { Button("下一章") { changeChapter(1) }.padding() }
                }
            }
        } else {
            TabView(selection: $page) {
                if isOnline, b.chapters.readableIndex(from: chapter - 1, direction: -1) != nil { Text("上一章").tag(-1) }
                ForEach(Array(displayImages.enumerated()), id: \.offset) { i, address in
                    MangaPageImage(isRemote: isOnline, ref: address, bookId: b.id, enhanced: enhanced, source: store.sourceForBook(b))
                        .brightness(imageBrightness).contrast(imageContrast).saturation(imageSaturation)
                        .scaleEffect(zoom)
                        .gesture(MagnificationGesture().onChanged { zoom = max(1.0, min(4.0, $0)) })
                        .tag(i)
                }
                if isOnline, b.chapters.readableIndex(from: chapter + 1) != nil { Text("下一章").tag(pageCount) }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .onChange(of: page) { _, value in
                if value < 0 { changeChapter(-1) }
                else if value >= pageCount, pageCount > 0 { changeChapter(1) }
            }
        }
    }

    @ViewBuilder
    func controls(_ b: LocalBook) -> some View {
        HStack {
            if showFooter { Text(pageCount == 0 ? "0 / 0" : "\(page + 1) / \(pageCount)").font(.caption) }
            Spacer()
            Button(enhanced ? "原图" : "增强") { enhanced.toggle() }
            Button(stripMode ? "单页模式" : "条漫模式") { stripMode.toggle() }
            Button(ocrRunning ? "识别中…" : "本页 OCR") { runOcr() }.disabled(ocrRunning || pageCount == 0)
        }.padding()
    }

    func loadChapterImages(_ b: LocalBook) {
        chapterTask?.cancel(); prefetchTask?.cancel(); loadToken = UUID(); loadingChapter = false; loadError = ""
        let token = loadToken
        guard isOnline, b.chapters.indices.contains(chapter) else { return }
        let ch = b.chapters[chapter]
        if !ch.imageUrls.isEmpty {
            page = landAtEnd ? max(0, ch.imageUrls.count - 1) : min(page, max(0, ch.imageUrls.count - 1)); landAtEnd = false
            prefetch(after: chapter)
            return
        }
        guard let src = store.sourceForBook(b) else { loadError = "书源已删除，无法拉取"; return }
        loadingChapter = true; loadError = ""
        let chIndex = chapter
        let nextURL = b.chapters.readableIndex(from: chIndex + 1).flatMap { b.chapters[$0].url }
        chapterTask = Task {
            do {
                let imgs = try await src.fetchChapterImages(ch, nextChapterUrl: nextURL)
                await MainActor.run {
                    guard !Task.isCancelled, loadToken == token else { return }
                    if var nb = store.books.first(where: { $0.id == bookId }), chIndex < nb.chapters.count {
                        nb.chapters[chIndex].imageUrls = imgs
                        store.updateBook(nb)
                    }
                    loadingChapter = false
                    if chIndex == chapter { page = landAtEnd ? max(0, imgs.count - 1) : 0; landAtEnd = false }
                    if imgs.isEmpty { loadError = "这一章没拉到图片（规则不匹配或该站拒绝）" }
                    else { prefetch(after: chIndex) }
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled, loadToken == token else { return }
                    loadingChapter = false
                    loadError = "拉取失败：\(sourceErrorMessage(error))"
                }
            }
        }
    }

    func changeChapter(_ delta: Int) {
        guard let b = book, isOnline else { return }
        guard let nc = b.chapters.readableIndex(from: chapter + delta, direction: delta) else { return }
        saveProgress()
        chapter = nc; page = 0; zoom = 1.0; landAtEnd = delta < 0 && !stripMode
        loadChapterImages(b)
    }

    func prefetch(after index: Int) {
        prefetchTask?.cancel()
        let count = min(50, max(0, UserDefaults.standard.object(forKey: "reader.preloadCount") as? Int ?? 3))
        guard count > 0, let current = book, let source = store.sourceForBook(current) else { return }
        let targets = Array(current.chapters.indices.dropFirst(index + 1).filter { !current.chapters[$0].isVolume }.prefix(count))
        prefetchTask = Task {
            for target in targets {
                guard !Task.isCancelled, let latest = book, latest.chapters.indices.contains(target), store.sourceForBook(latest) == source else { return }
                let original = latest.chapters[target]
                do {
                    let next = latest.chapters.readableIndex(from: target + 1).flatMap { latest.chapters[$0].url }
                    let urls = original.imageUrls.isEmpty ? try await source.fetchChapterImages(original, nextChapterUrl: next) : original.imageUrls
                    guard !Task.isCancelled else { return }
                    if var saved = book, saved.chapters.indices.contains(target), saved.chapters[target].id == original.id {
                        saved.chapters[target].imageUrls = urls; store.updateBook(saved)
                    }
                    for url in urls {
                        guard !Task.isCancelled else { return }
                        _ = await MangaImageStore.shared.image(for: url, bookId: bookId, source: source)
                    }
                } catch {
                    if !Task.isCancelled { SourceExecutionLog.shared.add("漫画预缓存：" + sourceErrorMessage(error), source: source.bookSourceUrl) }
                }
            }
        }
    }

    func runOcr() {
        guard let b = book, page < displayImages.count else { return }
        let ref = displayImages[page]
        ocrRunning = true
        Task {
            var img: UIImage?
            if isOnline {
                img = await MangaImageStore.shared.image(for: ref, bookId: b.id, source: store.sourceForBook(b))
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
