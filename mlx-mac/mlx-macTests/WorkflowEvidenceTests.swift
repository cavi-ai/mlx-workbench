import XCTest
@testable import mlx_workbench

@MainActor
final class WorkflowEvidenceTests: XCTestCase {
    private func record() -> WorkflowEvidence {
        WorkflowEvidence(id: UUID(), harness: "opencode", workloadID: "coding", useCase: .coding, modelPath: "/models/a", modelSignature: "weights", environmentFingerprint: "mac|chip|1", measuredAt: Date(timeIntervalSince1970: 1_700_000_000.123), sampleCount: 3, totalSeconds: 10, source: "session:one")
    }
    private func store() throws -> JSONStore<WorkflowEvidence> {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-report-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return JSONStore(fileURL: root.appendingPathComponent("reports.json"))
    }
    func testImportRestartIdempotencyAndConflictingIDs() throws {
        let disk = try store()
        let evidence = WorkflowEvidenceStore(store: disk)
        let fact = record()
        let report = WorkflowReport(schemaVersion: 1, records: [fact])
        let encoded = try WorkflowEvidenceStore.encode(report)
        let decoded = try WorkflowEvidenceStore.decode(encoded)
        XCTAssertEqual(decoded.records[0].measuredAt.timeIntervalSince1970, fact.measuredAt.timeIntervalSince1970, accuracy: 0.000001)
        XCTAssertEqual(try evidence.importReport(encoded), 1)
        XCTAssertEqual(try evidence.importReport(encoded), 0)
        let restart = WorkflowEvidenceStore(store: disk)
        XCTAssertEqual(restart.records, evidence.records)
        XCTAssertEqual(try restart.importReport(WorkflowEvidenceStore.encode(WorkflowReport(schemaVersion: 1, records: restart.records))), 0)
        var conflict = fact
        conflict.toolSeconds = 1
        XCTAssertThrowsError(try restart.importReport(WorkflowEvidenceStore.encode(WorkflowReport(schemaVersion: 1, records: [conflict]))))
        XCTAssertEqual(restart.records, evidence.records)
    }
    func testImporterRejectsBadMetricsAndQuality() throws {
        var fact = record()
        fact.inferenceSeconds = 8
        fact.toolSeconds = 3
        XCTAssertThrowsError(try fact.validate())
        fact.inferenceSeconds = nil
        fact.toolSeconds = nil
        fact.tokensPerSecond = .infinity
        XCTAssertThrowsError(try fact.validate())
        fact.tokensPerSecond = -1
        XCTAssertThrowsError(try fact.validate())
        fact.tokensPerSecond = nil
        fact.qualityScore = 5
        XCTAssertThrowsError(try fact.validate())
        fact.rubricID = "rubric\nsecret"
        XCTAssertThrowsError(try fact.validate())
        fact.rubricID = "outcome-v1"
        XCTAssertNoThrow(try fact.validate())
        fact.peakMemoryBytes = -1
        XCTAssertThrowsError(try fact.validate())
    }
    func testSizeSchemaDuplicatesAndCorruptStoreAreRejected() throws {
        XCTAssertThrowsError(try WorkflowEvidenceStore.decode(Data(repeating: 0, count: WorkflowEvidenceStore.maxBytes + 1)))
        XCTAssertThrowsError(try WorkflowEvidenceStore.decode(WorkflowEvidenceStore.encode(WorkflowReport(schemaVersion: 2, records: []))))
        let fact = record()
        XCTAssertThrowsError(try WorkflowEvidenceStore.decode(WorkflowEvidenceStore.encode(WorkflowReport(schemaVersion: 1, records: [fact, fact]))))
        let disk = try store()
        try Data("corrupt".utf8).write(to: disk.url)
        let evidence = WorkflowEvidenceStore(store: disk)
        XCTAssertThrowsError(try evidence.importReport(WorkflowEvidenceStore.encode(WorkflowReport.template)))
        XCTAssertEqual(try Data(contentsOf: disk.url), Data("corrupt".utf8))
    }
    func testUnknownComponentsStayUnknownAndTemplateIsEmpty() throws {
        var fact = record()
        XCTAssertNil(fact.unattributedSeconds)
        fact.inferenceSeconds = 5
        fact.toolSeconds = 2
        XCTAssertNil(fact.unattributedSeconds)
        fact.queueSeconds = 1
        XCTAssertEqual(fact.unattributedSeconds, 2)
        let template = try WorkflowEvidenceStore.decode(WorkflowEvidenceStore.encode(WorkflowReport.template))
        XCTAssertTrue(template.records.isEmpty)
        XCTAssertTrue(template.guidance?.contains("No measurements") == true)
    }
    func testBenchmarkUsageDoesNotChangeLastServedAndLegacyDecode() throws {
        let disk = JSONStore<UsageStamp>(fileURL: try store().url.appendingPathExtension("usage"))
        var time = Date(timeIntervalSince1970: 1)
        let tracker = UsageTracker(store: disk, now: { time })
        tracker.recordServed("/a")
        time = Date(timeIntervalSince1970: 2)
        tracker.record("/b")
        tracker.record("/a")
        XCTAssertEqual(tracker.lastServedByPath["/a"], Date(timeIntervalSince1970: 1))
        XCTAssertNil(tracker.lastServedByPath["/b"])
        XCTAssertEqual(UsageTracker(store: disk).lastServedByPath, tracker.lastServedByPath)
        let legacy = try JSONDecoder().decode(UsageStamp.self, from: Data(#"{"path":"/legacy","lastUsedAt":0}"#.utf8))
        XCTAssertNil(legacy.lastServedAt)
    }
}
