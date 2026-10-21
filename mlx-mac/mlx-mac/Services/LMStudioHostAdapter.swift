import Foundation

/// LM Studio: native inventory with loaded-instance identities, older endpoint fallbacks and per-instance unloading.
struct LMStudioHostAdapter: ModelHostAdapter {
    let title = "LM Studio"
    let defaultURL = "http://127.0.0.1:1234"
    var releaseScope: HostReleaseScope? { .instance }

    func inventory(from reader: HostReader) async throws -> HostInventory {
        let host = reader.host
        do {
            let response = try await reader.object("api/v1/models")
            var models = try HostReader.records(response["models"]).map { record in
                let id = try HostReader.identifier(record["key"])
                let instanceIDs = Self.loadedInstanceIDs(record["loaded_instances"])
                let instances = instanceIDs == nil ? nil : record["loaded_instances"] as? [[String: Any]]
                let contexts = instances?.compactMap { HostReader.int(($0["config"] as? [String: Any])?["context_length"]) }
                let context: Int? = if let contexts, let instances,
                                      !instances.isEmpty, contexts.count == instances.count, Set(contexts).count == 1 { contexts.first } else { nil }
                var capabilities: [String]?
                if let reported = record["capabilities"] as? [String: Any] {
                    capabilities = []
                    if HostReader.boolean(reported["vision"]) == true { capabilities?.append("vision") }
                    if HostReader.boolean(reported["trained_for_tool_use"]) == true { capabilities?.append("tools") }
                    if reported["reasoning"] as? [String: Any] != nil { capabilities?.append("reasoning") }
                }
                return HostedModel(
                    hostID: host.id, modelID: id, name: HostReader.text(record["display_name"]) ?? id,
                    family: HostReader.text(record["architecture"]), parameters: HostReader.text(record["params_string"]),
                    quantization: HostReader.text((record["quantization"] as? [String: Any])?["name"]),
                    format: HostReader.text(record["format"]), sizeBytes: HostReader.integer(record["size_bytes"]),
                    isLoaded: instances.map { !$0.isEmpty }, contextLength: context,
                    maximumContextLength: HostReader.int(record["max_context_length"]),
                    capabilities: capabilities, category: HostReader.text(record["type"]), loadedInstanceIDs: instanceIDs
                )
            }
            try HostReader.validateIDs(models)
            let occurrences = Dictionary((models.flatMap { $0.loadedInstanceIDs ?? [] }).map { ($0, 1) }, uniquingKeysWith: +)
            for index in models.indices where models[index].loadedInstanceIDs?.contains(where: { occurrences[$0, default: 0] > 1 }) == true {
                models[index].loadedInstanceIDs = nil
                models[index].isLoaded = nil
                models[index].contextLength = nil
            }
            let warnings = models.contains(where: { $0.loadedInstanceIDs == nil })
                ? ["Some loaded-instance identities are unavailable. Refresh the host before selecting an instance for memory release."] : []
            return HostInventory(host: host, models: models, capturedAt: Date(), warnings: warnings)
        } catch HostHTTPError.httpStatus(404) {
            // Older native endpoints are used only when the newer endpoint is absent.
        }
        do {
            let response = try await reader.object("api/v0/models")
            let models = try HostReader.records(response["data"]).map { record in
                let id = try HostReader.identifier(record["id"])
                let state = HostReader.text(record["state"])
                return HostedModel(
                    hostID: host.id, modelID: id, name: id, family: HostReader.text(record["arch"]),
                    quantization: HostReader.text(record["quantization"]), format: HostReader.text(record["compatibility_type"]),
                    isLoaded: state == "loaded" ? true : (state == "not-loaded" ? false : nil),
                    contextLength: HostReader.int(record["loaded_context_length"]),
                    maximumContextLength: HostReader.int(record["max_context_length"]), category: HostReader.text(record["type"])
                )
            }
            try HostReader.validateIDs(models)
            return HostInventory(host: host, models: models, capturedAt: Date(), warnings: ["Using the legacy LM Studio inventory endpoint; some metadata is unavailable."])
        } catch HostHTTPError.httpStatus(404) {
            return HostInventory(
                host: host, models: try await OpenAIHostAdapter.models(from: reader, readsLlamaMetadata: false), capturedAt: Date(),
                warnings: ["LM Studio native inventory is unavailable; its OpenAI-compatible model list does not establish loaded state or capabilities."]
            )
        }
    }

    func validateRelease(of model: HostedModel, selection: HostResourceSelection) throws {
        guard let instanceID = selection.instanceID, let instances = model.loadedInstanceIDs,
              !instances.isEmpty, instances.count <= 512,
              instances.allSatisfy({ HostResourceSelection.isValidID($0) }), Set(instances).count == instances.count,
              instances.contains(instanceID) else { throw HostResourceError.unavailableSelection }
    }

    func releaseRequest(for preview: HostResourcePreview) throws -> HostReleaseRequest {
        guard preview.model != nil, let instanceID = preview.selection.instanceID else { throw HostResourceError.unavailableSelection }
        return try HostReleaseRequest(path: "api/v1/models/unload", payload: ["instance_id": instanceID])
    }

    func releaseReadback(_ preview: HostResourcePreview, inventory: HostInventory) -> String {
        guard let model = HostReleaseReadback.model(preview, in: inventory) else { return HostReleaseReadback.absent }
        guard let instances = model.loadedInstanceIDs, let instance = preview.selection.instanceID else {
            return "Loaded-instance state is unavailable; memory release could not be verified."
        }
        return instances.contains(instance) ? "The selected instance is still reported loaded." : "The selected instance is no longer loaded."
    }

    private static func loadedInstanceIDs(_ value: Any?) -> [String]? {
        guard let instances = value as? [[String: Any]], instances.count <= HostReader.maximumModels else { return nil }
        let identifiers = instances.compactMap { try? HostReader.identifier($0["id"]) }
        guard identifiers.count == instances.count, Set(identifiers).count == identifiers.count else { return nil }
        return identifiers
    }
}
