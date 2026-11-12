import Foundation
import JavaScriptCore

/// The published CAVI HTTP client runs inside JavaScriptCore. Native transport
/// owns loopback validation, response bounds, redirects and cancellation.
enum CaviConnectionClient {
    static func request(baseURL: String, path: String, body: Data, token: String?,
                        http: HostHTTPClient = .init(), headers: [String: String] = [:]) async throws -> Data {
        let operation = CaviConnectionRequest(baseURL: baseURL, path: path, body: body,
                                              token: token, headers: headers, http: http)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: { operation.cancel() }
    }
}

private final class CaviConnectionRequest: @unchecked Sendable {
    private let queue = DispatchQueue(label: "workbench.client-connection")
    private let baseURL: String, path: String, body: Data, token: String?
    private let headers: [String: String], http: HostHTTPClient
    private var context: JSContext?
    private var fetchResolution: JSValue?
    private var continuation: CheckedContinuation<Data, Error>?
    private var network: Task<Void, Never>?
    private var timers: [Int: DispatchWorkItem] = [:]
    private var nextTimer = 0
    private var cancelled = false
    private var finished = false

    init(baseURL: String, path: String, body: Data, token: String?, headers: [String: String], http: HostHTTPClient) {
        self.baseURL = baseURL; self.path = path; self.body = body
        self.token = token; self.headers = headers; self.http = http
    }
    func start(_ continuation: CheckedContinuation<Data, Error>) {
        queue.async {
            self.continuation = continuation
            if self.cancelled { self.finish(.failure(CancellationError())); return }
            self.evaluate()
        }
    }
    func cancel() {
        queue.async {
            self.cancelled = true
            self.network?.cancel()
            if self.continuation != nil { self.finish(.failure(CancellationError())) }
        }
    }
    private func evaluate() {
        guard let sourceURL = Bundle.main.url(forResource: "cavi-api-client", withExtension: "js"),
              let source = try? String(contentsOf: sourceURL, encoding: .utf8), let context = JSContext() else {
            finish(.failure(HostHTTPError.invalidResponse)); return
        }
        self.context = context
        context.exceptionHandler = { [weak self] _, _ in self?.finish(.failure(HostHTTPError.invalidResponse)) }
        let setTimer: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, delay in
            guard let self else { return 0 }
            nextTimer += 1
            let id = nextTimer
            let work = DispatchWorkItem { [weak self] in
                guard let self, !finished else { return }
                timers.removeValue(forKey: id); callback.call(withArguments: [])
            }
            timers[id] = work
            queue.asyncAfter(deadline: .now() + max(0, min(delay, 120_000)) / 1_000, execute: work)
            return id
        }
        let clearTimer: @convention(block) (Int) -> Void = { [weak self] id in self?.timers.removeValue(forKey: id)?.cancel() }
        let fetch: @convention(block) (String, String, JSValue, JSValue) -> Void = { [weak self] url, initJSON, resolve, _ in
            self?.fetch(url: url, initJSON: initJSON, resolve: resolve)
        }
        let complete: @convention(block) (String) -> Void = { [weak self] text in self?.finish(.success(Data(text.utf8))) }
        let fail: @convention(block) () -> Void = { [weak self] in self?.finish(.failure(HostHTTPError.invalidResponse)) }
        context.setObject(setTimer, forKeyedSubscript: "setTimeout" as NSString)
        context.setObject(clearTimer, forKeyedSubscript: "clearTimeout" as NSString)
        context.setObject(fetch, forKeyedSubscript: "nativeFetch" as NSString)
        context.setObject(complete, forKeyedSubscript: "nativeComplete" as NSString)
        context.setObject(fail, forKeyedSubscript: "nativeFail" as NSString)
        context.evaluateScript(Self.adapter)
        context.evaluateScript(source, withSourceURL: sourceURL)
        guard !finished, let object = try? JSONSerialization.jsonObject(with: body) else { finish(.failure(HostHTTPError.invalidResponse)); return }
        context.objectForKeyedSubscript("connectCavi")?.call(withArguments: [baseURL, path, object, token as Any? ?? NSNull(), headers])
    }
    private func fetch(url: String, initJSON: String, resolve: JSValue) {
        guard network == nil, url == baseURL + "/" + path,
              let data = initJSON.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              request["method"] as? String == "POST", let body = request["body"] as? String,
              let actualHeaders = request["headers"] as? [String: String],
              actualHeaders["Authorization"] == token.map({ "Bearer " + $0 }),
              headers.allSatisfy({ actualHeaders[$0.key] == $0.value }) else {
            finish(.failure(HostHTTPError.invalidResponse)); return
        }
        let host = ModelHost(name: "Workbench", provider: .openAICompatible, baseURL: baseURL)
        fetchResolution = resolve
        network = Task {
            do {
                let response = try await http.request(host: host, path: path, method: "POST", body: Data(body.utf8),
                    token: token, maximumBytes: 1_048_576, timeout: 120, headers: headers)
                try Task.checkCancellation()
                queue.async { [self] in
                    guard !finished, let text = String(data: response, encoding: .utf8) else { finish(.failure(HostHTTPError.invalidResponse)); return }
                    fetchResolution?.call(withArguments: [text])
                }
            } catch { queue.async { self.finish(.failure(error)) } }
        }
    }
    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        timers.values.forEach { $0.cancel() }; timers.removeAll()
        network?.cancel(); network = nil
        fetchResolution = nil; context?.exceptionHandler = nil; context = nil
        continuation?.resume(with: result); continuation = nil
    }
    private static let adapter = #"""
    class AbortController {
      constructor() {
        const listeners = new Set();
        this.signal = {aborted:false, reason:undefined,
          addEventListener:(_, fn)=>listeners.add(fn), removeEventListener:(_, fn)=>listeners.delete(fn)};
        this.abort = reason => { if (this.signal.aborted) return;
          this.signal.aborted=true; this.signal.reason=reason;
          for (const fn of listeners) fn(); listeners.clear(); };
      }
    }
    function connectCavi(baseURL, path, body, token, headers) {
      const client = new CaviAPI.BaseHttpApiClient('workbench.connection', {
        baseUrl:baseURL, auth:{bearerToken:token}, includePortalClientIdHeader:false,
        defaultTimeoutMs:120000, defaultHeaders:headers,
        fetchImpl:(url, init)=>new Promise((resolve,reject)=>nativeFetch(url,JSON.stringify(init),
          text=>resolve({ok:true,status:200,text:()=>Promise.resolve(text),headers:{get:()=> 'application/json'}}),reject))
      });
      client.createTransport()(path,{method:'POST',body,redirect:'error'})
        .then(value=>nativeComplete(JSON.stringify(value)),()=>nativeFail());
    }
    """#
}
