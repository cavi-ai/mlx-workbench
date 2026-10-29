import Foundation

private struct ServeIntent: Equatable {
    let runtime: String
    let port: Int?
    let profile: ServingProfile?
    let m5Prefill: Bool
}

enum ModelWorkflowAPIUnavailable: LocalizedError {
    case repoConversion
    var errorDescription: String? { "Repository conversion is not available in this context." }
}

struct ModelWorkflowAPI {
    let convertPreview: (String, Int, String?) async throws -> [String: Any]
    let convertStart: (String, Int, String?, String) async throws -> [String: Any]
    let convertStatus: () async throws -> [Job]
    let servePreview: (String, String, Int?) async throws -> [String: Any]
    let serveStart: (String, String, Int?, String) async throws -> [String: Any]
    let serveStatus: () async throws -> [ServerInfo]
    let serveStop: (Int) async throws -> [String: Any]
    var profilePreview: (ServingProfile, Int?) async throws -> [String: Any] = { _, _ in throw WorkflowEvidenceError.invalid("Serving profiles are unavailable.") }
    var profileStart: (ServingProfile, Int?, String) async throws -> [String: Any] = { _, _, _ in throw WorkflowEvidenceError.invalid("Serving profiles are unavailable.") }
    var prefillPreview: (String, String, Int?) async throws -> [String: Any] = { _, _, _ in throw WorkflowEvidenceError.invalid("M5 prompt acceleration is unavailable.") }
    var prefillStart: (String, String, Int?, String) async throws -> [String: Any] = { _, _, _, _ in throw WorkflowEvidenceError.invalid("M5 prompt acceleration is unavailable.") }
    var convertRepoPreview: (RepoConversionRequest) async throws -> [String: Any] = { _ in
        throw ModelWorkflowAPIUnavailable.repoConversion
    }
    /// The request and the reviewed preview hash.
    var convertRepoStart: (RepoConversionRequest, String) async throws -> [String: Any] = { _, _ in
        throw ModelWorkflowAPIUnavailable.repoConversion
    }

    static func live(api: WorkbenchAPI, resolveProfile: @escaping (ServingProfile) throws -> ServingProfile = { $0 }) -> ModelWorkflowAPI {
        var workflowAPI = ModelWorkflowAPI(
            convertPreview: { path, qBits, output in try await api.convertPreview(ggufPath: path, qBits: qBits, out: output) },
            convertStart: { path, qBits, output, hash in try await api.convertStart(ggufPath: path, qBits: qBits, out: output, previewHash: hash) },
            convertStatus: { try await api.allJobs() },
            servePreview: { repo, runtime, port in try await api.servePreview(repo: repo, runtime: runtime, port: port) },
            serveStart: { repo, runtime, port, hash in try await api.serveStart(repo: repo, runtime: runtime, port: port, previewHash: hash) },
            serveStatus: { try await api.serveStatus() },
            serveStop: { port in try await api.serveStop(port: port) }
        )
        workflowAPI.profilePreview = { profile, port in try await resolveProfile(profile).preview(api: api, port: port) }
        workflowAPI.profileStart = { profile, port, hash in try await resolveProfile(profile).start(api: api, port: port, hash: hash) }
        workflowAPI.prefillPreview = { repo, runtime, port in
            try await api.servePreview(repo: repo, runtime: runtime, port: port, m5Prefill: true)
        }
        workflowAPI.prefillStart = { repo, runtime, port, hash in
            try await api.serveStart(repo: repo, runtime: runtime, port: port, previewHash: hash, m5Prefill: true)
        }
        workflowAPI.convertRepoPreview = { request in
            try await api.convertRepoPreview(
                repo: request.repo, qBits: request.qBits, out: request.output, hfCache: nil,
                backend: request.backend, modelType: request.modelType, subfolder: request.subfolder, sourcePath: request.sourcePath
            )
        }
        workflowAPI.convertRepoStart = { request, hash in
            try await api.convertRepoStart(
                repo: request.repo, qBits: request.qBits, out: request.output, hfCache: nil, previewHash: hash,
                backend: request.backend, modelType: request.modelType, subfolder: request.subfolder, sourcePath: request.sourcePath
            )
        }
        return workflowAPI
    }
}

/// One repo conversion as the agent's `convert start` takes it.
struct RepoConversionRequest: Equatable {
    let repo: String
    let backend: String
    let qBits: Int
    let output: String?
    var modelType: String? = nil
    var subfolder: String? = nil
    var sourcePath: String? = nil
}

struct ModelWorkflowPersistence: Sendable {
    let load: @Sendable () throws -> [ConversionWorkflow]
    let upsert: @Sendable (ConversionWorkflow) throws -> Void
    let remove: @Sendable (String) throws -> Void

    init(
        load: @escaping @Sendable () throws -> [ConversionWorkflow],
        upsert: @escaping @Sendable (ConversionWorkflow) throws -> Void,
        remove: @escaping @Sendable (String) throws -> Void = { _ in }
    ) {
        self.load = load
        self.upsert = upsert
        self.remove = remove
    }

    static func live(store: ModelWorkflowStore) -> ModelWorkflowPersistence {
        ModelWorkflowPersistence(load: { try store.load() }, upsert: { try store.upsert($0) }, remove: { try store.remove(id: $0) })
    }
}

@MainActor
final class ModelWorkflowCoordinator: ObservableObject {
    @Published private(set) var workflow: ConversionWorkflow
    @Published private(set) var history: [ConversionWorkflow]
    @Published private(set) var servers: [ServerInfo]
    /// The agent's conversion jobs from the latest status refresh.
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var persistenceError: String?
    /// Set when the last read-only serving refresh failed; cleared by the next success.
    @Published private(set) var serversError: String?
    @Published private(set) var isConversionSubmissionInFlight = false
    @Published private(set) var isServeSubmissionInFlight = false
    @Published private(set) var servingProfile: ServingProfile?

    private let api: ModelWorkflowAPI
    private let persistence: ModelWorkflowPersistence
    private let historyQueue = DispatchQueue(label: "workflow-history", qos: .utility)
    private var historyLoadTask: Task<Void, Never>?
    private var hasLoadedHistory = false
    private var workflowRevision: UInt = 0
    private var saveGeneration: UInt = 0
    private var recordSaveGenerations: [UUID: UInt] = [:]
    private var pendingRecordWrites: [UUID: Int] = [:]
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var pendingHistoryWrites = 0
    var isSavingHistory: Bool { pendingHistoryWrites > 0 }
    private let now: () -> Date
    private let fileManager: FileManager
    /// When set (via `VerificationCoordinator.attach`), a fresh-scan-confirmed
    /// conversion transitions to `.verifying` and the gate decides the final
    /// state. When nil, behavior is unchanged: completion goes straight to
    /// `.completed`.
    weak var completionVerifier: (any ConversionCompletionVerifying)?
    /// Stamps usage evidence when a serve reaches confirmed-running — feeds
    /// the Disk Pressure Advisor's staleness detector.
    var onServeStarted: ((String) -> Void)?
    /// Fired once when a workflow transitions into a terminal state
    /// (completed / verified / verificationFailed / failed). AppHost wires
    /// this to Notification Center; nil means no notifications. Restore and
    /// launch-load never fire it — only live transitions.
    var onTerminalState: ((ConversionWorkflow) -> Void)?
    private var selectedSource: ModelItem?
    private var selectedSnapshot: LibrarySnapshot?
    private var conversionPreviewQBits: Int?
    private var conversionPreviewOutput: String?
    private var completionRescanRequested = false
    private var pendingCompletionRecordIDs = Set<UUID>()
    private var servePreviewHash: String?
    private var servePreviewIntent: ServeIntent?
    private var serversRequested = 0
    private var serversShown = 0

    init(
        api: ModelWorkflowAPI,
        persistence: ModelWorkflowPersistence,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.api = api
        self.persistence = persistence
        self.now = now
        self.fileManager = fileManager
        self.workflow = Self.emptyWorkflow(at: now())
        self.history = []
        self.servers = []
        self.persistenceError = nil

        loadHistory()
    }

    private func loadHistory() {
        guard historyLoadTask == nil else { return }
        isLoadingHistory = true
        let persistence = persistence, queue = historyQueue, initialID = workflow.id
        historyLoadTask = Task { [weak self] in
            let result = await WorkbenchIO.perform(on: queue) {
                Result { try persistence.load().sorted { $0.updatedAt > $1.updatedAt } }
            }
            guard let self else { return }
            defer { self.isLoadingHistory = false; self.historyLoadTask = nil }
            do {
                let records = try result.get()
                let localIDs = Set(self.history.map(\.id))
                self.history += records.filter { !localIDs.contains($0.id) }
                if self.workflow.id == initialID, self.workflow.state == .idle,
                   let active = records.first(where: { $0.state != .completed && $0.state != .failed }) ?? records.first {
                    self.workflow = active; self.workflowRevision += 1
                }
                self.hasLoadedHistory = true; self.persistenceError = nil
            } catch {
                let message = "Saved workflow history is unavailable: \(AppHost.render(error))"
                self.persistenceError = message
                self.preserveLastKnownState(message: message)
            }
        }
    }

    func waitForHistory() async {
        if !hasLoadedHistory, historyLoadTask == nil { loadHistory() }
        await historyLoadTask?.value
    }

    private func historyAvailable() async -> Bool {
        await waitForHistory()
        guard hasLoadedHistory else {
            preserveLastKnownState(message: persistenceError ?? "Saved workflow history is unavailable.")
            return false
        }
        return true
    }

    func inspect(source: ModelItem, snapshot: LibrarySnapshot?) {
        selectedSource = source
        selectedSnapshot = snapshot
        conversionPreviewQBits = nil
        conversionPreviewOutput = nil
        servePreviewHash = nil
        servePreviewIntent = nil
        switch ModelWorkflowResolver.destination(for: source, library: snapshot) {
        case .reuseExisting(let model):
            let exactPath = preferredModelPath(
                model,
                preferred: ModelWorkflowResolver.sameDirectoryOutputURL(for: source).path
            )
            replace(
                makeWorkflow(
                    source: source,
                    outputPath: exactPath,
                    state: .existingModelFound,
                    completedModelPath: exactPath,
                    message: "An equivalent MLX model is already available."
                )
            )
        case .available(let output):
            replace(
                makeWorkflow(
                    source: source,
                    outputPath: output.path,
                    state: .inspectingSource,
                    message: "Ready to preview conversion."
                )
            )
        case .blocked(let output, let reason):
            replace(
                makeWorkflow(
                    source: source,
                    outputPath: output.path,
                    state: .failed,
                    message: reason,
                    errorMessage: reason
                )
            )
        }
    }

    /// Starts a conversion from a Hugging Face repo the intake sheet resolved
    /// as convertible and already downloaded into the HF cache.
    func inspect(intake: IntakeResolution, outputDirectory: String, qBits: Int, snapshot: LibrarySnapshot?, downloadedPath: String? = nil) {
        selectedSource = nil
        selectedSnapshot = snapshot
        conversionPreviewQBits = nil
        conversionPreviewOutput = nil
        servePreviewHash = nil
        servePreviewIntent = nil
        let bits = Self.allowedBits(qBits, allowed: intake.qBits)
        let output = Self.repoOutputPath(directory: outputDirectory, repo: intake.source.repo, subfolder: intake.source.subfolder, qBits: bits)
        var record = repoRecord(repo: intake.source.repo, subfolder: intake.source.subfolder, backend: intake.backend ?? "mlx-lm", output: output)
        record.estimatedOutputBytes = intake.estimatedOutputBytes
        record.modelType = intake.modelType
        record.allowedBits = intake.qBits
        record.localSourcePath = downloadedPath
        replace(record)
    }

    /// Prepare's bit-width picker for a repo source: the destination follows the
    /// width, and an output already converted at that width is offered instead.
    func selectRepoBits(_ qBits: Int) {
        guard let repo = workflow.sourceRepo,
              workflow.state == .existingModelFound || workflow.state == .inspectingSource,
              workflow.allowedBits?.contains(qBits) ?? true else { return }
        let directory = URL(fileURLWithPath: workflow.outputPath).deletingLastPathComponent().path
        let output = Self.repoOutputPath(directory: directory, repo: repo, subfolder: workflow.subfolder, qBits: qBits)
        guard canonicalPath(output) != canonicalPath(workflow.outputPath) else { return }
        var record = repoRecord(repo: repo, subfolder: workflow.subfolder, backend: workflow.backend ?? "mlx-lm", output: output, keeping: workflow)
        record.estimatedOutputBytes = workflow.estimatedOutputBytes
        record.modelType = workflow.modelType
        record.allowedBits = workflow.allowedBits
        record.localSourcePath = workflow.localSourcePath
        replace(record)
    }

    /// A repo workflow at `output`: the existing model when the library already
    /// has it, otherwise ready to preview. `keeping` preserves the record identity.
    private func repoRecord(repo: String, subfolder: String?, backend: String, output: String, keeping base: ConversionWorkflow? = nil) -> ConversionWorkflow {
        let reference = subfolder.map { "\(repo)/\($0)" } ?? repo
        let existing = selectedSnapshot?.models.first { canonicalPath($0.item.path) == canonicalPath(output) }
        let timestamp = now()
        return ConversionWorkflow(
            id: base?.id ?? UUID(),
            sourcePath: "hf://\(reference)",
            sourceModelKey: nil,
            sourceSignature: nil,
            outputPath: existing?.item.path ?? output,
            previewHash: nil,
            jobReceipt: nil,
            completedModelPath: existing?.item.path,
            state: existing == nil ? .inspectingSource : .existingModelFound,
            serveState: .idle,
            message: existing == nil
                ? "Ready to preview converting \(reference) with \(backend)."
                : "An MLX output already exists at the destination.",
            errorMessage: nil,
            createdAt: base?.createdAt ?? timestamp,
            updatedAt: timestamp,
            lastKnownAgentState: nil,
            sourceRepo: repo,
            backend: backend,
            subfolder: subfolder
        )
    }

    /// The requested width when intake allows it, else the widest it allows.
    nonisolated static func allowedBits(_ qBits: Int, allowed: [Int]?) -> Int {
        guard let allowed, !allowed.isEmpty, !allowed.contains(qBits) else { return qBits }
        return allowed.max() ?? qBits
    }

    func preview(qBits: Int, out: String?) async {
        guard !isConversionSubmissionInFlight else { return }
        isConversionSubmissionInFlight = true
        defer { isConversionSubmissionInFlight = false }
        let requestedID = workflow.id
        guard await historyAvailable(), workflow.id == requestedID else { return }
        if let repo = workflow.sourceRepo {
            await previewRepo(repo, backend: workflow.backend ?? "mlx-lm", qBits: qBits, out: out)
            return
        }
        guard !workflow.sourcePath.isEmpty else {
            await fail("Select a GGUF source before previewing conversion.")
            return
        }
        guard let source = selectedSource ?? restoredSource() else {
            await fail("The selected GGUF source is unavailable for validation.")
            return
        }
        let output = safeOutputOverride(out) ?? workflow.outputPath
        switch ModelWorkflowResolver.destination(
            for: source,
            library: selectedSnapshot,
            fileManager: fileManager,
            now: now()
        ) {
        case .reuseExisting(let model):
            await useExisting(model)
            return
        case .blocked(let destination, let reason):
            failDestination(destination: destination.path, reason: reason)
            return
        case .available:
            guard !fileManager.fileExists(atPath: canonicalPath(output)) else {
                failDestination(
                    destination: output,
                    reason: "The destination already exists and is not an equivalent model."
                )
                return
            }
        }

        conversionPreviewQBits = qBits
        conversionPreviewOutput = output
        update(state: .previewingConversion, outputPath: output, message: "Preparing conversion preview.", errorMessage: .some(nil))
        do {
            let response = try await api.convertPreview(workflow.sourcePath, qBits, output)
            guard let hash = response.string("preview_hash"), !hash.isEmpty else {
                await fail("Conversion preview did not include a preview hash.")
                return
            }
            update(state: .readyToConfirm, outputPath: output, previewHash: hash, message: "Preview ready for confirmation.", errorMessage: .some(nil))
        } catch {
            await fail("Conversion preview failed: \(AppHost.render(error))")
        }
    }

    func confirm(qBits: Int, reclaimSourceAfterVerification: Bool = false) async {
        guard !isConversionSubmissionInFlight else { return }
        isConversionSubmissionInFlight = true
        defer { isConversionSubmissionInFlight = false }
        let requestedID = workflow.id
        guard await historyAvailable(), workflow.id == requestedID else { return }
        var record = workflow
        record.reclaimSourceAfterVerification = reclaimSourceAfterVerification
        replace(record)
        if let repo = workflow.sourceRepo {
            await confirmRepo(repo, backend: workflow.backend ?? "mlx-lm", qBits: qBits)
            return
        }
        guard let hash = workflow.previewHash, !hash.isEmpty else {
            await fail("Preview conversion before confirming it.")
            return
        }
        guard conversionPreviewQBits == qBits,
              conversionPreviewOutput == workflow.outputPath else {
            await fail("The conversion intent changed after preview. Preview it again before confirming.")
            return
        }
        guard let source = selectedSource ?? restoredSource() else {
            await fail("The selected GGUF source is unavailable for validation.")
            return
        }
        switch ModelWorkflowResolver.destination(
            for: source,
            library: selectedSnapshot,
            fileManager: fileManager,
            now: now()
        ) {
        case .reuseExisting(let model):
            await useExisting(model)
            return
        case .blocked(let destination, let reason):
            failDestination(destination: destination.path, reason: reason)
            return
        case .available:
            guard !fileManager.fileExists(atPath: canonicalPath(workflow.outputPath)) else {
                failDestination(
                    destination: workflow.outputPath,
                    reason: "The destination became occupied after preview and is not an equivalent model."
                )
                return
            }
        }

        let submitted = workflow
        do {
            let requestedID = workflow.id, output = workflow.outputPath
            guard await save(workflow), workflow.id == requestedID,
                  workflow.outputPath == output, workflow.previewHash == hash,
                  conversionPreviewQBits == qBits, conversionPreviewOutput == output else { return }
            let response = try await api.convertStart(submitted.sourcePath, qBits, submitted.outputPath, hash)
            guard let receipt = await receipt(from: response, outputPath: submitted.outputPath), !receipt.isEmpty else {
                await failSubmission(submitted, message: PrepareWorkflowPresentation.missingReceiptMessage)
                return
            }
            conversionPreviewQBits = nil
            conversionPreviewOutput = nil
            await save(updatedRecord(from: submitted, state: .queued, jobReceipt: receipt,
                message: "Conversion queued.", errorMessage: .some(nil), lastKnownAgentState: "queued"),
                makeCurrent: workflow.id == submitted.id)
        } catch {
            await failSubmission(submitted, message: "\(PrepareWorkflowPresentation.queueFailurePrefix): \(AppHost.render(error))")
        }
    }

    /// Newer agents return the receipt as an object (no path inside); the
    /// authoritative receipt path only exists in convert status. Prefer a
    /// plain string receipt (older agents), else resolve the just-started
    /// job by output path.
    private func receipt(from response: [String: Any], outputPath: String) async -> String? {
        var receipt = response.string("receipt")
        if receipt == nil, let jobs = try? await api.convertStatus() {
            let target = canonicalPath(outputPath)
            receipt = jobs.first(where: {
                guard let out = $0.out else { return false }
                return canonicalPath(out) == target
            })?.receipt
        }
        return receipt
    }

    /// `<directory>/<name>[-<folder>]-MLX-<bits>bit` for a repo conversion (matches the agent's default name).
    static func repoOutputPath(directory: String, repo: String, subfolder: String? = nil, qBits: Int) -> String {
        let base = repo.split(separator: "/").last.map(String.init) ?? repo
        let name = subfolder.map { "\(base)-\($0.replacingOccurrences(of: "/", with: "-"))" } ?? base
        return URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath)
            .appendingPathComponent("\(name)-MLX-\(qBits)bit").path
    }

    private func previewRepo(_ repo: String, backend: String, qBits: Int, out: String?) async {
        let directory = URL(fileURLWithPath: workflow.outputPath).deletingLastPathComponent().path
        let output = safeOutputOverride(out) ?? Self.repoOutputPath(directory: directory, repo: repo, subfolder: workflow.subfolder, qBits: qBits)
        guard !fileManager.fileExists(atPath: canonicalPath(output)) else {
            failDestination(destination: output, reason: "The destination already exists; pick another output directory.")
            return
        }
        conversionPreviewQBits = qBits
        conversionPreviewOutput = output
        update(state: .previewingConversion, outputPath: output, message: "Preparing conversion preview.", errorMessage: .some(nil))
        do {
            let response = WorkbenchAPI.unwrapPlan(try await api.convertRepoPreview(repoRequest(repo, backend: backend, qBits: qBits, output: output)))
            guard let hash = response.string("preview_hash"), !hash.isEmpty else {
                await fail("Conversion preview did not include a preview hash.")
                return
            }
            update(state: .readyToConfirm, outputPath: output, previewHash: hash, message: "Preview ready for confirmation.", errorMessage: .some(nil))
        } catch {
            await fail("Conversion preview failed: \(AppHost.render(error))")
        }
    }

    private func repoRequest(_ repo: String, backend: String, qBits: Int, output: String) -> RepoConversionRequest {
        RepoConversionRequest(
            repo: repo, backend: backend, qBits: qBits, output: output,
            modelType: workflow.modelType, subfolder: workflow.subfolder, sourcePath: workflow.localSourcePath
        )
    }

    private func confirmRepo(_ repo: String, backend: String, qBits: Int) async {
        guard let hash = workflow.previewHash, !hash.isEmpty else {
            await fail("Preview conversion before confirming it.")
            return
        }
        guard conversionPreviewQBits == qBits, conversionPreviewOutput == workflow.outputPath else {
            await fail("The conversion intent changed after preview. Preview it again before confirming.")
            return
        }
        guard !fileManager.fileExists(atPath: canonicalPath(workflow.outputPath)) else {
            failDestination(destination: workflow.outputPath, reason: "The destination became occupied after preview.")
            return
        }
        let submitted = workflow
        do {
            let requestedID = workflow.id, output = workflow.outputPath
            guard await save(workflow), workflow.id == requestedID,
                  workflow.outputPath == output, workflow.previewHash == hash,
                  conversionPreviewQBits == qBits, conversionPreviewOutput == output else { return }
            let response = try await api.convertRepoStart(repoRequest(repo, backend: backend, qBits: qBits, output: submitted.outputPath), hash)
            guard let receipt = await receipt(from: response, outputPath: submitted.outputPath), !receipt.isEmpty else {
                await failSubmission(submitted, message: PrepareWorkflowPresentation.missingReceiptMessage)
                return
            }
            conversionPreviewQBits = nil
            conversionPreviewOutput = nil
            await save(updatedRecord(from: submitted, state: .queued, jobReceipt: receipt,
                message: "Conversion queued.", errorMessage: .some(nil), lastKnownAgentState: "queued"),
                makeCurrent: workflow.id == submitted.id)
        } catch {
            await failSubmission(submitted, message: "\(PrepareWorkflowPresentation.queueFailurePrefix): \(AppHost.render(error))")
        }
    }

    func useExisting(_ model: LibraryModel) async {
        let requestedID = workflow.id
        guard await historyAvailable(), workflow.id == requestedID else { return }
        let exactPath = preferredModelPath(model, preferred: workflow.completedModelPath ?? workflow.outputPath)
        await savedUpdate(
            state: .completed,
            outputPath: exactPath,
            completedModelPath: exactPath,
            message: "Using existing MLX model.",
            errorMessage: .some(nil)
        )
    }

    func prepareServe(model: LibraryModel, exactPath: String? = nil) {
        guard model.readiness == .ready, !isServeSubmissionInFlight else { return }
        guard ModelTaskPresentation.isServable(model) else {
            let title = model.item.task?.type.title ?? "This"
            update(serveState: .failed, message: "\(title) models are not servable by mlx-lm.", errorMessage: "\(title) models are not servable by mlx-lm.")
            return
        }
        let selectedPath = preferredModelPath(
            model,
            preferred: exactPath ?? workflow.completedModelPath ?? workflow.outputPath
        )
        if RunPresentation.requiresWorkflowReview(workflow.state),
           ([workflow.outputPath] + [workflow.completedModelPath].compactMap { $0 })
            .contains(where: { canonicalPath($0) == canonicalPath(selectedPath) }) { return }
        if servingProfile?.modelPath != selectedPath { servingProfile = nil }
        servePreviewHash = nil
        servePreviewIntent = nil
        // A completed or verified record of the selected model is served exactly as recorded.
        if RunPresentation.runnableStates.contains(workflow.state),
           let current = workflow.completedModelPath,
           canonicalPath(current) == canonicalPath(selectedPath) {
            return
        }
        // Any other record keeps its lifecycle; Run serves a separate, unsaved target.
        workflow = updatedRecord(
            from: Self.emptyWorkflow(at: now()),
            state: .completed,
            outputPath: selectedPath,
            completedModelPath: selectedPath,
            message: "Ready to preview serving \(model.displayName).",
            errorMessage: .some(nil)
        )
    }

    func selectServingProfile(_ profile: ServingProfile?) {
        guard !isServeSubmissionInFlight else { return }
        servingProfile = profile
        servePreviewHash = nil; servePreviewIntent = nil
        update(serveState: .idle, message: "Preview the selected serving configuration.", errorMessage: .some(nil))
    }

    func previewServe(runtime: String, port: Int?, m5Prefill: Bool = false) async {
        guard !isServeSubmissionInFlight else { return }
        isServeSubmissionInFlight = true
        defer { isServeSubmissionInFlight = false }
        let requestedID = workflow.id
        guard await historyAvailable(), workflow.id == requestedID else { return }
        guard let model = workflow.completedModelPath, !model.isEmpty else {
            update(serveState: .failed, message: "Complete or select an MLX model before previewing serve.", errorMessage: "No completed MLX model selected.")
            return
        }
        servePreviewHash = nil
        servePreviewIntent = nil
        let request = nextServersRequest()
        do {
            let snapshot = try await api.serveStatus()
            if showsServers(request) { servers = snapshot }
        } catch {
            update(serveState: .failed, message: "Serve status is unavailable; serving remains blocked.", errorMessage: AppHost.render(error))
            return
        }
        guard !servers.contains(where: { serverRunsModel($0, model) }) else {
            update(serveState: .failed, message: "A server is already running for the selected model.", errorMessage: "Stop the authoritative running server before starting another.")
            return
        }

        update(serveState: .previewing, message: "Preparing serve preview.", errorMessage: .some(nil))
        do {
            if let profile = servingProfile, profile.modelPath != model { throw WorkflowEvidenceError.invalid("Serving profile model changed.") }
            if m5Prefill, servingProfile != nil { throw WorkflowEvidenceError.invalid("M5 prompt acceleration requires MLX-LM without a serving profile.") }
            let response: [String: Any]
            if let profile = servingProfile { response = try await api.profilePreview(profile, port) }
            else if m5Prefill { response = try await api.prefillPreview(model, runtime, port) }
            else { response = try await api.servePreview(model, runtime, port) }
            guard let hash = response.string("preview_hash"), !hash.isEmpty else {
                update(serveState: .failed, message: "Serve preview did not include a preview hash.", errorMessage: "Missing serve preview hash.")
                return
            }
            servePreviewHash = hash
            servePreviewIntent = ServeIntent(runtime: runtime, port: port, profile: servingProfile, m5Prefill: m5Prefill)
            update(serveState: .readyToConfirm, message: "Serve preview ready for confirmation.", errorMessage: .some(nil))
        } catch {
            update(serveState: .failed, message: "Serve preview failed: \(AppHost.render(error))", errorMessage: AppHost.render(error))
        }
    }

    func confirmServe(runtime: String, port: Int?, m5Prefill: Bool = false) async {
        guard !isServeSubmissionInFlight else { return }
        isServeSubmissionInFlight = true
        defer { isServeSubmissionInFlight = false }
        let requestedID = workflow.id
        guard await historyAvailable(), workflow.id == requestedID else { return }
        guard let model = workflow.completedModelPath,
              !model.isEmpty,
              let hash = servePreviewHash,
              !hash.isEmpty,
              let intent = servePreviewIntent else {
            update(serveState: .failed, message: "Preview serving before confirming it.", errorMessage: "Missing serve preview hash.")
            return
        }
        guard intent.runtime == runtime, intent.port == port, intent.profile == servingProfile, intent.m5Prefill == m5Prefill else {
            servePreviewHash = nil
            servePreviewIntent = nil
            update(
                serveState: .failed,
                message: "Serve intent changed after preview. Preview it again before confirming.",
                errorMessage: "Serve intent changed after the preview."
            )
            return
        }
        guard !servers.contains(where: { serverRunsModel($0, model) }) else {
            update(serveState: .failed, message: "A server is already running for the selected model.", errorMessage: "Stop the authoritative running server before starting another.")
            return
        }
        servePreviewHash = nil
        servePreviewIntent = nil
        let submitted = workflow
        do {
            let requestedID = workflow.id
            guard await save(workflow), workflow.id == requestedID else { return }
            if let profile = servingProfile { _ = try await api.profileStart(profile, port, hash) }
            else if m5Prefill { _ = try await api.prefillStart(model, runtime, port, hash) }
            else { _ = try await api.serveStart(model, runtime, port, hash) }
            let statusAvailable = await refreshOperationalStatus()
            guard statusAvailable,
                  servers.contains(where: { serverRunsModel($0, model) }) else {
                await savedUpdate(from: submitted, serveState: .failed, message: "Server start was requested, but authoritative status did not report it running.", errorMessage: "Refresh server status before trying again.")
                return
            }
            await savedUpdate(from: submitted, serveState: .running, message: "Server is running.", errorMessage: .some(nil))
            onServeStarted?(model)
        } catch {
            await savedUpdate(from: submitted, serveState: .failed, message: "Server could not be started: \(AppHost.render(error))", errorMessage: AppHost.render(error))
        }
    }

    func stopServer(modelPath: String) async {
        guard !isServeSubmissionInFlight else { return }
        isServeSubmissionInFlight = true
        defer { isServeSubmissionInFlight = false }
        guard let server = servers.first(where: {
            serverRunsModel($0, modelPath)
        }), let port = server.port else {
            update(serveState: .failed, message: "No authoritative running server is available for the selected model.", errorMessage: "Selected model server status is unavailable.")
            return
        }
        servePreviewHash = nil
        servePreviewIntent = nil
        let stopped = workflow
        do {
            _ = try await api.serveStop(port)
            let statusAvailable = await refreshOperationalStatus()
            guard statusAvailable else {
                await savedUpdate(from: stopped, serveState: .failed, message: "Server stop was requested, but authoritative status is unavailable.", errorMessage: "Refresh server status before assuming the server stopped.")
                return
            }
            if servers.contains(where: { serverRunsModel($0, modelPath) }) {
                await savedUpdate(from: stopped, serveState: .running, message: "The authoritative server is still running.", errorMessage: "Stop was requested but has not been confirmed.")
            } else {
                await savedUpdate(from: stopped, serveState: .stopped, message: "Server stopped.", errorMessage: .some(nil))
            }
        } catch {
            await savedUpdate(from: stopped, serveState: .failed, message: "Server could not be stopped: \(AppHost.render(error))", errorMessage: AppHost.render(error))
        }
    }

    func restore(_ record: ConversionWorkflow) {
        workflowRevision += 1
        workflow = record
        selectedSource = nil
        selectedSnapshot = nil
        conversionPreviewQBits = nil
        conversionPreviewOutput = nil
        servePreviewHash = nil
        servePreviewIntent = nil
        if let index = history.firstIndex(where: { $0.persistenceIdentifier == record.persistenceIdentifier }) {
            history[index] = record
        } else {
            history.insert(record, at: 0)
        }
    }

    func reconcile(snapshot: LibrarySnapshot?, jobs: [Job]) async {
        guard await historyAvailable() else { return }
        let authoritativeJobs: [Job]
        if jobs.isEmpty {
            do {
                authoritativeJobs = try await api.convertStatus()
            } catch {
                preserveLastKnownState(message: "Conversion status unavailable: \(AppHost.render(error))")
                return
            }
        } else {
            authoritativeJobs = jobs
        }
        await reconcileAuthoritative(snapshot: snapshot, jobs: authoritativeJobs)
    }

    @discardableResult
    func refreshOperationalStatus() async -> Bool {
        guard await historyAvailable() else { return await refreshServingStatus() }
        do {
            let jobs = try await api.convertStatus()
            await reconcileAuthoritative(snapshot: nil, jobs: jobs)
        } catch {
            preserveLastKnownState(message: "Conversion status unavailable: \(AppHost.render(error))")
        }
        return await refreshServingStatus()
    }

    /// Read-only: replaces `servers` from `serve status`. It never touches
    /// conversion jobs, workflow records, verification or any serve action.
    func refreshServers() async {
        let request = nextServersRequest()
        do {
            let snapshot = try await api.serveStatus()
            guard showsServers(request) else { return }
            servers = snapshot
            serversError = nil
        } catch {
            guard showsServers(request) else { return }
            serversError = "Serving status unavailable: \(AppHost.render(error))"
        }
    }

    @discardableResult
    func refreshServingStatus() async -> Bool {
        let request = nextServersRequest()
        do {
            let snapshot = try await api.serveStatus()
            if showsServers(request) { servers = snapshot }
            return true
        } catch {
            if showsServers(request) {
                preserveLastKnownState(message: "Server status unavailable: \(AppHost.render(error))")
            }
            return false
        }
    }

    private func nextServersRequest() -> Int {
        serversRequested += 1
        return serversRequested
    }

    /// Status reads run concurrently and can finish out of order; a reply is
    /// shown only when no later-issued reply has been shown already.
    private func showsServers(_ request: Int) -> Bool {
        guard request > serversShown else { return false }
        serversShown = request
        return true
    }

    func clearTransientError() {
        update(message: .some(nil), errorMessage: .some(nil))
    }

    /// Dismiss a terminal workflow record from history. Dismissing the active
    /// record resets the workflow to idle so Overview stops surfacing it as
    /// the next action. Persisted so the record stays dismissed on relaunch.
    func dismiss(recordID: UUID) async {
        guard await historyAvailable(), pendingRecordWrites[recordID, default: 0] == 0,
              let record = history.first(where: { $0.id == recordID }) else { return }
        let persistence = persistence
        do {
            try await WorkbenchIO.perform(on: historyQueue) { Result { try persistence.remove(record.persistenceIdentifier) } }.get()
            history.removeAll { $0 == record }
            if workflow == record {
                workflow = Self.emptyWorkflow(at: now()); workflowRevision += 1
            }
        } catch {
            persistenceError = "Workflow history could not be saved: \(AppHost.render(error))"
        }
    }

    /// A completion scan could not run (another scan was in progress); ask again on the next refresh.
    func deferCompletionRescan() {
        completionRescanRequested = true
    }

    func consumeCompletionRescanRequest() -> Bool {
        let requested = completionRescanRequested
        completionRescanRequested = false
        return requested
    }

    func resolveCompletionAfterFreshScan(snapshot: LibrarySnapshot?) async {
        guard await historyAvailable() else { return }
        let ids = pendingCompletionRecordIDs.isEmpty ? [workflow.id] : Array(pendingCompletionRecordIDs)
        for id in ids {
            guard let record = history.first(where: { $0.id == id }) else { continue }
            if let completed = completedModel(in: snapshot, for: record) {
                let skippedType = completed.model.item.task.flatMap { $0.type.hasCanary ? nil : $0.type }
                if let verifier = completionVerifier, skippedType == nil {
                    guard await save(
                        updatedRecord(
                            from: record,
                            state: .verifying,
                            outputPath: completed.path,
                            completedModelPath: completed.path,
                            message: "Conversion completed; verifying the MLX output before it is marked verified.",
                            errorMessage: .some(nil)
                        ),
                        makeCurrent: record.id == workflow.id
                    ) else { continue }
                    verifier.beginVerification(
                        recordID: record.id,
                        modelPath: completed.path,
                        signature: completed.model.item.signature
                    )
                } else {
                    await save(
                        updatedRecord(
                            from: record,
                            state: .completed,
                            outputPath: completed.path,
                            completedModelPath: completed.path,
                            message: skippedType.map {
                                "Conversion completed; \($0.title) models have no canary, so the output was confirmed by a fresh scan only."
                            } ?? "Conversion completed and the MLX output was confirmed by a fresh scan.",
                            errorMessage: .some(nil)
                        ),
                        makeCurrent: record.id == workflow.id
                    )
                }
            } else {
                await save(
                    updatedRecord(
                        from: record,
                        state: .running,
                        message: "Conversion completed, but the fresh library scan did not find its expected MLX output.",
                        errorMessage: .some(nil)
                    ),
                    makeCurrent: record.id == workflow.id
                )
            }
        }
        pendingCompletionRecordIDs.removeAll()
    }

    /// Called by the Conversion Quality Gate when a verification run ends.
    /// Only records currently in `.verifying` are resolved; `.keptAnyway` is
    /// additionally accepted from `.verificationFailed` (the explicit user
    /// override). Anything else is a stale callback and ignored.
    func resolveVerification(recordID: UUID, resolution: VerificationResolution) async {
        guard await historyAvailable() else { return }
        guard let record = history.first(where: { $0.id == recordID }) else { return }
        if case .keptAnyway = resolution {
            guard record.state == .verifying || record.state == .verificationFailed else { return }
        } else {
            guard record.state == .verifying else { return }
        }
        switch resolution {
        case .passed(let summary):
            await save(
                updatedRecord(
                    from: record,
                    state: .verified,
                    message: "\(VerificationOutcome.passedLead) \(summary)",
                    errorMessage: .some(nil)
                ),
                makeCurrent: record.id == workflow.id
            )
        case .failed(let summary):
            await save(
                updatedRecord(
                    from: record,
                    state: .verificationFailed,
                    message: "Verification failed. \(summary)",
                    errorMessage: .some("Verification failed. \(summary)")
                ),
                makeCurrent: record.id == workflow.id
            )
        case .unavailable(let reason):
            await save(
                updatedRecord(
                    from: record,
                    state: .completed,
                    message: "Verification result unavailable (\(reason)); the output is complete but unverified.",
                    errorMessage: .some(nil)
                ),
                makeCurrent: record.id == workflow.id
            )
        case .keptAnyway:
            await save(
                updatedRecord(
                    from: record,
                    state: .completed,
                    message: "Kept despite a failed verification (explicit override).",
                    errorMessage: .some(nil)
                ),
                makeCurrent: record.id == workflow.id
            )
        }
    }

    private func reconcileAuthoritative(snapshot: LibrarySnapshot?, jobs: [Job]) async {
        self.jobs = jobs
        var records = history
        if !records.contains(where: { $0.id == workflow.id }), workflow.jobReceipt != nil {
            records.append(workflow)
        }
        let owners = Job.owners(of: jobs, among: records)
        for record in records {
            guard let receipt = record.jobReceipt, !receipt.isEmpty else { continue }
            guard jobs.contains(where: { $0.receipt == receipt }) else {
                if record.id == workflow.id {
                    preserveLastKnownState(message: "Conversion receipt \(receipt) was not present in authoritative status.")
                }
                continue
            }
            // A finished record keeps its outcome; a job moves only the newest record holding its receipt.
            guard !record.state.isTerminal, let job = owners[record.id] else { continue }

            let agentState = job.state.lowercased()
            switch agentState {
            case "queued", "pending", "starting":
                guard !record.reflects(state: .queued, message: "Conversion queued.", errorMessage: nil, agentState: job.state) else { continue }
                await save(updatedRecord(from: record, state: .queued, message: "Conversion queued.", errorMessage: .some(nil), lastKnownAgentState: job.state), makeCurrent: record.id == workflow.id)
            case "running", "active":
                guard !record.reflects(state: .running, message: "Conversion running.", errorMessage: nil, agentState: job.state) else { continue }
                await save(updatedRecord(from: record, state: .running, message: "Conversion running.", errorMessage: .some(nil), lastKnownAgentState: job.state), makeCurrent: record.id == workflow.id)
            case "done", "completed", "complete", "succeeded", "success":
                // Once the scan confirmed the output, later refreshes of the same done job change nothing.
                guard record.state != .verifying else { continue }
                completionRescanRequested = true
                pendingCompletionRecordIDs.insert(record.id)
                await save(updatedRecord(from: record, state: .running, message: "Conversion completed; waiting for a fresh library scan to confirm its MLX output.", errorMessage: .some(nil), lastKnownAgentState: job.state), makeCurrent: record.id == workflow.id)
            case "failed", "error", "cancelled", "canceled":
                let message = "Conversion \(job.state)."
                await save(updatedRecord(from: record, state: .failed, message: message, errorMessage: .some(message), lastKnownAgentState: job.state), makeCurrent: record.id == workflow.id)
            default:
                if record.id == workflow.id {
                    preserveLastKnownState(message: "Conversion status \(job.state) is not recognized; preserving the last known state.")
                }
            }
        }
        _ = snapshot
    }

    private func completedModel(in snapshot: LibrarySnapshot?, for record: ConversionWorkflow) -> (model: LibraryModel, path: String)? {
        let target = canonicalPath(record.outputPath)
        for model in snapshot?.models ?? [] {
            let candidates = [model.item.path] + model.outputPaths + model.sourcePaths
            if let exactPath = candidates.first(where: { canonicalPath($0) == target }) {
                return (model, exactPath)
            }
        }
        return nil
    }

    private func safeOutputOverride(_ output: String?) -> String? {
        guard let output else { return nil }
        let candidate = URL(fileURLWithPath: NSString(string: output).expandingTildeInPath).standardizedFileURL
        let sourceDirectory = URL(fileURLWithPath: workflow.sourcePath).standardizedFileURL.deletingLastPathComponent()
        guard candidate.deletingLastPathComponent() == sourceDirectory else { return nil }
        return candidate.path
    }

    private func restoredSource() -> ModelItem? {
        guard !workflow.sourcePath.isEmpty else { return nil }
        return ModelItem(
            path: workflow.sourcePath,
            name: URL(fileURLWithPath: workflow.sourcePath).lastPathComponent,
            bytes: 0,
            modifiedAt: nil,
            shard: nil,
            modelKey: workflow.sourceModelKey,
            architecture: nil,
            quantization: nil,
            parameters: nil,
            structure: nil,
            signature: workflow.sourceSignature,
            companion: nil,
            readable: true,
            status: "pending",
            outputs: [],
            tensorCount: nil,
            error: nil
        )
    }

    private func preferredModelPath(_ model: LibraryModel, preferred: String?) -> String {
        let candidates = [model.item.path] + model.outputPaths + model.sourcePaths
        if let preferred,
           let exact = candidates.first(where: { canonicalPath($0) == canonicalPath(preferred) }) {
            return exact
        }
        return model.item.path
    }

    private func failDestination(destination: String, reason: String) {
        update(
            state: .failed,
            previewHash: nil,
            message: .some(reason),
            errorMessage: .some(reason),
            clearPreviewHash: true
        )
        _ = destination
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    /// Serve status reports the repo id for HF-cache models while the
    /// workflow tracks filesystem paths; normalize both sides through the
    /// serve identity before comparing.
    private func serverRunsModel(_ server: ServerInfo, _ modelPath: String) -> Bool {
        guard server.state?.lowercased() == "running" else { return false }
        return server.matchesUnadaptedModel(modelPath)
    }

    private func makeWorkflow(
        source: ModelItem,
        outputPath: String,
        state: ConversionWorkflowState,
        completedModelPath: String? = nil,
        message: String? = nil,
        errorMessage: String? = nil
    ) -> ConversionWorkflow {
        makeWorkflow(
            sourcePath: source.path, sourceModelKey: source.modelKey, sourceSignature: source.signature,
            outputPath: outputPath, state: state, completedModelPath: completedModelPath,
            message: message, errorMessage: errorMessage
        )
    }

    private func makeWorkflow(
        sourcePath: String,
        sourceModelKey: String?,
        sourceSignature: String?,
        outputPath: String,
        state: ConversionWorkflowState,
        completedModelPath: String? = nil,
        message: String? = nil,
        errorMessage: String? = nil
    ) -> ConversionWorkflow {
        let timestamp = now()
        return ConversionWorkflow(
            id: UUID(),
            sourcePath: sourcePath,
            sourceModelKey: sourceModelKey,
            sourceSignature: sourceSignature,
            outputPath: outputPath,
            previewHash: nil,
            jobReceipt: nil,
            completedModelPath: completedModelPath,
            state: state,
            serveState: .idle,
            message: message,
            errorMessage: errorMessage,
            createdAt: timestamp,
            updatedAt: timestamp,
            lastKnownAgentState: nil
        )
    }

    private func update(
        state: ConversionWorkflowState? = nil,
        serveState: ServeWorkflowState? = nil,
        outputPath: String? = nil,
        previewHash: String? = nil,
        jobReceipt: String? = nil,
        completedModelPath: String? = nil,
        message: String?? = nil,
        errorMessage: String?? = nil,
        lastKnownAgentState: String? = nil,
        clearPreviewHash: Bool = false
    ) {
        let next = updatedRecord(
            from: workflow,
            state: state,
            serveState: serveState,
            outputPath: outputPath,
            previewHash: previewHash,
            jobReceipt: jobReceipt,
            completedModelPath: completedModelPath,
            message: message,
            errorMessage: errorMessage,
            lastKnownAgentState: lastKnownAgentState,
            clearPreviewHash: clearPreviewHash
        )
        replace(next)
    }

    @discardableResult
    private func savedUpdate(
        from record: ConversionWorkflow? = nil,
        state: ConversionWorkflowState? = nil,
        serveState: ServeWorkflowState? = nil,
        outputPath: String? = nil,
        previewHash: String? = nil,
        jobReceipt: String? = nil,
        completedModelPath: String? = nil,
        message: String?? = nil,
        errorMessage: String?? = nil,
        lastKnownAgentState: String? = nil,
        clearPreviewHash: Bool = false
    ) async -> Bool {
        let base = record ?? workflow
        let next = updatedRecord(
            from: base,
            state: state,
            serveState: serveState,
            outputPath: outputPath,
            previewHash: previewHash,
            jobReceipt: jobReceipt,
            completedModelPath: completedModelPath,
            message: message,
            errorMessage: errorMessage,
            lastKnownAgentState: lastKnownAgentState,
            clearPreviewHash: clearPreviewHash
        )
        return await save(next, makeCurrent: workflow.id == base.id)
    }

    private func updatedRecord(
        from base: ConversionWorkflow,
        state: ConversionWorkflowState? = nil,
        serveState: ServeWorkflowState? = nil,
        outputPath: String? = nil,
        previewHash: String? = nil,
        jobReceipt: String? = nil,
        completedModelPath: String? = nil,
        message: String?? = nil,
        errorMessage: String?? = nil,
        lastKnownAgentState: String? = nil,
        clearPreviewHash: Bool = false
    ) -> ConversionWorkflow {
        let nextMessage = message.map { $0 } ?? base.message
        let nextErrorMessage = errorMessage.map { $0 } ?? base.errorMessage
        return ConversionWorkflow(
            id: base.id,
            sourcePath: base.sourcePath,
            sourceModelKey: base.sourceModelKey,
            sourceSignature: base.sourceSignature,
            outputPath: outputPath ?? base.outputPath,
            previewHash: clearPreviewHash ? nil : (previewHash ?? base.previewHash),
            jobReceipt: jobReceipt ?? base.jobReceipt,
            completedModelPath: completedModelPath ?? base.completedModelPath,
            state: state ?? base.state,
            serveState: serveState ?? base.serveState,
            message: nextMessage,
            errorMessage: nextErrorMessage,
            createdAt: base.createdAt,
            updatedAt: now(),
            lastKnownAgentState: lastKnownAgentState ?? base.lastKnownAgentState,
            sourceRepo: base.sourceRepo,
            backend: base.backend,
            estimatedOutputBytes: base.estimatedOutputBytes,
            modelType: base.modelType,
            subfolder: base.subfolder,
            localSourcePath: base.localSourcePath,
            reclaimSourceAfterVerification: base.reclaimSourceAfterVerification,
            allowedBits: base.allowedBits
        )
    }

    private func replace(_ record: ConversionWorkflow, makeCurrent: Bool = true) {
        let previousState = history.first(where: {
            $0.persistenceIdentifier == record.persistenceIdentifier
        })?.state
        if makeCurrent {
            workflowRevision += 1
            workflow = record
        }
        if let index = history.firstIndex(where: { $0.persistenceIdentifier == record.persistenceIdentifier }) {
            history[index] = record
        } else if record.state != .idle {
            history.insert(record, at: 0)
        }
        if record.state.isTerminal, previousState != nil, previousState != record.state {
            onTerminalState?(record)
        }
    }

    @discardableResult
    private func save(_ record: ConversionWorkflow, makeCurrent: Bool = true) async -> Bool {
        guard await historyAvailable() else { return false }
        let selectedRevision = workflowRevision, persistence = persistence
        saveGeneration += 1
        let generation = saveGeneration
        recordSaveGenerations[record.id] = generation
        pendingHistoryWrites += 1; pendingRecordWrites[record.id, default: 0] += 1
        defer {
            pendingHistoryWrites -= 1
            let remaining = pendingRecordWrites[record.id, default: 1] - 1
            if remaining == 0 { pendingRecordWrites.removeValue(forKey: record.id) }
            else { pendingRecordWrites[record.id] = remaining }
        }
        do {
            try await WorkbenchIO.perform(on: historyQueue) { Result { try persistence.upsert(record) } }.get()
            guard recordSaveGenerations[record.id] == generation else { return false }
            replace(record, makeCurrent: makeCurrent && workflow.id == record.id && workflowRevision == selectedRevision)
            persistenceError = nil
            return true
        } catch {
            if recordSaveGenerations[record.id] == generation {
                let message = "Workflow state could not be saved: \(AppHost.render(error))"
                persistenceError = message
                preserveLastKnownState(message: message)
            }
            return false
        }
    }

    private func preserveLastKnownState(message: String) {
        update(message: message, errorMessage: .some(nil))
    }

    private func fail(_ message: String) async {
        conversionPreviewQBits = nil
        conversionPreviewOutput = nil
        await savedUpdate(state: .failed, previewHash: nil, message: message, errorMessage: message, clearPreviewHash: true)
    }

    private func failSubmission(_ submitted: ConversionWorkflow, message: String) async {
        if workflow.id == submitted.id {
            conversionPreviewQBits = nil; conversionPreviewOutput = nil
        }
        await save(updatedRecord(from: submitted, state: .failed, message: message,
            errorMessage: message, clearPreviewHash: true), makeCurrent: workflow.id == submitted.id)
    }

    private static func emptyWorkflow(at date: Date, message: String? = nil) -> ConversionWorkflow {
        ConversionWorkflow(
            id: UUID(), sourcePath: "", sourceModelKey: nil, sourceSignature: nil,
            outputPath: "", previewHash: nil, jobReceipt: nil, completedModelPath: nil,
            state: .idle, serveState: .idle, message: message, errorMessage: nil,
            createdAt: date, updatedAt: date, lastKnownAgentState: nil
        )
    }
}
