import Foundation
import SQLite3
import XCTest

@testable import mlx_workbench

@MainActor
final class ComparisonPhase2Tests: XCTestCase {
    // MARK: - Prompt history import

    func testImportExtractsRecentDistinctUserPrompts() throws {
        let db = try makeFixtureDatabase()
        let result = try XCTUnwrap(PromptHistoryImport.importPrompts(databasePath: db.path))

        XCTAssertEqual(result.prompts.count, 2)
        XCTAssertTrue(result.prompts.first?.contains("second real prompt") == true)  // newest first
        XCTAssertTrue(result.prompts.contains { $0.contains("first real prompt") })
        // Assistant text, tiny messages, and slash commands are excluded.
        XCTAssertFalse(result.prompts.contains { $0.contains("assistant reply") })
        XCTAssertFalse(result.prompts.contains { $0.contains("/compact") })
    }

    func testImportDedupesRepeatedPrompts() throws {
        let url = try makeFixtureDatabase()
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw FixtureError.openFailed }
        insertMessage(db: db, id: "m9", role: "user", text: "first real prompt about quantizing a model", created: 9)
        sqlite3_close(db)

        let result = try XCTUnwrap(PromptHistoryImport.importPrompts(databasePath: url.path))
        XCTAssertEqual(result.prompts.count, 2)  // not 3
    }

    func testImportReturnsNilForMissingDatabase() {
        XCTAssertNil(PromptHistoryImport.importPrompts(databasePath: "/nonexistent/opencode.db"))
    }

    func testImportHistoryCreatesPersistedUserSet() throws {
        let db = try makeFixtureDatabase()
        let coordinator = makeCoordinator()

        let set = try XCTUnwrap(coordinator.importHistory(databasePath: db.path))

        XCTAssertEqual(set.origin, .userCreated)
        XCTAssertEqual(set.prompts.count, 2)
        XCTAssertTrue(coordinator.promptSets.contains { $0.id == set.id })

        let reloaded = makeCoordinator()
        XCTAssertTrue(reloaded.promptSets.contains { $0.id == set.id })
    }

    func testImportHistoryWithoutDatabaseReportsError() {
        let coordinator = makeCoordinator()
        XCTAssertNil(coordinator.importHistory(databasePath: nil))
        XCTAssertNotNil(coordinator.lastError)
    }

    // MARK: - Sample metrics threading

    func testAggregationMapsPromptTokensPrefillAndToolCalls() {
        let probe = ProbeSample(
            text: "output",
            completionTokens: 10,
            promptTokens: 96,
            timeToFirstTokenSeconds: 0.5,
            durationSeconds: 1.5,
            metricsEstimated: false,
            toolCalls: 1,
            toolNames: ["get_current_weather"]
        )

        let sample = ComparisonAggregation.sample(from: probe, promptID: "tool-weather")

        XCTAssertEqual(sample.promptTokens, 96)
        XCTAssertEqual(sample.prefillTokensPerSecond, 192)
        XCTAssertEqual(sample.toolCalls, 1)
        XCTAssertEqual(sample.toolNames, ["get_current_weather"])
    }

    func testLegacySampleJSONDecodesWithNewFieldsAbsent() throws {
        let legacy = """
        {"promptID":"p1","outputExcerpt":"hi","tokensPerSecond":42.5,\
        "timeToFirstTokenSeconds":0.2,"error":null}
        """
        let sample = try JSONDecoder().decode(ComparisonSample.self, from: Data(legacy.utf8))

        XCTAssertEqual(sample.promptID, "p1")
        XCTAssertEqual(sample.tokensPerSecond, 42.5)
        XCTAssertNil(sample.promptTokens)
        XCTAssertNil(sample.prefillTokensPerSecond)
        XCTAssertNil(sample.toolCalls)
        XCTAssertNil(sample.toolNames)
    }

    // MARK: - Model performance profile

    func testProfileAggregatesCompletedRunsForExactPathAndSignature() {
        let older = makeRun(
            finishedAt: Date(timeIntervalSinceReferenceDate: 100),
            results: [makeResult(path: "/Models/a", signature: "sig-1", tps: 40, ttft: 0.5)]
        )
        let newer = makeRun(
            finishedAt: Date(timeIntervalSinceReferenceDate: 200),
            results: [makeResult(path: "/Models/a", signature: "sig-1", tps: 50, ttft: 0.4)]
        )

        let profile = ModelPerformanceProfile.derive(
            modelPath: "/Models/a",
            signature: "sig-1",
            runs: [newer, older]
        )

        XCTAssertEqual(profile?.runCount, 2)
        XCTAssertEqual(profile?.lastMeasuredAt, Date(timeIntervalSinceReferenceDate: 200))
        XCTAssertEqual(profile?.averageTokensPerSecond, 45)
        XCTAssertEqual(profile?.bestTokensPerSecond, 50)
        XCTAssertEqual(profile?.worstTokensPerSecond, 40)
        XCTAssertEqual(profile?.bestTTFTSeconds, 0.4)
    }

    func testProfileSkipsMismatchedSignatureErroredAndRunningRuns() {
        let wrongSignature = makeRun(
            finishedAt: Date(timeIntervalSinceReferenceDate: 100),
            results: [makeResult(path: "/Models/a", signature: "sig-old", tps: 99, ttft: 0.1)]
        )
        let errored = makeRun(
            finishedAt: Date(timeIntervalSinceReferenceDate: 200),
            results: [makeResult(path: "/Models/a", signature: "sig-1", tps: nil, ttft: nil, error: "boom")]
        )
        var running = makeRun(
            finishedAt: Date(timeIntervalSinceReferenceDate: 300),
            results: [makeResult(path: "/Models/a", signature: "sig-1", tps: 88, ttft: 0.1)]
        )
        running.state = .running
        let good = makeRun(
            finishedAt: Date(timeIntervalSinceReferenceDate: 150),
            results: [makeResult(path: "/Models/a", signature: "sig-1", tps: 42, ttft: 0.6)]
        )

        let profile = ModelPerformanceProfile.derive(
            modelPath: "/Models/a",
            signature: "sig-1",
            runs: [wrongSignature, errored, running, good]
        )

        XCTAssertEqual(profile?.runCount, 1)
        XCTAssertEqual(profile?.averageTokensPerSecond, 42)
    }

    func testProfileReturnsNilWhenNothingMatches() {
        XCTAssertNil(ModelPerformanceProfile.derive(modelPath: "/Models/nope", signature: nil, runs: []))
    }

    private func makeRun(finishedAt: Date, results: [VariantResult]) -> ComparisonRun {
        ComparisonRun(
            id: UUID(),
            promptSetID: "builtin-coding",
            promptSetName: "Coding basics",
            useCase: .coding,
            variants: results.map(\.modelPath),
            results: results,
            startedAt: finishedAt.addingTimeInterval(-60),
            finishedAt: finishedAt,
            state: .completed
        )
    }

    private func makeResult(
        path: String,
        signature: String?,
        tps: Double?,
        ttft: Double?,
        error: String? = nil
    ) -> VariantResult {
        VariantResult(
            modelPath: path,
            modelSignature: signature,
            samples: [],
            aggregateTokensPerSecond: tps,
            aggregateTTFTSeconds: ttft,
            error: error
        )
    }

    // MARK: - Output diff pairing

    func testDiffPairsMatchByPromptIDAndDropUnpaired() {
        let left = VariantResult(
            modelPath: "/m/q4", modelSignature: nil,
            samples: [
                ComparisonSample(promptID: "a", outputExcerpt: "alpha", tokensPerSecond: nil, timeToFirstTokenSeconds: nil, error: nil),
                ComparisonSample(promptID: "b", outputExcerpt: "beta", tokensPerSecond: nil, timeToFirstTokenSeconds: nil, error: nil),
            ],
            aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil
        )
        let right = VariantResult(
            modelPath: "/m/q8", modelSignature: nil,
            samples: [
                ComparisonSample(promptID: "b", outputExcerpt: "beta2", tokensPerSecond: nil, timeToFirstTokenSeconds: nil, error: nil),
                ComparisonSample(promptID: "c", outputExcerpt: "gamma", tokensPerSecond: nil, timeToFirstTokenSeconds: nil, error: nil),
            ],
            aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil
        )

        let pairs = ComparisonDiff.pairs(left, right)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.promptID, "b")
        XCTAssertEqual(pairs.first?.left, "beta")
        XCTAssertEqual(pairs.first?.right, "beta2")
    }

    // MARK: - Helpers

    func testDiffUsesFullRecordedOutputsAndExcludesFailedSamples() {
        func result(_ path: String, full: String) -> VariantResult {
            VariantResult(modelPath: path, modelSignature: nil, samples: [
                ComparisonSample(promptID: "p", outputExcerpt: "same prefix", tokensPerSecond: nil,
                    timeToFirstTokenSeconds: nil, error: nil, fullOutput: full),
                ComparisonSample(promptID: "failed", outputExcerpt: "partial", tokensPerSecond: nil,
                    timeToFirstTokenSeconds: nil, error: "Interrupted")
            ], aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil)
        }
        let pairs = ComparisonDiff.pairs(result("a", full: "Full answer A"), result("b", full: "Full answer B"))
        XCTAssertEqual(pairs.map(\.promptID), ["p"])
        XCTAssertEqual(pairs.first?.left, "Full answer A")
        XCTAssertEqual(pairs.first?.right, "Full answer B")
    }

    func testNewChatSamplesRetainFullResponseBeyondExcerpt() throws {
        let response = String(repeating: "A long response. ", count: 50) + "Final conclusion."
        let probe = ProbeSample(text: response, completionTokens: 100, timeToFirstTokenSeconds: 0.2,
            durationSeconds: 2, metricsEstimated: false)
        let sample = ComparisonAggregation.sample(from: probe, promptID: "p")
        XCTAssertEqual(sample.outputExcerpt, String(response.prefix(280)))
        XCTAssertEqual(sample.fullOutput, response)
        let restored = try JSONDecoder().decode(ComparisonSample.self, from: JSONEncoder().encode(sample))
        XCTAssertEqual(restored.fullOutput, response)
    }

    func testTextComparisonPreservesLegacyExcerptsEmptyResponsesAndGuardsLongDiffs() throws {
        func result(_ path: String, full: String?, error: String? = nil) -> VariantResult {
            VariantResult(modelPath: path, modelSignature: nil, samples: [
                ComparisonSample(promptID: "p", outputExcerpt: "legacy excerpt", tokensPerSecond: nil,
                    timeToFirstTokenSeconds: nil, error: nil, fullOutput: full)
            ], aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: error)
        }
        let legacy = result("a", full: nil)
        let empty = result("b", full: "")
        let pair = try XCTUnwrap(ComparisonDiff.pairs(legacy, empty).first)
        XCTAssertTrue(pair.leftIsExcerpt)
        XCTAssertFalse(pair.rightIsExcerpt)
        XCTAssertEqual(pair.right, "")
        XCTAssertEqual(ComparisonDiff.output(legacy, promptID: "p")?.text, "legacy excerpt")
        XCTAssertNil(ComparisonDiff.output(legacy, promptID: "missing"))
        XCTAssertNil(ComparisonDiff.output(result("c", full: "partial", error: "failed"), promptID: "p"))
        XCTAssertTrue(ComparisonDiff.pairs(legacy, legacy).isEmpty)
        let lines = try XCTUnwrap(ComparisonDiff.differences(pair))
        XCTAssertTrue(lines.contains { $0.kind == .removed && $0.text == "legacy excerpt" })
        XCTAssertNil(ComparisonDiff.differences(.init(promptID: "p", left: String(repeating: "x", count: 20_001), right: "x")))
        XCTAssertNil(ComparisonDiff.differences(.init(promptID: "p", left: String(repeating: "line\n", count: 501), right: "x")))
    }

    func testTextComparisonHandlesDuplicatePromptIDsWithoutCrashing() {
        let sample = ComparisonSample(promptID: "p", outputExcerpt: "first", tokensPerSecond: nil,
            timeToFirstTokenSeconds: nil, error: nil)
        func result(_ path: String) -> VariantResult {
            VariantResult(modelPath: path, modelSignature: nil, samples: [sample, sample],
                aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil)
        }
        XCTAssertEqual(ComparisonDiff.pairs(result("a"), result("b")).count, 1)
    }

    private var promptSetStoreURL: URL!
    private var runStoreURL: URL!

    override func setUp() {
        super.setUp()
        promptSetStoreURL = temporaryURL("prompt-sets.json")
        runStoreURL = temporaryURL("runs.json")
    }

    private func makeCoordinator() -> ComparisonCoordinator {
        ComparisonCoordinator(
            probe: ServeProbe(
                lifecycle: ServeLifecycle(preview: { _, _ in "h" }, start: { _, _, _ in }, stop: { _ in }),
                prober: NeverUsedProber()
            ),
            runStore: JSONStore<ComparisonRun>(fileURL: runStoreURL),
            promptSetStore: JSONStore<PromptSet>(fileURL: promptSetStoreURL)
        )
    }

    /// Minimal opencode-shaped fixture: message + part tables with
    /// role/type JSON extraction.
    private func makeFixtureDatabase() throws -> URL {
        let url = temporaryURL("opencode-fixture.db")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw FixtureError.openFailed }
        defer { sqlite3_close(db) }
        try exec(db, """
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
        """)
        insertMessage(db: db, id: "m1", role: "user", text: "first real prompt about quantizing a model", created: 1)
        insertMessage(db: db, id: "m2", role: "assistant", text: "assistant reply that is long enough to pass", created: 2)
        insertMessage(db: db, id: "m3", role: "user", text: "/compact", created: 3)
        insertMessage(db: db, id: "m4", role: "user", text: "ok", created: 4)
        insertMessage(db: db, id: "m5", role: "user", text: "second real prompt about serving a model locally", created: 5)
        return url
    }

    private func insertMessage(db: OpaquePointer?, id: String, role: String, text: String, created: Int) {
        try? exec(db, "INSERT INTO message VALUES ('\(id)', 's1', \(created), '{\"role\":\"\(role)\"}');")
        try? exec(db, "INSERT INTO part VALUES ('\(id)-p', '\(id)', 's1', \(created), '{\"type\":\"text\",\"text\":\"\(text)\"}');")
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw FixtureError.sql(message)
        }
    }

    private nonisolated func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-phase2-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    private enum FixtureError: Error {
        case openFailed
        case sql(String)
    }
}

private struct NeverUsedProber: EndpointProbing {
    func listModels(baseURL: URL) async -> [String] { [] }

    func isReady(baseURL: URL) async -> Bool { false }
    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int) async throws -> ProbeSample {
        throw StubProbeError.unused
    }
}

private enum StubProbeError: Error { case unused }
