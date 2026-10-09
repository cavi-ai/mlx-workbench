import Foundation
import XCTest

@testable import mlx_workbench

/// Pure presentation behind the remodeled Prepare route: quantization tiles,
/// the fit verdict, the lock, the pipeline track, the action matrix, the
/// subtitle and the toolbar badge.
final class PrepareRemodelTests: XCTestCase {
    private let stamp = Date(timeIntervalSinceReferenceDate: 1_000_000_000)
    private let hardware = HardwareProfile(chip: "M5", model: nil, memoryBytes: 32_000_000_000, macOSVersion: nil)
    private let allStates: [ConversionWorkflowState] = [
        .idle, .inspectingSource, .existingModelFound, .previewingConversion, .readyToConfirm, .queued,
        .running, .completed, .verifying, .verified, .verificationFailed, .failed,
    ]

    // MARK: - Size per state

    func testRepoTilesCarryTheIntakeEstimatePerWidth() {
        let presentation = PrepareWorkflowPresentation(workflow: workflow(
            sourcePath: "hf://org/thing", outputPath: "/models/mlx/thing-MLX-4bit", state: .inspectingSource,
            sourceRepo: "org/thing", estimates: ["4": 400, "8": 800]
        ))
        let tiles = presentation.tiles(actualBytes: nil)
        XCTAssertEqual(tiles.map(\.bits), [4, 8])
        XCTAssertEqual(tiles.map(\.size), [.estimated(400), .estimated(800)])
        XCTAssertTrue(tiles[0].size.text.hasPrefix("~"))
    }

    func testGGUFTilesHaveNoSize() {
        let presentation = PrepareWorkflowPresentation(workflow: workflow(state: .inspectingSource))
        XCTAssertEqual(presentation.tiles(actualBytes: nil).map(\.size), [.unknown, .unknown])
        XCTAssertEqual(PrepareTile.Size.unknown.text, "Size unknown")
    }

    func testVerifiedOutputShowsActualBytesOnlyOnTheConvertedWidth() {
        let presentation = PrepareWorkflowPresentation(workflow: workflow(
            sourcePath: "hf://org/thing", outputPath: "/models/mlx/thing-MLX-4bit", state: .verified,
            sourceRepo: "org/thing", estimates: ["4": 400, "8": 800]
        ))
        let tiles = presentation.tiles(actualBytes: 390)
        XCTAssertEqual(tiles[0].size, .actual(390), "actual replaces the estimate on the converted width")
        XCTAssertEqual(tiles[1].size, .estimated(800), "other widths keep their estimate")
        XCTAssertTrue(tiles[0].size.text.hasSuffix("actual"))
    }

    func testActualBytesNeedAKnownConvertedWidth() {
        let presentation = PrepareWorkflowPresentation(workflow: workflow(state: .verified))
        XCTAssertNil(presentation.destinationBits)
        XCTAssertEqual(presentation.tiles(actualBytes: 390).map(\.size), [.unknown, .unknown])
    }

    func testRestoredRecordWithoutEstimatesIsUnknown() {
        let presentation = PrepareWorkflowPresentation(workflow: workflow(
            sourcePath: "hf://org/thing", outputPath: "/models/mlx/thing-MLX-8bit", state: .readyToConfirm,
            sourceRepo: "org/thing", estimates: nil
        ))
        XCTAssertEqual(presentation.tiles(actualBytes: nil).map(\.size), [.unknown, .unknown])
    }

    func testEstimateIsGeneralizedPerWidthAndKeepsTheDestinationOutput() {
        let record = workflow(outputPath: "/models/mlx/thing-MLX-8bit", estimates: ["4": 400, "8": 800])
        XCTAssertEqual(ConversionProgressSnapshot.estimate(for: record), 800)
        XCTAssertEqual(ConversionProgressSnapshot.estimate(for: record, bits: 4), 400)
        XCTAssertNil(ConversionProgressSnapshot.estimate(for: record, bits: 6))
        XCTAssertNil(ConversionProgressSnapshot.estimate(for: workflow(estimates: ["4": 400])))
    }

    func testActualBytesComeFromTheLibraryOutputOnlyOnceConverted() {
        let output = model(bytes: 390, parameters: "7B", type: .textLLM, path: "/models/mlx/thing-MLX-4bit")
        let snapshot = LibrarySnapshot(models: [output], groups: [], hardware: hardware, generatedAt: stamp)
        var record = workflow(outputPath: "/models/mlx/thing-MLX-4bit", state: .verified)
        record.completedModelPathOverride("/models/mlx/thing-MLX-4bit")
        let done = PrepareWorkflowPresentation(workflow: record)
        XCTAssertEqual(done.actualBytes(outputModel: done.outputModel(in: snapshot)), 390)
        let running = PrepareWorkflowPresentation(workflow: workflow(outputPath: "/models/mlx/thing-MLX-4bit", state: .running))
        XCTAssertNil(running.actualBytes(outputModel: running.outputModel(in: snapshot)))
    }

    // MARK: - Fit verdict

    func testTileVerdictMatchesTheLibraryVerdictForTheSameInputs() {
        let memory = MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: 20_000_000_000)
        for bytes in [Int64(4_000_000_000), 11_000_000_000, 40_000_000_000] {
            let library = LibraryFitPresentation.make(
                model: model(bytes: bytes, parameters: "7B", type: .textLLM), memory: memory,
                hasProbed: true, contextTokens: 8192, reserveGB: 4, hardware: hardware
            )
            let tile = tileFit(.estimated(bytes), parameters: "7B", task: .textLLM, memory: memory)
            XCTAssertEqual(tile.state, .estimated)
            XCTAssertEqual(tile.word, library.word)
            XCTAssertEqual(tile.tone, library.tone)
        }
    }

    func testBytesEntryPointMatchesTheModelEntryPoint() {
        let memory = MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: 20_000_000_000)
        let item = model(bytes: 11_000_000_000, parameters: "7B", type: .textLLM)
        let byModel = ModelBudgetPresentation(memory: memory, reserveGB: 4, contextTokens: 8192, model: item, hardware: hardware)
        let bySubject = ModelBudgetPresentation(
            memory: memory, reserveGB: 4, contextTokens: 8192,
            subject: .init(bytes: 11_000_000_000, parameters: "7B", task: .textLLM), hardware: hardware
        )
        XCTAssertEqual(byModel, bySubject)
    }

    func testNonServableTaskIsNotEstimatedWithTheSharedSentence() {
        let memory = MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: 20_000_000_000)
        let fit = tileFit(.actual(4_000_000_000), parameters: nil, task: .imageGeneration, memory: memory)
        XCTAssertEqual(fit.state, .notEstimated)
        XCTAssertEqual(fit.help, "Fit not estimated for image generation models")
        XCTAssertEqual(fit.word, "Fit not estimated for image generation models", "the tile names what the product judges")
    }

    func testFinishedConversionKeepsItsMessageOutOfTheVisibleStatus() {
        for state in [ConversionWorkflowState.verified, .completed] {
            XCTAssertTrue(PrepareWorkflowPresentation(workflow: makeFinishedWorkflow(state: state)).isFinished)
        }
        for state in [ConversionWorkflowState.running, .failed, .readyToConfirm, .verificationFailed] {
            XCTAssertFalse(PrepareWorkflowPresentation(workflow: makeFinishedWorkflow(state: state)).isFinished)
        }
    }

    private func makeFinishedWorkflow(state: ConversionWorkflowState) -> ConversionWorkflow {
        ConversionWorkflow(
            id: UUID(), sourcePath: "/m/source.gguf", sourceModelKey: nil, sourceSignature: nil,
            outputPath: "/m/out", previewHash: nil, jobReceipt: nil, completedModelPath: nil,
            state: state, serveState: .idle, message: "Verification passed.", errorMessage: nil,
            createdAt: Date(), updatedAt: Date(), lastKnownAgentState: nil
        )
    }

    func testUnlabelledSourceWithoutALibraryModelGetsNoVerdict() {
        let memory = MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: 20_000_000_000)
        let fit = tileFit(.estimated(4_000_000_000), parameters: nil, task: nil, taskIsLabelled: false, memory: memory)
        XCTAssertEqual(fit.state, .notEstimated)
        XCTAssertEqual(fit.help, "Fit not estimated for these models")
    }

    func testUnknownSizeIsNotEstimated() {
        let memory = MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: 20_000_000_000)
        let fit = tileFit(.unknown, parameters: "7B", task: .textLLM, memory: memory)
        XCTAssertEqual(fit.state, .notEstimated)
        XCTAssertEqual(fit.help, "Fit not estimated: model size unavailable")
    }

    func testMemoryUnavailableAfterProbeHasNoFallbackVerdict() {
        let fit = tileFit(.estimated(4_000_000_000), parameters: "7B", task: .textLLM, memory: nil, hasProbed: true)
        XCTAssertEqual(fit.state, .unavailable)
        XCTAssertEqual(fit.word, "Memory reading unavailable")
        XCTAssertEqual(fit.tone, .neutral)
    }

    func testBeforeTheFirstProbeTheVerdictIsAPlaceholder() {
        let fit = tileFit(.estimated(4_000_000_000), parameters: "7B", task: .textLLM, memory: nil, hasProbed: false)
        XCTAssertEqual(fit.state, .redacted)
        XCTAssertEqual(fit.tone, .neutral)
    }

    func testUnknownParametersSayTheKVFigureIsTheDefaultAssumption() {
        let memory = MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: 20_000_000_000)
        let unknown = tileFit(.estimated(4_000_000_000), parameters: nil, task: .textLLM, memory: memory)
        XCTAssertTrue(unknown.help.contains("default 8B-class assumption"), unknown.help)
        let known = tileFit(.estimated(4_000_000_000), parameters: "7B", task: .textLLM, memory: memory)
        XCTAssertFalse(known.help.contains("default 8B-class assumption"), known.help)
    }

    func testTileVerdictIsOneWordWithTheLibraryVocabulary() {
        let memory = MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: 20_000_000_000)
        XCTAssertEqual(tileFit(.estimated(4_000_000_000), parameters: "7B", task: .textLLM, memory: memory).word, "Fits")
        XCTAssertEqual(tileFit(.estimated(11_000_000_000), parameters: "7B", task: .textLLM, memory: memory).word, "Tight")
        XCTAssertEqual(tileFit(.estimated(40_000_000_000), parameters: "7B", task: .textLLM, memory: memory).word, "Won't fit")
    }

    // MARK: - Lock

    func testLockedTilesHighlightTheWidthTheDestinationNames() {
        let presentation = PrepareWorkflowPresentation(workflow: workflow(
            outputPath: "/models/mlx/thing-MLX-4bit", previewHash: "hash", state: .readyToConfirm
        ))
        XCTAssertTrue(presentation.isQuantizationLocked)
        XCTAssertEqual(presentation.highlightedBits(selected: 8), 4, "the configured width is never presented as the converted one")
    }

    func testLockedWithAnUnknownWidthHighlightsNothing() {
        let presentation = PrepareWorkflowPresentation(workflow: workflow(
            outputPath: "/models/atlas-mlx", previewHash: "hash", state: .completed
        ))
        XCTAssertNil(presentation.destinationBits)
        XCTAssertNil(presentation.highlightedBits(selected: 4))
    }

    func testUnlockedTilesHighlightTheSelection() {
        let presentation = PrepareWorkflowPresentation(workflow: workflow(state: .inspectingSource))
        XCTAssertFalse(presentation.isQuantizationLocked)
        XCTAssertEqual(presentation.highlightedBits(selected: 8), 8)
    }

    // MARK: - Pipeline track

    func testStageMappingCoversAllTwelveStates() {
        typealias S = ModelFlightStageState
        let expected: [ConversionWorkflowState: [S]] = [
            .idle: [.pending, .pending, .pending, .pending, .pending],
            .inspectingSource: [.active, .pending, .pending, .pending, .pending],
            .existingModelFound: [.complete, .pending, .pending, .pending, .pending],
            .previewingConversion: [.complete, .active, .pending, .pending, .pending],
            .readyToConfirm: [.complete, .complete, .pending, .pending, .pending],
            .queued: [.complete, .complete, .active, .pending, .pending],
            .running: [.complete, .complete, .active, .pending, .pending],
            .completed: [.complete, .complete, .complete, .pending, .pending],
            .verifying: [.complete, .complete, .complete, .active, .pending],
            .verified: [.complete, .complete, .complete, .complete, .complete],
            .verificationFailed: [.complete, .complete, .complete, .failed, .pending],
            .failed: [.failed, .pending, .pending, .pending, .pending],
        ]
        XCTAssertEqual(Set(expected.keys), Set(allStates))
        for state in allStates {
            let presentation = PrepareWorkflowPresentation(workflow: workflow(state: state))
            XCTAssertEqual(presentation.stageStates(hasVerificationEvidence: false), expected[state], "\(state)")
        }
    }

    func testFailedStageComesOnlyFromPersistedFields() {
        let source = PrepareWorkflowPresentation(workflow: workflow(state: .failed))
        XCTAssertEqual(source.stageStates(hasVerificationEvidence: false)[0], .failed)
        let preview = PrepareWorkflowPresentation(workflow: workflow(previewHash: "hash", state: .failed))
        XCTAssertEqual(preview.stageStates(hasVerificationEvidence: false), [.complete, .failed, .pending, .pending, .pending])
        let convert = PrepareWorkflowPresentation(workflow: workflow(previewHash: "hash", jobReceipt: "job-1", state: .failed))
        XCTAssertEqual(convert.stageStates(hasVerificationEvidence: false), [.complete, .complete, .failed, .pending, .pending])
    }

    func testVerifyCompletesOnlyWithEvidence() {
        let completed = PrepareWorkflowPresentation(workflow: workflow(state: .completed))
        XCTAssertEqual(completed.stageStates(hasVerificationEvidence: false)[3], .pending)
        XCTAssertEqual(completed.stageStates(hasVerificationEvidence: false)[4], .pending)
        XCTAssertEqual(completed.stageStates(hasVerificationEvidence: true), Array(repeating: .complete, count: 5))

        XCTAssertFalse(PrepareWorkflowPresentation.hasVerificationEvidence(state: .completed, status: nil))
        XCTAssertFalse(PrepareWorkflowPresentation.hasVerificationEvidence(state: .completed, status: .unverified))
        XCTAssertFalse(PrepareWorkflowPresentation.hasVerificationEvidence(state: .completed, status: .inProgress))
        XCTAssertTrue(PrepareWorkflowPresentation.hasVerificationEvidence(state: .verified, status: nil))
        XCTAssertTrue(PrepareWorkflowPresentation.hasVerificationEvidence(state: .completed, status: .verified(report(passed: true))))
        XCTAssertFalse(PrepareWorkflowPresentation.hasVerificationEvidence(state: .completed, status: .failed(report(passed: false))))
    }

    func testOnlyInFlightStatesPulse() {
        for state in allStates {
            let presentation = PrepareWorkflowPresentation(workflow: workflow(state: state))
            let pulses = presentation.stageNodes(hasVerificationEvidence: false).filter(\.pulses)
            let inFlight: Set<ConversionWorkflowState> = [.previewingConversion, .queued, .running, .verifying]
            XCTAssertEqual(presentation.pulsesActiveStage, inFlight.contains(state), "\(state)")
            XCTAssertEqual(pulses.count, inFlight.contains(state) ? 1 : 0, "\(state)")
            XCTAssertTrue(pulses.allSatisfy { $0.state == .active }, "\(state)")
        }
    }

    func testTrackNodesReadStageAndState() {
        let presentation = PrepareWorkflowPresentation(workflow: workflow(state: .running))
        let labels = presentation.stageNodes(hasVerificationEvidence: false).map(FlightTrackView.accessibilityLabel(for:))
        XCTAssertEqual(labels, ["Source: Complete", "Preview: Complete", "Convert: In progress", "Verify: Pending", "Ready: Pending"])
        let overview = FlightTrackNode(id: "prepared", title: "Prepared", symbol: "shippingbox", state: .complete, detail: "Ready.", pulses: false)
        XCTAssertEqual(FlightTrackView.accessibilityLabel(for: overview), "Prepared: Complete. Ready.", "Overview labels are unchanged")
    }

    // MARK: - Actions

    func testNoStateHasMoreThanOneProminentOrADisabledProminent() {
        for state in allStates {
            for hash in [nil, "hash"] as [String?] {
                for submitting in [false, true] {
                    let presentation = PrepareWorkflowPresentation(workflow: workflow(previewHash: hash, state: state))
                    let plan = PrepareActionPlan.make(presentation: presentation, onward: [], existing: nil, isSubmitting: submitting)
                    XCTAssertLessThanOrEqual(plan.prominentCount, 1, "\(state) hash=\(String(describing: hash))")
                    XCTAssertTrue(plan.items.filter(\.isProminent).allSatisfy(\.isEnabled), "\(state)")
                }
            }
        }
    }

    func testActionMatrixPerState() {
        func plan(_ state: ConversionWorkflowState, hash: String? = nil, existing: PrepareExistingModel? = nil, onward: [ActivityWorkflowAction] = [], error: String? = nil, submitting: Bool = false) -> PrepareActionPlan {
            PrepareActionPlan.make(
                presentation: PrepareWorkflowPresentation(workflow: workflow(previewHash: hash, state: state, errorMessage: error)),
                onward: onward, existing: existing, isSubmitting: submitting
            )
        }
        XCTAssertEqual(plan(.inspectingSource).items.first, .init(action: .preview, isProminent: true, isEnabled: true))
        XCTAssertEqual(plan(.inspectingSource).items.last, .init(action: .confirm, isProminent: false, isEnabled: false))
        XCTAssertEqual(plan(.readyToConfirm, hash: "hash").items.first, .init(action: .confirm, isProminent: true, isEnabled: true))
        XCTAssertEqual(plan(.readyToConfirm, hash: "hash").items.last, .init(action: .preview, isProminent: false, isEnabled: true))
        XCTAssertEqual(plan(.readyToConfirm, hash: "hash", submitting: true).prominentCount, 0)
        XCTAssertEqual(plan(.previewingConversion).prominentCount, 0)
        XCTAssertEqual(plan(.failed, error: "Destination already exists and is not an equivalent MLX model.").prominentCount, 0)
        XCTAssertEqual(plan(.existingModelFound, existing: .init(path: "/m", isServable: true)).items, [.init(action: .runExisting, isProminent: true, isEnabled: true)])
        XCTAssertEqual(plan(.existingModelFound, existing: .init(path: "/m", isServable: false)).items, [.init(action: .openExistingInLibrary("/m"), isProminent: true, isEnabled: true)])
        XCTAssertEqual(plan(.existingModelFound).items, [.init(action: .rescan, isProminent: true, isEnabled: true)])
        for state in [ConversionWorkflowState.queued, .running, .verifying] {
            XCTAssertEqual(plan(state).items, [.init(action: .openActivity, isProminent: false, isEnabled: true)], "\(state)")
        }
        XCTAssertTrue(PrepareActionPlan.make(presentation: PrepareWorkflowPresentation(workflow: workflow(sourcePath: "", state: .idle)), onward: [], existing: nil, isSubmitting: false).items.isEmpty)
    }

    func testOnwardActionsComeFromTheActivityCardOwner() {
        let output = model(bytes: 390, parameters: "7B", type: .textLLM, path: "/models/mlx/thing-MLX-4bit")
        let snapshot = LibrarySnapshot(models: [output], groups: [], hardware: hardware, generatedAt: stamp)
        for state in [ConversionWorkflowState.completed, .verified] {
            var record = workflow(outputPath: "/models/mlx/thing-MLX-4bit", state: state)
            record.completedModelPathOverride("/models/mlx/thing-MLX-4bit")
            let owner = ActivityWorkflowCardPresentation(workflow: record, job: nil, snapshot: snapshot).actions
            XCTAssertEqual(owner.count, 2)
            let plan = PrepareActionPlan.make(presentation: PrepareWorkflowPresentation(workflow: record), onward: owner, existing: nil, isSubmitting: false)
            XCTAssertEqual(plan.items.first, .init(action: .onward(.runModel(record)), isProminent: true, isEnabled: true), "\(state)")
            XCTAssertEqual(plan.items.last, .init(action: .onward(.openInLibrary("/models/mlx/thing-MLX-4bit")), isProminent: false, isEnabled: true), "\(state)")
            XCTAssertEqual(plan.prominentCount, 1)
        }
    }

    func testNonServableOutputOffersOpenInLibraryAsTheOnlyProminent() {
        let output = model(bytes: 390, parameters: nil, type: .imageGeneration, path: "/models/mlx/pic-MLX-4bit")
        let snapshot = LibrarySnapshot(models: [output], groups: [], hardware: hardware, generatedAt: stamp)
        var record = workflow(outputPath: "/models/mlx/pic-MLX-4bit", state: .verified)
        record.completedModelPathOverride("/models/mlx/pic-MLX-4bit")
        let owner = ActivityWorkflowCardPresentation(workflow: record, job: nil, snapshot: snapshot).actions
        let plan = PrepareActionPlan.make(presentation: PrepareWorkflowPresentation(workflow: record), onward: owner, existing: nil, isSubmitting: false)
        XCTAssertEqual(plan.items, [.init(action: .onward(.openInLibrary("/models/mlx/pic-MLX-4bit")), isProminent: true, isEnabled: true)])
    }

    func testFinishedConversionNotYetInTheLibraryOffersRescan() {
        let plan = PrepareActionPlan.make(presentation: PrepareWorkflowPresentation(workflow: workflow(state: .verified)), onward: [], existing: nil, isSubmitting: false)
        XCTAssertEqual(plan.items, [.init(action: .rescan, isProminent: true, isEnabled: true)])
    }

    // MARK: - Naming and chrome

    func testHeaderNameIsTheRepoThenTheRestoredRepoThenTheFileName() {
        var repo = workflow(sourcePath: "hf://openai/whisper-tiny", state: .inspectingSource)
        repo.sourceRepo = "openai/whisper-tiny"
        XCTAssertEqual(PrepareWorkflowPresentation(workflow: repo).displayName, "openai/whisper-tiny")

        let restored = PrepareWorkflowPresentation(workflow: workflow(sourcePath: "hf://openai/whisper-tiny", state: .completed))
        XCTAssertEqual(restored.displayName, "openai/whisper-tiny")
        XCTAssertEqual(restored.sourceLabel, "Source repo", "an hf:// path is never labeled GGUF")
        XCTAssertFalse(restored.destinationNote.contains("same-directory"))

        let gguf = PrepareWorkflowPresentation(workflow: workflow(state: .inspectingSource))
        XCTAssertEqual(gguf.displayName, "atlas.gguf")
        XCTAssertEqual(PrepareWorkflowPresentation(workflow: workflow(sourcePath: "", state: .idle)).displayName, "")
    }

    func testPrepareSubtitleNamesTheWorkflowSourceNotTheLibrarySelection() {
        var repo = workflow(sourcePath: "hf://org/thing", state: .inspectingSource)
        repo.sourceRepo = "org/thing"
        let selected = "/models/other-model"
        XCTAssertEqual(ContentView.subtitle(route: .prepare, workflow: repo, selectedModelPath: selected), "org/thing")
        XCTAssertEqual(ContentView.subtitle(route: .prepare, workflow: workflow(sourcePath: "hf://org/thing", state: .completed), selectedModelPath: selected), "org/thing")
        XCTAssertEqual(ContentView.subtitle(route: .prepare, workflow: workflow(state: .inspectingSource), selectedModelPath: selected), "atlas.gguf")
        XCTAssertEqual(ContentView.subtitle(route: .prepare, workflow: workflow(sourcePath: "", state: .idle), selectedModelPath: selected), "")
    }

    func testOtherRoutesKeepTheirSubtitles() {
        let record = workflow(state: .inspectingSource)
        XCTAssertEqual(ContentView.subtitle(route: .compare, workflow: record, selectedModelPath: "/models/other-model"), "")
        XCTAssertEqual(ContentView.subtitle(route: .run, workflow: record, selectedModelPath: nil), "")
        XCTAssertEqual(ContentView.subtitle(route: .overview, workflow: record, selectedModelPath: "/models/other-model"), "")
    }

    func testToolbarBadgeIsSuppressedOnPrepareOnly() {
        XCTAssertFalse(ContentView.showsWorkflowBadge(route: .prepare, state: .verified))
        XCTAssertTrue(ContentView.showsWorkflowBadge(route: .overview, state: .verified))
        XCTAssertTrue(ContentView.showsWorkflowBadge(route: .library, state: .running))
        XCTAssertFalse(ContentView.showsWorkflowBadge(route: .overview, state: .idle))
    }

    // MARK: - Idle

    func testIdleHasNoActionsNoActiveStageAndNoTileVerdict() {
        let idle = PrepareWorkflowPresentation(workflow: workflow(sourcePath: "", outputPath: "", state: .idle))
        XCTAssertTrue(PrepareActionPlan.make(presentation: idle, onward: [], existing: nil, isSubmitting: false).items.isEmpty)
        XCTAssertEqual(idle.stageStates(hasVerificationEvidence: false), Array(repeating: .pending, count: 5))
        let memory = MemorySnapshot(totalBytes: 32_000_000_000, availableBytes: 20_000_000_000)
        for tile in idle.tiles(actualBytes: nil) {
            XCTAssertEqual(tileFit(tile.size, parameters: nil, task: nil, taskIsLabelled: false, memory: memory).state, .notEstimated)
        }
    }

    // MARK: - Helpers

    private func tileFit(
        _ size: PrepareTile.Size, parameters: String?, task: ModelTaskType?, taskIsLabelled: Bool = true,
        memory: MemorySnapshot?, hasProbed: Bool = true
    ) -> PrepareTileFit {
        PrepareTileFit.make(
            size: size, parameters: parameters, task: task, taskIsLabelled: taskIsLabelled, memory: memory,
            hasProbed: hasProbed, contextTokens: 8192, reserveGB: 4, hardware: hardware
        )
    }

    private func report(passed: Bool) -> VerificationReport {
        VerificationReport(
            id: UUID(), modelPath: "/models/atlas-mlx", modelSignature: nil, workflowRecordID: nil,
            suiteVersion: CanarySuite.version, canaries: [], tokensPerSecond: nil, timeToFirstTokenSeconds: nil,
            metricsEstimated: false, startedAt: stamp, finishedAt: stamp, outcome: passed ? .passed : .failed(canaryIDs: ["echo"])
        )
    }

    private func model(bytes: Int64, parameters: String?, type: ModelTaskType?, path: String = "/models/atlas-mlx") -> LibraryModel {
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: bytes,
            modifiedAt: nil, shard: nil,
            modelKey: "model", architecture: nil, quantization: "Q4_K_M", parameters: parameters,
            structure: nil, signature: nil, companion: nil, readable: true,
            status: "ready", outputs: [], tensorCount: nil, error: nil,
            task: type.map { ModelTask(type: $0, useCases: [], source: "registry", confidence: "confirmed") }
        )
        return LibraryModel(item: item, readiness: .ready)
    }

    private func workflow(
        sourcePath: String = "/models/atlas.gguf",
        outputPath: String = "/models/atlas-mlx",
        previewHash: String? = nil,
        jobReceipt: String? = nil,
        state: ConversionWorkflowState = .idle,
        errorMessage: String? = nil,
        sourceRepo: String? = nil,
        estimates: [String: Int64]? = nil
    ) -> ConversionWorkflow {
        let timestamp = Date(timeIntervalSince1970: 1_726_500_000)
        var record = ConversionWorkflow(
            id: UUID(), sourcePath: sourcePath, sourceModelKey: "atlas", sourceSignature: "signature",
            outputPath: outputPath, previewHash: previewHash, jobReceipt: jobReceipt, completedModelPath: nil,
            state: state, serveState: .idle, message: nil, errorMessage: errorMessage,
            createdAt: timestamp, updatedAt: timestamp, lastKnownAgentState: nil
        )
        record.sourceRepo = sourceRepo
        record.estimatedOutputBytes = estimates
        return record
    }
}

private extension ConversionWorkflow {
    /// `completedModelPath` is a `let`; rebuild the record with it set.
    mutating func completedModelPathOverride(_ path: String) {
        var rebuilt = ConversionWorkflow(
            id: id, sourcePath: sourcePath, sourceModelKey: sourceModelKey, sourceSignature: sourceSignature,
            outputPath: outputPath, previewHash: previewHash, jobReceipt: jobReceipt, completedModelPath: path,
            state: state, serveState: serveState, message: message, errorMessage: errorMessage,
            createdAt: createdAt, updatedAt: updatedAt, lastKnownAgentState: lastKnownAgentState
        )
        rebuilt.sourceRepo = sourceRepo
        rebuilt.backend = backend
        rebuilt.estimatedOutputBytes = estimatedOutputBytes
        rebuilt.modelType = modelType
        rebuilt.subfolder = subfolder
        rebuilt.localSourcePath = localSourcePath
        rebuilt.reclaimSourceAfterVerification = reclaimSourceAfterVerification
        rebuilt.allowedBits = allowedBits
        self = rebuilt
    }
}
