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

/// A request for a producer, never evidence of a run. Required measurements
/// are explicitly null so an unfilled draft cannot be imported as observations.
struct WorkflowCaptureRequest: Encodable {
    let schemaVersion = 1
    let contextCapturedAt: Date
    let model: WorkflowCaptureModel
    let environmentFingerprint: String?
    let reportDraft: Draft
    let instructions: String
    let reportContract = WorkflowReport.template.guidance

    static func make(harness: WorkflowHarness, model: WorkflowCaptureModel, environment: String?, now: Date = Date()) throws -> Self {
        guard model.path.hasPrefix("/") else { throw WorkflowEvidenceError.invalid("capture requires an absolute local model path") }
        let signature = model.signature.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let fingerprint = ComparisonInsights.knownEnvironment(environment) ? environment : nil
        let contextModel = WorkflowCaptureModel(path: model.path, name: model.name, signature: signature)
        return Self(contextCapturedAt: now, model: contextModel, environmentFingerprint: fingerprint,
            reportDraft: Draft(record: DraftRecord(id: UUID(), harness: harness.rawValue, modelPath: model.path, modelSignature: signature, environmentFingerprint: fingerprint)),
            instructions: "Produce a schema-1 local workflow report for \(harness.title). This request captures identity context only, not a measurement. Verify that the workflow actually uses this exact local model and environment; a client name alone does not identify the serving model. Unknown identity fields are null: establish them from the actual run, never invent a match. Never reuse this context for an older run or replace a recorded fingerprint. Fill reportDraft from measured local receipts/session evidence, retain the actual measuredAt, and save only the reportDraft object as JSON for Import workflow report. If the model, environment, receipt or required timings cannot be established, report missing evidence instead of inventing values. Use a stable workloadID and configurationFingerprint for the same prompts, tools, context and generation settings. Timing components must be additive, disjoint seconds; omit any unknown component. Do not infer GPU, disk or network time from unattributed time. Task quality requires an explicit human review and shared rubricID; no automatic quality score. Include only source identifiers, timings, scores and byte counts; omit prompts, transcripts, credentials and secrets.")
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
