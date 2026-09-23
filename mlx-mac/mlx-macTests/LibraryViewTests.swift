import Foundation
import XCTest

@testable import mlx_workbench

final class LibraryViewTests: XCTestCase {
    func testSummaryDescribesTheSnapshot() {
        let summary = LibraryPresentation.summary(for: makeSnapshot())

        XCTAssertEqual(summary.families, 3)
        XCTAssertEqual(summary.models, 3)
        XCTAssertEqual(summary.storage, ByteCountFormatter.string(fromByteCount: 3_072, countStyle: .file))
        XCTAssertEqual(summary.reclaimable, ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
        XCTAssertFalse(summary.scanned.isEmpty)
    }

    func testTableRowsFlattenSingleVariantFamiliesAndNestMultiVariantFamilies() {
        let groups = LibraryPresentation.filteredGroups(in: makeMultiVariantSnapshot(), search: "", readiness: nil, quantization: nil)
        let rows = LibraryTablePresentation.rows(groups: groups, sortOrder: [])

        XCTAssertEqual(rows.map(\.name), ["Assistant", "Bravo"])
        XCTAssertTrue(rows[0].id.hasPrefix(LibraryRow.familyIDPrefix))
        XCTAssertNil(rows[0].modelPath)
        XCTAssertNil(rows[0].readiness)
        XCTAssertEqual(rows[0].detail, "2 variants")
        XCTAssertEqual(rows[0].bytes, 5_120)
        XCTAssertEqual(rows[0].children?.map(\.modelPath), ["/models/assistant-ready.gguf", "/models/assistant-runtime.gguf"])
        XCTAssertNil(rows[1].children)
        XCTAssertEqual(rows[1].id, "/vault/bravo-ready.gguf")
        XCTAssertEqual(rows[1].readiness, .ready)
        XCTAssertEqual(rows[1].detail, "/vault")
    }

    func testTableRowsSortAtEveryLevel() {
        let groups = LibraryPresentation.filteredGroups(in: makeMultiVariantSnapshot(), search: "", readiness: nil, quantization: nil)
        let bySizeDescending = LibraryTablePresentation.rows(
            groups: groups,
            sortOrder: [KeyPathComparator(\LibraryRow.bytes, order: .reverse)]
        )

        XCTAssertEqual(bySizeDescending.map(\.bytes), [5_120, 1_024])
        XCTAssertEqual(bySizeDescending[0].children?.map(\.bytes), [4_096, 1_024])

        let byNameDescending = LibraryTablePresentation.rows(
            groups: groups,
            sortOrder: [KeyPathComparator(\LibraryRow.name, order: .reverse)]
        )
        XCTAssertEqual(byNameDescending.map(\.name), ["Bravo", "Assistant"])
        XCTAssertEqual(byNameDescending[1].children?.map(\.name), ["Assistant Runtime", "Assistant"])
    }

    func testSelectionMapsFamilyRowsToNoModelPath() {
        XCTAssertNil(LibraryTablePresentation.modelPath(forSelection: nil))
        XCTAssertNil(LibraryTablePresentation.modelPath(forSelection: LibraryRow.familyIDPrefix + "assistant"))
        XCTAssertEqual(LibraryTablePresentation.modelPath(forSelection: "/models/a.gguf"), "/models/a.gguf")
    }

    func testRowDetailPrefersTheHuggingFaceRepoID() {
        let cached = makeLibraryModel(
            path: "/Users/x/.cache/huggingface/hub/models--org--name/snapshots/abc/config.json",
            name: "Cached",
            modelKey: "cached",
            quantization: nil,
            status: "ready"
        )
        XCTAssertEqual(LibraryTablePresentation.detail(for: cached), "org/name")
        XCTAssertEqual(ModelDetailsPresentation.identityLine(for: cached), "org/name · Unknown · 1 KB")
    }

    func testIdentityRowsCollapseDuplicatePathsAndKeepConditionalRows() {
        let ready = makeLibraryModel(path: "/models/assistant-ready.gguf", name: "Assistant", modelKey: "assistant", quantization: "Q4_K_M", status: "ready")
        let readyRows = ModelDetailsPresentation.identityRows(for: ready, prepareDestination: nil)
        XCTAssertEqual(readyRows.first, DetailRow("Path", "/models/assistant-ready.gguf"))
        XCTAssertFalse(readyRows.contains { $0.label == "Source" })
        XCTAssertEqual(readyRows.first { $0.label == "Outputs" }?.value, "/mlx/Assistant")
        XCTAssertFalse(readyRows.contains { $0.label == "Duplicate status" })
        XCTAssertFalse(readyRows.contains { $0.label == "Prepare destination" })
        XCTAssertTrue(readyRows.first { $0.label == "Readiness" }?.value.hasPrefix("Ready — ") == true)
        XCTAssertFalse(readyRows.contains { $0.label == "Signature" })

        let source = makeLibraryModel(path: "/models/source.gguf", name: "Source", modelKey: "source", quantization: "Q4_K_M", status: "needs_conversion")
        let sourceRows = ModelDetailsPresentation.identityRows(for: source, prepareDestination: "/models/source-mlx")
        XCTAssertEqual(sourceRows.first { $0.label == "Prepare destination" }?.value, "/models/source-mlx")
        XCTAssertFalse(sourceRows.contains { $0.label == "Outputs" })

        let duplicate = makeLibraryModel(path: "/models/dup.gguf", name: "Dup", modelKey: "dup", quantization: nil, status: "duplicate")
        let duplicateRows = ModelDetailsPresentation.identityRows(for: duplicate, prepareDestination: nil)
        XCTAssertTrue(duplicateRows.contains { $0.label == "Duplicate status" })
    }

    func testFlightPathRequiresExactMeasurementIdentityAndBothServingAuthorities() {
        let model = makeLibraryModel(path: "/models/flight.gguf", name: "Flight", modelKey: "flight", quantization: "Q4_K_M", status: "ready", signature: "new")
        let result = VariantResult(modelPath: model.item.path, modelSignature: "old", samples: [ComparisonSample(promptID: "p", outputExcerpt: "ok", tokensPerSecond: 1, timeToFirstTokenSeconds: 0.1, error: nil)], aggregateTokensPerSecond: 1, aggregateTTFTSeconds: 0.1, error: nil)
        let run = ComparisonRun(id: UUID(), promptSetID: "set", promptSetName: "Set", useCase: .coding, variants: [model.item.path], results: [result], startedAt: Date(), finishedAt: Date(), state: .completed)
        let server = ServerInfo(repo: model.item.path, runtime: "mlx", port: 8766, pid: 1, state: "running", logPath: nil, startedAt: nil, receipt: "receipt")

        let pendingMeasurement = ModelFlightPathPresentation.derive(model: model, verification: .unverified, completedRuns: [run], endpointState: .running(modelPath: model.item.path, port: 8766), servers: [server])
        XCTAssertEqual(pendingMeasurement.stages.first(where: { $0.stage == .measured })?.state, .pending)
        XCTAssertEqual(pendingMeasurement.stages.first(where: { $0.stage == .serving })?.state, .complete)

        let matching = VariantResult(modelPath: model.item.path, modelSignature: "new", samples: result.samples, aggregateTokensPerSecond: 1, aggregateTTFTSeconds: 0.1, error: nil)
        let matchingRun = ComparisonRun(id: UUID(), promptSetID: "set", promptSetName: "Set", useCase: .coding, variants: [model.item.path], results: [matching], startedAt: Date(), finishedAt: Date(), state: .completed)
        let mismatchedEndpoint = ModelFlightPathPresentation.derive(model: model, verification: .unverified, completedRuns: [matchingRun], endpointState: .running(modelPath: "/models/other", port: 8766), servers: [server])
        XCTAssertEqual(mismatchedEndpoint.stages.first(where: { $0.stage == .measured })?.state, .complete)
        XCTAssertEqual(mismatchedEndpoint.stages.first(where: { $0.stage == .serving })?.state, .pending)
    }

    func testFlightPathReportsTheActualPendingReadiness() {
        let model = makeLibraryModel(
            path: "/models/source.gguf",
            name: "Source",
            modelKey: "source",
            quantization: "Q4_K_M",
            status: "needs_conversion",
            signature: "source-signature"
        )

        let presentation = ModelFlightPathPresentation.derive(
            model: model,
            verification: .unverified,
            completedRuns: [],
            endpointState: .disabled,
            servers: []
        )

        XCTAssertEqual(
            presentation.stages.first(where: { $0.stage == .prepared })?.detail,
            "Library readiness is Needs Conversion."
        )
    }

    func testFlightPathDoesNotSubstituteAReadyModelWhenNothingIsSelected() {
        let snapshot = makeSnapshot()

        XCTAssertNil(
            ModelFlightPathPresentation.selectedModel(
                in: snapshot,
                selectedModelPath: nil
            )
        )
    }

    func testFlightPathReportsFailedCanaryEvidenceAsFailure() {
        let model = makeLibraryModel(
            path: "/models/failed.gguf",
            name: "Failed",
            modelKey: "failed",
            quantization: "Q4_K_M",
            status: "ready",
            signature: "failed-signature"
        )
        let report = VerificationReport(
            id: UUID(),
            modelPath: model.item.path,
            modelSignature: model.item.signature,
            workflowRecordID: nil,
            suiteVersion: CanarySuite.version,
            canaries: [],
            tokensPerSecond: nil,
            timeToFirstTokenSeconds: nil,
            metricsEstimated: false,
            startedAt: Date(),
            finishedAt: Date(),
            outcome: .failed(canaryIDs: ["echo"])
        )

        let presentation = ModelFlightPathPresentation.derive(
            model: model,
            verification: .failed(report),
            completedRuns: [],
            endpointState: .disabled,
            servers: []
        )
        let verification = presentation.stages.first { $0.stage == .verified }

        XCTAssertEqual(verification?.state, .failed)
        XCTAssertEqual(verification?.state.label, "Failed")
        XCTAssertEqual(verification?.detail, "Failed canaries: echo.")
    }

    func testSearchMatchesFamilyVariantAndKnownPathFields() {
        let snapshot = makeSnapshot()

        let familyMatches = LibraryPresentation.filteredGroups(
            in: snapshot,
            search: "assistant",
            readiness: nil,
            quantization: nil
        )
        XCTAssertEqual(familyMatches.map(\.sourceGroup.normalizedModelKey), ["assistant-alpha", "assistant-beta"])

        let variantMatches = LibraryPresentation.filteredGroups(
            in: snapshot,
            search: "runtime",
            readiness: nil,
            quantization: nil
        )
        XCTAssertEqual(variantMatches.flatMap(\.variants).map(\.item.path), ["/models/assistant-runtime.gguf"])

        let pathMatches = LibraryPresentation.filteredGroups(
            in: snapshot,
            search: "/vault/bravo-ready.gguf",
            readiness: nil,
            quantization: nil
        )
        XCTAssertEqual(pathMatches.map(\.primaryDisplayName), ["Bravo"])
    }

    func testReadinessFilterLimitsVisibleVariants() {
        let snapshot = makeSnapshot()

        let runtimeMatches = LibraryPresentation.filteredGroups(
            in: snapshot,
            search: "",
            readiness: .needsRuntime,
            quantization: nil
        )

        XCTAssertEqual(runtimeMatches.count, 1)
        XCTAssertEqual(runtimeMatches.first?.variants.map(\.item.path), ["/models/assistant-runtime.gguf"])
    }

    func testQuantizationFilterHandlesKnownAndUnknownValues() {
        let snapshot = makeSnapshot()

        let q4Matches = LibraryPresentation.filteredGroups(
            in: snapshot,
            search: "",
            readiness: nil,
            quantization: "Q4_K_M"
        )
        XCTAssertEqual(q4Matches.flatMap(\.variants).map(\.item.path), [
            "/models/assistant-ready.gguf",
            "/models/assistant-runtime.gguf",
        ])

        let unknownMatches = LibraryPresentation.filteredGroups(
            in: snapshot,
            search: "",
            readiness: nil,
            quantization: LibraryPresentation.unknownQuantizationLabel
        )
        XCTAssertEqual(unknownMatches.flatMap(\.variants).map(\.item.path), ["/vault/bravo-ready.gguf"])
    }

    func testGroupOrderingIsStableByDisplayNameThenKeyThenPath() {
        let ordered = LibraryPresentation.filteredGroups(
            in: makeSnapshot(),
            search: "",
            readiness: nil,
            quantization: nil
        )

        XCTAssertEqual(
            ordered.map(\.sourceGroup.normalizedModelKey),
            ["assistant-alpha", "assistant-beta", "bravo"]
        )
        XCTAssertEqual(
            ordered.compactMap { $0.variants.first?.item.path },
            [
                "/models/assistant-ready.gguf",
                "/models/assistant-runtime.gguf",
                "/vault/bravo-ready.gguf",
            ]
        )
    }

    func testPreparePresentationShowsSourceAndSameDirectoryDestination() {
        let presentation = PrepareWorkflowPresentation(workflow: makeWorkflow(
            sourcePath: "/models/atlas.gguf",
            outputPath: "/models/atlas-mlx",
            state: .inspectingSource
        ))

        XCTAssertEqual(presentation.sourcePath, "/models/atlas.gguf")
        XCTAssertEqual(presentation.destinationPath, "/models/atlas-mlx")
        XCTAssertEqual(presentation.primaryAction, .preview)
        XCTAssertTrue(presentation.canPreview)
    }

    func testPreparePresentationChoosesRunExistingForEquivalentModel() {
        let presentation = PrepareWorkflowPresentation(workflow: makeWorkflow(
            outputPath: "/models/atlas-mlx",
            state: .existingModelFound
        ))

        XCTAssertEqual(presentation.primaryAction, .runExisting)
        XCTAssertFalse(presentation.canPreview)
    }

    func testPreparePresentationDisablesConfirmationWithoutPreviewHash() {
        let presentation = PrepareWorkflowPresentation(workflow: makeWorkflow(state: .readyToConfirm))

        XCTAssertEqual(presentation.primaryAction, .confirm)
        XCTAssertFalse(presentation.canConfirm)
    }

    func testPreparePresentationShowsExactBlockedDestinationError() {
        let blockedReason = "Destination already exists and is not an equivalent MLX model."
        let presentation = PrepareWorkflowPresentation(workflow: makeWorkflow(
            outputPath: "/models/atlas-mlx",
            state: .failed,
            errorMessage: blockedReason
        ))

        XCTAssertEqual(presentation.errorMessage, blockedReason)
        XCTAssertEqual(presentation.stateTitle, "Preparation needs attention")
    }

    func testPreparePresentationHidesPrimaryActionForBlockedDestinationWithOldPreviewHash() {
        let presentation = PrepareWorkflowPresentation(workflow: makeWorkflow(
            previewHash: "old-preview",
            state: .failed,
            errorMessage: "Destination already exists and is not an equivalent MLX model."
        ))

        XCTAssertFalse(presentation.canConfirm)
        XCTAssertEqual(presentation.primaryAction, .none)
    }

    func testPreparePresentationLocksQuantizationAfterPreview() {
        let noPreview = PrepareWorkflowPresentation(workflow: makeWorkflow())
        let previewed = PrepareWorkflowPresentation(workflow: makeWorkflow(
            previewHash: "preview-hash",
            state: .readyToConfirm
        ))

        XCTAssertFalse(noPreview.isQuantizationLocked)
        XCTAssertTrue(previewed.isQuantizationLocked)
    }

    private func makeSnapshot() -> LibrarySnapshot {
        let assistantReady = makeLibraryModel(
            path: "/models/assistant-ready.gguf",
            name: "Assistant",
            modelKey: "assistant-alpha",
            quantization: "Q4_K_M",
            status: "ready"
        )
        let assistantRuntime = makeLibraryModel(
            path: "/models/assistant-runtime.gguf",
            name: "Assistant Runtime",
            modelKey: "assistant-beta",
            quantization: "Q4_K_M",
            status: "missing_runtime"
        )
        let bravo = makeLibraryModel(
            path: "/vault/bravo-ready.gguf",
            name: "Bravo",
            modelKey: "bravo",
            quantization: nil,
            status: "ready"
        )

        return LibrarySnapshot(
            models: [assistantRuntime, bravo, assistantReady],
            groups: [
                ModelGroup(variants: [bravo], normalizedModelKey: "bravo", primaryDisplayName: "Bravo"),
                ModelGroup(variants: [assistantRuntime], normalizedModelKey: "assistant-beta", primaryDisplayName: "Assistant"),
                ModelGroup(variants: [assistantReady], normalizedModelKey: "assistant-alpha", primaryDisplayName: "Assistant"),
            ],
            hardware: HardwareProfile(chip: "M4", model: "Mac16,1", memoryBytes: 32_000_000_000, macOSVersion: "14.0"),
            generatedAt: Date(timeIntervalSince1970: 1_726_500_000)
        )
    }

    private func makeMultiVariantSnapshot() -> LibrarySnapshot {
        let assistantReady = makeLibraryModel(
            path: "/models/assistant-ready.gguf",
            name: "Assistant",
            modelKey: "assistant",
            quantization: "Q4_K_M",
            status: "ready"
        )
        let assistantRuntime = makeLibraryModel(
            path: "/models/assistant-runtime.gguf",
            name: "Assistant Runtime",
            modelKey: "assistant",
            quantization: "Q8_0",
            status: "missing_runtime",
            bytes: 4_096
        )
        let bravo = makeLibraryModel(
            path: "/vault/bravo-ready.gguf",
            name: "Bravo",
            modelKey: "bravo",
            quantization: nil,
            status: "ready"
        )

        return LibrarySnapshot(
            models: [assistantRuntime, bravo, assistantReady],
            groups: [
                ModelGroup(variants: [bravo], normalizedModelKey: "bravo", primaryDisplayName: "Bravo"),
                ModelGroup(variants: [assistantRuntime, assistantReady], normalizedModelKey: "assistant", primaryDisplayName: "Assistant"),
            ],
            hardware: HardwareProfile(chip: "M4", model: "Mac16,1", memoryBytes: 32_000_000_000, macOSVersion: "14.0"),
            generatedAt: Date(timeIntervalSince1970: 1_726_500_000)
        )
    }

    private func makeLibraryModel(
        path: String,
        name: String,
        modelKey: String,
        quantization: String?,
        status: String,
        signature: String? = nil,
        bytes: Int64 = 1_024
    ) -> LibraryModel {
        LibraryModel(
            item: ModelItem(
                path: path,
                name: name,
                bytes: bytes,
                modifiedAt: 1_726_500_000,
                shard: nil,
                modelKey: modelKey,
                architecture: "llama",
                quantization: quantization,
                parameters: "7B",
                structure: nil,
                signature: signature,
                companion: nil,
                readable: true,
                status: status,
                outputs: status == "ready" ? ["/mlx/\(name)"] : [],
                tensorCount: 32,
                error: nil
            ),
            normalizedFamilyKey: modelKey,
            displayName: name
        )
    }

    private func makeWorkflow(
        sourcePath: String = "/models/atlas.gguf",
        outputPath: String = "/models/atlas-mlx",
        previewHash: String? = nil,
        state: ConversionWorkflowState = .idle,
        errorMessage: String? = nil
    ) -> ConversionWorkflow {
        let timestamp = Date(timeIntervalSince1970: 1_726_500_000)
        return ConversionWorkflow(
            id: UUID(),
            sourcePath: sourcePath,
            sourceModelKey: "atlas",
            sourceSignature: "signature",
            outputPath: outputPath,
            previewHash: previewHash,
            jobReceipt: nil,
            completedModelPath: nil,
            state: state,
            serveState: .idle,
            message: nil,
            errorMessage: errorMessage,
            createdAt: timestamp,
            updatedAt: timestamp,
            lastKnownAgentState: nil
        )
    }
}
