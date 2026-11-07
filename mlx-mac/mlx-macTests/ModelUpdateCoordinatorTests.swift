import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class ModelUpdateCoordinatorTests: XCTestCase {
    func testSupersededPreparationDiscardsOnlyItsOwnCapturedReview() async throws {
        let a = try makeReview()
        let b = try makeReview(previous: .init(repo: "org/model", path: "/models/old-b", signature: "old-b-signature",
            revision: oldRevision, displayName: "Model B", canQuarantine: true, retentionReason: nil))
        let harness = try Harness(review: b)
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }
        let captures = ModelUpdateCaptures()
        let gate = UpdatePreparationGate()
        let entered = expectation(description: "first preparation entered")
        var api = harness.api
        api.candidates = { _ in [a.previous, b.previous] }
        api.prepare = { _, candidate in
            if candidate == a.previous { entered.fulfill(); await gate.wait() }
            let review = candidate == a.previous ? a : b
            captures.insert(review.id, endpoints: [], cleanup: nil)
            return review
        }
        let originalRevalidate = api.revalidate
        api.revalidate = { review, mutation in
            guard captures[review.id] != nil else { throw ModelUpdateError.unavailable }
            try await originalRevalidate(review, mutation)
        }
        let coordinator = ModelUpdateCoordinator(api: api, store: harness.store)
        coordinator.onDiscardReview = { captures.discard($0) }
        await coordinator.begin(repo: "org/model")
        let first = Task { await coordinator.selectPrevious(path: a.previous.path) }
        await fulfillment(of: [entered], timeout: 2)
        defer { gate.open() }
        await coordinator.selectPrevious(path: b.previous.path)
        XCTAssertEqual(coordinator.review?.id, b.id)
        gate.open()
        await first.value
        XCTAssertNil(captures[a.id])
        XCTAssertNotNil(captures[b.id])
        let completed = await coordinator.confirm(quarantinePrevious: false)
        XCTAssertTrue(completed, coordinator.error ?? "")
    }

    private let oldRevision = String(repeating: "a", count: 40)
    private let newRevision = String(repeating: "b", count: 40)

    func testOpeningAlertRequiresSelectingPreviousModelAndNeverMutates() async throws {
        let harness = try Harness(review: makeReview())
        let coordinator = makeCoordinator(harness)
        await coordinator.begin(repo: "org/model", alertID: UUID())
        XCTAssertEqual(coordinator.candidates, [harness.review.previous])
        XCTAssertNil(coordinator.selectedPreviousPath)
        XCTAssertNil(coordinator.review)
        XCTAssertTrue(harness.events.isEmpty)
        coordinator.close()
        XCTAssertTrue(coordinator.records.isEmpty)
        XCTAssertTrue(harness.events.isEmpty)
    }

    func testRelatedRepositoriesCannotBeSelectedAsPreviousVersion() async throws {
        let harness = try Harness(review: makeReview())
        let original = harness.review.previous
        harness.candidates = [original, .init(repo: "other/model", path: "/models/other", signature: "s", revision: oldRevision,
            displayName: "Other", canQuarantine: false, retentionReason: "Owned by another app")]
        let coordinator = makeCoordinator(harness)
        await coordinator.begin(repo: "org/model")
        XCTAssertEqual(coordinator.candidates, [original])
        await coordinator.selectPrevious(path: "/models/other")
        XCTAssertNil(coordinator.review)
    }

    func testSuccessfulUpdatePersistsEachStageBeforeMutationAndDismissesLast() async throws {
        let harness = try Harness(review: makeReview())
        let coordinator = makeCoordinator(harness)
        let alertID = UUID()
        var completed: [UUID] = []
        coordinator.onCompletion = { id in
            let record = try? harness.store.load().first
            XCTAssertEqual(record?.state, .completed)
            completed.append(id)
            harness.events.append("dismiss")
        }
        await prepare(coordinator, alertID: alertID)
        let success = await coordinator.confirm(quarantinePrevious: true)
        XCTAssertTrue(success)
        XCTAssertEqual(harness.events, ["check-download", "download", "check-verify", "verify", "check-switch", "switch", "check-quarantine", "quarantine", "dismiss"])
        XCTAssertEqual(completed, [alertID])
        XCTAssertEqual(coordinator.activeRecord?.stage, .completed)
        XCTAssertEqual(coordinator.activeRecord?.state, .completed)
        XCTAssertNotNil(coordinator.activeRecord?.installation)
        XCTAssertEqual(try harness.store.load().first, coordinator.activeRecord)
    }

    func testVerificationFailureKeepsAlertAndNeverSwitchesOrCleansUp() async throws {
        let harness = try Harness(review: makeReview())
        harness.failure = "verify"
        let coordinator = makeCoordinator(harness)
        var dismissed = false
        coordinator.onCompletion = { _ in dismissed = true }
        await prepare(coordinator, alertID: UUID())
        let success = await coordinator.confirm(quarantinePrevious: true)
        XCTAssertFalse(success)
        XCTAssertFalse(dismissed)
        XCTAssertEqual(harness.events, ["check-download", "download", "check-verify", "verify"])
        XCTAssertEqual(coordinator.activeRecord?.state, .failed)
        XCTAssertEqual(coordinator.activeRecord?.stage, .verifying)
        XCTAssertNotNil(coordinator.activeRecord?.installation)
        XCTAssertEqual(try harness.store.load().first?.state, .failed)
    }

    func testFreshCleanupDriftAfterSwitchPreventsQuarantineAndKeepsAlert() async throws {
        let harness = try Harness(review: makeReview())
        harness.failure = "check-quarantine"
        let coordinator = makeCoordinator(harness)
        var dismissed = false
        coordinator.onCompletion = { _ in dismissed = true }
        await prepare(coordinator, alertID: UUID())
        let success = await coordinator.confirm(quarantinePrevious: true)
        XCTAssertFalse(success)
        XCTAssertFalse(dismissed)
        XCTAssertTrue(harness.events.contains("switch"))
        XCTAssertFalse(harness.events.contains("quarantine"))
        XCTAssertEqual(coordinator.activeRecord?.stage, .quarantining)
        XCTAssertEqual(coordinator.activeRecord?.state, .failed)
    }

    func testSwitchFailureNeverQuarantinesPreviousVersion() async throws {
        let harness = try Harness(review: makeReview())
        harness.failure = "switch"
        let coordinator = makeCoordinator(harness)
        await prepare(coordinator)
        let success = await coordinator.confirm(quarantinePrevious: true)
        XCTAssertFalse(success)
        XCTAssertFalse(harness.events.contains("quarantine"))
        XCTAssertEqual(coordinator.activeRecord?.stage, .switching)
    }

    func testKeepingPreviousVersionSkipsCleanupEntirely() async throws {
        let harness = try Harness(review: makeReview())
        let coordinator = makeCoordinator(harness)
        await prepare(coordinator)
        let success = await coordinator.confirm(quarantinePrevious: false)
        XCTAssertTrue(success)
        XCTAssertFalse(harness.events.contains("check-quarantine"))
        XCTAssertFalse(harness.events.contains("quarantine"))
        XCTAssertEqual(coordinator.activeRecord?.quarantinePrevious, false)
    }

    func testExternalCacheCleanupCannotBeConfirmed() async throws {
        let previous = ModelUpdatePreviousModel(repo: "org/model", path: "/cache/models--org--model/snapshots/\(oldRevision)",
            signature: "old-signature", revision: oldRevision, displayName: "Model", canQuarantine: false,
            retentionReason: "This shared cache stays in place.")
        let harness = try Harness(review: makeReview(previous: previous))
        let coordinator = makeCoordinator(harness)
        await prepare(coordinator, path: previous.path)
        let success = await coordinator.confirm(quarantinePrevious: true)
        XCTAssertFalse(success)
        XCTAssertTrue(harness.events.isEmpty)
        XCTAssertTrue(coordinator.records.isEmpty)
    }

    func testWrongDownloadRevisionCannotReachVerification() async throws {
        let harness = try Harness(review: makeReview())
        harness.installation = .init(repo: "org/model", revision: oldRevision, path: harness.review.destinationPath, signature: "wrong")
        let coordinator = makeCoordinator(harness)
        await prepare(coordinator)
        let success = await coordinator.confirm(quarantinePrevious: true)
        XCTAssertFalse(success)
        XCTAssertEqual(harness.events, ["check-download", "download"])
        XCTAssertEqual(coordinator.activeRecord?.state, .failed)
    }

    func testPrepareCannotSubstituteAnotherPreviousInstallation() async throws {
        let harness = try Harness(review: makeReview())
        let original = harness.review.previous
        let other = ModelUpdatePreviousModel(repo: original.repo, path: "/models/other-old", signature: "other-signature",
            revision: oldRevision, displayName: "Other local version", canQuarantine: true, retentionReason: nil)
        harness.candidates = [other]
        let coordinator = makeCoordinator(harness)
        await coordinator.begin(repo: "org/model")
        await coordinator.selectPrevious(path: other.path)
        XCTAssertNil(coordinator.review)
        XCTAssertNotNil(coordinator.error)
        XCTAssertTrue(harness.events.isEmpty)
    }

    func testInterruptedUpdateLoadsWithoutRepeatingAnyOperation() async throws {
        let harness = try Harness(review: makeReview())
        let date = Date(timeIntervalSince1970: 10)
        let record = ModelUpdateRecord(id: harness.review.id, alertID: UUID(), review: harness.review,
            quarantinePrevious: true, createdAt: date, updatedAt: date, stage: .switching,
            state: .inProgress, installation: harness.installation, error: nil)
        try harness.store.replaceAll([record])
        let coordinator = makeCoordinator(harness)
        await coordinator.waitForHistory()
        XCTAssertEqual(coordinator.records.first?.state, .interrupted)
        XCTAssertEqual(coordinator.records.first?.stage, .switching)
        XCTAssertEqual(coordinator.records.first?.installation, record.installation)
        XCTAssertTrue(harness.events.isEmpty)
        XCTAssertEqual(try harness.store.load().first?.state, .interrupted)
    }

    func testCorruptHistoryPreventsAcceptingAnotherUpdate() async throws {
        let harness = try Harness(review: makeReview())
        try Data("corrupt".utf8).write(to: harness.store.url)
        let coordinator = makeCoordinator(harness)
        await coordinator.begin(repo: "org/model")
        XCTAssertNotNil(coordinator.persistenceError)
        XCTAssertTrue(coordinator.candidates.isEmpty)
        let success = await coordinator.confirm(quarantinePrevious: false)
        XCTAssertFalse(success)
        XCTAssertTrue(harness.events.isEmpty)
        XCTAssertEqual(try String(contentsOf: harness.store.url, encoding: .utf8), "corrupt")
    }

    func testFailedStageWritePreventsDownload() async throws {
        let harness = try Harness(review: makeReview())
        try harness.store.replaceAll([])
        let failingStore = JSONStore<ModelUpdateRecord>(fileURL: harness.store.url, replaceItem: { old, staged in
            let records = try JSONDecoder().decode([ModelUpdateRecord].self, from: Data(contentsOf: staged))
            if records.first?.stage == .downloading { throw ModelUpdateError.invalid("Storage is unavailable") }
            _ = try FileManager.default.replaceItemAt(old, withItemAt: staged)
        })
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }
        let coordinator = ModelUpdateCoordinator(api: harness.api, store: failingStore)
        await prepare(coordinator)
        let success = await coordinator.confirm(quarantinePrevious: true)
        XCTAssertFalse(success)
        XCTAssertTrue(harness.events.isEmpty)
        XCTAssertNotNil(coordinator.persistenceError)
        XCTAssertEqual(try harness.store.load().first?.stage, .accepted)
    }

    func testReviewRejectsMutableOrUnchangedRevisionAndOtherRepository() throws {
        let valid = try makeReview()
        XCTAssertNoThrow(try valid.validate())
        let mutable = ModelUpdateReview(id: UUID(), repo: valid.repo, previous: valid.previous,
            resolution: valid.resolution, targetRevision: "main", destinationPath: valid.destinationPath,
            previewHash: "h", endpointSummary: [])
        XCTAssertThrowsError(try mutable.validate())
        let same = ModelUpdateReview(id: UUID(), repo: valid.repo, previous: valid.previous,
            resolution: valid.resolution, targetRevision: oldRevision, destinationPath: valid.destinationPath,
            previewHash: "h", endpointSummary: [])
        XCTAssertThrowsError(try same.validate())
        let unresolved = ModelUpdateReview(id: UUID(), repo: valid.repo, previous: valid.previous,
            resolution: valid.resolution, targetRevision: String(repeating: "c", count: 40), destinationPath: valid.destinationPath,
            previewHash: "h", endpointSummary: [])
        XCTAssertThrowsError(try unresolved.validate())
        let other = ModelUpdateReview(id: UUID(), repo: "other/model", previous: valid.previous,
            resolution: valid.resolution, targetRevision: newRevision, destinationPath: valid.destinationPath,
            previewHash: "h", endpointSummary: [])
        XCTAssertThrowsError(try other.validate())
    }

    private func makeCoordinator(_ harness: Harness) -> ModelUpdateCoordinator {
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }
        return ModelUpdateCoordinator(api: harness.api, store: harness.store)
    }

    private func prepare(_ coordinator: ModelUpdateCoordinator, alertID: UUID? = nil, path: String = "/models/old") async {
        await coordinator.begin(repo: "org/model", alertID: alertID)
        await coordinator.selectPrevious(path: path)
        XCTAssertNotNil(coordinator.review)
    }

    private func makeReview(previous: ModelUpdatePreviousModel? = nil) throws -> ModelUpdateReview {
        let source = """
        {"schema":"intake/1","source":{"input":"org/model","repo":"org/model","revision":"main","resolved_revision":"\(newRevision)","file":null,"url":"https://huggingface.co/org/model"},
         "verdict":"already_mlx","reasons":[],"backend":"mlx-lm","backend_installed":true,"model_type":"llama","components":[],"task":null,"custom_code":false,"gated":false,"bytes":100,"download_bytes":100,"files":{"safetensors":1,"gguf":[],"python":[]},"warnings":[]}
        """
        let resolution = try JSONDecoder().decode(IntakeResolution.self, from: Data(source.utf8))
        return ModelUpdateReview(id: UUID(), repo: "org/model", previous: previous ?? .init(repo: "org/model", path: "/models/old",
            signature: "old-signature", revision: oldRevision, displayName: "Model", canQuarantine: true, retentionReason: nil),
            resolution: resolution, targetRevision: newRevision, destinationPath: "/models/new", previewHash: "preview", endpointSummary: ["Chat · 8090"])
    }

    @MainActor
    private final class Harness {
        let root: URL
        let store: JSONStore<ModelUpdateRecord>
        let review: ModelUpdateReview
        var candidates: [ModelUpdatePreviousModel]
        var installation: ModelUpdateInstallation
        var events: [String] = []
        var failure: String?

        init(review: ModelUpdateReview) throws {
            self.review = review
            candidates = [review.previous]
            installation = .init(repo: review.repo, revision: review.targetRevision, path: review.destinationPath, signature: "new-signature")
            root = FileManager.default.temporaryDirectory.appendingPathComponent("model-update-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = JSONStore(fileURL: root.appendingPathComponent("updates.json"))
        }

        var api: ModelUpdateAPI {
            ModelUpdateAPI(candidates: { _ in self.candidates }, prepare: { _, _ in self.review },
                revalidate: { _, mutation in
                    let stage: ModelUpdateStage
                    let name: String
                    switch mutation {
                    case .download: stage = .downloading; name = "download"
                    case .verify: stage = .verifying; name = "verify"
                    case .switchEndpoints: stage = .switching; name = "switch"
                    case .quarantinePrevious: stage = .quarantining; name = "quarantine"
                    }
                    XCTAssertEqual(try self.store.load().first?.stage, stage)
                    try self.record("check-" + name)
                }, download: { _ in try self.record("download"); return self.installation },
                verify: { _, _ in try self.record("verify") },
                switchEndpoints: { _, _ in try self.record("switch") },
                quarantinePrevious: { _, _ in try self.record("quarantine") })
        }

        func record(_ event: String) throws {
            events.append(event)
            if failure == event { throw ModelUpdateError.invalid("Failed \(event)") }
        }
    }
}

@MainActor
private final class UpdatePreparationGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
