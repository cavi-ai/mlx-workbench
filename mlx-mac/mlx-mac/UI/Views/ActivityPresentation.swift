import CoreGraphics
import Foundation

// MARK: - Action titles

extension ActivityWorkflowAction {
    var title: String {
        switch self {
        case .openInLibrary: return "Open in Library"
        case .runModel: return "Run model"
        case .retryPreview: return "Retry preview"
        case .keepAnyway: return "Keep anyway (unverified)"
        }
    }
}

// MARK: - Formatting

enum ActivityFormat {
    /// An absolute date and time for details, never a relative one.
    static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Stage track

enum ActivityTrack {
    /// The track spoken as one element: where the run stopped, is working, or finished.
    static func label(for nodes: [FlightTrackNode]) -> String {
        if let failed = nodes.first(where: { $0.state == .failed }) { return "Stopped at \(failed.title)" }
        if let active = nodes.first(where: { $0.state == .active }) { return "In progress at \(active.title)" }
        if nodes.last?.state == .complete {
            return nodes.contains(where: \.isNotApplicable) ? "Ready, verification not applicable" : "Ready"
        }
        if let reached = nodes.last(where: { $0.state == .complete }) { return "Reached \(reached.title)" }
        return "Not started"
    }
}

// MARK: - Messages

enum ActivityMessageLine: Equatable {
    case failure(String)
    case note(String)
}

enum ActivityMessage {
    /// A message that only restates the state word ("Conversion failed." under "Failed").
    static func isGeneric(_ text: String, stateWord: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let restated = "conversion " + stateWord.lowercased()
        return normalized == restated || normalized == restated + "."
    }

    /// What a passing verification message adds beyond "Verified": nil when it is not one, "" when nothing.
    private static func passedVerificationDetail(_ message: String?) -> String? {
        guard var text = message?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix(VerificationOutcome.passedLead) else { return nil }
        text = String(text.dropFirst(VerificationOutcome.passedLead.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(VerificationOutcome.passedSummary) {
            text = String(text.dropFirst(VerificationOutcome.passedSummary.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " ·"))
        }
        return text
    }

    /// The one line a row shows under its detail lines; nil when the state word already says it.
    static func line(for workflow: ConversionWorkflow, stateWord: String) -> ActivityMessageLine? {
        func specific(_ text: String?) -> String? {
            guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  !isGeneric(text, stateWord: stateWord) else { return nil }
            for restated in [stateWord + ". ", "Conversion " + stateWord.lowercased() + "; "]
            where text.lowercased().hasPrefix(restated.lowercased()) {
                text = String(text.dropFirst(restated.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return text.isEmpty ? nil : text
        }
        if let error = specific(workflow.errorMessage) { return .failure(error) }
        if workflow.state == .verified, let detail = passedVerificationDetail(workflow.message) {
            return detail.isEmpty ? nil : .note(detail)
        }
        guard let message = specific(workflow.message) else { return nil }
        switch workflow.state {
        case .failed, .verificationFailed: return .failure(message)
        default: return .note(message)
        }
    }
}

// MARK: - Row

struct ActivityRowPresentation: Identifiable, Equatable {
    let card: ActivityWorkflowCardPresentation
    let name: String
    let quantization: String?
    let nodes: [FlightTrackNode]
    let trackLabel: String
    let primary: ActivityWorkflowAction?
    let overflow: [ActivityWorkflowAction]
    let line: ActivityMessageLine?
    let relativeTime: String
    let createdText: String
    let updatedText: String

    var id: UUID { card.id }
    var workflow: ConversionWorkflow { card.workflow }
    var stateWord: String { card.stateTitle }
    var isActive: Bool { card.isActive }
    var source: String? { workflow.sourcePath.isEmpty ? nil : workflow.sourcePath }
    var destination: String? { workflow.outputPath.isEmpty ? nil : workflow.outputPath }
    var receipt: String? { workflow.jobReceipt.flatMap { $0.isEmpty ? nil : $0 } }
    var agentState: String? { workflow.lastKnownAgentState.flatMap { $0.isEmpty ? nil : $0 } }
    var logPath: String? { card.logPath.flatMap { $0.isEmpty ? nil : $0 } }

    /// A failed row says in words where it stopped.
    var showsTrackCaption: Bool { workflow.state == .failed || workflow.state == .verificationFailed }
    /// A failed row with no message of its own offers its log inline.
    var showsInlineLog: Bool { showsTrackCaption && line == nil && logPath != nil }

    /// Every distinct stored message, including the ones the row suppresses as restating its state.
    var recordedMessages: [String] {
        var seen: [String] = []
        for text in [workflow.errorMessage, workflow.message] {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !seen.contains(text) else { continue }
            seen.append(text)
        }
        return seen
    }

    init(card: ActivityWorkflowCardPresentation, snapshot: LibrarySnapshot?, verification: VerificationStatus?, now: Date) {
        self.card = card
        let record = card.workflow
        let taskType = PrepareWorkflowPresentation(workflow: record).outputModel(in: snapshot)?.item.task?.type
        let presentation = PrepareWorkflowPresentation(workflow: record, taskType: taskType)
        let evidence = PrepareWorkflowPresentation.hasVerificationEvidence(state: record.state, status: verification)
        let nodes = presentation.stageNodes(hasVerificationEvidence: evidence)
        self.nodes = nodes
        trackLabel = ActivityTrack.label(for: nodes)
        let destinationName = URL(fileURLWithPath: record.outputPath).lastPathComponent
        name = [presentation.displayName, destinationName].first { !$0.isEmpty } ?? "Conversion"
        quantization = record.destinationBits.map { "\($0)-bit" }
        let primary = ActivityWorkflowAction.primary(among: card.actions)
        self.primary = primary
        overflow = card.actions.filter { $0 != primary }
        line = ActivityMessage.line(for: record, stateWord: card.stateTitle)
        relativeTime = WorkbenchRelativeTime.text(for: record.createdAt, style: .abbreviated, now: now)
        createdText = ActivityFormat.absolute(record.createdAt)
        updatedText = ActivityFormat.absolute(record.updatedAt)
    }
}

// MARK: - Page

struct ActivityGroup: Identifiable, Equatable {
    let day: Date
    let title: String
    let rows: [ActivityRowPresentation]
    var id: Date { day }
}

struct ActivityPage: Equatable {
    let inFlight: [ActivityRowPresentation]
    let groups: [ActivityGroup]

    var isEmpty: Bool { inFlight.isEmpty && groups.isEmpty }
}

enum ActivityTimeline {
    /// In-flight records first, then the rest grouped by the day they were created, newest first.
    /// Both the grouping and the relative time read `createdAt`; `updatedAt` is rewritten by
    /// status normalisation and never says when a conversion happened.
    static func page(
        cards: [ActivityWorkflowCardPresentation],
        snapshot: LibrarySnapshot?,
        verification: [UUID: VerificationStatus],
        now: Date,
        calendar: Calendar = .current
    ) -> ActivityPage {
        let rows = cards
            .sorted { ($0.workflow.createdAt, $0.workflow.updatedAt) > ($1.workflow.createdAt, $1.workflow.updatedAt) }
            .map { ActivityRowPresentation(card: $0, snapshot: snapshot, verification: verification[$0.id], now: now) }
        let inFlight = rows.filter(\.isActive)
        let settled = Dictionary(grouping: rows.filter { !$0.isActive }) { calendar.startOfDay(for: $0.workflow.createdAt) }
        let groups = settled.keys.sorted(by: >).map { day in
            ActivityGroup(day: day, title: title(forDay: day, now: now, calendar: calendar), rows: settled[day] ?? [])
        }
        return ActivityPage(inFlight: inFlight, groups: groups)
    }

    static func title(forDay day: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(day, equalTo: now, toGranularity: .year) ? "EEEMMMd" : "yMMMd")
        return formatter.string(from: day)
    }
}

// MARK: - Poll

enum ActivityPoll {
    static let interval: Duration = .seconds(2)

    /// The ids the poll is keyed to: it runs while any is in flight and restarts when the set changes.
    static func inFlightIDs(workflow: ConversionWorkflow, history: [ConversionWorkflow]) -> Set<UUID> {
        var ids = Set(history.filter { $0.state.isInFlight }.map(\.id))
        if workflow.state.isInFlight { ids.insert(workflow.id) }
        return ids
    }
}

// MARK: - Layout

/// Activity's width thresholds, derived from the width the page is offered, never from its content.
struct ActivityLayout: Equatable {
    /// The width inside a row: the page content width minus the row surface's insets.
    let rowWidth: CGFloat

    init(viewportWidth: CGFloat) {
        rowWidth = RunLayout(viewportWidth: viewportWidth).innerWidth + (WorkbenchSize.Run.surfaceChrome - WorkbenchSize.Activity.rowChrome)
    }

    /// A compact row flips back to wide only once the width clears the threshold by the hysteresis.
    static func isCompact(rowWidth: CGFloat, wasCompact: Bool) -> Bool {
        let threshold = WorkbenchSize.Activity.rowThreshold
        return rowWidth < (wasCompact ? threshold + WorkbenchSize.Library.tierHysteresis : threshold)
    }
}

// MARK: - Servers

struct ActivityServerRow: Identifiable, Equatable {
    let id: String
    let stateWord: String
    let isRunning: Bool
    let name: String
    let identity: String
    let endpoint: String
    /// "3 days ago", or the agent's raw timestamp when it does not parse.
    let startedText: String?
    let startedAbsolute: String?
    let pid: String?
    let receipt: String?
    let logPath: String?

    init(server: ServerInfo, index: Int, models: [LibraryModel], now: Date) {
        let word = RunStateWord.word(for: server)
        let identity = server.modelIdentity
        id = "\(index)-\(server.id)"
        stateWord = WorkbenchStatus(rawValue: word).label
        isRunning = server.state?.lowercased() == "running"
        name = RunModels.name(for: identity, model: RunModels.model(for: identity, in: models))
        self.identity = identity
        endpoint = server.port.map { RunFormat.endpoint(port: $0) } ?? "No port"
        if let raw = server.startedAt, !raw.isEmpty {
            if let date = ConversionProgressReader.date(fromAgentTimestamp: raw) {
                startedText = WorkbenchRelativeTime.text(for: date, style: .abbreviated, now: now)
                startedAbsolute = ActivityFormat.absolute(date)
            } else {
                startedText = raw
                startedAbsolute = nil
            }
        } else {
            startedText = nil
            startedAbsolute = nil
        }
        pid = server.pid.map { String($0) }
        receipt = server.receipt.flatMap { $0.isEmpty ? nil : $0 }
        logPath = server.logPath.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Running servers first, in the agent's order; every other server follows.
    static func split(_ servers: [ServerInfo], models: [LibraryModel], now: Date) -> (running: [ActivityServerRow], earlier: [ActivityServerRow]) {
        let rows = servers.enumerated().map { ActivityServerRow(server: $1, index: $0, models: models, now: now) }
        return (rows.filter(\.isRunning), rows.filter { !$0.isRunning })
    }
}
