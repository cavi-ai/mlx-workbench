import Foundation

indirect enum LabValue: Codable, Equatable, Sendable {
    case object([String: LabValue]), array([LabValue]), string(String)
    case integer(Int), number(Double), boolean(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .boolean(x) }
        else if let x = try? c.decode(Int.self) { self = .integer(x) }
        else if let x = try? c.decode(Double.self) { self = .number(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode([String: LabValue].self) { self = .object(x) }
        else { self = .array(try c.decode([LabValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .string(let x): try c.encode(x)
        case .integer(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .boolean(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
    var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    var object: [String: LabValue]? { if case .object(let value) = self { return value }; return nil }
    var text: String? { if case .string(let value) = self { return value }; return nil }
    var decimal: Double? {
        switch self { case .integer(let n): return Double(n); case .number(let n): return n; default: return nil }
    }
}

struct LabDraft: Codable, Sendable {
    var baseline: LabValue
    var variablePath: String
    var alternateValue: LabValue
    enum CodingKeys: String, CodingKey {
        case baseline, variablePath = "variable_path", alternateValue = "alternate_value"
    }
}

struct LabScore: Codable, Sendable {
    let displayPosition: String
    let dimension: String
    let score: Int
    enum CodingKeys: String, CodingKey { case displayPosition = "display_position", dimension, score }
}

struct LabRequest: Codable, Sendable {
    var operation: String
    var draft: LabDraft? = nil
    var experimentID: String? = nil
    var jobID: String? = nil
    var workerID: String? = nil
    var sessionID: String? = nil
    var preference: String? = nil
    var scores: [LabScore]? = nil
    var notes: String? = nil
    var studyID: String? = nil
    var manifest: LabValue? = nil
    var evaluationID: String? = nil
    var receipt: String? = nil
    var prompt: String? = nil
    var maxTokens: Int? = nil
    var sourceDatabase: String? = nil
    var sourceArtifacts: String? = nil
    var destination: String? = nil
    var previewHash: String? = nil
    var promptSuite: TrainingEvaluationSuite? = nil
    var promptID: String? = nil
    var artifactSHA256: String? = nil
    var settings: LabValue? = nil
    enum CodingKeys: String, CodingKey {
        case operation, draft, experimentID = "experiment_id", jobID = "job_id"
        case workerID = "worker_id", sessionID = "session_id", preference, scores, notes
        case studyID = "study_id", manifest
        case evaluationID = "evaluation_id"
        case receipt, prompt, maxTokens = "max_tokens"
        case sourceDatabase = "source_database", sourceArtifacts = "source_artifacts", destination, previewHash = "preview_hash", settings
        case promptSuite = "prompt_suite", promptID = "prompt_id", artifactSHA256 = "artifact_sha256"
    }
}

struct LabHistoryItem: Decodable, Identifiable, Sendable {
    let id: String
    let sealed: Bool
    let states: [String]
    let evidenceCompleteness: String
    enum CodingKeys: String, CodingKey { case id, sealed, states, evidenceCompleteness = "evidence_completeness" }
}
struct LabHistory: Decodable, Sendable { let items: [LabHistoryItem] }
struct LabJob: Decodable, Identifiable, Sendable {
    let id: String
    let experimentID: String
    let state: String
    let error: String?
    enum CodingKeys: String, CodingKey { case id, experimentID = "experiment_id", state, error }
}
struct LabResponse: Decodable, Sendable {
    var evaluationID: String? = nil
    var reviews: [TrainingEvaluationReview]? = nil
    var studies: [LabValue]? = nil
    var study: LabValue? = nil
    var plan: LabValue? = nil
    var report: LabValue? = nil
    var artifactSHA256: String? = nil
    var evaluations: [LabValue]? = nil
    var history: LabHistory? = nil
    var queue: [LabJob]? = nil
    var experimentID: String? = nil
    var sessionID: String? = nil
    var prompt: String? = nil
    var left: String? = nil
    var right: String? = nil
    var status: String? = nil
    var errorCode: String? = nil
    var errorMessage: String? = nil
    var changedPaths: [String]? = nil
    var reviewID: String? = nil
    var revision: Int? = nil
    var previewHash: String? = nil
    var sourceDatabaseDigest: String? = nil
    var artifactCount: Int? = nil
    var artifactBytes: Int64? = nil
    var storePath: String? = nil
    var canonicalByDisplay: [String: String]? = nil
    var variablePath: String? = nil
    var baselineValue: LabValue? = nil
    var alternateValue: LabValue? = nil
    var manifests: [String: LabValue]? = nil
    var recipes: [StudyRecipeOption]? = nil
    var manifest: LabValue? = nil
    enum CodingKeys: String, CodingKey {
        case evaluationID = "evaluation_id", reviews
        case studies, study, recipes, manifest
        case plan, report, artifactSHA256 = "artifact_sha256", evaluations
        case history, queue, experimentID = "experiment_id", sessionID = "session_id", prompt, left, right, status
        case errorCode = "error_code", errorMessage = "error_message", changedPaths = "changed_paths"
        case reviewID = "review_id", revision
        case previewHash = "preview_hash", sourceDatabaseDigest = "source_database_digest"
        case artifactCount = "artifact_count", artifactBytes = "artifact_bytes", storePath = "store_path"
        case canonicalByDisplay = "canonical_by_display", variablePath = "variable_path"
        case baselineValue = "baseline_value", alternateValue = "alternate_value", manifests
    }
}

struct TrainingEvaluationSuite: Codable, Equatable, Sendable {
    struct Prompt: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let text: String
        let maxTokens: Int
        enum CodingKeys: String, CodingKey { case id, text, maxTokens = "max_tokens" }
    }
    let id: String
    let name: String
    let prompts: [Prompt]

    static func unavailableReason(_ set: PromptSet) -> String? {
        guard set.effectiveMode == .chat else { return "Choose a chat prompt set." }
        guard (1...16).contains(set.prompts.count) else { return "Evaluation supports 1–16 prompts per set." }
        guard validID(set.id), PromptSetNameValidation.error(for: set.name) == nil, set.name.count <= 200 else {
            return "The prompt set needs a valid identity and name."
        }
        guard Set(set.prompts.map(\.id)).count == set.prompts.count else { return "Prompt identities must be unique." }
        for prompt in set.prompts {
            guard validID(prompt.id), !prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  prompt.text.count <= 8000, (1...512).contains(prompt.maxTokens) else {
                return "Each prompt needs text up to 8,000 characters and a token limit from 1 to 512."
            }
            guard prompt.tool == nil, prompt.inputKind == nil, prompt.inputPath == nil, prompt.builtinInput == nil,
                  prompt.media == nil, prompt.expectedKeywords == nil else {
                return "Evaluation uses text-only prompts without tools, media or expected-word scoring."
            }
        }
        return nil
    }

    init(_ set: PromptSet) throws {
        if let reason = Self.unavailableReason(set) { throw WorkflowEvidenceError.invalid(reason) }
        id = set.id; name = set.name
        prompts = set.prompts.map { Prompt(id: $0.id, text: $0.text, maxTokens: $0.maxTokens) }
    }

    private static func validID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil
    }
}

struct TrainingEvaluationReview: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let evaluationID: String
    let artifactSHA256: String
    let promptID: String
    let reviewerID: String
    let preference: String
    let notes: String
    let createdAt: String
    enum CodingKeys: String, CodingKey {
        case id, evaluationID = "evaluation_id", artifactSHA256 = "artifact_sha256", promptID = "prompt_id"
        case reviewerID = "reviewer_id", preference, notes, createdAt = "created_at"
    }
    static let preferences = ["baseline", "adapter", "tie", "neither"]
    static func title(_ value: String) -> String {
        switch value {
        case "baseline": return "Base model"
        case "adapter": return "Trained adapter"
        case "tie": return "Tie"
        case "neither": return "Neither"
        default: return "Choose a preference"
        }
    }
}

struct TrainingEvaluationSample: Identifiable, Equatable {
    let id: String
    let prompt: String
    let maxTokens: Int
    let baseline: String
    let adapter: String

    static func parse(_ report: LabValue) throws -> [Self] {
        guard let object = report.object else { throw WorkflowEvidenceError.invalid("Evaluation report is unreadable.") }
        let rows: [LabValue]
        let suite: TrainingEvaluationSuite?
        switch object["schema_version"]?.text {
        case "text-training-evaluation/2":
            guard case .array(let values) = object["samples"] else { throw WorkflowEvidenceError.invalid("Evaluation samples are missing.") }
            rows = values
            guard let captured = object["prompt_suite"] else { throw WorkflowEvidenceError.invalid("The recorded prompt suite is missing.") }
            suite = try JSONDecoder().decode(TrainingEvaluationSuite.self, from: JSONEncoder().encode(captured))
        case "text-training-evaluation/1":
            rows = [.object(object.merging(["id": .string("prompt")]) { _, new in new })]; suite = nil
        default: throw WorkflowEvidenceError.invalid("This report has no supported evaluation schema.")
        }
        let samples = try rows.map { row -> Self in
            guard let value = row.object, let id = value["id"]?.text, !id.isEmpty,
                  let prompt = value["prompt"]?.text, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let limit = value["max_tokens"]?.decimal, limit.rounded() == limit, limit >= 1, limit <= 512,
                  let outputs = value["outputs"]?.object, let baseline = outputs["baseline"]?.text,
                  let adapter = outputs["adapter"]?.text, !baseline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !adapter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowEvidenceError.invalid("Evaluation did not return a complete paired output.")
            }
            return Self(id: id, prompt: prompt, maxTokens: Int(limit), baseline: baseline, adapter: adapter)
        }
        guard (1...16).contains(samples.count), Set(samples.map(\.id)).count == samples.count else {
            throw WorkflowEvidenceError.invalid("Evaluation prompt identities are incomplete or repeated.")
        }
        if let suite {
            guard samples.map(\.id) == suite.prompts.map(\.id),
                  zip(samples, suite.prompts).allSatisfy({ pair in pair.0.prompt == pair.1.text && pair.0.maxTokens == pair.1.maxTokens }) else {
                throw WorkflowEvidenceError.invalid("Recorded samples do not match their frozen prompt suite.")
            }
        }
        return samples
    }
}

struct QueueResponse: Decodable, Sendable {
    let conversionQueue: LabValue?
    let queuePath: String
    let previewHash: String?
    let sourceDigest: String?
    let itemCount: Int?
    let backup: String?
    enum CodingKeys: String, CodingKey {
        case conversionQueue = "conversion_queue", queuePath = "queue_path"
        case previewHash = "preview_hash", sourceDigest = "source_digest", itemCount = "item_count", backup
    }
    func snapshot() throws -> WebConvertQueue.Snapshot {
        let items = try conversionQueue.map { try WebConvertQueue.parse(JSONEncoder().encode($0)) } ?? []
        return WebConvertQueue.Snapshot(items: items, path: queuePath, problem: nil)
    }
}

struct TrainingSnapshot: Decodable, Sendable { let jobs: [TrainingJob] }
struct TrainingJob: Decodable, Identifiable, Sendable {
    let receipt: String
    let repo: String
    let out: String
    let pid: Int
    let state: String
    let logPath: String?
    let adapterIdentity: LabValue?
    var id: String { receipt }
    enum CodingKeys: String, CodingKey {
        case receipt, repo, out, pid, state, logPath = "log_path", adapterIdentity = "adapter_identity"
    }
}
