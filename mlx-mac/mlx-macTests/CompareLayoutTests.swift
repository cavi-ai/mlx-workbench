import Foundation
import XCTest

@testable import mlx_workbench

final class CompareLayoutTests: XCTestCase {
    private func model(_ path: String, key: String? = "key") -> LibraryModel {
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: 1000,
            modifiedAt: nil, shard: nil,
            modelKey: key, architecture: nil, quantization: "Q4_K_M", parameters: nil,
            structure: nil, signature: nil, companion: nil, readable: true,
            status: "ready", outputs: [], tensorCount: nil, error: nil
        )
        return LibraryModel(item: item, readiness: .ready)
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
}
