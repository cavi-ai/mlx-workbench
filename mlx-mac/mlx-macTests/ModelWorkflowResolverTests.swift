import Foundation
import XCTest

@testable import mlx_workbench

final class ModelWorkflowResolverTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1234)
    private let fileManager = TestFileManager()

    func testDefaultsOutputBesideSourceWithoutAutomaticSuffix() {
        let source = makeGGUF(path: "/Models/llama-3-q4.gguf", modelKey: "llama-3")

        let decision = ModelWorkflowResolver.destination(
            for: source,
            library: nil,
            fileManager: fileManager,
            now: now
        )

        XCTAssertEqual(decision, .available(URL(fileURLWithPath: "/Models/llama-3-q4")))
    }

    func testEquivalentSiblingMLXIsReused() {
        let source = makeGGUF(path: "/Models/llama-3-q4.gguf", modelKey: "llama-3")
        let existing = makeLibraryModel(path: "/Models/llama-3-q4", modelKey: "llama-3")
        let snapshot = makeSnapshot(models: [existing])

        XCTAssertEqual(
            ModelWorkflowResolver.destination(for: source, library: snapshot,
                                              fileManager: fileManager, now: now),
            .reuseExisting(existing)
        )
    }

    func testNonEquivalentExistingDestinationBlocksInsteadOfSuffixing() throws {
        let source = makeGGUF(path: "/Models/llama-3-q4.gguf", modelKey: "llama-3")
        try fileManager.createDirectory(atPath: "/Models/llama-3-q4", withIntermediateDirectories: true)

        let decision = ModelWorkflowResolver.destination(
            for: source, library: nil, fileManager: fileManager, now: now
        )

        guard case .blocked(let path, let reason) = decision else { return XCTFail() }
        XCTAssertEqual(path.path, "/Models/llama-3-q4")
        XCTAssertTrue(reason.contains("already exists"))
    }

    private func makeGGUF(path: String, modelKey: String?) -> ModelItem {
        ModelItem(path: path, name: "llama-3-q4.gguf", bytes: 1_024, modifiedAt: nil, shard: nil,
                  modelKey: modelKey, architecture: "llama", quantization: "Q4", parameters: "3B",
                  structure: nil, signature: nil, companion: nil, readable: true, status: "ready",
                  outputs: [], tensorCount: nil, error: nil)
    }

    private func makeLibraryModel(path: String, modelKey: String?) -> LibraryModel {
        LibraryModel(item: ModelItem(path: path, name: "llama-3-q4", bytes: 2_048, modifiedAt: nil,
                                     shard: nil, modelKey: modelKey, architecture: "llama",
                                     quantization: nil, parameters: "3B", structure: nil, signature: nil,
                                     companion: nil, readable: true, status: "ready", outputs: [path],
                                     tensorCount: nil, error: nil), normalizedFamilyKey: modelKey)
    }

    private func makeSnapshot(models: [LibraryModel]) -> LibrarySnapshot {
        LibrarySnapshot(models: models, groups: [],
                        hardware: HardwareProfile(chip: nil, model: nil, memoryBytes: nil, macOSVersion: nil),
                        generatedAt: now)
    }
}

private final class TestFileManager: FileManager {
    private var virtualDirectories = Set<String>()

    override func fileExists(atPath path: String) -> Bool {
        virtualDirectories.contains(path)
    }

    override func createDirectory(atPath path: String, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        virtualDirectories.insert(path)
    }
}
