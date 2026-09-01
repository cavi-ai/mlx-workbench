import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class ReclaimAdvisorTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000_000)

    // MARK: - Quarantine guard (mirrors mlx_workbench/quarantine.py)

    func testGuardRejectsNonGGUF() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("model.bin")
        try Data("x".utf8).write(to: file)

        XCTAssertThrowsError(try Quarantine.guardPath(file.path, roots: [root.path])) { error in
            guard case QuarantineError.notGGUF = error else {
                return XCTFail("expected notGGUF, got \(error)")
            }
        }
    }

    func testGuardRejectsPathOutsideRoots() throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        let file = outside.appendingPathComponent("model.gguf")
        try Data("x".utf8).write(to: file)

        XCTAssertThrowsError(try Quarantine.guardPath(file.path, roots: [root.path])) { error in
            guard case QuarantineError.outsideRoots = error else {
                return XCTFail("expected outsideRoots, got \(error)")
            }
        }
    }

    func testGuardRejectsMissingFile() throws {
        let root = try makeRoot()
        XCTAssertThrowsError(try Quarantine.guardPath(root.appendingPathComponent("gone.gguf").path, roots: [root.path])) { error in
            guard case QuarantineError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    func testMoveQuarantinesGGUFAndAppendsLedger() throws {
        let root = try makeRoot()
        let quarantineDir = try makeRoot().appendingPathComponent("quarantine")
        let file = root.appendingPathComponent("redundant.gguf")
        try Data("weights".utf8).write(to: file)

        let record = try Quarantine.move(
            target: file.path,
            roots: [root.path],
            quarantineDir: quarantineDir.path,
            now: now
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.to))
        XCTAssertEqual(record.from, Quarantine.resolve(file.path))
        XCTAssertEqual(record.bytes, 7)
        XCTAssertTrue(record.to.contains("redundant.gguf"))

        let ledger = Quarantine.ledger(quarantineDir: quarantineDir.path)
        XCTAssertEqual(ledger, [record])
    }

    func testMoveRefusesAlreadyQuarantined() throws {
        let root = try makeRoot()
        let quarantineDir = root.appendingPathComponent("quarantine")
        try FileManager.default.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
        let file = quarantineDir.appendingPathComponent("already.gguf")
        try Data("x".utf8).write(to: file)

        XCTAssertThrowsError(try Quarantine.move(target: file.path, roots: [root.path], quarantineDir: quarantineDir.path, now: now)) { error in
            guard case QuarantineError.alreadyQuarantined = error else {
                return XCTFail("expected alreadyQuarantined, got \(error)")
            }
        }
    }

    func testMoveCollisionGetsNumberedSuffix() throws {
        let root = try makeRoot()
        let quarantineDir = try makeRoot().appendingPathComponent("quarantine")
        let first = root.appendingPathComponent("one.gguf")
        let second = root.appendingPathComponent("two.gguf")
        // Same file name from two sources collides on the stamped destination.
        let subdir = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let secondSameName = subdir.appendingPathComponent("one.gguf")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: secondSameName)

        let recordOne = try Quarantine.move(target: first.path, roots: [root.path], quarantineDir: quarantineDir.path, now: now)
        let recordTwo = try Quarantine.move(target: secondSameName.path, roots: [root.path], quarantineDir: quarantineDir.path, now: now)

        XCTAssertNotEqual(recordOne.to, recordTwo.to)
        XCTAssertEqual(try String(contentsOfFile: recordOne.to), "a")
        XCTAssertEqual(try String(contentsOfFile: recordTwo.to), "b")
    }

    // MARK: - Advisor detectors

    func testStaleUsesUsageEvidenceOverMtime() {
        let model = makeModel(path: "/m/old.gguf", modifiedDaysAgo: 10)
        let staleDate = now.addingTimeInterval(-90 * 86_400)
        let opportunities = ReclaimAdvisor.opportunities(
            snapshot: snapshot(with: [model]),
            duplicates: [],
            lastUsedByPath: ["/m/old.gguf": staleDate],
            isVerified: { _ in false },
            occupiedPaths: [],
            now: now
        )

        XCTAssertEqual(opportunities.count, 1)
        XCTAssertEqual(opportunities.first?.kind, .stale)
        XCTAssertEqual(opportunities.first?.confidence, .high)
        XCTAssertTrue(opportunities.first?.actionable == true)
    }

    func testStaleFallsBackToMtimeAtReviewConfidence() {
        let model = makeModel(path: "/m/old.gguf", modifiedDaysAgo: 200)
        let opportunities = ReclaimAdvisor.opportunities(
            snapshot: snapshot(with: [model]),
            duplicates: [],
            lastUsedByPath: [:],
            isVerified: { _ in false },
            occupiedPaths: [],
            now: now
        )

        XCTAssertEqual(opportunities.first?.kind, .stale)
        XCTAssertEqual(opportunities.first?.confidence, .review)
    }

    func testRecentlyUsedModelIsNotStale() {
        let model = makeModel(path: "/m/fresh.gguf", modifiedDaysAgo: 200)
        let opportunities = ReclaimAdvisor.opportunities(
            snapshot: snapshot(with: [model]),
            duplicates: [],
            lastUsedByPath: ["/m/fresh.gguf": now.addingTimeInterval(-5 * 86_400)],
            isVerified: { _ in false },
            occupiedPaths: [],
            now: now
        )
        XCTAssertTrue(opportunities.isEmpty)
    }

    func testOccupiedPathsAreNeverReclaimed() {
        let model = makeModel(path: "/m/serving.gguf", modifiedDaysAgo: 500)
        let opportunities = ReclaimAdvisor.opportunities(
            snapshot: snapshot(with: [model]),
            duplicates: [],
            lastUsedByPath: [:],
            isVerified: { _ in false },
            occupiedPaths: ["/m/serving.gguf"],
            now: now
        )
        XCTAssertTrue(opportunities.isEmpty)
    }

    func testSupersededByVerifiedSibling() {
        let q4 = makeModel(path: "/m/q4", modelKey: "qwen", quantization: "Q4_K_M")
        let q8 = makeModel(path: "/m/q8", modelKey: "qwen", quantization: "Q8_0")
        let fp16 = makeModel(path: "/m/fp16", modelKey: "qwen", quantization: "fp16")
        let opportunities = ReclaimAdvisor.opportunities(
            snapshot: snapshot(with: [q4, q8, fp16]),
            duplicates: [],
            lastUsedByPath: [:],
            isVerified: { $0 == "/m/q8" },
            occupiedPaths: [],
            now: now
        )

        let superseded = opportunities.filter { $0.kind == .supersededVariant }
        XCTAssertEqual(superseded.map(\.paths), [["/m/q4"]])
        // fp16 (16 bits > 8) is not superseded by the verified 8-bit sibling.
        XCTAssertFalse(superseded.contains { $0.paths == ["/m/fp16"] })
    }

    func testUnverifiedSiblingNeverSupersedes() {
        let q4 = makeModel(path: "/m/q4", modelKey: "qwen", quantization: "Q4_K_M")
        let q8 = makeModel(path: "/m/q8", modelKey: "qwen", quantization: "Q8_0")
        let opportunities = ReclaimAdvisor.opportunities(
            snapshot: snapshot(with: [q4, q8]),
            duplicates: [],
            lastUsedByPath: [:],
            isVerified: { _ in false },
            occupiedPaths: [],
            now: now
        )
        XCTAssertFalse(opportunities.contains { $0.kind == .supersededVariant })
    }

    func testQuantBitsParsing() {
        XCTAssertEqual(ReclaimAdvisor.quantBits("Q4_K_M"), 4)
        XCTAssertEqual(ReclaimAdvisor.quantBits("8-bit"), 8)
        XCTAssertEqual(ReclaimAdvisor.quantBits("fp16"), 16)
        XCTAssertEqual(ReclaimAdvisor.quantBits(nil), 0)
        XCTAssertEqual(ReclaimAdvisor.quantBits("unknown"), 0)
    }

    func testCrossRootDuplicatesFromScanGroups() {
        let group = DuplicateGroup(
            kind: "exact", modelKey: "qwen", quantization: "Q4",
            quantizations: nil, reclaimableBytes: 4_000_000_000,
            keep: "/a/qwen.gguf", redundant: ["/b/qwen.gguf"],
            members: nil, count: nil, groupId: "g1"
        )
        let opportunities = ReclaimAdvisor.opportunities(
            snapshot: nil,
            duplicates: [group],
            lastUsedByPath: [:],
            isVerified: { _ in false },
            occupiedPaths: [],
            now: now
        )

        XCTAssertEqual(opportunities.first?.kind, .crossRootDuplicate)
        XCTAssertEqual(opportunities.first?.paths, ["/b/qwen.gguf"])
        XCTAssertEqual(opportunities.first?.bytes, 4_000_000_000)
        XCTAssertEqual(opportunities.first?.confidence, .high)
    }

    // MARK: - Coordinator

    func testPreviewConfirmMovesFilesAndDropsOpportunity() throws {
        let root = try makeRoot()
        let quarantine = try makeRoot()
        let file = root.appendingPathComponent("stale.gguf")
        try Data("weights".utf8).write(to: file)

        let coordinator = ReclaimCoordinator(now: { self.now })
        coordinator.quarantineDir = { quarantine.path }
        coordinator.ggufRoots = { [root.path] }
        coordinator.analyze(
            snapshot: nil,
            duplicates: [],
            lastUsedByPath: [:],
            isVerified: { _ in false },
            occupiedPaths: []
        )
        // Inject a stale opportunity directly for the apply path.
        let opportunity = ReclaimOpportunity(
            kind: .stale, paths: [file.path], bytes: 7,
            evidence: "test", confidence: .high, actionable: true
        )
        coordinator.setOpportunitiesForTesting([opportunity])
        coordinator.preview(selected: [opportunity.id])

        let plan = try XCTUnwrap(coordinator.plan)
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.totalBytes, 7)

        let results = coordinator.confirm(previewHash: plan.previewHash)

        XCTAssertEqual(results?.count, 1)
        XCTAssertNil(results?.first?.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(coordinator.opportunities.isEmpty)
    }

    func testConfirmRejectsHashMismatch() throws {
        let coordinator = ReclaimCoordinator(now: { self.now })
        let opportunity = ReclaimOpportunity(
            kind: .stale, paths: ["/m/x.gguf"], bytes: 1,
            evidence: "test", confidence: .high, actionable: true
        )
        coordinator.setOpportunitiesForTesting([opportunity])
        coordinator.preview(selected: [opportunity.id])

        XCTAssertNil(coordinator.confirm(previewHash: "bogus"))
        XCTAssertEqual(coordinator.lastError, ReclaimError.previewHashMismatch.errorDescription)
    }

    func testPerItemFailureDoesNotStopTheBatch() throws {
        let root = try makeRoot()
        let quarantine = try makeRoot()
        let good = root.appendingPathComponent("good.gguf")
        try Data("ok".utf8).write(to: good)

        let coordinator = ReclaimCoordinator(now: { self.now })
        coordinator.quarantineDir = { quarantine.path }
        coordinator.ggufRoots = { [root.path] }
        let goodOpportunity = ReclaimOpportunity(kind: .stale, paths: [good.path], bytes: 2, evidence: "", confidence: .high, actionable: true)
        let badOpportunity = ReclaimOpportunity(kind: .stale, paths: [root.appendingPathComponent("gone.gguf").path], bytes: 2, evidence: "", confidence: .high, actionable: true)
        coordinator.setOpportunitiesForTesting([goodOpportunity, badOpportunity])
        coordinator.preview(selected: [goodOpportunity.id, badOpportunity.id])

        let results = try XCTUnwrap(coordinator.confirm(previewHash: coordinator.plan!.previewHash))

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.filter { $0.error == nil }.count, 1)
        XCTAssertEqual(results.filter { $0.error != nil }.count, 1)
    }

    func testBadgeTextOnlyAboveThreshold() {
        let coordinator = ReclaimCoordinator(now: { self.now })
        let small = ReclaimOpportunity(kind: .stale, paths: ["/m/a.gguf"], bytes: 1_000, evidence: "", confidence: .high, actionable: true)
        coordinator.setOpportunitiesForTesting([small])
        XCTAssertNil(coordinator.badgeText)

        let big = ReclaimOpportunity(kind: .stale, paths: ["/m/b.gguf"], bytes: ReclaimAdvisor.badgeThresholdBytes, evidence: "", confidence: .high, actionable: true)
        coordinator.setOpportunitiesForTesting([big])
        XCTAssertNotNil(coordinator.badgeText)
    }

    // MARK: - HF-cache prune

    func testCacheCheckSurfacesFindingsAndReclaimableBytes() async {
        let coordinator = ReclaimCoordinator(now: { self.now })
        coordinator.doctorScan = {
            DoctorResult(
                findings: [DoctorFinding(path: "/cache/a", kind: "incomplete", message: nil, size: 2_000)],
                prune_count: 1, preview_hash: nil, reclaimedBytes: nil, removed: nil
            )
        }

        await coordinator.checkCache()

        XCTAssertEqual(coordinator.cacheFindings.count, 1)
        XCTAssertEqual(coordinator.cacheReclaimableBytes, 2_000)
    }

    func testCachePruneConfirmRequiresPreviewHash() async {
        let coordinator = ReclaimCoordinator(now: { self.now })
        coordinator.doctorPruneConfirm = { _ in
            DoctorResult(findings: [], prune_count: 0, preview_hash: nil, reclaimedBytes: nil, removed: [])
        }

        let confirmed = await coordinator.confirmCachePrune()

        XCTAssertFalse(confirmed)
        XCTAssertEqual(coordinator.lastError, ReclaimError.previewHashMismatch.errorDescription)
    }

    func testCachePrunePreviewConfirmFlow() async {
        let coordinator = ReclaimCoordinator(now: { self.now })
        coordinator.doctorPrunePreview = {
            DoctorResult(findings: nil, prune_count: 2, preview_hash: "hash-1", reclaimedBytes: 5_000, removed: nil)
        }
        coordinator.doctorPruneConfirm = { hash in
            XCTAssertEqual(hash, "hash-1")
            return DoctorResult(
                findings: [], prune_count: 2, preview_hash: nil, reclaimedBytes: 5_000,
                removed: [PrunedItem(repo: "a", removed: true, bytes: 5_000)]
            )
        }

        await coordinator.previewCachePrune()
        XCTAssertEqual(coordinator.cachePruneHash, "hash-1")

        let confirmed = await coordinator.confirmCachePrune()

        XCTAssertTrue(confirmed)
        XCTAssertNil(coordinator.cachePruneHash)
        XCTAssertEqual(coordinator.cachePruneNote, "Pruned 1 cache item(s).")
    }

    // MARK: - Helpers

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-reclaim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeModel(
        path: String,
        modelKey: String = "model",
        quantization: String? = nil,
        modifiedDaysAgo: Int = 0
    ) -> LibraryModel {
        let modified = Int(now.timeIntervalSince1970) - modifiedDaysAgo * 86_400
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: 1000,
            modifiedAt: modifiedDaysAgo == 0 ? nil : modified, shard: nil,
            modelKey: modelKey, architecture: nil, quantization: quantization, parameters: nil,
            structure: nil, signature: nil, companion: nil, readable: true,
            status: "ready", outputs: [], tensorCount: nil, error: nil
        )
        return LibraryModel(item: item)
    }

    private func snapshot(with models: [LibraryModel]) -> LibrarySnapshot {
        LibrarySnapshot(
            models: models,
            groups: [],
            hardware: HardwareProfile.current(),
            generatedAt: now
        )
    }
}
