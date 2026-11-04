import Foundation

/// TypeSafe System One decision servers, such as Kev's `kev.serve`: `/v1/models` lists the
/// served decision models and `/v1/systemone` answers typed questions about a state.
struct SystemOneHostAdapter: ModelHostAdapter {
    let title = "System One"
    let defaultURL = "http://127.0.0.1:8008"
    static let category = "decision"
    /// A decision request scores every option in one pass; larger models can take longer than the inventory timeout.
    static let decisionTimeout: TimeInterval = 120

    func inventory(from reader: HostReader) async throws -> HostInventory {
        let response = try await reader.object("v1/models")
        let models = try HostReader.records(response["models"] ?? response["data"]).map { record in
            let id = try HostReader.identifier(record["id"])
            var model = HostedModel(hostID: reader.host.id, modelID: id, name: id)
            model.family = HostReader.text(record["base"])
            model.category = Self.category
            model.capabilities = ["decisions output"]
            return model
        }
        try HostReader.validateIDs(models)
        return HostInventory(host: reader.host, models: models, capturedAt: Date())
    }

    /// One System One request for `model`; answers are returned as reported.
    static func decide(_ reader: HostReader, model: String, state: String, questions: [DecisionQuestion]) async throws -> DecisionResult {
        let body = try DecisionRequest.body(state: state, questions: questions, model: model)
        let data = try await reader.http.request(host: reader.host, path: "v1/systemone", method: "POST", body: body,
                                                 token: reader.token, timeout: decisionTimeout)
        do { return try JSONDecoder().decode(DecisionResult.self, from: data) }
        catch { throw HostHTTPError.invalidResponse }
    }
}
