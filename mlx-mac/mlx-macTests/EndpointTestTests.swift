import Foundation
import XCTest
@testable import mlx_workbench

@MainActor
final class EndpointTestTests: XCTestCase {
    private let server = ServerInfo(repo: "org/model", runtime: "mlx_lm", port: 8766, pid: 123,
                                    state: "running", receipt: "/receipts/model.json")

    func testSendUsesCapturedEndpointAndChecksIdentityBeforeAndAfter() async {
        let engine = PromptEngine(server: server)
        let coordinator = EndpointTestCoordinator(client: engine.client)
        await coordinator.send(to: server, prompt: "  My question  ")?.value
        let calls = await engine.calls
        XCTAssertEqual(calls, ["status", "ask:org/model:8766:256:My question", "status"])
        XCTAssertEqual(coordinator.sample?.text, "An answer")
        XCTAssertNil(coordinator.error)
        XCTAssertFalse(coordinator.isSending)
        XCTAssertNil(coordinator.activeServer)
    }

    func testInvalidPromptAndUnknownProcessNeverReachTransport() async {
        let engine = PromptEngine(server: server)
        let coordinator = EndpointTestCoordinator(client: engine.client)
        for prompt in ["  ", String(repeating: "a", count: 4001)] {
            await coordinator.send(to: server, prompt: prompt)?.value
            XCTAssertNotNil(coordinator.error)
        }
        await coordinator.send(to: ServerInfo(repo: "org/model", port: 8766, state: "running"), prompt: "Hello")?.value
        let calls = await engine.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertNil(coordinator.sample)
    }

    func testChangedOrAmbiguousEndpointPreventsInference() async {
        let changed = ServerInfo(repo: "org/model", runtime: "mlx_lm", port: 8766, pid: 456,
                                 state: "running", receipt: "/receipts/other.json")
        for servers in [[changed], [server, server], [server, changed], []] {
            let engine = PromptEngine(server: server, before: servers)
            let coordinator = EndpointTestCoordinator(client: engine.client)
            await coordinator.send(to: server, prompt: "Hello")?.value
            let calls = await engine.calls
            XCTAssertEqual(calls, ["status"])
            XCTAssertTrue(coordinator.error?.contains("changed") == true)
        }
    }

    func testDriftAfterAnswerDiscardsUnattributedOutput() async {
        let engine = PromptEngine(server: server, after: [])
        let coordinator = EndpointTestCoordinator(client: engine.client)
        await coordinator.send(to: server, prompt: "Hello")?.value
        XCTAssertNil(coordinator.sample)
        XCTAssertTrue(coordinator.error?.contains("changed") == true)
    }

    func testOneWindowOwnsThePromptAndOldDismissalCannotClearAnotherWindow() async throws {
        let engine = PromptEngine(server: server)
        let coordinator = EndpointTestCoordinator(client: engine.client)
        let first = try XCTUnwrap(coordinator.open(server))
        XCTAssertNil(coordinator.open(server))
        coordinator.close(presentationID: first.id)
        let second = try XCTUnwrap(coordinator.open(server))
        await coordinator.send(to: server, prompt: "Hello", presentationID: second.id)?.value
        coordinator.close(presentationID: first.id)
        coordinator.reset(presentationID: first.id)
        XCTAssertEqual(coordinator.presentationID, second.id)
        XCTAssertEqual(coordinator.sample?.text, "An answer")
        XCTAssertNil(coordinator.send(to: server, prompt: "Stale click", presentationID: first.id))
        coordinator.close(presentationID: second.id)
        XCTAssertNil(coordinator.sample)
        XCTAssertNil(coordinator.presentationID)
    }

    func testActivityStartingDuringStatusCheckPreventsInference() async {
        let engine = PromptEngine(server: server)
        let coordinator = EndpointTestCoordinator(client: engine.client)
        var checks = 0
        coordinator.canUseServer = { _ in checks += 1; return checks == 1 }
        await coordinator.send(to: server, prompt: "Hello")?.value
        let calls = await engine.calls
        XCTAssertEqual(calls, ["status"])
        XCTAssertNotNil(coordinator.error)
    }

    func testCancelRetainsClaimUntilRequestReturnsAndRejectsDuplicateSend() async throws {
        let entered = expectation(description: "request started")
        let release = PromptRelease()
        let engine = PromptEngine(server: server)
        var client = engine.client
        client.ask = { _, _, _ in
            entered.fulfill()
            await release.wait()
            return Self.answer
        }
        let coordinator = EndpointTestCoordinator(client: client)
        let target = server
        let request = try XCTUnwrap(coordinator.send(to: target, prompt: "First"))
        await fulfillment(of: [entered], timeout: 5)
        coordinator.cancel()
        XCTAssertTrue(coordinator.isSending)
        XCTAssertEqual(coordinator.activeServer, target)
        await coordinator.send(to: target, prompt: "Duplicate")?.value
        await release.finish()
        await request.value
        XCTAssertNil(coordinator.sample, "A cancelled request must not publish its late answer")
        XCTAssertTrue(coordinator.error?.hasPrefix("Stopped waiting") == true)
        XCTAssertFalse(coordinator.isSending)
        XCTAssertNil(coordinator.activeServer)
    }

    func testDismissClearsOutputAndFencesLateFailure() async throws {
        let entered = expectation(description: "request started")
        let release = PromptRelease()
        let target = server
        let coordinator = EndpointTestCoordinator(client: EndpointTestClient(servers: { [target] }, ask: { _, _, _ in
            entered.fulfill()
            await release.wait()
            throw URLError(.timedOut)
        }))
        let request = try XCTUnwrap(coordinator.send(to: target, prompt: "Hello"))
        await fulfillment(of: [entered], timeout: 5)
        coordinator.close()
        await release.finish()
        await request.value
        XCTAssertNil(coordinator.sample)
        XCTAssertNil(coordinator.error)
        XCTAssertFalse(coordinator.isSending)
    }

    func testDismissBeforeTaskStartsNeverSendsARequest() async throws {
        let engine = PromptEngine(server: server)
        let coordinator = EndpointTestCoordinator(client: engine.client)
        let request = try XCTUnwrap(coordinator.send(to: server, prompt: "Hello"))
        coordinator.close()
        await request.value
        let calls = await engine.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertNil(coordinator.error)
    }

    func testCompletionLabelsDoNotTurnIncompleteOutputIntoSuccess() {
        XCTAssertEqual(EndpointTestCoordinator.outcome(Self.answer), "Answer returned")
        XCTAssertEqual(EndpointTestCoordinator.outcome(Self.sample(text: "Partial", finish: "length")), "Token limit reached")
        XCTAssertEqual(EndpointTestCoordinator.outcome(Self.sample(text: "Partial", finish: nil)), "Completion not confirmed")
        XCTAssertEqual(EndpointTestCoordinator.outcome(Self.sample(text: "", finish: "stop")), "No answer text returned")
    }

    func testPromptClaimProtectsStopButCanBeExcludedForItsOwnEligibilityCheck() {
        var occupancy = ModelOccupancy()
        occupancy.add([server.modelIdentity], for: .promptTest)
        XCTAssertTrue(occupancy.blocksStop(server))
        XCTAssertFalse(occupancy.blocksStop(server, excluding: .promptTest))
        occupancy.add([server.modelIdentity], for: .comparison)
        XCTAssertTrue(occupancy.blocksStop(server, excluding: .promptTest))
    }

    nonisolated private static var answer: ProbeSample { sample(text: "An answer", finish: "stop") }
    nonisolated private static func sample(text: String, finish: String?) -> ProbeSample {
        ProbeSample(text: text, completionTokens: 2, timeToFirstTokenSeconds: 0.1,
                    durationSeconds: 0.5, metricsEstimated: false, finishReason: finish)
    }
}

private actor PromptEngine {
    let server: ServerInfo
    let before: [ServerInfo]
    let after: [ServerInfo]
    private(set) var calls: [String] = []
    private var reads = 0
    init(server: ServerInfo, before: [ServerInfo]? = nil, after: [ServerInfo]? = nil) {
        self.server = server; self.before = before ?? [server]; self.after = after ?? [server]
    }
    nonisolated var client: EndpointTestClient {
        EndpointTestClient(servers: { await self.status() }, ask: { server, prompt, limit in
            await self.answer(server, prompt: prompt, limit: limit)
        })
    }
    private func status() -> [ServerInfo] {
        calls.append("status"); reads += 1
        return reads == 1 ? before : after
    }
    private func answer(_ server: ServerInfo, prompt: String, limit: Int) -> ProbeSample {
        calls.append("ask:\(server.modelIdentity):\(server.port ?? 0):\(limit):\(prompt)")
        return ProbeSample(text: "An answer", completionTokens: 2, timeToFirstTokenSeconds: 0.1,
                           durationSeconds: 0.5, metricsEstimated: false, finishReason: "stop")
    }
}

private actor PromptRelease {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { released = true; continuation?.resume(); continuation = nil }
}
