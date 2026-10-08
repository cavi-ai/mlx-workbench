import Foundation
import XCTest

@testable import mlx_workbench

final class CompareRemodelTests: XCTestCase {
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

    // MARK: Lane states

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
        let tied = run(.chat, variants: ["/a", "/b", "/c"], results: [
            result("/a", tps: 40, ttft: 0.5), result("/b", tps: 40, ttft: 0.2), result("/c", tps: 12),
        ])
        XCTAssertEqual(Set(tied.leaders.map(\.modelPath)), ["/a", "/b"])
        XCTAssertTrue(tied.leaders.contains { $0.modelPath == tied.winner?.modelPath })
        XCTAssertEqual(ComparePresentation.lanes(for: tied).map(\.isLeader), [true, true, false])

        let single = run(.chat, variants: ["/a", "/b"], results: [result("/a", tps: 30), result("/b", tps: 20)])
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
}
