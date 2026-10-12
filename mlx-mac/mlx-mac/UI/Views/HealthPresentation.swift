import SwiftUI

// MARK: - Layout

/// Health's width thresholds, derived from the width the page is offered and
/// built on the Run content width, never from measured children.
struct HealthLayout: Equatable {
    enum ForkMode: Equatable {
        /// Foundation pair, connector and capability pair in one row.
        case oneRow
        /// Foundation pair above the capability pair.
        case twoRow
        /// One column of four links.
        case stacked
    }

    /// The page content width, including the surface chrome.
    private(set) var contentWidth: CGFloat
    /// The width inside a surface.
    private(set) var innerWidth: CGFloat
    private(set) var forkMode: ForkMode = .twoRow
    private(set) var wrapsHeader = false
    private(set) var compactFindings = false

    static let assumedViewportWidth = WorkbenchSize.assumedContentWidth + WorkbenchSpacing.pageInset * 2

    /// A compact layout flips back to wide only once the width clears the threshold by the hysteresis.
    static func isCompact(width: CGFloat, threshold: CGFloat, wasCompact: Bool) -> Bool {
        width < (wasCompact ? threshold + WorkbenchSize.Health.hysteresis : threshold)
    }

    init(viewportWidth: CGFloat = Self.assumedViewportWidth, previous: HealthLayout? = nil) {
        let raw = RunLayout(viewportWidth: viewportWidth).innerWidth
        innerWidth = max(raw, 0)
        contentWidth = max(raw + WorkbenchSize.Health.surfaceChrome, 0)
        let stacked = Self.isCompact(
            width: contentWidth, threshold: WorkbenchSize.Health.forkStackThreshold,
            wasCompact: previous?.forkMode == .stacked
        )
        let twoRow = Self.isCompact(
            width: contentWidth, threshold: WorkbenchSize.Health.forkRowThreshold,
            wasCompact: previous.map { $0.forkMode != .oneRow } ?? false
        )
        forkMode = stacked ? .stacked : (twoRow ? .twoRow : .oneRow)
        wrapsHeader = Self.isCompact(
            width: innerWidth, threshold: WorkbenchSize.Health.headerThreshold,
            wasCompact: previous?.wrapsHeader ?? false
        )
        compactFindings = Self.isCompact(
            width: innerWidth, threshold: WorkbenchSize.Health.findingThreshold,
            wasCompact: previous?.compactFindings ?? false
        )
    }
}

// MARK: - Readiness chain

enum HealthTone: Equatable {
    case positive
    case negative
    /// A link that cannot be judged until the one it depends on works.
    case pending
    case caution
}

enum HealthLinkID: String, Equatable {
    case agent, python, prepare, run
}

struct HealthPart: Equatable, Identifiable {
    let name: String
    let isPresent: Bool
    var id: String { name }
}

struct HealthLink: Equatable, Identifiable {
    let id: HealthLinkID
    let title: String
    let stateWord: String
    let tone: HealthTone
    /// A path or a sentence under the state word.
    let detail: String?
    let detailIsPath: Bool
    let parts: [HealthPart]

    var symbol: String {
        switch tone {
        case .positive: return "checkmark.circle.fill"
        case .negative: return "xmark.circle.fill"
        case .pending: return "ellipsis.circle"
        case .caution: return "exclamationmark.triangle.fill"
        }
    }
}

enum HealthVerdict: Equatable {
    case ready
    case agentNotConfigured
    case agentNotFound
    case agentNotUsable
    case pythonMissing
    case prepareAndRunNeedSetup
    case prepareNeedsSetup
    case runNeedsSetup
    case runtimeNeedsSetup

    var text: String {
        switch self {
        case .ready: return "Ready to prepare and run"
        case .agentNotConfigured: return "mlx-agent isn't configured"
        case .agentNotFound: return "mlx-agent wasn't found"
        case .agentNotUsable: return "mlx-agent can't be used"
        case .pythonMissing: return "Python wasn't found"
        case .prepareAndRunNeedSetup: return "Prepare and Run need setup"
        case .prepareNeedsSetup: return "Prepare needs setup"
        case .runNeedsSetup: return "Run needs setup"
        case .runtimeNeedsSetup: return "The runtime needs setup"
        }
    }

    var isReady: Bool { self == .ready }

    var symbol: String { isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill" }
}

/// Which resolving controls the hero offers. The runtime installer brings its own prominent button.
struct HealthActions: Equatable {
    let showsInstall: Bool
    let showsInstallCommand: Bool
    let showsOpenSettings: Bool
    let openSettingsIsProminent: Bool

    var prominentCount: Int { (showsInstall ? 1 : 0) + (openSettingsIsProminent ? 1 : 0) }
}

struct HealthChain: Equatable {
    let verdict: HealthVerdict
    /// mlx-agent, then Python.
    let foundation: [HealthLink]
    /// Prepare and Run, siblings that both depend on the foundation.
    let capabilities: [HealthLink]
    let environment: String
    let actions: HealthActions

    var links: [HealthLink] { foundation + capabilities }
}

enum HealthPresentation {
    /// The parts of Prepare and Run in the order the runtime probe declares them.
    static let prepareParts = ["torch", "transformers", "gguf", "accelerate", "mlx_lm.convert"]
    static let runParts = ["mlx_lm.server"]

    static func chain(
        agent: AgentHealth,
        report: RuntimeReport,
        fingerprint: EnvironmentFingerprint,
        installAvailable: Bool
    ) -> HealthChain {
        let agentReady: Bool
        if case .ready = agent { agentReady = true } else { agentReady = false }
        // Without an interpreter no probe could run; an inconsistent ready report is trusted.
        let pythonBlocks = report.python == nil && !report.ok

        let gate: Gate = !agentReady ? .agent : (pythonBlocks ? .python : .open)
        let prepare = capabilityLink(
            .prepare, title: "Prepare", gate: gate, ok: report.convert.ok,
            missing: report.convert.missingModules.count + report.convert.missingExecutables.count,
            parts: prepareParts.map { name in
                HealthPart(name: name, isPresent: report.convert.modules[name] ?? report.convert.executables[name] ?? false)
            }
        )
        let run = capabilityLink(
            .run, title: "Run", gate: gate, ok: report.serve.ok,
            missing: report.serve.missingExecutables.count,
            parts: runParts.map { HealthPart(name: $0, isPresent: report.serve.executables[$0] ?? false) }
        )
        let showsInstall = !report.ok && installAvailable
        return HealthChain(
            verdict: verdict(agent: agent, report: report),
            foundation: [agentLink(agent), pythonLink(report.python)],
            capabilities: [prepare, run],
            environment: environmentLine(fingerprint),
            actions: HealthActions(
                showsInstall: showsInstall,
                showsInstallCommand: !report.ok,
                showsOpenSettings: !agentReady,
                openSettingsIsProminent: !agentReady && !showsInstall
            )
        )
    }

    private enum Gate { case agent, python, open }

    static func verdict(agent: AgentHealth, report: RuntimeReport) -> HealthVerdict {
        switch agent {
        case .notConfigured: return .agentNotConfigured
        case .notFound: return .agentNotFound
        case .notUsable: return .agentNotUsable
        case .ready:
            if report.ok { return .ready }
            if report.python == nil { return .pythonMissing }
            switch (report.convert.ok, report.serve.ok) {
            case (false, false): return .prepareAndRunNeedSetup
            case (false, true): return .prepareNeedsSetup
            case (true, false): return .runNeedsSetup
            case (true, true): return .runtimeNeedsSetup
            }
        }
    }

    private static func agentLink(_ agent: AgentHealth) -> HealthLink {
        switch agent {
        case .ready(let path, _):
            return HealthLink(id: .agent, title: "mlx-agent", stateWord: "Found", tone: .positive, detail: path, detailIsPath: true, parts: [])
        case .notConfigured:
            return HealthLink(id: .agent, title: "mlx-agent", stateWord: "Not configured", tone: .negative, detail: "Set the checkout path in Settings.", detailIsPath: false, parts: [])
        case .notFound(let path, _):
            return HealthLink(id: .agent, title: "mlx-agent", stateWord: "Not found", tone: .negative, detail: path, detailIsPath: true, parts: [])
        case .notUsable(_, _, let reason):
            return HealthLink(id: .agent, title: "mlx-agent", stateWord: "Can't be used", tone: .negative, detail: reason, detailIsPath: false, parts: [])
        }
    }

    private static func pythonLink(_ python: String?) -> HealthLink {
        if let python {
            return HealthLink(id: .python, title: "Python", stateWord: "Found", tone: .positive, detail: python, detailIsPath: true, parts: [])
        }
        return HealthLink(id: .python, title: "Python", stateWord: "Not found", tone: .negative, detail: "No interpreter was resolved.", detailIsPath: false, parts: [])
    }

    private static func capabilityLink(
        _ id: HealthLinkID, title: String, gate: Gate, ok: Bool, missing: Int, parts: [HealthPart]
    ) -> HealthLink {
        let word: String
        let tone: HealthTone
        switch gate {
        case .agent: (word, tone) = ("Waiting on mlx-agent", .pending)
        case .python: (word, tone) = ("Waiting on Python", .pending)
        case .open:
            if ok { (word, tone) = ("Ready", .positive) }
            else if missing > 0 { (word, tone) = ("Missing \(missing)", .negative) }
            else { (word, tone) = ("Needs setup", .negative) }
        }
        return HealthLink(id: id, title: title, stateWord: word, tone: tone, detail: nil, detailIsPath: false, parts: parts)
    }

    /// macOS, chip and mlx-lm; a part that could not be read says so.
    static func environmentLine(_ fingerprint: EnvironmentFingerprint) -> String {
        [
            fingerprint.macOSVersion == "unknown" ? "macOS unknown" : "macOS \(fingerprint.macOSVersion)",
            fingerprint.chip == "unknown" ? "chip unknown" : fingerprint.chip,
            fingerprint.mlxLMVersion.map { "mlx-lm \($0)" } ?? "mlx-lm unknown",
        ].joined(separator: " · ")
    }
}

// MARK: - Environment evidence

/// How many verified models were verified under the current environment.
struct EnvironmentEvidence: Equatable {
    enum Status: Equatable {
        /// The fingerprint has an unread part; nothing is classified against it.
        case pending
        case noVerifiedModels
        case counted(current: Int, earlier: Int, unrecorded: Int)
    }

    static let pendingText = "Environment check pending"
    static let emptyText = "No verified models yet"
    static let reviewTitle = "Review on Overview"

    let parts: String
    let status: Status

    var currentText: String? {
        guard case .counted(let current, _, _) = status else { return nil }
        return current == 1 ? "verified model matches this environment" : "verified models match this environment"
    }

    var earlierText: String? {
        guard case .counted(_, let earlier, _) = status, earlier > 0 else { return nil }
        return "verified under an earlier macOS or mlx-lm"
    }

    var unrecordedHelp: String? {
        guard case .counted(_, _, let unrecorded) = status, unrecorded > 0 else { return nil }
        return unrecorded == 1
            ? "1 verified model has no recorded environment"
            : "\(unrecorded) verified models have no recorded environment"
    }

    /// The latest passed report per model, compared with the current fingerprint.
    static func make(reports: [VerificationReport], fingerprint: EnvironmentFingerprint) -> EnvironmentEvidence {
        let parts = HealthPresentation.environmentLine(fingerprint)
        let isWhole = fingerprint.mlxLMVersion != nil && fingerprint.macOSVersion != "unknown" && fingerprint.chip != "unknown"
        guard isWhole else { return EnvironmentEvidence(parts: parts, status: .pending) }

        var latest: [String: VerificationReport] = [:]
        for report in reports where report.outcome == .passed {
            if let known = latest[report.modelPath], known.finishedAt >= report.finishedAt { continue }
            latest[report.modelPath] = report
        }
        guard !latest.isEmpty else { return EnvironmentEvidence(parts: parts, status: .noVerifiedModels) }

        let description = fingerprint.description
        var current = 0, earlier = 0, unrecorded = 0
        for report in latest.values {
            switch report.environmentFingerprint {
            case .none: unrecorded += 1
            case .some(let recorded): if recorded == description { current += 1 } else { earlier += 1 }
            }
        }
        return EnvironmentEvidence(parts: parts, status: .counted(current: current, earlier: earlier, unrecorded: unrecorded))
    }
}

// MARK: - Connector

struct HealthConnectorSegment: Equatable {
    let from: CGPoint
    let to: CGPoint
    /// Drawn in accent when the source side is ready, muted and dashed after a break.
    let isLive: Bool
}

enum HealthConnectorPlan {
    /// Segments in the container's coordinates. `icons` holds each link's symbol bounds;
    /// `slot` is the gap between the two columns (one row) or the two rows (two rows).
    /// Both capabilities depend on both foundations, and the capabilities never depend on each other.
    static func segments(
        mode: HealthLayout.ForkMode, links: [HealthLink], icons: [HealthLinkID: CGRect], slot: CGRect?
    ) -> [HealthConnectorSegment] {
        guard links.count == 4, links.allSatisfy({ icons[$0.id] != nil }) else { return [] }
        let positive = links.map { $0.tone == .positive }
        let rects = links.map { icons[$0.id]! }
        let foundationReady = positive[0] && positive[1]
        func segment(_ from: CGPoint, _ to: CGPoint, _ isLive: Bool) -> HealthConnectorSegment {
            HealthConnectorSegment(from: from, to: to, isLive: isLive)
        }
        switch mode {
        case .oneRow:
            guard let slot else { return [] }
            let x1 = slot.minX + slot.width / 3
            let x2 = slot.minX + slot.width * 2 / 3
            let inputs = [rects[0].midY, rects[1].midY]
            let outputs = [rects[2].midY, rects[3].midY]
            let trunk = (inputs[0] + inputs[1]) / 2
            let joined = outputs + [trunk]
            let outputEnd = { (rect: CGRect) in rect.minX - WorkbenchSpacing.xxs }
            return [
                segment(CGPoint(x: slot.minX, y: inputs[0]), CGPoint(x: x1, y: inputs[0]), positive[0]),
                segment(CGPoint(x: slot.minX, y: inputs[1]), CGPoint(x: x1, y: inputs[1]), positive[1]),
                segment(CGPoint(x: x1, y: inputs.min()!), CGPoint(x: x1, y: inputs.max()!), foundationReady),
                segment(CGPoint(x: x1, y: trunk), CGPoint(x: x2, y: trunk), foundationReady),
                segment(CGPoint(x: x2, y: joined.min()!), CGPoint(x: x2, y: joined.max()!), foundationReady),
                segment(CGPoint(x: x2, y: outputs[0]), CGPoint(x: outputEnd(rects[2]), y: outputs[0]), foundationReady),
                segment(CGPoint(x: x2, y: outputs[1]), CGPoint(x: outputEnd(rects[3]), y: outputs[1]), foundationReady),
            ]
        case .twoRow:
            guard let slot else { return [] }
            let bus = slot.midY
            let columns = rects.map(\.midX)
            return [
                segment(CGPoint(x: columns[0], y: rects[0].maxY), CGPoint(x: columns[0], y: bus), positive[0]),
                segment(CGPoint(x: columns[1], y: rects[1].maxY), CGPoint(x: columns[1], y: bus), positive[1]),
                segment(CGPoint(x: columns.min()!, y: bus), CGPoint(x: columns.max()!, y: bus), foundationReady),
                segment(CGPoint(x: columns[2], y: bus), CGPoint(x: columns[2], y: rects[2].minY), foundationReady),
                segment(CGPoint(x: columns[3], y: bus), CGPoint(x: columns[3], y: rects[3].minY), foundationReady),
            ]
        case .stacked:
            let trunkX = rects[1].midX
            return [
                segment(CGPoint(x: rects[0].midX, y: rects[0].maxY), CGPoint(x: rects[1].midX, y: rects[1].minY), positive[0]),
                segment(CGPoint(x: trunkX, y: rects[1].maxY), CGPoint(x: trunkX, y: rects[3].midY), foundationReady),
                segment(CGPoint(x: trunkX, y: rects[2].midY), CGPoint(x: rects[2].minX, y: rects[2].midY), foundationReady),
                segment(CGPoint(x: trunkX, y: rects[3].midY), CGPoint(x: rects[3].minX, y: rects[3].midY), foundationReady),
            ]
        }
    }
}

// MARK: - Doctor

struct HealthFindingRow: Identifiable, Equatable {
    let id: String
    let title: String
    /// A full path, shown selectable.
    let detail: String?
    let remediation: String?
    let size: String?
}

struct HealthFindingGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let rows: [HealthFindingRow]
    /// The Reclaim hand-off; set on the incomplete-download group only.
    let prunableLine: String?

    var heading: String { "\(title) · \(rows.count)" }
}

enum HealthDoctor {
    private static let knownCodes = [
        "hf_cache_incomplete", "drift_missing_model", "drift_missing_file", "drift_hash_mismatch", "drift_endpoint_conflict",
    ]

    static func groupTitle(_ code: String?) -> String {
        switch code {
        case "hf_cache_incomplete": return "Incomplete download"
        case "drift_missing_model": return "Client config names a missing model"
        case "drift_missing_file": return "Wired file missing"
        case "drift_hash_mismatch": return "Wired file changed after wiring"
        case "drift_endpoint_conflict": return "Port claimed by two runtimes"
        case .some(let other): return humanized(other)
        case .none: return "Issue"
        }
    }

    static func groupSymbol(_ code: String?) -> String {
        switch code {
        case "hf_cache_incomplete": return "arrow.down.circle"
        case "drift_missing_model": return "questionmark.folder"
        case "drift_missing_file": return "doc.questionmark"
        case "drift_hash_mismatch": return "doc.badge.ellipsis"
        case "drift_endpoint_conflict": return "exclamationmark.arrow.triangle.2.circlepath"
        default: return "exclamationmark.triangle"
        }
    }

    static func humanized(_ code: String) -> String {
        let words = code.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return "Issue" }
        return first.uppercased() + words.dropFirst()
    }

    /// One row per finding, named by its code: a repo id, the missing model, or the file.
    static func row(_ finding: DoctorFinding, models: [LibraryModel], id: String) -> HealthFindingRow {
        let size = finding.size.map { ReclaimFormat.byteCount($0) }
        let remediation = finding.message
        switch finding.kind {
        case "hf_cache_incomplete":
            return HealthFindingRow(id: id, title: finding.model ?? finding.path, detail: nil, remediation: remediation, size: size)
        case "drift_missing_model":
            return HealthFindingRow(id: id, title: finding.model ?? "Unnamed model", detail: finding.path, remediation: remediation, size: size)
        default:
            let name = ReclaimNames.resolve(paths: [finding.path], models: models)
            return HealthFindingRow(id: id, title: name.title, detail: finding.path, remediation: remediation, size: size)
        }
    }

    /// Known codes in a fixed order, then any other code in the order the agent reported it.
    /// The incomplete-download group also carries the prunable line, and exists whenever something is prunable.
    static func groups(findings: [DoctorFinding], prunableCount: Int, models: [LibraryModel]) -> [HealthFindingGroup] {
        var order = knownCodes
        for finding in findings {
            let code = finding.kind ?? ""
            if !order.contains(code) { order.append(code) }
        }
        return order.compactMap { code in
            let members = findings.filter { ($0.kind ?? "") == code }
            let hostsPrunable = code == DoctorFinding.incompleteDownloadCode && prunableCount > 0
            guard !members.isEmpty || hostsPrunable else { return nil }
            let rows = members.enumerated().map { row($1, models: models, id: "\(code)-\($0)") }
            return HealthFindingGroup(
                id: code,
                title: groupTitle(code.isEmpty ? nil : code),
                symbol: groupSymbol(code),
                rows: rows,
                prunableLine: hostsPrunable ? prunableText(prunableCount) : nil
            )
        }
    }

    static func prunableText(_ count: Int) -> String {
        "\(ReclaimFormat.count(count, "incomplete download")) can be removed in Reclaim"
    }

    /// What a clean run covered; empty when the report carried no summary.
    static func cleanLines(_ summary: DoctorSummary?) -> [String] {
        guard let summary else { return [] }
        var lines: [String] = []
        if let models = summary.models {
            lines.append("\(ReclaimFormat.count(models, "model")) checked across the Hugging Face cache and running local servers")
        }
        if let bytes = summary.hfCacheBytes {
            lines.append("\(ReclaimFormat.byteCount(bytes)) in the default Hugging Face cache")
        }
        return lines
    }

    static func checkedText(_ date: Date, now: Date = Date()) -> String {
        "Checked " + WorkbenchRelativeTime.text(for: date, style: .full, now: now)
    }

    static func tone(_ state: DoctorCheckState) -> HealthTone {
        switch state {
        case .notRun, .running: return .pending
        case .failed: return .negative
        case .completed: return state.isClean ? .positive : .caution
        }
    }
}
