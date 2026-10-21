import Foundation

/// Read-only inventory through each provider's adapter. Provider metadata remains optional when the server does not report it.
struct ModelHostClient: Sendable {
    private let http: HostHTTPClient

    init(http: HostHTTPClient = HostHTTPClient()) { self.http = http }

    func inventoryInspecting(_ model: HostedModel, host: ModelHost, token: String? = nil) async throws -> HostInventory {
        guard host.provider.adapter.identifiesWeightsByDigest, model.hostID == host.id,
              let digest = HostReader.text(model.digest) else {
            throw HostedIntegrationError.invalid("Select an installed Ollama model with a reported digest before reading details.")
        }
        _ = try HostReader.identifier(model.modelID)
        let before = try await inventory(host: host, token: token)
        guard before.models.contains(where: { $0.modelID == model.modelID && $0.digest == digest }) else {
            throw HostedIntegrationError.invalid("The installed model changed. Refresh and select it again before reading details.")
        }
        try Task.checkCancellation()
        let details = try await host.provider.adapter.details(of: model, from: reader(host, token: token))
        let capturedAt = Date()
        try Task.checkCancellation()
        let after = try await inventory(host: host, token: token)
        guard let index = after.models.firstIndex(where: { $0.modelID == model.modelID && $0.digest == digest }) else {
            throw HostedIntegrationError.invalid("The installed model changed while reading details. Refresh and select it again.")
        }
        try Task.checkCancellation()
        var models = after.models
        models[index].maximumContextLength = details.maximumContextLength
        models[index].capabilities = details.capabilities
        models[index].detailsCapturedAt = capturedAt
        return HostInventory(host: after.host, models: models, capturedAt: after.capturedAt,
            runtimeVersion: after.runtimeVersion, deviceSummary: after.deviceSummary, warnings: after.warnings,
            activity: after.activity, runningModels: after.runningModels)
    }

    func inventory(host: ModelHost, token: String? = nil) async throws -> HostInventory {
        _ = try host.validatedURL()
        var result = try await host.provider.adapter.inventory(from: reader(host, token: token))
        result.activity = try await activity(host: host, token: token)
        return result
    }

    func activity(host: ModelHost, token: String? = nil) async throws -> HostActivity {
        try Task.checkCancellation()
        _ = try host.validatedURL()
        return try await host.provider.adapter.activity(from: reader(host, token: token))
    }

    private func reader(_ host: ModelHost, token: String?) -> HostReader {
        HostReader(host: host, token: token, http: http)
    }
}
