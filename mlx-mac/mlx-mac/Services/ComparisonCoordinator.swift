import Foundation

// MARK: - ComparisonCoordinator
//
// Measured Comparisons (premium spec 03). Replays a prompt set against
// selected MLX variants, one variant at a time (each on its own ephemeral
// ServeProbe server), persists the run after every variant, and feeds
// measured aggregates into the RecommendationEngine as
// RecommendationBenchmarkResult — real local evidence replacing catalog
// hints.

@MainActor
final class ComparisonCoordinator: ObservableObject {
    @Published private(set) var runs: [ComparisonRun] = []
    @Published private(set) var promptSets: [PromptSet] = []
    @Published private(set) var activeRunID: UUID?
    @Published private(set) var progressMessage: String?
    @Published private(set) var lastError: String?
    @Published private(set) var persistenceError: String?
    @Published private(set) var promptSetManagementError: String?
    @Published private(set) var savingPromptSet = false
    @Published private(set) var isCancelling = false
    @Published private(set) var cleanupPending = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var detailedRun: ComparisonRun?
    @Published private(set) var detailError: String?
    private var detailGeneration = UUID()
    private var historyLoadTask: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?
    private var reviewGeneration = 0
    private var runTask: Task<Void, Never>?
    private var pendingCleanup: (() async throws -> Void)?
    private var cleanupCompletionState: ComparisonRunState = .failed
    private let recoverCleanup: @Sendable (ComparisonServerReceipt) async throws -> Void
    private struct OwnershipRecordingError: LocalizedError {
        let errorDescription: String?
    }

    private func restorePendingCleanup() {
        guard let run = runs.first(where: { $0.pendingServerCleanup != nil }), let record = run.pendingServerCleanup else { return }
        activeRunID = run.id; cleanupPending = true; isCancelling = false
        cleanupCompletionState = record.completionState
        let recover = recoverCleanup
        pendingCleanup = {
            guard record.isValid else { throw WorkflowEvidenceError.invalid("The recorded cleanup evidence is invalid; no process was stopped.") }
            try await recover(record.server)
        }
        progressMessage = "A previous comparison needs server cleanup. Retry cleanup before starting another comparison."
    }

    private func recordServer(_ server: ComparisonServerReceipt, runID: UUID) async throws {
        guard activeRunID == runID, let index = runs.firstIndex(where: { $0.id == runID }), server.isValid else {
            throw WorkflowEvidenceError.invalid("Comparison server ownership could not be recorded.")
        }
        var updated = runs[index]
        updated.pendingServerCleanup = ComparisonCleanup(server: server, completionState: .interrupted)
        do { try await historyWorker.upsert(updated) }
        catch { throw OwnershipRecordingError(errorDescription: "Comparison ownership could not be saved: \(AppHost.render(error))") }
        runs[index] = updated
    }

    private func clearRecordedCleanup(_ id: UUID) async throws {
        guard let index = runs.firstIndex(where: { $0.id == id }), let expected = runs[index].pendingServerCleanup else { return }
        var updated = runs[index]; updated.pendingServerCleanup = nil
        let captured = updated
        let saved = try await historyWorker.update(id: id) { current in
            guard current.pendingServerCleanup == expected else {
                throw WorkflowEvidenceError.invalid("The recorded comparison cleanup changed; refresh before retrying.")
            }
            return captured
        }
        guard saved else { throw WorkflowEvidenceError.invalid("The comparison cleanup record is unavailable.") }
        runs[index] = updated
    }

    func cancel() {
        guard activeRunID != nil, !isCancelling, !cleanupPending else { return }
        isCancelling = true
        progressMessage = "Cancelling… Waiting for owned work and cleanup to finish."
        runTask?.cancel()
    }

    func retryCleanup() {
        guard let id = activeRunID, cleanupPending, !isCancelling, let cleanup = pendingCleanup else { return }
        isCancelling = true
        progressMessage = "Retrying comparison server cleanup…"
        runTask = Task {
            do {
                if let expected = runs.first(where: { $0.id == id })?.pendingServerCleanup {
                    guard try await historyWorker.record(id: id)?.pendingServerCleanup == expected else {
                        throw WorkflowEvidenceError.invalid("The recorded comparison cleanup changed. No recovery action was taken.")
                    }
                }
                try await cleanup(); try await clearRecordedCleanup(id); await finishRun(id, state: cleanupCompletionState)
            }
            catch {
                lastError = "Comparison server cleanup failed: \(AppHost.render(error))"
                progressMessage = "Cleanup failed. Retry cleanup before starting another comparison."
                isCancelling = false; runTask = nil
            }
        }
    }

    private func finishRun(_ id: UUID, state: ComparisonRunState) async {
        guard activeRunID == id, let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].state = state; runs[index].finishedAt = now()
        await persist(runs[index])
        if state == .cancelled { lastError = nil }
        onBenchmarks?(state == .completed ? benchmarks(for: runs[index]) : [])
        if let summary = try? await historyWorker.summarized(runs[index]), summary.historyDetailsOmitted == true {
            detailedRun = runs[index]; runs[index] = summary
        }
        activeRunID = nil; progressMessage = nil; isCancelling = false
        cleanupPending = false; pendingCleanup = nil; runTask = nil
        restorePendingCleanup()
    }

    private let probe: ServeProbe
    private let strataProbe: (@Sendable (StrataComparisonOptions) -> ServeProbe)?
    private let historyWorker: ComparisonHistoryWorker
    private let promptSetStore: JSONStore<PromptSet>
    private let promptInputStore: ComparisonPromptInputStore
    private let now: () -> Date
    private let mediaRunner: ComparisonMediaRunner?
    /// Where media runs keep their outputs. Nil disables media modes, so nothing here
    /// ever prunes a folder the caller did not hand over.
    let outputStore: ComparisonOutputStore?
    private let generateInput: @Sendable (PromptEntry, URL) async throws -> URL
    /// True once the saved runs were read. Output pruning keeps only the runs it knows, so it never runs on a failed load.
    private var runsLoaded = false
    var hasLoadedHistory: Bool { runsLoaded }
    var runStateUnavailableReason: String? {
        if isLoadingHistory { return "Loading saved comparisons…" }
        return runsLoaded ? nil : "Saved comparison state is unavailable. Resolve its storage error and reopen before running a comparison."
    }

    /// Receives benchmark aggregates when a run completes. AppHost wires
    /// this into `benchmarkResults` for the RecommendationEngine.
    var onBenchmarks: (([RecommendationBenchmarkResult]) -> Void)?
    /// Called after each successfully measured variant — stamps usage
    /// evidence for the Disk Pressure Advisor.
    var onVariantMeasured: ((String) -> Void)?
    /// Environment fingerprint stamped on every measured variant (spec 08
    /// follow-up): the RecommendationEngine down-weights stale evidence.
    var environmentFingerprint: () -> String? = { nil }
    /// Per-prompt max_tokens cap from Settings (wired by AppHost).
    var maxTokensCap: () -> Int = { Int.max }
    var memoryProbe: @Sendable () -> MemorySnapshot? = MemorySnapshot.probe

    init(
        probe: ServeProbe,
        runStore: JSONStore<ComparisonRun>,
        promptSetStore: JSONStore<PromptSet>,
        now: @escaping () -> Date = Date.init,
        loadHistoryInBackground: Bool = false,
        indexedHistory: Bool = false,
        mediaRunner: ComparisonMediaRunner? = nil,
        outputStore: ComparisonOutputStore? = nil,
        recoverCleanup: @escaping @Sendable (ComparisonServerReceipt) async throws -> Void = { _ in
            throw WorkflowEvidenceError.invalid("Comparison cleanup requires its configured runtime. Reopen with the original runtime available.")
        },
        strataProbe: (@Sendable (StrataComparisonOptions) -> ServeProbe)? = nil,
        generateInput: @escaping @Sendable (PromptEntry, URL) async throws -> URL = { entry, directory in
            try await ComparisonMediaFixtures.generateInput(for: entry, into: directory)
        }
    ) {
        self.probe = probe
        self.strataProbe = strataProbe
        self.historyWorker = ComparisonHistoryWorker(store: runStore, indexed: indexedHistory)
        self.promptSetStore = promptSetStore
        self.promptInputStore = ComparisonPromptInputStore(root: promptSetStore.url.deletingLastPathComponent()
            .appendingPathComponent("prompt-set-inputs", isDirectory: true))
        self.now = now
        self.mediaRunner = mediaRunner
        self.outputStore = outputStore
        self.recoverCleanup = recoverCleanup
        self.generateInput = generateInput
        if !loadHistoryInBackground && !indexedHistory {
            do {
                runs = try runStore.loadStreaming().sorted { $0.startedAt > $1.startedAt }
                runsLoaded = true
                // Interrupted runs retain measurements but cannot supply a completed cohort.
                for index in runs.indices where runs[index].state == .running {
                    runs[index].state = .interrupted
                    do { try runStore.upsertStreaming(runs[index], id: \.id) }
                    catch { persistenceError = "Interrupted comparison status could not be saved: \(AppHost.render(error))" }
                }
                for index in runs.indices where runs[index].pendingServerCleanup != nil && runs[index].state == .completed {
                    runs[index].state = .failed
                }
            } catch {
                persistenceError = "Saved comparison runs are unavailable: \(AppHost.render(error))"
            }
        }
        do {
            let userSets = try promptSetStore.load()
            promptSets = Self.builtinSets + userSets.filter { user in
                !Self.builtinSets.contains(where: { $0.id == user.id })
            }
        } catch {
            promptSets = Self.builtinSets
            persistenceError = "Saved prompt sets are unavailable: \(AppHost.render(error))"
        }
        restorePendingCleanup()
        if loadHistoryInBackground || indexedHistory {
            isLoadingHistory = true
            historyLoadTask = Task { [weak self] in await self?.loadHistory() }
        }
    }

    func waitForHistory() async { await historyLoadTask?.value }

    private func loadHistory() async {
        defer { isLoadingHistory = false; historyLoadTask = nil }
        do {
            var loaded = try await historyWorker.load().sorted { $0.startedAt > $1.startedAt }
            for index in loaded.indices where loaded[index].state == .running || loaded[index].pendingServerCleanup != nil {
                guard let full = try await historyWorker.record(id: loaded[index].id) else { throw CancellationError() }
                loaded[index] = full
            }
            for index in loaded.indices where loaded[index].state == .running {
                loaded[index].state = .interrupted
                try await historyWorker.upsert(loaded[index])
            }
            for index in loaded.indices where loaded[index].pendingServerCleanup != nil && loaded[index].state == .completed {
                loaded[index].state = .failed
            }
            runs = loaded
            runsLoaded = true
            restorePendingCleanup()
            onBenchmarks?(aggregateBenchmarks())
        } catch { persistenceError = "Saved comparison runs are unavailable: \(AppHost.render(error))" }
    }

    private static var builtinSets: [PromptSet] { BuiltinPromptSets.all + ComparisonMediaFixtures.all }

    func loadDetails(for id: UUID) async {
        guard !Task.isCancelled, runs.first(where: { $0.id == id })?.historyDetailsOmitted == true, detailedRun?.id != id else { return }
        let generation = UUID(); detailGeneration = generation; detailedRun = nil; detailError = nil
        do {
            guard let full = try await historyWorker.details(id: id) else { throw WorkflowEvidenceError.invalid("The saved comparison is unavailable.") }
            guard !Task.isCancelled, detailGeneration == generation else { return }
            detailedRun = full
        } catch is CancellationError {
            // Selection changes are not output-load failures.
        } catch { if !Task.isCancelled, detailGeneration == generation { detailError = AppHost.render(error) } }
    }

    /// Benchmark aggregates for every completed run — used to rehydrate
    /// recommendation evidence after an app restart.
    func aggregateBenchmarks() -> [RecommendationBenchmarkResult] {
        runs.filter { $0.state == .completed }.flatMap { benchmarks(for: $0) }
    }

    private struct PromptSetManagementError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func persistNewPromptSet(_ set: PromptSet) throws {
        guard !promptSets.contains(where: { $0.id == set.id }) else {
            throw PromptSetManagementError(message: "This draft has already been saved. Create a new set instead.")
        }
        try promptSetStore.upsert(set, id: \.id)
        promptSets.append(set)
        promptSetManagementError = nil
    }

    /// Create a new set in any mode, keeping failures local to this action. Saving
    /// a new or reused setup makes its media independent of source files; publish
    /// only after all copies and the durable JSON write succeed.
    func createPromptSet(_ draft: PromptSetDraft) async -> PromptSet? {
        guard !savingPromptSet, activeRunID == nil else {
            promptSetManagementError = "Wait for the current save or comparison to finish."
            return nil
        }
        savingPromptSet = true
        defer { savingPromptSet = false }
        var ownedID: UUID?
        do {
            guard draft.original == nil else { throw PromptSetManagementError(message: "Use Save changes to edit this set.") }
            let set = try await promptInputStore.copyingInputs(in: draft.promptSet())
            ownedID = set.inputStorageID
            try Task.checkCancellation()
            try persistNewPromptSet(set)
            return set
        } catch {
            if let ownedID { promptInputStore.discard(ownedID) }
            promptSetManagementError = "Prompt set could not be created: \(AppHost.render(error))"
            return nil
        }
    }

    private static func isManageablePromptSet(_ set: PromptSet) -> Bool {
        set.origin == .userCreated && !builtinSets.contains { $0.id == set.id }
    }

    func canManagePromptSet(id: String) -> Bool {
        promptSets.contains { $0.id == id && Self.isManageablePromptSet($0) }
    }

    @discardableResult
    func renamePromptSet(id: String, name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = PromptSetNameValidation.error(for: name) {
            promptSetManagementError = error
            return false
        }
        return changePromptSet(id: id) { set in
            var renamed = set
            renamed.name = name
            return renamed
        }
    }

    @discardableResult
    func removePromptSet(id: String) async -> Bool {
        var removed: PromptSet?
        guard changePromptSet(id: id, transform: { removed = $0; return nil }), let removed else { return false }
        savingPromptSet = true
        defer { savingPromptSet = false }
        await reclaimPromptInputs(of: removed)
        return true
    }

    /// Called by the Edit action, never during view evaluation. Reopening a
    /// stale editor reads the current durable set without writing it.
    func preparePromptSetEdit(id: String) -> PromptSetDraft? {
        do {
            guard activeRunID == nil, canManagePromptSet(id: id),
                  let stored = try promptSetStore.load().first(where: { $0.id == id }),
                  Self.isManageablePromptSet(stored) else {
                throw PromptSetManagementError(message: "Select a saved prompt set after the comparison finishes.")
            }
            let edit = try PromptSetDraft(set: stored)
            if let index = promptSets.firstIndex(where: { $0.id == id }) { promptSets[index] = stored }
            promptSetManagementError = nil
            return edit
        } catch {
            promptSetManagementError = "Prompt set could not be opened: \(AppHost.render(error))"
            return nil
        }
    }

    /// Preserve unchanged owned files, copy replacements, then atomically
    /// compare against the editor's original snapshot before publishing.
    func savePromptSetEdits(_ edit: PromptSetDraft) async -> Bool {
        guard !savingPromptSet, activeRunID == nil, let original = edit.original else {
            promptSetManagementError = "Select a saved prompt set after the current save or comparison finishes."
            return false
        }
        savingPromptSet = true
        defer { savingPromptSet = false }
        var newOwnedID: UUID?
        do {
            let edited = try edit.promptSet()
            let copied = try await promptInputStore.copyingInputs(in: edited, reusingInputsFrom: original)
            if copied.inputStorageID != edited.inputStorageID { newOwnedID = copied.inputStorageID }
            try Task.checkCancellation()
            let saved = changePromptSet(id: edit.id, requiredMode: edit.mode, allowingInputSave: true) { stored in
                guard stored == original else {
                    throw PromptSetManagementError(message: "The saved prompt set changed while this editor was open. Cancel and reopen it before saving.")
                }
                return copied
            }
            guard saved else {
                if let newOwnedID { promptInputStore.discard(newOwnedID) }
                return false
            }
            await reclaimPromptInputs(of: original)
            return true
        } catch {
            if let newOwnedID { promptInputStore.discard(newOwnedID) }
            promptSetManagementError = "Prompt set could not be updated: \(AppHost.render(error))"
            return false
        }
    }

    private func reclaimPromptInputs(of previous: PromptSet) async {
        guard runsLoaded, let savedRuns = try? await historyWorker.load() else { return }
        let legacy = savedRuns.filter { $0.inputArtifacts == nil }.flatMap { $0.promptEntries ?? [] }
        let store = promptSetStore, inputs = promptInputStore
        await WorkbenchIO.perform {
            guard let sets = try? store.load() else { return }
            inputs.reclaimInputs(of: previous, sets: sets, legacyEntries: legacy)
        }
    }

    private func changePromptSet(id: String, requiredMode: ComparisonMode? = nil, allowingInputSave: Bool = false,
                                 transform: (PromptSet) throws -> PromptSet?) -> Bool {
        do {
            guard activeRunID == nil, !savingPromptSet || allowingInputSave else {
                throw PromptSetManagementError(message: "Wait for the comparison to finish before managing prompt sets.")
            }
            guard let index = promptSets.firstIndex(where: { $0.id == id && Self.isManageablePromptSet($0)
                && (requiredMode == nil || $0.effectiveMode == requiredMode) }) else {
                throw PromptSetManagementError(message: "Select a saved, user-created prompt set.")
            }
            var changed: PromptSet?
            let found = try promptSetStore.update(id: id, keyPath: \.id) { stored in
                guard Self.isManageablePromptSet(stored), requiredMode == nil || stored.effectiveMode == requiredMode else {
                    throw PromptSetManagementError(message: "The saved prompt set changed. Select it again.")
                }
                changed = try transform(stored)
                return changed
            }
            guard found else { throw PromptSetManagementError(message: "The saved prompt set is no longer available.") }
            if let changed { promptSets[index] = changed }
            else {
                promptSets.remove(at: index)
            }
            promptSetManagementError = nil
            return true
        } catch {
            promptSetManagementError = "Prompt set could not be updated: \(AppHost.render(error))"
            return false
        }
    }

    @discardableResult
    func reviewQuality(runID: UUID, modelPath: String, score: Int?) -> Task<Void, Never>? {
        guard runsLoaded, score == nil || (1...5).contains(score!) else { return nil }
        let previous = reviewTask
        reviewGeneration += 1
        let generation = reviewGeneration
        let task = Task {
            await previous?.value
            defer { if reviewGeneration == generation { reviewTask = nil } }
            guard activeRunID != runID, let index = runs.firstIndex(where: { $0.id == runID && $0.state == .completed }),
                  runs[index].results.contains(where: { $0.id == modelPath }) else { return }
            let visible = runs[index]
            do {
                guard let original = try await historyWorker.record(id: runID) else {
                    throw WorkflowEvidenceError.invalid("The saved comparison is unavailable. Reopen its results before rating it.")
                }
                let summary = try await historyWorker.summarized(original)
                guard original == visible || summary == visible else {
                    throw WorkflowEvidenceError.invalid("The saved comparison changed. Reopen its results before rating it.")
                }
                var updated = original
                var reviews = updated.qualityReviews ?? [:]
                let rubric = updated.effectiveMode == .musicGeneration
                    ? ComparisonQualityReview.musicListeningRubric : ComparisonQualityReview.taskOutcomeRubric
                reviews[modelPath] = score.map { ComparisonQualityReview(score: $0, rubricID: rubric, reviewedAt: now()) }
                updated.qualityReviews = reviews
                let captured = updated
                let saved = try await historyWorker.update(id: runID) { current in
                    guard current == original else { throw WorkflowEvidenceError.invalid("The saved comparison changed. Reopen its results before rating it.") }
                    return captured
                }
                guard saved, let currentIndex = runs.firstIndex(where: { $0.id == runID }), runs[currentIndex] == visible else {
                    throw WorkflowEvidenceError.invalid("The saved comparison is unavailable. Reopen its results before rating it.")
                }
                runs[currentIndex] = try await historyWorker.summarized(updated)
                if detailedRun?.id == runID { detailedRun = updated }
                persistenceError = nil
            } catch { persistenceError = "Task review could not be saved: \(AppHost.render(error))" }
        }
        reviewTask = task
        return task
    }

    func requireCurrentSuggestion(_ expected: ComparisonRun) async throws -> VariantResult {
        guard runsLoaded, activeRunID == nil else { throw WorkflowEvidenceError.invalid("Wait for comparison history and the current comparison to finish.") }
        guard let current = try await historyWorker.record(id: expected.id), activeRunID == nil, current == expected,
              let id = current.settingsSearchCandidateID, let result = current.results.first(where: { $0.id == id }) else {
            throw WorkflowEvidenceError.invalid("The suggested comparison changed or is no longer eligible. Review its current results again.")
        }
        return result
    }

    func recordedRun(id: UUID) async throws -> ComparisonRun? {
        guard runsLoaded else { throw WorkflowEvidenceError.invalid("Saved comparison history is unavailable.") }
        return try await historyWorker.record(id: id)
    }

    func requireCurrentProfileLane(_ expected: ComparisonRun, laneID: String) async throws -> VariantResult {
        guard runsLoaded, activeRunID == nil else { throw WorkflowEvidenceError.invalid("Wait for comparison history and the current comparison to finish.") }
        guard let current = try await recordedRun(id: expected.id), activeRunID == nil, current == expected, current.state == .completed,
              current.effectiveMode == .chat, current.hasValidLaneIdentities,
              let lane = current.laneConfigurations?.first(where: { $0.id == laneID }), lane.servingProfileID != nil,
              current.results.filter({ $0.id == laneID }).count == 1,
              let result = current.results.first(where: { $0.id == laneID }), result.error == nil,
              result.modelPath == lane.modelPath, result.modelSignature == lane.modelSignature,
              let prompts = current.promptEntries, !prompts.isEmpty, Set(prompts.map(\.id)).count == prompts.count,
              result.samples.count == prompts.count, Set(result.samples.map(\.promptID)) == Set(prompts.map(\.id)),
              result.samples.allSatisfy(\.hasCompletedAnswer),
              let evidence = result.servingEvidence, evidence.runtime == "strata",
              evidence.modelFingerprint?.isEmpty == false, evidence.runtimeFingerprint?.isEmpty == false,
              evidence.speculation == lane.strataOptions?.speculation, evidence.expertMemoryGB == lane.strataOptions?.expertMemoryGB,
              evidence.contextTokens == lane.strataOptions?.contextTokens else {
            throw WorkflowEvidenceError.invalid("The measured profile lane changed or lacks complete matching evidence. Review its current comparison again.")
        }
        return result
    }

    /// Opt-in: import the user's real opencode prompts as a comparison
    /// prompt set. Returns the durably saved set, or nil when import or saving fails.
    /// The button press is the consent; import only happens here.
    @discardableResult
    func importHistory(databasePath: String? = PromptHistoryImport.defaultDatabasePath()) -> PromptSet? {
        guard let databasePath else {
            lastError = "No opencode history found on this machine."
            return nil
        }
        guard let result = PromptHistoryImport.importPrompts(databasePath: databasePath) else {
            lastError = "No usable prompts found in the opencode history."
            return nil
        }
        let set = PromptSet(
            id: UUID().uuidString,
            name: "My opencode prompts (\(result.prompts.count))",
            useCase: .coding,
            prompts: result.prompts.map { PromptEntry(id: UUID().uuidString, text: $0) },
            origin: .userCreated
        )
        do {
            try persistNewPromptSet(set)
            lastError = nil
            return set
        } catch {
            lastError = "Prompts could not be imported: \(AppHost.render(error))"
            return nil
        }
    }

    /// Start a comparison run. One run at a time; variants are measured
    /// sequentially so memory pressure from one server never contaminates
    /// another variant's numbers. Chat replays prompts on the serve probe;
    /// every other mode runs each prompt through the media runner and keeps
    /// what the model produced.
    func start(lanes: [ComparisonLaneConfiguration], promptSet: PromptSet, settingsSearchGoal: StrataSettingsSearchGoal? = nil) {
        start(variants: lanes.map { ($0.modelPath, $0.modelSignature) }, promptSet: promptSet,
              mode: .chat, laneConfigurations: lanes, settingsSearchGoal: settingsSearchGoal)
    }

    func start(variants: [(path: String, signature: String?)], promptSet: PromptSet, mode: ComparisonMode? = nil,
               strataOptions: [String: StrataComparisonOptions] = [:],
               laneConfigurations: [ComparisonLaneConfiguration]? = nil, settingsSearchGoal: StrataSettingsSearchGoal? = nil) {
        if let reason = runStateUnavailableReason { lastError = reason; return }
        if let goal = settingsSearchGoal, !goal.matches(laneConfigurations ?? []) {
            lastError = "Settings search requires four matching lanes at one fixed context."; return
        }
        guard !savingPromptSet else {
            lastError = "Wait for the prompt set save to finish."
            return
        }
        guard activeRunID == nil else {
            lastError = "A comparison run is already in progress."
            return
        }
        guard !variants.isEmpty, !promptSet.prompts.isEmpty else {
            lastError = "Select at least one variant and a non-empty prompt set."
            return
        }
        let mode = mode ?? promptSet.effectiveMode
        if let lanes = laneConfigurations {
            guard mode == .chat, lanes.count <= 4, lanes.count == variants.count,
                  lanes.map(\.modelPath) == variants.map(\.path), lanes.allSatisfy(\.isValid),
                  Set(lanes.map(\.id)).count == lanes.count, strataOptions.isEmpty,
                  lanes.allSatisfy({ $0.strataOptions == nil || strataProbe != nil }) else {
                lastError = "Each chat lane needs a unique identity and valid serving settings."
                return
            }
            let repeatedPaths = Set(lanes.filter { lane in lanes.filter { $0.modelPath == lane.modelPath }.count > 1 }.map(\.modelPath))
            guard lanes.filter({ repeatedPaths.contains($0.modelPath) }).allSatisfy({ $0.strataOptions != nil }) else {
                lastError = "Repeated model selections require independent Strata settings."
                return
            }
        } else if Set(variants.map(\.path)).count != variants.count {
            lastError = "Repeated model selections require independent comparison lanes."
            return
        }
        if !strataOptions.isEmpty {
            guard mode == .chat, strataProbe != nil, Set(strataOptions.keys).isSubset(of: Set(variants.map(\.path))),
                  strataOptions.values.allSatisfy({ $0.validationError == nil }) else {
                lastError = "Strata settings require valid chat variants and a configured serving runtime."
                return
            }
        }
        guard promptSet.effectiveMode == mode else {
            lastError = "\(promptSet.name) is a \(promptSet.effectiveMode.title) prompt set, not \(mode.title)."
            return
        }
        if mode != .chat {
            guard mediaRunner != nil, outputStore != nil else {
                lastError = "\(mode.title) comparisons are not available in this build."
                return
            }
        }
        lastError = nil
        let run = ComparisonRun(
            id: UUID(),
            promptSetID: promptSet.id,
            promptSetName: promptSet.name,
            useCase: promptSet.useCase,
            variants: variants.map(\.path),
            results: [],
            startedAt: now(),
            finishedAt: nil,
            state: .running,
            mode: mode == .chat ? nil : mode,
            promptEntries: promptSet.prompts,
            strataOptions: strataOptions.isEmpty ? nil : strataOptions,
            laneConfigurations: laneConfigurations,
            settingsSearchGoal: settingsSearchGoal
        )
        activeRunID = run.id
        progressMessage = "Saving comparison…"
        runTask = Task { [probe, now] in
            do { try await historyWorker.upsert(run) }
            catch {
                persistenceError = "Comparison could not be saved: \(AppHost.render(error))"
                lastError = "Resolve the comparison storage error before starting a run."
                activeRunID = nil; progressMessage = nil; isCancelling = false; runTask = nil
                return
            }
            runs.insert(run, at: 0)
            if Task.isCancelled { await finishRun(run.id, state: .cancelled); return }
            if mode == .chat {
                await execute(runID: run.id, variants: variants, promptSet: promptSet, probe: probe, now: now,
                              strataOptions: strataOptions, laneConfigurations: laneConfigurations,
                              warmEachPrompt: settingsSearchGoal?.warmEachPrompt == true)
            } else if let mediaRunner, let outputStore {
                await executeMedia(runID: run.id, mode: mode, variants: variants, promptSet: promptSet,
                                   runner: mediaRunner, store: outputStore)
            }
        }
    }

    /// Keeps the output folders of the newest media runs; the run just added counts.
    private func pruneOutputs(store: ComparisonOutputStore) {
        guard runsLoaded else { return }
        let keep = runs.filter { $0.effectiveMode != .chat }.prefix(ComparisonOutputStore.retainedRuns).map(\.id)
        store.prune(keeping: Set(keep))
    }

    private func executeMedia(
        runID: UUID,
        mode: ComparisonMode,
        variants: [(path: String, signature: String?)],
        promptSet: PromptSet,
        runner: ComparisonMediaRunner,
        store: ComparisonOutputStore
    ) async {
        guard !Task.isCancelled else { await finishRun(runID, state: .cancelled); return }
        var setupError: String?
        do {
            try store.createRunDirectory(runID)
        } catch {
            setupError = "Output folder could not be created: \(AppHost.render(error))"
        }

        // Every variant uses the same saved input; later changes to the original
        // user-picked file cannot change a cohort halfway through replay.
        var inputs: [String: URL] = [:]
        var inputArtifacts: [String: String] = [:]
        var inputLanguages: [String: String] = [:]
        var inputErrors: [String: String] = [:]
        if setupError == nil, mode.inputKind != nil {
            for entry in promptSet.prompts {
                if Task.isCancelled { break }
                progressMessage = "Preparing input for \(entry.id)…"
                if let builtin = entry.builtinInput {
                    inputLanguages[entry.id] = ComparisonMediaFixtures.language(ofBuiltinInput: builtin)
                }
                if let path = entry.inputPath {
                    do {
                        guard path.hasPrefix("/") else { throw ComparisonOutputStore.InputError.unavailable }
                        let artifact = try await store.snapshotInput(from: URL(fileURLWithPath: path), runID: runID)
                        inputs[entry.id] = store.inputArtifactURL(runID: runID, artifact: artifact)
                        inputArtifacts[entry.id] = artifact
                    } catch {
                        inputErrors[entry.id] = "Input could not be saved: \(AppHost.render(error))"
                    }
                } else if entry.builtinInput != nil {
                    do {
                        let url = try await generateInput(entry, store.inputsDirectory(runID))
                        guard url.deletingLastPathComponent().standardizedFileURL == store.inputsDirectory(runID).standardizedFileURL,
                              store.readableInputArtifactURL(runID: runID, artifact: url.lastPathComponent) != nil else {
                            throw ComparisonOutputStore.InputError.unsafeLocation
                        }
                        let artifact = try await store.snapshotInput(from: url, runID: runID)
                        // Only this freshly generated, owned file is removed. User-picked
                        // originals are never changed by the snapshot operation.
                        try FileManager.default.removeItem(at: url)
                        inputs[entry.id] = store.inputArtifactURL(runID: runID, artifact: artifact)
                        inputArtifacts[entry.id] = artifact
                    } catch {
                        inputErrors[entry.id] = "Input could not be generated: \(AppHost.render(error))"
                    }
                } else {
                    inputErrors[entry.id] = ComparisonMediaError.missingInput.localizedDescription
                }
            }
        }

        if mode.inputKind != nil, let index = runs.firstIndex(where: { $0.id == runID }) {
            runs[index].inputArtifacts = inputArtifacts
            await persist(runs[index])
        }
        guard !Task.isCancelled else { await finishRun(runID, state: .cancelled); return }
        // Reused inputs can belong to the oldest retained run. Copy them into
        // this run before pruning their source folder.
        pruneOutputs(store: store)

        for (variantIndex, variant) in variants.enumerated() {
            guard !Task.isCancelled else { await finishRun(runID, state: .cancelled); return }
            guard let runIndex = runs.firstIndex(where: { $0.id == runID }) else { return }
            let name = URL(fileURLWithPath: variant.path).lastPathComponent
            var samples: [ComparisonSample] = []
            if let setupError {
                samples = promptSet.prompts.map { ComparisonMediaScoring.failedSample(promptID: $0.id, message: setupError) }
            } else {
                for (promptIndex, entry) in promptSet.prompts.enumerated() {
                    if Task.isCancelled { break }
                    progressMessage = "Measuring \(name) · prompt \(promptIndex + 1) of \(promptSet.prompts.count)…"
                    if let message = inputErrors[entry.id] {
                        samples.append(ComparisonMediaScoring.failedSample(promptID: entry.id, message: message))
                        continue
                    }
                    let artifact = ComparisonOutputStore.artifactName(
                        variantIndex: variantIndex, promptID: entry.id, kind: mode.outputKind
                    )
                    let artifactURL = store.artifactURL(runID: runID, artifact: artifact)
                    let request = MediaRunRequest(
                        mode: mode,
                        modelPath: variant.path,
                        entry: entry,
                        inputURL: inputs[entry.id],
                        outputURL: mode.outputKind == .text ? nil : artifactURL,
                        maxTokens: min(entry.maxTokens, maxTokensCap()),
                        language: inputLanguages[entry.id]
                    )
                    do {
                        let output = try await runner.run(request)
                        try Task.checkCancellation()
                        if let url = request.outputURL, !FileManager.default.fileExists(atPath: url.path) {
                            throw ComparisonMediaError.outputNotWritten
                        }
                        if mode.outputKind == .text, let artifactURL {
                            try Data((output.text ?? "").utf8).write(to: artifactURL, options: .atomic)
                        }
                        samples.append(ComparisonMediaScoring.sample(mode: mode, entry: entry, output: output, artifact: artifact))
                    } catch {
                        if Task.isCancelled { break }
                        samples.append(ComparisonMediaScoring.failedSample(promptID: entry.id, message: AppHost.render(error)))
                    }
                }
            }

            if samples.isEmpty && Task.isCancelled { await finishRun(runID, state: .cancelled); return }
            let failures = samples.compactMap(\.error)
            let allFailed = failures.count == samples.count
            let result = VariantResult(
                modelPath: variant.path,
                modelSignature: variant.signature,
                samples: samples,
                aggregateTokensPerSecond: nil,
                aggregateTTFTSeconds: nil,
                error: allFailed ? failures.first : nil,
                environmentFingerprint: allFailed ? nil : environmentFingerprint(),
                aggregateMetric: ComparisonMediaScoring.aggregateMetric(samples, mode: mode)
            )
            runs[runIndex].results.append(result)
            await persist(runs[runIndex])
            if Task.isCancelled { await finishRun(runID, state: .cancelled); return }
            if result.error == nil {
                onVariantMeasured?(variant.path)
            }
        }

        await finishRun(runID, state: .completed)
    }

    private func execute(
        runID: UUID,
        variants: [(path: String, signature: String?)],
        promptSet: PromptSet,
        probe: ServeProbe,
        now: () -> Date,
        strataOptions: [String: StrataComparisonOptions],
        laneConfigurations: [ComparisonLaneConfiguration]?,
        warmEachPrompt: Bool
    ) async {
        let prompts = promptSet.prompts.map {
            ProbePrompt(id: $0.id, prompt: $0.text, maxTokens: min($0.maxTokens, maxTokensCap()), tool: $0.tool)
        }

        for (variantIndex, variant) in variants.enumerated() {
            guard let runIndex = runs.firstIndex(where: { $0.id == runID }) else { return }
            guard !Task.isCancelled else { await finishRun(runID, state: .cancelled); return }
            progressMessage = "Measuring \(URL(fileURLWithPath: variant.path).lastPathComponent)…"
            let options = laneConfigurations?[variantIndex].strataOptions ?? strataOptions[variant.path]
            var selectedProbe = options.flatMap { self.strataProbe?($0) } ?? probe
            selectedProbe.memoryProbe = memoryProbe
            var outcome: ProbeRunResult?
            var failure: String?
            var cleanupPort: Int?
            var cancelled = false
            var recordingFailed = false
            do {
                outcome = try await selectedProbe.run(modelPath: variant.path, prompts: prompts,
                    warmup: [ProbePrompt(id: "__warmup", prompt: "Say OK.", maxTokens: 4)], warmEachPrompt: warmEachPrompt,
                    onServerStarted: { [weak self] server in
                        guard let self else { throw CancellationError() }
                        try await self.recordServer(server, runID: runID)
                    })
            } catch let stopped as ServeProbeCancelled {
                outcome = stopped.partial; cancelled = true
            } catch {
                if case ServeProbeError.stopFailed(_, let port, let partial) = error { cleanupPort = port; outcome = partial }
                recordingFailed = error is OwnershipRecordingError
                failure = AppHost.render(error)
            }
            let samples = promptSet.prompts.compactMap { entry in
                outcome?.samples[entry.id].map { ComparisonAggregation.sample(from: $0, promptID: entry.id) }
            }
            let result = VariantResult(modelPath: variant.path, modelSignature: variant.signature, samples: samples,
                aggregateTokensPerSecond: ComparisonAggregation.medianTokensPerSecond(samples),
                aggregateTTFTSeconds: ComparisonAggregation.bestTTFT(samples), error: failure,
                environmentFingerprint: outcome == nil ? nil : environmentFingerprint(), servingEvidence: outcome?.servingEvidence,
                startupSeconds: outcome?.startupSeconds, laneID: laneConfigurations?[variantIndex].id, systemMemory: outcome?.systemMemory)
            if !samples.isEmpty || (!Task.isCancelled && !cancelled) || cleanupPort != nil {
                runs[runIndex].results.append(result)
                await persist(runs[runIndex])
            }
            if let port = cleanupPort {
                runs[runIndex].state = .failed
                runs[runIndex].finishedAt = now()
                let completion: ComparisonRunState = Task.isCancelled || cancelled ? .cancelled : .failed
                if runs[runIndex].pendingServerCleanup == nil, let server = outcome?.ownedServer {
                    runs[runIndex].pendingServerCleanup = ComparisonCleanup(server: server, completionState: completion)
                }
                runs[runIndex].pendingServerCleanup?.completionState = completion
                await persist(runs[runIndex])
                let lifecycle = selectedProbe.lifecycle
                if let record = runs[runIndex].pendingServerCleanup {
                    let recover = recoverCleanup
                    pendingCleanup = { try await recover(record.server) }
                } else { pendingCleanup = { try await lifecycle.stop(port) } }
                cleanupCompletionState = completion
                cleanupPending = true; isCancelling = false; runTask = nil
                lastError = failure
                progressMessage = "Cleanup failed. Retry cleanup before starting another comparison."
                return
            }
            do { try await clearRecordedCleanup(runID) }
            catch {
                runs[runIndex].state = .failed; await persist(runs[runIndex])
                lastError = "Comparison cleanup could not be saved: \(AppHost.render(error))"
                restorePendingCleanup(); runTask = nil
                return
            }
            if recordingFailed { await finishRun(runID, state: .failed); return }
            if Task.isCancelled || cancelled { await finishRun(runID, state: .cancelled); return }
            if result.error == nil {
                onVariantMeasured?(variant.path)
            }
        }

        await finishRun(runID, state: .completed)
    }

    private func benchmarks(for run: ComparisonRun) -> [RecommendationBenchmarkResult] {
        guard run.state == .completed, run.effectiveMode == .chat, !run.hasCustomServingConfiguration,
              let measuredAt = run.finishedAt else { return [] }
        let useCase = run.useCase ?? .generalChat
        return run.results.compactMap { result in
            guard result.error == nil, !result.samples.isEmpty else { return nil }
            return RecommendationBenchmarkResult(
                modelID: result.modelPath,
                useCase: useCase,
                tokensPerSecond: result.aggregateTokensPerSecond,
                timeToFirstTokenSeconds: result.aggregateTTFTSeconds,
                measuredAt: measuredAt,
                sampleCount: result.samples.count,
                environmentFingerprint: result.environmentFingerprint
            )
        }
    }

    private func persist(_ run: ComparisonRun) async {
        do {
            try await historyWorker.upsert(run)
        } catch {
            persistenceError = "Comparison run could not be saved: \(AppHost.render(error))"
        }
    }
}
