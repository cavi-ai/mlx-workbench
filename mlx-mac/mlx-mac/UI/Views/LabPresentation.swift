import Foundation

// MARK: - Rows

/// One controlled experiment as the list draws it.
struct LabExperimentRow: Equatable, Identifiable {
    let id: String
    let title: String
    let status: WorkbenchStatus?
    let evidenceTag: String
    let reviewed: Bool
    let canReview: Bool

    init(item: LabHistoryItem) {
        id = item.id
        title = "Experiment " + LabPresentation.shortID(item.id)
        status = item.states.isEmpty ? nil : LabPresentation.aggregateStatus(item.states)
        reviewed = !item.sealed
        evidenceTag = item.states.isEmpty ? "No jobs yet" : (item.sealed ? "Identity sealed" : "Reviewed")
        canReview = !item.states.isEmpty && item.states.allSatisfy { $0 == "completed" }
    }
}

/// One queued or finished job; unknown states keep their own wording.
struct LabJobRow: Equatable, Identifiable {
    let id: String
    let shortID: String
    let status: WorkbenchStatus
    let canRun: Bool
    let canCancel: Bool
    let failure: String?

    init(job: LabJob) {
        id = job.id
        shortID = LabPresentation.shortID(job.id)
        status = LabPresentation.status(for: job.state)
        canRun = job.state == "queued"
        canCancel = !LabPresentation.finishedJobStates.contains(job.state)
        failure = job.error.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A labelled figure from a study's progress record.
struct LabProgressItem: Equatable {
    let label: String
    let value: String
}

enum LabStudyAction: Equatable {
    case resume, generate, review(session: String), none
}

/// One adaptive guidance study.
struct LabStudyRow: Equatable, Identifiable {
    let id: String
    let shortID: String
    let status: WorkbenchStatus?
    let progress: [LabProgressItem]
    let action: LabStudyAction
    let prompt: String
    let retainsEvidence: Bool
    let rawText: String

    init?(value: LabValue) {
        guard let item = value.object, let identity = item["study_id"]?.text else { return nil }
        id = identity
        shortID = LabPresentation.shortID(identity)
        status = item["state"]?.text.flatMap { $0.isEmpty ? nil : LabPresentation.status(for: $0) }
        progress = LabPresentation.progressItems(item["progress"])
        prompt = item["prompt"]?.text ?? ""
        let next = item["next_action"]?.text ?? "none"
        switch next {
        case "resume": action = .resume
        case "complete_generation": action = .generate
        case "record_preference":
            action = item["review_id"]?.text.map { .review(session: $0) } ?? .none
        default: action = .none
        }
        retainsEvidence = next == "none"
        rawText = value.jsonText
    }
}

// MARK: - Presentation

enum LabPresentation {
    static let shortIDLength = 8
    static let finishedJobStates: Set<String> = ["completed", "failed", "cancelled"]
    static let emptySentence = "No controlled experiments in this workspace. New experiment… captures or imports a recipe; generation starts only when you run its queued jobs."
    static let maxProgressItems = 4

    /// The part of an engine id after its kind prefix, cut to a readable length.
    static func shortID(_ id: String) -> String {
        let body = id.split(separator: "_", maxSplits: 1).dropFirst().first.map(String.init) ?? id
        return String(body.prefix(shortIDLength))
    }

    /// The badge for one engine state; states the app does not know keep the engine's own wording.
    static func status(for state: String) -> WorkbenchStatus {
        switch state {
        case "completed": return .succeeded
        case "failed": return .failure
        case "running": return .running
        case "queued": return .queued
        case "cancelled": return WorkbenchStatus(rawValue: state)
        default: return .verbatim(state)
        }
    }

    /// Any failure fails the experiment; a running job keeps it live; a mixed set reads as its states.
    static func aggregateStatus(_ states: [String]) -> WorkbenchStatus {
        guard !states.isEmpty else { return .unknown }
        if states.contains("failed") { return .failure }
        if states.allSatisfy({ $0 == "completed" }) { return .succeeded }
        if states.contains("running") { return .running }
        var unique: [String] = []
        for state in states where !unique.contains(state) { unique.append(state) }
        if unique.count == 1 { return status(for: unique[0]) }
        return .verbatim(unique.map { status(for: $0).label }.joined(separator: " · "))
    }

    /// A baseline or alternate value as one line; structured values point at the manifests.
    static func revealValue(_ value: LabValue?) -> String {
        guard let value else { return "" }
        return scalarText(value) ?? "see Frozen manifests"
    }

    /// Scalar progress entries as label and value; nested values stay in the raw record.
    static func progressItems(_ progress: LabValue?) -> [LabProgressItem] {
        guard let progress else { return [] }
        guard let fields = progress.object else {
            return scalarText(progress).map { [LabProgressItem(label: "Progress", value: $0)] } ?? []
        }
        let items: [LabProgressItem] = fields.keys.sorted().compactMap { key in
            guard let value = fields[key].flatMap(scalarText) else { return nil }
            return LabProgressItem(label: label(forKey: key), value: value)
        }
        return Array(items.prefix(maxProgressItems))
    }

    private static func label(forKey key: String) -> String {
        let words = key.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static func scalarText(_ value: LabValue) -> String? {
        switch value {
        case .integer(let number): return String(number)
        case .number(let number): return number.formatted(.number.precision(.fractionLength(0...2)))
        case .string(let text): return text.isEmpty || text.count > 24 ? nil : text
        default: return nil
        }
    }

    /// The store path with the home directory collapsed to `~`.
    static func storePath(_ path: String, home: String? = NSHomeDirectory()) -> String {
        TrainingPresentation.abbreviated(path, home: home)
    }
}
