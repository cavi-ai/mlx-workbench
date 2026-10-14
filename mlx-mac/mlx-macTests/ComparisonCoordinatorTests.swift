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

    func testLocalStrataLaneComparisonWhenRequested() async throws {
        guard let manifestPath = ProcessInfo.processInfo.environment["MLX_WORKBENCH_STRATA_LANE_MANIFEST"] else {
            throw XCTSkip("Set MLX_WORKBENCH_STRATA_LANE_MANIFEST for an explicit local Strata lane comparison.")
        }
        struct Manifest: Decodable {
            let agentPath: String
            let modelPath: String
            let evidenceRoot: String
            let expertMemoryGB: Double
            let contextTokens: Int
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        guard [manifest.agentPath, manifest.modelPath, manifest.evidenceRoot].allSatisfy({ $0.hasPrefix("/") }) else {
            throw NSError(domain: "StrataLaneAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: "Manifest paths must be absolute."])
        }
        let directory = URL(fileURLWithPath: manifest.evidenceRoot, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: manifest.agentPath, receiptDirectory: directory.path)
        let events = ComparisonProbeEvents()
        let factory: @Sendable (StrataComparisonOptions) -> ServeProbe = { options in
            var lifecycle = ServeLifecycle.live(api: api, runtime: "strata", strataOptions: options)
            let preview = lifecycle.reviewedPreview!
            let start = lifecycle.start
            let stop = lifecycle.stop
            lifecycle.reviewedPreview = { path, port in
                await events.record("preview:\(options.speculation)")
                return try await preview(path, port)
            }
            lifecycle.start = { path, port, hash in
                await events.record("start:\(options.speculation)")
                try await start(path, port, hash)
            }
            lifecycle.stop = { port in
                try await stop(port)
                let stillReady = await OpenAIEndpointProber().isReady(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
                XCTAssertFalse(stillReady, "The stopped lane endpoint must be released before another lane loads")
                await events.record("stop:\(options.speculation)")
            }
            return ServeProbe(lifecycle: lifecycle, prober: OpenAIEndpointProber(requestTimeout: 900), readyTimeout: 900)
        }
        let lanes = [false, true].map { speculation in
            ComparisonLaneConfiguration(id: UUID().uuidString, modelPath: manifest.modelPath, modelSignature: nil,
                strataOptions: StrataComparisonOptions(speculation: speculation, expertMemoryGB: manifest.expertMemoryGB,
                                                       contextTokens: manifest.contextTokens))
        }
        let coordinator = ComparisonCoordinator(probe: factory(StrataComparisonOptions()),
            runStore: JSONStore(fileURL: directory.appendingPathComponent("runs.json")),
            promptSetStore: JSONStore(fileURL: directory.appendingPathComponent("prompts.json")), strataProbe: factory)
        let promptSet = PromptSet(id: "strata-lane-acceptance", name: "Strata lanes", useCase: nil,
            prompts: [PromptEntry(id: "p1", text: "Calculate 17 times 19. In your final answer, return only JSON with one key named answer and its numeric value.", maxTokens: 1024)], origin: .userCreated)
        let finished = expectation(description: "both real Strata lanes finished")
        coordinator.onBenchmarks = { values in XCTAssertTrue(values.isEmpty); finished.fulfill() }
        coordinator.start(lanes: lanes, promptSet: promptSet)
        await fulfillment(of: [finished], timeout: 1800)
        let run = try XCTUnwrap(coordinator.runs.first)
        XCTAssertEqual(run.laneConfigurations, lanes)
        XCTAssertEqual(run.results.map(\.id), lanes.map(\.id))
        XCTAssertEqual(run.results.count, 2)
        for (lane, result) in zip(lanes, run.results) {
            XCTAssertNil(result.error)
            XCTAssertEqual(result.modelPath, manifest.modelPath)
            XCTAssertEqual(result.servingEvidence?.speculation, lane.strataOptions?.speculation)
            XCTAssertEqual(result.servingEvidence?.expertMemoryGB, manifest.expertMemoryGB)
            XCTAssertEqual(result.servingEvidence?.contextTokens, manifest.contextTokens)
            let sample = try XCTUnwrap(result.samples.first)
            XCTAssertTrue(sample.hasCompletedAnswer)
            XCTAssertNotNil(sample.timeToFirstAnswerSeconds)
            XCTAssertEqual(sample.finishReason, "stop")
            XCTAssertEqual(sample.metricsEstimated, false)
            XCTAssertGreaterThan(sample.completionTokens ?? 0, 0)
            XCTAssertFalse((sample.reasoningText ?? "").isEmpty)
        }
        XCTAssertEqual(Set(run.results.compactMap { $0.servingEvidence?.modelFingerprint }).count, 1)
        XCTAssertEqual(Set(run.results.compactMap { $0.servingEvidence?.runtimeFingerprint }).count, 1)
        let ordered = await events.values
        XCTAssertEqual(ordered, ["preview:false", "start:false", "stop:false", "preview:true", "start:true", "stop:true"])
        XCTAssertEqual(try ComparisonRunSetup(run: run).laneConfigurations, lanes)
    }

    func testSameModelLanesKeepSettingsResultsReviewsAndReuseIndependent() async throws {
        let events = ComparisonProbeEvents()
        let factory: @Sendable (StrataComparisonOptions) -> ServeProbe = { options in
            ServeProbe(lifecycle: ServeLifecycle(preview: { path, _ in
                await events.record("preview:\(path):\(options.speculation)"); return "hash"
            }, start: { path, _, _ in await events.record("start:\(path)") },
                stop: { _ in await events.record("stop") }), prober: LaneComparisonProber(speculation: options.speculation), pickPort: { 9997 })
        }
        let lanes = [
            ComparisonLaneConfiguration(id: "lane-a", modelPath: "/Models/strata", modelSignature: "sig",
                strataOptions: StrataComparisonOptions(expertMemoryGB: 2, contextTokens: 8192)),
            ComparisonLaneConfiguration(id: "lane-b", modelPath: "/Models/strata", modelSignature: "sig",
                strataOptions: StrataComparisonOptions(speculation: true, expertMemoryGB: 2, contextTokens: 8192))]
        let coordinator = ComparisonCoordinator(probe: factory(StrataComparisonOptions()),
            runStore: JSONStore(fileURL: coordinatorRunStoreURL), promptSetStore: JSONStore(fileURL: coordinatorPromptSetStoreURL),
            strataProbe: factory)
        let finished = expectation(description: "both lanes finished")
        coordinator.onBenchmarks = { values in XCTAssertTrue(values.isEmpty); finished.fulfill() }
        coordinator.start(lanes: lanes, promptSet: BuiltinPromptSets.coding)
        await fulfillment(of: [finished], timeout: 5)
        let run = try XCTUnwrap(coordinator.runs.first)
        XCTAssertEqual(run.results.map(\.id), ["lane-a", "lane-b"])
        XCTAssertEqual(run.results.map(\.modelPath), ["/Models/strata", "/Models/strata"])
        XCTAssertEqual(ComparePresentation.lanes(for: run).map(\.resultKey), ["lane-a", "lane-b"])
        XCTAssertEqual(ComparePresentation.lanes(for: run).compactMap(\.value), [10, 20])
        XCTAssertEqual(run.results.map { $0.samples.first?.fullOutput }, ["answer-a", "answer-b"])
        XCTAssertEqual(ComparisonDiff.pairs(run.results[0], run.results[1]).count, BuiltinPromptSets.coding.prompts.count)
        let ordered = await events.values
        XCTAssertEqual(ordered, ["preview:/Models/strata:false", "start:/Models/strata", "stop",
                                "preview:/Models/strata:true", "start:/Models/strata", "stop"])
        coordinator.reviewQuality(runID: run.id, modelPath: "lane-a", score: 2)
        coordinator.reviewQuality(runID: run.id, modelPath: "lane-b", score: 5)
        let persisted = try XCTUnwrap(JSONStore<ComparisonRun>(fileURL: coordinatorRunStoreURL).load().first)
        XCTAssertEqual(persisted.qualityReviews?["lane-a"]?.score, 2)
        XCTAssertEqual(persisted.qualityReviews?["lane-b"]?.score, 5)
        XCTAssertEqual(try ComparisonRunSetup(run: persisted).laneConfigurations, lanes)
        XCTAssertTrue(coordinator.aggregateBenchmarks().isEmpty)
    }

    func testInvalidLaneIdentitiesAndUnconfiguredRepeatedModelsNeverStart() {
        let coordinator = makeCoordinator()
        let repeated = [ComparisonLaneConfiguration(id: "same", modelPath: "/Models/a", modelSignature: nil),
                        ComparisonLaneConfiguration(id: "same", modelPath: "/Models/b", modelSignature: nil)]
        coordinator.start(lanes: repeated, promptSet: BuiltinPromptSets.coding)
        XCTAssertNil(coordinator.activeRunID)
        XCTAssertTrue(coordinator.runs.isEmpty)
        let unconfigured = [ComparisonLaneConfiguration(id: "a", modelPath: "/Models/a", modelSignature: nil),
                            ComparisonLaneConfiguration(id: "b", modelPath: "/Models/a", modelSignature: nil)]
        coordinator.start(lanes: unconfigured, promptSet: BuiltinPromptSets.coding)
        XCTAssertNil(coordinator.activeRunID)
        XCTAssertTrue(coordinator.runs.isEmpty)
    }

    func testLegacyRunDecodingPreservesPathsAndDoesNotInventCompletionOrLanes() throws {
        let original = makeRun(results: [VariantResult(modelPath: "/Models/a", modelSignature: "sig", samples: [
            ComparisonSample(promptID: "p", outputExcerpt: "historical", tokensPerSecond: 10,
                             timeToFirstTokenSeconds: 0.1, error: nil)],
            aggregateTokensPerSecond: 10, aggregateTTFTSeconds: 0.1, error: nil)], state: .completed)
        let decoded = try JSONDecoder().decode(ComparisonRun.self, from: JSONEncoder().encode(original))
        XCTAssertNil(decoded.laneConfigurations)
        XCTAssertEqual(decoded.variantIdentities, ["/Models/a"])
        XCTAssertEqual(decoded.results.first?.id, "/Models/a")
        XCTAssertNil(decoded.results.first?.samples.first?.reasoningText)
        XCTAssertNil(decoded.results.first?.samples.first?.finishReason)
        XCTAssertNil(decoded.results.first?.samples.first?.completionDescription)
    }

    func testLocalStrataSettingsComparisonWhenRequested() async throws {
        guard let manifestPath = ProcessInfo.processInfo.environment["MLX_WORKBENCH_STRATA_COMPARISON_MANIFEST"] else {
            throw XCTSkip("Set MLX_WORKBENCH_STRATA_COMPARISON_MANIFEST for an explicit local Strata comparison.")
        }
        struct Manifest: Decodable {
            let agentPath: String
            let modelPath: String
            let evidenceRoot: String
            let expertMemoryGB: Double
            let contextTokens: Int
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        let directory = URL(fileURLWithPath: manifest.evidenceRoot, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: manifest.agentPath, receiptDirectory: directory.path)
        let factory: (StrataComparisonOptions) -> ServeProbe = { options in
            ServeProbe(lifecycle: .live(api: api, runtime: "strata", strataOptions: options),
                       prober: OpenAIEndpointProber(requestTimeout: 900), readyTimeout: 900)
        }
        let coordinator = ComparisonCoordinator(probe: factory(StrataComparisonOptions()),
            runStore: JSONStore(fileURL: directory.appendingPathComponent("runs.json")),
            promptSetStore: JSONStore(fileURL: directory.appendingPathComponent("prompts.json")), strataProbe: factory)
        let prompt = PromptSet(id: "local-strata-controls", name: "Strata settings", useCase: nil,
            prompts: [PromptEntry(id: "p1", text: "Explain how a hash table handles collisions using separate chaining. Give a short example.", maxTokens: 128)], origin: .userCreated)
        for speculation in [false, true] {
            let options = StrataComparisonOptions(speculation: speculation, expertMemoryGB: manifest.expertMemoryGB,
                                                   contextTokens: manifest.contextTokens)
            XCTAssertNil(options.validationError)
            let finished = expectation(description: "comparison finished")
            coordinator.onBenchmarks = { _ in finished.fulfill() }
            coordinator.start(variants: [(manifest.modelPath, nil)], promptSet: prompt,
                              strataOptions: [manifest.modelPath: options])
            await fulfillment(of: [finished], timeout: 1800)
            XCTAssertNil(coordinator.activeRunID)
            let run = try XCTUnwrap(coordinator.runs.first)
            let result = try XCTUnwrap(run.results.first)
            XCTAssertNil(result.error)
            XCTAssertEqual(result.servingEvidence?.speculation, speculation)
            XCTAssertEqual(result.servingEvidence?.expertMemoryGB, options.expertMemoryGB)
            XCTAssertEqual(result.servingEvidence?.contextTokens, options.contextTokens)
            XCTAssertFalse(result.samples.isEmpty)
            if let sample = result.samples.first {
                XCTAssertFalse((sample.fullOutput ?? sample.outputExcerpt).isEmpty)
                XCTAssertNotNil(sample.timeToFirstTokenSeconds)
            }
            guard result.error == nil else { return }
        }
    }

    func testStopFailurePreventsLoadingAnotherVariant() async throws {
        let events = ComparisonProbeEvents()
        let probe = ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "hash" },
            start: { path, _, _ in await events.record(path) }, stop: { _ in throw StubServeError.failed }),
            prober: StubComparisonProber(gate: nil), pickPort: { 9997 })
        let coordinator = ComparisonCoordinator(probe: probe, runStore: JSONStore(fileURL: coordinatorRunStoreURL),
            promptSetStore: JSONStore(fileURL: coordinatorPromptSetStoreURL))
        let finished = expectation(description: "comparison aborted after stop failure")
        coordinator.onBenchmarks = { _ in finished.fulfill() }
        coordinator.start(variants: [("/Models/a", nil), ("/Models/b", nil)], promptSet: BuiltinPromptSets.coding)
        await fulfillment(of: [finished], timeout: 5)
        let started = await events.values
        XCTAssertEqual(started, ["/Models/a"])
        XCTAssertEqual(coordinator.runs.first?.state, .failed)
        XCTAssertEqual(coordinator.runs.first?.results.count, 1)
        XCTAssertNotNil(coordinator.runs.first?.results.first?.error)
        XCTAssertTrue(coordinator.aggregateBenchmarks().isEmpty)
    }

    func testCustomStrataSettingsReachServingPersistAndDoNotFeedDefaultBenchmarks() async throws {
        let options = StrataComparisonOptions(speculation: true, expertMemoryGB: 2, contextTokens: 8192)
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: "/fixture", command: { _, argv, _, _ in
            if argv.contains("stop") { return [:] }
            XCTAssertEqual(argv[try XCTUnwrap(argv.firstIndex(of: "--strata-speculation")) + 1], "on")
            XCTAssertEqual(argv[try XCTUnwrap(argv.firstIndex(of: "--strata-expert-memory-gb")) + 1], "2.0")
            XCTAssertEqual(argv[try XCTUnwrap(argv.firstIndex(of: "--strata-context-tokens")) + 1], "8192")
            if argv.contains("--confirm") { return [:] }
            return ["plan": ["preview_hash": "custom", "runtime": "strata", "strata_speculation": true,
                "strata_expert_memory_gb": 2.0, "strata_context_tokens": 8192]]
        })
        let benchmarks = BenchmarkRecorder()
        let coordinator = ComparisonCoordinator(probe: ServeProbe(
            lifecycle: .live(api: api), prober: StubComparisonProber(gate: nil), pickPort: { 9997 }),
            runStore: JSONStore(fileURL: coordinatorRunStoreURL), promptSetStore: JSONStore(fileURL: coordinatorPromptSetStoreURL),
            strataProbe: { setting in ServeProbe(lifecycle: .live(api: api, runtime: "strata", strataOptions: setting),
                prober: StubComparisonProber(gate: nil), pickPort: { 9997 }) })
        coordinator.onBenchmarks = { benchmarks.record($0) }
        coordinator.start(variants: [("/Models/strata", "sig")], promptSet: BuiltinPromptSets.coding,
                          strataOptions: ["/Models/strata": options])
        let finished = await waitFor { coordinator.activeRunID == nil }
        XCTAssertTrue(finished)
        let persisted = try JSONStore<ComparisonRun>(fileURL: coordinatorRunStoreURL).load()
        let run = try XCTUnwrap(persisted.first)
        XCTAssertNil(run.results.first?.error)
        XCTAssertEqual(run.strataOptions?["/Models/strata"], options)
        XCTAssertEqual(run.results.first?.servingEvidence?.expertMemoryGB, 2)
        XCTAssertEqual(run.results.first?.servingEvidence?.contextTokens, 8192)
        XCTAssertTrue(run.hasCustomServingConfiguration)
        XCTAssertEqual(try ComparisonRunSetup(run: run).strataOptions, run.strataOptions)
        XCTAssertEqual(benchmarks.values.flatMap { $0 }.count, 0)
        XCTAssertTrue(coordinator.aggregateBenchmarks().isEmpty)
    }

    func testWarmupAndMeasurementsShareOneServerAndWarmupIsNotPersisted() async throws {
        let events = ComparisonProbeEvents()
        let probe = ServeProbe(
            lifecycle: ServeLifecycle(
                preview: { _, _ in await events.record("preview"); return "hash" },
                start: { _, _, _ in await events.record("start") },
                stop: { _ in await events.record("stop") }
            ),
            prober: RecordingComparisonProber(events: events),
            pickPort: { 9997 }
        )
        let coordinator = ComparisonCoordinator(probe: probe,
            runStore: JSONStore(fileURL: coordinatorRunStoreURL),
            promptSetStore: JSONStore(fileURL: coordinatorPromptSetStoreURL))
        let set = PromptSet(id: "single", name: "Single", useCase: nil,
            prompts: [PromptEntry(id: "measured", text: "Answer the question.")], origin: .userCreated)
        coordinator.start(variants: [("/Models/strata", nil)], promptSet: set)
        let finished = await waitFor { coordinator.activeRunID == nil }
        XCTAssertTrue(finished)
        let recorded = await events.values
        XCTAssertEqual(recorded, ["preview", "start", "Say OK.", "Answer the question.", "stop"])
        let persisted = try JSONStore<ComparisonRun>(fileURL: coordinatorRunStoreURL).load()
        XCTAssertEqual(persisted.first?.results.first?.samples.map(\.promptID), ["measured"])
    }

    func testComparisonPersistsResolvedRuntimeAndQuantizationFromReviewedPlan() async throws {
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: "/fixture", command: { _, argv, _, _ in
            if argv.contains("--confirm") || argv.contains("stop") { return [:] }
            return ["plan": ["preview_hash": "reviewed-hash", "runtime": "strata",
                "weight_format": "gguf", "weight_quantization": "GSQ-RCO Q2_0", "weights_preserved": true,
                "strata_speculation": false, "strata_model_fingerprint": "model-fingerprint",
                "strata_runtime_fingerprint": "runtime-fingerprint", "readiness_deadline": 900]]
        })
        let coordinator = ComparisonCoordinator(
            probe: ServeProbe(lifecycle: .live(api: api), prober: StubComparisonProber(gate: nil), pickPort: { 9997 }),
            runStore: JSONStore(fileURL: coordinatorRunStoreURL),
            promptSetStore: JSONStore(fileURL: coordinatorPromptSetStoreURL))
        coordinator.start(variants: [("/Models/strata", "sig")], promptSet: BuiltinPromptSets.coding)
        let finished = await waitFor { coordinator.activeRunID == nil }
        XCTAssertTrue(finished)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: coordinatorRunStoreURL)) as? [[String: Any]])
        let results = try XCTUnwrap(stored.first?["results"] as? [[String: Any]])
        let evidence = try XCTUnwrap(results.first?["servingEvidence"] as? [String: Any])
        XCTAssertEqual(evidence["runtime"] as? String, "strata")
        XCTAssertEqual(evidence["previewHash"] as? String, "reviewed-hash")
        XCTAssertEqual(evidence["weightFormat"] as? String, "gguf")
        XCTAssertEqual(evidence["weightQuantization"] as? String, "GSQ-RCO Q2_0")
        XCTAssertEqual(evidence["speculation"] as? Bool, false)
        XCTAssertEqual(evidence["weightsPreserved"] as? Bool, true)
        XCTAssertEqual(evidence["modelFingerprint"] as? String, "model-fingerprint")
        XCTAssertEqual(evidence["runtimeFingerprint"] as? String, "runtime-fingerprint")
        XCTAssertGreaterThan(try XCTUnwrap(results.first?["startupSeconds"] as? Double), 0)
        let reloaded = try JSONStore<ComparisonRun>(fileURL: coordinatorRunStoreURL).load()
        XCTAssertEqual(reloaded.first?.results.first?.servingEvidence?.runtime, "strata")
        XCTAssertEqual(reloaded.first?.results.first?.servingEvidence?.speculation, false)
    }

    func testHistoricalResultRemainsUnknownAfterDecoding() throws {
        let data = Data(#"{"modelPath":"/old/model","samples":[],"aggregateTokensPerSecond":12}"#.utf8)
        let result = try JSONDecoder().decode(VariantResult.self, from: data)
        XCTAssertNil(result.servingEvidence)
        XCTAssertNil(result.startupSeconds)
        XCTAssertEqual(ComparisonViewLogic.servingDetails(result), ["Runtime not recorded"])
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertNil(encoded["servingEvidence"])
    }

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

private struct LaneComparisonProber: EndpointProbing {
    let speculation: Bool
    func listModels(baseURL: URL) async -> [String] { [] }
    func isReady(baseURL: URL) async -> Bool { true }
    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int) async throws -> ProbeSample {
        ProbeSample(text: speculation ? "answer-b" : "answer-a", completionTokens: speculation ? 20 : 10,
            timeToFirstTokenSeconds: 0.1, durationSeconds: 1.1, metricsEstimated: false,
            reasoningText: "fixture reasoning", finishReason: "stop", timeToFirstAnswerSeconds: 0.2)
    }
}

private actor ComparisonProbeEvents {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

private struct RecordingComparisonProber: EndpointProbing {
    let events: ComparisonProbeEvents
    func isReady(baseURL: URL) async -> Bool { true }
    func listModels(baseURL: URL) async -> [String] { [] }
    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int) async throws -> ProbeSample {
        await events.record(prompt)
        return ProbeSample(text: "OK", completionTokens: 2, timeToFirstTokenSeconds: 0.01,
            durationSeconds: 0.02, metricsEstimated: false)
    }
}
