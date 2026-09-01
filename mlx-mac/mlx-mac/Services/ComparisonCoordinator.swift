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

    private let probe: ServeProbe
    private let runStore: JSONStore<ComparisonRun>
    private let promptSetStore: JSONStore<PromptSet>
    private let now: () -> Date

    /// Receives benchmark aggregates when a run completes. AppHost wires
    /// this into `benchmarkResults` for the RecommendationEngine.
    var onBenchmarks: (([RecommendationBenchmarkResult]) -> Void)?
    /// Called after each successfully measured variant — stamps usage
    /// evidence for the Disk Pressure Advisor.
    var onVariantMeasured: ((String) -> Void)?
    /// Environment fingerprint stamped on every measured variant (spec 08
    /// follow-up): the RecommendationEngine down-weights stale evidence.
    var environmentFingerprint: () -> String? = { nil }

    init(
        probe: ServeProbe,
        runStore: JSONStore<ComparisonRun>,
        promptSetStore: JSONStore<PromptSet>,
        now: @escaping () -> Date = Date.init
    ) {
        self.probe = probe
        self.runStore = runStore
        self.promptSetStore = promptSetStore
        self.now = now
        do {
            runs = try runStore.load().sorted { $0.startedAt > $1.startedAt }
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
            promptSets = BuiltinPromptSets.all + userSets.filter { user in
                !BuiltinPromptSets.all.contains(where: { $0.id == user.id })
            }
        } catch {
            promptSets = BuiltinPromptSets.all
            persistenceError = "Saved prompt sets are unavailable: \(AppHost.render(error))"
        }
    }

    /// Benchmark aggregates for every completed run — used to rehydrate
    /// recommendation evidence after an app restart.
    func aggregateBenchmarks() -> [RecommendationBenchmarkResult] {
        runs.filter { $0.state == .completed }.flatMap { benchmarks(for: $0) }
    }

    func savePromptSet(_ set: PromptSet) {
        guard set.origin == .userCreated else { return }
        do {
            try promptSetStore.upsert(set, id: \.id)
            if let index = promptSets.firstIndex(where: { $0.id == set.id }) {
                promptSets[index] = set
            } else {
                promptSets.append(set)
            }
        } catch {
            persistenceError = "Prompt set could not be saved: \(AppHost.render(error))"
        }
    }

    /// Start a comparison run. One run at a time; variants are measured
    /// sequentially so memory pressure from one server never contaminates
    /// another variant's numbers.
    func start(variants: [(path: String, signature: String?)], promptSet: PromptSet) {
        guard activeRunID == nil else {
            lastError = "A comparison run is already in progress."
            return
        }
        guard !variants.isEmpty, !promptSet.prompts.isEmpty else {
            lastError = "Select at least one variant and a non-empty prompt set."
            return
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
            state: .running
        )
        runs.insert(run, at: 0)
        activeRunID = run.id

        Task { [probe, now] in
            await execute(runID: run.id, variants: variants, promptSet: promptSet, probe: probe, now: now)
        }
    }

    private func execute(
        runID: UUID,
        variants: [(path: String, signature: String?)],
        promptSet: PromptSet,
        probe: ServeProbe,
        now: () -> Date
    ) async {
        let prompts = promptSet.prompts.map {
            ProbePrompt(id: $0.id, prompt: $0.text, maxTokens: $0.maxTokens)
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
        guard run.state == .completed, let measuredAt = run.finishedAt else { return [] }
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
