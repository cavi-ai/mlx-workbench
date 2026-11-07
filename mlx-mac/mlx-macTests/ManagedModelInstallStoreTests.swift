import Darwin
import Foundation
import XCTest

@testable import mlx_workbench

final class ManagedModelInstallStoreTests: XCTestCase {
    private let revisionA = String(repeating: "a", count: 40)
    private let revisionB = String(repeating: "b", count: 40)

    func testManagedDirectoriesSeparateRepositoryComponentsAndRevisions() throws {
        let root = try temporaryRoot()
        let first = try XCTUnwrap(ManagedModelInstallStore.directory(root: root.path, source: source("owner/model", revision: revisionA)))
        let otherOwner = try XCTUnwrap(ManagedModelInstallStore.directory(root: root.path, source: source("other/model", revision: revisionA)))
        let otherModel = try XCTUnwrap(ManagedModelInstallStore.directory(root: root.path, source: source("owner/other", revision: revisionA)))
        let nextRevision = try XCTUnwrap(ManagedModelInstallStore.directory(root: root.path, source: source("owner/model", revision: revisionB)))
        XCTAssertEqual(Set([first, otherOwner, otherModel, nextRevision]).count, 4)
        XCTAssertEqual(first, root.appendingPathComponent("managed/owner/model/\(revisionA)").path)
        XCTAssertEqual(ManagedModelInstallStore.directory(root: root.path, source: source("owner/model", revision: revisionA.uppercased())), first)
        XCTAssertEqual(ManagedModelInstallStore.directory(root: root.path, source: source("owner/model", revision: "main", resolved: revisionA)), first)
    }

    func testManagedPresentationNamesIncludeRepositoryCheckpointAndRevision() throws {
        let root = try temporaryRoot()
        let directory = try XCTUnwrap(ManagedModelInstallStore.directory(root: root.path, source: source("owner/model", revision: revisionA)))
        let identity = try XCTUnwrap(ManagedModelInstallStore.presentationIdentity(path: directory))
        XCTAssertEqual(identity.displayName, "owner/model · aaaaaaaa")
        XCTAssertEqual(identity.family, "owner/model")
        let checkpoint = try XCTUnwrap(ManagedModelInstallStore.directory(root: root.path, source: source("owner/model", revision: revisionA, subfolder: "checkpoints/small")))
        XCTAssertEqual(ManagedModelInstallStore.presentationIdentity(path: checkpoint + "/checkpoints/small")?.displayName, "owner/model/checkpoints/small · aaaaaaaa")
        let pending = try XCTUnwrap(ManagedModelInstallStore.directory(root: root.path, source: source("owner/model", revision: "main")))
        XCTAssertEqual(ManagedModelInstallStore.presentationIdentity(path: pending)?.displayName, "owner/model · local download")
        for path in ["/models/managed/owner/model/main", "/models/managed/owner/model/selection-bad/\(revisionA)", "/models/other/owner/model/\(revisionA)"] {
            XCTAssertNil(ManagedModelInstallStore.presentationIdentity(path: path))
        }
    }

    func testMalformedRepositoryDoesNotAliasAValidManagedDirectory() throws {
        let root = try temporaryRoot()
        for repo in ["owner//model", "/owner/model", "owner/model/", "../model", "owner/..", "owner/model/subfolder", "owner/model name"] {
            XCTAssertNil(ManagedModelInstallStore.directory(root: root.path, source: source(repo, revision: revisionA)), repo)
        }
    }

    func testCheckpointAndFileSelectionsHaveSeparateImmutableDirectories() throws {
        let root = try temporaryRoot()
        let firstSource = source("owner/model", revision: revisionA, subfolder: "checkpoints/small")
        let secondSource = source("owner/model", revision: revisionA, subfolder: "checkpoints/large")
        let first = try XCTUnwrap(ManagedModelInstallStore.directory(root: root.path, source: firstSource))
        let second = try XCTUnwrap(ManagedModelInstallStore.directory(root: root.path, source: secondSource))
        let file = try XCTUnwrap(ManagedModelInstallStore.directory(root: root.path, source: source("owner/model", revision: revisionA), file: "model-Q4.gguf"))
        let folderWithFileName = try XCTUnwrap(ManagedModelInstallStore.directory(root: root.path, source: source("owner/model", revision: revisionA, subfolder: "model-Q4.gguf")))
        XCTAssertEqual(Set([first, second, file, folderWithFileName]).count, 4)
        XCTAssertEqual(ManagedModelInstallStore.directory(root: root.path, source: firstSource), first)
        XCTAssertEqual(ManagedModelInstallStore.directory(root: root.path, source: source("owner/model", revision: revisionA, file: "model-Q4.gguf")), file)
        XCTAssertEqual(URL(fileURLWithPath: first).lastPathComponent, revisionA)
        XCTAssertTrue(URL(fileURLWithPath: first).deletingLastPathComponent().lastPathComponent.hasPrefix("selection-"))
        let fullRepository = try XCTUnwrap(ManagedModelInstallStore.directory(root: root.path, source: source("owner/model", revision: revisionA)))
        for selected in [first, second, file, folderWithFileName] {
            XCTAssertFalse(selected.hasPrefix(fullRepository + "/"))
            XCTAssertFalse(fullRepository.hasPrefix(selected + "/"))
        }
        XCTAssertNil(ManagedModelInstallStore.directory(root: root.path, source: firstSource, file: "model-Q4.gguf"))
        XCTAssertNil(ManagedModelInstallStore.directory(root: root.path, source: source("owner/model", revision: revisionA), file: "../model.gguf"))
    }

    func testMutableBranchDownloadsGetSeparateDestinations() throws {
        let root = try temporaryRoot()
        let source = source("owner/model", revision: "main")
        let first = try XCTUnwrap(ManagedModelInstallStore.directory(root: root.path, source: source))
        let second = try XCTUnwrap(ManagedModelInstallStore.directory(root: root.path, source: source))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(URL(fileURLWithPath: first).lastPathComponent.hasPrefix("download-"))
    }

    func testMetadataSignatureDetectsInPlaceWeightEditWithRestoredSizeAndMtime() throws {
        let root = try temporaryRoot()
        let model = try createModel(at: root.appendingPathComponent("model"))
        let weights = model.appendingPathComponent("model.safetensors")
        let originalMtime = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: weights.path)[.modificationDate] as? Date)
        var beforeStat = stat()
        XCTAssertEqual(lstat(weights.path, &beforeStat), 0)
        let before = try ManagedModelInstallStore.signature(path: model.path)
        let handle = try FileHandle(forWritingTo: weights)
        try handle.write(contentsOf: Data("changed!".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: originalMtime], ofItemAtPath: weights.path)
        var afterStat = stat()
        XCTAssertEqual(lstat(weights.path, &afterStat), 0)
        XCTAssertEqual(beforeStat.st_ino, afterStat.st_ino)
        XCTAssertEqual(beforeStat.st_size, afterStat.st_size)
        XCTAssertNotEqual(try ManagedModelInstallStore.signature(path: model.path), before)
    }

    func testMetadataSignatureIsStableAndDetectsWeightReplacementAndAddedFiles() throws {
        let root = try temporaryRoot()
        let model = try createModel(at: root.appendingPathComponent("model"))
        let before = try ManagedModelInstallStore.signature(path: model.path)
        XCTAssertEqual(try ManagedModelInstallStore.signature(path: model.path), before)
        try Data("updated!".utf8).write(to: model.appendingPathComponent("model.safetensors"), options: .atomic)
        let replaced = try ManagedModelInstallStore.signature(path: model.path)
        XCTAssertNotEqual(replaced, before)
        try Data("{}".utf8).write(to: model.appendingPathComponent("generation_config.json"))
        XCTAssertNotEqual(try ManagedModelInstallStore.signature(path: model.path), replaced)
    }

    func testHuggingFaceSnapshotAllowsOnlyItsOwnRepositoryBlobs() throws {
        let root = try temporaryRoot()
        let repo = root.appendingPathComponent("models--owner--model")
        let snapshot = repo.appendingPathComponent("snapshots/\(revisionA)")
        let blobs = repo.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let ownBlob = blobs.appendingPathComponent("weights")
        try Data("original".utf8).write(to: ownBlob)
        let link = snapshot.appendingPathComponent("model.safetensors")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../blobs/weights")
        let before = try ManagedModelInstallStore.signature(path: snapshot.path)
        try Data("changed!".utf8).write(to: ownBlob)
        XCTAssertNotEqual(try ManagedModelInstallStore.signature(path: snapshot.path), before)

        let otherBlob = root.appendingPathComponent("models--other--model/blobs/weights")
        try FileManager.default.createDirectory(at: otherBlob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("external".utf8).write(to: otherBlob)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: otherBlob.path)
        XCTAssertThrowsError(try ManagedModelInstallStore.signature(path: snapshot.path))
    }

    func testCacheBlobLinkCannotEscapeThroughAnotherLink() throws {
        let root = try temporaryRoot()
        let repo = root.appendingPathComponent("models--owner--model")
        let snapshot = repo.appendingPathComponent("snapshots/\(revisionA)")
        let blobs = repo.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.safetensors")
        try Data("external".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: blobs.appendingPathComponent("weights").path, withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: snapshot.appendingPathComponent("model.safetensors").path,
            withDestinationPath: "../../blobs/weights")
        XCTAssertThrowsError(try ManagedModelInstallStore.signature(path: snapshot.path))
    }

    func testManagedFolderRejectsLinksEvenToLocalRegularFiles() throws {
        let root = try temporaryRoot()
        let model = try createModel(at: root.appendingPathComponent("model"))
        try FileManager.default.createSymbolicLink(atPath: model.appendingPathComponent("alias.safetensors").path,
            withDestinationPath: "model.safetensors")
        XCTAssertThrowsError(try ManagedModelInstallStore.signature(path: model.path))
    }

    func testSignatureRefusesSymlinkedParentOutsideManagedTree() throws {
        let root = try temporaryRoot()
        let outside = try createModel(at: root.appendingPathComponent("external/model"))
        let managed = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: managed.appendingPathComponent("owner").path,
            withDestinationPath: outside.deletingLastPathComponent().path)
        XCTAssertThrowsError(try ManagedModelInstallStore.signature(path: managed.appendingPathComponent("owner/model").path))
    }

    func testSourceSelectionRoundTripsAndPreservesExactCheckpointReference() async throws {
        let root = try temporaryRoot()
        let store = ManagedModelInstallStore(store: JSONStore(fileURL: root.appendingPathComponent("managed.json")))
        let checkpointSource = source("owner/model", revision: revisionA, subfolder: "checkpoints/small")
        let directory = try XCTUnwrap(ManagedModelInstallStore.directory(root: root.path, source: checkpointSource))
        let selected = ManagedModelInstall(repo: "owner/model", revision: revisionA,
            path: URL(fileURLWithPath: directory).appendingPathComponent("checkpoints/small").path,
            signature: "weights", installedAt: Date(timeIntervalSince1970: 10), file: nil, subfolder: "checkpoints/small")
        try await store.record(selected)
        let loaded = try await store.records()
        XCTAssertEqual(loaded, [selected])
        XCTAssertEqual(try ManagedModelInstallStore.sourceReference(repo: selected.repo, file: selected.file, subfolder: selected.subfolder), "owner/model/checkpoints/small")
        XCTAssertTrue(ManagedModelInstallStore.matchesManagedSourcePath(selected, root: root.path))
        XCTAssertEqual(try ManagedModelInstallStore.sourceReference(repo: selected.repo, file: "quantizations/model-Q4.gguf", subfolder: nil),
            "https://huggingface.co/owner/model/blob/main/quantizations/model-Q4.gguf")
    }

    func testLegacyLedgerDecodesWithoutInventingCheckpointSelection() throws {
        let root = try temporaryRoot()
        let original = install(path: root.appendingPathComponent("managed/owner/model/\(revisionA)").path, revision: revisionA, signature: "old")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ManagedModelInstall.self, from: data)
        XCTAssertNil(decoded.file)
        XCTAssertNil(decoded.subfolder)
        XCTAssertTrue(ManagedModelInstallStore.matchesManagedSourcePath(decoded, root: root.path))
        let untrackedCheckpoint = install(path: decoded.path + "/checkpoints/small", revision: revisionA, signature: "old")
        XCTAssertFalse(ManagedModelInstallStore.matchesManagedSourcePath(untrackedCheckpoint, root: root.path))
    }

    func testSourceSelectionRejectsTraversalAndAmbiguousFilePlusFolder() throws {
        for selection in ["../outside", "/absolute", "folder//child", "folder/..", "folder/./child", "folder/", ""] {
            XCTAssertThrowsError(try ManagedModelInstallStore.sourceReference(repo: "owner/model", file: nil, subfolder: selection), selection)
        }
        XCTAssertThrowsError(try ManagedModelInstallStore.sourceReference(repo: "owner/model", file: "model.gguf", subfolder: "checkpoint"))
        XCTAssertThrowsError(try ManagedModelInstallStore.sourceReference(repo: "owner/model", file: "../model.gguf", subfolder: nil))
        XCTAssertThrowsError(try ManagedModelInstallStore.sourceReference(repo: "owner/model", file: "model.safetensors", subfolder: nil))
    }

    func testCacheSelectionKeepsNestedCheckpointAndFileIdentity() {
        let base = "/cache/models--owner--model/snapshots/\(revisionA)"
        let root = ManagedModelInstallStore.cacheSelection(path: base, repo: "owner/model")
        XCTAssertEqual(root?.revision, revisionA)
        XCTAssertNil(root?.file)
        XCTAssertNil(root?.subfolder)
        let checkpoint = ManagedModelInstallStore.cacheSelection(path: base + "/checkpoints/small", repo: "owner/model")
        XCTAssertEqual(checkpoint?.subfolder, "checkpoints/small")
        XCTAssertNil(checkpoint?.file)
        let file = ManagedModelInstallStore.cacheSelection(path: base + "/gguf/model-Q4.gguf", repo: "owner/model")
        XCTAssertEqual(file?.file, "gguf/model-Q4.gguf")
        XCTAssertNil(file?.subfolder)
        XCTAssertNil(ManagedModelInstallStore.cacheSelection(path: base, repo: "other/model"))
        XCTAssertNil(ManagedModelInstallStore.cacheSelection(path: "/cache/models--owner--model/snapshots/main", repo: "owner/model"))
        XCTAssertNil(ManagedModelInstallStore.cacheSelection(path: "/cache/models--owner--model/refs/main", repo: "owner/model"))
    }

    func testChangedManagedFilesLoseRecordedRevisionAttribution() async throws {
        let root = try temporaryRoot()
        let model = try createModel(at: root.appendingPathComponent("managed/owner/model/\(revisionA)"))
        let json = JSONStore<ManagedModelInstall>(fileURL: root.appendingPathComponent("managed.json"))
        let store = ManagedModelInstallStore(store: json)
        let before = try ManagedModelInstallStore.signature(path: model.path)
        let recorded = install(path: model.path, revision: revisionA, signature: before)
        try await store.record(recorded)
        let confirmed = try await store.verifiedRecord(path: model.path, signature: before)
        XCTAssertEqual(confirmed?.revision, revisionA)
        try Data("modified".utf8).write(to: model.appendingPathComponent("model.safetensors"), options: .atomic)
        let changed = try ManagedModelInstallStore.signature(path: model.path)
        let unconfirmed = try await store.verifiedRecord(path: model.path, signature: changed)
        XCTAssertNil(unconfirmed)
        XCTAssertEqual(try json.load(), [recorded])
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))
    }

    func testUpdateReviewCannotReplaceASelectedCheckpointWithRepositoryRoot() throws {
        let previous = ModelUpdatePreviousModel(repo: "owner/model", path: "/models/old", signature: "old",
            revision: revisionA, displayName: "Small", canQuarantine: false, retentionReason: nil,
            subfolder: "checkpoints/small")
        let matching = ModelUpdateReview(id: UUID(), repo: "owner/model", previous: previous,
            resolution: try resolution(subfolder: previous.subfolder), targetRevision: revisionB,
            destinationPath: "/models/new/checkpoints/small", previewHash: "preview", endpointSummary: [])
        XCTAssertNoThrow(try matching.validate())
        let otherCheckpoint = ModelUpdateReview(id: UUID(), repo: matching.repo, previous: previous,
            resolution: try resolution(subfolder: nil), targetRevision: revisionB,
            destinationPath: "/models/new", previewHash: "preview", endpointSummary: [])
        XCTAssertThrowsError(try otherCheckpoint.validate())
    }

    func testGGUFFileSelectionRequiresPreparationEvenWhenRepositoryIsTaggedMLX() throws {
        let previous = ModelUpdatePreviousModel(repo: "owner/model", path: "/models/old.gguf", signature: "old",
            revision: revisionA, displayName: "GGUF", canQuarantine: false, retentionReason: nil, file: "model.gguf")
        let review = ModelUpdateReview(id: UUID(), repo: "owner/model", previous: previous,
            resolution: try resolution(subfolder: nil, file: previous.file), targetRevision: revisionB,
            destinationPath: "/models/new", previewHash: "preview", endpointSummary: [])
        XCTAssertThrowsError(try review.validate())
    }

    func testLedgerPreservesOtherInstallationsAndReplacesOnlySamePath() async throws {
        let root = try temporaryRoot()
        let store = ManagedModelInstallStore(store: JSONStore(fileURL: root.appendingPathComponent("managed.json")))
        let first = install(path: root.appendingPathComponent("old").path, revision: revisionA, signature: "old")
        let second = install(path: root.appendingPathComponent("new").path, revision: revisionB, signature: "new")
        try await store.record(first)
        try await store.record(second)
        let replacement = install(path: first.path, revision: revisionA, signature: "refreshed")
        try await store.record(replacement)
        let records = try await store.records()
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains(second))
        XCTAssertTrue(records.contains(replacement))
        try await store.forget(path: first.path)
        let remaining = try await store.records()
        XCTAssertEqual(remaining, [second])
    }

    func testInvalidProvenanceDoesNotOverwriteLedger() async throws {
        let root = try temporaryRoot()
        let json = JSONStore<ManagedModelInstall>(fileURL: root.appendingPathComponent("managed.json"))
        let existing = install(path: root.appendingPathComponent("old").path, revision: revisionA, signature: "old")
        try json.replaceAll([existing])
        let store = ManagedModelInstallStore(store: json)
        for invalid in [install(path: existing.path, revision: "main", signature: "new"),
                        install(path: "relative/model", revision: revisionB, signature: "new"),
                        install(path: existing.path, revision: revisionB, signature: "")] {
            do { try await store.record(invalid); XCTFail("Invalid provenance was saved") } catch {}
        }
        XCTAssertEqual(try json.load(), [existing])
    }

    func testCorruptLedgerBlocksRecordAndForgetWithoutReplacingSourceBytes() async throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("managed.json")
        let corrupt = Data("invalid ledger".utf8)
        try corrupt.write(to: url)
        let store = ManagedModelInstallStore(store: JSONStore(fileURL: url))
        do { try await store.record(install(path: root.appendingPathComponent("new").path, revision: revisionB, signature: "new")); XCTFail("Corrupt ledger was overwritten") } catch {}
        do { try await store.forget(path: root.appendingPathComponent("old").path); XCTFail("Corrupt ledger was overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testSymlinkedLedgerNeverChangesItsTarget() async throws {
        let root = try temporaryRoot()
        let target = root.appendingPathComponent("owned.json")
        let existing = install(path: root.appendingPathComponent("old").path, revision: revisionA, signature: "old")
        let targetStore = JSONStore<ManagedModelInstall>(fileURL: target)
        try targetStore.replaceAll([existing])
        let link = root.appendingPathComponent("managed.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = ManagedModelInstallStore(store: JSONStore(fileURL: link))
        do { try await store.record(install(path: root.appendingPathComponent("new").path, revision: revisionB, signature: "new")); XCTFail("Ledger link was followed for a write") } catch {}
        do { try await store.forget(path: existing.path); XCTFail("Ledger link was followed for a write") } catch {}
        XCTAssertEqual(try targetStore.load(), [existing])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testLedgerWriteFailurePreservesPreviousRecords() async throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("managed.json")
        let existing = install(path: root.appendingPathComponent("old").path, revision: revisionA, signature: "old")
        let json = JSONStore<ManagedModelInstall>(fileURL: url)
        try json.replaceAll([existing])
        let store = ManagedModelInstallStore(store: JSONStore(fileURL: url, replaceItem: { _, _ in
            throw ModelUpdateError.invalid("Storage unavailable")
        }))
        do { try await store.record(install(path: root.appendingPathComponent("new").path, revision: revisionB, signature: "new")); XCTFail("Write failure was ignored") } catch {}
        do { try await store.forget(path: existing.path); XCTFail("Write failure was ignored") } catch {}
        XCTAssertEqual(try json.load(), [existing])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(leftovers, ["managed.json"])
    }

    private func resolution(subfolder: String?, file: String? = nil) throws -> IntakeResolution {
        let object: [String: Any] = [
            "schema": "intake/1", "source": ["input": "owner/model", "repo": "owner/model", "revision": "main",
                "resolved_revision": revisionB, "file": file.map { $0 as Any } ?? NSNull(), "subfolder": subfolder.map { $0 as Any } ?? NSNull(), "url": "https://huggingface.co/owner/model"],
            "verdict": "already_mlx", "reasons": [], "backend": "mlx-lm", "backend_installed": true,
            "model_type": "llama", "components": [], "custom_code": false, "gated": false, "bytes": 8,
            "files": ["safetensors": 1, "gguf": [], "python": []], "warnings": []
        ]
        return try JSONDecoder().decode(IntakeResolution.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func source(_ repo: String, revision: String, resolved: String? = nil, file: String? = nil, subfolder: String? = nil) -> IntakeSource {
        IntakeSource(input: repo, repo: repo, revision: revision, file: file, subfolder: subfolder,
            url: "https://huggingface.co/\(repo)", resolvedRevision: resolved)
    }

    private func install(path: String, revision: String, signature: String) -> ManagedModelInstall {
        ManagedModelInstall(repo: "owner/model", revision: revision, path: path, signature: signature,
            installedAt: Date(timeIntervalSince1970: 10))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("managed-install-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func createModel(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url.appendingPathComponent("config.json"))
        try Data("original".utf8).write(to: url.appendingPathComponent("model.safetensors"))
        return url
    }
}
