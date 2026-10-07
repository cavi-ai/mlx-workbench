import Foundation

enum WorkflowHarness: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude, openClaw = "openclaw", openCode = "opencode", custom
    var id: String { rawValue }
    var title: String {
        switch self { case .claude: return "Claude"; case .openClaw: return "OpenClaw"; case .openCode: return "OpenCode"; case .custom: return "Custom" }
    }
}

struct WorkflowCaptureModel: Codable, Equatable, Sendable, Identifiable {
    let path: String
    let name: String
    let signature: String?
    var id: String { path }
}

/// Wiring context is an instruction for a future run, never measured evidence.
struct WorkflowCaptureEndpoint: Encodable {
    let baseURL: String
    let modelIdentity: String
    let clientIDs: [String]
    let wiringTransactionID: UUID
    let wiredAt: Date

    func validate(model: WorkflowCaptureModel) throws {
        guard let url = URLComponents(string: baseURL), url.scheme == "http", url.host == "127.0.0.1",
              let port = url.port, (1...65535).contains(port), url.path == "/v1",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              HFRepoID.matches(modelIdentity, model.path), !clientIDs.isEmpty else {
            throw WorkflowEvidenceError.invalid("Capture endpoint must match the local model and a loopback server with successful client wiring.")
        }
    }
}

struct WiredWorkflowCapture: Identifiable {
    let model: WorkflowCaptureModel
    let harness: WorkflowHarness
    let endpoint: WorkflowCaptureEndpoint
    var id: UUID { endpoint.wiringTransactionID }

    static func make(reviewedServer: ServerInfo, currentServers: [ServerInfo], transaction: WiringTransaction,
                     models: [WorkflowCaptureModel]) throws -> Self {
        let current = currentServers.filter { $0.port == reviewedServer.port && $0.state?.lowercased() == "running" }
        guard current.count == 1, ClientWiringSelection.sameServer(reviewedServer, current[0]),
              let endpoint = WireEndpoint(server: current[0]), transaction.rolledBackAt == nil,
              transaction.endpointBaseURL == endpoint.baseURL, transaction.modelName == endpoint.modelName,
              !transaction.receipts.isEmpty else {
            throw WorkflowEvidenceError.invalid("Wired server stopped or changed, or its client wiring is unavailable. Wire the current endpoint before measuring.")
        }
        let matching = models.filter { HFRepoID.matches($0.path, endpoint.modelName) }
        guard matching.count == 1 else {
            throw WorkflowEvidenceError.invalid("The wired model must match exactly one ready local model. Rescan Library; ambiguous repository revisions need a local-path server.")
        }
        let clients = Array(Set(transaction.receipts.map(\.clientID))).sorted()
        let context = WorkflowCaptureEndpoint(baseURL: endpoint.baseURL, modelIdentity: endpoint.modelName,
            clientIDs: clients, wiringTransactionID: transaction.id, wiredAt: transaction.appliedAt)
        try context.validate(model: matching[0])
        return Self(model: matching[0], harness: clients.contains("opencode") ? .openCode : .custom, endpoint: context)
    }
}

/// A request for a producer, never evidence of a run. Required measurements
/// are explicitly null so an unfilled draft cannot be imported as observations.
struct WorkflowCaptureRequest: Encodable {
    let schemaVersion = 1
    let contextCapturedAt: Date
    let model: WorkflowCaptureModel
    let environmentFingerprint: String?
    let endpoint: WorkflowCaptureEndpoint?
    let reportDraft: Draft
    let instructions: String
    let reportContract = WorkflowReport.template.guidance

    static func make(harness: WorkflowHarness, model: WorkflowCaptureModel, environment: String?, now: Date = Date(), endpoint: WorkflowCaptureEndpoint? = nil) throws -> Self {
        guard model.path.hasPrefix("/") else { throw WorkflowEvidenceError.invalid("capture requires an absolute local model path") }
        try endpoint?.validate(model: model)
        let signature = model.signature.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let fingerprint = ComparisonInsights.knownEnvironment(environment) ? environment : nil
        let contextModel = WorkflowCaptureModel(path: model.path, name: model.name, signature: signature)
        return Self(contextCapturedAt: now, model: contextModel, environmentFingerprint: fingerprint, endpoint: endpoint,
            reportDraft: Draft(record: DraftRecord(id: UUID(), harness: harness.rawValue, modelPath: model.path, modelSignature: signature, environmentFingerprint: fingerprint)),
            instructions: "Produce a schema-1 local workflow report for \(harness.title). This request captures identity context only, not a measurement. Verify that the workflow actually uses this exact local model and environment; a client name alone does not identify the serving model. Endpoint context, when present, records successful config writes only: verify the actual workflow used that endpoint and served model; wiredAt is not measuredAt and wiringTransactionID is not a run receipt. Unknown identity fields are null: establish them from the actual run, never invent a match. Never reuse this context for an older run or replace a recorded fingerprint. Fill reportDraft from measured local receipts/session evidence, retain the actual measuredAt, and save only the reportDraft object as JSON for Import workflow report. If the model, environment, receipt or required timings cannot be established, report missing evidence instead of inventing values. Use a stable workloadID and configurationFingerprint for the same prompts, tools, context and generation settings. Timing components must be additive, disjoint seconds; omit any unknown component. Do not infer GPU, disk or network time from unattributed time. Task quality requires an explicit human review and shared rubricID; no automatic quality score. Include only source identifiers, timings, scores and byte counts; omit prompts, transcripts, credentials and secrets.")
    }

    struct Draft: Encodable {
        let schemaVersion = 1
        let records: [DraftRecord]
        init(record: DraftRecord) { records = [record] }
    }

    struct DraftRecord: Encodable {
        let id: UUID
        let harness: String
        let modelPath: String
        let modelSignature: String?
        let environmentFingerprint: String?
        enum CodingKeys: String, CodingKey { case id, harness, modelPath, modelSignature, environmentFingerprint, workloadID, measuredAt, sampleCount, totalSeconds, source, configurationFingerprint }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(harness, forKey: .harness)
            try values.encode(modelPath, forKey: .modelPath)
            try values.encode(modelSignature, forKey: .modelSignature)
            try values.encode(environmentFingerprint, forKey: .environmentFingerprint)
            for key: CodingKeys in [.workloadID, .measuredAt, .sampleCount, .totalSeconds, .source, .configurationFingerprint] { try values.encodeNil(forKey: key) }
        }
    }
}

enum WorkflowImportIdentity: String {
    case matching, missingModel, changedModel, unknownModel, changedEnvironment, unknownEnvironment
    var label: String {
        switch self {
        case .matching: return "Matching model and environment"
        case .missingModel: return "Model unavailable · historical evidence"
        case .changedModel: return "Model signature changed · historical evidence"
        case .unknownModel: return "Model signature unavailable · identity unconfirmed"
        case .changedEnvironment: return "Environment changed · historical evidence"
        case .unknownEnvironment: return "Environment unavailable · identity unconfirmed"
        }
    }
    static func status(_ record: WorkflowEvidence, models: [WorkflowCaptureModel], environment: String?) -> Self {
        guard let model = models.first(where: { $0.path == record.modelPath }) else { return .missingModel }
        guard let signature = model.signature, !signature.isEmpty else { return .unknownModel }
        guard signature == record.modelSignature else { return .changedModel }
        guard ComparisonInsights.knownEnvironment(environment), ComparisonInsights.knownEnvironment(record.environmentFingerprint) else { return .unknownEnvironment }
        return environment == record.environmentFingerprint ? .matching : .changedEnvironment
    }
}
