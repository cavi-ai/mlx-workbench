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

    private let probe: ServeProbe
    private let runStore: JSONStore<ComparisonRun>
    private let promptSetStore: JSONStore<PromptSet>
    private let now: () -> Date
    private let mediaRunner: ComparisonMediaRunner?
    /// Where media runs keep their outputs. Nil disables media modes, so nothing here
    /// ever prunes a folder the caller did not hand over.
    let outputStore: ComparisonOutputStore?
    private let generateInput: @Sendable (PromptEntry, URL) async throws -> URL
    /// True once the saved runs were read. Output pruning keeps only the runs it knows, so it never runs on a failed load.
    private var runsLoaded = false

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

    init(
        probe: ServeProbe,
        runStore: JSONStore<ComparisonRun>,
        promptSetStore: JSONStore<PromptSet>,
        now: @escaping () -> Date = Date.init,
        mediaRunner: ComparisonMediaRunner? = nil,
        outputStore: ComparisonOutputStore? = nil,
        generateInput: @escaping @Sendable (PromptEntry, URL) async throws -> URL = { entry, directory in
            try await ComparisonMediaFixtures.generateInput(for: entry, into: directory)
        }
    ) {
        self.probe = probe
        self.runStore = runStore
        self.promptSetStore = promptSetStore
        self.now = now
        self.mediaRunner = mediaRunner
        self.outputStore = outputStore
        self.generateInput = generateInput
        do {
            runs = try runStore.load().sorted { $0.startedAt > $1.startedAt }
            runsLoaded = true
            // A run interrupted by an app quit can never resume its in-flight
            // probe; reconcile it to completed with its partial (real,
            // measured) results instead of leaving a phantom running run.
            for index in runs.indices where runs[index].state == .running {
                runs[index].state = .completed
                runs[index].finishedAt = runs[index].finishedAt ?? now()
                try? runStore.upsert(runs[index], id: \.id)
            }
        } catch {
            persistenceError = "Saved comparison runs are unavailable: \(AppHost.render(error))"
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
    }

    private static var builtinSets: [PromptSet] { BuiltinPromptSets.all + ComparisonMediaFixtures.all }

    /// Benchmark aggregates for every completed run — used to rehydrate
    /// recommendation evidence after an app restart.
    func aggregateBenchmarks() -> [RecommendationBenchmarkResult] {
        runs.filter { $0.state == .completed }.flatMap { benchmarks(for: $0) }
    }

    @discardableResult
    func savePromptSet(_ set: PromptSet) -> Bool {
        guard set.origin == .userCreated else { return false }
        do {
            try promptSetStore.upsert(set, id: \.id)
            if let index = promptSets.firstIndex(where: { $0.id == set.id }) {
                promptSets[index] = set
            } else {
                promptSets.append(set)
            }
            return true
        } catch {
            persistenceError = "Prompt set could not be saved: \(AppHost.render(error))"
            return false
        }
    }

    private struct PromptSetManagementError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Create from a validated draft, keeping failures local to this action and
    /// publishing only after the atomic store accepts the new identity.
    func createMusicPromptSet(_ draft: MusicPromptSetDraft) -> PromptSet? {
        do {
            let set = try draft.promptSet()
            try persistNewPromptSet(set)
            return set
        } catch {
            promptSetManagementError = "Prompt set could not be created: \(AppHost.render(error))"
            return nil
        }
    }

    func createPromptSet(_ draft: ComparisonPromptSetDraft) -> PromptSet? {
        do {
            guard draft.original == nil else { throw PromptSetManagementError(message: "Use Save changes to edit this set.") }
            let set = try draft.promptSet()
            try persistNewPromptSet(set)
            return set
        } catch {
            promptSetManagementError = "Prompt set could not be created: \(AppHost.render(error))"
            return nil
        }
    }

    private func persistNewPromptSet(_ set: PromptSet) throws {
        guard !promptSets.contains(where: { $0.id == set.id }) else {
            throw PromptSetManagementError(message: "This draft has already been saved. Create a new set instead.")
        }
        try promptSetStore.upsert(set, id: \.id)
        promptSets.append(set)
        promptSetManagementError = nil
    }

    private static func isManageablePromptSet(_ set: PromptSet) -> Bool {
        set.origin == .userCreated && !builtinSets.contains { $0.id == set.id }
    }

    private static func isManageableMusicPromptSet(_ set: PromptSet) -> Bool {
        isManageablePromptSet(set) && set.effectiveMode == .musicGeneration
    }

    func canManagePromptSet(id: String) -> Bool {
        promptSets.contains { $0.id == id && Self.isManageablePromptSet($0) }
    }

    func canManageMusicPromptSet(id: String) -> Bool {
        promptSets.contains { $0.id == id && Self.isManageableMusicPromptSet($0) }
    }

    @discardableResult
    func renameMusicPromptSet(id: String, name: String) -> Bool {
        renameSavedPromptSet(id: id, name: name, requiredMode: .musicGeneration)
    }

    @discardableResult
    func renamePromptSet(id: String, name: String) -> Bool {
        renameSavedPromptSet(id: id, name: name, requiredMode: nil)
    }

    private func renameSavedPromptSet(id: String, name: String, requiredMode: ComparisonMode?) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.unicodeScalars.contains(where: { $0.value < 32 }) else {
            promptSetManagementError = "Enter a prompt set name without control characters."
            return false
        }
        return changePromptSet(id: id, requiredMode: requiredMode) { set in
            var renamed = set
            renamed.name = name
            return renamed
        }
    }

    @discardableResult
    func removeMusicPromptSet(id: String) -> Bool {
        changePromptSet(id: id, requiredMode: .musicGeneration) { _ in nil }
    }

    @discardableResult
    func removePromptSet(id: String) -> Bool {
        changePromptSet(id: id) { _ in nil }
    }

    func preparePromptSetEdit(id: String) -> ComparisonPromptSetDraft? {
        do {
            guard activeRunID == nil, canManagePromptSet(id: id),
                  let stored = try promptSetStore.load().first(where: { $0.id == id }),
                  Self.isManageablePromptSet(stored) else {
                throw PromptSetManagementError(message: "Select a saved prompt set after the comparison finishes.")
            }
            let edit = try ComparisonPromptSetDraft(set: stored)
            if let index = promptSets.firstIndex(where: { $0.id == id }) { promptSets[index] = stored }
            promptSetManagementError = nil
            return edit
        } catch {
            promptSetManagementError = "Prompt set could not be opened: \(AppHost.render(error))"
            return nil
        }
    }

    @discardableResult
    func savePromptSetEdits(_ edit: ComparisonPromptSetDraft) -> Bool {
        changePromptSet(id: edit.id, requiredMode: edit.mode) { stored in
            guard stored == edit.original else {
                throw PromptSetManagementError(message: "The saved prompt set changed while this editor was open. Cancel and reopen it before saving.")
            }
            return try edit.promptSet()
        }
    }

    /// Called by the Edit action, never during view evaluation. Reopening a
    /// stale editor reads the current durable set without writing it.
    func prepareMusicPromptSetEdit(id: String) -> MusicPromptSetEdit? {
        do {
            guard activeRunID == nil, canManageMusicPromptSet(id: id) else {
                throw PromptSetManagementError(message: "Select a saved music prompt set after the comparison finishes.")
            }
            guard let stored = try promptSetStore.load().first(where: { $0.id == id }),
                  Self.isManageableMusicPromptSet(stored) else {
                throw PromptSetManagementError(message: "The saved music prompt set is no longer available.")
            }
            let edit = try MusicPromptSetEdit(set: stored)
            if let index = promptSets.firstIndex(where: { $0.id == id }) { promptSets[index] = stored }
            promptSetManagementError = nil
            return edit
        } catch {
            promptSetManagementError = "Music prompt set could not be opened: \(AppHost.render(error))"
            return nil
        }
    }

    @discardableResult
    func saveMusicPromptSetEdits(_ edit: MusicPromptSetEdit) -> Bool {
        changePromptSet(id: edit.id, requiredMode: .musicGeneration) { stored in
            guard stored == edit.original else {
                throw PromptSetManagementError(message: "The saved prompt set changed while this editor was open. Cancel and reopen it before saving.")
            }
            return try edit.updatedPromptSet()
        }
    }

    private func changePromptSet(id: String, requiredMode: ComparisonMode? = nil, transform: (PromptSet) throws -> PromptSet?) -> Bool {
        do {
            guard activeRunID == nil else {
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
            else { promptSets.remove(at: index) }
            promptSetManagementError = nil
            return true
        } catch {
            promptSetManagementError = "Prompt set could not be updated: \(AppHost.render(error))"
            return false
        }
    }

    func reviewQuality(runID: UUID, modelPath: String, score: Int?) {
        guard activeRunID != runID, let index = runs.firstIndex(where: { $0.id == runID && $0.state == .completed }),
              runs[index].results.contains(where: { $0.modelPath == modelPath }),
              score == nil || (1...5).contains(score!) else { return }
        var updated = runs[index]
        var reviews = updated.qualityReviews ?? [:]
        let rubric = updated.effectiveMode == .musicGeneration
            ? ComparisonQualityReview.musicListeningRubric : ComparisonQualityReview.taskOutcomeRubric
        reviews[modelPath] = score.map { ComparisonQualityReview(score: $0, rubricID: rubric, reviewedAt: now()) }
        updated.qualityReviews = reviews
        do {
            try runStore.upsert(updated, id: \.id)
            runs[index] = updated
        } catch { persistenceError = "Task review could not be saved: \(AppHost.render(error))" }
    }

    /// Opt-in: import the user's real opencode prompts as a comparison
    /// prompt set. Returns the created set, or nil when no history exists.
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
        savePromptSet(set)
        lastError = nil
        return set
    }

    /// Start a comparison run. One run at a time; variants are measured
    /// sequentially so memory pressure from one server never contaminates
    /// another variant's numbers. Chat replays prompts on the serve probe;
    /// every other mode runs each prompt through the media runner and keeps
    /// what the model produced.
    func start(variants: [(path: String, signature: String?)], promptSet: PromptSet, mode: ComparisonMode? = nil) {
        guard activeRunID == nil else {
            lastError = "A comparison run is already in progress."
            return
        }
        guard !variants.isEmpty, !promptSet.prompts.isEmpty else {
            lastError = "Select at least one variant and a non-empty prompt set."
            return
        }
        let mode = mode ?? promptSet.effectiveMode
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
            promptEntries: promptSet.prompts
        )
        runs.insert(run, at: 0)
        activeRunID = run.id

        if mode == .chat {
            Task { [probe, now] in
                await execute(runID: run.id, variants: variants, promptSet: promptSet, probe: probe, now: now)
            }
        } else if let mediaRunner, let outputStore {
            pruneOutputs(store: outputStore)
            Task {
                await executeMedia(
                    runID: run.id, mode: mode, variants: variants, promptSet: promptSet,
                    runner: mediaRunner, store: outputStore
                )
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
        var setupError: String?
        do {
            try store.createRunDirectory(runID)
        } catch {
            setupError = "Output folder could not be created: \(AppHost.render(error))"
        }

        // Inputs are shared by every variant: user-picked files as they are,
        // built-in ones generated once into the run's inputs folder.
        var inputs: [String: URL] = [:]
        var inputLanguages: [String: String] = [:]
        var inputErrors: [String: String] = [:]
        if setupError == nil, mode.inputKind != nil {
            for entry in promptSet.prompts {
                progressMessage = "Preparing input for \(entry.id)…"
                if let path = entry.inputPath {
                    var isDirectory: ObjCBool = false
                    if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                        inputs[entry.id] = URL(fileURLWithPath: path)
                    } else {
                        inputErrors[entry.id] = "Input file not found: \(path)"
                    }
                } else if let builtin = entry.builtinInput {
                    do {
                        inputs[entry.id] = try await generateInput(entry, store.inputsDirectory(runID))
                        inputLanguages[entry.id] = ComparisonMediaFixtures.language(ofBuiltinInput: builtin)
                    } catch {
                        inputErrors[entry.id] = "Input could not be generated: \(AppHost.render(error))"
                    }
                } else {
                    inputErrors[entry.id] = ComparisonMediaError.missingInput.localizedDescription
                }
            }
        }

        for (variantIndex, variant) in variants.enumerated() {
            guard let runIndex = runs.firstIndex(where: { $0.id == runID }) else { return }
            let name = URL(fileURLWithPath: variant.path).lastPathComponent
            var samples: [ComparisonSample] = []
            if let setupError {
                samples = promptSet.prompts.map { ComparisonMediaScoring.failedSample(promptID: $0.id, message: setupError) }
            } else {
                for (promptIndex, entry) in promptSet.prompts.enumerated() {
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
                        if let url = request.outputURL, !FileManager.default.fileExists(atPath: url.path) {
                            throw ComparisonMediaError.outputNotWritten
                        }
                        if mode.outputKind == .text, let artifactURL {
                            try Data((output.text ?? "").utf8).write(to: artifactURL, options: .atomic)
                        }
                        samples.append(ComparisonMediaScoring.sample(mode: mode, entry: entry, output: output, artifact: artifact))
                    } catch {
                        samples.append(ComparisonMediaScoring.failedSample(promptID: entry.id, message: AppHost.render(error)))
                    }
                }
            }

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
            persist(runs[runIndex])
            if result.error == nil {
                onVariantMeasured?(variant.path)
            }
        }

        guard let finalIndex = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[finalIndex].finishedAt = now()
        runs[finalIndex].state = .completed
        persist(runs[finalIndex])
        activeRunID = nil
        progressMessage = nil
    }

    private func execute(
        runID: UUID,
        variants: [(path: String, signature: String?)],
        promptSet: PromptSet,
        probe: ServeProbe,
        now: () -> Date
    ) async {
        let prompts = promptSet.prompts.map {
            ProbePrompt(id: $0.id, prompt: $0.text, maxTokens: min($0.maxTokens, maxTokensCap()), tool: $0.tool)
        }

        for variant in variants {
            guard let runIndex = runs.firstIndex(where: { $0.id == runID }) else { return }
            progressMessage = "Measuring \(URL(fileURLWithPath: variant.path).lastPathComponent)…"
            let result: VariantResult
            do {
                // Warm-up: one throwaway prompt so first-token load cost does
                // not contaminate measured TTFT.
                _ = try await probe.run(
                    modelPath: variant.path,
                    prompts: [ProbePrompt(id: "__warmup", prompt: "Say OK.", maxTokens: 4)]
                )
                let outcome = try await probe.run(modelPath: variant.path, prompts: prompts)
                let samples = promptSet.prompts.compactMap { entry in
                    outcome.samples[entry.id].map {
                        ComparisonAggregation.sample(from: $0, promptID: entry.id)
                    }
                }
                result = VariantResult(
                    modelPath: variant.path,
                    modelSignature: variant.signature,
                    samples: samples,
                    aggregateTokensPerSecond: ComparisonAggregation.medianTokensPerSecond(samples),
                    aggregateTTFTSeconds: ComparisonAggregation.bestTTFT(samples),
                    error: nil,
                    environmentFingerprint: environmentFingerprint()
                )
            } catch {
                result = VariantResult(
                    modelPath: variant.path,
                    modelSignature: variant.signature,
                    samples: [],
                    aggregateTokensPerSecond: nil,
                    aggregateTTFTSeconds: nil,
                    error: AppHost.render(error)
                )
            }
            runs[runIndex].results.append(result)
            persist(runs[runIndex])
            if result.error == nil {
                onVariantMeasured?(variant.path)
            }
        }

        guard let finalIndex = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[finalIndex].finishedAt = now()
        runs[finalIndex].state = .completed
        persist(runs[finalIndex])
        activeRunID = nil
        progressMessage = nil
        onBenchmarks?(benchmarks(for: runs[finalIndex]))
    }

    private func benchmarks(for run: ComparisonRun) -> [RecommendationBenchmarkResult] {
        guard run.state == .completed, run.effectiveMode == .chat, let measuredAt = run.finishedAt else { return [] }
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

    private func persist(_ run: ComparisonRun) {
        do {
            try runStore.upsert(run, id: \.id)
        } catch {
            persistenceError = "Comparison run could not be saved: \(AppHost.render(error))"
        }
    }
}
