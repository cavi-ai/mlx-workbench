import SwiftUI
import XCTest

@testable import mlx_workbench

/// Pure presentation behind the Overview route: the Model Budget instrument,
/// the next-step button, the layout thresholds, the flight-path tones and the
/// Library strip.
final class OverviewPresentationTests: XCTestCase {
    private let stamp = Date(timeIntervalSinceReferenceDate: 1_000_000_000)
    private let hardware = HardwareProfile(chip: "M5", model: nil, memoryBytes: 32_000_000_000, macOSVersion: nil)

    // MARK: - Model budget

    func testBudgetSegmentsSplitTotalIntoInUseReserveAndBudget() throws {
        let presentation = budget(total: 32_000_000_000, available: 20_000_000_000, reserveGB: 4)
        let segments = try XCTUnwrap(presentation.segments)
        XCTAssertEqual(segments.inUse, 0.375, accuracy: 1e-9)
        XCTAssertEqual(segments.reserve, 0.125, accuracy: 1e-9)
        XCTAssertEqual(segments.budget, 0.5, accuracy: 1e-9)
        XCTAssertEqual(segments.inUse + segments.reserve + segments.budget, 1, accuracy: 1e-9, "no serving segment is fabricated")
        XCTAssertEqual(presentation.budgetBytes, 16_000_000_000)
        XCTAssertEqual(presentation.leadText, "~16.0")
    }

    func testBudgetClampsAtZeroWhenReserveExceedsAvailable() throws {
        let presentation = budget(total: 32_000_000_000, available: 3_000_000_000, reserveGB: 4)
        XCTAssertEqual(presentation.budgetBytes, 0)
        XCTAssertEqual(presentation.leadText, "~0.0")
        let segments = try XCTUnwrap(presentation.segments)
        XCTAssertEqual(segments.budget, 0)
        XCTAssertEqual(segments.reserve, 3.0 / 32.0, accuracy: 1e-9)
        XCTAssertEqual(segments.inUse + segments.reserve + segments.budget, 1, accuracy: 1e-9)
    }

    func testCaptionStatesTotalReserveAndContext() {
        let presentation = budget(total: 32_000_000_000, available: 20_000_000_000, reserveGB: 4, context: 8192)
        XCTAssertEqual(presentation.caption, "of 32.0 GB unified memory · 4 GB reserve · 8K-token context")
        XCTAssertEqual(presentation.compactCaption, "of 32.0 GB · 4 GB reserve")
    }

    func testMarkerSitsAtModelFootprintFromStartOfBudget() throws {
        let model = makeModel(bytes: 4_000_000_000, parameters: "7B")
        let presentation = budget(total: 32_000_000_000, available: 20_000_000_000, reserveGB: 4, model: model)
        let needed = FitAdvisor.neededBytes(modelBytes: 4_000_000_000, contextTokens: 8192, parameters: "7B")
        let marker = try XCTUnwrap(presentation.markerFraction)
        XCTAssertEqual(marker, 0.5 + Double(needed) / 32_000_000_000, accuracy: 1e-9)
    }

    func testMarkerClampsToTheEndOfTheBar() throws {
        let model = makeModel(bytes: 100_000_000_000, parameters: "7B")
        let presentation = budget(total: 32_000_000_000, available: 20_000_000_000, reserveGB: 4, model: model)
        let marker = try XCTUnwrap(presentation.markerFraction)
        XCTAssertEqual(marker, 1, accuracy: 1e-9)
    }

    func testFitsVerdictUsesConfiguredReserveAndContext() {
        let model = makeModel(bytes: 4_000_000_000, parameters: "7B")
        let presentation = budget(total: 32_000_000_000, available: 20_000_000_000, reserveGB: 4, model: model)
        let expected = ComparisonInsights.fitEstimate(model: model, hardware: hardware, memory: memory(32_000_000_000, 20_000_000_000), contextTokens: 8192, reserveGB: 4)
        XCTAssertEqual(presentation.fit, .estimated(expected))
        XCTAssertEqual(presentation.tone, .fits)
        XCTAssertTrue(presentation.verdictText.hasPrefix("Fits with "), presentation.verdictText)
        XCTAssertTrue(presentation.verdictText.hasSuffix(" GB to spare"), presentation.verdictText)
    }

    func testTightVerdict() {
        let model = makeModel(bytes: 11_000_000_000, parameters: "7B")
        let presentation = budget(total: 32_000_000_000, available: 20_000_000_000, reserveGB: 4, model: model)
        XCTAssertEqual(presentation.tone, .tight)
        XCTAssertTrue(presentation.verdictText.hasPrefix("Tight"), presentation.verdictText)
    }

    func testWontFitVerdictNamesTheShortfallAndSuggestedContext() {
        let model = makeModel(bytes: 2_000_000_000, parameters: "70B")
        let presentation = budget(total: 32_000_000_000, available: 20_000_000_000, reserveGB: 4, context: 16384, model: model)
        XCTAssertEqual(presentation.tone, .wontFit)
        XCTAssertTrue(presentation.verdictText.contains("short"), presentation.verdictText)
        XCTAssertTrue(presentation.verdictText.hasSuffix("; 4K tokens would fit"), presentation.verdictText)
    }

    func testReserveFromConfigChangesTheVerdict() {
        let model = makeModel(bytes: 11_000_000_000, parameters: "7B")
        let small = budget(total: 32_000_000_000, available: 20_000_000_000, reserveGB: 1, model: model)
        let large = budget(total: 32_000_000_000, available: 20_000_000_000, reserveGB: 8, model: model)
        XCTAssertEqual(small.tone, .fits)
        XCTAssertEqual(large.tone, .wontFit)
    }

    func testModelWithoutSizeIsNotEstimatedAndHasNoMarker() {
        let model = makeModel(bytes: 0, parameters: "7B")
        let presentation = budget(total: 32_000_000_000, available: 20_000_000_000, reserveGB: 4, model: model)
        XCTAssertEqual(presentation.fit, .notEstimated("Fit not estimated: model size unavailable"))
        XCTAssertNil(presentation.markerFraction)
        XCTAssertEqual(presentation.tone, .neutral)
    }

    func testNonServableModelIsNotEstimatedAndHasNoMarker() {
        let model = makeModel(bytes: 4_000_000_000, parameters: nil, type: .imageGeneration)
        let presentation = budget(total: 32_000_000_000, available: 20_000_000_000, reserveGB: 4, model: model)
        XCTAssertEqual(presentation.verdictText, "Fit not estimated for image generation models")
        XCTAssertNil(presentation.markerFraction)
    }

    func testNoSelectedModelShowsASentenceAndNoMarker() {
        let presentation = budget(total: 32_000_000_000, available: 20_000_000_000, reserveGB: 4)
        XCTAssertEqual(presentation.fit, .noModel)
        XCTAssertNil(presentation.markerFraction)
        XCTAssertEqual(presentation.verdictText, "Select a model in Library to check fit.")
    }

    func testUnavailableMemoryNeverReadsAsZero() {
        let model = makeModel(bytes: 4_000_000_000, parameters: "7B")
        let presentation = ModelBudgetPresentation(memory: nil, reserveGB: 4, contextTokens: 8192, model: model, hardware: hardware)
        XCTAssertNil(presentation.leadText)
        XCTAssertNil(presentation.segments)
        XCTAssertNil(presentation.markerFraction)
        XCTAssertEqual(presentation.unavailableText, "Memory reading unavailable")
        XCTAssertEqual(presentation.fit, .notEstimated("Fit not estimated: live memory unavailable"))
        XCTAssertFalse(presentation.accessibilityLabel.contains("0 GB"), presentation.accessibilityLabel)
        XCTAssertTrue(presentation.accessibilityLabel.contains("unavailable"))
    }

    func testAccessibilityLabelIsOneSentenceWithEveryFact() {
        let model = makeModel(bytes: 4_000_000_000, parameters: "7B")
        let label = budget(total: 32_000_000_000, available: 20_000_000_000, reserveGB: 4, model: model).accessibilityLabel
        for fact in ["16.0 GB", "20.0 GB available", "32.0 GB unified memory", "4 GB reserve", "8K-token context", "fits with"] {
            XCTAssertTrue(label.contains(fact), "\(fact) missing from: \(label)")
        }
        XCTAssertTrue(label.hasSuffix("."), label)
        XCTAssertEqual(label.components(separatedBy: ". ").count, 1, "exactly one sentence: \(label)")
        let withoutDecimals = label.replacingOccurrences(of: #"(?<=\d)\.(?=\d)"#, with: "", options: .regularExpression)
        XCTAssertEqual(withoutDecimals.filter { $0 == "." }.count, 1, "one period: \(label)")
    }

    func testReadingBranchesLoadingUnavailableLive() {
        let loading = ModelBudgetPresentation(memory: nil, reserveGB: 4, contextTokens: 8192, model: nil, hardware: hardware, hasProbed: false)
        XCTAssertEqual(loading.reading, .loading)
        XCTAssertNil(loading.leadText)
        let unavailable = ModelBudgetPresentation(memory: nil, reserveGB: 4, contextTokens: 8192, model: nil, hardware: hardware, hasProbed: true)
        XCTAssertEqual(unavailable.reading, .unavailable)
        let live = budget(total: 32_000_000_000, available: 20_000_000_000, reserveGB: 4)
        XCTAssertEqual(live.reading, .live)
        let liveBeforeFlag = ModelBudgetPresentation(memory: memory(32_000_000_000, 20_000_000_000), reserveGB: 4, contextTokens: 8192, model: nil, hardware: hardware, hasProbed: false)
        XCTAssertEqual(liveBeforeFlag.reading, .live)
        XCTAssertEqual(ModelBudgetPresentation.placeholderLabels.count, 3)
    }

    func testNeutralVerdictAndNoModelUseDistinctSymbols() {
        XCTAssertEqual(budget(total: 32_000_000_000, available: 20_000_000_000, reserveGB: 4).verdictSymbol, "questionmark.circle")
    }

    func testSegmentLabelsAnchorAtEachSegmentsLeadingEdge() throws {
        let presentation = budget(total: 32_000_000_000, available: 20_000_000_000, reserveGB: 4)
        let labels = presentation.segmentLabels
        XCTAssertEqual(labels.map(\.leadingFraction), [0, 0.375, 0.5])
        XCTAssertEqual(labels.map(\.text), ["In use 12.0 GB", "Reserve 4 GB", "Budget 16.0 GB"])
        let unavailable = ModelBudgetPresentation(memory: nil, reserveGB: 4, contextTokens: 8192, model: nil, hardware: hardware)
        XCTAssertTrue(unavailable.segmentLabels.isEmpty)
    }

    func testLabelOriginsKeepLeadingEdgesButNeverOverlapOrOverflow() {
        let spread = SegmentLabelsLayout.origins(desired: [0, 100, 200], widths: [50, 50, 50], total: 400, gap: 10)
        XCTAssertEqual(spread, [0, 100, 200])
        let crowded = SegmentLabelsLayout.origins(desired: [0, 100, 110], widths: [50, 80, 70], total: 400, gap: 10)
        XCTAssertEqual(crowded, [0, 100, 190])
        let edge = SegmentLabelsLayout.origins(desired: [0, 100, 395], widths: [50, 50, 70], total: 400, gap: 10)
        XCTAssertEqual(edge, [0, 100, 330])
    }

    func testTokenText() {
        XCTAssertEqual(ModelBudgetPresentation.tokens(8192), "8K")
        XCTAssertEqual(ModelBudgetPresentation.tokens(2048), "2K")
        XCTAssertEqual(ModelBudgetPresentation.tokens(1000), "1000")
    }

    // MARK: - Next step button

    func testButtonTitleMatchesWhatPerformDoesOnEveryBranch() {
        XCTAssertEqual(derive(rootsConfigured: false).buttonTitle, "Open Settings")
        XCTAssertEqual(derive(agentReady: false).buttonTitle, "Open Settings")
        XCTAssertEqual(derive().buttonTitle, "Open Library", "scan branch only navigates")
        XCTAssertEqual(derive(lastError: "scan failed").buttonTitle, "Open Library")
        XCTAssertEqual(derive(workflow: workflow(state: .running)).buttonTitle, "Open Activity")

        let source = makeModel(bytes: 1000, parameters: nil, readiness: .needsConversion, path: "/models/source.gguf")
        XCTAssertEqual(derive(snapshot: snapshot(with: [source])).buttonTitle, "Prepare")

        let ready = makeModel(bytes: 1000, parameters: nil, readiness: .ready, path: "/models/atlas-mlx")
        let run = derive(workflow: workflow(state: .completed, completedModelPath: ready.item.path), snapshot: snapshot(with: [ready]))
        XCTAssertEqual(run.buttonTitle, "Run")

        XCTAssertEqual(derive(snapshot: snapshot(with: [])).buttonTitle, "Open Library")

        let reclaim = derive(snapshot: snapshot(with: []), reclaimableBytes: ReclaimAdvisor.badgeThresholdBytes, diskFreeFraction: 0.05)
        XCTAssertEqual(reclaim.route, AppRoute.reclaim.rawValue)
        XCTAssertEqual(reclaim.buttonTitle, "Open Reclaim")
    }

    // MARK: - Layout

    func testLayoutThresholds() {
        XCTAssertEqual(OverviewLayoutMode(contentWidth: 512), .compact)
        XCTAssertEqual(OverviewLayoutMode(contentWidth: 615), .compact)
        XCTAssertEqual(OverviewLayoutMode(contentWidth: 616), .regular)
        XCTAssertEqual(OverviewLayoutMode(contentWidth: 1039), .regular)
        XCTAssertEqual(OverviewLayoutMode(contentWidth: 1040), .wide)
        XCTAssertFalse(OverviewLayoutMode.compact.heroIsSideBySide)
        XCTAssertTrue(OverviewLayoutMode.regular.heroIsSideBySide)
        XCTAssertFalse(OverviewLayoutMode.regular.usesTwoColumnLowerRow)
        XCTAssertTrue(OverviewLayoutMode.wide.usesTwoColumnLowerRow)
    }

    func testCollapseOrderThresholds() {
        XCTAssertFalse(OverviewLayoutMode.showsTileCaptions(contentWidth: 593))
        XCTAssertTrue(OverviewLayoutMode.showsTileCaptions(contentWidth: 594))
        XCTAssertFalse(OverviewLayoutMode.showsStageState(contentWidth: 599))
        XCTAssertTrue(OverviewLayoutMode.showsStageState(contentWidth: 600))
        XCTAssertFalse(OverviewLayoutMode.showsBarLabels(instrumentWidth: 459))
        XCTAssertTrue(OverviewLayoutMode.showsBarLabels(instrumentWidth: 460))
        XCTAssertTrue(OverviewLayoutMode.foldsAlertActions(rowWidth: 559))
        XCTAssertFalse(OverviewLayoutMode.foldsAlertActions(rowWidth: 560))
    }

    func testMinimumWindowKeepsTheHeroRowStackedNotTruncated() {
        let sidebar: CGFloat = 180
        let gutters = WorkbenchSpacing.pageInset * 2
        let minimumContent = WorkbenchSize.windowMinimumWidth - sidebar - gutters
        XCTAssertEqual(OverviewLayoutMode(contentWidth: minimumContent), .compact)
        XCTAssertGreaterThanOrEqual(minimumContent, WorkbenchSize.instrumentMinimum)
        XCTAssertEqual(WorkbenchSize.instrumentMinimum + WorkbenchSize.nextStepMinimum + WorkbenchSpacing.md, WorkbenchSize.heroRowMinimum)
    }

    // MARK: - Flight path

    func testStageStateToneMappingIsPinned() {
        XCTAssertEqual(ModelFlightStageState.pending.tone, .neutral)
        XCTAssertEqual(ModelFlightStageState.active.tone, .accent)
        XCTAssertEqual(ModelFlightStageState.complete.tone, .accent)
        XCTAssertEqual(ModelFlightStageState.attention.tone, .warning)
        XCTAssertEqual(ModelFlightStageState.failed.tone, .failure)
        XCTAssertEqual(ModelFlightStageState.active.label, "In progress")
    }

    func testVerificationInProgressIsTheActiveStage() {
        let model = makeModel(bytes: 1000, parameters: nil, readiness: .ready, path: "/models/flight")
        let presentation = ModelFlightPathPresentation.derive(model: model, verification: .inProgress, completedRuns: [], endpointState: .disabled, servers: [])
        XCTAssertEqual(presentation.stages.first(where: { $0.stage == .verified })?.state, .active)
        XCTAssertEqual(presentation.stages.first(where: { $0.stage == .measured })?.state, .pending)
    }

    func testTrackFillsUpToTheLastCompleteStage() {
        let model = makeModel(bytes: 1000, parameters: nil, readiness: .ready, path: "/models/flight")
        let presentation = ModelFlightPathPresentation.derive(model: model, verification: .unverified, completedRuns: [], endpointState: .disabled, servers: [])
        XCTAssertEqual(presentation.lastCompleteIndex, 1)
        let none = ModelFlightPathPresentation.derive(model: nil, verification: .unverified, completedRuns: [], endpointState: .disabled, servers: [])
        XCTAssertNil(none.lastCompleteIndex)
    }

    // MARK: - Library strip

    func testStripWithoutSnapshotIsDesignedNotZero() {
        let strip = LibraryStripPresentation(snapshot: nil, rootCount: 0, reclaimableBytes: 0, runs: [], now: stamp)
        XCTAssertEqual(strip.tiles.map(\.name), ["Models", "On disk", "Comparisons"])
        XCTAssertEqual(strip.tiles[0].value, "None")
        XCTAssertEqual(strip.tiles[0].caption, "No scan yet")
        XCTAssertEqual(strip.tiles[1].caption, "Nothing to reclaim")
        XCTAssertEqual(strip.tiles[2].value, "0")
        XCTAssertEqual(strip.tiles[2].caption, "None yet")
    }

    func testStripCountsModelsRootsDiskAndCompletedRuns() {
        let model = makeModel(bytes: 1000, parameters: nil)
        let snap = snapshot(with: [model])
        let finished = stamp.addingTimeInterval(-3600)
        let completed = ComparisonRun(id: UUID(), promptSetID: "s", promptSetName: "S", useCase: nil, variants: [], results: [], startedAt: finished, finishedAt: finished, state: .completed)
        let running = ComparisonRun(id: UUID(), promptSetID: "s", promptSetName: "S", useCase: nil, variants: [], results: [], startedAt: stamp, finishedAt: nil, state: .running)
        let strip = LibraryStripPresentation(snapshot: snap, rootCount: 2, reclaimableBytes: 1_500_000_000, runs: [completed, running], now: stamp)
        XCTAssertEqual(strip.tiles[0].value, "1")
        XCTAssertEqual(strip.tiles[0].caption, "in 2 roots")
        XCTAssertEqual(strip.tiles[1].value, ModelBudgetPresentation.gb(snap.totalBytes) + " GB")
        XCTAssertEqual(strip.tiles[1].caption, "1.5 GB reclaimable")
        XCTAssertEqual(strip.tiles[2].value, "1")
        XCTAssertTrue(strip.tiles[2].caption.hasPrefix("Last "), strip.tiles[2].caption)
        let single = LibraryStripPresentation(snapshot: snap, rootCount: 1, reclaimableBytes: 0, runs: [], now: stamp)
        XCTAssertEqual(single.tiles[0].caption, "in 1 root")
    }

    // MARK: - Helpers

    private func memory(_ total: Int64, _ available: Int64) -> MemorySnapshot {
        MemorySnapshot(totalBytes: total, availableBytes: available)
    }

    private func budget(total: Int64, available: Int64, reserveGB: Double, context: Int = 8192, model: LibraryModel? = nil) -> ModelBudgetPresentation {
        ModelBudgetPresentation(memory: memory(total, available), reserveGB: reserveGB, contextTokens: context, model: model, hardware: hardware)
    }

    private func makeModel(bytes: Int64, parameters: String?, type: ModelTaskType? = nil, readiness: ModelReadiness = .ready, path: String = "/models/atlas-mlx") -> LibraryModel {
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: bytes,
            modifiedAt: nil, shard: nil,
            modelKey: "model", architecture: nil, quantization: "Q4_K_M", parameters: parameters,
            structure: nil, signature: nil, companion: nil, readable: true,
            status: readiness == .ready ? "ready" : "needs_conversion",
            outputs: [], tensorCount: nil, error: nil,
            task: type.map { ModelTask(type: $0, useCases: [], source: "registry", confidence: "confirmed") }
        )
        return LibraryModel(item: item, readiness: readiness)
    }

    private func snapshot(with models: [LibraryModel]) -> LibrarySnapshot {
        LibrarySnapshot(models: models, groups: [], hardware: hardware, generatedAt: stamp)
    }

    private func derive(
        workflow: ConversionWorkflow? = nil,
        snapshot: LibrarySnapshot? = nil,
        rootsConfigured: Bool = true,
        lastError: String? = nil,
        agentReady: Bool = true,
        reclaimableBytes: Int64 = 0,
        diskFreeFraction: Double? = nil
    ) -> HomeNextAction {
        HomeNextAction.derive(
            workflow: workflow ?? self.workflow(state: .idle),
            snapshot: snapshot,
            rootsConfigured: rootsConfigured,
            isScanning: false,
            lastError: lastError,
            agentReady: agentReady,
            convertRuntimeReady: true,
            serveRuntimeReady: true,
            reclaimableBytes: reclaimableBytes,
            diskFreeFraction: diskFreeFraction
        )
    }

    private func workflow(state: ConversionWorkflowState, completedModelPath: String? = nil) -> ConversionWorkflow {
        ConversionWorkflow(
            id: UUID(),
            sourcePath: "/models/source.gguf",
            sourceModelKey: nil,
            sourceSignature: nil,
            outputPath: "/models/out",
            previewHash: nil,
            jobReceipt: nil,
            completedModelPath: completedModelPath,
            state: state,
            serveState: .idle,
            message: nil,
            errorMessage: nil,
            createdAt: stamp,
            updatedAt: stamp,
            lastKnownAgentState: nil
        )
    }
}
