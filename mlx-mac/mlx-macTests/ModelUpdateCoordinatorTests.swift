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

    func testExactGGUFFileRevisionCanBeReviewedWithoutAnIntakeHandoff() throws {
        let previous = ModelUpdatePreviousModel(repo: "org/model", path: "/models/old/model-Q4.gguf",
            signature: "old-source", revision: oldRevision, displayName: "Local GGUF", canQuarantine: false,
            retentionReason: "Provider cache", file: "model-Q4.gguf")
        let source = """
        {"schema":"intake/1","source":{"input":"org/model","repo":"org/model","revision":"main","resolved_revision":"\(newRevision)","file":"model-Q4.gguf","url":"https://huggingface.co/org/model"},
         "verdict":"gguf","reasons":[],"backend":null,"backend_installed":true,"model_type":null,"components":[],"task":null,"custom_code":false,"gated":false,"bytes":100,"download_bytes":100,"files":{"safetensors":0,"gguf":[{"name":"model-Q4.gguf","bytes":100}],"python":[]},"warnings":[]}
        """
        let resolution = try JSONDecoder().decode(IntakeResolution.self, from: Data(source.utf8))
        let review = ModelUpdateReview(id: UUID(), repo: previous.repo, previous: previous, resolution: resolution,
            targetRevision: newRevision, destinationPath: "/models/new/model-Q4.gguf", previewHash: "download", endpointSummary: [])
        XCTAssertNoThrow(try review.validate())
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

    func testConversionStopsAtPersistedPreparationReviewBeforeMutation() async throws {
        let review = try makeConversionReview()
        let harness = try Harness(review: review)
        let source = downloadedSource(review)
        var api = harness.api
        api.download = { _ in try harness.record("download"); return source }
        api.previewPreparation = { review, downloaded in
            XCTAssertEqual(try harness.store.load().first?.downloadedSource, downloaded)
            return self.preparation(review, source: downloaded)
        }
        api.prepareInstallation = { _, _, _ in try harness.record("convert"); return .installed(harness.installation) }
        let coordinator = ModelUpdateCoordinator(api: api, store: harness.store)
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }
        await prepare(coordinator)
        let downloaded = await coordinator.confirm(quarantinePrevious: true)
        XCTAssertFalse(downloaded)
        XCTAssertEqual(harness.events, ["check-download", "download"])
        XCTAssertEqual(coordinator.activeRecord?.stage, .awaitingPreparation)
        XCTAssertEqual(coordinator.protectedPaths.sorted(), [review.previous.path, review.sourceDirectory, review.destinationPath].sorted())
        let preview = try XCTUnwrap(coordinator.preparationReview)
        let completed = await coordinator.confirmPreparation(preview)
        XCTAssertTrue(completed, coordinator.error ?? "")
        XCTAssertEqual(harness.events, ["check-download", "download", "check-prepare", "convert", "check-verify", "verify", "check-switch", "switch", "check-quarantine", "quarantine"])
        XCTAssertEqual(coordinator.activeRecord?.downloadedSource, source)
        XCTAssertTrue(coordinator.protectedPaths.isEmpty)
    }

    func testBackendInstallationRequiresAnotherConcreteConversionConfirmation() async throws {
        let review = try makeConversionReview()
        let harness = try Harness(review: review), source = downloadedSource(review)
        var backend = preparation(review, source: source)
        backend.operation = .installBackend; backend.backendInstallID = "mlx-lm"
        backend.backendInstallation = .init(id: "mlx-lm", version: "1.0", package: "mlx_lm", target: "/runtime", network: ["pypi.org"])
        var api = harness.api
        api.download = { _ in source }
        api.previewPreparation = { _, _ in backend }
        api.prepareInstallation = { _, _, preview in
            if preview.operation == .installBackend { try harness.record("install"); return .review(self.preparation(review, source: source)) }
            try harness.record("convert"); return .installed(harness.installation)
        }
        let coordinator = ModelUpdateCoordinator(api: api, store: harness.store)
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }
        await prepare(coordinator)
        _ = await coordinator.confirm(quarantinePrevious: false)
        let installed = await coordinator.confirmPreparation(try XCTUnwrap(coordinator.preparationReview))
        XCTAssertFalse(installed)
        XCTAssertTrue(harness.events.contains("install"))
        XCTAssertFalse(harness.events.contains("convert"))
        XCTAssertFalse(harness.events.contains("verify"))
        XCTAssertEqual(coordinator.preparationReview?.operation, .convert)
        let completed = await coordinator.confirmPreparation(try XCTUnwrap(coordinator.preparationReview))
        XCTAssertTrue(completed, coordinator.error ?? "")
    }

    func testPreparationFailureKeepsOldVersionAlertAndDownloadedSource() async throws {
        let review = try makeConversionReview()
        let harness = try Harness(review: review), source = downloadedSource(review)
        var api = harness.api
        api.download = { _ in source }
        api.previewPreparation = { _, _ in self.preparation(review, source: source) }
        api.prepareInstallation = { _, _, _ in throw ModelUpdateError.invalid("Converter failed") }
        let coordinator = ModelUpdateCoordinator(api: api, store: harness.store)
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }
        var dismissed = false
        coordinator.onCompletion = { _ in dismissed = true }
        await prepare(coordinator, alertID: UUID())
        _ = await coordinator.confirm(quarantinePrevious: true)
        let completed = await coordinator.confirmPreparation(try XCTUnwrap(coordinator.preparationReview))
        XCTAssertFalse(completed)
        XCTAssertEqual(coordinator.activeRecord?.state, .failed)
        XCTAssertEqual(coordinator.activeRecord?.downloadedSource, source)
        XCTAssertFalse(harness.events.contains("switch"))
        XCTAssertFalse(harness.events.contains("quarantine"))
        XCTAssertFalse(dismissed)
    }

    func testRestartReconnectsPreparationOnlyAfterExplicitContinue() async throws {
        let review = try makeConversionReview(), source = downloadedSource(try makeConversionReview())
        let harness = try Harness(review: review)
        let actualSource = ModelUpdateInstallation(repo: review.repo, revision: review.targetRevision, path: review.downloadedModelPath,
            signature: source.signature, fetchReceipt: source.fetchReceipt, sourceFiles: [.init(path: review.downloadedModelPath, signature: source.signature)])
        let date = Date(timeIntervalSince1970: 10)
        var original = ModelUpdateRecord(id: review.id, alertID: nil, review: review, quarantinePrevious: false,
            createdAt: date, updatedAt: date, stage: .preparing, state: .inProgress, installation: nil, error: nil,
            downloadedSource: actualSource, preparation: preparation(review, source: actualSource))
        try harness.store.replaceAll([original])
        var api = harness.api
        api.recover = { record in
            try harness.record("recover")
            var result = record; result.preparation?.operation = .observeConversion
            return result
        }
        api.prepareInstallation = { _, _, preview in
            XCTAssertEqual(preview.operation, .observeConversion)
            try harness.record("observe"); return .installed(harness.installation)
        }
        let coordinator = ModelUpdateCoordinator(api: api, store: harness.store)
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }
        await coordinator.waitForHistory()
        XCTAssertTrue(harness.events.isEmpty)
        original = try XCTUnwrap(coordinator.resumableRecords.first)
        let resumed = await coordinator.resume(recordID: original.id)
        XCTAssertFalse(resumed)
        XCTAssertEqual(harness.events, ["recover"])
        XCTAssertEqual(coordinator.preparationReview?.operation, .observeConversion)
        let completed = await coordinator.confirmPreparation(try XCTUnwrap(coordinator.preparationReview))
        XCTAssertTrue(completed, coordinator.error ?? "")
        XCTAssertFalse(harness.events.contains("download"))
        XCTAssertEqual(harness.events.filter { $0 == "observe" }.count, 1)
    }

    func testCleanupRetryDoesNotRepeatVerificationOrEndpointSwitch() async throws {
        let harness = try Harness(review: makeReview())
        var api = harness.api
        api.recover = { $0 }
        let coordinator = ModelUpdateCoordinator(api: api, store: harness.store)
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }
        await prepare(coordinator)
        harness.failure = "quarantine"
        let first = await coordinator.confirm(quarantinePrevious: true)
        XCTAssertFalse(first)
        XCTAssertEqual(coordinator.activeRecord?.endpointsSwitched, true)
        harness.failure = nil; harness.events = []
        let completed = await coordinator.resume(recordID: try XCTUnwrap(coordinator.activeRecordID))
        XCTAssertTrue(completed, coordinator.error ?? "")
        XCTAssertEqual(harness.events, ["check-quarantine", "quarantine"])
        XCTAssertEqual(coordinator.activeRecord?.cleanupCompleted, true)
    }

    func testUnsupportedNewBitsRemainReviewableButCannotDownload() throws {
        let review = try makeConversionReview(bits: 5)
        XCTAssertNoThrow(try review.validate())
        XCTAssertEqual(review.missingSelectionReason, "Choose a bit width supported by this revision.")
        XCTAssertThrowsError(try review.validateForDownload())
    }

    func testPreparationRejectsChangedSourceProjectorAndDependencyReceiptCount() throws {
        let review = try makeConversionReview(), source = downloadedSource(try makeConversionReview())
        var prepared = preparation(review, source: source)
        prepared.projectorPath = "/unreviewed/mmproj.gguf"
        XCTAssertThrowsError(try prepared.validate(for: review))
        prepared.projectorPath = nil; prepared.dependencyFetchReceipts = ["/unexpected.json"]
        XCTAssertThrowsError(try prepared.validate(for: review))
    }

    func testPreparationPlanBindsRevisionSelectionProjectorAndDependencies() throws {
        let review = try makeConversionReview(), source = downloadedSource(try makeConversionReview())
        let valid: [String: Any] = ["out": review.destinationPath, "q_bits": 4,
            "source": ["path": review.downloadedModelPath, "fetch_receipt": source.fetchReceipt!,
                "origin": ["repo": review.repo, "revision": review.targetRevision, "additional_files": []]]]
        XCTAssertNoThrow(try AppHost.validateUpdateConversionSource(plan: valid, review: review, source: source, recipe: review.conversion!))
        for field in ["repo", "revision", "file", "subfolder", "additional_files"] {
            var changed = valid
            var details = changed["source"] as! [String: Any], origin = details["origin"] as! [String: Any]
            origin[field] = field == "additional_files" ? ["unreviewed.gguf"] : "changed"
            details["origin"] = origin; changed["source"] = details
            XCTAssertThrowsError(try AppHost.validateUpdateConversionSource(plan: changed, review: review, source: source, recipe: review.conversion!), field)
        }
    }

    func testUnknownPreviousRevisionRequiresExplicitSourceConfirmation() throws {
        var review = try makeConversionReview()
        let old = review.previous
        let previous = ModelUpdatePreviousModel(repo: old.repo, path: old.path, signature: old.signature, revision: nil,
            displayName: old.displayName, canQuarantine: false, retentionReason: "Source unrecorded", needsSourceConfirmation: true, isConverted: true)
        review = ModelUpdateReview(id: review.id, repo: review.repo, previous: previous, resolution: review.resolution,
            targetRevision: review.targetRevision, destinationPath: review.destinationPath, previewHash: review.previewHash,
            endpointSummary: [], conversion: review.conversion, downloadDirectory: review.sourceDirectory)
        XCTAssertNoThrow(try review.validate())
        XCTAssertNil(review.previous.revision)
        XCTAssertThrowsError(try review.validateForDownload())
        review.sourceConfirmed = true
        XCTAssertNoThrow(try review.validateForDownload())
        XCTAssertNil(review.previous.revision)
    }

    func testSourceDownloadCannotEncloseOrReplaceOldOrPreparedModel() throws {
        let original = try makeConversionReview()
        for path in [original.previous.path, original.previous.path + "/source", original.destinationPath + "/source", "/models"] {
            var changed = original; changed.downloadDirectory = path
            XCTAssertThrowsError(try changed.validate(), path)
        }
    }

    func testSwitchedEndpointReadbackRejectsPolicyAndProfileDrift() throws {
        let installed = ModelUpdateInstallation(repo: "org/model", revision: newRevision, path: "/models/new", signature: "new")
        let original = EndpointSlot(enabled: true, port: 8090, modelPath: "/models/old", memoryPolicy: .automatic)
        var current = original; current.modelPath = installed.path
        XCTAssertTrue(AppHost.matchesSwitchedUpdate(expected: [original], current: [current], installed: installed))
        current.port += 1
        XCTAssertFalse(AppHost.matchesSwitchedUpdate(expected: [original], current: [current], installed: installed))
        current = original; current.modelPath = installed.path; current.enabled = false
        XCTAssertFalse(AppHost.matchesSwitchedUpdate(expected: [original], current: [current], installed: installed))
        XCTAssertFalse(AppHost.matchesSwitchedUpdate(expected: [original], current: [current, original], installed: installed))
    }

    func testRawVisionGGUFUpdatePreservesRecordedProjectorAndCompanions() {
        let old = ModelUpdatePreviousModel(repo: "org/model", path: "/models/model.gguf", signature: "old", revision: oldRevision,
            displayName: "Vision GGUF", canQuarantine: true, retentionReason: nil, file: "model.gguf", requiresProjector: true,
            additionalFiles: ["mmproj.gguf", "support.gguf"], projectorFile: "mmproj.gguf")
        let selected = ModelUpdateGGUFSelection.bundle(previous: old, settings: .init(), main: "model.gguf",
            available: ["model.gguf", "mmproj.gguf", "support.gguf"])
        XCTAssertEqual(selected.projector, "mmproj.gguf")
        XCTAssertEqual(selected.additionalFiles, ["mmproj.gguf", "support.gguf"])
        XCTAssertTrue(selected.requiresProjector)
        let missing = ModelUpdateGGUFSelection.bundle(previous: old, settings: .init(), main: "model.gguf", available: ["model.gguf"])
        XCTAssertNil(missing.projector)
        XCTAssertTrue(missing.requiresProjector)
        XCTAssertTrue(missing.requiresCompanionSelection)
        let replacement = ModelUpdateGGUFSelection.bundle(previous: old,
            settings: .init(projectorFile: "new-projector.gguf", additionalFiles: ["new-support.gguf"]), main: "model.gguf",
            available: ["model.gguf", "new-projector.gguf", "new-support.gguf"])
        XCTAssertEqual(replacement.additionalFiles, ["new-projector.gguf", "new-support.gguf"])
        XCTAssertFalse(replacement.requiresCompanionSelection)
    }

    func testGenericGGUFCompanionIsNotRelabeledAsVisionProjector() {
        let old = ModelUpdatePreviousModel(repo: "org/model", path: "/models/main.gguf", signature: "old", revision: oldRevision,
            displayName: "Text model", canQuarantine: true, retentionReason: nil, file: "main.gguf", requiresProjector: false,
            additionalFiles: ["draft.gguf"])
        let selection = ModelUpdateGGUFSelection.bundle(previous: old, settings: .init(), main: "main.gguf", available: ["main.gguf", "draft.gguf"])
        XCTAssertNil(selection.projector)
        XCTAssertFalse(selection.requiresProjector)
        XCTAssertEqual(selection.additionalFiles, ["draft.gguf"])
    }

    func testSplitGGUFRequiresCompleteFirstShardSet() {
        let first = "nested/model-00001-of-00003.gguf"
        let files = [first, "nested/model-00002-of-00003.gguf", "nested/model-00003-of-00003.gguf"]
        let selection = ModelUpdateGGUFSelection.shards(main: first, available: files)
        XCTAssertEqual(selection.files, Array(files.dropFirst()))
        XCTAssertNil(selection.problem)
        XCTAssertNotNil(ModelUpdateGGUFSelection.shards(main: first, available: Array(files.prefix(2))).problem)
        XCTAssertNotNil(ModelUpdateGGUFSelection.shards(main: files[1], available: files).problem)
        XCTAssertNotNil(ModelUpdateGGUFSelection.shards(main: "model-00001-of-99999.gguf", available: []).problem)
        XCTAssertTrue(ModelUpdateGGUFSelection.shards(main: "ordinary.gguf", available: ["ordinary.gguf"]).files.isEmpty)
    }

    func testRecoveryRequiresASeparateConfirmationAndDoesNotReplayOnPreview() async throws {
        let harness = try Harness(review: makeReview())
        let date = Date()
        let record = ModelUpdateRecord(id: harness.review.id, alertID: nil, review: harness.review, quarantinePrevious: false,
            createdAt: date, updatedAt: date, stage: .downloading, state: .failed, installation: nil, error: "Download failed")
        try harness.store.replaceAll([record])
        let recovery = ModelUpdateRecoveryReview(recordID: record.id, snapshots: [], failedReceipts: ["/receipt"], queueItems: [], resetsDownload: true)
        var api = harness.api
        api.previewRecovery = { _ in try harness.record("preview-recovery"); return recovery }
        api.applyRecovery = { captured, preview in
            XCTAssertEqual(preview, recovery)
            try harness.record("quarantine-staging")
            return captured
        }
        api.recover = { $0 }
        let coordinator = ModelUpdateCoordinator(api: api, store: harness.store)
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }
        await coordinator.waitForHistory()
        await coordinator.reviewRecovery(recordID: record.id)
        XCTAssertEqual(harness.events, ["preview-recovery"])
        XCTAssertEqual(coordinator.recoveryReview, recovery)
        coordinator.cancelRecovery()
        let cancelled = await coordinator.confirmRecovery(recovery)
        XCTAssertFalse(cancelled)
        XCTAssertEqual(harness.events, ["preview-recovery"])
        await coordinator.reviewRecovery(recordID: record.id)
        let completed = await coordinator.confirmRecovery(recovery)
        XCTAssertTrue(completed, coordinator.error ?? "")
        XCTAssertEqual(harness.events.filter { $0 == "quarantine-staging" }.count, 1)
    }

    func testDownloadedSourceCanReviewNewBitsWithoutAnotherDownload() async throws {
        let review = try makeConversionReview(), harness = try Harness(review: makeConversionReview())
        let source = downloadedSource(review), date = Date()
        let record = ModelUpdateRecord(id: review.id, alertID: nil, review: review, quarantinePrevious: false,
            createdAt: date, updatedAt: date, stage: .downloading, state: .failed, installation: nil,
            error: "Unsupported converter bit width", downloadedSource: source)
        try harness.store.replaceAll([record])
        var api = harness.api
        api.recover = { $0 }
        api.previewPreparation = { _, _ in throw ModelUpdateError.invalid("Review bit width") }
        api.revisePreparation = { captured, bits in
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(captured.review)) as! [String: Any]
            var recipe = object["conversion"] as! [String: Any]; recipe["qBits"] = bits
            object["conversion"] = recipe; object["destinationPath"] = "/models/prepared-8"
            let revised = try JSONDecoder().decode(ModelUpdateReview.self, from: JSONSerialization.data(withJSONObject: object))
            try harness.record("review-bits")
            return .init(id: captured.id, alertID: captured.alertID, review: revised, quarantinePrevious: captured.quarantinePrevious,
                createdAt: captured.createdAt, updatedAt: Date(), stage: .awaitingPreparation, state: .inProgress,
                installation: nil, error: nil, downloadedSource: source, preparation: self.preparation(revised, source: source))
        }
        let coordinator = ModelUpdateCoordinator(api: api, store: harness.store)
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }
        await coordinator.waitForHistory()
        _ = await coordinator.resume(recordID: record.id)
        XCTAssertTrue(coordinator.canRevisePreparation)
        let revised = await coordinator.revisePreparation(bits: 8)
        XCTAssertTrue(revised, coordinator.error ?? "")
        XCTAssertEqual(coordinator.activeRecord?.downloadedSource, source)
        XCTAssertEqual(coordinator.preparationReview?.recipe.qBits, 8)
        XCTAssertEqual(coordinator.preparationReview?.outputPath, "/models/prepared-8")
        XCTAssertEqual(harness.events, ["review-bits"])
        XCTAssertEqual(try harness.store.load().first?.stage, .awaitingPreparation)
    }

    func testPendingGGUFMainKeepsKnownProjectorReviewable() throws {
        let previous = ModelUpdatePreviousModel(repo: "org/model", path: "/models/old.gguf", signature: "old", revision: oldRevision,
            displayName: "Old", canQuarantine: false, retentionReason: nil, file: "old.gguf", requiresProjector: true,
            additionalFiles: ["mmproj.gguf"], projectorFile: "mmproj.gguf")
        let selection = ModelUpdateGGUFSelection.bundle(previous: previous, settings: .init(), main: nil,
            available: ["new.gguf", "mmproj.gguf"])
        XCTAssertEqual(selection.projector, "mmproj.gguf")
        XCTAssertEqual(selection.additionalFiles, ["mmproj.gguf"])
        XCTAssertTrue(selection.requiresProjector)
    }

    func testRecoveredFailedPreparationCanChangeBitsOnlyAfterWorkersStop() {
        var job = Job(receipt: "/receipt", repo: "org/model", source: "gguf", qBits: 4, out: "/models/prepared", pid: 100,
            logPath: nil, startedAt: nil, completedAt: nil, state: "failed", processesQuiescent: false)
        XCTAssertFalse(ModelUpdatePreparationState.canRevise(output: "/models/prepared", jobs: [job], queue: [], outputExists: false))
        job.processesQuiescent = nil
        XCTAssertFalse(ModelUpdatePreparationState.canRevise(output: "/models/prepared", jobs: [job], queue: [], outputExists: false))
        job.processesQuiescent = true
        XCTAssertTrue(ModelUpdatePreparationState.canRevise(output: "/models/prepared", jobs: [job], queue: [], outputExists: false))
        XCTAssertFalse(ModelUpdatePreparationState.canRevise(output: "/models/prepared", jobs: [job], queue: [], outputExists: true))
        let done = Job(receipt: "/done", repo: "org/model", source: "gguf", qBits: 4, out: "/models/prepared", pid: 101,
            logPath: nil, startedAt: nil, completedAt: nil, state: "done", processesQuiescent: true)
        XCTAssertFalse(ModelUpdatePreparationState.canRevise(output: "/models/prepared", jobs: [done], queue: [], outputExists: false))
    }

    func testConversionRetrySelectsCurrentReceiptWithoutAdoptingFailedHistory() throws {
        func job(_ receipt: String, _ state: String, hash: String = "reviewed") -> Job {
            Job(receipt: receipt, repo: "org/model", source: "gguf", qBits: 4, out: "/models/prepared", pid: 100,
                logPath: nil, startedAt: nil, completedAt: nil, state: state, previewHash: hash)
        }
        let failed = job("/old-failed", "failed"), current = job("/current", "done")
        XCTAssertEqual(try ModelUpdatePreparationState.observedJob(jobs: [failed, current], previewHash: "reviewed", output: "/models/prepared"), current)
        XCTAssertNil(try ModelUpdatePreparationState.observedJob(jobs: [failed], previewHash: "reviewed", output: "/models/prepared"))
        XCTAssertThrowsError(try ModelUpdatePreparationState.observedJob(jobs: [current, job("/unknown", "unknown")], previewHash: "reviewed", output: "/models/prepared"))
        XCTAssertThrowsError(try ModelUpdatePreparationState.observedJob(jobs: [current, job("/other", "running")], previewHash: "reviewed", output: "/models/prepared"))
        XCTAssertNil(try ModelUpdatePreparationState.observedJob(jobs: [current], previewHash: "reviewed", output: "/models/prepared", excludingReceipts: [current.receipt!]))
        XCTAssertNil(try ModelUpdatePreparationState.observedJob(jobs: [job("/wrong", "done", hash: "different")], previewHash: "reviewed", output: "/models/prepared"))
    }

    private func makeConversionReview(bits: Int = 4) throws -> ModelUpdateReview {
        let direct = try makeReview()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(direct.resolution)) as! [String: Any]
        object["verdict"] = "convertible"; object["q_bits"] = [4, 8]
        let resolution = try JSONDecoder().decode(IntakeResolution.self, from: JSONSerialization.data(withJSONObject: object))
        return ModelUpdateReview(id: UUID(), repo: direct.repo, previous: direct.previous, resolution: resolution,
            targetRevision: direct.targetRevision, destinationPath: "/models/prepared", previewHash: "fetch-plan", endpointSummary: [],
            conversion: .init(kind: .repository, qBits: bits, backend: "mlx-lm", modelType: "llama"), downloadDirectory: "/models/source")
    }

    private func downloadedSource(_ review: ModelUpdateReview) -> ModelUpdateInstallation {
        .init(repo: review.repo, revision: review.targetRevision, path: review.downloadedModelPath, signature: "source-signature",
            fetchReceipt: "/receipts/source.json", sourceFiles: [.init(path: review.downloadedModelPath, signature: "source-signature")])
    }

    private func preparation(_ review: ModelUpdateReview, source: ModelUpdateInstallation) -> ModelUpdatePreparationReview {
        .init(id: UUID(), previewHash: "conversion-plan", recipe: review.conversion!, repo: review.repo,
            sourcePath: review.downloadedModelPath, outputPath: review.destinationPath, fetchReceipt: source.fetchReceipt!, sourceFiles: source.sourceFiles!)
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
                    case .prepare: stage = .preparing; name = "prepare"
                    case .verify: stage = .verifying; name = "verify"
                    case .switchEndpoints: stage = .switching; name = "switch"
                    case .quarantinePrevious: stage = .quarantining; name = "quarantine"
                    }
                    XCTAssertEqual(try self.store.load().first?.stage, stage)
                    try self.record("check-" + name)
                }, download: { _ in try self.record("download"); return self.installation },
                verify: { _, installed in try self.record("verify"); return installed },
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
