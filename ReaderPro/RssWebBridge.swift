import WebKit

struct RssWebAction: Identifiable {
    let id = UUID()
    var command: String
    var value: String
    var scope = ""
}

final class RssWebBridge: NSObject, WKScriptMessageHandlerWithReply {
    let source: RssSource
    let onAction: (RssWebAction) -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]
    init(source: RssSource, onAction: @escaping (RssWebAction) -> Void) { self.source = source; self.onAction = onAction }
    func install(_ configuration: WKWebViewConfiguration) {
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "readerRss")
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
    func cancel() { for task in tasks.values { task.cancel() }; tasks = [:] }
    var script: String {
        let values = (try? JSONEncoder().encode(LegadoJS.persistentValues(source: source.sourceUrl))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let metadata = (try? JSONEncoder().encode(source)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let configuration = SourceScriptConfiguration.json([
            "read": SourceScriptConfiguration.readConfig(), "theme": SourceScriptConfiguration.themeConfig(),
            "mode": SourceScriptConfiguration.themeMode()
        ])
        return "var _readerRssValues=" + values + ";var source=" + metadata + ";var _readerConfiguration=" + configuration + ";\n" + #"""
        (function(){
          function call(command,args){return window.webkit.messageHandlers.readerRss.postMessage({command:command,args:Array.from(args||[]).map(function(v){return v==null?'':String(v);})});}
          function send(command,args){call(command,args).catch(function(e){console.error(String(e));});}
          function get(key){return _readerRssValues[String(key)]||'';}
          function put(key,value){key=String(key);value=String(value);_readerRssValues[key]=value;send('_put',[key,value]);return value;}
          source.get=get;source.put=put;source.getKey=function(){return source.sourceUrl;};source.getTag=function(){return source.sourceName;};
          var java=window.java||{};window.java=java;java.get=get;java.put=put;
          java.getThemeMode=function(){return _readerConfiguration.mode;};
          java.getThemeConfig=function(){return JSON.stringify(_readerConfiguration.theme);};
          java.getReadBookConfig=function(){return JSON.stringify(_readerConfiguration.read);};
          ['searchBook','addBook','showPhoto','open','openUrl','startBrowser','toast','longToast','copyText'].forEach(function(name){java[name]=function(){send(name,arguments);};});
          java.run=function(code){return call('run',[code]);};window.run=java.run;
          ['ajaxAwait','connectAwait','getAwait','headAwait','postAwait','webViewAwait','webViewGetSourceAwait','downloadFileAwait','readTxtFileAwait','importScriptAwait','getStringAwait','decryptStrAwait','encryptBase64Await','encryptHexAwait','createSignHexAwait'].forEach(function(name){
            java[name]=function(){return call(name,arguments);};window[name]=java[name];
          });
          window.cache={put:function(k,v,seconds){put('cache:'+k,JSON.stringify({value:String(v),until:seconds?Date.now()+seconds*1000:0}));},get:function(k){try{var item=JSON.parse(get('cache:'+k));return item.until&&item.until<=Date.now()?null:item.value;}catch(e){return null;}},delete:function(k){put('cache:'+k,'');send('_invalidate',[]);}};
        })();
        """#
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let input = message.body as? [String: Any], let command = input["command"] as? String,
              let args = input["args"] as? [String], args.count <= 6, args.reduce(0, { $0 + $1.utf8.count }) <= 2 * 1024 * 1024 else {
            replyHandler(nil, "订阅网页请求格式错误"); return
        }
        let first = args.first ?? ""
        switch command {
        case "_put":
            if args.count == 2 { LegadoJS.putPersistentValue(first, value: args[1], source: source.sourceUrl) }
            replyHandler(NSNull(), nil); return
        case "_invalidate": SourceJSBridge.invalidateImportedScripts(); replyHandler(NSNull(), nil); return
        case "searchBook", "addBook", "showPhoto", "open", "openUrl", "startBrowser", "toast", "longToast", "copyText":
            onAction(RssWebAction(command: command, value: first, scope: args.dropFirst().first ?? ""))
            replyHandler(NSNull(), nil); return
        default: break
        }
        let source = self.source, base = message.frameInfo.request.url?.absoluteString ?? source.sourceUrl, token = UUID()
        tasks[token] = Task { @MainActor [weak self] in
            let worker = Task.detached { try await Self.evaluate(command: command, args: args, source: source, base: base) }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); replyHandler(value, nil)
            } catch { replyHandler(nil, sourceErrorMessage(error)) }
            self?.tasks[token] = nil
        }
    }
    static func evaluate(command: String, args: [String], source: RssSource, base: String) async throws -> String {
        func argument(_ index: Int, fallback: String = "null") -> String { args.indices.contains(index) ? sourceJSONString(args[index]) : fallback }
        let script: String
        switch command {
        case "run": script = args.first ?? ""
        case "ajaxAwait": script = "java.ajax(" + argument(0) + ",Number(" + argument(1, fallback: "9000") + "))"
        case "connectAwait", "getAwait", "headAwait", "postAwait":
            let method = command == "connectAwait" ? "connect" : command.replacingOccurrences(of: "Await", with: "")
            let headersIndex = command == "postAwait" ? 2 : 1
            let header = "JSON.parse(" + argument(headersIndex, fallback: "'{}'") + "||'{}')"
            let timeout = "Number(" + argument(headersIndex + 1, fallback: "9000") + ")"
            let parameters = command == "postAwait" ? [argument(0), argument(1), header, timeout] : [argument(0), header, timeout]
            let output = command == "headAwait" ? "JSON.stringify(r.headers())" : command == "connectAwait" ? "'Response{code='+r.code()+', url='+r.url()+'}'" : "r.body()"
            script = "var r=java." + method + "(" + parameters.joined(separator: ",") + ");" + output
        case "getStringAwait": script = "java.setContent(" + argument(1, fallback: "''") + ");java.getString(" + argument(0) + ")"
        case "webViewAwait", "webViewGetSourceAwait":
            let name = command.replacingOccurrences(of: "Await", with: ""), cacheIndex = command == "webViewAwait" ? 3 : 4
            var parameters = (0..<cacheIndex).map { argument($0) }
            parameters.append(args.indices.contains(cacheIndex) && args[cacheIndex].lowercased() == "true" ? "true" : "false")
            if command == "webViewGetSourceAwait" { parameters.append("Number(" + argument(5, fallback: "0") + ")") }
            script = "java." + name + "(" + parameters.joined(separator: ",") + ")"
        case "downloadFileAwait", "readTxtFileAwait", "importScriptAwait":
            let name = command.replacingOccurrences(of: "Await", with: "")
            script = "java." + name + "(" + args.map(sourceJSONString).joined(separator: ",") + ")"
        case "decryptStrAwait", "encryptBase64Await", "encryptHexAwait":
            let name = command.replacingOccurrences(of: "Await", with: "")
            script = "java.createSymmetricCrypto(" + [argument(0),argument(1),argument(2)].joined(separator: ",") + ")." + name + "(" + argument(3) + ")"
        case "createSignHexAwait":
            script = "java.createSign(" + argument(0) + ").setPublicKey(" + argument(1) + ").setPrivateKey(" + argument(2) + ").signHex(" + argument(3) + ")"
        default: throw SourceFailure(stage: "订阅网页", message: "未知脚本接口：" + command)
        }
        return try await withTimeout(45) {
            try await source.ruleSource.withRules {
                let value = LegadoJS.run(script, input: "", baseUrl: base, sourceKey: "", sourceUrl: source.sourceUrl)
                try LegadoJSCtx.failures?.check(); return value
            }
        }
    }
}
