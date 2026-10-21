import Foundation

/// OpenAI-compatible model lists; llama.cpp adds its reported training context, size and modalities.
struct OpenAIHostAdapter: ModelHostAdapter {
    let title: String
    let defaultURL = "http://127.0.0.1:8080"
    let readsLlamaMetadata: Bool

    func inventory(from reader: HostReader) async throws -> HostInventory {
        HostInventory(host: reader.host, models: try await Self.models(from: reader, readsLlamaMetadata: readsLlamaMetadata), capturedAt: Date())
    }

    static func models(from reader: HostReader, readsLlamaMetadata: Bool) async throws -> [HostedModel] {
        let response = try await reader.object("v1/models")
        let models = try HostReader.records(response["data"]).map { record in
            let id = try HostReader.identifier(record["id"])
            var model = HostedModel(hostID: reader.host.id, modelID: id, name: id)
            if readsLlamaMetadata {
                let metadata = record["meta"] as? [String: Any] ?? [:]
                model.maximumContextLength = HostReader.int(metadata["n_ctx_train"])
                model.parameters = HostReader.integer(metadata["n_params"]).map(String.init)
                model.sizeBytes = HostReader.integer(metadata["size"])
                if let architecture = record["architecture"] as? [String: Any],
                   let inputs = architecture["input_modalities"] as? [String], inputs.count <= 32,
                   inputs.allSatisfy({ HostReader.text($0) != nil }) {
                    // The upstream default text output is compatibility metadata, not a generation guarantee.
                    model.capabilities = Array(Set(inputs.map { $0 + " input" })).sorted()
                    if let outputs = architecture["output_modalities"] as? [String], outputs.count <= 32 {
                        model.capabilities?.append(contentsOf: Set(outputs.filter { $0 != "text" && HostReader.text($0) != nil }.map { $0 + " output" }).sorted())
                    }
                }
            }
            return model
        }
        try HostReader.validateIDs(models)
        return models
    }
}
