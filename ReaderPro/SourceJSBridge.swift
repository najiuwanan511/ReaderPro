import Foundation

// JavaScriptCore callbacks are synchronous, as are Legado's Java interfaces.
// Only rule workers call this bridge; URLSession callbacks use their own queue.
enum SourceJSBridge {
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
        let (data, response) = try box.get()!.get()
        let http = response as? HTTPURLResponse
        let fields = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { $0[String(describing: $1.key).lowercased()] = String(describing: $1.value) }
        let text = (options["type"] as? String ?? "").isEmpty ? SourceHTTP.decode(data, response: response) : data.map { String(format: "%02x", $0) }.joined()
        return ["text": text, "url": response.url?.absoluteString ?? address,
                "status": http?.statusCode ?? 0, "headers": fields]
    }
}
