import Foundation

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

    enum CodingKeys: String, CodingKey {
        case path, name, bytes, shard, architecture, quantization, parameters
        case structure, signature, companion, readable, status, outputs, error
        case modifiedAt = "modified_at"
        case modelKey = "model_key"
        case tensorCount = "tensor_count"
    }

    var id: String { path }

    init(path: String, name: String, bytes: Int64, modifiedAt: Int?, shard: String?,
         modelKey: String?, architecture: String?, quantization: String?, parameters: String?,
         structure: String?, signature: String?, companion: Bool?, readable: Bool?,
         status: String, outputs: [String], tensorCount: Int?, error: String?) {
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

    enum CodingKeys: String, CodingKey {
        case path, name, quantization, provenance
        case modelKey = "model_key"
    }

    var id: String { path }
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

    enum CodingKeys: String, CodingKey {
        case receipt, repo, source, out, pid, state
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
    let runtime: String?
    let port: Int?
    let pid: Int?
    let state: String?
    let logPath: String?
    let startedAt: String?
    let receipt: String?

    enum CodingKeys: String, CodingKey {
        case repo, runtime, port, pid, state, receipt
        case logPath = "log_path"
        case startedAt = "started_at"
    }

    var id: String { "\(repo ?? "")-\(port.map(String.init) ?? "")" }
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

    enum CodingKeys: String, CodingKey {
        case repo, base, roles, license, wiring, downloads, likes
        case estRamGb = "est_ram_gb"
        case fits
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

    var id: String { path }
}

// MARK: - AdoptResult

struct AdoptResult: Codable, Equatable {
    let state: String?
    let role: String?
    let model: String?
    let status: String?
    let message: String?
    let manager: String?
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
        guard let v = value(key) else { return nil }
        if let i = v as? Int { return i }
        if let i64 = v as? Int64 { return Int(i64) }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    func double(_ key: String) -> Double? {
        guard let v = value(key) else { return nil }
        if let d = v as? Double { return d }
        if let f = v as? Float { return Double(f) }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }
}