import Foundation

// MARK: - Rows

/// One training job as the list draws it; the agent's state string maps to a
/// status and unknown states keep their own wording.
struct TrainingJobRow: Equatable, Identifiable {
    let id: String
    let repo: String
    let outputPath: String
    let status: WorkbenchStatus
    let pid: Int
    let logPath: String?
    let adapterIdentity: LabValue?
    let canCompare: Bool
    let canCancel: Bool

    init(job: TrainingJob, home: String?) {
        id = job.id
        repo = job.repo
        outputPath = TrainingPresentation.abbreviated(job.out, home: home)
        status = WorkbenchStatus(rawValue: job.state)
        pid = job.pid
        logPath = job.logPath
        adapterIdentity = job.adapterIdentity
        canCompare = job.state == "done" && job.adapterIdentity != nil
        canCancel = job.state == "running"
    }
}

/// One retained evaluation: a short id and when it was created.
struct TrainingEvaluationRow: Equatable, Identifiable {
    let id: String
    let shortID: String
    let dateText: String?

    init?(value: LabValue, now: Date) {
        guard let record = value.object, let identity = record["id"]?.text else { return nil }
        id = identity
        shortID = String(identity.prefix(TrainingPresentation.shortIDLength))
        dateText = record["created_at"]?.text.map { TrainingPresentation.dateText($0, now: now) }
    }
}

// MARK: - Presentation

struct TrainingPresentation: Equatable {
    static let shortIDLength = 8
    static let noJobsSentence = "No training jobs yet. Preview and confirm a fine-tune to start one."
    static let noEvaluationsSentence = "No retained evaluations yet. Compare a finished adapter with its base model to keep one."

    let jobs: [TrainingJobRow]
    let evaluations: [TrainingEvaluationRow]

    var showsNoJobs: Bool { jobs.isEmpty }
    var showsNoEvaluations: Bool { evaluations.isEmpty }

    static func make(jobs: [TrainingJob], evaluations: [LabValue], home: String? = NSHomeDirectory(), now: Date = Date()) -> TrainingPresentation {
        TrainingPresentation(
            jobs: jobs.map { TrainingJobRow(job: $0, home: home) },
            evaluations: evaluations.compactMap { TrainingEvaluationRow(value: $0, now: now) }
        )
    }

    /// The home directory collapses to `~`; any other path is unchanged.
    static func abbreviated(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
    }

    /// A parseable timestamp reads relative to `now`; anything else keeps its own text.
    static func dateText(_ raw: String, now: Date) -> String {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = plain.date(from: raw) ?? fractional.date(from: raw) else { return raw }
        return WorkbenchRelativeTime.text(for: date, style: .full, now: now)
    }
}

// MARK: - Loader

/// Loads jobs and evaluation history independently, so one failing request
/// never discards what the other returned.
@MainActor
final class TrainingLoader: ObservableObject {
    @Published private(set) var jobs: [TrainingJob] = []
    @Published private(set) var evaluations: [LabValue] = []
    @Published private(set) var jobsError: String?
    @Published private(set) var historyError: String?
    private let loadJobs: () async throws -> [TrainingJob]
    private let loadHistory: () async throws -> [LabValue]
    private let render: @MainActor (Error) -> String

    init(
        jobs: @escaping () async throws -> [TrainingJob],
        history: @escaping () async throws -> [LabValue],
        render: @escaping @MainActor (Error) -> String = { AppHost.render($0) },
        seededJobs: [TrainingJob] = [],
        seededEvaluations: [LabValue] = []
    ) {
        loadJobs = jobs
        loadHistory = history
        self.render = render
        self.jobs = seededJobs
        self.evaluations = seededEvaluations
    }

    func refresh() async {
        do {
            jobs = try await loadJobs()
            jobsError = nil
        } catch {
            jobsError = render(error)
        }
        do {
            evaluations = try await loadHistory()
            historyError = nil
        } catch {
            historyError = render(error)
        }
    }
}
