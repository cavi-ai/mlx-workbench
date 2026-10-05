import Foundation

// MARK: - Reclaim models
//
// Disk Pressure Advisor (premium spec 04): ranked reclaim opportunities with
// evidence, applied through the quarantine pipeline (move, never delete).

enum ReclaimKind: String, Codable, Sendable {
    /// Not served/verified/measured within the staleness window.
    case stale
    /// A retained model dominates on comparable reviewed task evidence.
    case supersededVariant
    /// Same weights in more than one root (scan-computed duplicates).
    case crossRootDuplicate

    var title: String {
        switch self {
        case .stale: return "Stale"
        case .supersededVariant: return "Task-scoped replacement"
        case .crossRootDuplicate: return "Duplicate across roots"
        }
    }
}

enum ReclaimConfidence: String, Codable, Sendable {
    case high
    case review
}

struct ReclaimOpportunity: Equatable, Identifiable, Sendable {
    /// Stable identity: kind + sorted paths, so selection survives re-analysis.
    let id: String
    let kind: ReclaimKind
    let paths: [String]
    let bytes: Int64
    let evidence: String
    let confidence: ReclaimConfidence
    /// False when a path is not a `.gguf` file — quarantine only moves those;
    /// anything else is review-only ("move it yourself, deliberately").
    let actionable: Bool
    let replacement: ModelReplacementChain?

    init(kind: ReclaimKind, paths: [String], bytes: Int64, evidence: String, confidence: ReclaimConfidence, actionable: Bool, replacement: ModelReplacementChain? = nil) {
        self.id = "\(kind.rawValue)::\(paths.sorted().joined(separator: "|"))\(replacement.map { "::\($0.source)::\($0.keeper.path)" } ?? "")"
        self.kind = kind
        self.paths = paths
        self.bytes = bytes
        self.evidence = evidence
        self.confidence = confidence
        self.actionable = actionable
        self.replacement = replacement
    }
}

/// All members belong to one evidence cohort; chains never cross tasks or configurations.
struct ModelReplacementChain: Codable, Equatable, Sendable {
    let keeper: ModelReplacementMember
    let replaced: [ModelReplacementMember]
    let task: String
    let source: String
}

struct ModelReplacementMember: Codable, Equatable, Sendable {
    let path: String
    let name: String
    let diskBytes: Int64
    let qualityScore: Int
    let tokensPerSecond: Double
    let firstTokenSeconds: Double
}

/// Live disk-free probe for the Home next-action escalation.
enum DiskProbe {
    static func freeFraction(volume: URL = URL(fileURLWithPath: "/")) -> Double? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: volume.path),
              let free = attributes[.systemFreeSize] as? Int64,
              let total = attributes[.systemSize] as? Int64,
              total > 0 else { return nil }
        return Double(free) / Double(total)
    }
}
