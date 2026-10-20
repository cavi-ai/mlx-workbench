import CoreFoundation
import Foundation

/// Read-only inventory adapters. Provider metadata remains optional when the server does not report it.
struct ModelHostClient: Sendable {
    private let http: HostHTTPClient
    private static let maximumModels = 512
    private static let maximumCategories = 32

    init(http: HostHTTPClient = HostHTTPClient()) { self.http = http }

    func inventory(host: ModelHost, token: String? = nil) async throws -> HostInventory {
        _ = try host.validatedURL()
        switch host.provider {
        case .ollama: return try await ollama(host, token: token)
        case .lmStudio: return try await lmStudio(host, token: token)
        case .comfyUI: return try await comfyUI(host, token: token)
        case .llamaCpp, .openAICompatible:
            return HostInventory(host: host, models: try await openAIModels(host, token: token), capturedAt: Date())
        }
    }

    private func ollama(_ host: ModelHost, token: String?) async throws -> HostInventory {
        let response = try await object(host, path: "api/tags", token: token)
        let tags = try Self.records(response["models"])
        var models = try tags.map { tag in
            let id = try Self.identifier(tag["name"] ?? tag["model"])
            let details = tag["details"] as? [String: Any] ?? [:]
            return HostedModel(
                hostID: host.id, modelID: id, name: id, digest: Self.text(tag["digest"]),
                family: Self.text(details["family"]), parameters: Self.text(details["parameter_size"]),
                quantization: Self.text(details["quantization_level"]), format: Self.text(details["format"]),
                sizeBytes: Self.integer(tag["size"])
            )
        }
        try Self.validateIDs(models)
        var warnings = ["Maximum context and capabilities are unavailable in this inventory."]
        do {
            let running = try Self.records(try await object(host, path: "api/ps", token: token)["models"])
            let names = try running.map { try Self.identifier($0["name"] ?? $0["model"]) }
            guard Set(names).count == names.count else { throw HostHTTPError.invalidResponse }
            for index in models.indices {
                let match = running.first { Self.text($0["name"] ?? $0["model"]) == models[index].modelID }
                if let match {
                    if let digest = models[index].digest, let runningDigest = Self.text(match["digest"]) {
                        models[index].isLoaded = digest == runningDigest
                        if digest == runningDigest {
                            models[index].memoryBytes = Self.integer(match["size_vram"])
                            models[index].contextLength = Self.int(match["context_length"])
                        }
                    }
                } else { models[index].isLoaded = false }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { warnings.append("Loaded-model metadata is unavailable; loaded state is unknown.") }
        var version: String?
        do {
            version = Self.text(try await object(host, path: "api/version", token: token)["version"])
            if version == nil { warnings.append("The host did not report its runtime version.") }
        } catch is CancellationError { throw CancellationError() }
        catch { warnings.append("The runtime version is unavailable.") }
        return HostInventory(host: host, models: models, capturedAt: Date(), runtimeVersion: version, warnings: warnings)
    }

    private func lmStudio(_ host: ModelHost, token: String?) async throws -> HostInventory {
        do {
            let response = try await object(host, path: "api/v1/models", token: token)
            let models = try Self.records(response["models"]).map { record in
                let id = try Self.identifier(record["key"])
                let instances = record["loaded_instances"] as? [[String: Any]]
                let contexts = instances?.compactMap { Self.int(($0["config"] as? [String: Any])?["context_length"]) }
                let context: Int? = if let contexts, let instances,
                                      !instances.isEmpty, contexts.count == instances.count, Set(contexts).count == 1 { contexts.first } else { nil }
                var capabilities: [String]?
                if let reported = record["capabilities"] as? [String: Any] {
                    capabilities = []
                    if Self.boolean(reported["vision"]) == true { capabilities?.append("vision") }
                    if Self.boolean(reported["trained_for_tool_use"]) == true { capabilities?.append("tools") }
                    if reported["reasoning"] as? [String: Any] != nil { capabilities?.append("reasoning") }
                }
                return HostedModel(
                    hostID: host.id, modelID: id, name: Self.text(record["display_name"]) ?? id,
                    family: Self.text(record["architecture"]), parameters: Self.text(record["params_string"]),
                    quantization: Self.text((record["quantization"] as? [String: Any])?["name"]),
                    format: Self.text(record["format"]), sizeBytes: Self.integer(record["size_bytes"]),
                    isLoaded: instances.map { !$0.isEmpty }, contextLength: context,
                    maximumContextLength: Self.int(record["max_context_length"]),
                    capabilities: capabilities, category: Self.text(record["type"])
                )
            }
            try Self.validateIDs(models)
            return HostInventory(host: host, models: models, capturedAt: Date())
        } catch HostHTTPError.httpStatus(404) {
            // Older native endpoints are used only when the newer endpoint is absent.
        }
        do {
            let response = try await object(host, path: "api/v0/models", token: token)
            let models = try Self.records(response["data"]).map { record in
                let id = try Self.identifier(record["id"])
                let state = Self.text(record["state"])
                return HostedModel(
                    hostID: host.id, modelID: id, name: id, family: Self.text(record["arch"]),
                    quantization: Self.text(record["quantization"]), format: Self.text(record["compatibility_type"]),
                    isLoaded: state == "loaded" ? true : (state == "not-loaded" ? false : nil),
                    contextLength: Self.int(record["loaded_context_length"]),
                    maximumContextLength: Self.int(record["max_context_length"]), category: Self.text(record["type"])
                )
            }
            try Self.validateIDs(models)
            return HostInventory(host: host, models: models, capturedAt: Date(), warnings: ["Using the legacy LM Studio inventory endpoint; some metadata is unavailable."])
        } catch HostHTTPError.httpStatus(404) {
            return HostInventory(
                host: host, models: try await openAIModels(host, token: token), capturedAt: Date(),
                warnings: ["LM Studio native inventory is unavailable; its OpenAI-compatible model list does not establish loaded state or capabilities."]
            )
        }
    }

    private func openAIModels(_ host: ModelHost, token: String?) async throws -> [HostedModel] {
        let response = try await object(host, path: "v1/models", token: token)
        let models = try Self.records(response["data"]).map { record in
            let id = try Self.identifier(record["id"])
            var model = HostedModel(hostID: host.id, modelID: id, name: id)
            if host.provider == .llamaCpp {
                let metadata = record["meta"] as? [String: Any] ?? [:]
                model.maximumContextLength = Self.int(metadata["n_ctx_train"])
                model.parameters = Self.integer(metadata["n_params"]).map(String.init)
                model.sizeBytes = Self.integer(metadata["size"])
                if let architecture = record["architecture"] as? [String: Any],
                   let inputs = architecture["input_modalities"] as? [String], inputs.count <= 32,
                   inputs.allSatisfy({ Self.text($0) != nil }) {
                    // The upstream default text output is compatibility metadata, not a generation guarantee.
                    model.capabilities = Array(Set(inputs.map { $0 + " input" })).sorted()
                    if let outputs = architecture["output_modalities"] as? [String], outputs.count <= 32 {
                        model.capabilities?.append(contentsOf: Set(outputs.filter { $0 != "text" && Self.text($0) != nil }.map { $0 + " output" }).sorted())
                    }
                }
            }
            return model
        }
        try Self.validateIDs(models)
        return models
    }

    private func comfyUI(_ host: ModelHost, token: String?) async throws -> HostInventory {
        let data = try await http.request(host: host, path: "models", token: token)
        guard let categories = try Self.json(data) as? [String], categories.count <= Self.maximumCategories,
              Set(categories).count == categories.count else { throw HostHTTPError.invalidResponse }
        var models: [HostedModel] = []
        var warnings: [String] = []
        for category in categories {
            guard !category.isEmpty, category.utf8.count <= 128,
                  category.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }) else {
                throw HostHTTPError.invalidResponse
            }
            do {
                let data = try await http.request(host: host, path: "models/" + category, token: token)
                guard let files = try Self.json(data) as? [String], files.count <= Self.maximumModels,
                      Set(files).count == files.count else { throw HostHTTPError.invalidResponse }
                let entries = try files.map { filename in
                    _ = try Self.identifier(filename)
                    return HostedModel(hostID: host.id, modelID: category + "/" + filename, name: filename, category: category)
                }
                guard models.count + entries.count <= Self.maximumModels else { throw HostHTTPError.responseTooLarge }
                models.append(contentsOf: entries)
            } catch is CancellationError { throw CancellationError() }
            catch HostHTTPError.responseTooLarge { throw HostHTTPError.responseTooLarge }
            catch { warnings.append("A ComfyUI model category could not be listed; this inventory is partial.") }
        }
        try Self.validateIDs(models)
        var version: String?
        var devices: String?
        do {
            let stats = try await object(host, path: "system_stats", token: token)
            version = Self.text((stats["system"] as? [String: Any])?["comfyui_version"])
            if let reported = stats["devices"] as? [[String: Any]], reported.count <= 32 {
                let names = reported.compactMap { device -> String? in
                    guard let name = Self.text(device["name"]) else { return nil }
                    return Self.text(device["type"]).map { name + " (" + $0 + ")" } ?? name
                }
                if !names.isEmpty { devices = names.joined(separator: ", ") }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { warnings.append("ComfyUI runtime and device metadata is unavailable.") }
        return HostInventory(host: host, models: models, capturedAt: Date(), runtimeVersion: version, deviceSummary: devices, warnings: warnings)
    }

    private func object(_ host: ModelHost, path: String, token: String?) async throws -> [String: Any] {
        let data = try await http.request(host: host, path: path, token: token)
        guard let object = try Self.json(data) as? [String: Any] else { throw HostHTTPError.invalidResponse }
        return object
    }

    private static func json(_ data: Data) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw HostHTTPError.invalidResponse }
    }

    private static func records(_ value: Any?) throws -> [[String: Any]] {
        guard let records = value as? [[String: Any]], records.count <= maximumModels else { throw HostHTTPError.invalidResponse }
        return records
    }

    private static func validateIDs(_ models: [HostedModel]) throws {
        guard models.count <= maximumModels, Set(models.map(\.modelID)).count == models.count else { throw HostHTTPError.invalidResponse }
    }

    private static func identifier(_ value: Any?) throws -> String {
        guard let value = text(value), value.utf8.count <= 2048 else { throw HostHTTPError.invalidResponse }
        return value
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= 4096, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value.rounded(.towardZero) == value, value < Double(Int64.max) else { return nil }
        return number.int64Value
    }

    private static func int(_ value: Any?) -> Int? { integer(value).flatMap(Int.init(exactly:)) }
}
