import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class IntakeCoordinatorTests: XCTestCase {
    func testPrimaryUpdateKeepsTheReusedSourceAndOriginalReceipt() async throws {
        let root = try storageRoot()
        let old = root.appendingPathComponent("hub/models--openai--whisper-tiny/snapshots/" + String(repeating: "a", count: 40))
        let current = root.appendingPathComponent("existing-source")
        try storageModel(at: old); try storageModel(at: current)
        let revision = String(repeating: "b", count: 40), receiptPath = "/original/source.json"
        let resolution = try Self.resolution(verdict: "already_mlx", backend: "mlx-lm", resolvedRevision: revision)
        let resolved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(resolution)) as? [String: Any])
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: "/fixture", command: { _, argv, _, _ in
            if argv.prefix(2) == ["serve", "discover"] {
                return ["schema_version": 1, "services": [], "capabilities": ["model_storage_admission": true, "model_update_preparation": true]]
            }
            if argv.prefix(2) == ["intake", "resolve"] { return resolved }
            if argv.prefix(2) == ["intake", "fetch"] {
                if !argv.contains("--confirm") {
                    return ["plan": ["preview_hash": "reuse-approval", "local_dir": current.path,
                        "storage": ["mode": "reuse", "receipt": receiptPath, "fetch_preview_hash": "original-approval"]]]
                }
                return ["status": "reused", "receipt": ["repo": resolution.source.repo, "revision": revision,
                    "slug": "source", "started_at": "original", "local_dir": current.path, "preview_hash": "original-approval"],
                    "reused_fetch": ["receipt": receiptPath, "repo": resolution.source.repo, "revision": revision,
                        "local_dir": current.path, "state": "done", "path": current.path, "started_at": "original", "preview_hash": "original-approval"]]
            }
            return ["jobs": [], "servers": []]
        })
        let host = storageHost(root: root, api: api, previous: old.path)
        let candidates = try await host.updateCandidates(repo: resolution.source.repo)
        let previous = try XCTUnwrap(candidates.first)
        let review = try await host.prepareCompleteModelUpdate(repo: resolution.source.repo, previous: previous, settings: .init())
        XCTAssertEqual(review.sourceDirectory, current.path)
        XCTAssertEqual(review.previewHash, "original-approval")
        XCTAssertEqual(review.downloadAdmissionPreviewHash, "reuse-approval")
        XCTAssertEqual(review.downloadFetchReceipt, receiptPath)
        let installed = try await host.downloadCompleteModelUpdate(review)
        XCTAssertEqual(installed.path, current.path)
        XCTAssertEqual(installed.fetchReceipt, receiptPath)
        let records = try await host.managedModels.records()
        XCTAssertEqual(records.first?.path, current.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testFailedNewSharedComponentCanRecoverWithoutMovingCompletedSharedSources() async throws {
        let root = try storageRoot()
        let old = root.appendingPathComponent("hub/models--openai--whisper-tiny/snapshots/" + String(repeating: "a", count: 40))
        try storageModel(at: old)
        let revision = String(repeating: "b", count: 40)
        let resolution = try Self.resolution(verdict: "already_mlx", backend: "mlx-lm", resolvedRevision: revision)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(resolution)) as? [String: Any])
        var source = try XCTUnwrap(object["source"] as? [String: Any]); source["repo"] = "org/component"; object["source"] = source
        let component = try JSONDecoder().decode(IntakeResolution.self, from: JSONSerialization.data(withJSONObject: object))
        let output = root.appendingPathComponent("output").path
        let primary = try XCTUnwrap(ManagedModelInstallStore.directory(root: output, source: resolution.source))
        let shared = try XCTUnwrap(ManagedModelInstallStore.dependencyDirectory(root: output, source: component.source, additionalFiles: []))
        try storageModel(at: URL(fileURLWithPath: primary)); try storageModel(at: URL(fileURLWithPath: shared))
        let fetches: [[String: Any]] = [
            ["receipt": "/state/primary.json", "repo": resolution.source.repo, "revision": revision, "local_dir": primary,
             "state": "done", "path": primary, "preview_hash": "primary-approval"],
            ["receipt": "/state/component.json", "repo": component.source.repo, "revision": revision, "local_dir": shared,
             "state": "failed", "preview_hash": "component-approval", "processes_quiescent": true]]
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: "/fixture", command: { _, argv, _, _ in
            argv.prefix(2) == ["intake", "status"] ? ["jobs": fetches] : ["jobs": [], "servers": []]
        })
        let host = storageHost(root: root, api: api, previous: old.path)
        let previous = ModelUpdatePreviousModel(repo: resolution.source.repo, path: old.path,
            signature: try ManagedModelInstallStore.signature(path: old.path), revision: String(repeating: "a", count: 40),
            displayName: "Previous", canQuarantine: false, retentionReason: nil)
        var review = ModelUpdateReview(id: UUID(), repo: resolution.source.repo, previous: previous, resolution: resolution,
            targetRevision: revision, destinationPath: primary, previewHash: "primary-approval", endpointSummary: [],
            downloadDirectory: primary, dependencies: [.init(resolution: component, directory: shared, modelPath: shared,
                previewHash: "component-approval", shared: true)], reviewedEndpoints: [])
        func record(_ value: ModelUpdateReview) -> ModelUpdateRecord {
            .init(id: value.id, alertID: nil, review: value, quarantinePrevious: false, createdAt: Date(), updatedAt: Date(),
                  stage: .downloading, state: .failed, installation: nil, error: "Synthetic failed dependency")
        }
        let failed = record(review)
        let recovery = try await host.previewModelUpdateRecovery(failed)
        XCTAssertEqual(recovery.snapshots.map(\.path), [shared])
        XCTAssertTrue(recovery.resetsDownload)
        review.dependencies?[0].fetchReceipt = "/original/completed-component.json"
        do { _ = try await host.previewModelUpdateRecovery(record(review)); XCTFail("A reused shared source must remain protected") } catch {}
        let recovered = try await host.applyModelUpdateRecovery(failed, preview: recovery)
        XCTAssertEqual(recovered.stage, .downloading)
        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertEqual(recovered.review.previewHash, failed.review.previewHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared))
        XCTAssertTrue(FileManager.default.fileExists(atPath: primary))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    private func storageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("storage-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func storageModel(at path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: path.appendingPathComponent("config.json"))
        try Data("synthetic fixture".utf8).write(to: path.appendingPathComponent("model.safetensors"))
    }

    private func storageHost(root: URL, api: WorkbenchAPI, previous: String) -> AppHost {
        var config = Config.defaults(ggufRoots: [])
        config.outputDir = root.appendingPathComponent("output").path
        config.quarantineDir = root.appendingPathComponent("quarantine").path
        let item = ModelItem(path: previous, name: "Previous", bytes: 1, modifiedAt: nil, shard: nil,
            modelKey: "previous", architecture: nil, quantization: "4bit", parameters: nil, structure: nil,
            signature: nil, companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil, task: nil)
        let scan = ScanResult(roots: nil, models: [item], outputs: [], pending: [], duplicates: [],
            totals: .init(gguf: 0, pending: 0, converted: 1, unreadable: 0, bytes: 1, reclaimableBytes: 0))
        let host = AppHost(config: config, discoveredRoots: [], agentHealth: .notConfigured, runtimeReport: .checking,
            scanOperation: { _, _, _, _ in scan },
            modelPurposes: ModelPurposeStore(store: JSONStore(fileURL: root.appendingPathComponent("purposes.json"))),
            workbenchAPI: api, managedModels: ManagedModelInstallStore(store: JSONStore(fileURL: root.appendingPathComponent("models.json"))))
        host.librarySnapshot = ModelLibraryBuilder.build(scan: scan, hardware: host.hardwareProfile, now: Date())
        return host
    }

    func testGGUFReuseRequiresTheSelectedFileAndResolvedRevision() throws {
        let revision = String(repeating: "a", count: 40)
        let resolution = try Self.resolution(verdict: "gguf", backend: nil, resolvedRevision: revision)
        let path = "/cache/models--openai--whisper-tiny/snapshots/\(revision)/model-Q4.gguf"
        XCTAssertEqual(IntakeCoordinator.existingModelPath(resolution, qBits: 4, history: [], readyPaths: [path], selectedFile: "model-Q4.gguf"), path)
        XCTAssertNil(IntakeCoordinator.existingModelPath(resolution, qBits: 4, history: [], readyPaths: [path], selectedFile: "model-Q8.gguf"))
        let newer = try Self.resolution(verdict: "gguf", backend: nil, resolvedRevision: String(repeating: "b", count: 40))
        XCTAssertNil(IntakeCoordinator.existingModelPath(newer, qBits: 4, history: [], readyPaths: [path], selectedFile: "model-Q4.gguf"))
    }

    func testManagedReuseNeedsTheReviewedOriginalReceipt() async throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let revision = String(repeating: "a", count: 40)
        let canonical = temporary.path, receiptPath = "/original-receipts/original.json"
        for corrupt in [false, true] {
            let api = IntakeAPI.stub(fetchPreview: { _ in
                ["preview_hash": "reuse-review", "local_dir": canonical,
                 "storage": ["mode": "reuse", "receipt": receiptPath]]
            }, fetchStart: { _, _ in
                ["status": "reused", "receipt": ["repo": "openai/whisper-tiny", "revision": revision,
                    "slug": "original", "started_at": "old-launch", "local_dir": canonical, "preview_hash": "original-review"],
                 "reused_fetch": ["receipt": corrupt ? "/another-receipt.json" : receiptPath, "repo": "openai/whisper-tiny",
                    "revision": revision, "local_dir": canonical, "state": "done", "path": canonical,
                    "started_at": "old-launch", "preview_hash": "original-review"]]
            })
            let intake = IntakeCoordinator(api: api)
            let resolution = try Self.resolution(verdict: "already_mlx", backend: "mlx-lm", resolvedRevision: revision)
            do {
                let result = try await intake.download(resolution: resolution, localDir: temporary.appendingPathComponent("copy").path, previewHash: nil)
                XCTAssertFalse(corrupt)
                XCTAssertEqual(result, canonical)
                XCTAssertEqual(intake.completedFetch?.receipt, receiptPath)
            } catch { XCTAssertTrue(corrupt, "\(error)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("copy").path))
        }
    }

    func testUpdateComponentReusesOneVerifiedLegacyLocation() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let legacy = root.appendingPathComponent("managed-dependencies/previous-review/0").path
        let revision = String(repeating: "a", count: 40)
        let resolution = try Self.resolution(verdict: "already_mlx", backend: "mlx-lm", resolvedRevision: revision)
        let job = FetchJob(receipt: "/state/original.json", repo: resolution.source.repo, revision: revision,
            file: nil, subfolder: nil, localDir: legacy, state: "done", path: legacy, logPath: nil,
            startedAt: "original", completedAt: "done", previewHash: "original-hash")
        let reused = try XCTUnwrap(AppHost.reusableUpdateDependency(resolution, extras: [], root: root.path, fetches: [job]))
        XCTAssertEqual(reused.directory, legacy)
        XCTAssertEqual(reused.previewHash, "original-hash")
        XCTAssertEqual(reused.fetchReceipt, job.receipt)
        XCTAssertEqual(reused.shared, true)
        XCTAssertThrowsError(try AppHost.reusableUpdateDependency(resolution, extras: [], root: root.path, fetches: [job, job]))
        XCTAssertNil(try AppHost.reusableUpdateDependency(resolution, extras: ["different.bin"], root: root.path, fetches: [job]))
        XCTAssertNil(try AppHost.reusableUpdateDependency(resolution, extras: [], root: root.appendingPathComponent("other").path, fetches: [job]))
    }

    func testDownloadReservesActivityBeforeDestinationValidationSuspends() async throws {
        let gate = IntakeValidationGate()
        let entered = expectation(description: "destination validation entered")
        let destination = "/intake-fixture-\(UUID().uuidString)"
        let api = IntakeAPI.stub(resolve: { _ in try Self.resolution(verdict: "already_mlx", backend: "mlx-lm") },
            fetchPreview: { _ in ["preview_hash": "f"] }, fetchStart: { request, _ in Self.receipt(request, slug: "r") },
            fetchStatus: { [FetchJob(receipt: "/receipts/r.json", repo: "openai/whisper-tiny", revision: "main", file: nil,
                subfolder: nil, localDir: destination, state: "done", path: destination, logPath: nil, startedAt: "now", completedAt: nil)] })
        let intake = IntakeCoordinator(api: api, validateDestination: { _ in entered.fulfill(); await gate.wait() })
        intake.sourceText = "openai/whisper-tiny"
        await intake.resolve()
        let first = Task { await intake.download(localDir: destination) }
        await fulfillment(of: [entered], timeout: 2)
        defer { gate.open() }
        XCTAssertTrue(intake.isBusy)
        intake.open(with: "other/model")
        XCTAssertEqual(intake.sourceText, "openai/whisper-tiny")
        let second = await intake.download(localDir: destination)
        XCTAssertNil(second)
        XCTAssertEqual(intake.activity, .downloading(repo: "openai/whisper-tiny"))
        gate.open()
        let result = await first.value
        XCTAssertEqual(result, destination)
    }

    func testDestinationValidationFailureIsReportedByManualDownload() async throws {
        let intake = IntakeCoordinator(api: .stub(resolve: { _ in try Self.resolution(verdict: "already_mlx", backend: "mlx-lm") }),
            validateDestination: { _ in throw WorkflowEvidenceError.invalid("Fixture destination changed") })
        intake.sourceText = "openai/whisper-tiny"
        await intake.resolve()
        let path = await intake.download(localDir: "/destination")
        XCTAssertNil(path)
        guard case .failed(let message) = intake.activity else { return XCTFail("Expected a visible destination error") }
        XCTAssertTrue(message.contains("Fixture destination changed"))
    }

    private static func receipt(_ request: IntakeFetchRequest, slug: String) -> [String: Any] {
        var receipt: [String: Any] = ["repo": "openai/whisper-tiny", "revision": request.revision, "slug": slug, "started_at": "now"]
        receipt["file"] = request.file
        receipt["local_dir"] = request.localDir
        if request.source.hasSuffix("/multilingual") { receipt["subfolder"] = "multilingual" }
        return ["receipt": receipt]
    }

    func testDownloadCannotReuseAnOlderCompletedReceipt() async throws {
        let api = IntakeAPI.stub(
            resolve: { _ in try Self.resolution(verdict: "already_mlx", backend: "mlx-lm") },
            fetchPreview: { _ in ["preview_hash": "f"] },
            fetchStart: { request, _ in Self.receipt(request, slug: "r") },
            fetchStatus: { [FetchJob(receipt: "/receipts/r.json", repo: "openai/whisper-tiny", revision: "main", file: nil, subfolder: nil, localDir: nil,
                state: "done", path: "/old/model", logPath: nil, startedAt: "old", completedAt: "old")] })
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 2)
        intake.sourceText = "openai/whisper-tiny"
        await intake.resolve()
        let path = await intake.download(localDir: nil)
        XCTAssertNil(path)
        guard case .failed = intake.activity else { return XCTFail("Expected unmatched-receipt failure") }
    }

    func testExistingMLXIntakeUsesTheReadySnapshotOnly() throws {
        let result = try Self.resolution(verdict: "already_mlx", backend: "mlx-lm", resolvedRevision: String(repeating: "a", count: 40))
        let path = "/cache/models--openai--whisper-tiny/snapshots/" + String(repeating: "a", count: 40)
        XCTAssertEqual(IntakeCoordinator.existingModelPath(result, qBits: 4, history: [], readyPaths: [path]), path)
        XCTAssertNil(IntakeCoordinator.existingModelPath(result, qBits: 4, history: [], readyPaths: []))
        XCTAssertNil(IntakeCoordinator.existingModelPath(result, qBits: 4, history: [], readyPaths: ["/cache/models--other--model/snapshots/abc"]))
    }

    func testConvertibleIntakeReusesOnlyMatchingCurrentOutputAndWidth() throws {
        let revision = String(repeating: "a", count: 40)
        let resolution = try Self.resolution(verdict: "convertible", backend: "mlx-lm", resolvedRevision: revision)
        let path = "/models/whisper-tiny-MLX-4bit"
        var record = ConversionWorkflow(id: UUID(), sourcePath: "hf://openai/whisper-tiny", sourceModelKey: nil, sourceSignature: nil,
            outputPath: path, previewHash: nil, jobReceipt: nil, completedModelPath: path,
            state: .verified, serveState: .idle, message: nil, errorMessage: nil, createdAt: Date(), updatedAt: Date(), lastKnownAgentState: nil)
        XCTAssertNil(IntakeCoordinator.existingModelPath(resolution, qBits: 4, history: [record], readyPaths: [path]))
        record.localSourcePath = "/cache/models--openai--whisper-tiny/snapshots/" + revision
        XCTAssertEqual(IntakeCoordinator.existingModelPath(resolution, qBits: 4, history: [record], readyPaths: [path]), path)
        XCTAssertNil(IntakeCoordinator.existingModelPath(resolution, qBits: 8, history: [record], readyPaths: [path]))
        XCTAssertNil(IntakeCoordinator.existingModelPath(resolution, qBits: 4, history: [record], readyPaths: []))
        let other = try Self.resolution(verdict: "convertible", backend: "mlx-lm", subfolder: "different")
        XCTAssertNil(IntakeCoordinator.existingModelPath(other, qBits: 4, history: [record], readyPaths: [path]))
    }
    func testLinkSniffing() {
        for text in ["https://huggingface.co/org/name", "hf.co/org/name", "  org/name  ", "https://www.huggingface.co/org/name/tree/main"] {
            XCTAssertTrue(IntakeCoordinator.looksLikeHFLink(text), text)
        }
        for text in [nil, "", "hello world", "https://github.com/org/name", "a/b/c", String(repeating: "x", count: 3000)] {
            XCTAssertFalse(IntakeCoordinator.looksLikeHFLink(text), text ?? "nil")
        }
    }

    func testOpenResetsStateAndKeepsText() async throws {
        let api = IntakeAPI.stub(resolve: { _ in try Self.resolution(verdict: "convertible", backend: "mlx-lm") })
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 3)
        intake.open(with: "  org/name  ")
        XCTAssertEqual(intake.sourceText, "org/name")
        XCTAssertNil(intake.resolution)
        XCTAssertNil(intake.draft)
        XCTAssertEqual(intake.logTail, [])
        for _ in 0..<200 where intake.resolution == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(intake.resolution?.verdict, .convertible)
        XCTAssertEqual(intake.sourceText, "org/name")
        XCTAssertNil(intake.draft)
        XCTAssertEqual(intake.logTail, [])
    }

    func testUnsupportedResolutionRunsAnalysis() async throws {
        var analyzed = 0
        let api = IntakeAPI.stub(
            resolve: { _ in try Self.resolution(verdict: "unsupported", backend: nil) },
            portAnalysis: { _ in analyzed += 1; return try Self.analysis() }
        )
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 3)
        intake.sourceText = "Edge0/Audio8-ASR-Infinite"
        await intake.resolve()
        XCTAssertEqual(intake.resolution?.verdict, .unsupported)
        XCTAssertEqual(analyzed, 1)
        XCTAssertNotNil(intake.analysis)
        XCTAssertEqual(intake.activity, .idle)
    }

    func testInstallPollsUntilInstalledThenReResolves() async throws {
        var states: [BackendState] = [.installing, .installed]
        var resolves = 0
        let api = IntakeAPI.stub(
            resolve: { _ in resolves += 1; return try Self.resolution(verdict: resolves == 1 ? "convertible_after_install" : "convertible", backend: "mlx-audio") },
            backends: { BackendList(schema: "backends/1", root: "/b", backends: [Self.entry(states.removeFirst())]) },
            installPreview: { _ in ["preview_hash": "h"] },
            installStart: { _, hash in XCTAssertEqual(hash, "h"); return ["status": "started"] }
        )
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 5)
        intake.sourceText = "openai/whisper-tiny"
        await intake.resolve()
        await intake.installBackend()
        XCTAssertEqual(resolves, 2)
        XCTAssertEqual(intake.resolution?.verdict, .convertible)
        XCTAssertEqual(intake.activity, .idle)
    }

    func testFailedInstallSurfacesTheLog() async throws {
        let api = IntakeAPI.stub(
            resolve: { _ in try Self.resolution(verdict: "convertible_after_install", backend: "mlx-audio") },
            backends: { BackendList(schema: "backends/1", root: "/b", backends: [Self.entry(.failed, log: "/logs/mlx-audio.log")]) },
            installPreview: { _ in ["preview_hash": "h"] },
            installStart: { _, _ in [:] }
        )
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 5)
        intake.sourceText = "openai/whisper-tiny"
        await intake.resolve()
        await intake.installBackend()
        guard case .failed(let message) = intake.activity else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("/logs/mlx-audio.log"))
    }

    func testDownloadReturnsTheMarkerPath() async throws {
        var polls = 0
        let api = IntakeAPI.stub(
            resolve: { _ in try Self.resolution(verdict: "convertible", backend: "mlx-lm") },
            fetchPreview: { _ in ["preview_hash": "f"] },
            fetchStart: { request, _ in Self.receipt(request, slug: "r") },
            fetchStatus: {
                polls += 1
                return [FetchJob(receipt: "/receipts/r.json", repo: "openai/whisper-tiny", revision: "main", file: nil, subfolder: nil, localDir: nil, state: polls < 2 ? "running" : "done", path: "/hf/snap", logPath: nil, startedAt: "now", completedAt: nil)]
            }
        )
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 5)
        intake.sourceText = "openai/whisper-tiny"
        await intake.resolve()
        let path = await intake.download(localDir: nil)
        XCTAssertEqual(path, "/hf/snap")
        XCTAssertEqual(intake.downloadedPath, "/hf/snap")
    }

    /// A subfolder checkpoint downloads as org/name/folder and waits for that folder's job, not the root's.
    func testSubfolderDownloadNamesTheFolderAndWaitsForItsJob() async throws {
        var requested: IntakeFetchRequest?
        let api = IntakeAPI.stub(
            resolve: { _ in try Self.resolution(verdict: "convertible", backend: "mlx-embeddings", subfolder: "multilingual") },
            fetchPreview: { request in requested = request; return ["preview_hash": "f"] },
            fetchStart: { request, _ in Self.receipt(request, slug: "ml") },
            fetchStatus: {
                [FetchJob(receipt: "root", repo: "openai/whisper-tiny", revision: "main", file: nil, subfolder: nil, localDir: nil, state: "done", path: "/hf/root", logPath: nil, startedAt: nil, completedAt: nil),
                 FetchJob(receipt: "/receipts/ml.json", repo: "openai/whisper-tiny", revision: "main", file: nil, subfolder: "multilingual", localDir: nil, state: "done", path: "/hf/snap", logPath: nil, startedAt: "now", completedAt: nil)]
            }
        )
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 5)
        intake.sourceText = "openai/whisper-tiny/multilingual"
        await intake.resolve()
        let path = await intake.download(localDir: nil)
        XCTAssertEqual(requested?.source, "openai/whisper-tiny/multilingual")
        XCTAssertEqual(path, "/hf/snap")
    }

    func testDraftNeedsARunningServerAndUsesItsIdentity() async throws {
        var drafted: (String, String, String)?
        let server = ServerInfo(repo: "Qwen/Qwen3-8B-MLX", path: nil, runtime: "mlx-lm", port: 8090, pid: 1, state: "running", logPath: nil, startedAt: nil, receipt: nil)
        let api = IntakeAPI.stub(
            resolve: { _ in try Self.resolution(verdict: "unsupported", backend: nil) },
            portAnalysis: { _ in try Self.analysis() },
            portPlan: { source, endpoint, model in
                drafted = (source, endpoint, model)
                return PortPlanResult(schema: "port-plan/1", path: "/plans/x.md", model: model, endpoint: endpoint, analysisSha256: "s", promptChars: 1, truncated: false, bytes: 1)
            },
            serveStatus: { [server] }
        )
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 3)
        intake.sourceText = "Edge0/Audio8-ASR-Infinite"
        await intake.resolve()
        XCTAssertEqual(intake.draftServer?.port, 8090)
        await intake.draftPlan()
        XCTAssertEqual(drafted?.1, "http://127.0.0.1:8090")
        XCTAssertEqual(drafted?.2, "Qwen/Qwen3-8B-MLX")
        XCTAssertEqual(intake.draft?.path, "/plans/x.md")
    }

    func testNoRunningServerMeansNoDraft() async throws {
        let api = IntakeAPI.stub(
            resolve: { _ in try Self.resolution(verdict: "unsupported", backend: nil) },
            portAnalysis: { _ in try Self.analysis() },
            serveStatus: { [] }
        )
        let intake = IntakeCoordinator(api: api, pollInterval: .milliseconds(1), pollLimit: 3)
        intake.sourceText = "Edge0/Audio8-ASR-Infinite"
        await intake.resolve()
        XCTAssertNil(intake.draftServer)
        await intake.draftPlan()
        XCTAssertNil(intake.draft)
    }

    static func resolution(verdict: String, backend: String?, subfolder: String? = nil, resolvedRevision: String? = nil) throws -> IntakeResolution {
        let json = """
        {"schema":"intake/1","source":{"input":"x","repo":"openai/whisper-tiny","revision":"main","file":null,
         "subfolder":\(subfolder.map { "\"\($0)\"" } ?? "null"),"url":"u","resolved_revision":\(resolvedRevision.map { "\"\($0)\"" } ?? "null")},
         "verdict":"\(verdict)","reasons":[],"backend":\(backend.map { "\"\($0)\"" } ?? "null"),"backend_installed":\(verdict == "convertible"),
         "model_type":"whisper","components":[],"task":null,"custom_code":false,"gated":false,"library_name":null,"pipeline_tag":null,
         "transformers_version":null,"bytes":0,"files":{"safetensors":1,"gguf":[],"python":[]},"warnings":[]}
        """
        return try JSONDecoder().decode(IntakeResolution.self, from: Data(json.utf8))
    }

    static func analysis() throws -> PortAnalysis {
        let json = """
        {"schema":"port-analysis/1","source":{"input":"x","repo":"o/n","revision":"main","file":null,"url":"u"},"model_type":"t",
         "architectures":[],"processor_class":null,"transformers_version":null,"components":[],
         "weights":{"index_available":false,"prefixes":[],"extra_files":[]},"code":{"files":[],"truncated":false},"missing":[],"warnings":[]}
        """
        return try JSONDecoder().decode(PortAnalysis.self, from: Data(json.utf8))
    }

    static func entry(_ state: BackendState, log: String? = nil) -> BackendEntry {
        BackendEntry(id: "mlx-audio", version: "0.5.7", builtin: false, state: state, categories: ["speech_to_text"], modelTypes: 30, registrySource: "snapshot", target: "/b/mlx-audio", logPath: log, startedAt: nil, completedAt: nil)
    }
}

@MainActor
private final class IntakeValidationGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
