import Foundation

/// Explicit model-memory requests through each provider's adapter. The host remains responsible for its process and active work.
struct HostResourceClient: Sendable {
    private let http: HostHTTPClient

    init(http: HostHTTPClient = HostHTTPClient()) { self.http = http }

    func preview(host: ModelHost, selection: HostResourceSelection, token: String? = nil) async throws -> HostResourcePreview {
        _ = try host.validatedURL()
        let adapter = host.provider.adapter
        try Self.validateSelection(selection, scope: adapter.releaseScope)
        let client = ModelHostClient(http: http)
        if adapter.releaseScope == .host {
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
        let adapter = preview.host.provider.adapter
        try Self.validateSelection(preview.selection, scope: adapter.releaseScope)
        if adapter.releaseScope != .host {
            guard let model = preview.model else { throw HostResourceError.unavailableSelection }
            try Self.validateModel(model, host: preview.host, selection: preview.selection)
        }
        let request = try adapter.releaseRequest(for: preview)
        _ = try await http.request(host: preview.host, path: request.path, method: "POST", body: request.body, token: token, maximumBytes: 65_536)
    }

    private static func validateSelection(_ selection: HostResourceSelection, scope: HostReleaseScope?) throws {
        switch scope {
        case .model:
            guard HostResourceSelection.isValidID(selection.modelID), selection.instanceID == nil else { throw HostResourceError.invalidSelection }
        case .instance:
            guard HostResourceSelection.isValidID(selection.modelID), HostResourceSelection.isValidID(selection.instanceID) else {
                throw HostResourceError.invalidSelection
            }
        case .host:
            guard selection.modelID == nil, selection.instanceID == nil else { throw HostResourceError.invalidSelection }
        case nil:
            throw HostResourceError.unsupportedProvider
        }
    }

    private static func validateModel(_ model: HostedModel, host: ModelHost, selection: HostResourceSelection) throws {
        guard model.hostID == host.id, model.modelID == selection.modelID, model.isLoaded == true else {
            throw HostResourceError.unavailableSelection
        }
        try host.provider.adapter.validateRelease(of: model, selection: selection)
    }
}

extension HostResourceSelection {
    static func isValidID(_ value: String?) -> Bool {
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
