import Foundation

// MARK: - Watch models
//
// Watch & Regression Alerts (premium spec 08): a low-noise notification layer
// for upstream drift (owned HF repos changed) and environment drift (macOS /
// MLX changed since models were verified). Alerts are rare, actionable, and
// never block anything; the feature is deliberately silent about network
// failure.

enum WatchAlertKind: String, Codable, Sendable {
    case upstreamChange
    case environmentDrift

    var route: String {
        switch self {
        case .upstreamChange: return "convert"
        case .environmentDrift: return "models"
        }
    }
}

struct WatchAlert: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: WatchAlertKind
    /// Dedupe key: an alert never fires twice for the same change-set.
    let fingerprint: String
    let modelKey: String
    let title: String
    let body: String
    let route: String
    let createdAt: Date
    var snoozedUntil: Date?
    var muted: Bool
    var dismissedAt: Date?

    func isActive(at now: Date) -> Bool {
        guard dismissedAt == nil, !muted else { return false }
        if let snoozedUntil, snoozedUntil > now { return false }
        return true
    }
}

/// Watch scheduler state: last check time, whether an upstream baseline has
/// been established, and the environment fingerprint last seen.
struct WatchState: Codable, Equatable, Sendable {
    var lastCheckedAt: Date?
    var baselineEstablished: Bool
    var lastEnvironmentFingerprint: String?

    static var empty: WatchState {
        WatchState(lastCheckedAt: nil, baselineEstablished: false, lastEnvironmentFingerprint: nil)
    }
}

/// macOS + chip + MLX runtime tuple. Recorded on every verification report;
/// a change means previously measured evidence may no longer hold.
struct EnvironmentFingerprint: Equatable, Sendable, CustomStringConvertible {
    let macOSVersion: String
    let chip: String
    let mlxLMVersion: String?

    var description: String {
        "\(macOSVersion)|\(chip)|\(mlxLMVersion ?? "unknown")"
    }

    static func current(hardware: HardwareProfile, mlxLMVersion: () -> String?) -> EnvironmentFingerprint {
        EnvironmentFingerprint(
            macOSVersion: hardware.macOSVersion ?? "unknown",
            chip: hardware.chip ?? "unknown",
            mlxLMVersion: mlxLMVersion()
        )
    }
}
