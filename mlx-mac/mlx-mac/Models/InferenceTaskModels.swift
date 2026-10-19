import Foundation

enum TaskKind: Equatable, Sendable {
    case classification
    case musicGeneration
    case transcribe
    case speak
    case unsupported(String)

    var wireValue: String {
        switch self {
        case .classification: "classification"
        case .musicGeneration: "music_generation"
        case .transcribe: "transcribe"
        case .speak: "speak"
        case .unsupported(let value): value
        }
    }

    var isSupported: Bool {
        switch self {
        case .classification, .musicGeneration, .transcribe, .speak: true
        case .unsupported: false
        }
    }
}

enum TaskProtocolError: Error, LocalizedError {
    case invalidRequest
    case invalidIdentifier
    case unsupportedCapability

    var errorDescription: String? {
        switch self {
        case .invalidRequest: "The task request does not match a supported task schema."
        case .invalidIdentifier: "Task identifiers must be canonical UUIDs."
        case .unsupportedCapability: "This mlx-agent task contract is not supported by this version of Workbench."
        }
    }
}

struct TaskEngineError: Error, LocalizedError, Sendable {
    let detail: TaskErrorDetail
    let task: TaskRecord?
    var errorDescription: String? { detail.message }
    var code: String { detail.code }
    var remediation: String { detail.remediation }
}

struct TaskStartOutcomeUnknown: Error, LocalizedError, Sendable {
    var errorDescription: String? { "The agent started, but Workbench could not read the task ID. Check Recent tasks before retrying." }
}

extension TaskKind: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "classification": self = .classification
        case "music_generation": self = .musicGeneration
        case "transcribe": self = .transcribe
        case "speak": self = .speak
        default: self = .unsupported(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

enum TaskState: Equatable, Sendable {
    case starting
    case running
    case succeeded
    case failed
    case cancelled
    case unsupported(String)

    var wireValue: String {
        switch self {
        case .starting: "starting"
        case .running: "running"
        case .succeeded: "succeeded"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .unsupported(let value): value
        }
    }

    var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }

    var isActive: Bool { self == .starting || self == .running }
}

extension TaskState: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "starting": self = .starting
        case "running": self = .running
        case "succeeded": self = .succeeded
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .unsupported(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var integerValue: Int? {
        if case .number(let value) = self, value.isFinite, value.rounded(.towardZero) == value { Int(exactly: value) } else { nil }
    }
    fileprivate var isStateValue: Bool {
        switch self {
        case .string, .object, .array: true
        case .null, .bool, .number: false
        }
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), container.decodeNil() {
            self = .null
        } else if let container = try? decoder.singleValueContainer(), let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let container = try? decoder.singleValueContainer(), let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let container = try? decoder.singleValueContainer(), let value = try? container.decode(String.self) {
            self = .string(value)
        } else if var container = try? decoder.unkeyedContainer() {
            var values: [JSONValue] = []
            while !container.isAtEnd { values.append(try container.decode(JSONValue.self)) }
            self = .array(values)
        } else {
            let container = try decoder.container(keyedBy: JSONKey.self)
            var values: [String: JSONValue] = [:]
            for key in container.allKeys { values[key.stringValue] = try container.decode(JSONValue.self, forKey: key) }
            self = .object(values)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer(); try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer(); try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer(); try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer(); try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        case .object(let values):
            var container = encoder.container(keyedBy: JSONKey.self)
            for (key, value) in values { try container.encode(value, forKey: JSONKey(stringValue: key)!) }
        }
    }

    private struct JSONKey: CodingKey, Hashable {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

struct TaskRequest: Codable, Equatable, Sendable {
    let schema: String
    let kind: TaskKind
    let modelPath: String
    let parameters: [String: JSONValue]

    init(kind: TaskKind, modelPath: String, parameters: [String: JSONValue]) {
        self.schema = kind == .transcribe || kind == .speak ? "task-request/2" : "task-request/1"
        self.kind = kind
        self.modelPath = modelPath
        self.parameters = parameters
    }

    var isSupported: Bool {
        switch (schema, kind) {
        case ("task-request/1", .classification), ("task-request/1", .musicGeneration),
             ("task-request/2", .transcribe), ("task-request/2", .speak): true
        default: false
        }
    }

    func validate() throws {
        guard isSupported, Self.absolutePath(modelPath) else { throw TaskProtocolError.invalidRequest }
        switch kind {
        case .classification:
            guard Set(parameters.keys) == ["state", "questions"],
                  let state = parameters["state"], state.isStateValue,
                  let questions = parameters["questions"]?.objectValue, !questions.isEmpty else {
                throw TaskProtocolError.invalidRequest
            }
            for question in questions.values {
                guard let fields = question.objectValue,
                      let type = fields["type"]?.stringValue,
                      fields["instructions"] != nil else { throw TaskProtocolError.invalidRequest }
                let criteria = fields["criteria"]
                switch type {
                case "choice":
                    guard (criteria?.arrayValue?.count ?? criteria?.objectValue?.count ?? 0) >= 2 else { throw TaskProtocolError.invalidRequest }
                case "score":
                    guard (criteria?.arrayValue?.count ?? 0) >= 2 else { throw TaskProtocolError.invalidRequest }
                case "noul":
                    guard criteria == nil || criteria?.objectValue != nil else { throw TaskProtocolError.invalidRequest }
                default: throw TaskProtocolError.invalidRequest
                }
            }
        case .musicGeneration:
            guard Set(parameters.keys).isSubset(of: ["caption", "lyrics", "duration", "steps", "seed"]),
                  let caption = parameters["caption"]?.stringValue,
                  !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  caption.count <= 2_000,
                  Self.validText(caption, limit: 2_000),
                  parameters["lyrics"] == nil || parameters["lyrics"]?.stringValue.map({ Self.validText($0, limit: 10_000) }) == true,
                  parameters["duration"] == nil || parameters["duration"]?.numberValue.map({ $0 > 0 && $0 <= 360 }) == true,
                  parameters["steps"] == nil || parameters["steps"]?.integerValue.map({ (1...30).contains($0) }) == true,
                  parameters["seed"] == nil || parameters["seed"]?.integerValue.map({ (0...4_294_967_295).contains($0) }) == true else {
                throw TaskProtocolError.invalidRequest
            }
        case .transcribe:
            guard Set(parameters.keys).isSubset(of: ["audio_path", "language"]),
                  let audioPath = parameters["audio_path"]?.stringValue,
                  Self.absolutePath(audioPath),
                  parameters["language"] == nil || parameters["language"]?.stringValue != nil else {
                throw TaskProtocolError.invalidRequest
            }
        case .speak:
            guard Set(parameters.keys).isSubset(of: ["text", "voice", "speed", "lang_code"]),
                  let text = parameters["text"]?.stringValue,
                  parameters["voice"] == nil || parameters["voice"]?.stringValue != nil,
                  parameters["speed"] == nil || parameters["speed"]?.numberValue != nil,
                  parameters["lang_code"] == nil || parameters["lang_code"]?.stringValue != nil else {
                throw TaskProtocolError.invalidRequest
            }
            _ = text
        case .unsupported:
            throw TaskProtocolError.invalidRequest
        }
    }

    private static func absolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.unicodeScalars.contains(where: { $0.value < 0x20 })
    }

    private static func validText(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 && $0.value != 0x09 && $0.value != 0x0A })
    }

    enum CodingKeys: String, CodingKey {
        case schema, kind, parameters
        case modelPath = "model_path"
    }
}

struct TaskArtifactReference: Codable, Equatable, Sendable {
    let path: String
    let sha256: String
    let bytes: Int
}

struct TaskErrorDetail: Codable, Equatable, Sendable {
    let code: String
    let message: String
    let remediation: String
}

struct TaskIdentitySummary: Codable, Equatable, Sendable {
    let backend: String?
    let backendVersion: String?
    let engineVersion: String?
    let pythonVersion: String?
    let modelFingerprint: String?

    enum CodingKeys: String, CodingKey {
        case backend
        case backendVersion = "backend_version"
        case engineVersion = "engine_version"
        case pythonVersion = "python_version"
        case modelFingerprint = "model_fingerprint"
    }
}

struct TaskProcessReference: Codable, Equatable, Sendable {
    let pid: Int
    let identity: String?
}

struct TaskRecord: Codable, Equatable, Sendable {
    let schema: String
    let id: String
    let kind: TaskKind
    let state: TaskState
    let modelPath: String
    let createdAt: String
    let startedAt: String?
    let completedAt: String?
    let cancelRequested: Bool
    let identity: TaskIdentitySummary
    let request: TaskArtifactReference
    let result: TaskArtifactReference?
    let error: TaskErrorDetail?
    let supervisor: TaskProcessReference?
    let execution: TaskProcessReference?
    let executionUnresolved: Bool
    let inputArtifact: TaskArtifactReference?

    var isSupported: Bool {
        switch (schema, kind) {
        case ("task-run/1", .classification), ("task-run/1", .musicGeneration),
             ("task-run/2", .transcribe), ("task-run/2", .speak): state.isSupported
        default: false
        }
    }

    enum CodingKeys: String, CodingKey {
        case schema, id, kind, state, identity, request, result, error, supervisor, execution
        case inputArtifact = "input_artifact"
        case modelPath = "model_path"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case cancelRequested = "cancel_requested"
        case executionUnresolved = "execution_unresolved"
    }
}

struct TaskPage: Codable, Equatable, Sendable {
    let tasks: [TaskRecord]
    let hasMore: Bool
    enum CodingKeys: String, CodingKey { case tasks; case hasMore = "has_more" }
}

struct TaskResultResponse: Codable, Equatable, Sendable {
    let task: TaskRecord
    let artifact: TaskArtifactReference
    let inline: Bool
    let result: JSONValue?
}

struct TaskCapability: Codable, Equatable, Sendable {
    let kind: TaskKind
    let resultSchema: String
    let cancellation: Bool
    let requiresLocalModel: Bool
    let modelVerification: Bool?
    let requestSchema: String?
    let runSchema: String?
    enum CodingKeys: String, CodingKey {
        case kind, cancellation
        case resultSchema = "result_schema"
        case requiresLocalModel = "requires_local_model"
        case modelVerification = "model_verification"
        case requestSchema = "request_schema"
        case runSchema = "run_schema"
    }
}

struct TaskCapabilities: Codable, Equatable, Sendable {
    let schema: String
    let requestSchema: String
    let runSchema: String
    let tasks: [TaskCapability]
    var isSupported: Bool {
        schema == "task-capabilities/1" && requestSchema == "task-request/1" && runSchema == "task-run/1"
            && tasks.allSatisfy { $0.kind.isSupported }
    }
    func requestSchema(for kind: TaskKind) -> String? { tasks.first(where: { $0.kind == kind })?.requestSchema ?? requestSchema }
    func runSchema(for kind: TaskKind) -> String? { tasks.first(where: { $0.kind == kind })?.runSchema ?? runSchema }
    enum CodingKeys: String, CodingKey {
        case schema, tasks
        case requestSchema = "request_schema"
        case runSchema = "run_schema"
    }
}

struct TaskModelVerification: Codable, Equatable, Sendable {
    let id: String
    let modelPath: String
    let modelFingerprint: String
    let matches: Bool

    enum CodingKeys: String, CodingKey {
        case id, matches
        case modelPath = "model_path"
        case modelFingerprint = "model_fingerprint"
    }
}

struct TaskAnswerProjection: Equatable, Sendable {
    let type: String?
    let choice: String?
    let score: Double?
    let noul: Double?
    let legend: [String: JSONValue]?
    let probabilities: [String: JSONValue]?
    let confidence: Double?
    let activityProbability: Double?

    fileprivate init(value: JSONValue) {
        let fields = value.objectValue ?? [:]
        type = fields["type"]?.stringValue
        choice = fields["choice"]?.stringValue
        score = fields["score"]?.numberValue
        noul = fields["noul"]?.numberValue
        legend = fields["legend"]?.objectValue
        probabilities = fields["probabilities"]?.objectValue
        confidence = fields["confidence"]?.numberValue
        activityProbability = fields["laya"]?.objectValue?["act_probability"]?.numberValue
    }
}

struct TaskResultProjection: Equatable, Sendable {
    let raw: JSONValue
    let answers: [String: TaskAnswerProjection]

    init(raw: JSONValue) {
        self.raw = raw
        answers = raw.objectValue?["answers"]?.objectValue?.mapValues(TaskAnswerProjection.init(value:)) ?? [:]
    }
}

extension JSONValue {
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var numberValue: Double? { if case .number(let value) = self { value } else { nil } }
}
