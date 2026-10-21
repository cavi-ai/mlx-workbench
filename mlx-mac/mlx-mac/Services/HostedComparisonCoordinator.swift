import Foundation

/// Runs explicitly selected endpoints. Hosted observations never enter the local benchmark store.
@MainActor
final class HostedComparisonCoordinator: ObservableObject {
    typealias Chat = @Sendable (ModelHost, String?, String, PromptEntry) async throws -> ProbeSample
    @Published private(set) var records: [HostedComparisonRecord] = []
    @Published private(set) var activeRunID: UUID?
    @Published private(set) var progress: String?
    @Published private(set) var lastError: String?
    @Published private(set) var storageError: String?
    @Published private(set) var cancelling = false
    @Published private(set) var cleanupPending = false
    let outputStore: ComparisonOutputStore
    private let store: JSONStore<HostedComparisonRecord>
    private let nativeProbe: ServeProbe?
    private let readToken: (UUID) throws -> String?
    private let freshInventory: @Sendable (ModelHost, String?) async throws -> HostInventory
    private let hostedChat: Chat
    private let comfy: ComfyWorkflowRunner
    private let recoverCleanup: @Sendable (ComparisonServerReceipt) async throws -> Void
    private let memoryProbe: @Sendable () -> MemorySnapshot?
    private let now: @Sendable () -> Date
    private var task: Task<Void, Never>?
    private var pendingNativeServer: ComparisonServerReceipt?
    /// Current local inventory and connection configuration are rechecked before each lane.
    var validateTarget: (HostedComparisonTarget) throws -> Void = { _ in }

    init(store: JSONStore<HostedComparisonRecord> = JSONStore(fileURL: JSONStore<HostedComparisonRecord>.defaultFileURL("hosted-comparison-runs.json")),
         outputStore: ComparisonOutputStore = ComparisonOutputStore(root: JSONStore<HostedComparisonRecord>.defaultFileURL("hosted-comparison-outputs")),
         nativeProbe: ServeProbe? = nil,
         readToken: @escaping (UUID) throws -> String? = HostCredentialStore.token,
         freshInventory: @escaping @Sendable (ModelHost, String?) async throws -> HostInventory = { host, token in
             try await ModelHostClient().inventory(host: host, token: token)
         },
         hostedChat: @escaping Chat = { host, token, model, prompt in
             let prober = OpenAIEndpointProber(session: HostHTTPClient.sharedSession, requestTimeout: 180, bearerToken: token)
             return try await prober.chat(baseURL: host.validatedURL(), model: model, prompt: prompt.text,
                                          maxTokens: prompt.maxTokens, tool: prompt.tool)
         }, comfy: ComfyWorkflowRunner = ComfyWorkflowRunner(),
         recoverCleanup: @escaping @Sendable (ComparisonServerReceipt) async throws -> Void = { _ in
             throw HostedIntegrationError.invalid("Reopen with the original native runtime to recover its owned server.")
         }, memoryProbe: @escaping @Sendable () -> MemorySnapshot? = MemorySnapshot.probe,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.outputStore = outputStore; self.nativeProbe = nativeProbe
        self.readToken = readToken; self.freshInventory = freshInventory; self.hostedChat = hostedChat
        self.comfy = comfy; self.recoverCleanup = recoverCleanup
        self.memoryProbe = memoryProbe; self.now = now
        do {
            var saved = try store.load().sorted { $0.run.startedAt > $1.run.startedAt }
            for index in saved.indices where saved[index].run.state == .running {
                saved[index].run.state = .interrupted; saved[index].run.finishedAt = Date()
                try store.upsert(saved[index], id: \.id)
            }
            records = saved
            if let pending = saved.first(where: { $0.run.pendingServerCleanup != nil }) {
                activeRunID = pending.id; cleanupPending = true
                progress = "A native comparison server needs cleanup before another run."
            }
        } catch { storageError = "Saved hosted comparisons are unavailable. Resolve the storage error before starting another run." }
    }

    func start(targets: [HostedComparisonTarget], promptSet: PromptSet, workflow: ComfyWorkflow? = nil) throws {
        guard storageError == nil, activeRunID == nil else {
            throw HostedIntegrationError.invalid(storageError ?? "Wait for the active comparison and its cleanup.")
        }
        let mode = promptSet.effectiveMode
        guard mode == .chat || mode == .imageGeneration, (1...4).contains(targets.count),
              Set(targets.map(\.id)).count == targets.count, (1...32).contains(promptSet.prompts.count),
              Set(promptSet.prompts.map(\.id)).count == promptSet.prompts.count,
              promptSet.prompts.allSatisfy({ !$0.id.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...4096).contains($0.maxTokens) }) else {
            throw HostedIntegrationError.invalid("Choose 1–4 distinct models and 1–32 valid prompts with at most 4096 output tokens each.")
        }
        for target in targets {
            try target.validate(mode: mode); try validateTarget(target)
            if target.host == nil && nativeProbe == nil { throw HostedIntegrationError.invalid("The native comparison runtime is unavailable.") }
        }
        if mode == .imageGeneration {
            guard let workflow else { throw HostedIntegrationError.invalid("Import and bind a ComfyUI API workflow first.") }
            try workflow.validated()
        }
        let run = ComparisonRun(id: UUID(), promptSetID: promptSet.id, promptSetName: promptSet.name,
            useCase: promptSet.useCase, variants: targets.map(\.id), results: [], startedAt: Date(), finishedAt: nil,
            state: .running, mode: mode == .chat ? nil : mode, promptEntries: promptSet.prompts)
        let record = HostedComparisonRecord(run: run, targets: targets, temperature: 0, workflow: workflow, submissions: [], conditions: [])
        try store.upsert(record, id: \.id)
        records.insert(record, at: 0); activeRunID = run.id; lastError = nil; cancelling = false
        task = Task { await execute(record.id) }
    }

    func cancel() {
        guard activeRunID != nil, !cleanupPending else { return }
        cancelling = true
        progress = "Cancelling local observation. A submitted ComfyUI job may continue on its host."
        task?.cancel()
    }

    func retryCleanup() {
        guard let id = activeRunID, cleanupPending, !cancelling,
              let record = records.first(where: { $0.id == id }),
              let server = record.run.pendingServerCleanup?.server ?? pendingNativeServer else { return }
        let pending = record.run.pendingServerCleanup
        cancelling = true
        task = Task {
            do {
                guard server.isValid else { throw HostedIntegrationError.invalid("The saved server ownership is invalid. No process was stopped.") }
                if let pending {
                    guard try store.load().first(where: { $0.id == id })?.run.pendingServerCleanup == pending else {
                        throw HostedIntegrationError.invalid("The saved server ownership changed. No process was stopped.")
                    }
                }
                try await recoverCleanup(server)
                try update(id) { $0.run.pendingServerCleanup = nil; $0.run.state = pending?.completionState ?? .failed; $0.run.finishedAt = Date() }
                pendingNativeServer = nil
                cleanupPending = false; activeRunID = nil; progress = nil; lastError = nil
            } catch { lastError = "Native server cleanup failed: \(AppHost.render(error))" }
            cancelling = false; task = nil
        }
    }

    func review(runID: UUID, targetID: String, score: Int?) {
        guard activeRunID == nil, score == nil || (1...5).contains(score!),
              records.first(where: { $0.id == runID })?.run.results.contains(where: { $0.id == targetID }) == true else { return }
        do {
            try update(runID) {
                var reviews = $0.run.qualityReviews ?? [:]
                reviews[targetID] = score.map { ComparisonQualityReview(score: $0, rubricID: "task-outcome-v1", reviewedAt: Date()) }
                $0.run.qualityReviews = reviews
            }
            lastError = nil
        } catch { lastError = "The quality review could not be saved." }
    }

    private func update(_ id: UUID, _ mutation: (inout HostedComparisonRecord) throws -> Void) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
        let original = records[index]
        var copy = original; try mutation(&copy)
        guard try store.update(id: id, keyPath: \.id, transform: { current in
            guard current == original else { throw HostedIntegrationError.invalid("The saved comparison changed. Reopen it before continuing.") }
            return copy
        }) else { throw HostedIntegrationError.invalid("The saved comparison is no longer available.") }
        records[index] = copy
    }

    private func execute(_ id: UUID) async {
        guard let original = records.first(where: { $0.id == id }), let entries = original.run.promptEntries else { return }
        var state: ComparisonRunState = .completed
        defer {
            if !cleanupPending { activeRunID = nil; progress = nil }
            cancelling = false; task = nil
        }
        do {
            for (lane, target) in original.targets.enumerated() {
                try Task.checkCancellation(); try validateTarget(target)
                progress = "Measuring \(target.displayName)…"
                var samples: [ComparisonSample] = []
                var outcome: ProbeRunResult?
                var failure: String?
                do {
                    if let host = target.host, let model = target.model {
                        let token = try readToken(host.id)
                        let fresh = try await freshInventory(host, token)
                        try target.validate(inventory: fresh, mode: original.run.effectiveMode)
                        try await recordConditions(id, target: target, inventory: fresh)
                        for entry in entries {
                            try Task.checkCancellation()
                            if let workflow = original.workflow {
                                let result = try await comfy.run(host: host, token: token, modelID: model.name, prompt: entry.text,
                                    workflow: workflow, onSubmitted: { [weak self] remoteID, graph in
                                        guard let self else { throw CancellationError() }
                                        try await self.recordSubmission(id, target: target.id, prompt: entry.id, remoteID: remoteID, graph: graph)
                                    })
                                let artifact = try await saveImage(result, runID: id, lane: lane, prompt: entry.id)
                                samples.append(ComparisonSample(promptID: entry.id, outputExcerpt: "ComfyUI image · queue-inclusive elapsed time",
                                    tokensPerSecond: nil, timeToFirstTokenSeconds: nil, error: nil, artifact: artifact, seconds: result.durationSeconds))
                            } else {
                                let sample = try await hostedChat(host, token, model.modelID, entry)
                                samples.append(ComparisonAggregation.sample(from: sample, promptID: entry.id))
                            }
                        }
                    } else if let nativeProbe, let path = target.localPath {
                        try await recordConditions(id, target: target, inventory: nil)
                        do {
                            outcome = try await nativeProbe.run(modelPath: path, prompts: entries.map {
                                ProbePrompt(id: $0.id, prompt: $0.text, maxTokens: $0.maxTokens, tool: $0.tool)
                            }, onServerStarted: { [weak self] server in
                                guard let self else { throw CancellationError() }
                                try await self.recordNativeServer(id, server: server)
                            })
                        } catch let cancelled as ServeProbeCancelled { outcome = cancelled.partial; throw CancellationError() }
                        catch {
                            if case ServeProbeError.stopFailed(_, _, let partial) = error {
                                outcome = partial
                                cleanupPending = true
                                if let server = partial?.ownedServer {
                                    pendingNativeServer = server
                                    try recordNativeServer(id, server: server)
                                }
                            }
                            throw error
                        }
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError { state = .cancelled }
                    else { state = .failed; failure = AppHost.render(error) }
                }
                if let outcome {
                    samples = entries.compactMap { entry in outcome.samples[entry.id].map { ComparisonAggregation.sample(from: $0, promptID: entry.id) } }
                }
                let result = VariantResult(modelPath: target.id, modelSignature: target.signature, samples: samples,
                    aggregateTokensPerSecond: ComparisonAggregation.medianTokensPerSecond(samples),
                    aggregateTTFTSeconds: ComparisonAggregation.bestTTFT(samples), error: failure,
                    servingEvidence: outcome?.servingEvidence, startupSeconds: outcome?.startupSeconds, systemMemory: outcome?.systemMemory)
                try update(id) {
                    $0.run.results.append(result)
                    if cleanupPending { $0.run.pendingServerCleanup?.completionState = state == .cancelled ? .cancelled : .failed }
                    else { $0.run.pendingServerCleanup = nil }
                }
                if !cleanupPending { pendingNativeServer = nil }
                if cleanupPending { progress = "Native server cleanup failed. Retry cleanup before another run."; lastError = failure; break }
                if state == .cancelled { break }
            }
            try update(id) { $0.run.state = state; $0.run.finishedAt = Date() }
        } catch {
            lastError = "The comparison could not continue: \(AppHost.render(error))"
            if pendingNativeServer != nil || records.first(where: { $0.id == id })?.run.pendingServerCleanup != nil {
                cleanupPending = true; progress = "Native server ownership is retained. Retry cleanup before another run."
            }
            do { try update(id) { $0.run.state = Task.isCancelled ? .cancelled : .failed; $0.run.finishedAt = Date() } }
            catch { storageError = "Comparison results could not be saved. Resolve the storage error before another run." }
        }
    }

    private func recordConditions(_ id: UUID, target: HostedComparisonTarget, inventory: HostInventory?) async throws {
        let probe = memoryProbe, clock = now
        let (reading, capturedAt) = await Task.detached(priority: .utility) { (probe(), clock()) }.value
        try Task.checkCancellation()
        try validateTarget(target)
        let validReading = reading.flatMap { $0.totalBytes > 0 && (0...$0.totalBytes).contains($0.availableBytes) ? $0 : nil }
        let conditions = HostedLaneConditions(targetID: target.id, memoryCapturedAt: capturedAt, systemMemory: validReading,
            reserveBytes: FitAdvisor.reserveBytes, inventoryCapturedAt: inventory?.capturedAt, activity: inventory?.activity,
            loadedModels: inventory?.reportedLoadedModels, unknownResidencyCount: inventory.map { $0.models.filter { $0.isLoaded == nil }.count },
            inventoryWarnings: inventory?.warnings, deviceMemory: inventory?.deviceMemory)
        try update(id) { record in
            if let inventory, let model = inventory.models.first(where: { $0.id == target.id }) {
                var observed = HostedComparisonTarget(host: inventory.host, model: model, capturedAt: inventory.capturedAt, runtimeVersion: inventory.runtimeVersion)
                observed.deviceSummary = inventory.deviceSummary
                record.observedTargets = (record.observedTargets ?? []) + [observed]
            }
            record.conditions = (record.conditions ?? []) + [conditions]
        }
    }

    private func recordNativeServer(_ id: UUID, server: ComparisonServerReceipt) throws {
        guard server.isValid else { throw HostedIntegrationError.invalid("The native runtime returned invalid server ownership.") }
        pendingNativeServer = server
        try update(id) { $0.run.pendingServerCleanup = ComparisonCleanup(server: server, completionState: .interrupted) }
    }

    private func recordSubmission(_ id: UUID, target: String, prompt: String, remoteID: String, graph: Data) throws {
        guard let json = String(data: graph, encoding: .utf8) else { throw HostedIntegrationError.invalid("The submitted workflow could not be recorded.") }
        try update(id) { $0.submissions.append(HostedWorkflowSubmission(id: UUID(), targetID: target, promptID: prompt,
            remotePromptID: remoteID, graphJSON: json, submittedAt: Date())) }
    }

    private func saveImage(_ result: ComfyWorkflowOutput, runID: UUID, lane: Int, prompt: String) async throws -> String {
        let store = outputStore
        return try await Task.detached {
            let name = "\(lane)-\(UUID().uuidString).\(result.fileExtension)"
            let directory = store.runDirectory(runID)
            for url in [store.root.deletingLastPathComponent(), store.root, directory] {
                if FileManager.default.fileExists(atPath: url.path) {
                    guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])).isSymbolicLink != true,
                          (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                        throw HostedIntegrationError.invalid("The comparison output directory is unsafe.")
                    }
                } else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
            }
            guard let url = store.artifactURL(runID: runID, artifact: name) else { throw HostedIntegrationError.invalid("Invalid output name.") }
            try result.imageData.write(to: url, options: .atomic)
            return name
        }.value
    }
}
