import Foundation

enum ScanContractError: LocalizedError, Equatable {
    case invalidRequiredField(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequiredField(let path):
            return "The model inventory returned invalid required data at \(path)."
        }
    }
}

// MARK: - ModelItem
// One entry from `convert scan` (the .gguf inventory), also reused for MLX outputs.

struct ModelItem: Codable, Equatable, Identifiable, Hashable {
    let path: String
    let name: String
    let bytes: Int64
    let modifiedAt: Int?
    let shard: String?
    let modelKey: String?
    let architecture: String?
    let quantization: String?
    let parameters: String?
    let structure: String?
    let signature: String?
    let companion: Bool?
    let readable: Bool?
    let status: String
    let outputs: [String]
    let tensorCount: Int?
    let error: String?
    let task: ModelTask?
    let draft: ModelDraft?
    var servingRuntime: String? = nil
    var backend: OutputBackend? = nil
    /// The bit widths the engine converts this GGUF at; nil when the scan did not report them.
    var qBits: [Int]? = nil
    /// The model family Splash's engine serves this output as; nil when Splash does not serve it or is not installed.
    var splashFamily: String? = nil

    enum CodingKeys: String, CodingKey {
        case path, name, bytes, shard, architecture, quantization, parameters
        case structure, signature, companion, readable, status, outputs, error, task, draft, backend
        case qBits = "q_bits"
        case splashFamily = "splash_family"
        case modifiedAt = "modified_at"
        case modelKey = "model_key"
        case tensorCount = "tensor_count"
        case servingRuntime = "runtime"
    }

    var id: String { path }

    /// A vision projector or similar sidecar that runs only beside its model.
    var isCompanion: Bool { status == "companion" || companion == true }

    init(path: String, name: String, bytes: Int64, modifiedAt: Int?, shard: String?,
         modelKey: String?, architecture: String?, quantization: String?, parameters: String?,
         structure: String?, signature: String?, companion: Bool?, readable: Bool?,
         status: String, outputs: [String], tensorCount: Int?, error: String?,
         task: ModelTask? = nil, draft: ModelDraft? = nil, servingRuntime: String? = nil,
         backend: OutputBackend? = nil, splashFamily: String? = nil) {
        self.backend = backend
        self.splashFamily = splashFamily
        self.path = path
        self.name = name
        self.bytes = bytes
        self.modifiedAt = modifiedAt
        self.shard = shard
        self.modelKey = modelKey
        self.architecture = architecture
        self.quantization = quantization
        self.parameters = parameters
        self.structure = structure
        self.signature = signature
        self.companion = companion
        self.readable = readable
        self.status = status
        self.outputs = outputs
        self.tensorCount = tensorCount
        self.error = error
        self.task = task
        self.draft = draft
        self.servingRuntime = servingRuntime
    }
}

// MARK: - ScanTotals

struct ScanTotals: Codable, Equatable {
    let gguf: Int
    let pending: Int
    let converted: Int
    let unreadable: Int
    let bytes: Int64
    let reclaimableBytes: Int64

    enum CodingKeys: String, CodingKey {
        case gguf, pending, converted, unreadable, bytes
        case reclaimableBytes = "reclaimable_bytes"
    }
}

// MARK: - ScanResult

struct ScanResult: Codable, Equatable {
    let roots: ScanRoots?
    let models: [ModelItem]
    let outputs: [MLXOutput]
    let pending: [String]
    let duplicates: [DuplicateGroup]
    let totals: ScanTotals
    var rootErrors: [ScanRootError]? = nil
    /// Disk each model occupies with every file counted once, as the scan reports it.
    var storage: ScanStorage? = nil
    /// Copies of one model across formats and stores, as the scan groups them.
    var families: [ModelFamily]? = nil

    enum CodingKeys: String, CodingKey {
        case roots, models, outputs, pending, duplicates, totals, storage, families
        case rootErrors = "root_errors"
    }
}

struct ScanStorage: Codable, Equatable {
    let diskBytes: Int64
    let roots: [RootUsage]
    let stores: [StoreUsage]
    let items: [StoredModel]

    enum CodingKeys: String, CodingKey {
        case roots, stores, items
        case diskBytes = "disk_bytes"
    }
}

struct RootUsage: Codable, Equatable {
    let root: String
    /// Bytes of recognized models under this root, each file once.
    let bytes: Int64
    /// Every regular file under this root, each file once.
    let totalBytes: Int64
    /// Places under this root holding bytes no recognized model owns.
    let other: [OtherPlace]

    enum CodingKeys: String, CodingKey {
        case root, bytes, other
        case totalBytes = "total_bytes"
    }
}

struct OtherPlace: Codable, Equatable, Hashable {
    let path: String
    let bytes: Int64
}

struct StoreUsage: Codable, Equatable {
    let store: String
    let bytes: Int64
}

struct StoredFile: Codable, Equatable, Hashable {
    /// Device and inode: equal ids are one file on disk.
    let id: String
    let path: String
    let bytes: Int64
}

struct StoredModel: Codable, Equatable, Hashable, Identifiable {
    let path: String
    /// `gguf`, `folder` or `ollama`.
    let kind: String
    let format: String?
    let name: String
    let modelKey: String?
    let root: String?
    /// `folder`, `huggingface` or `ollama`.
    let store: String
    let bytes: Int64
    let files: [StoredFile]

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path, kind, format, name, root, store, bytes, files
        case modelKey = "model_key"
    }
}

struct ModelFamily: Codable, Equatable, Hashable, Identifiable {
    let familyID: String
    let name: String
    let members: [String]
    let bytes: Int64

    var id: String { familyID }

    enum CodingKeys: String, CodingKey {
        case name, members, bytes
        case familyID = "family_id"
    }
}

struct ScanRootError: Codable, Equatable {
    let path: String
    let message: String
}

struct ScanRoots: Codable, Equatable {
    let gguf: [String]
    let mlx: [String]
}

struct MLXOutput: Codable, Equatable, Identifiable, Hashable {
    let path: String
    let name: String
    let modelKey: String?
    let quantization: QuantInfo?
    let provenance: String?
    var task: ModelTask? = nil
    var runtime: String? = nil
    /// The backend that runs this output for its task, as the scan reports it.
    var backend: OutputBackend? = nil
    /// The family Splash's engine finds this output's config to describe, as the scan reports it.
    var splashFamily: String? = nil

    enum CodingKeys: String, CodingKey {
        case path, name, quantization, provenance, task, runtime, backend
        case modelKey = "model_key"
        case splashFamily = "splash_family"
    }

    var id: String { path }
}

struct OutputBackend: Codable, Equatable, Hashable {
    let id: String
    let installed: Bool
}

struct QuantInfo: Codable, Equatable, Hashable {
    let bits: Int
    let groupSize: Int?
    let modelType: String?

    enum CodingKeys: String, CodingKey {
        case bits
        case groupSize = "group_size"
        case modelType = "model_type"
    }
}

// MARK: - DuplicateGroup

struct DuplicateGroup: Codable, Equatable, Identifiable {
    let kind: String?
    let modelKey: String?
    let quantization: String?
    let quantizations: [String]?
    let reclaimableBytes: Int64?
    let keep: String?
    let redundant: [String]?
    let members: [String]?
    let count: Int?
    let groupId: String?

    enum CodingKeys: String, CodingKey {
        case kind, quantization, quantizations, keep, redundant, members, count
        case modelKey = "model_key"
        case reclaimableBytes = "reclaimable_bytes"
        case groupId = "group_id"
    }

    var id: String {
        return groupId ?? "\(kind ?? "")-\(modelKey ?? "")-\(quantization ?? "")"
    }

    var paths: [String] {
        if let members, !members.isEmpty { return members }
        if let redundant { return redundant }
        return []
    }

    var sources: [String] {
        var all = paths
        if let keep { all.insert(keep, at: 0) }
        return Array(Set(all))
    }
}

// MARK: - Job

struct Job: Codable, Equatable, Identifiable {
    let receipt: String?
    let repo: String?
    let source: String?
    let qBits: Int?
    let out: String?
    let pid: Int?
    let logPath: String?
    let startedAt: String?
    let completedAt: String?
    let state: String
    var previewHash: String? = nil
    var sourceDetails: ModelConversionSourceDetails? = nil
    var backend: String? = nil
    var modelType: String? = nil
    var completionObserved: Bool? = nil
    var exitCode: Int? = nil
    var processesQuiescent: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case receipt, repo, source, out, pid, state, backend
        case previewHash = "preview_hash", sourceDetails = "source_details", modelType = "model_type"
        case completionObserved = "completion_observed", exitCode = "exit_code"
        case processesQuiescent = "processes_quiescent"
        case qBits = "q_bits"
        case logPath = "log_path"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }

    var id: String { receipt ?? "\(repo ?? "")-\(out ?? "" )-\(startedAt ?? "")" }

    var displayName: String {
        guard let repo else { return out ?? "job" }
        return URL(fileURLWithPath: repo).deletingPathExtension().lastPathComponent
    }
}

// MARK: - ServerInfo

struct ServerInfo: Codable, Equatable, Identifiable {
    let repo: String?
    let path: String?
    let runtime: String?
    let port: Int?
    let pid: Int?
    let state: String?
    let logPath: String?
    let startedAt: String?
    let receipt: String?
    let jit: Bool?
    let modelState: String?
    let workerPid: Int?
    let activeRequests: Int?
    let memoryPolicy: EndpointMemoryPolicy?
    let loadBlockedReason: String?
    let adapterPath: String?
    let adapterIdentity: LabValue?
    let adapterStatus: String?
    let trainingBinding: TrainedAdapterBinding?
    let prefillKernel: LabValue?
    let decodeProfile: LabValue?
    let visionProfile: LabValue?
    let receiptsDirectory: String?
    let serviceID: String?
    let processStartedAt: String?
    let memoryAllocation: ServingMemoryAllocation?
    let requestBlockedReason: String?
    let lastUnloadReason: String?
    let taskKinds: [String]?
    let apiKeySHA256: String?
    var inferenceTelemetry: LabValue? = nil
    var requestDefaults: LabValue? = nil
    /// Why the gateway's last load or worker failed, as the engine reports it.
    var lastError: String? = nil
    var supportsChatCompletions: Bool { runtime != "tasks" && (taskKinds?.isEmpty ?? true) }

    enum CodingKeys: String, CodingKey {
        case repo, path, runtime, port, pid, state, receipt
        case jit
        case modelState = "model_state"
        case workerPid = "worker_pid"
        case activeRequests = "active_requests"
        case memoryPolicy = "memory_policy"
        case loadBlockedReason = "load_blocked_reason"
        case adapterPath = "adapter_path"
        case adapterIdentity = "adapter_identity"
        case adapterStatus = "adapter_status"
        case trainingBinding = "training_binding"
        case prefillKernel = "prefill_kernel"
        case decodeProfile = "decode_profile"
        case visionProfile = "vision_profile"
        case receiptsDirectory = "receipts_dir"
        case serviceID = "service_id"
        case processStartedAt = "process_started_at"
        case memoryAllocation = "memory_allocation"
        case requestBlockedReason = "request_blocked_reason"
        case lastUnloadReason = "last_unload_reason"
        case taskKinds = "task_kinds"
        case apiKeySHA256 = "api_key_sha256"
        case inferenceTelemetry = "inference_telemetry", requestDefaults = "request_defaults"
        case lastError = "last_error"
        case logPath = "log_path"
        case startedAt = "started_at"
    }

    init(
        repo: String? = nil,
        path: String? = nil,
        runtime: String? = nil,
        port: Int? = nil,
        pid: Int? = nil,
        state: String? = nil,
        logPath: String? = nil,
        startedAt: String? = nil,
        receipt: String? = nil,
        jit: Bool? = nil,
        modelState: String? = nil,
        workerPid: Int? = nil,
        activeRequests: Int? = nil,
        memoryPolicy: EndpointMemoryPolicy? = nil,
        loadBlockedReason: String? = nil,
        adapterPath: String? = nil,
        adapterIdentity: LabValue? = nil,
        adapterStatus: String? = nil,
        trainingBinding: TrainedAdapterBinding? = nil,
        prefillKernel: LabValue? = nil,
        decodeProfile: LabValue? = nil,
        visionProfile: LabValue? = nil,
        receiptsDirectory: String? = nil,
        serviceID: String? = nil,
        processStartedAt: String? = nil,
        memoryAllocation: ServingMemoryAllocation? = nil,
        requestBlockedReason: String? = nil,
        lastUnloadReason: String? = nil,
        taskKinds: [String]? = nil,
        apiKeySHA256: String? = nil,
        inferenceTelemetry: LabValue? = nil,
        requestDefaults: LabValue? = nil,
        lastError: String? = nil
    ) {
        self.repo = repo
        self.path = path
        self.runtime = runtime
        self.port = port
        self.pid = pid
        self.state = state
        self.logPath = logPath
        self.startedAt = startedAt
        self.receipt = receipt
        self.jit = jit
        self.modelState = modelState
        self.workerPid = workerPid
        self.activeRequests = activeRequests
        self.memoryPolicy = memoryPolicy
        self.loadBlockedReason = loadBlockedReason
        self.adapterPath = adapterPath
        self.adapterIdentity = adapterIdentity
        self.adapterStatus = adapterStatus
        self.trainingBinding = trainingBinding
        self.prefillKernel = prefillKernel
        self.decodeProfile = decodeProfile
        self.visionProfile = visionProfile
        self.receiptsDirectory = receiptsDirectory
        self.serviceID = serviceID
        self.processStartedAt = processStartedAt
        self.memoryAllocation = memoryAllocation
        self.requestBlockedReason = requestBlockedReason
        self.lastUnloadReason = lastUnloadReason
        self.taskKinds = taskKinds
        self.apiKeySHA256 = apiKeySHA256
        self.inferenceTelemetry = inferenceTelemetry
        self.requestDefaults = requestDefaults
        self.lastError = lastError
    }

    /// The identity serve reports for this server's model: the repo id for
    /// cache serves, the local path for `--path` serves, whichever the agent
    /// populated.
    var modelIdentity: String { repo ?? path ?? "" }

    var id: String { "\(modelIdentity)-\(port.map(String.init) ?? "")" }

    /// Receipt metadata records requested acceleration, including native fallback.
    /// Presence is not proof that a particular request used an accelerated path.
    func matchesAcceleration(_ options: LocalInferenceOptions) -> Bool {
        func matches(_ value: LabValue?, requested: Bool, name: String) -> Bool {
            guard requested else { return value == nil }
            guard let fields = value?.object, fields["name"]?.text == name,
                  let hash = fields["fingerprint"]?.text else { return false }
            return hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        }
        return matches(prefillKernel, requested: options.m5Prefill, name: "m5-q4-prefill-v1")
            && matches(decodeProfile, requested: options.promptLookup, name: "prompt-lookup-v1")
            && matches(visionProfile, requested: options.visionCache, name: "vision-features-v1")
            && ServingRequestDefaults.matches(requestDefaults, options: options)
    }

    /// Model-only workflows cannot substitute an adapter server, including
    /// historical servers whose adapter metadata could not be established.
    func matchesUnadaptedModel(_ modelPath: String) -> Bool {
        adapterPath == nil && adapterIdentity == nil && adapterStatus == nil && trainingBinding == nil
            && HFRepoID.matches(modelIdentity, modelPath)
    }

    var adapterSummary: String? {
        if let adapterPath, !adapterPath.isEmpty {
            return "Adapter: " + URL(fileURLWithPath: adapterPath).lastPathComponent
        }
        return adapterIdentity != nil || adapterStatus != nil || trainingBinding != nil ? "Adapter identity unavailable" : nil
    }

    func sameProcess(as other: ServerInfo) -> Bool {
        modelIdentity == other.modelIdentity && port == other.port && pid == other.pid &&
        runtime == other.runtime && receipt == other.receipt && startedAt == other.startedAt &&
        adapterPath == other.adapterPath && adapterIdentity == other.adapterIdentity && adapterStatus == other.adapterStatus && trainingBinding == other.trainingBinding &&
        prefillKernel == other.prefillKernel && decodeProfile == other.decodeProfile && visionProfile == other.visionProfile &&
        processStartedAt == other.processStartedAt && apiKeySHA256 == other.apiKeySHA256
    }

    var residencySummary: String {
        guard jit == true else { return "Serving process" }
        switch modelState {
        case "loaded": return "JIT · loaded"
        case "unloaded": return "JIT · loads on request"
        case "loading": return "JIT · loading…"
        case "unloading": return "JIT · unloading…"
        case "failed": return "JIT · load failed"
        default: return "JIT · residency unknown"
        }
    }
}

// MARK: - DiscoverResult

struct DiscoverResult: Codable, Equatable {
    let candidates: [DiscoverCandidate]?
}

struct DiscoverCandidate: Codable, Equatable, Identifiable {
    let repo: String
    let base: String?
    let roles: [String]?
    let estRamGb: Double?
    let fits: Bool?
    let license: String?
    let wiring: String?
    let downloads: Int?
    let likes: Int?
    /// Position in the engine's Hugging Face listing for the requested sort; nil from older engines.
    var listRank: Int? = nil

    enum CodingKeys: String, CodingKey {
        case repo, base, roles, license, wiring, downloads, likes
        case estRamGb = "est_ram_gb"
        case fits
        case listRank = "list_rank"
    }

    var id: String { repo }

    var displayName: String {
        base ?? repo
    }

    var paramsText: String? {
        guard let estRamGb else { return nil }
        return String(format: "%.1f GB", estRamGb)
    }
}

// MARK: - DoctorResult

struct DoctorResult: Codable, Equatable {
    let findings: [DoctorFinding]?
    let prune_count: Int?
    let preview_hash: String?
    let reclaimedBytes: Int64?
    let removed: [PrunedItem]?
    var summary: DoctorSummary? = nil
}

/// The doctor report's own tally: models counts Hugging Face cache repos plus
/// models listed by running local runtimes.
struct DoctorSummary: Codable, Equatable {
    let models: Int?
    let hfCacheBytes: Int64?
    let wiredConfigs: Int?
    let findings: Int?
    var hfCacheChecked: Bool? = nil
}

struct PrunedItem: Codable, Equatable, Identifiable {
    let repo: String?
    let removed: Bool?
    let bytes: Int64?

    var id: String { repo ?? UUID().uuidString }
}

struct DoctorFinding: Codable, Equatable, Identifiable {
    let path: String
    let kind: String?
    let message: String?
    let size: Int64?
    var model: String? = nil

    var id: String { path }

    static let incompleteDownloadCode = "hf_cache_incomplete"

    /// The one owner of "incomplete download": the only finding the prune flow removes.
    var isIncompleteDownload: Bool { kind == Self.incompleteDownloadCode }

    /// Wiring drift is reported, never pruned.
    var isDrift: Bool { kind?.hasPrefix("drift_") == true }
}

// MARK: - AdoptResult

struct AdoptResult: Codable, Equatable {
    let state: String?
    let role: String?
    let model: String?
    let status: String?
    let message: String?
    let manager: String?
    let workflowID: String?
    let phase: String?
    let evidenceStrength: String?

    init(state: String?, role: String?, model: String?, status: String?, message: String?, manager: String?,
         workflowID: String? = nil, phase: String? = nil, evidenceStrength: String? = nil) {
        self.state = state
        self.role = role
        self.model = model
        self.status = status
        self.message = message
        self.manager = manager
        self.workflowID = workflowID
        self.phase = phase
        self.evidenceStrength = evidenceStrength
    }
}

// MARK: - WireResult

struct WireResult {
    let preview_hash: String?
    let config: [String: Any]?
    let applied: Bool?
}

// MARK: - ServeMetrics

struct ServeMetrics: Codable, Equatable {
    let tokensPerSec: Double?
    let vramUsed: Double?
    let vramFree: Double?
    let cpuTemp: Double?
    let gpuLoad: Double?
}

// MARK: - QueueItem

struct QueueItem: Codable, Equatable, Identifiable {
    let id: String
    let kind: String
    let previewHash: String
    let qBits: Int
    let out: String?
    let path: String?
    let repo: String?
    let hfCache: String?
    let label: String
    let state: String
}

// MARK: - JSON helpers

/// Case-insensitive dictionary getter so CLI payloads decode regardless of key casing.
extension Dictionary where Key == String, Value == Any {
    func value(_ key: String) -> Any? {
        if let hit = self[key] { return hit }
        let lower = key.lowercased()
        for (k, v) in self where k.lowercased() == lower {
            return v
        }
        return nil
    }

    func string(_ key: String) -> String? {
        guard let v = value(key) else { return nil }
        if let s = v as? String { return s }
        if let num = v as? NSNumber { return num.stringValue }
        return nil
    }

    func int(_ key: String) -> Int? {
        guard let value = value(key), let integer = Self.int64(value),
              integer >= Int64(Int.min), integer <= Int64(Int.max) else {
            return nil
        }
        return Int(integer)
    }

    func double(_ key: String) -> Double? {
        guard let v = value(key) else { return nil }
        if let d = v as? Double { return d }
        if let f = v as? Float { return Double(f) }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    func requiredString(_ key: String, at path: String) throws -> String {
        guard let string = string(key), !string.isEmpty else {
            throw ScanContractError.invalidRequiredField(path)
        }
        return string
    }

    func requiredInt64(_ key: String, at path: String) throws -> Int64 {
        guard let value = value(key), let integer = Self.int64(value), integer >= 0 else {
            throw ScanContractError.invalidRequiredField(path)
        }
        return integer
    }

    func optionalInt64(_ key: String, at path: String) throws -> Int64? {
        guard let value = value(key) else { return nil }
        guard let integer = Self.int64(value), integer >= 0 else {
            throw ScanContractError.invalidRequiredField(path)
        }
        return integer
    }

    private static func int64(_ value: Any) -> Int64? {
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
            let double = value.doubleValue
            guard double.isFinite, double.rounded(.towardZero) == double,
                  double >= Double(Int64.min), double <= Double(Int64.max) else {
                return nil
            }
            return value.int64Value
        }
        if value is Bool { return nil }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Double {
            guard value.isFinite, value.rounded(.towardZero) == value,
                  value >= Double(Int64.min), value <= Double(Int64.max) else {
                return nil
            }
            return Int64(value)
        }
        if let value = value as? String { return Int64(value) }
        return nil
    }
}
