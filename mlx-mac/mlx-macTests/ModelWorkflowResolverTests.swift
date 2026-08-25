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

    func testMatchingSignatureReusesDespiteDifferentModelKeys() {
        let source = makeGGUF(path: "/Models/llama-3-q4.gguf", modelKey: "llama-3", signature: "signature-1")
        let existing = makeLibraryModel(path: "/Models/llama-3-q4", modelKey: "different-key", signature: "signature-1")

        XCTAssertEqual(
            ModelWorkflowResolver.destination(for: source, library: makeSnapshot(models: [existing]),
                                              fileManager: fileManager, now: now),
            .reuseExisting(existing)
        )
    }

    func testPathFallbackResolvesSymlinkAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let realDirectory = root.appendingPathComponent("real")
        let aliasDirectory = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: realDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = makeGGUF(path: aliasDirectory.appendingPathComponent("llama-3-q4.gguf").path,
                              modelKey: nil)
        let existing = makeLibraryModel(path: realDirectory.appendingPathComponent("llama-3-q4").path,
                                        modelKey: nil, signature: nil)

        XCTAssertTrue(ModelWorkflowResolver.matchesEquivalent(source: source, candidate: existing))
    }

    private func makeGGUF(path: String, modelKey: String?, signature: String? = nil) -> ModelItem {
        ModelItem(path: path, name: "llama-3-q4.gguf", bytes: 1_024, modifiedAt: nil, shard: nil,
                  modelKey: modelKey, architecture: "llama", quantization: "Q4", parameters: "3B",
                  structure: nil, signature: signature, companion: nil, readable: true, status: "ready",
                  outputs: [], tensorCount: nil, error: nil)
    }

    private func makeLibraryModel(path: String, modelKey: String?, signature: String? = nil) -> LibraryModel {
        LibraryModel(item: ModelItem(path: path, name: "llama-3-q4", bytes: 2_048, modifiedAt: nil,
                                     shard: nil, modelKey: modelKey, architecture: "llama",
                                     quantization: nil, parameters: "3B", structure: nil, signature: signature,
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
