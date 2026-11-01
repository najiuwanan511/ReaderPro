import Foundation

// JavaScriptCore callbacks are synchronous, as are Legado's Java interfaces.
// Only rule workers call this bridge; URLSession callbacks use their own queue.
enum SourceJSBridge {
    private static let importedScripts: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 128
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    private static let importCacheLock = NSLock()
    private static var importCacheGeneration: UInt64 = 0

    // Legado stores downloaded scripts under md5Encode16(url), so a source
    // can remove that cache key after detecting a changed ETag. Evicting the
    // bounded in-memory cache on any explicit deletion is conservative and
    // avoids keeping a separate unbounded reverse index of script URLs.
    static func invalidateImportedScripts() {
        importCacheLock.lock(); defer { importCacheLock.unlock() }
        importCacheGeneration &+= 1
        importedScripts.removeAllObjects()
    }

    // Android's importScript returns source text, rather than evaluating it.
    // Cache downloaded libraries for this process and resolve local relative
    // paths against the app's Documents directory.
    static func importScript(_ path: String, base: String, headers: [String: String], source: String = "") throws -> String {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw SourceFailure(stage: "导入脚本", message: "脚本地址为空") }
        if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") {
            let url = URL(string: value)
            // An imported script may depend on an account, cookie, proxy or
            // source-specific headers. Do not reuse those responses; shared
            // cookie storage can change between consecutive evaluations.
            func cacheable() -> Bool {
                guard headers.isEmpty, let url, url.query == nil, url.user == nil, url.password == nil else { return false }
                return (HTTPCookieStorage.shared.cookies(for: url) ?? []).isEmpty
            }
            let key = ((source.isEmpty ? base : source) + "\n" + value) as NSString
            let eligible = cacheable()
            importCacheLock.lock()
            let generation = importCacheGeneration
            let cached = eligible ? importedScripts.object(forKey: key) : nil
            importCacheLock.unlock()
            if let cached { return cached as String }
            let response = try request(value, base: base, headers: headers)
            let status = response["status"] as? Int ?? 0
            guard (200..<300).contains(status) else {
                throw SourceFailure(stage: "导入脚本", message: "HTTP \(status)", url: value)
            }
            let script = response["text"] as? String ?? ""
            guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SourceFailure(stage: "导入脚本", message: "脚本内容为空", url: value)
            }
            if eligible && cacheable() {
                importCacheLock.lock()
                // A cache.delete while the request was in flight must not
                // repopulate the cache with the just-invalidated response.
                if generation == importCacheGeneration {
                    importedScripts.setObject(script as NSString, forKey: key, cost: script.utf8.count)
                }
                importCacheLock.unlock()
            }
            return script
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = (value.hasPrefix("/") ? URL(fileURLWithPath: value) : documents.appendingPathComponent(value))
            .resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(home.path + "/") else {
            throw SourceFailure(stage: "导入脚本", message: "本地脚本不在应用数据目录中")
        }
        let script = decodeTextData(try Data(contentsOf: file))
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceFailure(stage: "导入脚本", message: "脚本内容为空")
        }
        return script
    }

    final class ResponseBox: @unchecked Sendable {
        let lock = NSLock()
        var result: Result<(Data, URLResponse), Error>?
        func set(_ value: Result<(Data, URLResponse), Error>) { lock.lock(); result = value; lock.unlock() }
        func get() -> Result<(Data, URLResponse), Error>? { lock.lock(); defer { lock.unlock() }; return result }
    }

    static func request(_ address: String, base: String, headers: [String: String],
                        method: String = "", body: String = "", timeout: Double = 20,
                        followRedirects: Bool = true) throws -> [String: Any] {
        guard !Thread.isMainThread else { throw SourceFailure(stage: "脚本兼容性", message: "网络脚本必须在后台书源任务中执行") }
        if let inline = try SourceHTTP.inlinePage(address) {
            return ["text": inline.text, "url": inline.url, "status": 200, "headers": [String: String]()]
        }
        var request = try SourceHTTP.request(address, base: base, headers: headers,
                                             key: LegadoJSCtx.key)
        let options = SourceHTTP.options(address).options
        if options["webView"] as? Bool == true || !(options["webJs"] as? String ?? "").isEmpty {
            let page = try web(request, script: options["webJs"] as? String ?? "", delay: SourceHTTP.webViewDelay(options))
            return ["text": page.text, "url": page.url, "status": 200, "headers": [String: String]()]
        }
        if !method.isEmpty { request.httpMethod = method }
        if method == "POST" {
            request.httpBody = Data(body.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        let deadline = min(LegadoJSCtx.deadline ?? .distantFuture, Date().addingTimeInterval(max(0.1, timeout)))
        request.timeoutInterval = max(0.1, deadline.timeIntervalSinceNow)
        let box = ResponseBox()
        let completed = DispatchSemaphore(value: 0)
        let lease = try SourceTLS.lease(for: request, followRedirects: followRedirects)
        defer { lease.finish() }
        let task = lease.session.dataTask(with: request) { data, response, error in
            if let error { box.set(.failure(error)) }
            else if let data, let response { box.set(.success((data, response))) }
            else { box.set(.failure(URLError(.badServerResponse))) }
            completed.signal()
        }
        task.resume()
        while box.get() == nil {
            if Task.isCancelled { task.cancel(); throw CancellationError() }
            if Date() >= deadline { task.cancel(); throw URLError(.timedOut) }
            // Wake immediately for a completed request; timed waits retain
            // bounded cancellation/deadline checks while avoiding an extra
            // 20 ms delay on every synchronous ajax in a list script.
            _ = completed.wait(timeout: .now() + .milliseconds(20))
        }
        let result: (Data, URLResponse)
        do { result = try box.get()!.get() }
        catch { throw SourceTLS.contextualizeProxyError(error, request: request) }
        let (data, response) = result
        let http = response as? HTTPURLResponse
        let fields = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { $0[String(describing: $1.key).lowercased()] = String(describing: $1.value) }
        let text = (options["type"] as? String ?? "").isEmpty ? SourceHTTP.decode(data, response: response) : data.map { String(format: "%02x", $0) }.joined()
        return ["text": text, "url": response.url?.absoluteString ?? address,
                "status": http?.statusCode ?? 0, "headers": fields]
    }
}
