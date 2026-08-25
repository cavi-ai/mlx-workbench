import Foundation
import XCTest

@testable import mlx_workbench

final class ModelWorkflowCoordinatorTests: XCTestCase {
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
        await host.modelWorkflow.confirm(qBits: 4)

        await MainActor.run {
            XCTAssertEqual(host.modelWorkflow.workflow.state, .queued)
            XCTAssertEqual(host.modelWorkflow.workflow.jobReceipt, "receipt-1")
        }
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

        let failingStore = ModelWorkflowStore(fileURL: url, replaceItem: { _, temporaryURL in
            XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
            throw TestError.replacementFailed
        })
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
        receipt: String?
    ) -> ConversionWorkflow {
        ConversionWorkflow(
            id: workflowID(id),
            sourcePath: "/Models/source.gguf",
            sourceModelKey: "source-model",
            sourceSignature: "signature-1",
            outputPath: "/Models/source",
            previewHash: "preview-1",
            jobReceipt: receipt,
            completedModelPath: nil,
            state: state,
            serveState: .idle,
            message: nil,
            errorMessage: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            lastKnownAgentState: nil
        )
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
        jobs: [Job] = [],
        statusError: Error? = nil,
        onStatus: (@Sendable () async -> Void)? = nil,
        scanOperation: (@Sendable ([String], [String], Bool, Int?) async throws -> ScanResult)? = nil
    ) async -> AppHost {
        let api = ModelWorkflowAPI(
            convertPreview: { _, _, _ in preview },
            convertStart: { _, _, _, _ in ["receipt": confirmReceipt] },
            convertStatus: {
                if let onStatus { await onStatus() }
                if let statusError { throw statusError }
                return jobs
            },
            servePreview: { _, _, _ in ["preview_hash": "serve-hash"] },
            serveStart: { _, _, _, _ in ["receipt": "serve-receipt"] },
            serveStatus: { [] },
            serveStop: { _ in [:] }
        )
        let store = makeStore()
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

private enum TestSequenceError: Error {
    case exhausted
}

private actor WorkflowEventLog {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}
