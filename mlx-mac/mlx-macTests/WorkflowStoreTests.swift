import Foundation
import XCTest
import SQLite3

@testable import mlx_workbench

func executeHistorySQL(_ url: URL, _ sql: String) throws {
    var connection: OpaquePointer?
    guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        if let connection { sqlite3_close(connection) }
        throw WorkflowEvidenceError.invalid("Could not open test history")
    }
    defer { sqlite3_close(connection) }
    guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
        throw WorkflowEvidenceError.invalid(String(cString: sqlite3_errmsg(connection)))
    }
}

func rejectHistoryWrites(_ url: URL) throws {
    try executeHistorySQL(url, "CREATE TRIGGER reject_write BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'Write unavailable'); END")
}

/// Durable state stores: same atomic-replace + corruption-blocking contract
/// as JSONStore, exercised against the real record types.
final class WorkflowStoreTests: XCTestCase {
    private let stamp = Date(timeIntervalSinceReferenceDate: 1_000_000_000)

    func testWorkflowMigrationKeepsTheOriginalJSONAfterRecordUpdates() throws {
        let url = storeURL("workflow-migration")
        let original = workflow(sourcePath: "/models/a.gguf")
        let backup = try JSONEncoder().encode([original])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try backup.write(to: url)
        let store = ModelWorkflowStore(fileURL: url)
        XCTAssertEqual(try store.load(), [original])
        let updated = workflow(id: original.id, sourcePath: original.sourcePath, state: .verified)
        try store.upsert(updated)
        XCTAssertEqual(try store.load(), [updated])
        XCTAssertEqual(try Data(contentsOf: url), backup, "Migrated JSON remains a recovery source")
    }

    func testVerificationMigrationKeepsTheOriginalJSONAfterRecordUpdates() throws {
        let url = storeURL("verification-migration"), original = report(modelPath: "/models/a")
        let backup = try JSONEncoder().encode([original])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try backup.write(to: url)
        let store = VerificationStore(fileURL: url)
        XCTAssertEqual(try store.load(), [original])
        var updated = original; updated.outcome = .failed(canaryIDs: ["canary-1"])
        try store.upsert(updated)
        XCTAssertEqual(try store.load(), [updated])
        XCTAssertEqual(try Data(contentsOf: url), backup, "Migrated JSON remains a recovery source")
    }

    func testWorkflowUpsertDoesNotReadOrRewriteOtherRecords() throws {
        let url = storeURL("independent-workflows")
        let first = workflow(sourcePath: "/models/a.gguf"), second = workflow(sourcePath: "/models/b.gguf")
        let store = ModelWorkflowStore(fileURL: url)
        try store.replace([first, second])
        try executeHistorySQL(store.databaseURL,
            "UPDATE records SET payload=x'7b',summary=x'7b' WHERE id='\(second.id.uuidString)'")
        let updated = workflow(id: first.id, sourcePath: first.sourcePath, state: .verified)
        try store.upsert(updated)
        let archive = RecordArchive<ConversionWorkflow>(legacyURL: url)
        XCTAssertEqual(try archive.record(id: first.id), updated)
        XCTAssertThrowsError(try archive.record(id: second.id), "Unrelated corruption must remain visible")
        XCTAssertThrowsError(try store.load())
    }

    // MARK: - ModelWorkflowStore

    func testWorkflowUpsertReplaceRemoveRoundTrip() throws {
        let store = ModelWorkflowStore(fileURL: storeURL("workflows"))
        let first = workflow(sourcePath: "/models/a.gguf")
        let second = workflow(sourcePath: "/models/b.gguf")

        try store.upsert(first)
        try store.upsert(second)
        XCTAssertEqual(try store.load().count, 2)

        var updated = first
        updated = workflow(id: first.id, sourcePath: first.sourcePath, state: .verified)
        try store.upsert(updated)
        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first { $0.id == first.id }?.state, .verified)

        try store.remove(id: first.persistenceIdentifier)
        XCTAssertEqual(try store.load().map(\.id), [second.id])

        try store.replace([])
        XCTAssertEqual(try store.load(), [])
    }

    func testWorkflowCorruptFileThrowsAndBlocksWrites() throws {
        let url = storeURL("workflows")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: url)
        let before = try Data(contentsOf: url)

        let store = ModelWorkflowStore(fileURL: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.upsert(workflow(sourcePath: "/models/a.gguf")))
        XCTAssertThrowsError(try store.remove(id: "anything"))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    // MARK: - VerificationStore

    func testVerificationUpsertByIDRoundTrips() throws {
        let store = VerificationStore(fileURL: storeURL("verification"))
        let report = report(modelPath: "/models/a")
        try store.upsert(report)
        XCTAssertEqual(try store.load(), [report])

        var updated = report
        updated.outcome = .failed(canaryIDs: ["canary-1"])
        try store.upsert(updated)

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.outcome, .failed(canaryIDs: ["canary-1"]))
    }

    func testVerificationCorruptFileThrowsAndBlocksWrites() throws {
        let url = storeURL("verification")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]]".utf8).write(to: url)
        let before = try Data(contentsOf: url)

        let store = VerificationStore(fileURL: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.upsert(report(modelPath: "/models/a")))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    // MARK: - Helpers

    private func storeURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-stores-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("\(name).json", isDirectory: false)
    }

    private func workflow(
        id: UUID = UUID(),
        sourcePath: String,
        state: ConversionWorkflowState = .queued
    ) -> ConversionWorkflow {
        ConversionWorkflow(
            id: id,
            sourcePath: sourcePath,
            sourceModelKey: nil,
            sourceSignature: nil,
            outputPath: "/out/model",
            previewHash: nil,
            jobReceipt: nil,
            completedModelPath: nil,
            state: state,
            serveState: .idle,
            message: nil,
            errorMessage: nil,
            createdAt: stamp,
            updatedAt: stamp,
            lastKnownAgentState: nil
        )
    }

    private func report(modelPath: String) -> VerificationReport {
        VerificationReport(
            id: UUID(),
            modelPath: modelPath,
            modelSignature: nil,
            workflowRecordID: nil,
            suiteVersion: 1,
            canaries: [],
            tokensPerSecond: nil,
            timeToFirstTokenSeconds: nil,
            metricsEstimated: false,
            startedAt: stamp,
            finishedAt: stamp,
            outcome: .passed
        )
    }
}
