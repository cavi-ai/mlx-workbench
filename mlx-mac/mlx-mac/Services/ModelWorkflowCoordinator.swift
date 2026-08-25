import Foundation

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

    static func live(store: ModelWorkflowStore) -> ModelWorkflowPersistence {
        ModelWorkflowPersistence(load: store.load, upsert: store.upsert)
    }
}

@MainActor
final class ModelWorkflowCoordinator: ObservableObject {
    @Published private(set) var workflow: ConversionWorkflow
    @Published private(set) var history: [ConversionWorkflow]
    @Published private(set) var servers: [ServerInfo]

    private let api: ModelWorkflowAPI
    private let persistence: ModelWorkflowPersistence
    private let now: () -> Date
    private var completionRescanRequested = false
    private var servePreviewHash: String?

    init(
        api: ModelWorkflowAPI,
        persistence: ModelWorkflowPersistence,
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.persistence = persistence
        self.now = now
        self.workflow = Self.emptyWorkflow(at: now())
        self.history = []
        self.servers = []

        do {
            let records = try persistence.load().sorted { $0.updatedAt > $1.updatedAt }
            history = records
            if let active = records.first(where: { $0.state != .completed && $0.state != .failed }) ?? records.first {
                workflow = active
            }
        } catch {
            workflow = Self.emptyWorkflow(at: now(), message: "Saved workflow history is unavailable: \(AppHost.render(error))")
        }
    }

    func inspect(source: ModelItem, snapshot: LibrarySnapshot?) {
        let timestamp = now()
        switch ModelWorkflowResolver.destination(for: source, library: snapshot) {
        case .reuseExisting(let model):
            replace(
                makeWorkflow(
                    source: source,
                    outputPath: model.item.path,
                    state: .existingModelFound,
                    completedModelPath: model.item.path,
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
        _ = timestamp
    }

    func preview(qBits: Int, out: String?) async {
        guard !workflow.sourcePath.isEmpty else {
            fail("Select a GGUF source before previewing conversion.")
            return
        }
        let output = safeOutputOverride(out) ?? workflow.outputPath
        update(state: .previewingConversion, outputPath: output, message: "Preparing conversion preview.", errorMessage: nil)
        do {
            let response = try await api.convertPreview(workflow.sourcePath, qBits, output)
            guard let hash = response.string("preview_hash"), !hash.isEmpty else {
                fail("Conversion preview did not include a preview hash.")
                return
            }
            update(state: .readyToConfirm, outputPath: output, previewHash: hash, message: "Preview ready for confirmation.", errorMessage: nil)
        } catch {
            fail("Conversion preview failed: \(AppHost.render(error))")
        }
    }

    func confirm(qBits: Int) async {
        guard let hash = workflow.previewHash, !hash.isEmpty else {
            fail("Preview conversion before confirming it.")
            return
        }
        do {
            let response = try await api.convertStart(workflow.sourcePath, qBits, workflow.outputPath, hash)
            guard let receipt = response.string("receipt"), !receipt.isEmpty else {
                fail("Conversion start did not include a job receipt.")
                return
            }
            update(state: .queued, jobReceipt: receipt, message: "Conversion queued.", errorMessage: nil, lastKnownAgentState: "queued", persist: true)
        } catch {
            fail("Conversion could not be queued: \(AppHost.render(error))")
        }
    }

    func useExisting(_ model: LibraryModel) {
        update(
            state: .completed,
            completedModelPath: model.item.path,
            message: "Using existing MLX model.",
            errorMessage: nil,
            persist: true
        )
    }

    func prepareServe(model: LibraryModel) {
        update(
            state: workflow.state == .idle ? .completed : workflow.state,
            completedModelPath: model.item.path,
            message: "Ready to preview serving \(model.displayName).",
            errorMessage: nil,
            persist: true
        )
    }

    func previewServe(runtime: String, port: Int?) async {
        guard let model = workflow.completedModelPath, !model.isEmpty else {
            update(serveState: .failed, message: "Complete or select an MLX model before previewing serve.", errorMessage: "No completed MLX model selected.")
            return
        }
        update(serveState: .previewing, message: "Preparing serve preview.", errorMessage: nil)
        do {
            let response = try await api.servePreview(model, runtime, port)
            guard let hash = response.string("preview_hash"), !hash.isEmpty else {
                update(serveState: .failed, message: "Serve preview did not include a preview hash.", errorMessage: "Missing serve preview hash.")
                return
            }
            servePreviewHash = hash
            update(serveState: .readyToConfirm, message: "Serve preview ready for confirmation.", errorMessage: nil)
        } catch {
            update(serveState: .failed, message: "Serve preview failed: \(AppHost.render(error))", errorMessage: AppHost.render(error))
        }
    }

    func confirmServe(runtime: String, port: Int?) async {
        guard let model = workflow.completedModelPath, !model.isEmpty, let hash = servePreviewHash, !hash.isEmpty else {
            update(serveState: .failed, message: "Preview serving before confirming it.", errorMessage: "Missing serve preview hash.")
            return
        }
        do {
            _ = try await api.serveStart(model, runtime, port, hash)
            update(serveState: .running, message: "Server start requested.", errorMessage: nil, persist: true)
            await refreshOperationalStatus()
        } catch {
            update(serveState: .failed, message: "Server could not be started: \(AppHost.render(error))", errorMessage: AppHost.render(error), persist: true)
        }
    }

    func stopServer() async {
        guard let server = servers.first(where: { $0.state?.lowercased() == "running" }), let port = server.port else {
            update(serveState: .failed, message: "No authoritative running server port is available to stop.", errorMessage: "Server status is unavailable.")
            return
        }
        do {
            _ = try await api.serveStop(port)
            update(serveState: .stopped, message: "Server stop requested.", errorMessage: nil, persist: true)
            await refreshOperationalStatus()
        } catch {
            update(serveState: .failed, message: "Server could not be stopped: \(AppHost.render(error))", errorMessage: AppHost.render(error), persist: true)
        }
    }

    func restore(_ record: ConversionWorkflow) {
        workflow = record
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

    func refreshOperationalStatus() async {
        do {
            let jobs = try await api.convertStatus()
            await reconcileAuthoritative(snapshot: nil, jobs: jobs)
        } catch {
            preserveLastKnownState(message: "Conversion status unavailable: \(AppHost.render(error))")
        }

        do {
            servers = try await api.serveStatus()
        } catch {
            preserveLastKnownState(message: "Server status unavailable: \(AppHost.render(error))")
        }
    }

    func clearTransientError() {
        update(message: nil, errorMessage: nil)
    }

    func consumeCompletionRescanRequest() -> Bool {
        let requested = completionRescanRequested
        completionRescanRequested = false
        return requested
    }

    func resolveCompletionAfterFreshScan(snapshot: LibrarySnapshot?) {
        guard let model = completedModel(in: snapshot) else {
            update(
                state: .running,
                message: "Conversion completed, but the fresh library scan did not find its expected MLX output.",
                errorMessage: nil,
                persist: true
            )
            return
        }
        update(
            state: .completed,
            completedModelPath: model.item.path,
            message: "Conversion completed and the MLX output was confirmed by a fresh scan.",
            errorMessage: nil,
            persist: true
        )
    }

    private func reconcileAuthoritative(snapshot: LibrarySnapshot?, jobs: [Job]) async {
        guard let receipt = workflow.jobReceipt, !receipt.isEmpty else { return }
        guard let job = jobs.first(where: { $0.receipt == receipt }) else {
            preserveLastKnownState(message: "Conversion receipt \(receipt) was not present in authoritative status.")
            return
        }

        let agentState = job.state.lowercased()
        switch agentState {
        case "queued", "pending", "starting":
            update(state: .queued, message: "Conversion queued.", errorMessage: nil, lastKnownAgentState: job.state, persist: true)
        case "running", "active":
            update(state: .running, message: "Conversion running.", errorMessage: nil, lastKnownAgentState: job.state, persist: true)
        case "completed", "complete", "succeeded", "success":
            completionRescanRequested = true
            update(state: .running, message: "Conversion completed; waiting for a fresh library scan to confirm its MLX output.", errorMessage: nil, lastKnownAgentState: job.state, persist: true)
        case "failed", "error", "cancelled", "canceled":
            update(state: .failed, message: "Conversion \(job.state).", errorMessage: "Conversion \(job.state).", lastKnownAgentState: job.state, persist: true)
        default:
            preserveLastKnownState(message: "Conversion status \(job.state) is not recognized; preserving the last known state.")
        }
        _ = snapshot
    }

    private func completedModel(in snapshot: LibrarySnapshot?) -> LibraryModel? {
        snapshot?.models.first { model in
            model.item.path == workflow.outputPath ||
            model.outputPaths.contains(workflow.outputPath) ||
            model.sourcePaths.contains(workflow.outputPath)
        }
    }

    private func safeOutputOverride(_ output: String?) -> String? {
        guard let output else { return nil }
        let candidate = URL(fileURLWithPath: NSString(string: output).expandingTildeInPath).standardizedFileURL
        let sourceDirectory = URL(fileURLWithPath: workflow.sourcePath).standardizedFileURL.deletingLastPathComponent()
        guard candidate.deletingLastPathComponent() == sourceDirectory else { return nil }
        return candidate.path
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
        persist: Bool = false
    ) {
        let next = ConversionWorkflow(
            id: workflow.id,
            sourcePath: workflow.sourcePath,
            sourceModelKey: workflow.sourceModelKey,
            sourceSignature: workflow.sourceSignature,
            outputPath: outputPath ?? workflow.outputPath,
            previewHash: previewHash ?? workflow.previewHash,
            jobReceipt: jobReceipt ?? workflow.jobReceipt,
            completedModelPath: completedModelPath ?? workflow.completedModelPath,
            state: state ?? workflow.state,
            serveState: serveState ?? workflow.serveState,
            message: message ?? workflow.message,
            errorMessage: errorMessage ?? workflow.errorMessage,
            createdAt: workflow.createdAt,
            updatedAt: now(),
            lastKnownAgentState: lastKnownAgentState ?? workflow.lastKnownAgentState
        )
        replace(next, persist: persist)
    }

    private func replace(_ record: ConversionWorkflow, persist: Bool) {
        workflow = record
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
        update(message: message, errorMessage: nil)
    }

    private func fail(_ message: String) {
        update(state: .failed, message: message, errorMessage: message, persist: true)
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
