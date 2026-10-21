import Foundation
import XCTest

@testable import mlx_workbench

final class ModelWorkflowCoordinatorTests: XCTestCase {
    func testRestoredProjectorWorkflowCannotPreviewOrQueueConversion() async {
        let host = await makeHost(preview: ["preview_hash": "hash-1"], confirmReceipt: "receipt-1")
        let timestamp = Date()
        let record = ConversionWorkflow(
            id: UUID(), sourcePath: "/Models/model-mmproj-BF16.gguf", sourceModelKey: "hf",
            sourceSignature: nil, outputPath: "/Models/model-mmproj-BF16", previewHash: nil,
            jobReceipt: nil, completedModelPath: nil, state: .failed, serveState: .idle,
            message: "Conversion failed.", errorMessage: "Conversion failed.",
            createdAt: timestamp, updatedAt: timestamp, lastKnownAgentState: "failed"
        )
        await MainActor.run { host.modelWorkflow.restore(record) }
        await host.modelWorkflow.preview(qBits: 8, out: nil)
        await MainActor.run {
            XCTAssertEqual(host.modelWorkflow.workflow.state, .failed)
            XCTAssertNil(host.modelWorkflow.workflow.previewHash)
            XCTAssertTrue(host.modelWorkflow.workflow.errorMessage?.contains("companion") == true)
        }
        await host.modelWorkflow.confirm(qBits: 8)
        await MainActor.run {
            XCTAssertEqual(host.modelWorkflow.workflow.state, .failed)
            XCTAssertNil(host.modelWorkflow.workflow.jobReceipt)
        }
    }

    func testInspectingEquivalentModelProducesRunExistingState() async {
        let host = await makeHost(snapshot: snapshotWithEquivalentMLX())

        await MainActor.run {
            host.modelWorkflow.inspect(source: ggufSource, snapshot: host.librarySnapshot)
            XCTAssertEqual(host.modelWorkflow.workflow.state, .existingModelFound)
            XCTAssertEqual(host.modelWorkflow.workflow.completedModelPath, existingMLXPath)
        }
    }

    func testConfirmStoresReceiptAndEntersQueuedState() async {
        let host = await makeHost(preview: ["preview_hash": "hash-1"], confirmReceipt: "receipt-1")
        await MainActor.run { host.modelWorkflow.inspect(source: ggufSource, snapshot: nil) }
        await host.modelWorkflow.preview(qBits: 4, out: nil)
        await host.modelWorkflow.confirm(qBits: 4, reclaimSourceAfterVerification: true)

        await MainActor.run {
            XCTAssertEqual(host.modelWorkflow.workflow.state, .queued)
            XCTAssertEqual(host.modelWorkflow.workflow.jobReceipt, "receipt-1")
            XCTAssertEqual(host.modelWorkflow.workflow.reclaimSourceAfterVerification, true)
        }
    }

    func testConfirmServeRejectsChangedRuntimeWithoutLaunching() async {
        let launches = ServeLaunchRecorder()
        let host = await makeHost(onServeStart: { runtime, port in
            await launches.record(runtime: runtime, port: port)
        })
        await MainActor.run {
            host.modelWorkflow.restore(
                makeWorkflow(state: .completed, receipt: "receipt-1", completedModelPath: "/Models/ready")
            )
        }

        await host.modelWorkflow.previewServe(runtime: "mlx_lm", port: 8080)
        await host.modelWorkflow.confirmServe(runtime: "mlx-vlm", port: 8080)

        let state = await MainActor.run { host.modelWorkflow.workflow }
        let launchCount = await launches.count
        XCTAssertEqual(state.serveState, .failed)
        XCTAssertTrue(state.errorMessage?.contains("intent changed") == true)
        XCTAssertEqual(launchCount, 0)
    }

    func testConfirmServeRejectsChangedPortWithoutLaunching() async {
        let launches = ServeLaunchRecorder()
        let host = await makeHost(onServeStart: { runtime, port in
            await launches.record(runtime: runtime, port: port)
        })
        await MainActor.run {
            host.modelWorkflow.restore(
                makeWorkflow(state: .completed, receipt: "receipt-1", completedModelPath: "/Models/ready")
            )
        }

        await host.modelWorkflow.previewServe(runtime: "mlx_lm", port: 8080)
        await host.modelWorkflow.confirmServe(runtime: "mlx_lm", port: 8081)

        let state = await MainActor.run { host.modelWorkflow.workflow }
        let launchCount = await launches.count
        XCTAssertEqual(state.serveState, .failed)
        XCTAssertTrue(state.errorMessage?.contains("intent changed") == true)
        XCTAssertEqual(launchCount, 0)
    }

    func testFailedStatusPreservesLastKnownRunningState() async {
        let host = await makeHost(statusError: TestError.offline)
        await MainActor.run { host.modelWorkflow.restore(makeWorkflow(state: .running, receipt: "receipt-1")) }

        await host.modelWorkflow.reconcile(snapshot: nil, jobs: [])

        await MainActor.run {
            XCTAssertEqual(host.modelWorkflow.workflow.state, .running)
            XCTAssertTrue(host.modelWorkflow.workflow.message?.contains("unavailable") == true)
        }
    }

    func testCompletedJobRequiresFreshRescanBeforeCompletion() async {
        let completedJob = Job(receipt: "receipt-1", repo: nil, source: nil, qBits: 4, out: "/Models/source", pid: nil, logPath: nil, startedAt: nil, completedAt: nil, state: "completed")
        let host = await makeHost(jobs: [completedJob])
        await MainActor.run { host.modelWorkflow.restore(makeWorkflow(state: .running, receipt: "receipt-1")) }

        await host.modelWorkflow.reconcile(snapshot: nil, jobs: [])

        await MainActor.run {
            XCTAssertEqual(host.modelWorkflow.workflow.state, .running)
            XCTAssertTrue(host.modelWorkflow.workflow.message?.contains("fresh library scan") == true)
        }
    }

    /// mlx-agent's `convert status` reports a finished job as "done"
    /// (convert.py status_convert); it must be treated as completed.
    func testAgentDoneStateIsTreatedAsCompleted() async {
        let doneJob = Job(receipt: "receipt-1", repo: nil, source: nil, qBits: 4, out: "/Models/source", pid: nil, logPath: nil, startedAt: nil, completedAt: nil, state: "done")
        let host = await makeHost(jobs: [doneJob])
        await MainActor.run { host.modelWorkflow.restore(makeWorkflow(state: .running, receipt: "receipt-1")) }

        await host.modelWorkflow.reconcile(snapshot: nil, jobs: [])

        await MainActor.run {
            XCTAssertEqual(host.modelWorkflow.workflow.state, .running)
            XCTAssertTrue(host.modelWorkflow.workflow.message?.contains("fresh library scan") == true)
            XCTAssertFalse(host.modelWorkflow.workflow.message?.contains("not recognized") == true)
        }
    }

    func testTerminalStatusCompletesOnlyFromPostStatusRescan() async {
        let events = WorkflowEventLog()
        let scans = ScanSequence([
            scanResult(outputs: []),
            scanResult(outputs: [
                MLXOutput(
                    path: "/Models/source",
                    name: "source",
                    modelKey: "source-model",
                    quantization: nil,
                    provenance: "signature-1"
                ),
            ]),
        ])
        let terminalJob = Job(receipt: "receipt-1", repo: nil, source: nil, qBits: 4, out: "/Models/source", pid: nil, logPath: nil, startedAt: nil, completedAt: nil, state: "completed")
        let host = await makeHost(
            jobs: [terminalJob],
            onStatus: { await events.record("status") },
            scanOperation: { _, _, _, _ in
                await events.record("scan")
                return try await scans.next()
            }
        )
        await MainActor.run { host.modelWorkflow.restore(makeWorkflow(state: .running, receipt: "receipt-1")) }

        await host.rescan()

        let state = await MainActor.run { (host.modelWorkflow.workflow.state, host.modelWorkflow.workflow.completedModelPath) }
        let scanCount = await scans.count
        let eventValues = await events.values
        XCTAssertEqual(state.0, .completed)
        XCTAssertEqual(state.1, "/Models/source")
        XCTAssertEqual(scanCount, 2)
        XCTAssertEqual(eventValues, ["scan", "status", "scan"])
    }

    func testActivityRefreshAfterTerminalStatusTriggersFreshScan() async {
        let terminalJob = Job(receipt: "receipt-activity", repo: nil, source: nil, qBits: 4, out: "/Models/source", pid: nil, logPath: nil, startedAt: nil, completedAt: nil, state: "completed")
        let scans = ScanSequence([
            scanResult(outputs: [
                MLXOutput(path: "/Models/source", name: "source", modelKey: "source-model", quantization: nil, provenance: "signature-1")
            ])
        ])
        let host = await makeHost(
            scanOperation: { _, _, _, _ in try await scans.next() }
        )
        await MainActor.run {
            host.modelWorkflow.restore(makeWorkflow(state: .running, receipt: "receipt-activity"))
        }

        await host.refreshWorkflowStatus(jobs: [terminalJob])

        let state = await MainActor.run {
            (host.modelWorkflow.workflow.state, host.modelWorkflow.workflow.completedModelPath)
        }
        let scanCount = await scans.count
        XCTAssertEqual(state.0, .completed)
        XCTAssertEqual(state.1, "/Models/source")
        XCTAssertEqual(scanCount, 1)
    }

    func testMissingStoreLoadsEmptyRecords() throws {
        let store = makeStore()

        XCTAssertEqual(try store.load(), [])
    }

    func testUpsertRoundTripsWorkflowRecord() throws {
        let store = makeStore()
        let record = makeWorkflow(state: .queued, receipt: "receipt-1")

        try store.upsert(record)

        XCTAssertEqual(try store.load(), [record])
    }

    func testReplaceRemovesRecordsNotInReplacement() throws {
        let store = makeStore()
        try store.replace([
            makeWorkflow(id: "old", state: .failed, receipt: "receipt-old"),
            makeWorkflow(id: "keep", state: .running, receipt: "receipt-keep"),
        ])

        try store.replace([makeWorkflow(id: "keep", state: .completed, receipt: "receipt-keep")])

        XCTAssertEqual(try store.load().map(\.persistenceIdentifier), [workflowID("keep").uuidString])
    }

    func testCorruptStoreThrowsInsteadOfReturningEmptyHistory() throws {
        let url = temporaryURL("workflows.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url)

        XCTAssertThrowsError(try ModelWorkflowStore(fileURL: url).load())
    }

    func testRemovePersistsTheRemainingRecords() throws {
        let store = makeStore()
        let removed = makeWorkflow(id: "remove", state: .queued, receipt: "receipt-remove")
        let remaining = makeWorkflow(id: "remain", state: .running, receipt: "receipt-remain")
        try store.replace([removed, remaining])

        try store.remove(id: removed.persistenceIdentifier)

        XCTAssertEqual(try store.load(), [remaining])
    }

    func testFailedReplacementPreservesPreviousPersistedRecord() throws {
        let url = temporaryURL("workflows.json")
        let originalStore = ModelWorkflowStore(fileURL: url)
        let original = makeWorkflow(id: "original", state: .queued, receipt: "receipt-original")
        try originalStore.replace([original])

        try rejectHistoryWrites(originalStore.databaseURL)
        let failingStore = ModelWorkflowStore(fileURL: url)
        let replacement = makeWorkflow(id: "replacement", state: .completed, receipt: "receipt-replacement")

        XCTAssertThrowsError(try failingStore.replace([replacement]))
        XCTAssertEqual(try originalStore.load(), [original])
    }

    func testConcurrentUpsertsFromTwoStoresPreserveBothRecords() throws {
        let url = temporaryURL("workflows.json")
        let stores = [ModelWorkflowStore(fileURL: url), ModelWorkflowStore(fileURL: url)]
        let records = [
            makeWorkflow(id: "concurrent-one", state: .queued, receipt: "receipt-one"),
            makeWorkflow(id: "concurrent-two", state: .running, receipt: "receipt-two"),
        ]
        let errorsLock = NSLock()
        var errors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: records.count) { index in
            do {
                try stores[index].upsert(records[index])
            } catch {
                errorsLock.lock()
                errors.append(error)
                errorsLock.unlock()
            }
        }

        XCTAssertTrue(errors.isEmpty, "unexpected upsert errors: \(errors)")
        XCTAssertEqual(
            Set(try stores[0].load().map(\.persistenceIdentifier)),
            Set(records.map(\.persistenceIdentifier))
        )
    }

    func testCompletedConversionRoutesToVerificationWhenGateAttached() async {
        let completedJob = Job(receipt: "receipt-1", repo: nil, source: nil, qBits: 4, out: "/Models/source", pid: nil, logPath: nil, startedAt: nil, completedAt: nil, state: "completed")
        let scans = ScanSequence([
            scanResult(outputs: []),
            scanResult(outputs: [
                MLXOutput(
                    path: "/Models/source",
                    name: "source",
                    modelKey: "source-model",
                    quantization: nil,
                    provenance: "signature-1"
                ),
            ]),
        ])
        let host = await makeHost(
            jobs: [completedJob],
            scanOperation: { _, _, _, _ in try await scans.next() }
        )
        let (recordID, verifier) = await MainActor.run { () -> (UUID, StubCompletionVerifier) in
            let verifier = StubCompletionVerifier()
            let record = makeWorkflow(state: .running, receipt: "receipt-1")
            host.modelWorkflow.restore(record)
            host.modelWorkflow.completionVerifier = verifier
            return (record.id, verifier)
        }

        await host.rescan()

        await MainActor.run {
            XCTAssertEqual(host.modelWorkflow.workflow.state, .verifying)
            XCTAssertEqual(verifier.calls.count, 1)
            XCTAssertEqual(verifier.calls.first?.0, recordID)
            XCTAssertEqual(verifier.calls.first?.1, "/Models/source")
        }
    }

    /// Status refreshes keep arriving while the gate runs; a done job must not
    /// pull the record back to "waiting for a scan" and start a second verification.
    func testStatusRefreshDuringVerificationDoesNotRestartIt() async {
        let completedJob = Job(receipt: "receipt-1", repo: nil, source: nil, qBits: 4, out: "/Models/source", pid: nil, logPath: nil, startedAt: nil, completedAt: nil, state: "done")
        let output = MLXOutput(path: "/Models/source", name: "source", modelKey: "source-model", quantization: nil, provenance: "signature-1")
        let scans = ScanSequence([scanResult(outputs: []), scanResult(outputs: [output]), scanResult(outputs: [output]), scanResult(outputs: [output])])
        let host = await makeHost(jobs: [completedJob], scanOperation: { _, _, _, _ in try await scans.next() })
        let verifier = await MainActor.run { () -> StubCompletionVerifier in
            let verifier = StubCompletionVerifier()
            host.modelWorkflow.restore(makeWorkflow(state: .running, receipt: "receipt-1"))
            host.modelWorkflow.completionVerifier = verifier
            return verifier
        }
        await host.rescan()
        await host.refreshWorkflowStatus()
        await host.refreshWorkflowStatus()
        await MainActor.run {
            XCTAssertEqual(host.modelWorkflow.workflow.state, .verifying)
            XCTAssertEqual(verifier.calls.count, 1)
            XCTAssertFalse(host.modelWorkflow.consumeCompletionRescanRequest())
        }
    }

    func testCompletedConversionSkipsVerificationWithoutGate() async {
        let completedJob = Job(receipt: "receipt-1", repo: nil, source: nil, qBits: 4, out: "/Models/source", pid: nil, logPath: nil, startedAt: nil, completedAt: nil, state: "completed")
        let withOutput = scanResult(outputs: [
            MLXOutput(path: "/Models/source", name: "source", modelKey: "source-model", quantization: nil, provenance: "signature-1")
        ])
        let scans = ScanSequence([withOutput, withOutput])
        let host = await makeHost(
            jobs: [completedJob],
            scanOperation: { _, _, _, _ in try await scans.next() }
        )
        await MainActor.run { host.modelWorkflow.restore(makeWorkflow(state: .running, receipt: "receipt-1")) }

        await host.rescan()

        await MainActor.run {
            XCTAssertEqual(host.modelWorkflow.workflow.state, .completed)
        }
    }

    func testConfirmResolvesReceiptFromStatusWhenStartReturnsReceiptObject() async {
        // mlx-agent ≥ 0.5.x: convert start returns receipt as an object; the
        // authoritative receipt path only exists in convert status.
        let startedJob = Job(receipt: "/receipts/stories.json", repo: nil, source: nil, qBits: 4, out: "/Models/source", pid: 42, logPath: nil, startedAt: nil, completedAt: nil, state: "running")
        let host = await makeHost(
            confirmResponse: ["status": "started", "receipt": ["pid": 42]],
            jobs: [startedJob]
        )
        await MainActor.run { host.modelWorkflow.inspect(source: ggufSource, snapshot: nil) }
        await host.modelWorkflow.preview(qBits: 4, out: nil)

        await host.modelWorkflow.confirm(qBits: 4)

        await MainActor.run {
            XCTAssertEqual(host.modelWorkflow.workflow.state, .queued)
            XCTAssertEqual(host.modelWorkflow.workflow.jobReceipt, "/receipts/stories.json")
        }
    }

    func testConfirmServeMatchesAuthoritativeServerByRepoID() async {
        // The server record reports the HF repo id; the workflow tracks the
        // HF-cache snapshot path. They must reconcile as the same model.
        let cachePath = "/Users/x/.cache/huggingface/hub/models--mlx-community--Qwen3-0.6B-4bit/snapshots/abc123"
        let runningServer = ServerInfo(repo: "mlx-community/Qwen3-0.6B-4bit", runtime: "mlx_lm", port: 8080, pid: 1, state: "running", logPath: nil, startedAt: nil, receipt: "srv-1")
        let started = FlagBox()
        let host = await makeHost(
            onServeStart: { _, _ in await started.set(true) },
            servers: [],
            dynamicServers: { await started.value ? [runningServer] : [] }
        )
        await MainActor.run {
            host.modelWorkflow.restore(
                makeWorkflow(state: .completed, receipt: "receipt-1", completedModelPath: cachePath)
            )
        }

        await host.modelWorkflow.previewServe(runtime: "mlx_lm", port: 8080)
        await host.modelWorkflow.confirmServe(runtime: "mlx_lm", port: 8080)

        let state = await MainActor.run { host.modelWorkflow.workflow }
        XCTAssertEqual(state.serveState, .running)
    }

    func testTerminalFailureNotifiesOnceAcrossReconciles() async {
        let failedJob = Job(receipt: "receipt-1", repo: nil, source: nil, qBits: 4, out: "/Models/source", pid: nil, logPath: nil, startedAt: nil, completedAt: nil, state: "failed")
        let host = await makeHost(jobs: [failedJob])
        let recorder = TerminalStateRecorder()
        await MainActor.run {
            host.modelWorkflow.onTerminalState = { recorder.states.append($0.state) }
            host.modelWorkflow.restore(makeWorkflow(state: .running, receipt: "receipt-1"))
        }

        await host.modelWorkflow.reconcile(snapshot: nil, jobs: [failedJob])
        await host.modelWorkflow.reconcile(snapshot: nil, jobs: [failedJob])

        XCTAssertEqual(recorder.states, [.failed])
    }

    func testReconcilingAnUnchangedJobLeavesTheRecordUntouched() async {
        for (agentState, expected) in [("failed", ConversionWorkflowState.failed), ("running", .running), ("queued", .queued)] {
            let job = Job(receipt: "receipt-1", repo: nil, source: nil, qBits: 4, out: "/Models/source", pid: nil, logPath: nil, startedAt: nil, completedAt: nil, state: agentState)
            let host = await makeHost(jobs: [job])
            await MainActor.run { host.modelWorkflow.restore(makeWorkflow(state: .running, receipt: "receipt-1")) }

            await host.modelWorkflow.reconcile(snapshot: nil, jobs: [job])
            let first = await MainActor.run { host.modelWorkflow.history.first { $0.jobReceipt == "receipt-1" } }
            XCTAssertEqual(first?.state, expected, agentState)

            await host.modelWorkflow.reconcile(snapshot: nil, jobs: [job])
            let second = await MainActor.run { host.modelWorkflow.history.first { $0.jobReceipt == "receipt-1" } }
            XCTAssertEqual(second?.updatedAt, first?.updatedAt, "\(agentState): a reconcile that changes nothing must not rewrite the record")
            XCTAssertEqual(second, first, agentState)
        }
    }

    /// Receipts are named by destination, so a re-run reuses the older record's receipt.
    func testDoneJobReconcilesOnlyTheNewestRecordSharingItsReceipt() async {
        let doneJob = Job(receipt: "receipt-1", repo: nil, source: nil, qBits: 4, out: "/Models/source", pid: nil, logPath: nil, startedAt: nil, completedAt: nil, state: "done")
        let output = MLXOutput(path: "/Models/source", name: "source", modelKey: "source-model", quantization: nil, provenance: "signature-1")
        let scans = ScanSequence([scanResult(outputs: []), scanResult(outputs: [output])])
        let host = await makeHost(jobs: [doneJob], scanOperation: { _, _, _, _ in try await scans.next() })
        let older = makeWorkflow(id: "old", state: .failed, receipt: "receipt-1", message: "Conversion failed.", errorMessage: "Conversion failed.", agentState: "failed")
        let newer = makeWorkflow(state: .running, receipt: "receipt-1", agentState: "running", createdAt: Date(timeIntervalSinceReferenceDate: 30))
        let verifier = await MainActor.run { () -> StubCompletionVerifier in
            let verifier = StubCompletionVerifier()
            host.modelWorkflow.restore(older)
            host.modelWorkflow.restore(newer)
            host.modelWorkflow.completionVerifier = verifier
            return verifier
        }

        await host.rescan()

        await MainActor.run {
            XCTAssertEqual(verifier.calls.map { $0.0 }, [newer.id])
            XCTAssertEqual(host.modelWorkflow.history.first { $0.id == newer.id }?.state, .verifying)
            XCTAssertEqual(host.modelWorkflow.history.first { $0.id == older.id }, older)
        }
    }

    func testNewerRunNeverRewritesAnOlderFailedRecord() async {
        for agentState in ["queued", "running", "done", "cancelled"] {
            let job = Job(receipt: "receipt-1", repo: nil, source: nil, qBits: 4, out: "/Models/source", pid: nil, logPath: nil, startedAt: nil, completedAt: nil, state: agentState)
            let host = await makeHost(jobs: [job])
            let failed = makeWorkflow(state: .failed, receipt: "receipt-1", message: "Conversion failed.", errorMessage: "Conversion failed.", agentState: "failed")
            let recorder = TerminalStateRecorder()
            await MainActor.run {
                host.modelWorkflow.onTerminalState = { recorder.states.append($0.state) }
                host.modelWorkflow.restore(failed)
            }

            await host.modelWorkflow.reconcile(snapshot: nil, jobs: [job])

            await MainActor.run {
                XCTAssertEqual(host.modelWorkflow.history.first { $0.id == failed.id }, failed, agentState)
                XCTAssertEqual(host.modelWorkflow.workflow, failed, agentState)
                XCTAssertFalse(host.modelWorkflow.consumeCompletionRescanRequest(), agentState)
            }
            XCTAssertEqual(recorder.states, [], agentState)
        }
    }

    func testJobOfANewerRunLeavesAnOlderInFlightRecordAlone() async {
        let failedJob = Job(receipt: "receipt-1", repo: nil, source: nil, qBits: 4, out: "/Models/source", pid: nil, logPath: nil, startedAt: nil, completedAt: nil, state: "failed")
        let host = await makeHost(jobs: [failedJob])
        let older = makeWorkflow(id: "old", state: .running, receipt: "receipt-1", agentState: "running")
        let newer = makeWorkflow(state: .failed, receipt: "receipt-1", message: "Conversion failed.", errorMessage: "Conversion failed.", agentState: "failed", createdAt: Date(timeIntervalSinceReferenceDate: 30))
        await MainActor.run {
            host.modelWorkflow.restore(older)
            host.modelWorkflow.restore(newer)
        }

        await host.modelWorkflow.reconcile(snapshot: nil, jobs: [failedJob])

        await MainActor.run {
            XCTAssertEqual(host.modelWorkflow.history.first { $0.id == older.id }, older)
            XCTAssertEqual(host.modelWorkflow.history.first { $0.id == newer.id }, newer)
        }
    }

    func testVerificationResolutionNotifiesTheTerminalOutcome() async {
        let host = await makeHost()
        let recorder = TerminalStateRecorder()
        let record = makeWorkflow(state: .verifying, receipt: "receipt-1", completedModelPath: "/Models/ready")

        await MainActor.run {
            host.modelWorkflow.onTerminalState = { recorder.states.append($0.state) }
            host.modelWorkflow.restore(record)
            host.modelWorkflow.resolveVerification(recordID: record.id, resolution: .passed(summary: "canary ok"))
        }

        XCTAssertEqual(recorder.states, [.verified])
    }

    func testVerificationFailureNotifiesOnceEvenWhenRepeated() async {
        let host = await makeHost()
        let recorder = TerminalStateRecorder()
        let record = makeWorkflow(state: .verifying, receipt: "receipt-1", completedModelPath: "/Models/ready")

        await MainActor.run {
            host.modelWorkflow.onTerminalState = { recorder.states.append($0.state) }
            host.modelWorkflow.restore(record)
            host.modelWorkflow.resolveVerification(recordID: record.id, resolution: .failed(summary: "canary mismatch"))
        }

        XCTAssertEqual(recorder.states, [.verificationFailed])
    }

    func testRestoringATerminalRecordDoesNotNotify() async {
        let host = await makeHost()
        let recorder = TerminalStateRecorder()

        await MainActor.run {
            host.modelWorkflow.onTerminalState = { recorder.states.append($0.state) }
            host.modelWorkflow.restore(makeWorkflow(state: .completed, receipt: "receipt-1", completedModelPath: "/Models/ready"))
            host.modelWorkflow.restore(makeWorkflow(id: "old", state: .failed, receipt: "receipt-2"))
        }

        XCTAssertTrue(recorder.states.isEmpty)
    }

    @MainActor
    func testAnOlderServeStatusReplyNeverReplacesANewerOne() async throws {
        let replies = StatusReplies()
        let api = ModelWorkflowAPI(
            convertPreview: { _, _, _ in [:] },
            convertStart: { _, _, _, _ in [:] },
            convertStatus: { [] },
            servePreview: { _, _, _ in [:] },
            serveStart: { _, _, _, _ in [:] },
            serveStatus: { try await replies.next() },
            serveStop: { _ in [:] }
        )
        let coordinator = ModelWorkflowCoordinator(api: api, persistence: ModelWorkflowPersistence(load: { [] }, upsert: { _ in }))
        let running = ServerInfo(path: "/models/m", runtime: "mlx_lm", port: 8080, pid: 1, state: "running")

        let older = Task { await coordinator.refreshServers() }
        try await replies.waitForRequests(1)
        let newer = Task { await coordinator.refreshServingStatus() }
        try await replies.waitForRequests(2)

        await replies.answer(1, with: .success([running]))
        let newerRead = await newer.value
        await replies.answer(0, with: .success([]))
        await older.value
        XCTAssertTrue(newerRead)
        XCTAssertEqual(coordinator.servers.map(\.port), [8080], "the older empty reply arrived last and was not shown")

        let olderFailure = Task { await coordinator.refreshServers() }
        try await replies.waitForRequests(3)
        let newerSuccess = Task { await coordinator.refreshServers() }
        try await replies.waitForRequests(4)
        await replies.answer(3, with: .success([running]))
        await newerSuccess.value
        await replies.answer(2, with: .failure(BridgeError.skillFailed))
        await olderFailure.value
        XCTAssertNil(coordinator.serversError, "the older failure arrived last and was not shown")

        let latest = Task { await coordinator.refreshServers() }
        try await replies.waitForRequests(5)
        await replies.answer(4, with: .success([]))
        await latest.value
        XCTAssertTrue(coordinator.servers.isEmpty, "a newer reply still replaces the shown one")
    }

    func testPreparingToServeAVerifiedRecordKeepsItVerified() async throws {
        let store = makeStore()
        let snapshot = snapshotWithEquivalentMLX()
        let model = try XCTUnwrap(snapshot.models.first)
        let path = existingMLXPath
        let started = FlagBox()
        let host = await makeHost(
            snapshot: snapshot,
            onServeStart: { _, _ in await started.set(true) },
            dynamicServers: {
                await started.value ? [ServerInfo(path: path, runtime: "mlx_lm", port: 8080, pid: 1, state: "running")] : []
            },
            store: store
        )
        let recorder = TerminalStateRecorder()
        let record = makeWorkflow(
            state: .verified,
            receipt: "receipt-1",
            completedModelPath: path,
            message: "Verification passed. canary ok",
            reclaimSourceAfterVerification: true
        )

        await MainActor.run {
            host.modelWorkflow.onTerminalState = { recorder.states.append($0.state) }
            host.modelWorkflow.restore(record)
            host.modelWorkflow.prepareServe(model: model, exactPath: path)
            XCTAssertEqual(host.modelWorkflow.workflow, record)
            XCTAssertEqual(host.modelWorkflow.history.first { $0.id == record.id }, record)
        }
        XCTAssertTrue(recorder.states.isEmpty)
        XCTAssertTrue(try store.load().isEmpty)

        await host.modelWorkflow.previewServe(runtime: "mlx_lm", port: 8080)
        await host.modelWorkflow.confirmServe(runtime: "mlx_lm", port: 8080)

        let served = await MainActor.run { host.modelWorkflow.workflow }
        XCTAssertEqual(served.serveState, .running)
        XCTAssertEqual(served.state, .verified)
        XCTAssertEqual(try store.load().map(\.state), [.verified])
        XCTAssertTrue(recorder.states.isEmpty)
    }

    func testPreparingToServeACompletedRecordKeepsItCompleted() async throws {
        let store = makeStore()
        let snapshot = snapshotWithEquivalentMLX()
        let model = try XCTUnwrap(snapshot.models.first)
        let path = existingMLXPath
        let host = await makeHost(snapshot: snapshot, store: store)
        let recorder = TerminalStateRecorder()
        let record = makeWorkflow(
            state: .completed,
            receipt: "receipt-1",
            completedModelPath: path,
            message: "Conversion completed and the MLX output was confirmed by a fresh scan."
        )

        await MainActor.run {
            host.modelWorkflow.onTerminalState = { recorder.states.append($0.state) }
            host.modelWorkflow.restore(record)
            host.modelWorkflow.prepareServe(model: model, exactPath: path)
            XCTAssertEqual(host.modelWorkflow.workflow, record)
            XCTAssertEqual(host.modelWorkflow.history.first { $0.id == record.id }, record)
        }
        XCTAssertTrue(recorder.states.isEmpty)
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testPreparingTheSameOutputCannotBypassAnUnsettledOrFailedWorkflow() async throws {
        let snapshot = snapshotWithEquivalentMLX(), model = try XCTUnwrap(snapshotWithEquivalentMLX().models.first)
        for state: ConversionWorkflowState in [.queued, .running, .verifying, .verificationFailed, .failed] {
            let store = makeStore(), host = await makeHost(snapshot: snapshot, store: store)
            await MainActor.run {
                let base = makeWorkflow(state: state, receipt: nil)
                let record = ConversionWorkflow(id: base.id, sourcePath: base.sourcePath, sourceModelKey: base.sourceModelKey,
                    sourceSignature: base.sourceSignature, outputPath: existingMLXPath, previewHash: nil, jobReceipt: nil,
                    completedModelPath: existingMLXPath, state: state, serveState: .idle, message: nil, errorMessage: nil,
                    createdAt: base.createdAt, updatedAt: base.updatedAt, lastKnownAgentState: nil)
                host.modelWorkflow.restore(record)
                host.modelWorkflow.prepareServe(model: model, exactPath: existingMLXPath)
                XCTAssertEqual(host.modelWorkflow.workflow, record, state.rawValue)
            }
            XCTAssertTrue(try store.load().isEmpty)
        }
    }

    func testPreparingToServeAnotherModelLeavesTheCurrentConversionAlone() async throws {
        let store = makeStore()
        let snapshot = snapshotWithEquivalentMLX()
        let model = try XCTUnwrap(snapshot.models.first)
        let path = existingMLXPath
        let host = await makeHost(snapshot: snapshot, store: store)
        let recorder = TerminalStateRecorder()
        let record = makeWorkflow(state: .running, receipt: "receipt-1")

        await MainActor.run {
            host.modelWorkflow.onTerminalState = { recorder.states.append($0.state) }
            host.modelWorkflow.restore(record)
            host.modelWorkflow.prepareServe(model: model)
            XCTAssertEqual(host.modelWorkflow.history.first { $0.id == record.id }, record)
            XCTAssertNotEqual(host.modelWorkflow.workflow.id, record.id)
            XCTAssertEqual(host.modelWorkflow.workflow.state, .completed)
            XCTAssertEqual(host.modelWorkflow.workflow.completedModelPath, path)
        }
        XCTAssertTrue(recorder.states.isEmpty)
        XCTAssertTrue(try store.load().isEmpty)
    }

    private func makeStore() -> ModelWorkflowStore {
        ModelWorkflowStore(fileURL: temporaryURL("workflows.json"))
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-workflow-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    private func makeWorkflow(
        id: String = "workflow",
        state: ConversionWorkflowState,
        receipt: String?,
        completedModelPath: String? = nil,
        message: String? = nil,
        errorMessage: String? = nil,
        agentState: String? = nil,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 10),
        reclaimSourceAfterVerification: Bool? = nil
    ) -> ConversionWorkflow {
        var record = ConversionWorkflow(
            id: workflowID(id),
            sourcePath: "/Models/source.gguf",
            sourceModelKey: "source-model",
            sourceSignature: "signature-1",
            outputPath: "/Models/source",
            previewHash: "preview-1",
            jobReceipt: receipt,
            completedModelPath: completedModelPath,
            state: state,
            serveState: .idle,
            message: message,
            errorMessage: errorMessage,
            createdAt: createdAt,
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            lastKnownAgentState: agentState
        )
        record.reclaimSourceAfterVerification = reclaimSourceAfterVerification
        return record
    }

    private func workflowID(_ value: String) -> UUID {
        switch value {
        case "original": return UUID(uuidString: "00000000-0000-4000-8000-000000000006")!
        case "replacement": return UUID(uuidString: "00000000-0000-4000-8000-000000000007")!
        case "concurrent-one": return UUID(uuidString: "00000000-0000-4000-8000-000000000008")!
        case "concurrent-two": return UUID(uuidString: "00000000-0000-4000-8000-000000000009")!
        case "old": return UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        case "keep": return UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        case "remove": return UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        case "remain": return UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
        default: return UUID(uuidString: "00000000-0000-4000-8000-000000000005")!
        }
    }

    func testDismissRemovesFailedRecordAndResetsActiveWorkflow() async {
        let host = await makeHost()
        let record = makeWorkflow(id: "remove", state: .failed, receipt: nil)

        await MainActor.run {
            host.modelWorkflow.restore(record)
            XCTAssertEqual(host.modelWorkflow.workflow.state, .failed)
            XCTAssertTrue(host.modelWorkflow.history.contains(where: { $0.id == record.id }))

            host.modelWorkflow.dismiss(recordID: record.id)

            XCTAssertEqual(host.modelWorkflow.workflow.state, .idle)
            XCTAssertFalse(host.modelWorkflow.history.contains(where: { $0.id == record.id }))
        }
    }

    func testDismissLeavesOtherRecordsAndActiveWorkflowAlone() async {
        let host = await makeHost()
        let failed = makeWorkflow(id: "remove", state: .failed, receipt: nil)
        let active = makeWorkflow(id: "remain", state: .completed, receipt: "receipt-2", completedModelPath: "/Models/other")

        await MainActor.run {
            host.modelWorkflow.restore(failed)
            host.modelWorkflow.restore(active)
            host.modelWorkflow.dismiss(recordID: failed.id)

            XCTAssertEqual(host.modelWorkflow.workflow.id, active.id)
            XCTAssertTrue(host.modelWorkflow.history.contains(where: { $0.id == active.id }))
            XCTAssertFalse(host.modelWorkflow.history.contains(where: { $0.id == failed.id }))
        }
    }

    private let existingMLXPath = "/Models/existing-mlx"
    private var ggufSource: ModelItem {
        ModelItem(
            path: "/Models/source.gguf", name: "source", bytes: 1, modifiedAt: nil, shard: nil,
            modelKey: "source-model", architecture: nil, quantization: nil, parameters: nil,
            structure: nil, signature: "signature-1", companion: nil, readable: true,
            status: "pending", outputs: [], tensorCount: nil, error: nil
        )
    }

    private func snapshotWithEquivalentMLX() -> LibrarySnapshot {
        let item = ModelItem(
            path: existingMLXPath, name: "existing", bytes: 1, modifiedAt: nil, shard: nil,
            modelKey: "source-model", architecture: nil, quantization: nil, parameters: nil,
            structure: nil, signature: "signature-1", companion: nil, readable: true,
            status: "ready", outputs: [], tensorCount: nil, error: nil
        )
        return LibrarySnapshot(
            models: [LibraryModel(item: item)],
            groups: [],
            hardware: HardwareProfile.current(),
            generatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
    }

    private func makeHost(
        snapshot: LibrarySnapshot? = nil,
        preview: [String: Any] = ["preview_hash": "preview-1"],
        confirmReceipt: String = "receipt-1",
        confirmResponse: [String: Any]? = nil,
        jobs: [Job] = [],
        statusError: Error? = nil,
        onStatus: (@Sendable () async -> Void)? = nil,
        onServeStart: (@Sendable (String, Int?) async -> Void)? = nil,
        servers: [ServerInfo] = [],
        dynamicServers: (@Sendable () async -> [ServerInfo])? = nil,
        scanOperation: (@Sendable ([String], [String], Bool, Int?) async throws -> ScanResult)? = nil,
        store: ModelWorkflowStore? = nil
    ) async -> AppHost {
        let api = ModelWorkflowAPI(
            convertPreview: { _, _, _ in preview },
            convertStart: { _, _, _, _ in confirmResponse ?? ["receipt": confirmReceipt] },
            convertStatus: {
                if let onStatus { await onStatus() }
                if let statusError { throw statusError }
                return jobs
            },
            servePreview: { _, _, _ in ["preview_hash": "serve-hash"] },
            serveStart: { _, runtime, port, _ in
                if let onServeStart { await onServeStart(runtime, port) }
                return ["receipt": "serve-receipt"]
            },
            serveStatus: {
                if let dynamicServers { return await dynamicServers() }
                return servers
            },
            serveStop: { _ in [:] }
        )
        let store = store ?? makeStore()
        return await MainActor.run {
            let host = AppHost(
                config: Config.defaults(),
                scanOperation: scanOperation,
                modelWorkflowAPI: api,
                modelWorkflowPersistence: .live(store: store)
            )
            host.librarySnapshot = snapshot
            return host
        }
    }

    private func scanResult(outputs: [MLXOutput]) -> ScanResult {
        ScanResult(
            roots: nil,
            models: [ggufSource],
            outputs: outputs,
            pending: [ggufSource.path],
            duplicates: [],
            totals: ScanTotals(
                gguf: 1,
                pending: 1,
                converted: outputs.count,
                unreadable: 0,
                bytes: 1,
                reclaimableBytes: 0
            )
        )
    }

    private enum TestError: LocalizedError {
        case replacementFailed
        case offline

        var errorDescription: String? {
            switch self {
            case .replacementFailed: return "replacement failed"
            case .offline: return "offline"
            }
        }
    }
}

private actor FlagBox {
    private(set) var value = false
    func set(_ newValue: Bool) { value = newValue }
}

private final class TerminalStateRecorder {
    var states: [ConversionWorkflowState] = []
}

/// Serve status requests that wait until the test answers each one by arrival index.
private actor StatusReplies {
    private var pending: [CheckedContinuation<[ServerInfo], Error>] = []

    func next() async throws -> [ServerInfo] {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func answer(_ index: Int, with reply: Result<[ServerInfo], Error>) {
        pending[index].resume(with: reply)
    }

    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<1000 where pending.count < count {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertGreaterThanOrEqual(pending.count, count, "serve status requests reached the API")
    }
}

@MainActor
private final class StubCompletionVerifier: ConversionCompletionVerifying {
    private(set) var calls: [(UUID, String, String?)] = []

    func beginVerification(recordID: UUID, modelPath: String, signature: String?) {
        calls.append((recordID, modelPath, signature))
    }
}

private actor ScanSequence {
    private var values: [ScanResult]
    private(set) var count = 0

    init(_ values: [ScanResult]) {
        self.values = values
    }

    func next() throws -> ScanResult {
        guard !values.isEmpty else { throw TestSequenceError.exhausted }
        count += 1
        return values.removeFirst()
    }
}

private actor ServeLaunchRecorder {
    private var launches: [(String, Int?)] = []

    func record(runtime: String, port: Int?) {
        launches.append((runtime, port))
    }

    var count: Int { launches.count }
}

private enum TestSequenceError: Error {
    case exhausted
}

private actor WorkflowEventLog {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}
