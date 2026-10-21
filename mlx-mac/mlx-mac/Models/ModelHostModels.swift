import Foundation

/// Provider behavior lives in its `adapter` (`Services/ModelHostAdapter.swift`).
enum ModelHostProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case ollama, lmStudio, comfyUI, llamaCpp, openAICompatible

    var id: String { rawValue }
}

struct ModelHost: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var provider: ModelHostProvider
    var baseURL: String

    var validationMessage: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else {
            return "Enter a host name of 1–120 characters."
        }
        do { _ = try validatedURL(); return nil }
        catch { return error.localizedDescription }
    }

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
    var loadedInstanceIDs: [String]? = nil
    var detailsCapturedAt: Date? = nil
    var id: String { hostID.uuidString + "/" + modelID }
}

struct HostInventory: Codable, Equatable, Sendable {
    let host: ModelHost
    let models: [HostedModel]
    let capturedAt: Date
    var runtimeVersion: String? = nil
    var deviceSummary: String? = nil
    var warnings: [String] = []
    var activity: HostActivity? = nil
    /// Ollama's complete running list, independent of the available tags. Nil means unavailable.
    var runningModels: [HostedModel]? = nil
    var deviceMemory: HostDeviceMemorySnapshot? = nil

    var reportedLoadedModels: [HostedModel] {
        (runningModels ?? models.filter { $0.isLoaded == true })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var loadedStateSummary: String {
        if let runningModels {
            let count = runningModels.count
            return "\(count) \(count == 1 ? "model" : "models") reported loaded"
        }
        let unknown = models.filter { $0.isLoaded == nil }.count
        guard !models.isEmpty, unknown != models.count else { return "Loaded state unknown" }
        let loaded = reportedLoadedModels.count
        let summary = "\(loaded) \(loaded == 1 ? "model" : "models") reported loaded"
        return unknown > 0 ? summary + " · \(unknown) unknown" : summary
    }
}

/// Independent host observations; devices may share the same underlying memory.
struct HostDeviceMemorySnapshot: Codable, Equatable, Sendable {
    let capturedAt: Date
    let devices: [HostDeviceMemory]
}

struct HostDeviceMemory: Codable, Equatable, Sendable {
    let name: String?
    let type: String?
    let index: Int?
    let totalBytes: Int64?
    let freeBytes: Int64?

    var reportsSystemMemory: Bool { type == "mps" || type == "cpu" }
}

enum HostActivityState: String, Codable, Sendable {
    case idle, busy, queued, unknown
    var title: String {
        switch self {
        case .idle: "Idle"
        case .busy: "Busy"
        case .queued: "Queued"
        case .unknown: "Activity unknown"
        }
    }
}

struct HostActivity: Codable, Equatable, Sendable {
    let state: HostActivityState
    var checkedAt: Date = Date()
    var runningCount: Int? = nil
    var pendingCount: Int? = nil
    let detail: String
    func matches(_ other: HostActivity) -> Bool {
        state == other.state && runningCount == other.runningCount && pendingCount == other.pendingCount && detail == other.detail
    }
}

struct HostResourceSelection: Equatable, Sendable {
    var modelID: String? = nil
    var instanceID: String? = nil
}

struct HostResourcePreview: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    let host: ModelHost
    let selection: HostResourceSelection
    let model: HostedModel?
    let activity: HostActivity
    var actionTitle: String {
        switch host.provider.adapter.releaseScope {
        case .host: "Free host memory"
        case .instance: "Unload instance"
        case .model, nil: "Unload model"
        }
    }
    var scope: String {
        switch host.provider.adapter.releaseScope {
        case .host: "All cached models on \(host.name). This can affect other workflows using the host. Running and queued jobs are not stopped."
        case .instance: "Instance \(selection.instanceID ?? "Unknown") of \(model?.name ?? "Unknown") on \(host.name)."
        case .model, nil: "\(model?.name ?? "Unknown") on \(host.name)."
        }
    }
    var warning: String {
        switch activity.state {
        case .unknown: "Other clients may be using this host. Unloading can interrupt their requests."
        case .busy, .queued: "This host has running or queued work. Memory cleanup may be deferred and models may need to load again."
        case .idle: "No queued or running work was reported at the check time. Another client can start work after this check."
        }
    }
    func matches(_ other: HostResourcePreview) -> Bool {
        host == other.host && selection == other.selection
            && model?.modelID == other.model?.modelID && model?.name == other.model?.name
            && model?.digest == other.model?.digest && model?.isLoaded == other.model?.isLoaded
            && model?.contextLength == other.model?.contextLength && model?.quantization == other.model?.quantization
            && activity.matches(other.activity)
    }
}
