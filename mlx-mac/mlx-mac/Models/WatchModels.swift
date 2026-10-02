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
    /// The agent's finding code and detail for upstream alerts; nil on alerts saved before they were kept.
    var code: String? = nil
    var detail: String? = nil

    func isActive(at now: Date) -> Bool {
        guard dismissedAt == nil, !muted else { return false }
        if let snoozedUntil, snoozedUntil > now { return false }
        return !WatchAlertPresentation.isUnknownAccess(self)
    }
}

/// What an alert says and the one action that resolves it.
struct WatchAlertPresentation: Equatable {
    enum ActionKind: Equatable {
        case addFromHuggingFace(repo: String)
        case openOnHuggingFace(repo: String)
        case reverify
    }

    struct Action: Equatable {
        let title: String
        let kind: ActionKind
    }

    let title: String
    let message: String
    let primary: Action?
    let muteTitle: String

    init(alert: WatchAlert) {
        let repo = alert.modelKey
        guard alert.kind == .upstreamChange else {
            title = alert.title
            message = alert.body
            primary = Action(title: "Re-verify", kind: .reverify)
            muteTitle = "Mute"
            return
        }
        let (code, detail) = Self.finding(of: alert)
        switch code {
        case "new_quant_of_owned":
            title = "New upload of a model you have"
            message = "\(repo) matches a model in your library."
            primary = Action(title: "Add from Hugging Face", kind: .addFromHuggingFace(repo: repo))
            muteTitle = "Mute"
        case "updated_tracked_repo":
            title = "\(repo) was updated"
            message = "Its weights changed on Hugging Face."
            primary = Action(title: "Get update", kind: .addFromHuggingFace(repo: repo))
            muteTitle = "Mute"
        case "owned_missing":
            title = "\(repo) is no longer on this Mac"
            message = "It was in \(Self.sourceName(detail)). Download it again, or stop watching it."
            primary = Action(title: "Download again", kind: .addFromHuggingFace(repo: repo))
            muteTitle = "Stop watching"
        case "gated_changed":
            title = "\(repo) changed access"
            message = Self.accessMessage(detail)
            primary = Action(title: "Open on Hugging Face", kind: .openOnHuggingFace(repo: repo))
            muteTitle = "Mute"
        default:
            title = "\(repo) changed on Hugging Face"
            message = (detail ?? alert.body)
            primary = Action(title: "Open on Hugging Face", kind: .openOnHuggingFace(repo: repo))
            muteTitle = "Mute"
        }
    }

    /// The finding code and detail; alerts saved before codes were kept carry them in the body
    /// as "[code] detail. Re-sync via Prepare when ready."
    static func finding(of alert: WatchAlert) -> (code: String?, detail: String?) {
        if alert.code != nil { return (alert.code, alert.detail) }
        guard let match = alert.body.range(of: #"^\[[a-z_]+\] "#, options: .regularExpression) else { return (nil, nil) }
        let code = String(alert.body[match].dropFirst().dropLast(2))
        var detail = String(alert.body[match.upperBound...])
        if let suffix = detail.range(of: ". Re-sync via Prepare when ready.") { detail = String(detail[..<suffix.lowerBound]) }
        return (code, detail)
    }

    /// Hugging Face not reporting a repo's access level is not a change worth an alert.
    static func isUnknownAccess(_ alert: WatchAlert) -> Bool {
        let (code, detail) = finding(of: alert)
        guard code == "gated_changed", let detail else { return false }
        return detail.hasSuffix(" to unknown") || detail.hasSuffix(" to None")
    }

    private static func accessMessage(_ detail: String?) -> String {
        let now = detail?.components(separatedBy: " to ").last?.lowercased()
        switch now {
        case "manual": return "It now requires approval from the authors to download."
        case "auto": return "It now requires accepting the authors' terms to download."
        case "false", "public": return "It is now public."
        default: return "Its access settings changed on Hugging Face."
        }
    }

    private static func sourceName(_ detail: String?) -> String {
        let source = detail?.range(of: #"via [A-Za-z_-]+"#, options: .regularExpression).map { String(detail![$0].dropFirst(4)) }
        switch source?.lowercased() {
        case "lmstudio": return "LM Studio"
        case "ollama": return "Ollama"
        case "hf", "huggingface", "hf-cache": return "the Hugging Face cache"
        case let other?: return other
        case nil: return "your library"
        }
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
