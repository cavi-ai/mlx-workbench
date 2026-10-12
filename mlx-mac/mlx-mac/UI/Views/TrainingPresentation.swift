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
        status = job.state == "done" ? .succeeded : WorkbenchStatus(rawValue: job.state)
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

    static let jobsFailureSentence = "Training jobs couldn't load."
    static let evaluationsFailureSentence = "Evaluations couldn't load."

    let jobs: [TrainingJobRow]
    let evaluations: [TrainingEvaluationRow]
    let jobsError: String?
    let historyError: String?

    var showsNoJobs: Bool { jobs.isEmpty && jobsError == nil }
    var showsNoEvaluations: Bool { evaluations.isEmpty && historyError == nil }

    static func make(
        jobs: [TrainingJob], evaluations: [LabValue], jobsError: String? = nil, historyError: String? = nil,
        home: String? = NSHomeDirectory(), now: Date = Date()
    ) -> TrainingPresentation {
        TrainingPresentation(
            jobs: jobs.map { TrainingJobRow(job: $0, home: home) },
            evaluations: evaluations.compactMap { TrainingEvaluationRow(value: $0, now: now) },
            jobsError: jobsError,
            historyError: historyError
        )
    }

    /// Hugging Face repo ids of the Library's cached models, sorted, so a base model can be picked instead of typed.
    static func baseModels(_ snapshot: LibrarySnapshot?) -> [String] {
        var identities: Set<String> = []
        for model in snapshot?.models ?? [] {
            for path in [model.item.path] + model.outputPaths {
                if let repoID = HFRepoID.forPath(path) {
                    identities.insert(repoID)
                }
            }
        }
        return identities.sorted()
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

// MARK: - Base model choice

/// Whether the base model comes from the cached list or the typed field; typing never hides the field.
struct TrainingBaseModelChoice: Equatable {
    private(set) var choosesCustom = true

    func showsField(cached: [String]) -> Bool { cached.isEmpty || choosesCustom }

    func selection(repo: String, cached: [String]) -> String {
        !choosesCustom && cached.contains(repo) ? repo : ""
    }

    /// The repo id the draft takes after a pick; the custom choice clears it.
    mutating func select(_ identity: String) -> String {
        choosesCustom = identity.isEmpty
        return identity
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
    private var generation = 0

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

    /// Both requests run at once and publish independently; a refresh started later supersedes an earlier one still in flight.
    func refresh() async {
        generation += 1
        let current = generation
        async let jobsDone: Void = refreshJobs(current)
        async let historyDone: Void = refreshHistory(current)
        _ = await (jobsDone, historyDone)
    }

    private func refreshJobs(_ current: Int) async {
        do {
            let loaded = try await loadJobs()
            guard current == generation else { return }
            jobs = loaded
            jobsError = nil
        } catch {
            guard current == generation else { return }
            jobsError = render(error)
        }
    }

    private func refreshHistory(_ current: Int) async {
        do {
            let loaded = try await loadHistory()
            guard current == generation else { return }
            evaluations = loaded
            historyError = nil
        } catch {
            guard current == generation else { return }
            historyError = render(error)
        }
    }
}
