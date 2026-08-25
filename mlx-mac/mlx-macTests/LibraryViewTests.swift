import Foundation
import XCTest

@testable import mlx_workbench

final class LibraryViewTests: XCTestCase {
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

    func testPreparePresentationDisablesConfirmationForBlockedDestinationWithOldPreviewHash() {
        let presentation = PrepareWorkflowPresentation(workflow: makeWorkflow(
            previewHash: "old-preview",
            state: .failed,
            errorMessage: "Destination already exists and is not an equivalent MLX model."
        ))

        XCTAssertFalse(presentation.canConfirm)
        XCTAssertEqual(presentation.primaryAction, .preview)
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

    private func makeLibraryModel(
        path: String,
        name: String,
        modelKey: String,
        quantization: String?,
        status: String
    ) -> LibraryModel {
        LibraryModel(
            item: ModelItem(
                path: path,
                name: name,
                bytes: 1_024,
                modifiedAt: 1_726_500_000,
                shard: nil,
                modelKey: modelKey,
                architecture: "llama",
                quantization: quantization,
                parameters: "7B",
                structure: nil,
                signature: nil,
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
