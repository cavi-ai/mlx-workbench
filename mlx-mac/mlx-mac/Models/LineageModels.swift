import Foundation

// MARK: - Lineage models
//
// Model Lineage (premium spec 07): one provenance timeline per model,
// assembled read-only from the stores the app already keeps (workflow
// history, verification reports, comparison runs, usage stamps, wiring
// transactions, quarantine ledger, scan evidence). No new data collection —
// this feature is surfacing.

enum LineageEventKind: String, Codable, Sendable {
    case source
    case converted
    case verified
    case verificationFailed
    case benchmarked
    case served
    case wired
    case quarantined

    var title: String {
        switch self {
        case .source: return "Source"
        case .converted: return "Converted"
        case .verified: return "Verified"
        case .verificationFailed: return "Verification failed"
        case .benchmarked: return "Benchmarked"
        case .served: return "Served"
        case .wired: return "Wired"
        case .quarantined: return "Quarantined"
        }
    }

    var systemImage: String {
        switch self {
        case .source: return "arrow.down.circle"
        case .converted: return "shippingbox"
        case .verified: return "checkmark.seal"
        case .verificationFailed: return "xmark.seal"
        case .benchmarked: return "chart.bar"
        case .served: return "play.circle"
        case .wired: return "cable.connector"
        case .quarantined: return "archivebox"
        }
    }
}

struct LineageEvent: Codable, Equatable, Identifiable, Sendable {
    /// Stable identity: kind + timestamp + summary.
    let id: String
    let kind: LineageEventKind
    let at: Date
    let summary: String
    let detail: [String: String]
    /// True when the event was recorded against different bytes than the
    /// model's current signature — evidence predates the current file.
    let stale: Bool

    init(kind: LineageEventKind, at: Date, summary: String, detail: [String: String] = [:], stale: Bool = false) {
        // hashValue is per-process seeded; identity only needs to be stable
        // within a rendered session.
        self.id = "\(kind.rawValue)::\(at.timeIntervalSince1970)::\(summary)"
        self.kind = kind
        self.at = at
        self.summary = summary
        self.detail = detail
        self.stale = stale
    }
}

struct ModelLineage: Codable, Equatable, Sendable {
    let modelPath: String
    let currentSignature: String?
    /// Newest first.
    let events: [LineageEvent]

    var markdown: String {
        var lines = ["# Lineage: \(URL(fileURLWithPath: modelPath).lastPathComponent)", ""]
        lines.append("- Path: `\(modelPath)`")
        lines.append("- Signature: \(currentSignature ?? "unknown")")
        lines.append("")
        for event in events {
            let marker = event.stale ? " *(predates current bytes)*" : ""
            lines.append("- **\(event.kind.title)** — \(event.at.formatted(date: .abbreviated, time: .shortened)): \(event.summary)\(marker)")
            for (key, value) in event.detail.sorted(by: { $0.key < $1.key }) {
                lines.append("  - \(key): \(value)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
