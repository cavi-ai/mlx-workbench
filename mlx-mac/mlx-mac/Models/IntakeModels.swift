import Foundation

// MARK: - Intake resolve (mlx-agent schemas/intake.schema.json)

enum IntakeVerdict: String, Codable, Equatable {
    case unknown
    case blocked
    case alreadyMLX = "already_mlx"
    case gguf
    case convertible
    case convertibleAfterInstall = "convertible_after_install"
    case unsupported

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = IntakeVerdict(rawValue: raw) ?? .unknown
    }

    var title: String {
        switch self {
        case .unknown: return "Hub unreachable"
        case .blocked: return "Blocked"
        case .alreadyMLX: return "Already MLX"
        case .gguf: return "GGUF repository"
        case .convertible: return "Convertible"
        case .convertibleAfterInstall: return "Convertible after install"
        case .unsupported: return "No MLX converter"
        }
    }
}

struct IntakeSource: Codable, Equatable {
    let input: String
    let repo: String
    let revision: String
    let file: String?
    let url: String
}

struct IntakeMatch: Codable, Equatable, Hashable {
    let backend: String
    let category: String
    let match: String
    let module: String
}

struct IntakeComponent: Codable, Equatable, Hashable, Identifiable {
    let role: String
    let configKey: String?
    let modelType: String
    let matches: [IntakeMatch]

    var id: String { role }

    enum CodingKeys: String, CodingKey {
        case role, matches
        case configKey = "config_key"
        case modelType = "model_type"
    }
}

struct IntakeGGUFFile: Codable, Equatable, Hashable, Identifiable {
    let name: String
    let bytes: Int64
    var id: String { name }
}

struct IntakeFiles: Codable, Equatable {
    let safetensors: Int
    let gguf: [IntakeGGUFFile]
    let python: [String]
}

struct IntakeResolution: Codable, Equatable {
    let schema: String
    let source: IntakeSource
    let verdict: IntakeVerdict
    let reasons: [String]
    let backend: String?
    let backendInstalled: Bool
    let modelType: String?
    let components: [IntakeComponent]
    let task: ModelTask?
    let customCode: Bool
    let gated: Bool
    let libraryName: String?
    let pipelineTag: String?
    let transformersVersion: String?
    let bytes: Int64
    /// Converted size by bit width ("4", "8") from the weight headers; nil when unknown.
    let estimatedOutputBytes: [String: Int64]?
    let files: IntakeFiles
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schema, source, verdict, reasons, backend, components, task, gated, bytes, files, warnings
        case estimatedOutputBytes = "estimated_output_bytes"
        case backendInstalled = "backend_installed"
        case modelType = "model_type"
        case customCode = "custom_code"
        case libraryName = "library_name"
        case pipelineTag = "pipeline_tag"
        case transformersVersion = "transformers_version"
    }

    var repoName: String { source.repo.split(separator: "/").last.map(String.init) ?? source.repo }
}

// MARK: - Backends (schemas/backends.schema.json)

enum BackendState: String, Codable, Equatable {
    case installed, installing, failed, absent

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BackendState(rawValue: raw) ?? .absent
    }
}

struct BackendEntry: Codable, Equatable, Identifiable {
    let id: String
    let version: String
    let builtin: Bool
    let state: BackendState
    let categories: [String]
    let modelTypes: Int
    let registrySource: String
    let target: String?
    let logPath: String?
    let startedAt: String?
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, version, builtin, state, categories, target
        case modelTypes = "model_types"
        case registrySource = "registry_source"
        case logPath = "log_path"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

struct BackendList: Codable, Equatable {
    let schema: String
    let root: String
    let backends: [BackendEntry]
}

// MARK: - Downloads (intake fetch / status)

struct IntakeFetchRequest: Equatable {
    let source: String
    let revision: String
    let file: String?
    let localDir: String?
}

struct FetchJob: Codable, Equatable {
    let receipt: String
    let repo: String?
    let revision: String?
    let file: String?
    let localDir: String?
    let state: String
    let path: String?
    let logPath: String?
    let startedAt: String?
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case receipt, repo, revision, file, state, path
        case localDir = "local_dir"
        case logPath = "log_path"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

// MARK: - Port analysis / plan (schemas/port-analysis.schema.json)

struct PortAnalysisComponent: Codable, Equatable, Hashable, Identifiable {
    let role: String
    let configKey: String?
    let modelType: String
    let status: String
    let matches: [IntakeMatch]

    var id: String { role }

    enum CodingKeys: String, CodingKey {
        case role, status, matches
        case configKey = "config_key"
        case modelType = "model_type"
    }
}

struct PortWeightPrefix: Codable, Equatable, Hashable, Identifiable {
    let prefix: String
    let tensors: Int
    let component: String?
    var id: String { prefix }
}

struct PortWeights: Codable, Equatable {
    let indexAvailable: Bool
    let prefixes: [PortWeightPrefix]
    let extraFiles: [String]

    enum CodingKeys: String, CodingKey {
        case prefixes
        case indexAvailable = "index_available"
        case extraFiles = "extra_files"
    }
}

struct PortCodeClass: Codable, Equatable, Hashable {
    let name: String
    let bases: [String]
    let methods: [String]
    let lineno: Int
}

struct PortCodeFile: Codable, Equatable, Hashable, Identifiable {
    let name: String
    let bytes: Int
    let parsed: Bool
    let classes: [PortCodeClass]
    var id: String { name }
}

struct PortCode: Codable, Equatable {
    let files: [PortCodeFile]
    let truncated: Bool
}

struct PortMissing: Codable, Equatable, Hashable {
    let kind: String
    let name: String
}

struct PortAnalysis: Codable, Equatable {
    let schema: String
    let source: IntakeSource
    let modelType: String?
    let architectures: [String]
    let processorClass: String?
    let transformersVersion: String?
    let components: [PortAnalysisComponent]
    let weights: PortWeights
    let code: PortCode
    let missing: [PortMissing]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schema, source, architectures, components, weights, code, missing, warnings
        case modelType = "model_type"
        case processorClass = "processor_class"
        case transformersVersion = "transformers_version"
    }
}

struct PortPlanResult: Codable, Equatable {
    let schema: String
    let path: String
    let model: String
    let endpoint: String
    let analysisSha256: String
    let promptChars: Int
    let truncated: Bool
    let bytes: Int

    enum CodingKeys: String, CodingKey {
        case schema, path, model, endpoint, truncated, bytes
        case analysisSha256 = "analysis_sha256"
        case promptChars = "prompt_chars"
    }
}
