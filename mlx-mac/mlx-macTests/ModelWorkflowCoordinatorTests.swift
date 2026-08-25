import Foundation
import XCTest

@testable import mlx_workbench

final class ModelWorkflowCoordinatorTests: XCTestCase {
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

    private enum TestError: Error {
        case replacementFailed
    }
}
