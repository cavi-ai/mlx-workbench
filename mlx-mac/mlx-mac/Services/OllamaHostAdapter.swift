import Foundation

/// Ollama: installed tags with digests, the running list, per-digest details and keep-alive unloading.
struct OllamaHostAdapter: ModelHostAdapter {
    let title = "Ollama"
    let defaultURL = "http://127.0.0.1:11434"
    var releaseScope: HostReleaseScope? { .model }
    var identifiesWeightsByDigest: Bool { true }

    func inventory(from reader: HostReader) async throws -> HostInventory {
        let host = reader.host
        let response = try await reader.object("api/tags")
        let tags = try HostReader.records(response["models"])
        var models = try tags.map { tag in
            let id = try HostReader.identifier(tag["name"] ?? tag["model"])
            let details = tag["details"] as? [String: Any] ?? [:]
            return HostedModel(
                hostID: host.id, modelID: id, name: id, digest: HostReader.text(tag["digest"]),
                family: HostReader.text(details["family"]), parameters: HostReader.text(details["parameter_size"]),
                quantization: HostReader.text(details["quantization_level"]), format: HostReader.text(details["format"]),
                sizeBytes: HostReader.integer(tag["size"])
            )
        }
        try HostReader.validateIDs(models)
        var warnings = ["Read model details for maximum context and capabilities; missing metadata remains unknown."]
        var runningModels: [HostedModel]?
        do {
            let running = try HostReader.records(try await reader.object("api/ps")["models"])
            let observed = try running.map { record in
                let id = try HostReader.identifier(record["name"] ?? record["model"])
                let details = record["details"] as? [String: Any] ?? [:]
                return HostedModel(hostID: host.id, modelID: id, name: id, digest: HostReader.text(record["digest"]),
                    family: HostReader.text(details["family"]), parameters: HostReader.text(details["parameter_size"]),
                    quantization: HostReader.text(details["quantization_level"]), format: HostReader.text(details["format"]),
                    isLoaded: true, contextLength: HostReader.int(record["context_length"]), memoryBytes: HostReader.integer(record["size_vram"]))
            }
            try HostReader.validateIDs(observed)
            runningModels = observed
            for index in models.indices {
                let match = observed.first { $0.modelID == models[index].modelID }
                if let match {
                    if let digest = models[index].digest, let runningDigest = match.digest {
                        models[index].isLoaded = digest == runningDigest
                        if digest == runningDigest {
                            models[index].memoryBytes = match.memoryBytes
                            models[index].contextLength = match.contextLength
                        }
                    }
                } else { models[index].isLoaded = false }
            }
            if observed.contains(where: { loaded in !models.contains(where: { $0.modelID == loaded.modelID }) }) {
                warnings.append("Some running models are absent from the installed tags. Review Reported running models; use Ollama to manage these weights.")
            }
            if observed.contains(where: { loaded in models.contains(where: { $0.modelID == loaded.modelID && $0.digest != nil && loaded.digest != nil && $0.digest != loaded.digest }) }) {
                warnings.append("Running weights differ from the installed tags for some model names. Their memory readings describe the running weights. Use Ollama to manage them before comparing or unloading these names.")
            }
        } catch is CancellationError { throw CancellationError() }
        catch { warnings.append("Loaded-model metadata is unavailable; loaded state is unknown.") }
        var version: String?
        do {
            version = HostReader.text(try await reader.object("api/version")["version"])
            if version == nil { warnings.append("The host did not report its runtime version.") }
        } catch is CancellationError { throw CancellationError() }
        catch { warnings.append("The runtime version is unavailable.") }
        return HostInventory(host: host, models: models, capturedAt: Date(), runtimeVersion: version, warnings: warnings, runningModels: runningModels)
    }

    func details(of model: HostedModel, from reader: HostReader) async throws -> HostModelDetails {
        let body = try JSONSerialization.data(withJSONObject: ["model": model.modelID, "verbose": false])
        guard let response = try HostReader.json(try await reader.data("api/show", method: "POST", body: body)) as? [String: Any] else {
            throw HostHTTPError.invalidResponse
        }
        var capabilities: [String]?
        if let value = response["capabilities"], !(value is NSNull) {
            guard let reported = value as? [String], reported.count <= 64,
                  reported.allSatisfy({ HostReader.text($0) != nil && $0.utf8.count <= 128 }),
                  Set(reported).count == reported.count else { throw HostHTTPError.invalidResponse }
            capabilities = reported
        }
        var maximumContext: Int?
        if let value = response["model_info"], !(value is NSNull) {
            guard let info = value as? [String: Any] else { throw HostHTTPError.invalidResponse }
            if let architecture = HostReader.text(info["general.architecture"]),
               let context = HostReader.int(info[architecture + ".context_length"]), context > 0 {
                maximumContext = context
            }
        }
        return HostModelDetails(capabilities: capabilities, maximumContextLength: maximumContext)
    }

    func validateRelease(of model: HostedModel, selection: HostResourceSelection) throws {
        guard HostResourceSelection.isValidID(model.digest) else { throw HostResourceError.unavailableSelection }
    }

    func releaseRequest(for preview: HostResourcePreview) throws -> HostReleaseRequest {
        guard let model = preview.model else { throw HostResourceError.unavailableSelection }
        return try HostReleaseRequest(path: "api/generate", payload: ["model": model.modelID, "keep_alive": 0, "stream": false])
    }

    func releaseReadback(_ preview: HostResourcePreview, inventory: HostInventory) -> String {
        guard let model = HostReleaseReadback.model(preview, in: inventory) else { return HostReleaseReadback.absent }
        guard let digest = preview.model?.digest, model.digest == digest else {
            return "The model identity changed; unloading the selected weights could not be verified."
        }
        return HostReleaseReadback.loadedState(model)
    }
}
