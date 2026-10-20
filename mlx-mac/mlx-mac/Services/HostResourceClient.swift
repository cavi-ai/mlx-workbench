import Foundation

/// Explicit model-memory requests. The host remains responsible for its process and active work.
struct HostResourceClient: Sendable {
    private let http: HostHTTPClient

    init(http: HostHTTPClient = HostHTTPClient()) { self.http = http }

    func preview(host: ModelHost, selection: HostResourceSelection, token: String? = nil) async throws -> HostResourcePreview {
        _ = try host.validatedURL()
        try Self.validateSelection(selection, provider: host.provider)
        let client = ModelHostClient(http: http)
        if host.provider == .comfyUI {
            return HostResourcePreview(host: host, selection: selection, model: nil,
                activity: try await client.activity(host: host, token: token))
        }
        let inventory = try await client.inventory(host: host, token: token)
        guard let model = inventory.models.first(where: { $0.modelID == selection.modelID }) else {
            throw HostResourceError.unavailableSelection
        }
        try Self.validateModel(model, host: host, selection: selection)
        guard let activity = inventory.activity else { throw HostResourceError.unavailableSelection }
        return HostResourcePreview(host: host, selection: selection, model: model, activity: activity)
    }

    /// A successful response means the API accepted the request; inventory readback establishes its effect.
    func release(preview: HostResourcePreview, token: String? = nil) async throws {
        try Task.checkCancellation()
        _ = try preview.host.validatedURL()
        try Self.validateSelection(preview.selection, provider: preview.host.provider)
        let path: String
        let payload: [String: Any]
        switch preview.host.provider {
        case .ollama:
            guard let model = preview.model else { throw HostResourceError.unavailableSelection }
            try Self.validateModel(model, host: preview.host, selection: preview.selection)
            path = "api/generate"
            payload = ["model": model.modelID, "keep_alive": 0, "stream": false]
        case .lmStudio:
            guard let model = preview.model, let instanceID = preview.selection.instanceID else {
                throw HostResourceError.unavailableSelection
            }
            try Self.validateModel(model, host: preview.host, selection: preview.selection)
            path = "api/v1/models/unload"
            payload = ["instance_id": instanceID]
        case .comfyUI:
            guard preview.model == nil else { throw HostResourceError.invalidSelection }
            path = "free"
            payload = ["unload_models": true, "free_memory": true]
        case .llamaCpp, .openAICompatible:
            throw HostResourceError.unsupportedProvider
        }
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        _ = try await http.request(host: preview.host, path: path, method: "POST", body: body, token: token, maximumBytes: 65_536)
    }

    private static func validateSelection(_ selection: HostResourceSelection, provider: ModelHostProvider) throws {
        switch provider {
        case .ollama:
            guard validID(selection.modelID), selection.instanceID == nil else { throw HostResourceError.invalidSelection }
        case .lmStudio:
            guard validID(selection.modelID), validID(selection.instanceID) else { throw HostResourceError.invalidSelection }
        case .comfyUI:
            guard selection.modelID == nil, selection.instanceID == nil else { throw HostResourceError.invalidSelection }
        case .llamaCpp, .openAICompatible:
            throw HostResourceError.unsupportedProvider
        }
    }

    private static func validateModel(_ model: HostedModel, host: ModelHost, selection: HostResourceSelection) throws {
        guard model.hostID == host.id, model.modelID == selection.modelID, model.isLoaded == true else {
            throw HostResourceError.unavailableSelection
        }
        if host.provider == .ollama {
            guard validID(model.digest) else { throw HostResourceError.unavailableSelection }
        } else if host.provider == .lmStudio {
            guard let instanceID = selection.instanceID, let instances = model.loadedInstanceIDs,
                  !instances.isEmpty, instances.count <= 512,
                  instances.allSatisfy({ validID($0) }), Set(instances).count == instances.count,
                  instances.contains(instanceID) else { throw HostResourceError.unavailableSelection }
        }
    }

    private static func validID(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 2048
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

enum HostResourceError: LocalizedError {
    case invalidSelection, unavailableSelection, unsupportedProvider

    var errorDescription: String? {
        switch self {
        case .invalidSelection: return "Choose the loaded model or instance to release. ComfyUI memory release applies to the whole host."
        case .unavailableSelection: return "The selected loaded model or instance is unavailable. Refresh the host and choose it again."
        case .unsupportedProvider: return "This host does not provide a supported model-memory release API."
        }
    }
}
