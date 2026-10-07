import XCTest
import AppKit
import SwiftUI
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

    func testImportPreviewDoesNotWriteAndConfirmDetectsStoreDrift() throws {
        let disk = try store()
        let evidence = WorkflowEvidenceStore(store: disk)
        let fact = record()
        let data = try WorkflowEvidenceStore.encode(WorkflowReport(schemaVersion: 1, records: [fact]))
        let preview = try evidence.previewReport(data)
        XCTAssertEqual(preview.newRecords.count, 1)
        XCTAssertEqual(preview.duplicateCount, 0)
        XCTAssertTrue(evidence.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.url.path))
        XCTAssertEqual(try evidence.confirmImport(preview), 1)
        let repeated = try evidence.previewReport(data)
        XCTAssertTrue(repeated.newRecords.isEmpty)
        XCTAssertEqual(repeated.duplicateCount, 1)
        try disk.replaceAll([record()])
        XCTAssertThrowsError(try evidence.confirmImport(repeated))
        XCTAssertNotEqual(try disk.load(), evidence.records, "External changes must be preserved")
    }

    func testPreviewShowsExactIdentityMismatchWithoutRewritingTheReport() throws {
        let fact = record()
        XCTAssertEqual(WorkflowImportIdentity.status(fact, models: [WorkflowCaptureModel(path: fact.modelPath, name: "A", signature: fact.modelSignature)], environment: fact.environmentFingerprint), .matching)
        XCTAssertEqual(WorkflowImportIdentity.status(fact, models: [], environment: fact.environmentFingerprint), .missingModel)
        XCTAssertEqual(WorkflowImportIdentity.status(fact, models: [WorkflowCaptureModel(path: fact.modelPath, name: "A", signature: "changed")], environment: fact.environmentFingerprint), .changedModel)
        XCTAssertEqual(WorkflowImportIdentity.status(fact, models: [WorkflowCaptureModel(path: fact.modelPath, name: "A", signature: fact.modelSignature)], environment: "changed"), .changedEnvironment)
        XCTAssertEqual(WorkflowImportIdentity.status(fact, models: [WorkflowCaptureModel(path: fact.modelPath, name: "A", signature: nil)], environment: fact.environmentFingerprint), .unknownModel)
        XCTAssertEqual(WorkflowImportIdentity.status(fact, models: [WorkflowCaptureModel(path: fact.modelPath, name: "A", signature: fact.modelSignature)], environment: "mac|unknown|1"), .unknownEnvironment)
        XCTAssertEqual(fact.measuredAt, Date(timeIntervalSince1970: 1_700_000_000.123))
    }

    func testCaptureRequestContainsContextButNoInventedMeasurements() throws {
        let model = WorkflowCaptureModel(path: "/models/a", name: "A", signature: "weights")
        let kit = try WorkflowCaptureRequest.make(harness: .openCode, model: model, environment: "mac|chip|1", now: Date(timeIntervalSince1970: 42))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: WorkflowEvidenceStore.encode(kit)) as? [String: Any])
        let report = try XCTUnwrap(json["reportDraft"] as? [String: Any])
        let records = try XCTUnwrap(report["records"] as? [[String: Any]])
        XCTAssertEqual(records[0]["harness"] as? String, "opencode")
        XCTAssertEqual(records[0]["modelSignature"] as? String, "weights")
        XCTAssertTrue(records[0]["measuredAt"] is NSNull)
        XCTAssertTrue(records[0]["totalSeconds"] is NSNull)
        XCTAssertTrue(records[0]["sampleCount"] is NSNull)
        XCTAssertTrue(kit.instructions.contains("Never reuse this context for an older run"))
        XCTAssertThrowsError(try WorkflowEvidenceStore.decode(WorkflowEvidenceStore.encode(kit)))
        let unknown = try WorkflowCaptureRequest.make(harness: .claude, model: WorkflowCaptureModel(path: "/a", name: "A", signature: nil), environment: "mac|unknown|1")
        let unknownJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: WorkflowEvidenceStore.encode(unknown)) as? [String: Any])
        let unknownDraft = try XCTUnwrap(unknownJSON["reportDraft"] as? [String: Any])
        let unknownRecords = try XCTUnwrap(unknownDraft["records"] as? [[String: Any]])
        XCTAssertTrue(unknownRecords[0]["modelSignature"] is NSNull)
        XCTAssertTrue(unknownRecords[0]["environmentFingerprint"] is NSNull)
        XCTAssertThrowsError(try WorkflowCaptureRequest.make(harness: .openClaw, model: WorkflowCaptureModel(path: "relative", name: "A", signature: nil), environment: nil))
    }

    private func wiredTransaction(server: ServerInfo, clients: [String] = ["opencode"]) -> WiringTransaction {
        WiringTransaction(id: UUID(), previewHash: "reviewed", endpointBaseURL: "http://127.0.0.1:8766/v1",
            modelName: server.modelIdentity, appliedAt: Date(timeIntervalSince1970: 42),
            receipts: clients.map { ClientEditReceipt(clientID: $0, configPath: "/test/\($0)", backupPath: nil, appliedAt: Date(timeIntervalSince1970: 42)) }, failures: [])
    }

    func testWiredCaptureExportsSuccessfulClientAndExactEndpointWithoutMeasurements() throws {
        let server = ServerInfo(path: "/models/a", runtime: "mlx_lm", port: 8766, pid: 7, state: "running")
        var transaction = wiredTransaction(server: server)
        transaction.failures = ["Zed: config drift"]
        let capture = try WiredWorkflowCapture.make(reviewedServer: server, currentServers: [server], transaction: transaction,
            models: [WorkflowCaptureModel(path: "/models/a", name: "A", signature: "weights")])
        let request = try WorkflowCaptureRequest.make(harness: capture.harness, model: capture.model, environment: "mac|chip|1", endpoint: capture.endpoint)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: WorkflowEvidenceStore.encode(request)) as? [String: Any])
        let endpoint = try XCTUnwrap(json["endpoint"] as? [String: Any])
        XCTAssertEqual(endpoint["baseURL"] as? String, "http://127.0.0.1:8766/v1")
        XCTAssertEqual(endpoint["modelIdentity"] as? String, "/models/a")
        XCTAssertEqual(endpoint["clientIDs"] as? [String], ["opencode"])
        let draft = try XCTUnwrap(json["reportDraft"] as? [String: Any])
        let record = try XCTUnwrap((draft["records"] as? [[String: Any]])?.first)
        XCTAssertEqual(record["harness"] as? String, "opencode")
        XCTAssertTrue(record["configurationFingerprint"] is NSNull)
        XCTAssertTrue(record["totalSeconds"] is NSNull)
        XCTAssertTrue(record["measuredAt"] is NSNull)
        XCTAssertThrowsError(try WorkflowEvidenceStore.decode(WorkflowEvidenceStore.encode(request)))
    }

    func testWiredCaptureRefusesChangedStoppedRolledBackOrUnwrittenEndpoint() throws {
        let server = ServerInfo(path: "/models/a", port: 8766, pid: 7, state: "running")
        let model = WorkflowCaptureModel(path: "/models/a", name: "A", signature: "weights")
        let transaction = wiredTransaction(server: server)
        for current in [[], [ServerInfo(path: "/models/a", port: 8766, pid: 8, state: "running")],
                        [ServerInfo(path: "/models/a", port: 8766, pid: 7, state: "stopped")], [server, server]] {
            XCTAssertThrowsError(try WiredWorkflowCapture.make(reviewedServer: server, currentServers: current, transaction: transaction, models: [model]))
        }
        var rolledBack = transaction
        rolledBack.rolledBackAt = Date()
        XCTAssertThrowsError(try WiredWorkflowCapture.make(reviewedServer: server, currentServers: [server], transaction: rolledBack, models: [model]))
        XCTAssertThrowsError(try WiredWorkflowCapture.make(reviewedServer: server, currentServers: [server], transaction: wiredTransaction(server: server, clients: []), models: [model]))
        XCTAssertThrowsError(try WiredWorkflowCapture.make(reviewedServer: server, currentServers: [server], transaction: transaction, models: []))
    }

    func testWiredRepoCaptureRefusesAmbiguousLocalRevisionsAndDoesNotInventHarness() throws {
        let server = ServerInfo(repo: "org/model", port: 8766, pid: 7, state: "running")
        let models = [WorkflowCaptureModel(path: "/cache/models--org--model/snapshots/a", name: "A", signature: "a"),
                      WorkflowCaptureModel(path: "/cache/models--org--model/snapshots/b", name: "B", signature: "b")]
        let transaction = wiredTransaction(server: server, clients: ["zed"])
        XCTAssertThrowsError(try WiredWorkflowCapture.make(reviewedServer: server, currentServers: [server], transaction: transaction, models: models))
        let capture = try WiredWorkflowCapture.make(reviewedServer: server, currentServers: [server], transaction: transaction, models: [models[0]])
        XCTAssertEqual(capture.harness, .custom)
        let otherModel = WorkflowCaptureModel(path: "/models/other", name: "Other", signature: "other")
        XCTAssertThrowsError(try WorkflowCaptureRequest.make(harness: .custom, model: otherModel, environment: nil, endpoint: capture.endpoint))
        let remote = WorkflowCaptureEndpoint(baseURL: "http://example.com:8766/v1", modelIdentity: "org/model", clientIDs: ["zed"],
            wiringTransactionID: transaction.id, wiredAt: transaction.appliedAt)
        XCTAssertThrowsError(try WorkflowCaptureRequest.make(harness: .custom, model: models[0], environment: nil, endpoint: remote))
    }

    func testWiredCaptureAndProducedReportRenderWithoutAutomaticallySavingEvidence() async throws {
        let server = ServerInfo(path: "/models/Qwen-converted-4bit", port: 8766, pid: 7, state: "running")
        let model = WorkflowCaptureModel(path: "/models/Qwen-converted-4bit", name: "Qwen converted 4-bit", signature: "weights")
        let capture = try WiredWorkflowCapture.make(reviewedServer: server, currentServers: [server],
            transaction: wiredTransaction(server: server), models: [model])
        try await attachView(WorkflowCaptureRequestView(models: [model], initialModelPath: model.path, environment: "mac|chip|1",
            endpoint: capture.endpoint, initialHarness: capture.harness, onImport: {}), name: "Wired workflow capture request", height: 540)

        // A producer fills the run fields; wiring context alone is not importable.
        let request = try WorkflowCaptureRequest.make(harness: capture.harness, model: model, environment: "mac|chip|1", endpoint: capture.endpoint)
        let encoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: WorkflowEvidenceStore.encode(request)) as? [String: Any])
        var draft = try XCTUnwrap(encoded["reportDraft"] as? [String: Any])
        var records = try XCTUnwrap(draft["records"] as? [[String: Any]])
        records[0]["workloadID"] = "coding-task"
        records[0]["measuredAt"] = "2026-01-01T12:00:00Z"
        records[0]["sampleCount"] = 3
        records[0]["totalSeconds"] = 24.0
        records[0]["source"] = "session:local-fixture"
        records[0].removeValue(forKey: "configurationFingerprint")
        draft["records"] = records
        let disk = try store()
        let evidence = WorkflowEvidenceStore(store: disk)
        let preview = try evidence.previewReport(JSONSerialization.data(withJSONObject: draft))
        XCTAssertTrue(evidence.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.url.path))
        XCTAssertEqual(preview.newRecords.first?.modelPath, "/models/Qwen-converted-4bit")
        XCTAssertEqual(preview.newRecords.first?.totalSeconds, 24)
        XCTAssertNil(preview.newRecords.first?.qualityScore)
        XCTAssertNil(preview.newRecords.first?.inferenceSeconds)
        XCTAssertNil(preview.newRecords.first?.peakMemoryBytes)
        try await attachView(WorkflowImportPreviewView(preview: preview, models: [model], environment: "mac|chip|1",
            onCancel: {}, onConfirm: {}), name: "Produced workflow report review", height: 460)
        XCTAssertEqual(try evidence.confirmImport(preview), 1)
        XCTAssertEqual(try disk.load().first?.source, "session:local-fixture")
    }

    private func attachView<V: View>(_ root: V, name: String, height: CGFloat) async throws {
        let view = NSHostingView(rootView: root.background(WorkbenchColor.canvas).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let attachment = XCTAttachment(data: try XCTUnwrap(image.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testImportConfirmsFrozenReportAfterOriginalFileChanges() throws {
        let disk = try store()
        let evidence = WorkflowEvidenceStore(store: disk)
        let file = disk.url.appendingPathExtension("input.json")
        let fact = record()
        try WorkflowEvidenceStore.encode(WorkflowReport(schemaVersion: 1, records: [fact])).write(to: file)
        let preview = try evidence.previewReport(WorkflowEvidenceStore.readReport(file))
        try Data("changed after preview".utf8).write(to: file)
        XCTAssertEqual(try evidence.confirmImport(preview), 1)
        XCTAssertEqual(try disk.load(), [fact], "Confirm saves exactly the observations reviewed, not changed file contents")
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
