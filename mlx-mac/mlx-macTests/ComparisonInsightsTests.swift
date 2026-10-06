import XCTest
@testable import mlx_workbench

final class ComparisonInsightsTests: XCTestCase {
    private let environment = "macOS|M4|1.0"
    private let prompt = PromptEntry(id: "p", text: "task")
    private func model(_ path: String, bytes: Int64 = 4_000_000_000, signature: String? = "s", key: String = "family", readiness: ModelReadiness = .ready, task: ModelTaskType? = nil, capabilities: [UseCase]? = nil) -> LibraryModel {
        LibraryModel(item: ModelItem(path: path, name: path, bytes: bytes, modifiedAt: nil, shard: nil, modelKey: key,
            architecture: nil, quantization: "Q4", parameters: "8B", structure: nil, signature: signature,
            companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil,
            task: task.map { ModelTask(type: $0, useCases: [], source: "test", confidence: "test") }), readiness: readiness, capabilities: capabilities)
    }
    private func result(_ path: String, speed: Double = 20, ttft: Double = 0.2, environment: String? = "macOS|M4|1.0", prompts: [String] = ["p"], metric: Double? = nil) -> VariantResult {
        VariantResult(modelPath: path, modelSignature: "s", samples: prompts.map {
            ComparisonSample(promptID: $0, outputExcerpt: "answer", tokensPerSecond: speed, timeToFirstTokenSeconds: ttft, error: nil)
        }, aggregateTokensPerSecond: speed, aggregateTTFTSeconds: ttft, error: nil, environmentFingerprint: environment, aggregateMetric: metric)
    }
    private func run(_ results: [VariantResult], scores: [String: Int] = [:], mode: ComparisonMode = .chat, set: String = "work") -> ComparisonRun {
        ComparisonRun(id: UUID(), promptSetID: set, promptSetName: "Task", useCase: .coding, variants: results.map(\.modelPath), results: results,
            startedAt: Date(timeIntervalSince1970: 1000), finishedAt: Date(timeIntervalSince1970: 1001), state: .completed, mode: mode,
            promptEntries: [prompt], qualityReviews: scores.mapValues { ComparisonQualityReview(score: $0, rubricID: "task-outcome-v1", reviewedAt: Date()) })
    }
    func testServedDefaultWinsAndMissingInventoryWaits() {
        let models = [model("/a"), model("/b")]
        let selection = ComparisonInsights.suggestion(candidates: models, lastServed: ["/b": Date()], selectedPath: "/a", runs: [], mode: .chat, environment: environment)
        XCTAssertEqual(selection.paths.first!, "/b")
        XCTAssertTrue(selection.reason.contains("Last intentionally served"))
        XCTAssertEqual(ComparisonInsights.suggestion(candidates: [], lastServed: ["/b": Date()], selectedPath: nil, runs: [], mode: .chat, environment: environment).paths, [nil, nil])
        XCTAssertEqual(ComparisonInsights.reconcile(slots: ["/b", "/gone", nil], available: ["/a", "/b"]), ["/b", nil, nil])
    }
    func testNearestRequiresSelectedFullCohortAndFreshIdentity() {
        let models = [model("/a"), model("/b", key: "other"), model("/c")]
        let measured = run([result("/a"), result("/b", speed: 21), result("/c", speed: 60)])
        let suggested = ComparisonInsights.suggestion(candidates: models, lastServed: [:], selectedPath: "/a", runs: [measured], mode: .chat, environment: environment, promptSetID: "work")
        XCTAssertEqual(suggested.paths[1], "/b")
        let wrongSet = ComparisonInsights.suggestion(candidates: models, lastServed: [:], selectedPath: "/a", runs: [measured], mode: .chat, environment: environment, promptSetID: "other")
        XCTAssertEqual(wrongSet.paths[1], "/c")
        var incomplete = measured
        incomplete.promptEntries = [prompt, PromptEntry(id: "missing", text: "task two")]
        XCTAssertNil(ComparisonInsights.currentResult(model: models[0], runs: [incomplete], environment: environment, promptSetID: "work"))
        XCTAssertNil(ComparisonInsights.currentResult(model: models[0], runs: [measured], environment: "different", promptSetID: "work"))
        XCTAssertFalse(ComparisonInsights.valid(measured.results[0], model: model("/a", signature: nil), environment: environment))
    }
    func testMediaNearestUsesPrimaryMetric() {
        let measured = run([result("/a", metric: 2), result("/b", metric: 2.1), result("/c", metric: 9)], mode: .imageGeneration)
        let suggested = ComparisonInsights.suggestion(candidates: [model("/a"), model("/b"), model("/c")], lastServed: [:], selectedPath: "/a", runs: [measured], mode: .imageGeneration, environment: environment)
        XCTAssertEqual(suggested.paths[1], "/b")
        XCTAssertTrue(suggested.reason.contains("same local run"))
    }
    func testSupersessionRejectsLowerQualityBiggerStaleUnknownAndProtected() {
        let left = model("/a")
        let replacement = model("/b", bytes: 3_000_000_000)
        let measured = run([result("/a"), result("/b", speed: 40, ttft: 0.1)], scores: ["/a": 5, "/b": 5])
        func advice(_ models: [LibraryModel], _ run: ComparisonRun, env: String? = "macOS|M4|1.0", protected: Set<String> = []) -> [ReclaimOpportunity] {
            ComparisonInsights.superseded(models: models, runs: [run], workflow: [], environment: env, protected: protected)
        }
        XCTAssertEqual(advice([left, replacement], measured).map(\.paths), [["/a"]])
        XCTAssertFalse(advice([left, replacement], measured)[0].actionable)
        let poor = run(measured.results, scores: ["/a": 5, "/b": 4])
        XCTAssertTrue(advice([left, replacement], poor).isEmpty)
        XCTAssertTrue(advice([left, model("/b", bytes: 5_000_000_000)], measured).isEmpty)
        XCTAssertTrue(advice([left, replacement], measured, env: "different").isEmpty)
        XCTAssertTrue(advice([left, replacement], measured, env: nil).isEmpty)
        XCTAssertTrue(advice([left, replacement], measured, env: "macOS|M4|unknown").isEmpty)
        XCTAssertTrue(advice([left, replacement], measured, protected: ["/a"]).isEmpty)
        XCTAssertTrue(advice([left, replacement], run(measured.results)).isEmpty)
        XCTAssertTrue(advice([model("/a", signature: "changed"), replacement], measured).isEmpty)
        for readiness in [ModelReadiness.needsRuntime, .unsupported, .incompleteCache] {
            XCTAssertTrue(advice([left, model("/b", bytes: 3_000_000_000, readiness: readiness)], measured).isEmpty)
        }
        XCTAssertTrue(advice([left, model("/b", bytes: 3_000_000_000, task: .imageGeneration)], measured).isEmpty)
    }
    func testReplacementChainGroupsUnderTerminalKeeperRegardlessOfInventoryOrder() {
        let measured = run([result("/a", speed: 20), result("/b", speed: 30), result("/c", speed: 40)], scores: ["/a": 5, "/b": 5, "/c": 5])
        for models in [[model("/a"), model("/b"), model("/c")], [model("/c"), model("/b"), model("/a")]] {
            let advice = ComparisonInsights.superseded(models: models, runs: [measured], workflow: [], environment: environment, protected: [])
            XCTAssertEqual(advice.count, 1, "One keeper should collect the entire task-scoped chain")
            XCTAssertEqual(advice.first?.paths.sorted(), ["/a", "/b"])
            XCTAssertEqual(advice.first?.bytes, 8_000_000_000)
            XCTAssertTrue(advice.first?.evidence.contains("/c") == true)
            XCTAssertEqual(advice.first?.replacement?.keeper.path, "/c")
        }
    }

    func testNewerTaskResultSuppressesOlderReplacementAdvice() {
        let old = run([result("/a"), result("/b", speed: 40)], scores: ["/a": 5, "/b": 5])
        var current = run([result("/a", speed: 40), result("/b", speed: 20)], scores: ["/a": 5, "/b": 5])
        current.finishedAt = Date(timeIntervalSince1970: 2000)
        let advice = ComparisonInsights.superseded(models: [model("/a"), model("/b")], runs: [old, current], workflow: [], environment: environment, protected: [])
        XCTAssertEqual(advice.map(\.paths), [["/b"]])
        XCTAssertEqual(advice.first?.replacement?.keeper.path, "/a")
        current.qualityReviews = nil
        XCTAssertTrue(ComparisonInsights.superseded(models: [model("/a"), model("/b")], runs: [old, current], workflow: [], environment: environment, protected: []).isEmpty)
    }

    func testReplacementChainsDoNotBridgeSeparatePromptSets() {
        let first = run([result("/a", speed: 20), result("/b", speed: 30)], scores: ["/a": 5, "/b": 5], set: "coding")
        let second = run([result("/b", speed: 30), result("/c", speed: 40)], scores: ["/b": 5, "/c": 5], set: "writing")
        let advice = ComparisonInsights.superseded(models: [model("/a"), model("/b"), model("/c")], runs: [first, second], workflow: [], environment: environment, protected: [])
        XCTAssertEqual(advice.map(\.paths), [["/a"], ["/b"]])
        XCTAssertTrue(advice[0].evidence.contains("/b"))
        XCTAssertFalse(advice[0].evidence.contains("/c"))
    }

    func testExportPreservesHistoricalFactsAndMissingQuality() throws {
        let measured = run([result("/a", environment: nil), result("/b")])
        let data = ComparisonInsights.agentEvidence(models: [model("/a"), model("/b")], runs: [measured], workflow: [], environment: environment,
            hardware: HardwareProfile(chip: "M4", memoryBytes: 32_000_000_000), memory: MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: 12_000_000_000), capturedAt: Date(timeIntervalSince1970: 42), contextTokens: 2048, reserveGB: 6, protected: ["/b"])
        XCTAssertEqual(data.schemaVersion, 1)
        XCTAssertEqual(data.reserveGB, 6)
        XCTAssertEqual(data.availableMemoryBytes, 12_000_000_000)
        XCTAssertFalse(data.comparisons[0].current)
        XCTAssertNil(data.comparisons[0].quality)
        XCTAssertNil(data.comparisons[0].environmentFingerprint)
        XCTAssertEqual(data.comparisons[0].runID, measured.id)
        XCTAssertTrue(data.models[1].protected)
        XCTAssertTrue(data.limitations.contains { $0.contains("GPU utilization") })
        XCTAssertTrue(data.replacementReviews.isEmpty)
        XCTAssertNoThrow(try WorkflowEvidenceStore.encode(data))
    }
    func testComparisonBackwardDecode() throws {
        let original = run([result("/a")])
        let data = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "promptEntries")
        json.removeValue(forKey: "qualityReviews")
        let decoded = try JSONDecoder().decode(ComparisonRun.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.promptEntries)
        XCTAssertNil(decoded.qualityReviews)
        XCTAssertFalse(ComparisonInsights.fullCohort(decoded.results[0], run: decoded))
    }

    private func guidance(_ models: [LibraryModel], _ runs: [ComparisonRun], workflow: [WorkflowEvidence] = [], available: Int64? = 12_000_000_000) throws -> [[String: Any]] {
        let evidence = ComparisonInsights.agentEvidence(models: models, runs: runs, workflow: workflow, environment: environment,
            hardware: HardwareProfile(chip: "M4", memoryBytes: 32_000_000_000), memory: available.map { MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: $0) },
            capturedAt: Date(timeIntervalSince1970: 42), contextTokens: 2048, reserveGB: 4, protected: [])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: WorkflowEvidenceStore.encode(evidence)) as? [String: Any])
        return try XCTUnwrap(json["taskGuidance"] as? [[String: Any]])
    }

    func testAgentGuidanceSeparatesQualitySpeedAndFitWithoutBreakingTies() throws {
        let measured = run([result("/a", speed: 20), result("/b", speed: 40), result("/c", speed: 40)], scores: ["/a": 5, "/b": 4, "/c": 4])
        let task = try XCTUnwrap(try guidance([model("/a", bytes: 20_000_000_000), model("/b"), model("/c")], [measured]).first)
        XCTAssertEqual(task["qualityLeaders"] as? [String], ["/a"])
        XCTAssertEqual(task["performanceLeaders"] as? [String], ["/b", "/c"])
        XCTAssertEqual(task["qualityFirstFitPaths"] as? [String], ["/b", "/c"])
        let candidates = try XCTUnwrap(task["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates[0]["fitStatus"] as? String, "wontFit")
        XCTAssertEqual(candidates[0]["evidenceID"] as? String, measured.id.uuidString)
    }

    func testNewerIncompleteOrUnreviewedGuidanceDoesNotFallBackToOlderWinner() throws {
        let old = run([result("/a"), result("/b", speed: 40)], scores: ["/a": 5, "/b": 5])
        var latest = run([result("/a"), result("/b")])
        latest.finishedAt = Date(timeIntervalSince1970: 2000)
        latest.promptEntries = [prompt, PromptEntry(id: "missing", text: "missing")]
        let incomplete = try XCTUnwrap(try guidance([model("/a"), model("/b")], [old, latest]).first)
        XCTAssertEqual(incomplete["performanceLeaders"] as? [String], [])
        latest.promptEntries = [prompt]
        let unreviewed = try XCTUnwrap(try guidance([model("/a"), model("/b")], [old, latest]).first)
        XCTAssertEqual(unreviewed["qualityFirstFitPaths"] as? [String], [])
        XCTAssertEqual(unreviewed["qualityLeaders"] as? [String], [])
        XCTAssertEqual(unreviewed["performanceLeaders"] as? [String], ["/a", "/b"])
    }

    func testWorkflowGuidanceNeverCombinesDifferentConfigurationsOrHistoricalIdentity() throws {
        func report(_ path: String, config: String, date: Double = 1000, signature: String = "s") -> WorkflowEvidence {
            var record = WorkflowEvidence(id: UUID(), harness: "opencode", workloadID: "task", useCase: .coding,
                modelPath: path, modelSignature: signature, environmentFingerprint: environment,
                measuredAt: Date(timeIntervalSince1970: date), sampleCount: 3, totalSeconds: 10, source: "receipt:\(path)")
            record.configurationFingerprint = config; record.tokensPerSecond = 20; record.qualityScore = 5; record.rubricID = "shared"
            return record
        }
        let models = [model("/a"), model("/b")]
        let split = try guidance(models, [], workflow: [report("/a", config: "one"), report("/b", config: "two")])
        XCTAssertEqual(split.count, 2)
        XCTAssertTrue(split.allSatisfy { ($0["qualityFirstFitPaths"] as? [String]) == [] })
        let history = try guidance(models, [], workflow: [report("/a", config: "one"), report("/b", config: "one"), report("/a", config: "one", date: 2000, signature: "old")])
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0]["qualityFirstFitPaths"] as? [String], [])
        let candidates = try XCTUnwrap(history[0]["candidates"] as? [[String: Any]])
        XCTAssertFalse(try XCTUnwrap(candidates.first { $0["modelPath"] as? String == "/a" })["comparable"] as? Bool ?? true)
    }

    func testGuidanceRefusesUnknownOrTightFitsAndHonorsMediaMetricDirection() throws {
        let models = [model("/a"), model("/b")]
        let measured = run([result("/a"), result("/b")], scores: ["/a": 5, "/b": 5])
        let unknown = try XCTUnwrap(try guidance(models, [measured], available: nil).first)
        XCTAssertEqual(unknown["qualityFirstFitPaths"] as? [String], [])
        let required = FitAdvisor.neededBytes(modelBytes: 4_000_000_000, contextTokens: 2048, parameters: "8B")
        let tight = try XCTUnwrap(try guidance(models, [measured], available: required + 4_000_000_000).first)
        XCTAssertEqual(tight["qualityFirstFitPaths"] as? [String], [])
        XCTAssertEqual((tight["candidates"] as? [[String: Any]])?.first?["fitStatus"] as? String, "tight")
        let media = run([result("/a", metric: 2), result("/b", metric: 1)], mode: .imageGeneration)
        let task = try XCTUnwrap(try guidance([model("/a", task: .imageGeneration), model("/b", task: .imageGeneration)], [media]).first)
        XCTAssertEqual(task["performanceLeaders"] as? [String], ["/b"])
        XCTAssertEqual(task["higherIsBetter"] as? Bool, false)
        XCTAssertEqual(task["qualityFirstFitPaths"] as? [String], [])
        XCTAssertEqual((task["candidates"] as? [[String: Any]])?.first?["fitStatus"] as? String, "unknown")
    }

    func testWorkflowGuidanceUsesWholeTaskDurationAndNewestReviewOnly() throws {
        func report(_ path: String, duration: Double, date: Double) -> WorkflowEvidence {
            var value = WorkflowEvidence(id: UUID(), harness: "opencode", workloadID: "same", useCase: .coding,
                modelPath: path, modelSignature: "s", environmentFingerprint: environment, measuredAt: Date(timeIntervalSince1970: date),
                sampleCount: 3, totalSeconds: duration, source: "session")
            value.configurationFingerprint = "config"; value.rubricID = "shared"; value.qualityScore = 5
            value.inferenceSeconds = 2; value.toolSeconds = 3; value.queueSeconds = 0
            return value
        }
        let a = report("/a", duration: 10, date: 1000), b = report("/b", duration: 8, date: 1001)
        let models = [model("/a"), model("/b"), model("/unmeasured", capabilities: [.coding])]
        let task = try XCTUnwrap(try guidance(models, [], workflow: [a, b]).first)
        XCTAssertEqual(task["performanceLeaders"] as? [String], ["/b"])
        XCTAssertEqual(task["qualityFirstFitPaths"] as? [String], ["/a", "/b"])
        XCTAssertEqual(task["unmeasuredModelPaths"] as? [String], ["/unmeasured"])
        XCTAssertEqual((task["candidates"] as? [[String: Any]])?.first?["toolSeconds"] as? Double, 3)
        var newest = report("/a", duration: 9, date: 2000)
        newest.qualityScore = nil; newest.rubricID = nil
        let unreviewed = try guidance(models, [], workflow: [a, b, newest])
        XCTAssertEqual(unreviewed.count, 1)
        XCTAssertEqual(unreviewed[0]["qualityFirstFitPaths"] as? [String], [])
        newest.qualityScore = 5; newest.rubricID = "different-rubric"
        XCTAssertEqual(try guidance(models, [], workflow: [b, newest])[0]["qualityLeaders"] as? [String], [])
    }

    func testWorkflowChartsPreserveMeasuredZerosAndUnattributedTime() throws {
        var record = WorkflowEvidence(id: UUID(), harness: "opencode", workloadID: "task", useCase: .coding,
            modelPath: "/a", modelSignature: "s", environmentFingerprint: environment,
            measuredAt: Date(timeIntervalSince1970: 1000), sampleCount: 3, totalSeconds: 10, source: "session")
        record.configurationFingerprint = "config"
        record.inferenceSeconds = 6; record.toolSeconds = 0; record.queueSeconds = 1
        let task = try XCTUnwrap(AgentTaskAdvisor.guidance(models: [model("/a")], runs: [], workflow: [record], environment: environment,
            hardware: HardwareProfile(chip: "M4", memoryBytes: nil), memory: nil, contextTokens: 2048, reserveGB: 4).first)
        let candidate = try XCTUnwrap(WorkflowCharts.chartCandidates(task).first)
        let segments = WorkflowCharts.segments(candidate)
        XCTAssertEqual(segments.map(\.seconds), [6, 0, 1, 3])
        XCTAssertEqual(segments.map(\.timing), [.inference, .tools, .queue, .unattributed])
        XCTAssertEqual(segments.reduce(0) { $0 + $1.seconds }, record.totalSeconds)
        XCTAssertTrue(WorkflowCharts.missingTimings(candidate).isEmpty)
    }

    func testWorkflowChartsKeepPartialBreakdownsUnknown() throws {
        var record = WorkflowEvidence(id: UUID(), harness: "claude", workloadID: "task", useCase: .coding,
            modelPath: "/a", modelSignature: "s", environmentFingerprint: environment,
            measuredAt: Date(timeIntervalSince1970: 1000), sampleCount: 3, totalSeconds: 10, source: "session")
        record.configurationFingerprint = "config"; record.inferenceSeconds = 6
        let task = try XCTUnwrap(AgentTaskAdvisor.guidance(models: [model("/a")], runs: [], workflow: [record], environment: environment,
            hardware: HardwareProfile(chip: "M4", memoryBytes: nil), memory: nil, contextTokens: 2048, reserveGB: 4).first)
        let candidate = try XCTUnwrap(WorkflowCharts.chartCandidates(task).first)
        XCTAssertEqual(WorkflowCharts.segments(candidate).map(\.timing), [.unknown])
        XCTAssertEqual(WorkflowCharts.segments(candidate).first?.seconds, 10)
        XCTAssertEqual(WorkflowCharts.missingTimings(candidate), ["Tools", "Queue"])
    }

    func testWorkflowChartsSeparateCohortsAndExcludeNewestStaleEvidence() throws {
        func report(_ path: String, config: String?, samples: Int = 3, harness: String = "opencode", date: Double = 1000, signature: String = "s") -> WorkflowEvidence {
            var record = WorkflowEvidence(id: UUID(), harness: harness, workloadID: "task", useCase: .coding,
                modelPath: path, modelSignature: signature, environmentFingerprint: environment,
                measuredAt: Date(timeIntervalSince1970: date), sampleCount: samples, totalSeconds: 10, source: "session")
            record.configurationFingerprint = config
            return record
        }
        let reports = [report("/a", config: "one"), report("/b", config: "two"), report("/b", config: "one", samples: 4),
            report("/b", config: "one", harness: "claude"), report("/b", config: nil),
            report("/a", config: "one", date: 2000, signature: "changed")]
        let tasks = AgentTaskAdvisor.guidance(models: [model("/a"), model("/b")], runs: [], workflow: reports, environment: environment,
            hardware: HardwareProfile(chip: "M4", memoryBytes: nil), memory: nil, contextTokens: 2048, reserveGB: 4)
        XCTAssertEqual(tasks.count, 5)
        XCTAssertEqual(tasks.flatMap { WorkflowCharts.chartCandidates($0) }.count, 3)
        XCTAssertFalse(tasks.flatMap { WorkflowCharts.chartCandidates($0) }.contains { $0.modelPath == "/a" })
        XCTAssertTrue(tasks.filter { $0.configurationFingerprint == nil }.allSatisfy { WorkflowCharts.chartCandidates($0).isEmpty })
        let changedEnvironment = AgentTaskAdvisor.guidance(models: [model("/a"), model("/b")], runs: [], workflow: reports, environment: "different",
            hardware: HardwareProfile(chip: "M4", memoryBytes: nil), memory: nil, contextTokens: 2048, reserveGB: 4)
        XCTAssertTrue(changedEnvironment.allSatisfy { WorkflowCharts.chartCandidates($0).isEmpty })
    }

    private func workflowTasks(_ reports: [WorkflowEvidence], models: [LibraryModel]) -> [AgentTaskGuidance] {
        AgentTaskAdvisor.guidance(models: models, runs: [], workflow: reports, environment: environment,
            hardware: HardwareProfile(chip: "M4", memoryBytes: nil), memory: nil, contextTokens: 2048, reserveGB: 4)
    }

    private func selectionReport(_ path: String, duration: Double = 10, signature: String = "s") -> WorkflowEvidence {
        var report = WorkflowEvidence(id: UUID(), harness: "opencode", workloadID: "task", useCase: .coding,
            modelPath: path, modelSignature: signature, environmentFingerprint: environment,
            measuredAt: Date(timeIntervalSince1970: 1000), sampleCount: 3, totalSeconds: duration, source: "session")
        report.configurationFingerprint = "config"
        return report
    }

    func testWorkflowSelectionLoadsMeasuredModelsWithoutAddingUnmeasuredAlternatives() throws {
        let models = [model("/a"), model("/b"), model("/unmeasured")]
        let task = try XCTUnwrap(workflowTasks([selectionReport("/a", duration: 20), selectionReport("/b")], models: models).first)
        let selection = WorkflowCharts.comparisonSelection(task, models: models, mode: .chat, activeRunID: nil)
        XCTAssertEqual(selection.slots, ["/b", "/a"])
        let single = try XCTUnwrap(workflowTasks([selectionReport("/a")], models: models).first)
        XCTAssertEqual(WorkflowCharts.comparisonSelection(single, models: models, mode: .chat, activeRunID: nil).slots, ["/a", nil])
    }

    func testWorkflowSelectionRejectsActiveRunsAndDoesNotSilentlyTruncateCohorts() throws {
        let models = [model("/a"), model("/b"), model("/c"), model("/d"), model("/e")]
        let task = try XCTUnwrap(workflowTasks(models.map { selectionReport($0.item.path) }, models: models).first)
        let oversized = WorkflowCharts.comparisonSelection(task, models: models, mode: .chat, activeRunID: nil)
        XCTAssertNil(oversized.slots)
        XCTAssertTrue(oversized.reason.contains("5"))
        XCTAssertTrue(oversized.reason.contains("4"))
        let small = try XCTUnwrap(workflowTasks([selectionReport("/a")], models: models).first)
        XCTAssertNil(WorkflowCharts.comparisonSelection(small, models: models, mode: .chat, activeRunID: UUID()).slots)
    }

    func testWorkflowSelectionRechecksReadinessAndMode() throws {
        let models = [model("/a"), model("/b")]
        let task = try XCTUnwrap(workflowTasks([selectionReport("/a"), selectionReport("/b")], models: models).first)
        let unavailable = [model("/a", readiness: .needsConversion)]
        XCTAssertNil(WorkflowCharts.comparisonSelection(task, models: unavailable, mode: .chat, activeRunID: nil).slots)
        let media = [model("/image", task: .imageGeneration)]
        let mediaTask = try XCTUnwrap(workflowTasks([selectionReport("/image")], models: media).first)
        XCTAssertNil(WorkflowCharts.comparisonSelection(mediaTask, models: media, mode: .chat, activeRunID: nil).slots)
        XCTAssertEqual(WorkflowCharts.comparisonSelection(mediaTask, models: media, mode: .imageGeneration, activeRunID: nil).slots, ["/image", nil])
    }

    func testWorkflowSelectionExcludesStaleAndMissingConfigurationEvidence() throws {
        let models = [model("/a"), model("/b")]
        let task = try XCTUnwrap(workflowTasks([selectionReport("/a", signature: "old"), selectionReport("/b")], models: models).first)
        XCTAssertEqual(WorkflowCharts.comparisonSelection(task, models: models, mode: .chat, activeRunID: nil).slots, ["/b", nil])
        var unconfigured = selectionReport("/a"); unconfigured.configurationFingerprint = nil
        let unknown = try XCTUnwrap(workflowTasks([unconfigured], models: models).first)
        XCTAssertNil(WorkflowCharts.comparisonSelection(unknown, models: models, mode: .chat, activeRunID: nil).slots)
    }

    func testAgentExportBackwardDecodeKeepsMissingGuidanceUnknown() throws {
        let exported = ComparisonInsights.agentEvidence(models: [], runs: [], workflow: [], environment: nil,
            hardware: HardwareProfile(chip: "M4", memoryBytes: nil), memory: nil, capturedAt: nil, contextTokens: 2048, reserveGB: 4, protected: [])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(exported)) as? [String: Any])
        object.removeValue(forKey: "taskGuidance")
        let decoded = try JSONDecoder().decode(AgentEvidenceExport.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.taskGuidance)
        XCTAssertEqual(exported.taskGuidance?.count, 0)
    }

    func testMediaPipelinesNeverReceiveChatFitEstimates() {
        let hardware = HardwareProfile(chip: "M4", memoryBytes: 32_000_000_000)
        let memory = MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: 24_000_000_000)
        for task in [ModelTaskType.imageGeneration, .speechToText, .textToSpeech, .videoGeneration] {
            let candidate = model("/media", task: task)
            XCTAssertEqual(ComparisonInsights.fitEstimate(model: candidate, hardware: hardware, memory: memory, contextTokens: 2048, reserveGB: 4), .unknown(reason: "media pipeline memory not modeled"))
            let exported = ComparisonInsights.agentEvidence(models: [candidate], runs: [], workflow: [], environment: environment, hardware: hardware, memory: memory, capturedAt: Date(), contextTokens: 2048, reserveGB: 4, protected: [])
            XCTAssertNil(exported.models[0].estimatedRequiredBytes)
            XCTAssertTrue(exported.models[0].fitEstimate.contains("not modeled"))
        }
    }

    func testMediaWorkflowMetricsCannotJustifyReplacementWithChatMemoryEstimate() {
        let mediaModels = [model("/a", task: .textToSpeech), model("/b", bytes: 3_000_000_000, task: .textToSpeech)]
        var left = WorkflowEvidence(id: UUID(), harness: "opencode", workloadID: "speech", useCase: nil,
            modelPath: "/a", modelSignature: "s", environmentFingerprint: environment,
            measuredAt: Date(timeIntervalSince1970: 1000), sampleCount: 3, totalSeconds: 10, source: "session:left")
        left.tokensPerSecond = 20
        left.timeToFirstTokenSeconds = 0.2
        left.qualityScore = 5
        left.rubricID = "speech-outcome-v1"
        left.configurationFingerprint = "same-prompts-settings"
        var right = WorkflowEvidence(id: UUID(), harness: "opencode", workloadID: "speech", useCase: nil,
            modelPath: "/b", modelSignature: "s", environmentFingerprint: environment,
            measuredAt: Date(timeIntervalSince1970: 1001), sampleCount: 3, totalSeconds: 8, source: "session:right")
        right.tokensPerSecond = 40
        right.timeToFirstTokenSeconds = 0.1
        right.qualityScore = 5
        right.rubricID = left.rubricID
        right.configurationFingerprint = left.configurationFingerprint
        XCTAssertTrue(ComparisonInsights.superseded(models: mediaModels, runs: [], workflow: [left, right], environment: environment, protected: []).isEmpty)
    }

    func testChampionsSeparateQualitySpeedAndShareTies() throws {
        let measured = run([result("/a", speed: 20), result("/b", speed: 40), result("/c", speed: 40)], scores: ["/a": 5, "/b": 4, "/c": 5])
        let award = try XCTUnwrap(ComparisonInsights.champions(models: [model("/a"), model("/b"), model("/c")], runs: [measured], environment: environment).first)
        XCTAssertEqual(award.performance.map(\.modelPath), ["/b", "/c"])
        XCTAssertEqual(award.quality.map(\.modelPath), ["/a", "/c"])
        XCTAssertEqual(award.latency.count, 3)
        var partlyReviewed = measured
        partlyReviewed.qualityReviews?.removeValue(forKey: "/b")
        XCTAssertTrue(try XCTUnwrap(ComparisonInsights.champions(models: [model("/a"), model("/b"), model("/c")], runs: [partlyReviewed], environment: environment).first).quality.isEmpty)
    }

    func testChampionsRefuseStaleIncompleteUnavailableAndOlderFallback() {
        let models = [model("/a"), model("/b")]
        let measured = run([result("/a"), result("/b", speed: 40)])
        XCTAssertTrue(ComparisonInsights.champions(models: models, runs: [measured], environment: "different").isEmpty)
        XCTAssertTrue(ComparisonInsights.champions(models: models, runs: [measured], environment: nil).isEmpty)
        XCTAssertTrue(ComparisonInsights.champions(models: [model("/a"), model("/b", signature: "changed")], runs: [measured], environment: environment).isEmpty)
        XCTAssertTrue(ComparisonInsights.champions(models: [model("/a"), model("/b", readiness: .unsupported)], runs: [measured], environment: environment).isEmpty)
        var incomplete = measured
        incomplete.promptEntries = [prompt, PromptEntry(id: "missing", text: "missing")]
        incomplete.finishedAt = Date(timeIntervalSince1970: 2000)
        XCTAssertTrue(ComparisonInsights.champions(models: models, runs: [measured, incomplete], environment: environment).isEmpty)
        var missingEntrant = measured
        missingEntrant.results.removeLast()
        XCTAssertTrue(ComparisonInsights.champions(models: models, runs: [missingEntrant], environment: environment).isEmpty)
    }

    func testMediaChampionsUseModeMetricDirection() throws {
        let measured = run([result("/a", metric: 2), result("/b", metric: 1)], mode: .imageGeneration)
        let award = try XCTUnwrap(ComparisonInsights.champions(models: [model("/a", task: .imageGeneration), model("/b", task: .imageGeneration)], runs: [measured], environment: environment).first)
        XCTAssertEqual(award.performance.map(\.modelPath), ["/b"])
        XCTAssertTrue(award.quality.isEmpty)
        XCTAssertTrue(award.latency.isEmpty)
    }
}
