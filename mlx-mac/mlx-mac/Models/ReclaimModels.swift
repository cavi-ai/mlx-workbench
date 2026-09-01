import Foundation

// MARK: - Reclaim models
//
// Disk Pressure Advisor (premium spec 04): ranked reclaim opportunities with
// evidence, applied through the quarantine pipeline (move, never delete).

enum ReclaimKind: String, Codable, Sendable {
    /// Not served/verified/measured within the staleness window.
    case stale
    /// A verified sibling variant of the same model exists at equal or
    /// higher quality.
    case supersededVariant
    /// Same weights in more than one root (scan-computed duplicates).
    case crossRootDuplicate

    var title: String {
        switch self {
        case .stale: return "Stale"
        case .supersededVariant: return "Superseded"
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

    init(kind: ReclaimKind, paths: [String], bytes: Int64, evidence: String, confidence: ReclaimConfidence, actionable: Bool) {
        self.id = "\(kind.rawValue)::\(paths.sorted().joined(separator: "|"))"
        self.kind = kind
        self.paths = paths
        self.bytes = bytes
        self.evidence = evidence
        self.confidence = confidence
        self.actionable = actionable
    }
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
