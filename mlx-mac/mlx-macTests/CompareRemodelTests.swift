import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

final class CompareRemodelTests: XCTestCase {
    func testWideChatResultsGiveModelAndPromptColumnsTheAvailableSpace() {
        let layout = ChatComparisonLayout(contentWidth: 1800, promptCount: 2)
        XCTAssertTrue(layout.isWide)
        XCTAssertGreaterThanOrEqual(layout.matrixWidth, 800)
        XCTAssertGreaterThanOrEqual(layout.modelColumn, 320)
        XCTAssertGreaterThanOrEqual(layout.promptColumn, 144)
        XCTAssertGreaterThanOrEqual(1800 - layout.matrixWidth - WorkbenchSpacing.lg, 480)
        XCTAssertEqual(layout.modelColumn + 2 * layout.promptColumn + layout.metricColumn
                       + 3 * WorkbenchSpacing.xs + 2 * WorkbenchSpacing.md, layout.matrixWidth, accuracy: 0.01)
    }

    func testChatResultsReserveReadingSpaceAndScrollLargePromptSets() {
        for width: CGFloat in [1000, 1200, 1800] {
            let layout = ChatComparisonLayout(contentWidth: width, promptCount: 12)
            XCTAssertGreaterThanOrEqual(width - layout.matrixWidth - WorkbenchSpacing.lg, 480)
            XCTAssertGreaterThanOrEqual(layout.modelColumn, 220)
            XCTAssertGreaterThanOrEqual(layout.promptColumn, 132)
            XCTAssertGreaterThan(layout.modelColumn + 12 * layout.promptColumn, layout.matrixWidth)
        }
        for width: CGFloat in [340, 580, 999] {
            let layout = ChatComparisonLayout(contentWidth: width, promptCount: 2)
            XCTAssertFalse(layout.isWide)
            XCTAssertEqual(layout.matrixWidth, width)
            XCTAssertGreaterThanOrEqual(layout.modelColumn, 220)
        }
    }

    func testPromptOutcomeMatrixDistinguishesMissingUnknownAndIncompleteEvidence() {
        let prompt = PromptEntry(id: "p", text: "Answer", maxTokens: 128)
        var run = ComparisonRun(id: UUID(), promptSetID: "test", promptSetName: "Test", useCase: .coding,
            variants: ["/a"], results: [], startedAt: Date(), state: .completed, promptEntries: [prompt])
        func result(_ finish: String?, text: String = "Answer", error: String? = nil, duplicate: Bool = false) -> VariantResult {
            let sample = ComparisonSample(promptID: "p", outputExcerpt: text, tokensPerSecond: 200,
                timeToFirstTokenSeconds: 0.1, error: error, fullOutput: text, finishReason: finish)
            return VariantResult(modelPath: "/a", modelSignature: nil, samples: duplicate ? [sample, sample] : [sample],
                aggregateTokensPerSecond: 200, aggregateTTFTSeconds: 0.1, error: nil)
        }
        XCTAssertEqual(ChatComparisonPresentation.outcome(result("stop"), prompt: prompt, in: run), .finished)
        XCTAssertEqual(ChatComparisonPresentation.outcome(result("length"), prompt: prompt, in: run), .tokenLimit)
        XCTAssertEqual(ChatComparisonPresentation.outcome(result("stop", text: "<think>Still thinking"), prompt: prompt, in: run), .incomplete)
        XCTAssertEqual(ChatComparisonPresentation.outcome(result(nil), prompt: prompt, in: run), .unknown)
        XCTAssertEqual(ChatComparisonPresentation.outcome(result("stop", duplicate: true), prompt: prompt, in: run), .unknown)
        XCTAssertEqual(ChatComparisonPresentation.outcome(result("stop", error: "Request failed"), prompt: prompt, in: run), .blocked)
        XCTAssertEqual(ChatComparisonPresentation.outcome(nil, prompt: prompt, in: run), .notRecorded)
        run.state = .running
        XCTAssertEqual(ChatComparisonPresentation.outcome(nil, prompt: prompt, in: run), .waiting)
        let blocked = VariantResult(modelPath: "/a", modelSignature: nil, samples: [],
            aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: "Runtime missing")
        XCTAssertEqual(ChatComparisonPresentation.outcome(blocked, prompt: prompt, in: run), .blocked)
    }

    func testChatCompletionRequiresTheRecordedCohortAndValidTaskOutcomes() throws {
        let prompts = [PromptEntry(id: "p", text: "Answer", maxTokens: 128)]
        func sample(_ reason: String?, output: String = "Answer", calls: Int? = nil, valid: Int? = nil) -> ComparisonSample {
            ComparisonSample(promptID: "p", outputExcerpt: output, tokensPerSecond: 100,
                timeToFirstTokenSeconds: 0.1, error: nil, toolCalls: calls, toolCallsValid: valid,
                fullOutput: output, finishReason: reason)
        }
        func result(_ samples: [ComparisonSample], speed: Double = 100) -> VariantResult {
            VariantResult(modelPath: "/a", modelSignature: nil, samples: samples,
                aggregateTokensPerSecond: speed, aggregateTTFTSeconds: 0.1, error: nil)
        }
        var run = ComparisonRun(id: UUID(), promptSetID: "test", promptSetName: "Test", useCase: .coding,
            variants: ["/a"], results: [result([sample("stop")])], startedAt: Date(), state: .completed,
            promptEntries: prompts)
        XCTAssertTrue(ChatComparisonPresentation.completion(run.results[0], in: run).isComplete)
        XCTAssertTrue(run.feedsRecommendations)
        XCTAssertNotNil(run.winner)
        run.laneConfigurations = [ComparisonLaneConfiguration(id: "a", modelPath: "/a", modelSignature: nil, runtime: "splash")]
        XCTAssertFalse(run.feedsRecommendations)
        XCTAssertNil(run.winner, "Custom serving stays out of recommendations and promotion")
        run.laneConfigurations = nil
        XCTAssertNotNil(run.winner)
        for samples in [[sample("length")], [sample(nil)], [], [sample("stop"), sample("stop")],
                        [sample("stop", output: "")], [sample("stop", output: "<think>Still thinking")]] {
            run.results = [result(samples, speed: 200)]
            XCTAssertFalse(ChatComparisonPresentation.completion(run.results[0], in: run).isComplete)
            XCTAssertNil(run.winner)
            XCTAssertEqual(run.results[0].aggregateTokensPerSecond, 200, "Raw measurements remain available")
        }
        run.results = [result([sample("stop")])]; run.promptEntries = nil
        XCTAssertNil(run.winner, "Legacy evidence cannot prove prompt coverage")
        run.promptEntries = prompts; run.state = .cancelled
        XCTAssertNil(run.winner)
        run.state = .completed
        run.promptEntries?[0].tool = PromptToolSpec(name: "lookup", description: "Look up a value", parametersJSON: "{}")
        run.results = [result([sample("tool_calls", output: "", calls: 1, valid: 1)])]
        XCTAssertNotNil(run.winner, "Valid tool-only outcomes can complete a tool prompt")
        run.results = [result([sample("tool_calls", output: "", calls: 2, valid: 1)])]
        XCTAssertNil(run.winner)
    }

    func testChatReadingSeparatesInlineReasoningWithoutChangingRecordedText() {
        let raw = "<think>Check the recurrence.</think>\n```python\ndef fib(n):\n    return n\n```"
        let output = ChatRecordedText(raw)
        XCTAssertEqual(output.reasoning, "Check the recurrence.")
        XCTAssertTrue(output.answer.hasPrefix("```python"))
        XCTAssertTrue(output.hasInlineReasoning)
        XCTAssertEqual(ChatRecordedText("<think>Still thinking").answer, "")
        XCTAssertEqual(ChatRecordedText("Plain answer").answer, "Plain answer")
        XCTAssertEqual(ChatRecordedText("Literal </think> text").answer, "Literal </think> text")
        XCTAssertEqual(ChatRecordedText("Before <think>reason</think> after").answer, "Before  after")
        XCTAssertTrue(raw.hasPrefix("<think>"), "Presentation must not mutate persisted output")
    }

    func testCancelledAndInterruptedRunsRetainValuesWithoutRankingIncompleteCohorts() {
        for state in [ComparisonRunState.cancelled, .interrupted] {
            let stopped = run(.chat, variants: ["/a", "/b", "/c"], results: [result("/a", tps: 50), result("/b", tps: 20)], state: state)
            let lanes = ComparePresentation.lanes(for: stopped)
            XCTAssertEqual(lanes[0].value, 50); XCTAssertEqual(lanes[1].value, 20)
            XCTAssertTrue(lanes.allSatisfy { !$0.isLeader && $0.fraction == nil })
            XCTAssertEqual(lanes[2].state, .notMeasured)
        }
    }
    func testModelPickerAllowsOnlyExplicitlyRepeatablePaths() {
        let models = [library("/models/strata"), library("/models/other")]
        let slots: [String?] = ["/models/strata", nil]
        XCTAssertEqual(ComparePresentation.options(forSlot: 1, slots: slots, candidates: models).map { $0.item.path }, ["/models/other"])
        XCTAssertEqual(ComparePresentation.options(forSlot: 1, slots: slots, candidates: models,
            repeatedPaths: ["/models/strata"]).map { $0.item.path }, ["/models/strata", "/models/other"])
    }

    private let base = Date(timeIntervalSince1970: 1_791_388_800)

    private func result(_ path: String, tps: Double? = nil, metric: Double? = nil, ttft: Double? = nil,
                        error: String? = nil, samples: [ComparisonSample] = []) -> VariantResult {
        VariantResult(modelPath: path, modelSignature: nil, samples: samples, aggregateTokensPerSecond: tps,
                      aggregateTTFTSeconds: ttft, error: error, aggregateMetric: metric)
    }

    private func run(_ mode: ComparisonMode?, variants: [String], results: [VariantResult], state: ComparisonRunState = .completed,
                     at offset: TimeInterval = 0, promptSetID: String = "builtin-coding", useCase: UseCase? = nil) -> ComparisonRun {
        ComparisonRun(id: UUID(), promptSetID: promptSetID, promptSetName: promptSetID, useCase: useCase, variants: variants,
                      results: results, startedAt: base.addingTimeInterval(offset), finishedAt: nil, state: state, mode: mode)
    }

    private func sample(_ id: String = "p", tps: Double? = nil, ttft: Double? = nil, prefill: Double? = nil,
                        calls: Int? = nil, names: [String]? = nil, valid: Int? = nil, error: String? = nil) -> ComparisonSample {
        ComparisonSample(promptID: id, outputExcerpt: "out", tokensPerSecond: tps, timeToFirstTokenSeconds: ttft, error: error,
                         prefillTokensPerSecond: prefill, toolCalls: calls, toolNames: names, toolCallsValid: valid)
    }

    private func states(_ run: ComparisonRun) -> [CompareLane.State] {
        ComparePresentation.lanes(for: run).map(\.state)
    }

    private func library(_ path: String, quantization: String? = "4bit", parameters: String? = nil, bytes: Int64 = 0) -> LibraryModel {
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: bytes,
            modifiedAt: nil, shard: nil, modelKey: nil, architecture: nil, quantization: quantization, parameters: parameters,
            structure: nil, signature: nil, companion: nil, readable: true,
            status: "ready", outputs: [], tensorCount: nil, error: nil
        )
        return LibraryModel(item: item, displayName: nil, readiness: .ready)
    }

    func testFastestNeedsAnAnswerToEveryChatPrompt() {
        let cut = ComparisonSample(promptID: "p", outputExcerpt: "", tokensPerSecond: 300, timeToFirstTokenSeconds: 0.1,
                                   error: nil, finishReason: "length")
        let answered = ComparisonSample(promptID: "p", outputExcerpt: "def fib(n):", tokensPerSecond: 90,
                                        timeToFirstTokenSeconds: 0.2, error: nil, finishReason: "stop")
        let chat = run(nil, variants: ["/fast", "/slow"],
                       results: [result("/fast", tps: 300, samples: [cut]), result("/slow", tps: 90, samples: [answered])])
        XCTAssertEqual(chat.leaders.map(\.modelPath), ["/slow"])
        XCTAssertEqual(ComparePresentation.lanes(for: chat).map(\.isLeader), [false, true])
    }

    // MARK: Lane states

    func testUnavailableReusedModelsBlockRunningUntilExplicitlyReplacedOrRemoved() {
        let slots: [String?] = ["/a", "/missing"]
        let available: Set<String> = ["/a", "/b"]
        XCTAssertFalse(ComparePresentation.canRun(slots: slots, activeRunID: nil, availablePaths: available))
        XCTAssertTrue(ComparePresentation.canRun(slots: ["/a", "/b"], activeRunID: nil, availablePaths: available))
        XCTAssertTrue(ComparePresentation.canRun(slots: ["/a", nil], activeRunID: nil, availablePaths: available))
        XCTAssertFalse(ComparePresentation.canRun(slots: ["/a", "/b"], activeRunID: UUID(), availablePaths: available))
    }

    func testRunGuidanceIdentifiesTheFirstBlockerWithoutChangingModelEligibility() {
        let available: Set<String> = ["/a", "/b"]
        XCTAssertEqual(ComparePresentation.runUnavailableReason(slots: [nil, nil], activeRunID: UUID(),
            availablePaths: available, hasPromptSet: false), "Wait for the current comparison to finish.")
        XCTAssertEqual(ComparePresentation.runUnavailableReason(slots: [nil, nil], activeRunID: nil,
            availablePaths: available, hasPromptSet: false), "Choose a prompt set.")
        XCTAssertEqual(ComparePresentation.runUnavailableReason(slots: [nil, nil], activeRunID: nil,
            availablePaths: available), "Choose at least one model.")
        XCTAssertEqual(ComparePresentation.runUnavailableReason(slots: ["/a", nil, "/missing", "/also-missing"],
            activeRunID: nil, availablePaths: available), "Model C is unavailable. Replace it or choose None.")
        XCTAssertEqual(ComparePresentation.runUnavailableReason(slots: [nil, "/missing"],
            activeRunID: nil, availablePaths: available), "Model B is unavailable. Replace it or choose None.")
        XCTAssertNil(ComparePresentation.runUnavailableReason(slots: ["/a", nil], activeRunID: nil, availablePaths: available))
        XCTAssertNil(ComparePresentation.runUnavailableReason(slots: ["/a", "/a"], activeRunID: nil, availablePaths: available))
        XCTAssertNil(ComparePresentation.runUnavailableReason(slots: ["/unknown", nil], activeRunID: nil))
        let slotCases: [[String?]] = [[nil, nil], ["/a", nil], ["/a", "/a"], ["/a", "/missing"], [nil, "/b"]]
        for slots in slotCases {
            for active in [UUID?.none, UUID?.some(UUID())] {
                let originalEligibility = !ComparePresentation.variantPaths(slots).isEmpty && active == nil
                    && ComparePresentation.variantPaths(slots).allSatisfy(available.contains)
                XCTAssertEqual(ComparePresentation.runUnavailableReason(slots: slots, activeRunID: active,
                    availablePaths: available) == nil, originalEligibility)
                XCTAssertEqual(ComparePresentation.canRun(slots: slots, activeRunID: active,
                    availablePaths: available), originalEligibility)
            }
        }
    }

    func testRunGuidanceBlocksPendingSavesAndEmptySetsUntilTheyBecomeRunnable() {
        let slots: [String?] = ["/a", nil]
        let available: Set<String> = ["/a"]
        XCTAssertEqual(ComparePresentation.runUnavailableReason(slots: slots, activeRunID: nil,
            availablePaths: available, savingPromptSet: true), "Wait for the prompt set save to finish.")
        XCTAssertEqual(ComparePresentation.runUnavailableReason(slots: slots, activeRunID: nil,
            availablePaths: available, hasPrompts: false), "Choose a prompt set with at least one prompt.")
        XCTAssertEqual(ComparePresentation.runUnavailableReason(slots: slots, activeRunID: nil,
            availablePaths: available, hasPromptSet: false, savingPromptSet: true, hasPrompts: false),
            "Wait for the prompt set save to finish.")
        XCTAssertEqual(ComparePresentation.runUnavailableReason(slots: slots, activeRunID: UUID(),
            availablePaths: available, savingPromptSet: true, hasPrompts: false),
            "Wait for the current comparison to finish.")
        XCTAssertEqual(ComparePresentation.runUnavailableReason(slots: slots, activeRunID: nil,
            availablePaths: available, hasPromptSet: false, hasPrompts: false), "Choose a prompt set.")
        XCTAssertNil(ComparePresentation.runUnavailableReason(slots: slots, activeRunID: nil,
            availablePaths: available, savingPromptSet: false, hasPrompts: true))
    }

    func testSixLaneStates() {
        let variants = ["/a", "/b", "/c", "/d"]
        let running = run(.chat, variants: variants, results: [result("/a", tps: 40)], state: .running)
        XCTAssertEqual(states(running), [.measured, .measuring, .waiting, .waiting])

        let finished = run(.chat, variants: variants, results: [
            result("/a", tps: 40), result("/b", error: "load failed"), result("/c"),
        ])
        XCTAssertEqual(states(finished), [.measured, .failed("load failed"), .noMeasurement, .notMeasured])
    }

    func testLanesFollowVariantsAndMatchResultsByPath() {
        let reordered = run(.chat, variants: ["/a", "/b"], results: [result("/b", tps: 20), result("/a", tps: 40)])
        let lanes = ComparePresentation.lanes(for: reordered)
        XCTAssertEqual(lanes.map(\.path), ["/a", "/b"])
        XCTAssertEqual(lanes.map(\.letter), ["A", "B"])
        XCTAssertEqual(lanes.map(\.value), [40, 20])
    }

    func testZeroAndNegativeMetricsAreNotMeasured() {
        let zero = run(.chat, variants: ["/a", "/b", "/c"], results: [result("/a", tps: 0), result("/b", tps: -3), result("/c", tps: 10)])
        XCTAssertEqual(states(zero), [.noMeasurement, .noMeasurement, .measured])
    }

    // MARK: Leader owner

    func testWinnerIsAmongLeadersAndTiesShareTheLead() {
        let finished = ComparisonSample(promptID: "p", outputExcerpt: "Answer", tokensPerSecond: 40,
            timeToFirstTokenSeconds: 0.2, error: nil, fullOutput: "Answer", finishReason: "stop")
        let prompts = [PromptEntry(id: "p", text: "Answer", maxTokens: 128)]
        var tied = run(.chat, variants: ["/a", "/b", "/c"], results: [
            result("/a", tps: 40, ttft: 0.5, samples: [finished]), result("/b", tps: 40, ttft: 0.2, samples: [finished]),
            result("/c", tps: 12, samples: [finished]),
        ])
        tied.promptEntries = prompts
        XCTAssertEqual(Set(tied.leaders.map(\.modelPath)), ["/a", "/b"])
        XCTAssertTrue(tied.leaders.contains { $0.modelPath == tied.winner?.modelPath })
        XCTAssertEqual(ComparePresentation.lanes(for: tied).map(\.isLeader), [true, true, false])

        var single = run(.chat, variants: ["/a", "/b"], results: [
            result("/a", tps: 30, samples: [finished]), result("/b", tps: 20, samples: [finished])])
        single.promptEntries = prompts
        XCTAssertEqual(single.leaders.map(\.modelPath), ["/a"])
        XCTAssertEqual(single.winner?.modelPath, "/a")
    }

    func testLowerIsBetterModesLeadWithTheSmallestValue() {
        let image = run(.imageGeneration, variants: ["/a", "/b"], results: [result("/a", metric: 2.0), result("/b", metric: 1.5)])
        XCTAssertEqual(image.leaders.map(\.modelPath), ["/b"])
        let lanes = ComparePresentation.lanes(for: image)
        XCTAssertEqual(lanes[1].fraction, 1)
        XCTAssertEqual(lanes[0].fraction ?? 0, 0.75, accuracy: 0.0001)
    }

    func testHigherIsBetterFractionIsShareOfBest() {
        let chat = run(.chat, variants: ["/a", "/b"], results: [result("/a", tps: 50), result("/b", tps: 20)])
        let lanes = ComparePresentation.lanes(for: chat)
        XCTAssertEqual(lanes[0].fraction, 1)
        XCTAssertEqual(lanes[1].fraction ?? 0, 0.4, accuracy: 0.0001)
    }

    func testSingleMeasuredLaneIsNotRanked() {
        let chat = run(.chat, variants: ["/a", "/b"], results: [result("/a", tps: 50), result("/b", error: "boom")])
        let lanes = ComparePresentation.lanes(for: chat)
        XCTAssertEqual(chat.leaders.map(\.modelPath), ["/a"])
        XCTAssertNil(lanes[0].fraction)
        XCTAssertFalse(lanes[0].isLeader)
    }

    func testFailedZeroAndNegativeResultsNeverLead() {
        let chat = run(.chat, variants: ["/a", "/b", "/c", "/d"], results: [
            result("/a", tps: 500, error: "failed"), result("/b", tps: 0), result("/c", tps: -4), result("/d", tps: 9),
        ])
        XCTAssertEqual(chat.leaders.map(\.modelPath), ["/d"])
        XCTAssertNil(run(.imageGeneration, variants: ["/a"], results: [result("/a", metric: 0)]).leaders.first)
    }

    func testChampionsUseTheLeaderOwner() {
        let tied = run(.chat, variants: ["/a", "/b"], results: [result("/a", tps: 40), result("/b", tps: 40)])
        let value = tied.metricValue(of: tied.results[0])
        XCTAssertEqual(value, 40)
        XCTAssertEqual(tied.metricValue(of: result("/x", tps: 3, error: "e")), nil)
    }

    // MARK: Mode and run coherence

    func testShownRunPrefersActiveThenPickInModeThenNewestOfMode() {
        let oldChat = run(.chat, variants: ["/a"], results: [], at: 0)
        let newChat = run(.chat, variants: ["/a"], results: [], at: 100)
        let image = run(.imageGeneration, variants: ["/a"], results: [], at: 200)
        let runs = [image, newChat, oldChat]

        XCTAssertEqual(ComparePresentation.shownRun(runs: runs, mode: .chat, selectedRunID: nil, activeRunID: nil)?.id, newChat.id)
        XCTAssertEqual(ComparePresentation.shownRun(runs: runs, mode: .chat, selectedRunID: oldChat.id, activeRunID: nil)?.id, oldChat.id)
        XCTAssertEqual(ComparePresentation.shownRun(runs: runs, mode: .chat, selectedRunID: image.id, activeRunID: nil)?.id, newChat.id)
        XCTAssertEqual(ComparePresentation.shownRun(runs: runs, mode: .chat, selectedRunID: oldChat.id, activeRunID: image.id)?.id, image.id)
        XCTAssertNil(ComparePresentation.shownRun(runs: runs, mode: .musicGeneration, selectedRunID: nil, activeRunID: nil))
    }

    func testPickingAnOlderCrossModeRunShowsThatRun() {
        let sets = BuiltinPromptSets.all + [ComparisonMediaFixtures.imageGenerationSet]
        let olderImage = run(.imageGeneration, variants: ["/a"], results: [], at: 10, promptSetID: ComparisonMediaFixtures.imageGenerationSet.id)
        let newerImage = run(.imageGeneration, variants: ["/a"], results: [], at: 90, promptSetID: ComparisonMediaFixtures.imageGenerationSet.id)
        let chat = run(.chat, variants: ["/a"], results: [], at: 50)
        let runs = [newerImage, chat, olderImage]

        let start = CompareSelection(mode: .chat, selectedRunID: nil, promptSetID: BuiltinPromptSets.coding.id)
        let picked = ComparePresentation.pick(olderImage, from: start, promptSets: sets)
        XCTAssertEqual(picked.mode, .imageGeneration)
        XCTAssertEqual(picked.selectedRunID, olderImage.id)
        XCTAssertEqual(ComparePresentation.shownRun(runs: runs, mode: picked.mode, selectedRunID: picked.selectedRunID, activeRunID: nil)?.id,
                       olderImage.id)
    }

    func testCrossModePickRestoresThatRunsPromptSetElseTheFirst() {
        let second = BuiltinPromptSets.generalChat
        let sets = BuiltinPromptSets.all
        let start = CompareSelection(mode: .imageGeneration, selectedRunID: nil, promptSetID: "image")
        let withSet = run(.chat, variants: ["/a"], results: [], promptSetID: second.id)
        XCTAssertEqual(ComparePresentation.pick(withSet, from: start, promptSets: sets).promptSetID, second.id)

        let missing = run(.chat, variants: ["/a"], results: [], promptSetID: "deleted-set")
        XCTAssertEqual(ComparePresentation.pick(missing, from: start, promptSets: sets).promptSetID,
                       ComparisonViewLogic.promptSets(sets, for: .chat).first?.id)

        let sameMode = CompareSelection(mode: .chat, selectedRunID: nil, promptSetID: "keep")
        let samePick = ComparePresentation.pick(withSet, from: sameMode, promptSets: sets)
        XCTAssertEqual(samePick.promptSetID, "keep")
        XCTAssertEqual(samePick.selectedRunID, withSet.id)
    }

    func testChangingModeClearsThePickAndShowsTheNewestOfThatMode() {
        let chat = run(.chat, variants: ["/a"], results: [], at: 5)
        let image = run(.imageGeneration, variants: ["/a"], results: [], at: 1)
        let sets = BuiltinPromptSets.all + [ComparisonMediaFixtures.imageGenerationSet]
        let start = CompareSelection(mode: .chat, selectedRunID: chat.id, promptSetID: "x")

        let next = ComparePresentation.changeMode(start, to: .imageGeneration, promptSets: sets)
        XCTAssertEqual(next.mode, .imageGeneration)
        XCTAssertNil(next.selectedRunID)
        XCTAssertEqual(next.promptSetID, ComparisonMediaFixtures.imageGenerationSet.id)
        XCTAssertEqual(ComparePresentation.shownRun(runs: [chat, image], mode: next.mode, selectedRunID: next.selectedRunID, activeRunID: nil)?.id,
                       image.id)
        XCTAssertEqual(ComparePresentation.changeMode(start, to: .chat, promptSets: sets), start)
    }

    func testOpeningKeepsTheNewestRunsPromptSetNotTheFirst() {
        let sets = ComparisonViewLogic.promptSets(BuiltinPromptSets.all, for: .chat)
        XCTAssertNotEqual(sets.first?.id, BuiltinPromptSets.toolCalling.id)
        let tool = run(.chat, variants: ["/a"], results: [], at: 100, promptSetID: BuiltinPromptSets.toolCalling.id)
        let older = run(.chat, variants: ["/a"], results: [], at: 1, promptSetID: BuiltinPromptSets.coding.id)
        let image = run(.imageGeneration, variants: ["/a"], results: [], at: 500, promptSetID: ComparisonMediaFixtures.imageGenerationSet.id)
        XCTAssertEqual(ComparePresentation.restoredPromptSetID(runs: [image, tool, older], mode: .chat, promptSets: sets), BuiltinPromptSets.toolCalling.id)
        XCTAssertNil(ComparePresentation.restoredPromptSetID(runs: [image], mode: .chat, promptSets: sets))
    }

    func testEmptyStatePredicateAndTitle() {
        let chat = run(.chat, variants: ["/a"], results: [])
        XCTAssertFalse(ComparePresentation.showsEmptyState(runs: [chat], mode: .chat, selectedRunID: nil, activeRunID: nil))
        XCTAssertTrue(ComparePresentation.showsEmptyState(runs: [chat], mode: .musicGeneration, selectedRunID: chat.id, activeRunID: nil))
        XCTAssertTrue(ComparePresentation.showsEmptyState(runs: [], mode: .chat, selectedRunID: nil, activeRunID: nil))
        XCTAssertEqual(ComparePresentation.emptyTitle(for: .musicGeneration), "No music generation comparisons yet")
    }

    // MARK: Strings

    func testChatCellStringsOmitMissingValuesAndNameTools() {
        let nbsp = "\u{00A0}"
        func joined(_ parts: [String]) -> String { parts.map { $0.replacingOccurrences(of: " ", with: nbsp) }.joined(separator: " · ") }

        let full = ComparisonViewLogic.metrics(sample(tps: 48.2, ttft: 0.42, prefill: 1200, calls: 2, names: ["get_weather", "search"], valid: 2), mode: .chat)
        XCTAssertEqual(full.primary, "48.2 tok/s")
        XCTAssertEqual(full.details, joined(["first token 0.42 s", "in ~1200 tok/s (est.)", "2 tool calls: get_weather, search", "2 usable"]))

        let bare = ComparisonViewLogic.metrics(sample(tps: 10), mode: .chat)
        XCTAssertEqual(bare.details, "")

        let none = ComparisonViewLogic.metrics(sample(tps: 10, calls: 0), mode: .chat)
        XCTAssertEqual(none.details, joined(["No tool calls"]))

        let one = ComparisonViewLogic.metrics(sample(tps: 10, calls: 1, names: nil, valid: nil), mode: .chat)
        XCTAssertEqual(one.details, joined(["1 tool call"]))
    }

    func testChatLaneStrings() {
        let full = result("/a", tps: 40, ttft: 0.42, samples: [
            sample("p1", tps: 31.2, prefill: 1180, calls: 1, valid: 1), sample("p2", tps: 48.0, prefill: 1220, calls: 1, valid: 0),
        ])
        XCTAssertEqual(ComparisonViewLogic.chatLaneDetails(full), [
            "in ~1200 tok/s (est.)", "first token 0.42 s", "31.2–48.0 tok/s across 2 prompts", "2 tool calls, 1 usable",
        ])

        let noTools = result("/b", tps: 40, samples: [sample("p1", tps: 40, calls: 0), sample("p2", tps: 40, calls: 0)])
        XCTAssertEqual(ComparisonViewLogic.chatLaneDetails(noTools).last, "No tool calls")

        let sparse = result("/c", tps: 12, samples: [sample("p1", tps: 12)])
        XCTAssertEqual(ComparisonViewLogic.chatLaneDetails(sparse), [])
    }

    func testPixelSpreadIsNotAMetricAndWordErrorsReadInWords() {
        let image = ComparisonSample(promptID: "i", outputExcerpt: "", tokensPerSecond: nil, timeToFirstTokenSeconds: nil, error: nil,
                                     seconds: 3, pixelStd: 54)
        XCTAssertFalse(ComparisonViewLogic.metrics(image, mode: .imageGeneration).details.contains("pixel"))
        XCTAssertEqual(ComparisonViewLogic.wordErrorText(0.12), "12% word errors")
        XCTAssertEqual(ComparisonViewLogic.wordErrorText(0), "0% word errors")
    }

    func testLaneValueSplitsNumeralFromUnitAndLabelsReadInOrder() {
        XCTAssertTrue(ComparePresentation.splitValue("48.2 tok/s") == ("48.2", "tok/s"))
        XCTAssertTrue(ComparePresentation.splitValue("RTF 0.50") == ("0.50", "RTF"))
        XCTAssertTrue(ComparePresentation.splitValue("n/a") == ("n/a", ""))

        let chat = run(.chat, variants: ["/a", "/b", "/c", "/d"], results: [
            result("/a", tps: 50), result("/b", tps: 20), result("/c", error: "x"),
        ], state: .running)
        let lanes = ComparePresentation.lanes(for: chat)
        let metric = ComparisonMode.chat.primaryMetric
        XCTAssertEqual(ComparePresentation.laneAccessibilityLabel(lanes[0], name: "Alpha", metric: metric), "A, Alpha, 50.0 tok/s, fastest")
        XCTAssertEqual(ComparePresentation.laneAccessibilityLabel(lanes[1], name: "Beta", metric: metric), "B, Beta, 20.0 tok/s, 40% of fastest")
        XCTAssertEqual(ComparePresentation.laneAccessibilityLabel(lanes[2], name: "Gamma", metric: metric), "C, Gamma, failed")
        XCTAssertEqual(ComparePresentation.laneAccessibilityLabel(lanes[3], name: "Delta", metric: metric), "D, Delta, measuring")
    }

    // MARK: Geometry and tiles

    func testGridKeepsLanesAtTheirMinimumAndScrollsBelow() {
        let size = WorkbenchSize.Compare.self
        let fits = ComparePresentation.gridLayout(contentWidth: 1032, laneCount: 4)
        XCTAssertFalse(fits.scrolls)
        XCTAssertEqual(fits.laneWidth, size.laneMinimum)
        XCTAssertEqual(fits.promptWidth, size.promptColumn)

        let tight = ComparePresentation.gridLayout(contentWidth: 1031, laneCount: 4)
        XCTAssertTrue(tight.scrolls)
        XCTAssertEqual(tight.laneWidth, size.laneIdeal)

        XCTAssertEqual(ComparePresentation.gridLayout(contentWidth: 1060, laneCount: 1).laneWidth, size.laneMaximum)
        XCTAssertEqual(ComparePresentation.gridLayout(contentWidth: 599, laneCount: 4).promptWidth, size.promptColumnCompact)
        XCTAssertEqual(ComparePresentation.gridLayout(contentWidth: 1060, laneCount: 1).mediaSide, size.thumbnailMaximum)
        XCTAssertEqual(ComparePresentation.gridLayout(contentWidth: 472, laneCount: 4).mediaSide, size.laneIdeal - 2 * size.cellInset)
    }

    func testGridLayoutForOneTwoAndFourLanes() {
        let size = WorkbenchSize.Compare.self
        for (width, lanes, expectedLane, scrolls) in [
            (CGFloat(1060), 1, size.laneMaximum, false), (1060, 2, size.laneMaximum, false), (1060, 4, (1060 - 184 - 48) / 4, false),
            (752, 1, size.laneMaximum, false), (752, 2, (752 - 184 - 24) / 2, false), (752, 4, size.laneIdeal, true),
        ] {
            let layout = ComparePresentation.gridLayout(contentWidth: width, laneCount: lanes)
            XCTAssertEqual(layout.promptWidth, size.promptColumn, "\(width) x \(lanes)")
            XCTAssertEqual(layout.laneWidth, expectedLane, "\(width) x \(lanes)")
            XCTAssertEqual(layout.scrolls, scrolls, "\(width) x \(lanes)")
        }
    }

    func testFailureFirstLineIsTheFirstNonEmptyLine() {
        let traceback = "\n  \nTraceback (most recent call last):\n  File \"x.py\", line 1\nRuntimeError: boom"
        XCTAssertEqual(ComparePresentation.firstLine(of: traceback), "Traceback (most recent call last):")
        XCTAssertEqual(ComparePresentation.firstLine(of: "single"), "single")
        XCTAssertEqual(ComparePresentation.firstLine(of: " \n "), "")
    }

    func testNotRunCellOnlyForAWholeVariantFailureWithoutASample() {
        let failed = result("/a", error: "load failed")
        let ok = result("/b", tps: 10)
        XCTAssertTrue(ComparePresentation.showsNotRun(sample: nil, result: failed))
        XCTAssertFalse(ComparePresentation.showsNotRun(sample: nil, result: ok))
        XCTAssertFalse(ComparePresentation.showsNotRun(sample: nil, result: nil))
        XCTAssertFalse(ComparePresentation.showsNotRun(sample: sample(error: "bad"), result: failed))
        XCTAssertFalse(ComparePresentation.showsNotRun(sample: sample(error: "bad"), result: ok))
    }

    func testListeningShowsOnlyForCompletedMusicRuns() {
        let results = [result("/a", metric: 1.2), result("/b", metric: 0.9)]
        XCTAssertTrue(ComparisonViewLogic.showsListening(run(.musicGeneration, variants: ["/a", "/b"], results: results)))
        XCTAssertFalse(ComparisonViewLogic.showsListening(run(.musicGeneration, variants: ["/a", "/b"], results: results, state: .running)))
        XCTAssertFalse(ComparisonViewLogic.showsListening(run(.imageGeneration, variants: ["/a", "/b"], results: results)))
        XCTAssertFalse(ComparisonViewLogic.showsListening(run(nil, variants: ["/a", "/b"], results: results)))
    }

    func testSlotTileLineComesFromTheLibraryModelOnly() {
        XCTAssertEqual(ComparePresentation.tileLine(library("/a", quantization: "4bit", parameters: "7B", bytes: 4_000_000_000)), "4bit · 7B")
        XCTAssertEqual(ComparePresentation.tileLine(library("/b", quantization: "8bit", parameters: nil, bytes: 2_000_000_000)),
                       "8bit · " + ByteCountFormatter.string(fromByteCount: 2_000_000_000, countStyle: .file))
        XCTAssertNil(ComparePresentation.tileLine(library("/c", quantization: nil, parameters: nil, bytes: 0)))
    }

    func testChatLaneWithoutARuntimeChoiceStillNamesItsRuntime() {
        XCTAssertEqual(ComparePresentation.fixedRuntimeTitle(nil), "Automatic")
        XCTAssertEqual(ComparePresentation.fixedRuntimeTitle("splash"), "Splash")
        XCTAssertEqual(ComparePresentation.fixedRuntimeTitle("mlx_lm"), "MLX-LM")
    }

    func testABlockedLaneSaysSoOnceWhenThePromptAndTheRunAgree() {
        typealias P = ChatComparisonPresentation
        let blocked = P.Completion(finished: 0, total: 2, label: "Blocked", isComplete: false)
        let lines = P.outcomeLines(prompt: .blocked, run: blocked)
        XCTAssertEqual(lines.prompt, "Blocked · entire run")
        XCTAssertNil(lines.run)

        let partial = P.Completion(finished: 1, total: 2, label: "1/2 finished · incomplete", isComplete: false)
        let mixed = P.outcomeLines(prompt: .finished, run: partial)
        XCTAssertEqual(mixed.prompt, "Finished · this prompt")
        XCTAssertEqual(mixed.run, "1/2 finished · incomplete · entire run")
        XCTAssertNil(P.outcomeLines(prompt: .notRecorded, run: nil).run)
    }
}
