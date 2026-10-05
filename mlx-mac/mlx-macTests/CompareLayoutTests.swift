import Foundation
import XCTest

@testable import mlx_workbench

final class CompareLayoutTests: XCTestCase {
    private func model(_ path: String, key: String? = "key", parameters: String? = nil, bytes: Int64 = 1000, displayName: String? = nil) -> LibraryModel {
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: bytes,
            modifiedAt: nil, shard: nil,
            modelKey: key, architecture: nil, quantization: "Q4_K_M", parameters: parameters,
            structure: nil, signature: nil, companion: nil, readable: true,
            status: "ready", outputs: [], tensorCount: nil, error: nil
        )
        return LibraryModel(item: item, displayName: displayName, readiness: .ready)
    }

    func testVariantPathsDropsNilAndDuplicatesAndKeepsOrder() {
        let slots: [String?] = ["/b", nil, "/a", "/b", "/c"]
        XCTAssertEqual(ComparePresentation.variantPaths(slots), ["/b", "/a", "/c"])
        XCTAssertEqual(ComparePresentation.variantPaths([nil, nil]), [])
    }

    func testOptionsExcludeOtherSlotsPicksButKeepOwn() {
        let candidates = [model("/a"), model("/b"), model("/c")]
        let slots: [String?] = ["/a", "/b"]
        XCTAssertEqual(
            ComparePresentation.options(forSlot: 0, slots: slots, candidates: candidates).map(\.item.path),
            ["/a", "/c"]
        )
        XCTAssertEqual(
            ComparePresentation.options(forSlot: 1, slots: slots, candidates: candidates).map(\.item.path),
            ["/b", "/c"]
        )
        XCTAssertEqual(
            ComparePresentation.options(forSlot: 0, slots: [nil, nil], candidates: candidates).map(\.item.path),
            ["/a", "/b", "/c"]
        )
    }

    func testMaxSlotsIsFour() {
        XCTAssertEqual(ComparePresentation.maxSlots, 4)
    }

    func testPreselectedSlotsPicksSelectedModelAndSameKeySibling() {
        let candidates = [
            model("/other", key: "other"),
            model("/q4", key: "llama"),
            model("/q8", key: "llama"),
        ]
        XCTAssertEqual(
            ComparePresentation.preselectedSlots(selectedPath: "/q4", candidates: candidates),
            ["/q4", "/q8"]
        )
        XCTAssertEqual(
            ComparePresentation.preselectedSlots(selectedPath: "/q8", candidates: candidates),
            ["/q8", "/q4"]
        )
        XCTAssertEqual(
            ComparePresentation.preselectedSlots(selectedPath: "/other", candidates: candidates),
            ["/other", nil]
        )
    }

    func testPreselectedSlotsMatchesAnOutputPath() {
        let item = ModelItem(
            path: "/src.gguf", name: "src.gguf", bytes: 1000, modifiedAt: nil, shard: nil,
            modelKey: "llama", architecture: nil, quantization: "Q4_K_M", parameters: nil,
            structure: nil, signature: nil, companion: nil, readable: true,
            status: "ready", outputs: ["/out-mlx"], tensorCount: nil, error: nil
        )
        let converted = LibraryModel(item: item, readiness: .ready)
        XCTAssertTrue(converted.outputPaths.contains("/out-mlx"))
        XCTAssertEqual(
            ComparePresentation.preselectedSlots(selectedPath: "/out-mlx", candidates: [converted]),
            ["/src.gguf", nil]
        )
    }

    func testPreselectedSlotsIsEmptyWhenNothingMatches() {
        let candidates = [model("/a"), model("/b")]
        XCTAssertEqual(
            ComparePresentation.preselectedSlots(selectedPath: "/missing", candidates: candidates),
            [nil, nil]
        )
        XCTAssertEqual(
            ComparePresentation.preselectedSlots(selectedPath: nil, candidates: candidates),
            [nil, nil]
        )
    }

    func testPreselectedSlotsIgnoresSiblingsWithoutAModelKey() {
        let candidates = [model("/a", key: nil), model("/b", key: nil)]
        XCTAssertEqual(
            ComparePresentation.preselectedSlots(selectedPath: "/a", candidates: candidates),
            ["/a", nil]
        )
    }

    func testCanRunNeedsAPickAndNoActiveRun() {
        XCTAssertFalse(ComparePresentation.canRun(slots: [nil, nil], activeRunID: nil))
        XCTAssertTrue(ComparePresentation.canRun(slots: ["/a", nil], activeRunID: nil))
        XCTAssertFalse(ComparePresentation.canRun(slots: ["/a", "/b"], activeRunID: UUID()))
    }

    /// Run results store model paths; HF-cache snapshots end in a commit hash,
    /// so the label must come from the Library or the repo id, not the folder.
    func testDisplayNamePrefersLibraryThenRepoIDThenFolder() {
        let snapshot = "/hub/models--mlx-community--Qwen3-4B-4bit/snapshots/4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25"
        let library = LibraryModel(item: model(snapshot).item, displayName: "Qwen3-4B-4bit", readiness: .ready)
        XCTAssertEqual(ComparePresentation.displayName(for: snapshot, models: [library]), "Qwen3-4B-4bit")
        XCTAssertEqual(ComparePresentation.displayName(for: snapshot, models: []), "mlx-community/Qwen3-4B-4bit")
        XCTAssertEqual(ComparePresentation.displayName(for: "/models/mlx/whisper-tiny-MLX-4bit", models: []), "whisper-tiny-MLX-4bit")
    }

    func testFiltersIntersectFamilyDiskSizeAndSearch() {
        let candidates = [model("/Qwen-small", key: "qwen", parameters: "350M", bytes: 1_000_000_000, displayName: "Qwen-0.35B"), model("/Qwen-large", key: "qwen", parameters: "8B", bytes: 5_000_000_000, displayName: "Qwen-8B"), model("/Other-small", key: "other", parameters: "2B", displayName: "Other-2B")]
        XCTAssertEqual(ComparePresentation.filtered(candidates, family: "Qwen", size: .under2, query: " QWEN ").map(\.item.path), ["/Qwen-small"])
        XCTAssertEqual(ComparePresentation.filtered(candidates, family: nil, size: .all, query: " ").count, 3)
        XCTAssertTrue(ComparePresentation.filtered(candidates, family: "missing", size: .all, query: "").isEmpty)
    }

    func testParameterBucketsHaveExplicitBoundariesAndUnknowns() {
        XCTAssertEqual(ComparePresentation.ParameterSize.bucket(model("/a", parameters: "2.99B")), .under3)
        XCTAssertEqual(ComparePresentation.ParameterSize.bucket(model("/a", parameters: "3B")), .from3To8)
        XCTAssertEqual(ComparePresentation.ParameterSize.bucket(model("/a", parameters: "8B", bytes: 5_000_000_000, displayName: "Qwen-8B")), .from8To20)
        XCTAssertEqual(ComparePresentation.ParameterSize.bucket(model("/a", parameters: "20B")), .over20)
        XCTAssertEqual(ComparePresentation.ParameterSize.bucket(model("/a", parameters: nil)), .unknown)
        XCTAssertEqual(ComparePresentation.ParameterSize.bucket(model("/a", parameters: "unknown")), .unknown)
    }

    func testGroupingUsesReadableFamiliesAndIndependentDiskSizes() {
        let candidates = [model("/z", key: "qwen", parameters: "20B", bytes: 1_000_000_000, displayName: "Qwen-20B"), model("/a", key: "qwen", parameters: "2B", bytes: 5_000_000_000, displayName: "Qwen-2B"), model("/unknown", key: "other", bytes: 0, displayName: "Other")]
        let families = ComparePresentation.groups(candidates, by: .family)
        XCTAssertEqual(families.map(\.title), ["Other", "Qwen"])
        XCTAssertEqual(families[1].models.map(\.item.path), ["/a", "/z"])
        XCTAssertEqual(ComparePresentation.groups(candidates, by: .parameters).map(\.title), ["Under 3B", "20B+", "Unknown size"])
        XCTAssertEqual(ComparePresentation.groups(candidates, by: .disk).map(\.title), ["Under 2 GB", "5–<10 GB", "Unknown disk size"])
    }

    func testFamilyLabelsUseRepoNamesInsteadOfSnapshotHashes() {
        let path = "/hub/models--mlx-community--Qwen2.5-VL-3B-Instruct-4bit/snapshots/4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25"
        XCTAssertEqual(ComparePresentation.familyLabel(model(path, key: "4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25")), "Qwen2.5-VL")
        XCTAssertEqual(ComparePresentation.familyLabel(model("/local", displayName: "LFM2.5-1.2B-Instruct-MLX-8bit")), "LFM2.5")
        XCTAssertEqual(ComparePresentation.familyLabel(model("/local", displayName: "whisper-tiny-MLX-4bit")), "whisper-tiny")
        XCTAssertEqual(ComparePresentation.familyLabel(model("/local", displayName: "4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25")), "Unknown family")
    }

    func testDiskBucketsWorkWithoutParameterMetadata() {
        XCTAssertEqual(ComparePresentation.SizeFilter.bucket(model("/a", bytes: 1_999_999_999)), .under2)
        XCTAssertEqual(ComparePresentation.SizeFilter.bucket(model("/a", bytes: 2_000_000_000)), .from2To5)
        XCTAssertEqual(ComparePresentation.SizeFilter.bucket(model("/a", bytes: 5_000_000_000)), .from5To10)
        XCTAssertEqual(ComparePresentation.SizeFilter.bucket(model("/a", bytes: 10_000_000_000)), .over10)
        XCTAssertEqual(ComparePresentation.SizeFilter.bucket(model("/a", bytes: 0)), .unknown)
        XCTAssertEqual(ComparePresentation.SizeFilter.bucket(model("/a", bytes: -1)), .unknown)
    }

    func testSelectedOutsideFiltersStaysAvailableWithoutDuplicatingOptions() {
        let candidates = [model("/a", key: "qwen", displayName: "Qwen-1B"), model("/b", key: "other", displayName: "Other-1B"), model("/c", key: "qwen", displayName: "Qwen-2B")]
        let filtered = ComparePresentation.filtered(candidates, family: "Qwen", size: .all, query: "")
        let slots: [String?] = ["/b", "/a"]
        XCTAssertEqual(ComparePresentation.selectedOutsideFilter(forSlot: 0, slots: slots, candidates: candidates, filtered: filtered)?.item.path, "/b")
        XCTAssertNil(ComparePresentation.selectedOutsideFilter(forSlot: 1, slots: slots, candidates: candidates, filtered: filtered))
        XCTAssertEqual(ComparePresentation.options(forSlot: 0, slots: slots, candidates: filtered).map(\.item.path), ["/c"])
        XCTAssertEqual(ComparePresentation.variantPaths(slots), ["/b", "/a"])
        XCTAssertNil(ComparePresentation.selectedOutsideFilter(forSlot: 9, slots: slots, candidates: candidates, filtered: filtered))
    }
}
