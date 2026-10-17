import Foundation

struct TrainingInspection: Decodable, Equatable, Sendable {
    struct Check: Decodable, Equatable, Sendable, Identifiable {
        enum ID: String, Decodable, Hashable, Sendable { case runtime, base, train, valid }
        enum Status: String, Decodable, Sendable { case ready, blocked }
        let id: ID
        let status: Status
        let message: String
        let remediation: String?
        let code: String?
        let examples: Int?
        let sha256: String?
        let path: String?

        var title: String {
            switch id {
            case .runtime: return "Training runtime"
            case .base: return "Cached base model"
            case .train: return "train.jsonl"
            case .valid: return "valid.jsonl"
            }
        }

        var repairField: TrainingField? {
            guard status == .blocked else { return nil }
            if id == .base { return .repo }
            if code == "dataset_too_small" { return .batchSize }
            return id == .train || id == .valid ? .data : nil
        }
    }

    let ready: Bool
    let repo: String?
    let data: String?
    let batchSize: Int
    let checks: [Check]

    private enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", ready, repo, data, batchSize = "batch_size", checks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(Int.self, forKey: .schemaVersion)
        ready = try container.decode(Bool.self, forKey: .ready)
        repo = try container.decodeIfPresent(String.self, forKey: .repo)
        data = try container.decodeIfPresent(String.self, forKey: .data)
        batchSize = try container.decode(Int.self, forKey: .batchSize)
        checks = try container.decode([Check].self, forKey: .checks)
        guard schema == 1, (1...64).contains(batchSize), checks.count == 4,
              Set(checks.map(\.id)) == Set([Check.ID.runtime, .base, .train, .valid]),
              ready == checks.allSatisfy({ $0.status == .ready }) else {
            throw DecodingError.dataCorruptedError(forKey: .checks, in: container, debugDescription: "Incomplete or inconsistent training inspection.")
        }
    }

    func matches(_ draft: TrainingDraft) -> Bool {
        (repo ?? "") == draft.repo.trimmingCharacters(in: .whitespacesAndNewlines)
            && (data ?? "") == draft.data.trimmingCharacters(in: .whitespacesAndNewlines)
            && batchSize == Int(draft.batchSize.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Captured plan fields only; older previews do not acquire inferred defaults.
struct TrainingPlanSummary: Equatable {
    let outputPath: String?
    let basePath: String?
    let baseMissing: Bool
    let trainingExamples: Int?
    let validationExamples: Int?
    let batchSize: Int?

    var blockingReason: String? {
        if baseMissing { return "The base model was not found in the local Hugging Face cache. Cache it, then preview again before confirming training." }
        if validationExamples == 0 { return "Training requires a nonempty valid.jsonl validation set. Add validation examples and preview again." }
        if let batchSize {
            if batchSize < 1 || batchSize > 64 { return "The preview reported an invalid batch size. Correct it and preview again." }
            if let trainingExamples, trainingExamples < batchSize { return "train.jsonl has fewer examples than the batch size. Reduce batch size or add examples, then preview again." }
            if let validationExamples, validationExamples < batchSize { return "valid.jsonl has fewer examples than the batch size. Reduce batch size or add examples, then preview again." }
        }
        return nil
    }

    init(payload: [String: Any]) {
        let plan = WorkbenchAPI.unwrapPlan(payload)
        func nonempty(_ value: Any?) -> String? {
            guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        func count(_ value: Any?) -> Int? {
            guard let count = value as? Int, count >= 0 else { return nil }
            return count
        }
        outputPath = nonempty(plan["out"])
        basePath = nonempty((plan["base_identity"] as? [String: Any])?["path"])
        baseMissing = plan["base_identity"] is NSNull
        let dataset = plan["dataset"] as? [String: Any]
        trainingExamples = count(dataset?["train_lines"])
        validationExamples = count(dataset?["valid_lines"])
        batchSize = count(plan["batch_size"])
    }
}

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
    let title: String?
    let promptCount: Int?

    init?(value: LabValue, now: Date) {
        guard let record = value.object, let identity = record["id"]?.text else { return nil }
        id = identity
        shortID = String(identity.prefix(TrainingPresentation.shortIDLength))
        dateText = record["created_at"]?.text.map { TrainingPresentation.dateText($0, now: now) }
        title = record["suite_name"]?.text
        if let count = record["prompt_count"]?.decimal, count.rounded() == count, count >= 1, count <= 16 {
            promptCount = Int(count)
        } else { promptCount = nil }
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
    let jobsLoading: Bool
    let historyLoading: Bool
    let jobsLoaded: Bool
    let historyLoaded: Bool

    var showsNoJobs: Bool { jobs.isEmpty && jobsError == nil && jobsLoaded && !jobsLoading }
    var showsNoEvaluations: Bool { evaluations.isEmpty && historyError == nil && historyLoaded && !historyLoading }

    static func make(
        jobs: [TrainingJob], evaluations: [LabValue], jobsError: String? = nil, historyError: String? = nil,
        home: String? = NSHomeDirectory(), now: Date = Date(),
        jobsLoading: Bool = false, historyLoading: Bool = false,
        jobsLoaded: Bool = true, historyLoaded: Bool = true
    ) -> TrainingPresentation {
        TrainingPresentation(
            jobs: jobs.map { TrainingJobRow(job: $0, home: home) },
            evaluations: evaluations.compactMap { TrainingEvaluationRow(value: $0, now: now) },
            jobsError: jobsError,
            historyError: historyError,
            jobsLoading: jobsLoading, historyLoading: historyLoading,
            jobsLoaded: jobsLoaded, historyLoaded: historyLoaded
        )
    }

    /// Known language models and legacy untyped cache entries are candidates;
    /// the engine's preview checks the actual MLX-LM architecture registry.
    static func baseModels(_ snapshot: LibrarySnapshot?) -> [String] {
        var identities: Set<String> = []
        for model in snapshot?.models ?? [] {
            guard model.item.draft == nil else { continue }
            if let type = model.item.task?.type, type != .textLLM && type != .visionLanguage { continue }
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

    func showsField(repo: String, cached: [String]) -> Bool { choosesCustom || !cached.contains(repo) }

    func selection(repo: String, cached: [String]) -> String {
        !choosesCustom && cached.contains(repo) ? repo : ""
    }

    /// The repo id the draft takes after a pick; the custom choice clears it.
    mutating func select(_ identity: String) -> String {
        choosesCustom = identity.isEmpty
        return identity
    }

    mutating func edit(_ identity: String) -> String {
        choosesCustom = true
        return identity
    }
}

// MARK: - Loader

enum TrainingCollectionPhase: Equatable { case loading, empty, populated, failed }

/// Independent collection reads retain prior rows. UI refresh entry points
/// lock duplicates; the existing refresh API can supersede older reads.
@MainActor
final class TrainingLoader: ObservableObject {
    struct Inspection {
        let recordID: String
        let response: LabResponse
        let workspace: LabWorkspaceContext?
    }

    @Published private(set) var jobs: [TrainingJob] = []
    @Published private(set) var evaluations: [LabValue] = []
    @Published private(set) var jobsError: String?
    @Published private(set) var historyError: String?
    @Published private(set) var isLoadingJobs = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var hasLoadedJobs = false
    @Published private(set) var hasLoadedHistory = false
    @Published private(set) var inspection: Inspection?
    @Published private(set) var inspectingID: String?
    @Published private(set) var inspectionError: String?
    @Published private(set) var workspace: LabWorkspaceContext?
    private let loadJobs: () async throws -> [TrainingJob]
    private var loadHistory: () async throws -> [LabValue]
    private var loadInspection: ((String) async throws -> LabResponse)?
    private let render: @MainActor (Error) -> String
    private var jobsGeneration = 0
    private var historyGeneration = 0
    private var inspectionGeneration = 0

    init(
        jobs: @escaping () async throws -> [TrainingJob],
        history: @escaping () async throws -> [LabValue],
        render: @escaping @MainActor (Error) -> String = { AppHost.render($0) },
        seededJobs: [TrainingJob] = [],
        seededEvaluations: [LabValue] = [],
        inspect: ((String) async throws -> LabResponse)? = nil,
        workspace: LabWorkspaceContext? = nil
    ) {
        loadJobs = jobs
        loadHistory = history
        loadInspection = inspect
        self.render = render
        self.jobs = seededJobs
        self.evaluations = seededEvaluations
        self.workspace = workspace
        hasLoadedJobs = !seededJobs.isEmpty
        hasLoadedHistory = !seededEvaluations.isEmpty
    }

    /// Evaluations belong to the experiment workspace; training jobs do not.
    @discardableResult
    func bindWorkspace(_ context: LabWorkspaceContext,
                       history: @escaping () async throws -> [LabValue],
                       inspect: @escaping (String) async throws -> LabResponse) -> Bool {
        guard workspace != context else { return false }
        historyGeneration += 1
        inspectionGeneration += 1
        loadHistory = history
        loadInspection = inspect
        workspace = context
        evaluations = []
        historyError = nil
        isLoadingHistory = false
        hasLoadedHistory = false
        inspection = nil
        inspectingID = nil
        inspectionError = nil
        return true
    }

    var jobsPhase: TrainingCollectionPhase {
        phase(populated: !jobs.isEmpty, loading: isLoadingJobs, loaded: hasLoadedJobs, error: jobsError)
    }

    var historyPhase: TrainingCollectionPhase {
        phase(populated: !evaluations.isEmpty, loading: isLoadingHistory, loaded: hasLoadedHistory, error: historyError)
    }

    private func phase(populated: Bool, loading: Bool, loaded: Bool, error: String?) -> TrainingCollectionPhase {
        if populated { return .populated }
        if loading || (!loaded && error == nil) { return .loading }
        if error != nil { return .failed }
        return .empty
    }

    /// Preserves the established API: a newer refresh supersedes older results.
    func refresh() async {
        let jobsTask = startJobs(superseding: true)
        let historyTask = startHistory(superseding: true)
        await jobsTask?.value
        await historyTask?.value
    }

    /// UI refreshes respect the independent synchronous locks.
    func refreshIfIdle() async {
        let jobsTask = refreshJobs()
        let historyTask = refreshHistory()
        await jobsTask?.value
        await historyTask?.value
    }

    @discardableResult
    func refreshJobs() -> Task<Void, Never>? { startJobs(superseding: false) }

    @discardableResult
    func refreshHistory() -> Task<Void, Never>? { startHistory(superseding: false) }

    private func startJobs(superseding: Bool) -> Task<Void, Never>? {
        guard superseding || !isLoadingJobs else { return nil }
        jobsGeneration += 1
        let current = jobsGeneration
        isLoadingJobs = true
        jobsError = nil
        return Task {
            defer { if current == jobsGeneration { isLoadingJobs = false } }
            do {
                let loaded = try await loadJobs()
                guard current == jobsGeneration else { return }
                jobs = loaded
                hasLoadedJobs = true
            } catch {
                guard current == jobsGeneration else { return }
                jobsError = render(error)
            }
        }
    }

    private func startHistory(superseding: Bool) -> Task<Void, Never>? {
        guard superseding || !isLoadingHistory else { return nil }
        historyGeneration += 1
        let current = historyGeneration
        let loadHistory = loadHistory
        isLoadingHistory = true
        historyError = nil
        return Task {
            defer { if current == historyGeneration { isLoadingHistory = false } }
            do {
                let loaded = try await loadHistory()
                guard current == historyGeneration else { return }
                evaluations = loaded
                hasLoadedHistory = true
            } catch {
                guard current == historyGeneration else { return }
                historyError = render(error)
            }
        }
    }

    @discardableResult
    func inspect(_ recordID: String) -> Task<Void, Never>? {
        guard inspectingID == nil, let loadInspection else { return nil }
        inspectionGeneration += 1
        let current = inspectionGeneration
        let workspace = workspace
        inspectingID = recordID
        inspectionError = nil
        return Task {
            defer { if current == inspectionGeneration { inspectingID = nil } }
            do {
                let response = try await loadInspection(recordID)
                guard current == inspectionGeneration else { return }
                if response.report != nil { inspection = Inspection(recordID: recordID, response: response, workspace: workspace) }
            } catch {
                guard current == inspectionGeneration else { return }
                inspectionError = "Could not inspect \(recordID): \(render(error))"
            }
        }
    }
}
