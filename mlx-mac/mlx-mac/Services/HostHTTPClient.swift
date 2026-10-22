import Foundation
import os

enum HostHTTPError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL, invalidPath, invalidResponse, responseTooLarge, requestFailed
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter an HTTP or HTTPS loopback URL without credentials, query or fragment."
        case .invalidPath: return "The host API path is invalid."
        case .invalidResponse: return "The host returned an invalid response."
        case .responseTooLarge: return "The host response exceeds the size limit."
        case .requestFailed: return "The local host could not be reached. Check its address and server settings."
        case .httpStatus(let status): return "The host returned HTTP \(status)."
        }
    }
}

/// Shared transport for host APIs. Response bodies and credentials never become error messages.
struct HostHTTPClient: Sendable {
    private let urlSession: URLSession
    static let sharedSession = session()

    init() { urlSession = Self.sharedSession }
    init(session: URLSession) { urlSession = session }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: HostRedirectFence.shared, delegateQueue: nil)
    }

    func request(
        host: ModelHost, path: String, method: String = "GET", body: Data? = nil,
        query: [URLQueryItem] = [], token: String? = nil, maximumBytes: Int = 8_388_608
    ) async throws -> Data {
        let baseURL = try host.validatedURL()
        guard maximumBytes > 0, !path.hasPrefix("//"), !path.contains(":"),
              !path.contains("?"), !path.contains("#"),
              !path.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              ["GET", "POST", "DELETE"].contains(method),
              token?.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) != true else {
            throw HostHTTPError.invalidPath
        }
        try ModelHost.validatePath(path)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = baseURL.path + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw HostHTTPError.invalidPath }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token, !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let receiver = HostResponseReceiver(maximumBytes: maximumBytes)
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { receiver.start(request, session: urlSession, continuation: $0) }
            } onCancel: { receiver.cancel() }
        } catch is CancellationError { throw CancellationError() }
        catch let error as HostHTTPError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw HostHTTPError.requestFailed }
    }
}

/// One bounded response and its continuation. Rejecting a body cancels only its task.
private final class HostResponseReceiver: NSObject, URLSessionDataDelegate, Sendable {
    private struct State: Sendable {
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<Data, Error>?
        var body = Data()
        var accepted = false
        var finished = false
    }
    private let maximumBytes: Int
    private let state = OSAllocatedUnfairLock(initialState: State())
    private struct Completion {
        let continuation: CheckedContinuation<Data, Error>?
        let task: URLSessionDataTask?
        let result: Result<Data, Error>
        let cancelTask: Bool
        func resume() {
            if cancelTask { task?.cancel() }
            continuation?.resume(with: result)
        }
    }

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func start(_ request: URLRequest, session: URLSession, continuation: CheckedContinuation<Data, Error>) {
        let task = session.dataTask(with: request)
        task.delegate = self
        let launch = state.withLock { state in
            guard !state.finished else { return false }
            state.task = task
            state.continuation = continuation
            return true
        }
        if launch { task.resume() }
        else { task.cancel(); continuation.resume(throwing: CancellationError()) }
    }

    func cancel() { finish(.failure(CancellationError()), cancelTask: true) }

    private func finish(_ result: Result<Data, Error>, cancelTask: Bool = false) {
        state.withLock { Self.complete(&$0, result: result, cancelTask: cancelTask) }?.resume()
    }

    private static func complete(_ state: inout State, result: Result<Data, Error>, cancelTask: Bool = false) -> Completion? {
        guard !state.finished else { return nil }
        state.finished = true
        let completion = Completion(continuation: state.continuation, task: state.task, result: result, cancelTask: cancelTask)
        state.continuation = nil
        state.task = nil
        state.body = Data()
        return completion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let error: HostHTTPError?
        if let response = response as? HTTPURLResponse {
            if !(200..<300).contains(response.statusCode) { error = .httpStatus(response.statusCode) }
            else if response.expectedContentLength > Int64(maximumBytes) { error = .responseTooLarge }
            else { error = nil }
        } else { error = .invalidResponse }
        if let error {
            finish(.failure(error), cancelTask: true)
            completionHandler(.cancel)
        } else {
            let accept = state.withLock { state in
                guard !state.finished else { return false }
                state.accepted = true
                return true
            }
            completionHandler(accept ? .allow : .cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let completion = state.withLock { state -> Completion? in
            guard !state.finished else { return nil }
            guard data.count <= maximumBytes - state.body.count else {
                return Self.complete(&state, result: .failure(HostHTTPError.responseTooLarge), cancelTask: true)
            }
            state.body.append(data)
            return nil
        }
        completion?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else {
            let completion = state.withLock { state in
                let result: Result<Data, Error> = state.accepted ? .success(state.body) : .failure(HostHTTPError.invalidResponse)
                return Self.complete(&state, result: result)
            }
            completion?.resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class HostRedirectFence: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = HostRedirectFence()
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
