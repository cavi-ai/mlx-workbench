import XCTest
import AppKit
import SwiftUI
@testable import mlx_workbench

final class ComparisonInsightsTests: XCTestCase {
    private func actionEvidence(models: [LibraryModel]? = nil, runs: [ComparisonRun], reports: [WorkflowEvidence] = [],
                                available: Int64 = 24_000_000_000, environment: String? = "macOS|M4|1.0") -> AgentEvidenceExport {
        ComparisonInsights.agentEvidence(models: models ?? [model("/a"), model("/b")], runs: runs, workflow: reports,
            environment: environment, hardware: HardwareProfile(chip: "M4", memoryBytes: 32_000_000_000),
            memory: MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: available), capturedAt: Date(),
            contextTokens: 2048, reserveGB: 4, protected: [])
    }

    func testGuidanceActionKeepsTiesAndRefreshesFitWithoutChangingEvidence() throws {
        let measured = run([result("/a"), result("/b")], scores: ["/a": 5, "/b": 5])
        let original = actionEvidence(runs: [measured])
        let task = try XCTUnwrap(original.taskGuidance?.first)
        XCTAssertEqual(task.qualityFirstFitPaths, ["/a", "/b"])
        let fresh = actionEvidence(runs: [measured], available: 4_000_000_000)
        for path in task.qualityLeaders {
            let checked = try ModelGuidanceAction.validate(original: original, fresh: fresh, taskID: task.id, path: path)
            XCTAssertEqual(checked.fitStatus, "wontFit")
        }
    }

    func testGuidanceActionRefusesChangedIdentityEvidenceAndOlderFallback() throws {
        let measured = run([result("/a"), result("/b")], scores: ["/a": 5, "/b": 4])
        let original = actionEvidence(runs: [measured])
        let taskID = try XCTUnwrap(original.taskGuidance?.first?.id)
        var changedReview = measured
        changedReview.qualityReviews?["/b"] = ComparisonQualityReview(score: 5, rubricID: "task-outcome-v1", reviewedAt: Date())
        var newer = run([result("/a"), result("/b")])
        newer.finishedAt = Date(timeIntervalSince1970: 2000)
        let invalid = [
            actionEvidence(runs: [measured], environment: "different"),
            actionEvidence(models: [model("/a", signature: "changed"), model("/b")], runs: [measured]),
            actionEvidence(models: [model("/a", readiness: .needsConversion), model("/b")], runs: [measured]),
            actionEvidence(models: [model("/b")], runs: [measured]),
            actionEvidence(runs: [changedReview]),
            actionEvidence(runs: [measured, newer])
        ]
        for fresh in invalid {
            XCTAssertThrowsError(try ModelGuidanceAction.validate(original: original, fresh: fresh, taskID: taskID, path: "/a"))
        }
    }

    func testGuidanceActionBindsWorkflowConfigurationAndPeerObservations() throws {
        let reports = [selectionReport("/a"), selectionReport("/b")]
        let original = actionEvidence(runs: [], reports: reports)
        let taskID = try XCTUnwrap(original.taskGuidance?.first?.id)
        XCTAssertNoThrow(try ModelGuidanceAction.validate(original: original, fresh: original, taskID: taskID, path: "/a"))
        var changed = reports
        changed[1].configurationFingerprint = "other-settings"
        XCTAssertThrowsError(try ModelGuidanceAction.validate(original: original,
            fresh: actionEvidence(runs: [], reports: changed), taskID: taskID, path: "/a"))
    }

    func testGuidanceEndpointGuardsDoNotBlockPreferenceOnlyChoice() throws {
        let measured = run([result("/a"), result("/b")], scores: ["/a": 5, "/b": 4])
        func review(available: Int64 = 24_000_000_000, verified: Bool = true, port: Int = 8766, roles: [UseCase] = [.coding]) throws -> ModelGuidanceReview {
            let evidence = actionEvidence(runs: [measured], available: available)
            let task = try XCTUnwrap(evidence.taskGuidance?.first)
            return ModelGuidanceReview(evidence: evidence, taskID: task.id, candidate: try XCTUnwrap(task.candidates.first), roles: roles,
                endpoint: EndpointConfig(enabled: false, port: port, modelPath: "", installedAtLogin: false), verified: verified)
        }
        let original = try review()
        XCTAssertNoThrow(try ModelGuidanceAction.validateApplication(review: original, fresh: original, role: .coding, enableEndpoint: true, comparisonActive: false))
        for fresh in [try review(available: 4_000_000_000), try review(verified: false), try review(port: 9000)] {
            XCTAssertThrowsError(try ModelGuidanceAction.validateApplication(review: original, fresh: fresh, role: .coding, enableEndpoint: true, comparisonActive: false))
            XCTAssertNoThrow(try ModelGuidanceAction.validateApplication(review: original, fresh: fresh, role: .coding, enableEndpoint: false, comparisonActive: true))
        }
        XCTAssertThrowsError(try ModelGuidanceAction.validateApplication(review: original, fresh: original, role: .coding, enableEndpoint: true, comparisonActive: true))
        XCTAssertThrowsError(try ModelGuidanceAction.validateApplication(review: original, fresh: original, role: .vision, enableEndpoint: false, comparisonActive: false))
    }

    @MainActor
    func testGuidanceReviewRendersWithExplicitRoleAndOptionalEndpoint() throws {
        let evidence = actionEvidence(runs: [run([result("/a"), result("/b")], scores: ["/a": 5, "/b": 4])])
        let task = try XCTUnwrap(evidence.taskGuidance?.first)
        let review = ModelGuidanceReview(evidence: evidence, taskID: task.id, candidate: try XCTUnwrap(task.candidates.first),
            roles: [.coding, .generalChat], endpoint: .disabled, verified: true)
        let view = NSHostingView(rootView: ModelGuidanceReviewView(review: review, onApply: { _, _, _ in "Saved" }, onBack: {}, onApplied: { _ in })
            .background(WorkbenchColor.canvas).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        defer { window.close() }
        view.setFrameSize(NSSize(width: 560, height: view.fittingSize.height))
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.bounds.height, 280)
        XCTAssertLessThan(view.bounds.height, 700)
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let attachment = XCTAttachment(data: try XCTUnwrap(image.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "Reviewed model guidance action"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
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

    func testWorkflowQualityChartRequiresSharedRubricAndKeepsMissingScoresUnknown() throws {
        var a = selectionReport("/a"); a.qualityScore = 5; a.rubricID = "task-rubric"
        var b = selectionReport("/b"); b.qualityScore = 3; b.rubricID = "task-rubric"
        let models = [model("/a"), model("/b")]
        func series(_ reports: [WorkflowEvidence]) throws -> WorkflowCharts.Series {
            let task = try XCTUnwrap(workflowTasks(reports, models: models).first)
            return WorkflowCharts.series(task, records: reports, metric: .quality)
        }
        let shared = try series([a, b])
        XCTAssertEqual(shared.points.map(\.value), [5, 3])
        XCTAssertNil(shared.unavailableReason)
        b.qualityScore = nil
        let partial = try series([a, b])
        XCTAssertEqual(partial.points.map(\.value), [5])
        XCTAssertEqual(partial.missing.map(\.modelPath), ["/b"])
        b.qualityScore = 3; b.rubricID = "different-rubric"
        let mixed = try series([a, b])
        XCTAssertTrue(mixed.points.isEmpty)
        XCTAssertNotNil(mixed.unavailableReason)
        b.rubricID = nil; b.qualityScore = nil
        XCTAssertTrue(try series([a, b]).points.isEmpty)
    }

    func testWorkflowTradeoffKeepsPairedMeasurementsTiesAndUnknownMemory() throws {
        var a = selectionReport("/a", duration: 10); a.qualityScore = 5; a.rubricID = "shared"; a.peakMemoryBytes = 0
        var b = selectionReport("/b", duration: 10); b.qualityScore = 5; b.rubricID = "shared"
        var c = selectionReport("/c", duration: 20); c.rubricID = "shared"
        let reports = [a, b, c]
        let task = try XCTUnwrap(workflowTasks(reports, models: [model("/a"), model("/b"), model("/c")]).first)
        let series = WorkflowCharts.series(task, records: reports, metric: .qualityRuntime)
        XCTAssertEqual(series.points.map(\.id), ["/a", "/b"], "Tied models must remain individually selectable")
        XCTAssertEqual(series.points.map(\.value), [5, 5])
        XCTAssertEqual(series.points.map { $0.candidate.totalSeconds }, [10, 10])
        XCTAssertEqual(series.points.first?.peakMemoryBytes, 0)
        XCTAssertNil(series.points.last?.peakMemoryBytes)
        XCTAssertEqual(series.missing.map(\.modelPath), ["/c"])
        c.rubricID = "different"
        let mixedTask = try XCTUnwrap(workflowTasks([a, b, c], models: [model("/a"), model("/b"), model("/c")]).first)
        XCTAssertNotNil(WorkflowCharts.series(mixedTask, records: [a, b, c], metric: .qualityRuntime).unavailableReason)
        var altered = a; altered.qualityScore = 1
        XCTAssertEqual(WorkflowCharts.series(task, records: [altered, b, c], metric: .qualityRuntime).points.map(\.id), ["/b"])
    }

    func testWorkflowTradeoffChoiceUsesExistingRechecksBeforeReview() throws {
        var a = selectionReport("/a"); a.qualityScore = 4; a.rubricID = "shared"
        var b = selectionReport("/b"); b.qualityScore = 5; b.rubricID = "shared"
        let original = actionEvidence(runs: [], reports: [a, b])
        let task = try XCTUnwrap(original.taskGuidance?.first)
        let plotted = WorkflowCharts.series(task, records: [a, b], metric: .qualityRuntime)
        let path = try XCTUnwrap(plotted.points.first?.id)
        XCTAssertNoThrow(try ModelGuidanceAction.validate(original: original, fresh: original, taskID: task.id, path: path))
        b.qualityScore = 2
        XCTAssertThrowsError(try ModelGuidanceAction.validate(original: original,
            fresh: actionEvidence(runs: [], reports: [a, b]), taskID: task.id, path: path))
        XCTAssertThrowsError(try ModelGuidanceAction.validate(original: original,
            fresh: actionEvidence(models: [model("/a")], runs: [], reports: [a, b]), taskID: task.id, path: path))
    }

    func testWorkflowPeakMemoryUsesRecordedBytesDatesAndTrueZeroWithoutFitFallback() throws {
        var a = selectionReport("/a"); a.peakMemoryBytes = 6_000_000_000
        let b = selectionReport("/b")
        var c = selectionReport("/c"); c.peakMemoryBytes = 0
        let older = WorkflowEvidence(id: UUID(), harness: "opencode", workloadID: "task", useCase: .coding,
            modelPath: "/a", modelSignature: "s", environmentFingerprint: environment, measuredAt: Date(timeIntervalSince1970: 1),
            sampleCount: 3, totalSeconds: 9, source: "older-session", peakMemoryBytes: 9_000_000_000, configurationFingerprint: "config")
        let reports = [older, a, b, c]
        let task = try XCTUnwrap(workflowTasks(reports, models: [model("/a"), model("/b"), model("/c")]).first)
        let memory = WorkflowCharts.series(task, records: reports, metric: .peakMemory)
        XCTAssertEqual(memory.points.map { $0.candidate.modelPath }, ["/c", "/a"])
        XCTAssertEqual(memory.points.map(\.value), [0, 6])
        XCTAssertEqual(memory.points.last?.candidate.measuredAt, a.measuredAt)
        XCTAssertEqual(memory.points.last?.candidate.evidenceID, a.id.uuidString)
        XCTAssertEqual(memory.missing.map(\.modelPath), ["/b"])
        XCTAssertNotNil(task.candidates.first?.estimatedRequiredBytes, "Live fit estimates exist but must not fill missing measured memory")
    }

    func testWorkflowMetricChartsRefuseStaleEvidenceAndMismatchedReportIdentity() throws {
        var a = selectionReport("/a"); a.qualityScore = 5; a.rubricID = "task-rubric"; a.peakMemoryBytes = 6_000_000_000
        var b = selectionReport("/b", signature: "old"); b.qualityScore = 3; b.rubricID = "task-rubric"; b.peakMemoryBytes = 1_000_000_000
        let task = try XCTUnwrap(workflowTasks([a, b], models: [model("/a"), model("/b")]).first)
        for metric in WorkflowCharts.Metric.allCases {
            XCTAssertEqual(WorkflowCharts.series(task, records: [a, b], metric: metric).points.map { $0.candidate.modelPath }, ["/a"])
        }
        var changed = a; changed.configurationFingerprint = "different-settings"
        XCTAssertTrue(WorkflowCharts.series(task, records: [changed, b], metric: .peakMemory).points.isEmpty)
        XCTAssertTrue(WorkflowCharts.series(task, records: [a, a, b], metric: .peakMemory).points.isEmpty)
        XCTAssertTrue(WorkflowCharts.series(task, records: [], metric: .quality).points.isEmpty)
    }

    @MainActor
    func testWorkflowMetricChartsRenderWithRecordedDatesAndUnknownValues() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-chart-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let models = [("/a", "Qwen 3 · 4-bit"), ("/b", "Qwen Coder · 8-bit"), ("/c", "LFM · 4-bit")].map { path, name in
            LibraryModel(item: model(path).item, displayName: name, readiness: .ready)
        }
        var reports: [WorkflowEvidence] = []
        for index in models.indices {
            var report = WorkflowEvidence(id: UUID(), harness: "opencode", workloadID: "coding-task", useCase: .coding,
                modelPath: models[index].item.path, modelSignature: "s", environmentFingerprint: environment,
                measuredAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400), sampleCount: 3,
                totalSeconds: Double(20 + index * 10), source: "session:chart-fixture-\(index)")
            report.configurationFingerprint = "same-prompts-tools-context"
            report.rubricID = "coding-outcome-v1"
            report.qualityScore = index == 2 ? nil : 4 + index
            report.peakMemoryBytes = index == 2 ? nil : Int64(6 - index * 2) * 1_000_000_000
            if index < 2 { report.inferenceSeconds = Double(12 + index * 10); report.toolSeconds = 5; report.queueSeconds = 1 }
            reports.append(report)
        }
        let store = WorkflowEvidenceStore(store: JSONStore<WorkflowEvidence>(fileURL: home.appendingPathComponent("evidence.json")))
        try store.importReport(WorkflowEvidenceStore.encode(WorkflowReport(schemaVersion: 1, records: reports)))
        let task = try XCTUnwrap(workflowTasks(reports, models: models).first)
        XCTAssertEqual(WorkflowCharts.series(task, records: store.records, metric: .quality).missing.map(\.name), ["LFM · 4-bit"])
        XCTAssertEqual(WorkflowCharts.series(task, records: store.records, metric: .peakMemory).missing.map(\.name), ["LFM · 4-bit"])
        for metric in WorkflowCharts.Metric.allCases {
            var reviewedPaths: [String] = []
            var applied = false
            let root = VStack(alignment: .leading) {
                WorkflowChartsView(workflow: store, models: models, environment: environment,
                    hardware: HardwareProfile(chip: "M4", memoryBytes: 32_000_000_000), mode: .chat, activeRunID: nil,
                    onCompare: { _ in WorkflowCharts.ComparisonSelection(slots: nil, reason: "") },
                    onReview: { task, path in
                        reviewedPaths.append(path)
                        return ModelGuidanceReview(evidence: self.actionEvidence(models: models, runs: [], reports: reports), taskID: task.id,
                            candidate: try XCTUnwrap(task.candidates.first { $0.modelPath == path }), roles: [.coding], endpoint: .disabled, verified: true)
                    },
                    onApply: { _, _, _ in applied = true; return "Fixture" }, metric: .constant(metric),
                    inspectedModelPath: .constant(metric == .qualityRuntime ? "/a" : nil))
                Spacer(minLength: 0)
            }.padding(20).frame(width: 960, height: metric == .qualityRuntime ? 760 : 620).background(WorkbenchColor.canvas).preferredColorScheme(.dark)
            let view = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: metric == .qualityRuntime ? 760 : 620), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view; window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            view.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            let attachment = XCTAttachment(data: try XCTUnwrap(image.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "Workflow chart - \(metric.title)"; attachment.lifetime = .keepAlways
            add(attachment)
            if metric == .qualityRuntime {
                XCTAssertTrue(reviewedPaths.isEmpty, "Selecting a point must not start a review or apply changes")
                // Hit the visible Use model button in this fixed 960x760 fixture.
                // Real window input avoids relying on SwiftUI's lazy accessibility tree.
                let point = view.convert(NSPoint(x: 875, y: view.isFlipped ? 443 : view.bounds.height - 443), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                }
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertEqual(reviewedPaths, ["/a"], "The selected model must reach the existing review flow")
                XCTAssertFalse(applied, "Opening review must not apply the preference or switch the endpoint")
            }
        }
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

    func testMusicChampionsKeepListeningQualitySeparateFromSpeedAndOtherRubrics() throws {
        var measured = run([result("/a", metric: 2), result("/b", metric: 1)], mode: .musicGeneration)
        measured.qualityReviews = ["/a": ComparisonQualityReview(score: 5, rubricID: "music-listening-v1", reviewedAt: Date()),
                                   "/b": ComparisonQualityReview(score: 2, rubricID: "music-listening-v1", reviewedAt: Date())]
        let models = [model("/a", task: .musicGeneration), model("/b", task: .musicGeneration)]
        let award = try XCTUnwrap(ComparisonInsights.champions(models: models, runs: [measured], environment: environment).first)
        XCTAssertEqual(award.performance.map(\.modelPath), ["/b"])
        XCTAssertEqual(award.quality.map(\.modelPath), ["/a"])
        measured.qualityReviews?["/b"] = ComparisonQualityReview(score: 5, rubricID: "task-outcome-v1", reviewedAt: Date())
        XCTAssertTrue(try XCTUnwrap(ComparisonInsights.champions(models: models, runs: [measured], environment: environment).first).quality.isEmpty)
    }

    func testMediaChampionsUseModeMetricDirection() throws {
        let measured = run([result("/a", metric: 2), result("/b", metric: 1)], mode: .imageGeneration)
        let award = try XCTUnwrap(ComparisonInsights.champions(models: [model("/a", task: .imageGeneration), model("/b", task: .imageGeneration)], runs: [measured], environment: environment).first)
        XCTAssertEqual(award.performance.map(\.modelPath), ["/b"])
        XCTAssertTrue(award.quality.isEmpty)
        XCTAssertTrue(award.latency.isEmpty)
    }
}
