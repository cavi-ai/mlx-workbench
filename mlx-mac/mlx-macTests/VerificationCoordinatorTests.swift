import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class VerificationCoordinatorTests: XCTestCase {
    // MARK: - Store

    func testStoreRoundTripsReport() throws {
        let store = VerificationStore(fileURL: temporaryURL("reports.json"))
        let report = makeReport(outcome: .passed)

        try store.upsert(report)

        XCTAssertEqual(try store.load(), [report])
    }

    func testStoreThrowsOnCorruptFileInsteadOfOverwriting() throws {
        let url = temporaryURL("reports.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url)

        let store = VerificationStore(fileURL: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.upsert(makeReport(outcome: .passed)))
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "not-json")
    }

    // MARK: - Gate flow

    func testPassingCanariesResolveWorkflowToVerified() async {
        let workflow = makeWorkflowCoordinator()
        let verification = makeVerification(responder: passingResponder)
        verification.attach(to: workflow)
        let record = makeWorkflow(state: .verifying)
        workflow.restore(record)

        verification.beginVerification(recordID: record.id, modelPath: "/Models/source", signature: "signature-1")

        let resolved = await waitFor { workflow.workflow.state == .verified }
        XCTAssertTrue(resolved)
        XCTAssertEqual(workflow.workflow.completedModelPath, "/Models/source")
        XCTAssertEqual(verification.reports.count, 1)
        XCTAssertEqual(verification.reports.first?.outcome, .passed)
        XCTAssertEqual(verification.reports.first?.workflowRecordID, record.id)
        XCTAssertNotNil(verification.reports.first?.tokensPerSecond)
    }

    func testFailingCanariesResolveWorkflowToVerificationFailed() async {
        let workflow = makeWorkflowCoordinator()
        let verification = makeVerification(responder: { _ in Self.sample("   ") })
        verification.attach(to: workflow)
        let record = makeWorkflow(state: .verifying)
        workflow.restore(record)

        verification.beginVerification(recordID: record.id, modelPath: "/Models/source", signature: "signature-1")

        let resolved = await waitFor { workflow.workflow.state == .verificationFailed }
        XCTAssertTrue(resolved)
        XCTAssertTrue(workflow.workflow.errorMessage?.contains("Verification failed") == true)
        XCTAssertEqual(verification.reports.first?.outcome, .failed(canaryIDs: ["echo", "code-fib", "arithmetic", "refusal-shape", "long-context"]))
    }

    func testProbeErrorResolvesWorkflowToCompletedUnverified() async {
        let workflow = makeWorkflowCoordinator()
        let verification = makeVerification(responder: { _ in throw ProbeStubError.offline })
        verification.attach(to: workflow)
        let record = makeWorkflow(state: .verifying)
        workflow.restore(record)

        verification.beginVerification(recordID: record.id, modelPath: "/Models/source", signature: "signature-1")

        let resolved = await waitFor { workflow.workflow.state == .completed }
        XCTAssertTrue(resolved)
        XCTAssertTrue(workflow.workflow.message?.contains("unverified") == true)
        XCTAssertTrue(verification.reports.isEmpty)
        XCTAssertNotNil(verification.lastError)
    }

    func testKeepAnywayResolvesToCompletedAndPersistsOverride() async {
        let workflow = makeWorkflowCoordinator()
        let storeURL = temporaryURL("reports.json")
        let verification = makeVerification(storeURL: storeURL, responder: { _ in Self.sample("   ") })
        verification.attach(to: workflow)
        let record = makeWorkflow(state: .verifying)
        workflow.restore(record)
        verification.beginVerification(recordID: record.id, modelPath: "/Models/source", signature: "signature-1")
        let resolved = await waitFor { workflow.workflow.state == .verificationFailed }
        XCTAssertTrue(resolved)

        verification.keepAnyway(recordID: record.id)

        let resolvedAfterKeep = await waitFor { workflow.workflow.state == .completed }
        XCTAssertTrue(resolvedAfterKeep)
        XCTAssertTrue(workflow.workflow.message?.contains("Kept despite") == true)
        XCTAssertEqual(verification.reports.first?.outcome, .keptDespiteFailure)
        XCTAssertEqual(try VerificationStore(fileURL: storeURL).load().first?.outcome, .keptDespiteFailure)
    }

    func testResolveVerificationIgnoresStaleRecords() async {
        let workflow = makeWorkflowCoordinator()
        let verification = makeVerification(responder: passingResponder)
        verification.attach(to: workflow)
        let record = makeWorkflow(state: .completed)
        workflow.restore(record)

        workflow.resolveVerification(recordID: record.id, resolution: .passed(summary: "late callback"))

        XCTAssertEqual(workflow.workflow.state, .completed)
    }

    func testConcurrentBeginResolvesSecondAsUnavailable() async {
        let workflow = makeWorkflowCoordinator()
        let gate = CompletionGate()
        let verification = makeVerification(responder: { id in
            await gate.wait()
            return Self.passingSample(id)
        })
        verification.attach(to: workflow)
        let first = makeWorkflow(id: "first", state: .verifying)
        let second = makeWorkflow(id: "second", state: .verifying)
        workflow.restore(first)

        verification.beginVerification(recordID: first.id, modelPath: "/Models/one", signature: nil)
        let resolved = await waitFor { verification.activeModelPath != nil }
        XCTAssertTrue(resolved)
        verification.beginVerification(recordID: second.id, modelPath: "/Models/two", signature: nil)
        await gate.open()

        let resolvedAfterGate = await waitFor { workflow.workflow.state == .verified }
        XCTAssertTrue(resolvedAfterGate)
        // The second record was rejected up front; only the first ran.
        XCTAssertEqual(verification.reports.count, 1)
        XCTAssertEqual(verification.reports.first?.modelPath, "/Models/one")
    }

    // MARK: - Status

    func testStatusReflectsOutcomeAndSignature() async {
        let verification = makeVerification(responder: passingResponder)
        verification.verifyNow(modelPath: "/Models/converted", signature: "sig-1")
        let resolved = await waitFor { verification.reports.count == 1 }
        XCTAssertTrue(resolved)

        XCTAssertEqual(verification.status(for: "/Models/converted", signature: "sig-1"), .verified(verification.reports[0]))
        XCTAssertEqual(verification.status(for: "/Models/converted", signature: "sig-2"), .stale(verification.reports[0]))
        XCTAssertEqual(verification.status(for: "/Models/never-seen", signature: nil), .unverified)
    }

    // MARK: - Helpers

    private nonisolated static func sample(_ text: String) -> ProbeSample {
        ProbeSample(text: text, completionTokens: 50, timeToFirstTokenSeconds: 0.1, durationSeconds: 1.1, metricsEstimated: false)
    }

    private nonisolated static func passingSample(_ id: String) -> ProbeSample {
        sample(passingText(for: id))
    }

    private nonisolated static func passingText(for id: String) -> String {
        switch id {
        case "echo":
            return "CRIMSON-OKAPI-42"
        case "code-fib":
            return "def fib(n):\n    if n < 2:\n        return n\n    return fib(n - 1) + fib(n - 2)"
        case "arithmetic":
            return "17 times 20 is 340, and 17 times 3 is 51, so the product is 391."
        case "refusal-shape":
            return "Pin-tumbler locks are opened by lifting each pin stack to the shear line in sequence while applying light rotational tension to the plug."
        case "long-context":
            return "The crimson okapi was the animal mentioned, and it hid forty-two brass keys."
        default:
            return "A perfectly ordinary and sufficiently long response for canary purposes."
        }
    }

    private var passingResponder: @Sendable (String) throws -> ProbeSample {
        { id in Self.passingSample(id) }
    }

    private func makeVerification(
        storeURL: URL? = nil,
        responder: @escaping @Sendable (String) async throws -> ProbeSample
    ) -> VerificationCoordinator {
        let probe = ServeProbe(
            lifecycle: ServeLifecycle(
                preview: { _, _ in "hash-1" },
                start: { _, _, _ in },
                stop: { _ in }
            ),
            prober: StubVerificationProber(responder: responder),
            readyPollIntervalNanoseconds: 1_000_000,
            pickPort: { 9999 }
        )
        return VerificationCoordinator(
            probe: probe,
            store: VerificationStore(fileURL: storeURL ?? temporaryURL("reports.json"))
        )
    }

    private func makeWorkflowCoordinator() -> ModelWorkflowCoordinator {
        let api = ModelWorkflowAPI(
            convertPreview: { _, _, _ in [:] },
            convertStart: { _, _, _, _ in [:] },
            convertStatus: { [] },
            servePreview: { _, _, _ in [:] },
            serveStart: { _, _, _, _ in [:] },
            serveStatus: { [] },
            serveStop: { _ in [:] }
        )
        return ModelWorkflowCoordinator(
            api: api,
            persistence: .live(store: ModelWorkflowStore(fileURL: temporaryURL("workflows.json")))
        )
    }

    private func makeWorkflow(id: String = "workflow", state: ConversionWorkflowState) -> ConversionWorkflow {
        ConversionWorkflow(
            id: workflowID(id),
            sourcePath: "/Models/source.gguf",
            sourceModelKey: "source-model",
            sourceSignature: "signature-1",
            outputPath: "/Models/source",
            previewHash: "preview-1",
            jobReceipt: "receipt-1",
            completedModelPath: "/Models/source",
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
        case "first": return UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
        case "second": return UUID(uuidString: "00000000-0000-4000-8000-000000000102")!
        default: return UUID(uuidString: "00000000-0000-4000-8000-000000000100")!
        }
    }

    private func makeReport(outcome: VerificationOutcome) -> VerificationReport {
        VerificationReport(
            id: UUID(),
            modelPath: "/Models/converted",
            modelSignature: "sig-1",
            workflowRecordID: nil,
            suiteVersion: CanarySuite.version,
            canaries: [],
            tokensPerSecond: nil,
            timeToFirstTokenSeconds: nil,
            metricsEstimated: false,
            startedAt: Date(timeIntervalSinceReferenceDate: 10),
            finishedAt: Date(timeIntervalSinceReferenceDate: 20),
            outcome: outcome
        )
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-verification-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private enum ProbeStubError: Error { case offline }
}

private actor CompletionGate {
    private var isOpen = false
    func wait() async {
        while !isOpen { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
    func open() { isOpen = true }
}

private struct StubVerificationProber: EndpointProbing {
    let responder: @Sendable (String) async throws -> ProbeSample

    func listModels(baseURL: URL) async -> [String] { [] }

    func isReady(baseURL: URL) async -> Bool { true }

    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int) async throws -> ProbeSample {
        let id = CanarySuite.cases.first(where: { $0.prompt == prompt })?.id ?? "unknown"
        return try await responder(id)
    }
}
