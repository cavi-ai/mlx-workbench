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
}
