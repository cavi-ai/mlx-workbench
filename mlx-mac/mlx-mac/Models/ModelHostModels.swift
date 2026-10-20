import Foundation

enum ModelHostProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case ollama, lmStudio, comfyUI, llamaCpp, openAICompatible

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .comfyUI: return "ComfyUI"
        case .llamaCpp: return "llama.cpp"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }
    var defaultURL: String {
        switch self {
        case .ollama: return "http://127.0.0.1:11434"
        case .lmStudio: return "http://127.0.0.1:1234"
        case .comfyUI: return "http://127.0.0.1:8188"
        case .llamaCpp, .openAICompatible: return "http://127.0.0.1:8080"
        }
    }
}

struct ModelHost: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var provider: ModelHostProvider
    var baseURL: String

    /// Connections are explicit local HTTP endpoints. A pasted OpenAI base URL may end in /v1.
    func validatedURL() throws -> URL {
        guard !baseURL.isEmpty, baseURL.utf8.count <= 2048,
              !baseURL.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              var components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let hostname = components.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(hostname),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let authority = baseURL.components(separatedBy: "://").dropFirst().first?.split(separator: "/", omittingEmptySubsequences: false).first,
              !authority.hasSuffix(":") else {
            throw HostHTTPError.invalidURL
        }
        try Self.validatePath(components.percentEncodedPath)
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/v1") { path.removeLast(3) }
        components.scheme = scheme
        components.path = path
        guard let url = components.url else { throw HostHTTPError.invalidURL }
        return url
    }

    static func validatePath(_ path: String) throws {
        var decoded = path
        for _ in 0..<4 {
            guard let next = decoded.removingPercentEncoding else { throw HostHTTPError.invalidPath }
            if next == decoded { break }
            decoded = next
        }
        guard !decoded.contains("%"), !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else {
            throw HostHTTPError.invalidPath
        }
    }
}

struct HostedModel: Codable, Equatable, Identifiable, Sendable {
    let hostID: UUID
    let modelID: String
    var name: String
    var digest: String? = nil
    var family: String? = nil
    var parameters: String? = nil
    var quantization: String? = nil
    var format: String? = nil
    var sizeBytes: Int64? = nil
    var isLoaded: Bool? = nil
    var contextLength: Int? = nil
    var maximumContextLength: Int? = nil
    var memoryBytes: Int64? = nil
    var capabilities: [String]? = nil
    var category: String? = nil
    var id: String { hostID.uuidString + "/" + modelID }
}

struct HostInventory: Codable, Equatable, Sendable {
    let host: ModelHost
    let models: [HostedModel]
    let capturedAt: Date
    var runtimeVersion: String? = nil
    var deviceSummary: String? = nil
    var warnings: [String] = []
}
