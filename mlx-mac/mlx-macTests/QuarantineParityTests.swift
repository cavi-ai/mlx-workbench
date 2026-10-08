import Foundation
import AppKit
import SwiftUI
import XCTest

@testable import mlx_workbench

/// Parity cases mirroring tests/test_quarantine.py plus ledger ordering —
/// the Swift port must refuse and record exactly like the Python original.
final class QuarantineParityTests: XCTestCase {
    func testConvertedSourceCleanupPreservesSharedBlobs() throws {
        let fixture = try cleanupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let plan = try ConvertedSourceCleanup.preview(workflow: fixture.workflow, roots: [fixture.root.path], protected: [])
        XCTAssertTrue(plan.paths.contains(fixture.repo.path))
        XCTAssertTrue(plan.paths.contains(fixture.blob.path))
        let other = fixture.root.appendingPathComponent("hub/models--other--model/snapshots/abc")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: other.appendingPathComponent("model.safetensors"), withDestinationURL: fixture.blob)
        let shared = try ConvertedSourceCleanup.preview(workflow: fixture.workflow, roots: [fixture.root.path], protected: [])
        XCTAssertFalse(shared.paths.contains(fixture.blob.path))
        XCTAssertTrue(shared.paths.contains(fixture.repo.path))
    }

    func testConvertedSourceCleanupRefusesActiveSourcesAndAdditionalRevisions() throws {
        let fixture = try cleanupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertThrowsError(try ConvertedSourceCleanup.preview(workflow: fixture.workflow, roots: [fixture.root.path], protected: [fixture.repo.path]))
        try FileManager.default.createDirectory(at: fixture.repo.appendingPathComponent("snapshots/another"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try ConvertedSourceCleanup.preview(workflow: fixture.workflow, roots: [fixture.root.path], protected: []))
    }

    func testConvertedSourceCleanupRechecksBeforeTrashAndRecordsRecoveryLocations() throws {
        let fixture = try cleanupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let roots = [fixture.root.path]
        let plan = try ConvertedSourceCleanup.preview(workflow: fixture.workflow, roots: roots, protected: [])
        let journal = fixture.root.appendingPathComponent("journal.json")
        XCTAssertThrowsError(try ConvertedSourceCleanup.apply(plan, workflow: fixture.workflow, roots: roots, protected: [fixture.repo.path], journalURL: journal))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.blob.path))
        let trashRoot = fixture.root.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        let moves = try ConvertedSourceCleanup.apply(plan, workflow: fixture.workflow, roots: roots, protected: [], journalURL: journal) { source in
            let destination = trashRoot.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        XCTAssertEqual(moves.count, 2)
        XCTAssertTrue(moves.allSatisfy { $0.to != nil })
        XCTAssertEqual(try JSONStore<ConvertedSourceMove>(fileURL: journal).load().count, 2)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as! [[String: Any]]
        XCTAssertEqual(saved.compactMap { $0["bytes"] as? Int64 }.reduce(0, +), 14)
        XCTAssertEqual(Set(saved.compactMap { $0["batchID"] as? String }).count, 1)
        XCTAssertEqual(saved.first?["workflowID"] as? String, fixture.workflow.id.uuidString)
        XCTAssertNotNil(saved.first?["movedAt"])
        XCTAssertEqual(saved.compactMap { $0["trashFingerprint"] as? String }.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.repo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workflow.outputPath + "/model.safetensors"))
    }

    func testConvertedSourceCleanupRefusesOutputChangedAfterVerification() throws {
        let fixture = try cleanupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.setAttributes([.modificationDate: fixture.workflow.updatedAt.addingTimeInterval(1)], ofItemAtPath: fixture.workflow.outputPath + "/model.safetensors")
        XCTAssertThrowsError(try ConvertedSourceCleanup.preview(workflow: fixture.workflow, roots: [fixture.root.path], protected: []))
    }

    func testConvertedSourceCleanupSupportsOnlyTheConfiguredCacheAlias() throws {
        let fixture = try cleanupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alias = fixture.root.appendingPathComponent("cache-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.repo.deletingLastPathComponent())
        let receipt = URL(fileURLWithPath: fixture.workflow.jobReceipt!)
        var payload = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as! [String: Any]
        payload["argv"] = ["convert", "--hf-path", alias.path + "/models--org--source/snapshots/abc", "--mlx-path", fixture.workflow.outputPath]
        try JSONSerialization.data(withJSONObject: payload).write(to: receipt)
        XCTAssertThrowsError(try ConvertedSourceCleanup.preview(workflow: fixture.workflow, roots: [fixture.root.path], protected: []))
        let plan = try ConvertedSourceCleanup.preview(workflow: fixture.workflow, roots: [fixture.root.path, alias.path], protected: [])
        XCTAssertTrue(plan.paths.contains(fixture.repo.path))
        XCTAssertFalse(plan.paths.contains(alias.path))
    }

    private func cleanupFixture() throws -> (root: URL, repo: URL, blob: URL, workflow: ConversionWorkflow) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = root.appendingPathComponent("hub/models--org--source")
        let source = repo.appendingPathComponent("snapshots/abc")
        let blob = root.appendingPathComponent("hub/blobs/ab/abcdef")
        let output = root.appendingPathComponent("output/model-MLX-4bit")
        for url in [source, blob.deletingLastPathComponent(), output] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data("source weights".utf8).write(to: blob)
        try fm.createSymbolicLink(at: source.appendingPathComponent("model.safetensors"), withDestinationURL: blob)
        try Data("{\"quantization\":{\"bits\":4}}".utf8).write(to: output.appendingPathComponent("config.json"))
        try Data("converted weights".utf8).write(to: output.appendingPathComponent("model.safetensors"))
        let receipt = root.appendingPathComponent("receipt.json")
        let payload: [String: Any] = ["exit_status":"done", "out":output.path, "argv":["convert", "--hf-path", source.path, "--mlx-path", output.path]]
        try JSONSerialization.data(withJSONObject: payload).write(to: receipt)
        let timestamp = Date().addingTimeInterval(1)
        let workflow = ConversionWorkflow(id: UUID(), sourcePath: "hf://org/source", sourceModelKey: nil, sourceSignature: nil,
            outputPath: output.path, previewHash: "hash", jobReceipt: receipt.path, completedModelPath: output.path,
            state: .verified, serveState: .idle, message: nil, errorMessage: nil, createdAt: timestamp, updatedAt: timestamp, lastKnownAgentState: "done")
        return (root, repo, blob, workflow)
    }

    func testSourceRecoveryRestoresBatchAndRecordsHistory() throws {
        let fixture = try cleanupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fm = FileManager.default
        let roots = [fixture.root.path], journal = fixture.root.appendingPathComponent("journal.json")
        let trash = fixture.root.appendingPathComponent("trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let plan = try ConvertedSourceCleanup.preview(workflow: fixture.workflow, roots: roots, protected: [])
        let moves = try ConvertedSourceCleanup.apply(plan, workflow: fixture.workflow, roots: roots, protected: [], journalURL: journal) { source in
            let destination = trash.appendingPathComponent(source.lastPathComponent)
            try fm.moveItem(at: source, to: destination)
            return destination
        }
        let restore = try ConvertedSourceRecovery.preview(ids: moves.map(\.id), roots: roots, journalURL: journal, trashRoots: [trash.path])
        XCTAssertEqual(restore.bytes, 14)
        try ConvertedSourceRecovery.restore(restore, roots: roots, journalURL: journal, trashRoots: [trash.path])
        XCTAssertEqual(try Data(contentsOf: fixture.blob), Data("source weights".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.repo.appendingPathComponent("snapshots/abc/model.safetensors")), Data("source weights".utf8))
        XCTAssertTrue(try JSONStore<ConvertedSourceMove>(fileURL: journal).load().allSatisfy { $0.restoredAt != nil })
        XCTAssertTrue(fm.fileExists(atPath: fixture.workflow.outputPath + "/model.safetensors"))
    }

    func testSourceRecoveryRefusesConflictsChangedTrashAndChangedRoots() throws {
        let fixture = try cleanupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fm = FileManager.default, journal = fixture.root.appendingPathComponent("journal.json")
        let original = fixture.root.appendingPathComponent("old.gguf"), trash = fixture.root.appendingPathComponent("trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let payload = trash.appendingPathComponent("old.gguf")
        try Data("weights".utf8).write(to: payload)
        let move = ConvertedSourceMove(id: "legacy", from: original.path, to: payload.path)
        try JSONStore<ConvertedSourceMove>(fileURL: journal).upsert(move, id: \.id)
        let roots = [fixture.root.path]
        let plan = try ConvertedSourceRecovery.preview(ids: [move.id], roots: roots, journalURL: journal, trashRoots: [trash.path])
        try fm.createSymbolicLink(atPath: original.path, withDestinationPath: "/missing")
        XCTAssertThrowsError(try ConvertedSourceRecovery.restore(plan, roots: roots, journalURL: journal, trashRoots: [trash.path]))
        try fm.removeItem(at: original)
        XCTAssertThrowsError(try ConvertedSourceRecovery.restore(plan, roots: [], journalURL: journal, trashRoots: [trash.path]))
        try Data("changed".utf8).write(to: payload)
        XCTAssertThrowsError(try ConvertedSourceRecovery.restore(plan, roots: roots, journalURL: journal, trashRoots: [trash.path]))
        XCTAssertTrue(fm.fileExists(atPath: payload.path))
        XCTAssertFalse(fm.fileExists(atPath: original.path))
    }

    func testSourceRecoveryFencesJournalAndTrashPaths() throws {
        let fixture = try cleanupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = fixture.root.appendingPathComponent("journal.json"), fakeTrash = fixture.root.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let move = ConvertedSourceMove(id: "bad", from: fixture.root.appendingPathComponent("old.gguf").path, to: fixture.blob.path)
        try JSONStore<ConvertedSourceMove>(fileURL: journal).upsert(move, id: \.id)
        XCTAssertThrowsError(try ConvertedSourceRecovery.preview(ids: [move.id], roots: [fixture.root.path], journalURL: journal, trashRoots: [fakeTrash.path]))
        XCTAssertThrowsError(try ConvertedSourceRecovery.preview(ids: [move.id], roots: [], journalURL: journal, trashRoots: [fixture.root.path]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.blob.path))
    }

    func testSourceHistoryKeepsLegacyMissingAndRestoredStatesDistinct() throws {
        let root = try makeRoot(), fm = FileManager.default
        let journal = root.appendingPathComponent("journal.json"), trash = root.appendingPathComponent("trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let present = trash.appendingPathComponent("present.gguf")
        try Data("weights".utf8).write(to: present)
        var restored = ConvertedSourceMove(id: "restored", from: root.appendingPathComponent("restored.gguf").path, to: trash.appendingPathComponent("gone.gguf").path)
        restored.restoredAt = now
        let records = [
            ConvertedSourceMove(id: "legacy", from: root.appendingPathComponent("present.gguf").path, to: present.path),
            ConvertedSourceMove(id: "missing", from: root.appendingPathComponent("missing.gguf").path, to: trash.appendingPathComponent("missing.gguf").path),
            ConvertedSourceMove(id: "interrupted", from: root.appendingPathComponent("interrupted.gguf").path, to: nil), restored
        ]
        try JSONStore<ConvertedSourceMove>(fileURL: journal).replaceAll(records)
        let history = try ConvertedSourceRecovery.history(roots: [root.path], journalURL: journal, trashRoots: [trash.path])
        let states = Dictionary(uniqueKeysWithValues: history.flatMap(\.items).map { ($0.id, $0.state) })
        XCTAssertEqual(states["legacy"], .inTrash)
        XCTAssertEqual(states["missing"], .unavailable)
        XCTAssertEqual(states["interrupted"], .incomplete)
        XCTAssertEqual(states["restored"], .restored)
        XCTAssertTrue(history.allSatisfy { $0.movedAt == nil && $0.bytes == nil })
        let preview = try ConvertedSourceRecovery.preview(ids: ["legacy"], roots: [root.path], journalURL: journal, trashRoots: [trash.path])
        XCTAssertTrue(preview.includesLegacyRecords)
        XCTAssertEqual(preview.bytes, 7)
    }

    func testSourceRecoveryRefusesRecordedIdentityDriftAndSymlinkedParents() throws {
        let root = try makeRoot(), fm = FileManager.default
        let journal = root.appendingPathComponent("journal.json"), trash = root.appendingPathComponent("trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let payload = trash.appendingPathComponent("old.gguf"), destination = root.appendingPathComponent("models/old.gguf")
        try Data("weights".utf8).write(to: payload)
        var move = ConvertedSourceMove(id: "recorded", from: destination.path, to: payload.path)
        move.trashFingerprint = try ConvertedSourceRecovery.snapshot(payload.path).fingerprint
        try JSONStore<ConvertedSourceMove>(fileURL: journal).upsert(move, id: \.id)
        let roots = [root.path]
        let plan = try ConvertedSourceRecovery.preview(ids: [move.id], roots: roots, journalURL: journal, trashRoots: [trash.path])
        let elsewhere = root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: destination.deletingLastPathComponent(), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try ConvertedSourceRecovery.restore(plan, roots: roots, journalURL: journal, trashRoots: [trash.path]))
        try fm.removeItem(at: destination.deletingLastPathComponent())
        try Data("changed".utf8).write(to: payload)
        XCTAssertThrowsError(try ConvertedSourceRecovery.preview(ids: [move.id], roots: roots, journalURL: journal, trashRoots: [trash.path]))
        XCTAssertTrue(fm.fileExists(atPath: payload.path))
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
    }

    @MainActor
    func testSourceCleanupDiscoveryAndRestoreCancelLeaveFilesUntouched() async throws {
        let fixture = try cleanupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fm = FileManager.default, journal = fixture.root.appendingPathComponent("journal.json")
        let trash = fixture.root.appendingPathComponent("trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let reclaim = ReclaimCoordinator(sourceJournalURL: journal, sourceTrashRoots: [trash.path])
        reclaim.mlxRoots = { [fixture.root.path] }
        await reclaim.checkSources(workflows: [fixture.workflow])
        XCTAssertEqual(reclaim.sourceCandidates.count, 1)
        XCTAssertEqual(reclaim.sourceCandidates.first?.bytes, 14)
        reclaim.protectedPaths = { [fixture.repo.path] }
        await reclaim.checkSources(workflows: [fixture.workflow])
        XCTAssertNil(reclaim.sourceCandidates.first?.bytes)
        XCTAssertNotNil(reclaim.sourceCandidates.first?.reason)
        let payload = trash.appendingPathComponent("legacy.gguf")
        try Data("weights".utf8).write(to: payload)
        let move = ConvertedSourceMove(id: "cancel", from: fixture.root.appendingPathComponent("legacy.gguf").path, to: payload.path)
        try JSONStore<ConvertedSourceMove>(fileURL: journal).upsert(move, id: \.id)
        await reclaim.previewSourceRestore(ids: [move.id])
        XCTAssertNotNil(reclaim.sourceRestorePlan)
        reclaim.cancelSourceRestore()
        await reclaim.confirmSourceRestore()
        XCTAssertTrue(fm.fileExists(atPath: payload.path))
        XCTAssertFalse(fm.fileExists(atPath: move.from))
        XCTAssertNil(try JSONStore<ConvertedSourceMove>(fileURL: journal).load().first?.restoredAt)
    }

    @MainActor
    func testSourceCleanupSectionRendersDiscoveryAndHistory() async throws {
        let fixture = try cleanupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = fixture.root.appendingPathComponent("journal.json"), trash = fixture.root.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let payload = trash.appendingPathComponent("earlier.gguf")
        try Data("weights".utf8).write(to: payload)
        let record = ConvertedSourceMove(id: "earlier", from: fixture.root.appendingPathComponent("earlier.gguf").path, to: payload.path)
        try JSONStore<ConvertedSourceMove>(fileURL: journal).upsert(record, id: \.id)
        let reclaim = ReclaimCoordinator(sourceJournalURL: journal, sourceTrashRoots: [trash.path])
        reclaim.mlxRoots = { [fixture.root.path] }
        await reclaim.checkSources(workflows: [fixture.workflow])
        let api = ModelWorkflowAPI(convertPreview: { _, _, _ in [:] }, convertStart: { _, _, _, _ in [:] }, convertStatus: { [] },
            servePreview: { _, _, _ in [:] }, serveStart: { _, _, _, _ in [:] }, serveStatus: { [] }, serveStop: { _ in [:] })
        let workflows = ModelWorkflowCoordinator(api: api, persistence: ModelWorkflowPersistence(load: { [fixture.workflow] }, upsert: { _ in }))
        let view = NSHostingView(rootView: SourceCleanupSection(reclaim: reclaim, modelWorkflow: workflows, rescan: {}).padding(24).frame(width: 680).preferredColorScheme(.dark))
        view.setFrameSize(NSSize(width: 680, height: view.fittingSize.height))
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.bounds.height, 200)
        XCTAssertLessThan(view.bounds.height, 850)
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let attachment = XCTAttachment(data: try XCTUnwrap(image.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "Source cleanup discovery and legacy history"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000_000)

    private func modelFolder(in root: URL) throws -> URL {
        let model = root.appendingPathComponent("local-model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{\"quantization\":{\"bits\":4}}".utf8).write(to: model.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: model.appendingPathComponent("model.safetensors"))
        return model
    }

    func testModelFolderMoveRestoreAndTrashPreserveTypedLedger() throws {
        let root = try makeRoot()
        let model = try modelFolder(in: root)
        let quarantine = root.appendingPathComponent("quarantine").path
        let preview = try Quarantine.folderSnapshot(target: model.path, roots: [root.path], protected: [])
        XCTAssertEqual(preview.bytes, 34)
        let record = try Quarantine.moveFolder(expected: preview, roots: [root.path], protected: [], quarantineDir: quarantine)
        XCTAssertEqual(record.kind, .mlxDirectory)
        XCTAssertEqual(Quarantine.ledger(quarantineDir: quarantine).first, record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path))
        try Quarantine.restore(record)
        XCTAssertEqual(try Data(contentsOf: model.appendingPathComponent("model.safetensors")), Data("weights".utf8))
        let second = try Quarantine.moveFolder(expected: Quarantine.folderSnapshot(target: model.path, roots: [root.path], protected: []), roots: [root.path], protected: [], quarantineDir: quarantine)
        let snapshot = try Quarantine.trashSnapshot(second, quarantineDir: quarantine)
        let trash = root.appendingPathComponent("test-trash")
        let result = try Quarantine.trash(second, quarantineDir: quarantine, expected: snapshot, trashFile: { try FileManager.default.moveItem(at: $0, to: trash) })
        XCTAssertNil(result.ledgerWarning)
        XCTAssertEqual(result.bytes, preview.bytes)
        XCTAssertNotNil(Quarantine.ledger(quarantineDir: quarantine).first?.deletedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("model.safetensors").path))
    }

    func testLibraryTrashRechecksIdentityRootsAndProtectionBeforeMoving() throws {
        let root = try makeRoot()
        let model = try modelFolder(in: root)
        let roots = [root.path]
        let plan = try Quarantine.previewModelTrash(model.path, roots: roots, protected: [])
        XCTAssertEqual(plan.snapshot.path, model.path)
        var attempted = false
        let move: (URL) throws -> URL = { source in
            attempted = true
            let destination = root.appendingPathComponent("test-trash")
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        XCTAssertThrowsError(try Quarantine.trashModel(plan, roots: [], protected: [], trash: move))
        XCTAssertThrowsError(try Quarantine.trashModel(plan, roots: roots, protected: [model.path], trash: move))
        try Data("changed weights".utf8).write(to: model.appendingPathComponent("model.safetensors"))
        XCTAssertThrowsError(try Quarantine.trashModel(plan, roots: roots, protected: [], trash: move))
        XCTAssertFalse(attempted)
        let fresh = try Quarantine.previewModelTrash(model.path, roots: roots, protected: [])
        let destination = try Quarantine.trashModel(fresh, roots: roots, protected: [], trash: move)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("model.safetensors")), Data("changed weights".utf8))
    }

    func testLibraryTrashMovesWholeCacheRepositoryAndRefusesExternalLinks() throws {
        let root = try makeRoot()
        let repo = root.appendingPathComponent("models--org--model")
        let snapshot = repo.appendingPathComponent("snapshots/rev")
        let blob = repo.appendingPathComponent("blobs/weights")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: blob)
        let link = snapshot.appendingPathComponent("model.safetensors")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../blobs/weights")
        let roots = [root.path]
        let plan = try Quarantine.previewModelTrash(snapshot.path, roots: roots, protected: [])
        XCTAssertTrue(plan.includesCacheRepository)
        XCTAssertEqual(plan.snapshot.path, repo.path)
        XCTAssertThrowsError(try Quarantine.previewModelTrash(snapshot.path, roots: roots, protected: ["org/model"]))
        XCTAssertThrowsError(try Quarantine.previewModelTrash(snapshot.path, roots: roots, protected: [snapshot.path]))
        XCTAssertThrowsError(try Quarantine.previewModelTrash(snapshot.path, roots: [repo.path], protected: []))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/passwd")
        XCTAssertThrowsError(try Quarantine.previewModelTrash(snapshot.path, roots: roots, protected: []))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../blobs/weights")
        let fresh = try Quarantine.previewModelTrash(snapshot.path, roots: roots, protected: [])
        let destination = try Quarantine.trashModel(fresh, roots: roots, protected: []) { source in
            let destination = root.appendingPathComponent("test-trash")
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("snapshots/rev/model.safetensors")), Data("weights".utf8))
    }

    func testLibraryTrashProtectsGGUFAndRefusesChangedFile() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("model.gguf")
        try Data("weights".utf8).write(to: file)
        let roots = [root.path]
        let plan = try Quarantine.previewModelTrash(file.path, roots: roots, protected: [])
        XCTAssertThrowsError(try Quarantine.previewModelTrash(file.path, roots: roots, protected: [file.path]))
        try Data("changed".utf8).write(to: file)
        XCTAssertThrowsError(try Quarantine.trashModel(plan, roots: roots, protected: [], trash: { _ in XCTFail("changed file reached Trash"); return file }))
    }

    func testRemovalStatusRequiresAnExplicitFleetAndModelIdentities() throws {
        XCTAssertThrowsError(try WorkbenchAPI.servingPathsForRemoval(from: [:]))
        XCTAssertThrowsError(try WorkbenchAPI.servingPathsForRemoval(from: ["servers": [["state": "running"]]]))
        XCTAssertEqual(try WorkbenchAPI.servingPathsForRemoval(from: ["servers": []]), [])
        XCTAssertEqual(try WorkbenchAPI.servingPathsForRemoval(from: ["servers": [["path": "/m/model", "state": "running"]]]), ["/m/model"])
    }

    @MainActor
    func testLibraryTrashReadsFreshServingStatusAndRefusesUnavailableStatus() async throws {
        let root = try makeRoot(), model = try modelFolder(in: root)
        let reclaim = ReclaimCoordinator()
        reclaim.mlxRoots = { [root.path] }
        await reclaim.previewLibraryTrash(model.path)
        XCTAssertNil(reclaim.libraryTrashPlan)
        XCTAssertNotNil(reclaim.lastError)
        var requests = 0
        reclaim.servingModelPaths = {
            requests += 1
            return requests == 1 ? [] : [model.path]
        }
        await reclaim.previewLibraryTrash(model.path)
        XCTAssertNotNil(reclaim.libraryTrashPlan)
        await reclaim.confirmLibraryTrash()
        XCTAssertEqual(requests, 2)
        XCTAssertNil(reclaim.libraryTrashPlan)
        XCTAssertNotNil(reclaim.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))
    }

    func testModelFolderRefusesRootsActiveDescendantsCacheLinksAndArbitraryDirectories() throws {
        let root = try makeRoot()
        let model = try modelFolder(in: root)
        XCTAssertThrowsError(try Quarantine.folderSnapshot(target: model.path, roots: [model.path], protected: []))
        XCTAssertThrowsError(try Quarantine.folderSnapshot(target: model.path, roots: [root.path], protected: [model.appendingPathComponent("model.safetensors").path]))
        XCTAssertThrowsError(try Quarantine.folderSnapshot(target: model.path, roots: [root.path], protected: [root.path]))
        let arbitrary = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: arbitrary, withIntermediateDirectories: true)
        XCTAssertThrowsError(try Quarantine.folderSnapshot(target: arbitrary.path, roots: [root.path], protected: []))
        let cache = root.appendingPathComponent("models--org--name/snapshots/revision")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: model, to: cache)
        XCTAssertThrowsError(try Quarantine.folderSnapshot(target: cache.path, roots: [root.path], protected: []))
        let link = model.appendingPathComponent("shared")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: arbitrary)
        XCTAssertThrowsError(try Quarantine.folderSnapshot(target: model.path, roots: [root.path], protected: []))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.linkItem(at: model.appendingPathComponent("model.safetensors"), to: root.appendingPathComponent("shared-weights"))
        XCTAssertThrowsError(try Quarantine.folderSnapshot(target: model.path, roots: [root.path], protected: []))
    }

    func testModelFolderConfirmRefusesContentAndProtectionDrift() throws {
        let root = try makeRoot()
        let model = try modelFolder(in: root)
        let preview = try Quarantine.folderSnapshot(target: model.path, roots: [root.path], protected: [])
        let quarantine = root.appendingPathComponent("quarantine").path
        XCTAssertThrowsError(try Quarantine.moveFolder(expected: preview, roots: [root.path], protected: [model.path], quarantineDir: quarantine))
        try Data("new".utf8).write(to: model.appendingPathComponent("new-file"))
        XCTAssertThrowsError(try Quarantine.moveFolder(expected: preview, roots: [root.path], protected: [], quarantineDir: quarantine))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))
    }

    func testModelFolderTrashRejectsChangedContentsAndUnrecordedDirectories() throws {
        let root = try makeRoot()
        let model = try modelFolder(in: root)
        let quarantine = root.appendingPathComponent("quarantine").path
        let preview = try Quarantine.folderSnapshot(target: model.path, roots: [root.path], protected: [])
        let record = try Quarantine.moveFolder(expected: preview, roots: [root.path], protected: [], quarantineDir: quarantine)
        let snapshot = try Quarantine.trashSnapshot(record, quarantineDir: quarantine)
        let weight = URL(fileURLWithPath: record.to).appendingPathComponent("model.safetensors")
        let date = try FileManager.default.attributesOfItem(atPath: weight.path)[.modificationDate]
        try Data("changed".utf8).write(to: weight)
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(date)], ofItemAtPath: weight.path)
        var attemptedTrash = false
        XCTAssertThrowsError(try Quarantine.trash(record, quarantineDir: quarantine, expected: snapshot, trashFile: { _ in attemptedTrash = true }))
        XCTAssertFalse(attemptedTrash)
        let forged = QuarantineRecord(movedAt: "unrecorded", from: record.from, to: record.to, bytes: record.bytes, kind: .mlxDirectory)
        XCTAssertThrowsError(try Quarantine.trashSnapshot(forged, quarantineDir: quarantine))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.to))
    }

    // MARK: - Guard parity

    func testRejectsTraversalOutOfARoot() throws {
        let root = try makeRoot()
        let models = root.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let secret = root.appendingPathComponent("secret.gguf")
        try Data("x".utf8).write(to: secret)

        XCTAssertThrowsError(
            try Quarantine.guardPath(models.appendingPathComponent("../secret.gguf").path, roots: [models.path])
        ) { error in
            guard case QuarantineError.outsideRoots = error else {
                return XCTFail("expected outsideRoots, got \(error)")
            }
        }
    }

    func testRejectsSiblingDirectoryThatSharesRootPrefix() throws {
        // /models2 must not pass a guard for /models.
        let base = try makeRoot()
        let models = base.appendingPathComponent("models")
        let sibling = base.appendingPathComponent("models2")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let file = sibling.appendingPathComponent("model.gguf")
        try Data("x".utf8).write(to: file)

        XCTAssertThrowsError(try Quarantine.guardPath(file.path, roots: [models.path])) { error in
            guard case QuarantineError.outsideRoots = error else {
                return XCTFail("expected outsideRoots, got \(error)")
            }
        }
    }

    func testAcceptsUppercaseGGUFSuffix() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("MODEL.GGUF")
        try Data("x".utf8).write(to: file)

        XCTAssertEqual(try Quarantine.guardPath(file.path, roots: [root.path]), Quarantine.resolve(file.path))
    }

    func testRejectsDirectoryNamedLikeAGGUf() throws {
        let root = try makeRoot()
        let directory = root.appendingPathComponent("bundle.gguf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try Quarantine.guardPath(directory.path, roots: [root.path])) { error in
            guard case QuarantineError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    // MARK: - Ledger ordering and limits

    func testLedgerListsNewestFirst() throws {
        let root = try makeRoot()
        let quarantineDir = try makeRoot()
        let first = root.appendingPathComponent("a.gguf")
        let second = root.appendingPathComponent("b.gguf")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)

        let earlier = now
        let later = now.addingTimeInterval(60)
        try Quarantine.move(target: first.path, roots: [root.path], quarantineDir: quarantineDir.path, now: earlier)
        try Quarantine.move(target: second.path, roots: [root.path], quarantineDir: quarantineDir.path, now: later)

        let records = Quarantine.ledger(quarantineDir: quarantineDir.path)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records[0].from.hasSuffix("b.gguf"))
        XCTAssertTrue(records[1].from.hasSuffix("a.gguf"))
    }

    func testLedgerRespectsLimit() throws {
        let root = try makeRoot()
        let quarantineDir = try makeRoot()
        for index in 0..<3 {
            let file = root.appendingPathComponent("m\(index).gguf")
            try Data("x".utf8).write(to: file)
            try Quarantine.move(
                target: file.path, roots: [root.path],
                quarantineDir: quarantineDir.path, now: now.addingTimeInterval(TimeInterval(index))
            )
        }

        let records = Quarantine.ledger(quarantineDir: quarantineDir.path, limit: 2)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records[0].from.hasSuffix("m2.gguf"))
        XCTAssertTrue(records[1].from.hasSuffix("m1.gguf"))
    }

    func testEmptyLedgerForMissingDirectory() throws {
        let missing = try makeRoot().appendingPathComponent("nothing")
        XCTAssertEqual(Quarantine.ledger(quarantineDir: missing.path), [])
    }

    // MARK: - Restore (put back)

    func testRestoreMovesTheFileBackToItsOrigin() throws {
        let root = try makeRoot()
        let quarantineDir = try makeRoot()
        let file = root.appendingPathComponent("wanted.gguf")
        try Data("weights".utf8).write(to: file)

        let record = try Quarantine.move(target: file.path, roots: [root.path], quarantineDir: quarantineDir.path, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try Quarantine.restore(record)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file), Data("weights".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.to))
    }

    func testRestoreRefusesWhenTheOriginalLocationIsTaken() throws {
        let root = try makeRoot()
        let quarantineDir = try makeRoot()
        let file = root.appendingPathComponent("wanted.gguf")
        try Data("weights".utf8).write(to: file)
        let record = try Quarantine.move(target: file.path, roots: [root.path], quarantineDir: quarantineDir.path, now: now)
        // Someone re-downloaded a file at the original path since the move.
        try Data("new download".utf8).write(to: file)

        XCTAssertThrowsError(try Quarantine.restore(record)) { error in
            guard case QuarantineError.restoreBlocked = error else {
                return XCTFail("expected restoreBlocked, got \(error)")
            }
        }
        // Neither copy is touched.
        XCTAssertEqual(try Data(contentsOf: file), Data("new download".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.to))
    }

    func testRestoreRefusesWhenTheQuarantinedFileIsGone() throws {
        let record = QuarantineRecord(
            movedAt: "2026-09-10T00:00:00Z",
            from: "/tmp/never-was.gguf",
            to: "/tmp/also-gone.gguf",
            bytes: 1
        )

        XCTAssertThrowsError(try Quarantine.restore(record)) { error in
            guard case QuarantineError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    // MARK: - Symlink refusal (P1-6 parity with mlx_workbench/quarantine.py)

    func testMoveRefusesSymlinkedSource() throws {
        let root = try makeRoot()
        let models = root.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let real = root.appendingPathComponent("real").appendingPathComponent("x.gguf")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: real)
        let link = models.appendingPathComponent("x.gguf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(
            try Quarantine.move(target: link.path, roots: [models.path], quarantineDir: try makeRoot().path, now: now)
        ) { error in
            guard case QuarantineError.symlinkRefused = error else {
                return XCTFail("expected symlinkRefused, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: real), Data("x".utf8))
    }

    func testMoveRefusesSymlinkedQuarantineDir() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("dupe.gguf")
        try Data("x".utf8).write(to: file)
        let realHold = try makeRoot()
        let linkHold = try makeRoot().appendingPathComponent("hold")
        try FileManager.default.createSymbolicLink(at: linkHold, withDestinationURL: realHold)

        XCTAssertThrowsError(
            try Quarantine.move(target: file.path, roots: [root.path], quarantineDir: linkHold.path, now: now)
        ) { error in
            guard case QuarantineError.symlinkRefused = error else {
                return XCTFail("expected symlinkRefused, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRestoreRefusesSymlinkAtTheOriginalLocation() throws {
        let root = try makeRoot()
        let quarantineDir = try makeRoot()
        let file = root.appendingPathComponent("wanted.gguf")
        try Data("weights".utf8).write(to: file)
        let record = try Quarantine.move(target: file.path, roots: [root.path], quarantineDir: quarantineDir.path, now: now)
        // The original spot now holds a symlink instead of the gone file.
        let decoy = try makeRoot().appendingPathComponent("decoy.gguf")
        try Data("decoy".utf8).write(to: decoy)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: decoy)

        XCTAssertThrowsError(try Quarantine.restore(record)) { error in
            guard case QuarantineError.symlinkRefused = error else {
                return XCTFail("expected symlinkRefused, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: decoy), Data("decoy".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.to))
    }

    func testTrashMovesOnlyPreviewedFileAndMarksLedgerWithoutLosingHistory() throws {
        let root = try makeRoot()
        let hold = try makeRoot()
        let trash = try makeRoot()
        let file = root.appendingPathComponent("trash-me.gguf")
        try Data("weights".utf8).write(to: file)
        let record = try Quarantine.move(target: file.path, roots: [root.path], quarantineDir: hold.path)
        let preview = try Quarantine.trashSnapshot(record, quarantineDir: hold.path)
        let result = try Quarantine.trash(record, quarantineDir: hold.path, expected: preview, trashFile: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
        XCTAssertEqual(result.bytes, 7)
        XCTAssertNil(result.ledgerWarning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.to))
        XCTAssertEqual(try Data(contentsOf: trash.appendingPathComponent(URL(fileURLWithPath: record.to).lastPathComponent)), Data("weights".utf8))
        let history = try XCTUnwrap(Quarantine.ledger(quarantineDir: hold.path).first)
        XCTAssertEqual(history.from, file.path)
        XCTAssertNotNil(history.deletedAt)
    }

    func testTrashRefusesChangedFileAfterPreview() throws {
        let root = try makeRoot()
        let hold = try makeRoot()
        let file = root.appendingPathComponent("changed.gguf")
        try Data("weights".utf8).write(to: file)
        let record = try Quarantine.move(target: file.path, roots: [root.path], quarantineDir: hold.path)
        let preview = try Quarantine.trashSnapshot(record, quarantineDir: hold.path)
        try Data("replacement weights".utf8).write(to: URL(fileURLWithPath: record.to))
        XCTAssertThrowsError(try Quarantine.trash(record, quarantineDir: hold.path, expected: preview, trashFile: { _ in XCTFail("Changed file reached Trash") }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.to))
        XCTAssertNil(Quarantine.ledger(quarantineDir: hold.path).first?.deletedAt)
    }

    func testTrashRefusesOutsideLedgerDirectoriesAndSymlinks() throws {
        let hold = try makeRoot()
        let outside = try makeRoot().appendingPathComponent("outside.gguf")
        try Data("untouched".utf8).write(to: outside)
        let ledger = hold.appendingPathComponent(Quarantine.ledgerName)
        try Data("history".utf8).write(to: ledger)
        let directory = hold.appendingPathComponent("directory.gguf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = hold.appendingPathComponent("link.gguf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for path in [outside.path, ledger.path, directory.path, link.path, hold.appendingPathComponent("missing.gguf").path] {
            let record = QuarantineRecord(movedAt: "now", from: "/original.gguf", to: path, bytes: 9)
            XCTAssertThrowsError(try Quarantine.trashSnapshot(record, quarantineDir: hold.path))
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
        XCTAssertEqual(try Data(contentsOf: ledger), Data("history".utf8))
    }

    func testTrashFailureKeepsFileAndLedgerRestorable() throws {
        let root = try makeRoot()
        let hold = try makeRoot()
        let file = root.appendingPathComponent("wanted.gguf")
        try Data("weights".utf8).write(to: file)
        let record = try Quarantine.move(target: file.path, roots: [root.path], quarantineDir: hold.path)
        let preview = try Quarantine.trashSnapshot(record, quarantineDir: hold.path)
        XCTAssertThrowsError(try Quarantine.trash(record, quarantineDir: hold.path, expected: preview, trashFile: { _ in
            throw CocoaError(.fileWriteNoPermission)
        }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.to))
        XCTAssertEqual(Quarantine.ledger(quarantineDir: hold.path), [record])
        try Quarantine.restore(record)
        XCTAssertEqual(try Data(contentsOf: file), Data("weights".utf8))
    }

    func testTrashLedgerUpdateRefusesDirectoryRedirectedDuringMove() throws {
        let root = try makeRoot()
        let hold = try makeRoot()
        let outside = try makeRoot()
        let preserved = try makeRoot().appendingPathComponent("old-quarantine")
        let file = root.appendingPathComponent("wanted.gguf")
        try Data("weights".utf8).write(to: file)
        let record = try Quarantine.move(target: file.path, roots: [root.path], quarantineDir: hold.path)
        let preview = try Quarantine.trashSnapshot(record, quarantineDir: hold.path)
        let outsideLedger = outside.appendingPathComponent(Quarantine.ledgerName)
        let original = try Data(contentsOf: hold.appendingPathComponent(Quarantine.ledgerName))
        try original.write(to: outsideLedger)
        let result = try Quarantine.trash(record, quarantineDir: hold.path, expected: preview, trashFile: { url in
            try FileManager.default.moveItem(at: url, to: outside.appendingPathComponent(url.lastPathComponent))
            try FileManager.default.moveItem(at: hold, to: preserved)
            try FileManager.default.createSymbolicLink(at: hold, withDestinationURL: outside)
        })
        XCTAssertNotNil(result.ledgerWarning)
        XCTAssertEqual(try Data(contentsOf: outsideLedger), original, "A late root redirect must not write outside quarantine")
    }

    // MARK: - Helpers

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-quarantine-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
