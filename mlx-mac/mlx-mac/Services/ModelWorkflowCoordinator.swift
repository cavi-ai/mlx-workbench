import Foundation

private struct ServeIntent: Equatable {
    let runtime: String
    let port: Int?
}

struct ModelWorkflowAPI {
    let convertPreview: (String, Int, String?) async throws -> [String: Any]
    let convertStart: (String, Int, String?, String) async throws -> [String: Any]
    let convertStatus: () async throws -> [Job]
    let servePreview: (String, String, Int?) async throws -> [String: Any]
    let serveStart: (String, String, Int?, String) async throws -> [String: Any]
    let serveStatus: () async throws -> [ServerInfo]
    let serveStop: (Int) async throws -> [String: Any]

    static func live(api: WorkbenchAPI) -> ModelWorkflowAPI {
        ModelWorkflowAPI(
            convertPreview: { path, qBits, output in try await api.convertPreview(ggufPath: path, qBits: qBits, out: output) },
            convertStart: { path, qBits, output, hash in try await api.convertStart(ggufPath: path, qBits: qBits, out: output, previewHash: hash) },
            convertStatus: { try await api.allJobs() },
            servePreview: { repo, runtime, port in try await api.servePreview(repo: repo, runtime: runtime, port: port) },
            serveStart: { repo, runtime, port, hash in try await api.serveStart(repo: repo, runtime: runtime, port: port, previewHash: hash) },
            serveStatus: { try await api.serveStatus() },
            serveStop: { port in try await api.serveStop(port: port) }
        )
    }
}

struct ModelWorkflowPersistence {
    let load: () throws -> [ConversionWorkflow]
    let upsert: (ConversionWorkflow) throws -> Void
    let remove: (String) throws -> Void

    init(
        load: @escaping () throws -> [ConversionWorkflow],
        upsert: @escaping (ConversionWorkflow) throws -> Void,
        remove: @escaping (String) throws -> Void = { _ in }
    ) {
        self.load = load
        self.upsert = upsert
        self.remove = remove
    }

    static func live(store: ModelWorkflowStore) -> ModelWorkflowPersistence {
        ModelWorkflowPersistence(load: store.load, upsert: store.upsert, remove: store.remove)
    }
}

@MainActor
final class ModelWorkflowCoordinator: ObservableObject {
    @Published private(set) var workflow: ConversionWorkflow
    @Published private(set) var history: [ConversionWorkflow]
    @Published private(set) var servers: [ServerInfo]
    @Published private(set) var persistenceError: String?
    @Published private(set) var isConversionSubmissionInFlight = false
    @Published private(set) var isServeSubmissionInFlight = false

    private let api: ModelWorkflowAPI
    private let persistence: ModelWorkflowPersistence
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
    private var selectedSource: ModelItem?
    private var selectedSnapshot: LibrarySnapshot?
    private var conversionPreviewQBits: Int?
    private var conversionPreviewOutput: String?
    private var completionRescanRequested = false
    private var pendingCompletionRecordIDs = Set<UUID>()
    private var servePreviewHash: String?
    private var servePreviewIntent: ServeIntent?

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

        do {
            let records = try persistence.load().sorted { $0.updatedAt > $1.updatedAt }
            history = records
            if let active = records.first(where: { $0.state != .completed && $0.state != .failed }) ?? records.first {
                workflow = active
            }
        } catch {
            persistenceError = "Saved workflow history is unavailable: \(AppHost.render(error))"
            workflow = Self.emptyWorkflow(at: now(), message: "Saved workflow history is unavailable: \(AppHost.render(error))")
        }
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
                ),
                persist: false
            )
        case .available(let output):
            replace(
                makeWorkflow(
                    source: source,
                    outputPath: output.path,
                    state: .inspectingSource,
                    message: "Ready to preview conversion."
                ),
                persist: false
            )
        case .blocked(let output, let reason):
            replace(
                makeWorkflow(
                    source: source,
                    outputPath: output.path,
                    state: .failed,
                    message: reason,
                    errorMessage: reason
                ),
                persist: false
            )
        }
    }

    func preview(qBits: Int, out: String?) async {
        guard !isConversionSubmissionInFlight else { return }
        guard !workflow.sourcePath.isEmpty else {
            fail("Select a GGUF source before previewing conversion.")
            return
        }
        guard let source = selectedSource ?? restoredSource() else {
            fail("The selected GGUF source is unavailable for validation.")
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
            useExisting(model)
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
        isConversionSubmissionInFlight = true
        defer { isConversionSubmissionInFlight = false }
        update(state: .previewingConversion, outputPath: output, message: "Preparing conversion preview.", errorMessage: .some(nil))
        do {
            let response = try await api.convertPreview(workflow.sourcePath, qBits, output)
            guard let hash = response.string("preview_hash"), !hash.isEmpty else {
                fail("Conversion preview did not include a preview hash.")
                return
            }
            update(state: .readyToConfirm, outputPath: output, previewHash: hash, message: "Preview ready for confirmation.", errorMessage: .some(nil))
        } catch {
            fail("Conversion preview failed: \(AppHost.render(error))")
        }
    }

    func confirm(qBits: Int) async {
        guard !isConversionSubmissionInFlight else { return }
        guard let hash = workflow.previewHash, !hash.isEmpty else {
            fail("Preview conversion before confirming it.")
            return
        }
        guard conversionPreviewQBits == qBits,
              conversionPreviewOutput == workflow.outputPath else {
            fail("The conversion intent changed after preview. Preview it again before confirming.")
            return
        }
        guard let source = selectedSource ?? restoredSource() else {
            fail("The selected GGUF source is unavailable for validation.")
            return
        }
        switch ModelWorkflowResolver.destination(
            for: source,
            library: selectedSnapshot,
            fileManager: fileManager,
            now: now()
        ) {
        case .reuseExisting(let model):
            useExisting(model)
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

        isConversionSubmissionInFlight = true
        defer { isConversionSubmissionInFlight = false }
        do {
            let response = try await api.convertStart(workflow.sourcePath, qBits, workflow.outputPath, hash)
            // Newer agents return the receipt as an object (no path inside);
            // the authoritative receipt path only exists in convert status.
            // Prefer a plain string receipt (older agents), else resolve the
            // just-started job by output path.
            var receipt = response.string("receipt")
            if receipt == nil, let jobs = try? await api.convertStatus() {
                let target = canonicalPath(workflow.outputPath)
                receipt = jobs.first(where: {
                    guard let out = $0.out else { return false }
                    return canonicalPath(out) == target
                })?.receipt
            }
            guard let receipt, !receipt.isEmpty else {
                fail("Conversion start did not include a job receipt.")
                return
            }
            conversionPreviewQBits = nil
            conversionPreviewOutput = nil
            update(state: .queued, jobReceipt: receipt, message: "Conversion queued.", errorMessage: .some(nil), lastKnownAgentState: "queued", persist: true)
        } catch {
            fail("Conversion could not be queued: \(AppHost.render(error))")
        }
    }

    func useExisting(_ model: LibraryModel) {
        let exactPath = preferredModelPath(model, preferred: workflow.completedModelPath ?? workflow.outputPath)
        update(
            state: .completed,
            outputPath: exactPath,
            completedModelPath: exactPath,
            message: "Using existing MLX model.",
            errorMessage: .some(nil),
            persist: true
        )
    }

    func prepareServe(model: LibraryModel, exactPath: String? = nil) {
        let selectedPath = preferredModelPath(
            model,
            preferred: exactPath ?? workflow.completedModelPath ?? workflow.outputPath
        )
        update(
            state: .completed,
            outputPath: selectedPath,
            completedModelPath: selectedPath,
            message: "Ready to preview serving \(model.displayName).",
            errorMessage: .some(nil),
            persist: true
        )
        servePreviewHash = nil
        servePreviewIntent = nil
    }

    func previewServe(runtime: String, port: Int?) async {
        guard !isServeSubmissionInFlight else { return }
        isServeSubmissionInFlight = true
        defer { isServeSubmissionInFlight = false }
        guard let model = workflow.completedModelPath, !model.isEmpty else {
            update(serveState: .failed, message: "Complete or select an MLX model before previewing serve.", errorMessage: "No completed MLX model selected.")
            return
        }
        servePreviewHash = nil
        servePreviewIntent = nil
        do {
            servers = try await api.serveStatus()
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
            let response = try await api.servePreview(model, runtime, port)
            guard let hash = response.string("preview_hash"), !hash.isEmpty else {
                update(serveState: .failed, message: "Serve preview did not include a preview hash.", errorMessage: "Missing serve preview hash.")
                return
            }
            servePreviewHash = hash
            servePreviewIntent = ServeIntent(runtime: runtime, port: port)
            update(serveState: .readyToConfirm, message: "Serve preview ready for confirmation.", errorMessage: .some(nil))
        } catch {
            update(serveState: .failed, message: "Serve preview failed: \(AppHost.render(error))", errorMessage: AppHost.render(error))
        }
    }

    func confirmServe(runtime: String, port: Int?) async {
        guard !isServeSubmissionInFlight else { return }
        isServeSubmissionInFlight = true
        defer { isServeSubmissionInFlight = false }
        guard let model = workflow.completedModelPath,
              !model.isEmpty,
              let hash = servePreviewHash,
              !hash.isEmpty,
              let intent = servePreviewIntent else {
            update(serveState: .failed, message: "Preview serving before confirming it.", errorMessage: "Missing serve preview hash.")
            return
        }
        guard intent.runtime == runtime, intent.port == port else {
            servePreviewHash = nil
            servePreviewIntent = nil
            update(
                serveState: .failed,
                message: "Serve intent changed after preview. Preview it again before confirming.",
                errorMessage: "Serve intent changed after the preview (runtime or port)."
            )
            return
        }
        guard !servers.contains(where: { serverRunsModel($0, model) }) else {
            update(serveState: .failed, message: "A server is already running for the selected model.", errorMessage: "Stop the authoritative running server before starting another.")
            return
        }
        servePreviewHash = nil
        servePreviewIntent = nil
        do {
            _ = try await api.serveStart(model, runtime, port, hash)
            let statusAvailable = await refreshOperationalStatus()
            guard statusAvailable,
                  servers.contains(where: { serverRunsModel($0, model) }) else {
                update(serveState: .failed, message: "Server start was requested, but authoritative status did not report it running.", errorMessage: "Refresh server status before trying again.", persist: true)
                return
            }
            update(serveState: .running, message: "Server is running.", errorMessage: .some(nil), persist: true)
            onServeStarted?(model)
        } catch {
            update(serveState: .failed, message: "Server could not be started: \(AppHost.render(error))", errorMessage: AppHost.render(error), persist: true)
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
        do {
            _ = try await api.serveStop(port)
            let statusAvailable = await refreshOperationalStatus()
            guard statusAvailable else {
                update(serveState: .failed, message: "Server stop was requested, but authoritative status is unavailable.", errorMessage: "Refresh server status before assuming the server stopped.", persist: true)
                return
            }
            if servers.contains(where: { serverRunsModel($0, modelPath) }) {
                update(serveState: .running, message: "The authoritative server is still running.", errorMessage: "Stop was requested but has not been confirmed.", persist: true)
            } else {
                update(serveState: .stopped, message: "Server stopped.", errorMessage: .some(nil), persist: true)
            }
        } catch {
            update(serveState: .failed, message: "Server could not be stopped: \(AppHost.render(error))", errorMessage: AppHost.render(error), persist: true)
        }
    }

    func restore(_ record: ConversionWorkflow) {
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
        do {
            let jobs = try await api.convertStatus()
            await reconcileAuthoritative(snapshot: nil, jobs: jobs)
        } catch {
            preserveLastKnownState(message: "Conversion status unavailable: \(AppHost.render(error))")
        }

        do {
            servers = try await api.serveStatus()
            return true
        } catch {
            preserveLastKnownState(message: "Server status unavailable: \(AppHost.render(error))")
            return false
        }
    }

    func clearTransientError() {
        update(message: .some(nil), errorMessage: .some(nil))
    }

    /// Dismiss a terminal workflow record from history. Dismissing the active
    /// record resets the workflow to idle so Overview stops surfacing it as
    /// the next action. Persisted so the record stays dismissed on relaunch.
    func dismiss(recordID: UUID) {
        guard let record = history.first(where: { $0.id == recordID }) else { return }
        history.removeAll { $0.persistenceIdentifier == record.persistenceIdentifier }
        do {
            try persistence.remove(record.persistenceIdentifier)
        } catch {
            persistenceError = "Workflow history could not be saved: \(AppHost.render(error))"
        }
        if workflow.id == recordID {
            workflow = Self.emptyWorkflow(at: now())
        }
    }

    func consumeCompletionRescanRequest() -> Bool {
        let requested = completionRescanRequested
        completionRescanRequested = false
        return requested
    }

    func resolveCompletionAfterFreshScan(snapshot: LibrarySnapshot?) {
        let ids = pendingCompletionRecordIDs.isEmpty ? [workflow.id] : Array(pendingCompletionRecordIDs)
        for id in ids {
            guard let record = history.first(where: { $0.id == id }) else { continue }
            if let completed = completedModel(in: snapshot, for: record) {
                if let verifier = completionVerifier {
                    replace(
                        updatedRecord(
                            from: record,
                            state: .verifying,
                            outputPath: completed.path,
                            completedModelPath: completed.path,
                            message: "Conversion completed; verifying the MLX output before it is marked verified.",
                            errorMessage: .some(nil)
                        ),
                        persist: true,
                        makeCurrent: record.id == workflow.id
                    )
                    verifier.beginVerification(
                        recordID: record.id,
                        modelPath: completed.path,
                        signature: completed.model.item.signature
                    )
                } else {
                    replace(
                        updatedRecord(
                            from: record,
                            state: .completed,
                            outputPath: completed.path,
                            completedModelPath: completed.path,
                            message: "Conversion completed and the MLX output was confirmed by a fresh scan.",
                            errorMessage: .some(nil)
                        ),
                        persist: true,
                        makeCurrent: record.id == workflow.id
                    )
                }
            } else {
                replace(
                    updatedRecord(
                        from: record,
                        state: .running,
                        message: "Conversion completed, but the fresh library scan did not find its expected MLX output.",
                        errorMessage: .some(nil)
                    ),
                    persist: true,
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
    func resolveVerification(recordID: UUID, resolution: VerificationResolution) {
        guard let record = history.first(where: { $0.id == recordID }) else { return }
        if case .keptAnyway = resolution {
            guard record.state == .verifying || record.state == .verificationFailed else { return }
        } else {
            guard record.state == .verifying else { return }
        }
        switch resolution {
        case .passed(let summary):
            replace(
                updatedRecord(
                    from: record,
                    state: .verified,
                    message: "Verification passed. \(summary)",
                    errorMessage: .some(nil)
                ),
                persist: true,
                makeCurrent: record.id == workflow.id
            )
        case .failed(let summary):
            replace(
                updatedRecord(
                    from: record,
                    state: .verificationFailed,
                    message: "Verification failed. \(summary)",
                    errorMessage: .some("Verification failed. \(summary)")
                ),
                persist: true,
                makeCurrent: record.id == workflow.id
            )
        case .unavailable(let reason):
            replace(
                updatedRecord(
                    from: record,
                    state: .completed,
                    message: "Verification could not run (\(reason)); the output is complete but unverified.",
                    errorMessage: .some(nil)
                ),
                persist: true,
                makeCurrent: record.id == workflow.id
            )
        case .keptAnyway:
            replace(
                updatedRecord(
                    from: record,
                    state: .completed,
                    message: "Kept despite a failed verification (explicit override).",
                    errorMessage: .some(nil)
                ),
                persist: true,
                makeCurrent: record.id == workflow.id
            )
        }
    }

    private func reconcileAuthoritative(snapshot: LibrarySnapshot?, jobs: [Job]) async {
        var records = history
        if !records.contains(where: { $0.id == workflow.id }), workflow.jobReceipt != nil {
            records.append(workflow)
        }
        for record in records {
            guard let receipt = record.jobReceipt, !receipt.isEmpty else { continue }
            guard let job = jobs.first(where: { $0.receipt == receipt }) else {
                if record.id == workflow.id {
                    preserveLastKnownState(message: "Conversion receipt \(receipt) was not present in authoritative status.")
                }
                continue
            }

            let agentState = job.state.lowercased()
            switch agentState {
            case "queued", "pending", "starting":
                replace(updatedRecord(from: record, state: .queued, message: "Conversion queued.", errorMessage: .some(nil), lastKnownAgentState: job.state), persist: true, makeCurrent: record.id == workflow.id)
            case "running", "active":
                replace(updatedRecord(from: record, state: .running, message: "Conversion running.", errorMessage: .some(nil), lastKnownAgentState: job.state), persist: true, makeCurrent: record.id == workflow.id)
            case "completed", "complete", "succeeded", "success":
                guard record.state != .completed else { continue }
                completionRescanRequested = true
                pendingCompletionRecordIDs.insert(record.id)
                replace(updatedRecord(from: record, state: .running, message: "Conversion completed; waiting for a fresh library scan to confirm its MLX output.", errorMessage: .some(nil), lastKnownAgentState: job.state), persist: true, makeCurrent: record.id == workflow.id)
            case "failed", "error", "cancelled", "canceled":
                replace(updatedRecord(from: record, state: .failed, message: "Conversion \(job.state).", errorMessage: .some("Conversion \(job.state)."), lastKnownAgentState: job.state), persist: true, makeCurrent: record.id == workflow.id)
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
        return HFRepoID.serveIdentity(for: server.repo ?? "") == HFRepoID.serveIdentity(for: modelPath)
    }

    private func makeWorkflow(
        source: ModelItem,
        outputPath: String,
        state: ConversionWorkflowState,
        completedModelPath: String? = nil,
        message: String? = nil,
        errorMessage: String? = nil
    ) -> ConversionWorkflow {
        let timestamp = now()
        return ConversionWorkflow(
            id: UUID(),
            sourcePath: source.path,
            sourceModelKey: source.modelKey,
            sourceSignature: source.signature,
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
        clearPreviewHash: Bool = false,
        persist: Bool = false
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
        replace(next, persist: persist)
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
            lastKnownAgentState: lastKnownAgentState ?? base.lastKnownAgentState
        )
    }

    private func replace(_ record: ConversionWorkflow, persist: Bool, makeCurrent: Bool = true) {
        if makeCurrent {
            workflow = record
        }
        if let index = history.firstIndex(where: { $0.persistenceIdentifier == record.persistenceIdentifier }) {
            history[index] = record
        } else if record.state != .idle {
            history.insert(record, at: 0)
        }
        guard persist else { return }
        do {
            try persistence.upsert(record)
        } catch {
            preserveLastKnownState(message: "Workflow state could not be saved: \(AppHost.render(error))")
        }
    }

    private func preserveLastKnownState(message: String) {
        update(message: message, errorMessage: .some(nil))
    }

    private func fail(_ message: String) {
        conversionPreviewQBits = nil
        conversionPreviewOutput = nil
        update(state: .failed, previewHash: nil, message: message, errorMessage: message, clearPreviewHash: true, persist: true)
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
