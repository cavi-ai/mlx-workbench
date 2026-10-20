import Foundation

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
        do {
            // A task delegate also fences sessions injected by a caller or test.
            let (bytes, response) = try await urlSession.bytes(for: request, delegate: HostRedirectFence.shared)
            guard let response = response as? HTTPURLResponse else { throw HostHTTPError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw HostHTTPError.httpStatus(response.statusCode) }
            guard response.expectedContentLength <= Int64(maximumBytes) else { throw HostHTTPError.responseTooLarge }
            var result = Data()
            for try await byte in bytes {
                guard result.count < maximumBytes else { throw HostHTTPError.responseTooLarge }
                result.append(byte)
            }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as HostHTTPError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw HostHTTPError.requestFailed }
    }
}

private final class HostRedirectFence: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = HostRedirectFence()
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
