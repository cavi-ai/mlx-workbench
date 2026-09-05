import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class ComparisonCoordinatorTests: XCTestCase {
    // MARK: - Builtin prompt sets

    func testBuiltinPromptSetsAreSane() {
        XCTAssertEqual(BuiltinPromptSets.all.count, 4)
        XCTAssertEqual(Set(BuiltinPromptSets.all.map(\.id)).count, 4)
        for set in BuiltinPromptSets.all {
            XCTAssertFalse(set.prompts.isEmpty, "\(set.id) has no prompts")
            XCTAssertEqual(Set(set.prompts.map(\.id)).count, set.prompts.count, "\(set.id) has duplicate entry ids")
            XCTAssertEqual(set.origin, .builtin)
            // Capability probes (tool calling) measure a capability, not a
            // use case; use-case sets must declare one.
            if set.id != BuiltinPromptSets.toolCalling.id {
                XCTAssertNotNil(set.useCase)
            }
        }
        XCTAssertTrue(BuiltinPromptSets.toolCalling.prompts.allSatisfy { $0.tool != nil })
    }

    // MARK: - Aggregation

    func testWinnerPrefersHigherThroughputThenLowerTTFT() {
        let slow = VariantResult(modelPath: "/m/slow", modelSignature: nil, samples: [Self.sample(tps: 10, ttft: 0.1)], aggregateTokensPerSecond: 10, aggregateTTFTSeconds: 0.1, error: nil)
        let fast = VariantResult(modelPath: "/m/fast", modelSignature: nil, samples: [Self.sample(tps: 40, ttft: 0.3)], aggregateTokensPerSecond: 40, aggregateTTFTSeconds: 0.3, error: nil)
        let broken = VariantResult(modelPath: "/m/broken", modelSignature: nil, samples: [], aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: "serve failed")
        let run = makeRun(results: [slow, broken, fast], state: .completed)

        XCTAssertEqual(run.winner?.modelPath, "/m/fast")
    }

    func testMedianTokensPerSecond() {
        let values = [Self.sample(tps: 10), Self.sample(tps: 30), Self.sample(tps: 20)]
        XCTAssertEqual(ComparisonAggregation.medianTokensPerSecond(values) ?? 0, 20, accuracy: 0.01)
        XCTAssertNil(ComparisonAggregation.medianTokensPerSecond([]))
    }

    // MARK: - JSONStore

    func testRunStoreRoundTripsAndUpserts() throws {
        let store = JSONStore<ComparisonRun>(fileURL: temporaryURL("runs.json"))
        var run = makeRun(results: [], state: .running)
        try store.upsert(run, id: \.id)
        run.state = .completed
        try store.upsert(run, id: \.id)

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.state, .completed)
    }

    func testRunStoreThrowsOnCorruptFileInsteadOfOverwriting() throws {
        let url = temporaryURL("runs.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url)

        let store = JSONStore<ComparisonRun>(fileURL: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.upsert(makeRun(results: [], state: .running), id: \.id))
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "not-json")
    }

    // MARK: - Coordinator runs

    func testRunMeasuresEveryVariantAndFeedsBenchmarks() async throws {
        let benchmarks = BenchmarkRecorder()
        let coordinator = makeCoordinator()
        coordinator.onBenchmarks = { benchmarks.record($0) }
        let promptSet = BuiltinPromptSets.coding

        coordinator.start(
            variants: [("/Models/q4", "sig-a"), ("/Models/q8", "sig-b")],
            promptSet: promptSet
        )

        let finished = await waitFor { coordinator.activeRunID == nil && coordinator.runs.first?.state == .completed }
        XCTAssertTrue(finished)

        let run = try XCTUnwrap(coordinator.runs.first)
        XCTAssertEqual(run.results.count, 2)
        XCTAssertEqual(Set(run.results.map(\.modelPath)), ["/Models/q4", "/Models/q8"])
        for result in run.results {
            XCTAssertNil(result.error)
            XCTAssertEqual(result.samples.count, promptSet.prompts.count)
            XCTAssertEqual(result.aggregateTokensPerSecond ?? 0, 50, accuracy: 0.01)
            XCTAssertEqual(result.aggregateTTFTSeconds ?? 0, 0.1, accuracy: 0.01)
        }

        let recorded = benchmarks.values
        XCTAssertEqual(recorded.flatMap { $0 }.count, 2)
        XCTAssertEqual(recorded.first?.first?.useCase, .coding)
        XCTAssertEqual(recorded.first?.first?.sampleCount, promptSet.prompts.count)

        let persisted = try JSONStore<ComparisonRun>(fileURL: coordinatorRunStoreURL).load()
        XCTAssertEqual(persisted.first?.state, .completed)
        XCTAssertEqual(persisted.first?.results.count, 2)
    }

    func testVariantFailureIsIsolatedAndRunCompletes() async throws {
        let coordinator = makeCoordinator(failingPaths: ["/Models/bad"])
        coordinator.start(
            variants: [("/Models/good", nil), ("/Models/bad", nil)],
            promptSet: BuiltinPromptSets.reasoning
        )

        let finished = await waitFor { coordinator.runs.first?.state == .completed }
        XCTAssertTrue(finished)

        let run = try XCTUnwrap(coordinator.runs.first)
        XCTAssertNil(run.results.first { $0.modelPath == "/Models/good" }?.error)
        XCTAssertNotNil(run.results.first { $0.modelPath == "/Models/bad" }?.error)
        XCTAssertEqual(run.winner?.modelPath, "/Models/good")
    }

    func testSecondStartIsRefusedWhileRunning() async {
        let gate = ProbeGate()
        let coordinator = makeCoordinator(gate: gate)
        coordinator.start(variants: [("/Models/q4", nil)], promptSet: BuiltinPromptSets.coding)
        let started = await waitFor { coordinator.activeRunID != nil }
        XCTAssertTrue(started)

        coordinator.start(variants: [("/Models/q8", nil)], promptSet: BuiltinPromptSets.coding)
        XCTAssertEqual(coordinator.lastError, "A comparison run is already in progress.")

        await gate.open()
        let finished = await waitFor { coordinator.activeRunID == nil }
        XCTAssertTrue(finished)
        XCTAssertEqual(coordinator.runs.count, 1)
    }

    func testInterruptedRunReconcilesToCompletedOnInit() throws {
        let url = temporaryURL("runs.json")
        let store = JSONStore<ComparisonRun>(fileURL: url)
        try store.upsert(makeRun(results: [], state: .running), id: \.id)

        let coordinator = makeCoordinator(runStoreURL: url)

        XCTAssertEqual(coordinator.runs.first?.state, .completed)
        XCTAssertNotNil(coordinator.runs.first?.finishedAt)
    }

    func testAggregateBenchmarksRehydrateFromCompletedRuns() async {
        let coordinator = makeCoordinator()
        coordinator.start(variants: [("/Models/q4", nil)], promptSet: BuiltinPromptSets.generalChat)
        let finished = await waitFor { coordinator.runs.first?.state == .completed }
        XCTAssertTrue(finished)

        let rehydrated = makeCoordinator(runStoreURL: coordinatorRunStoreURL, promptSetStoreURL: coordinatorPromptSetStoreURL)
        let benchmarks = rehydrated.aggregateBenchmarks()
        XCTAssertEqual(benchmarks.count, 1)
        XCTAssertEqual(benchmarks.first?.modelID, "/Models/q4")
        XCTAssertEqual(benchmarks.first?.useCase, .generalChat)
    }

    func testSavePromptSetPersistsUserSetsOnly() async {
        let coordinator = makeCoordinator()
        let builtinCount = coordinator.promptSets.count
        let userSet = PromptSet(
            id: UUID().uuidString,
            name: "My prompts",
            useCase: .coding,
            prompts: [PromptEntry(id: "p1", text: "Say hi.")],
            origin: .userCreated
        )

        coordinator.savePromptSet(userSet)
        coordinator.savePromptSet(BuiltinPromptSets.coding)  // builtins are code-owned

        XCTAssertEqual(coordinator.promptSets.count, builtinCount + 1)
        let reloaded = makeCoordinator(runStoreURL: coordinatorRunStoreURL, promptSetStoreURL: coordinatorPromptSetStoreURL)
        XCTAssertTrue(reloaded.promptSets.contains(where: { $0.id == userSet.id }))
    }

    // MARK: - Helpers

    private var coordinatorRunStoreURL: URL { sharedRunStoreURL }
    private var coordinatorPromptSetStoreURL: URL { sharedPromptSetStoreURL }
    private var sharedRunStoreURL: URL!
    private var sharedPromptSetStoreURL: URL!

    override func setUp() {
        super.setUp()
        sharedRunStoreURL = temporaryURL("runs.json")
        sharedPromptSetStoreURL = temporaryURL("prompt-sets.json")
    }

    private func makeCoordinator(
        runStoreURL: URL? = nil,
        promptSetStoreURL: URL? = nil,
        failingPaths: Set<String> = [],
        gate: ProbeGate? = nil
    ) -> ComparisonCoordinator {
        let probe = ServeProbe(
            lifecycle: ServeLifecycle(
                preview: { _, _ in "hash-1" },
                start: { modelPath, _, _ in
                    // A serve start failure is the realistic per-variant error.
                    if failingPaths.contains(modelPath) { throw StubServeError.failed }
                },
                stop: { _ in }
            ),
            prober: StubComparisonProber(gate: gate),
            readyPollIntervalNanoseconds: 1_000_000,
            pickPort: { 9997 }
        )
        return ComparisonCoordinator(
            probe: probe,
            runStore: JSONStore<ComparisonRun>(fileURL: runStoreURL ?? coordinatorRunStoreURL),
            promptSetStore: JSONStore<PromptSet>(fileURL: promptSetStoreURL ?? coordinatorPromptSetStoreURL)
        )
    }

    private nonisolated static func sample(tps: Double, ttft: Double = 0.1) -> ComparisonSample {
        ComparisonSample(
            promptID: UUID().uuidString,
            outputExcerpt: "output",
            tokensPerSecond: tps,
            timeToFirstTokenSeconds: ttft,
            error: nil
        )
    }

    private func makeRun(results: [VariantResult], state: ComparisonRunState) -> ComparisonRun {
        ComparisonRun(
            id: UUID(),
            promptSetID: "builtin-coding",
            promptSetName: "Coding basics",
            useCase: .coding,
            variants: results.map(\.modelPath),
            results: results,
            startedAt: Date(timeIntervalSinceReferenceDate: 10),
            finishedAt: state == .completed ? Date(timeIntervalSinceReferenceDate: 20) : nil,
            state: state
        )
    }

    private nonisolated func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-comparison-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

private final class BenchmarkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[RecommendationBenchmarkResult]] = []
    var values: [[RecommendationBenchmarkResult]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func record(_ value: [RecommendationBenchmarkResult]) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }
}

private actor ProbeGate {
    private var isOpen = false
    func wait() async {
        while !isOpen { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
    func open() { isOpen = true }
}

/// Answers every prompt with a fixed, measurable sample. The optional gate
/// blocks all answers until opened (to hold a run mid-flight).
private struct StubComparisonProber: EndpointProbing {
    let gate: ProbeGate?

    func listModels(baseURL: URL) async -> [String] { [] }

    func isReady(baseURL: URL) async -> Bool { true }

    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int) async throws -> ProbeSample {
        if let gate { await gate.wait() }
        if prompt == "Say OK." {
            return ProbeSample(text: "OK", completionTokens: 2, timeToFirstTokenSeconds: 0.01, durationSeconds: 0.02, metricsEstimated: false)
        }
        return ProbeSample(
            text: "A measured response for: \(prompt.prefix(24))",
            completionTokens: 50,
            timeToFirstTokenSeconds: 0.1,
            durationSeconds: 1.1,
            metricsEstimated: false
        )
    }
}

private enum StubServeError: Error { case failed }
