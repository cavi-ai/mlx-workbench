import Foundation
import XCTest

@testable import mlx_workbench

final class LineageIndexerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000_000)

    func testAssemblesFullTimelineNewestFirst() {
        let item = makeItem(path: "/Models/q4", signature: "sig-1", modifiedDaysAgo: 100)
        let workflow = makeWorkflow(outputPath: "/Models/q4", state: .verified, daysAgo: 90)
        let report = makeReport(modelPath: "/Models/q4", signature: "sig-1", outcome: .passed, daysAgo: 89)
        let run = makeRun(modelPath: "/Models/q4", signature: "sig-1", daysAgo: 80)
        let transaction = makeTransaction(modelName: "q4", daysAgo: 70)
        let usage = ["/Models/q4": now.addingTimeInterval(-60 * 86_400)]

        let lineage = LineageIndexer.assemble(
            modelPath: "/Models/q4",
            item: item,
            workflows: [workflow],
            reports: [report],
            runs: [run],
            lastUsedByPath: usage,
            transactions: [transaction],
            quarantineRecords: []
        )

        XCTAssertEqual(Set(lineage.events.map(\.kind)), [.source, .converted, .verified, .benchmarked, .served, .wired])
        XCTAssertEqual(lineage.events.map(\.at), lineage.events.map(\.at).sorted(by: >))
        XCTAssertTrue(lineage.events.allSatisfy { !$0.stale })
    }

    func testSignatureMismatchMarksEvidenceStale() {
        let report = makeReport(modelPath: "/Models/q4", signature: "old-sig", outcome: .passed, daysAgo: 10)
        let lineage = LineageIndexer.assemble(
            modelPath: "/Models/q4",
            item: makeItem(path: "/Models/q4", signature: "new-sig", modifiedDaysAgo: 1),
            workflows: [],
            reports: [report],
            runs: [],
            lastUsedByPath: [:],
            transactions: [],
            quarantineRecords: []
        )

        let verified = lineage.events.first { $0.kind == .verified }
        XCTAssertEqual(verified?.stale, true)
    }

    func testUnrelatedModelsAreExcluded() {
        let lineage = LineageIndexer.assemble(
            modelPath: "/Models/mine",
            item: nil,
            workflows: [makeWorkflow(outputPath: "/Models/other", state: .verified, daysAgo: 5)],
            reports: [makeReport(modelPath: "/Models/other", signature: nil, outcome: .passed, daysAgo: 4)],
            runs: [makeRun(modelPath: "/Models/other", signature: nil, daysAgo: 3)],
            lastUsedByPath: ["/Models/other": now],
            transactions: [makeTransaction(modelName: "other", daysAgo: 2)],
            quarantineRecords: []
        )
        XCTAssertTrue(lineage.events.isEmpty)
    }

    func testFailedVerificationRendersAsFailureEvent() {
        let report = makeReport(modelPath: "/Models/q4", signature: nil, outcome: .failed(canaryIDs: ["echo"]), daysAgo: 2)
        let lineage = LineageIndexer.assemble(
            modelPath: "/Models/q4",
            item: nil,
            workflows: [],
            reports: [report],
            runs: [],
            lastUsedByPath: [:],
            transactions: [],
            quarantineRecords: []
        )
        XCTAssertEqual(lineage.events.first?.kind, .verificationFailed)
        XCTAssertTrue(lineage.events.first?.summary.contains("echo") == true)
    }

    func testQuarantineEventMatchesOnSourcePath() {
        let record = QuarantineRecord(
            movedAt: ISO8601DateFormatter().string(from: now),
            from: "/Models/q4",
            to: "/quarantine/2026-q4",
            bytes: 1000
        )
        let lineage = LineageIndexer.assemble(
            modelPath: "/Models/q4",
            item: nil,
            workflows: [],
            reports: [],
            runs: [],
            lastUsedByPath: [:],
            transactions: [],
            quarantineRecords: [record]
        )
        XCTAssertEqual(lineage.events.first?.kind, .quarantined)
    }

    func testMarkdownExportContainsKeyFacts() {
        let lineage = LineageIndexer.assemble(
            modelPath: "/Models/q4",
            item: makeItem(path: "/Models/q4", signature: "sig-1", modifiedDaysAgo: 100),
            workflows: [makeWorkflow(outputPath: "/Models/q4", state: .verified, daysAgo: 90)],
            reports: [makeReport(modelPath: "/Models/q4", signature: "sig-1", outcome: .passed, daysAgo: 89)],
            runs: [],
            lastUsedByPath: [:],
            transactions: [],
            quarantineRecords: []
        )
        let markdown = lineage.markdown
        XCTAssertTrue(markdown.contains("# Lineage: q4"))
        XCTAssertTrue(markdown.contains("Signature: sig-1"))
        XCTAssertTrue(markdown.contains("**Converted**"))
        XCTAssertTrue(markdown.contains("**Verified**"))
    }

    func testCodableRoundTrip() throws {
        let lineage = LineageIndexer.assemble(
            modelPath: "/Models/q4",
            item: makeItem(path: "/Models/q4", signature: "sig-1", modifiedDaysAgo: 100),
            workflows: [makeWorkflow(outputPath: "/Models/q4", state: .verified, daysAgo: 90)],
            reports: [],
            runs: [],
            lastUsedByPath: [:],
            transactions: [],
            quarantineRecords: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(lineage)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ModelLineage.self, from: data)
        XCTAssertEqual(decoded.modelPath, lineage.modelPath)
        XCTAssertEqual(decoded.events.count, lineage.events.count)
    }

    // MARK: - Helpers

    private func makeItem(path: String, signature: String?, modifiedDaysAgo: Int) -> ModelItem {
        ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: 1000,
            modifiedAt: Int(now.timeIntervalSince1970) - modifiedDaysAgo * 86_400, shard: nil,
            modelKey: "model", architecture: "qwen3", quantization: "Q4_K_M", parameters: "8B",
            structure: nil, signature: signature, companion: nil, readable: true,
            status: "ready", outputs: [], tensorCount: nil, error: nil
        )
    }

    private func makeWorkflow(outputPath: String, state: ConversionWorkflowState, daysAgo: Int) -> ConversionWorkflow {
        let date = now.addingTimeInterval(TimeInterval(-daysAgo) * 86_400)
        return ConversionWorkflow(
            id: UUID(), sourcePath: "/Models/source.gguf", sourceModelKey: "model",
            sourceSignature: nil, outputPath: outputPath, previewHash: "h",
            jobReceipt: "receipt-1", completedModelPath: outputPath,
            state: state, serveState: .idle, message: nil, errorMessage: nil,
            createdAt: date, updatedAt: date, lastKnownAgentState: nil
        )
    }

    private func makeReport(modelPath: String, signature: String?, outcome: VerificationOutcome, daysAgo: Int) -> VerificationReport {
        VerificationReport(
            id: UUID(), modelPath: modelPath, modelSignature: signature, workflowRecordID: nil,
            suiteVersion: 1,
            canaries: [CanaryResult(id: "echo", title: "Echo", passed: outcome == .passed, failureReason: nil, responseExcerpt: "", tokensPerSecond: 42, timeToFirstTokenSeconds: 0.1)],
            tokensPerSecond: 42, timeToFirstTokenSeconds: 0.1, metricsEstimated: false,
            startedAt: now.addingTimeInterval(TimeInterval(-daysAgo) * 86_400),
            finishedAt: now.addingTimeInterval(TimeInterval(-daysAgo) * 86_400),
            outcome: outcome
        )
    }

    private func makeRun(modelPath: String, signature: String?, daysAgo: Int) -> ComparisonRun {
        let date = now.addingTimeInterval(TimeInterval(-daysAgo) * 86_400)
        return ComparisonRun(
            id: UUID(), promptSetID: "builtin-coding", promptSetName: "Coding basics",
            useCase: .coding, variants: [modelPath],
            results: [VariantResult(
                modelPath: modelPath, modelSignature: signature,
                samples: [ComparisonSample(promptID: "p1", outputExcerpt: "", tokensPerSecond: 50, timeToFirstTokenSeconds: 0.1, error: nil)],
                aggregateTokensPerSecond: 50, aggregateTTFTSeconds: 0.1, error: nil
            )],
            startedAt: date, finishedAt: date, state: .completed
        )
    }

    private func makeTransaction(modelName: String, daysAgo: Int) -> WiringTransaction {
        WiringTransaction(
            id: UUID(), previewHash: "h", endpointBaseURL: "http://127.0.0.1:8766/v1",
            modelName: modelName, appliedAt: now.addingTimeInterval(TimeInterval(-daysAgo) * 86_400),
            receipts: [ClientEditReceipt(clientID: "zed", configPath: "/x", backupPath: nil, appliedAt: now)],
            failures: [], rolledBackAt: nil
        )
    }
}
