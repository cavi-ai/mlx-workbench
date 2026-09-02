import Foundation
import XCTest

@testable import mlx_workbench

final class ServeProbeTests: XCTestCase {
    private func sample(text: String = "ok") -> ProbeSample {
        ProbeSample(text: text, completionTokens: 10, timeToFirstTokenSeconds: 0.05, durationSeconds: 0.5, metricsEstimated: false)
    }

    private func makeProbe(
        events: LifecycleRecorder,
        ready: Bool = true,
        readyTimeout: TimeInterval = 0.2,
        previewHash: String = "hash-1",
        responder: @escaping @Sendable (String) throws -> ProbeSample
    ) -> ServeProbe {
        ServeProbe(
            lifecycle: ServeLifecycle(
                preview: { modelPath, port in
                    await events.record("preview:\(modelPath):\(port)")
                    return previewHash
                },
                start: { modelPath, port, hash in
                    await events.record("start:\(modelPath):\(port):\(hash)")
                },
                stop: { port in
                    await events.record("stop:\(port)")
                }
            ),
            prober: StubProber(ready: ready, responder: responder),
            readyTimeout: readyTimeout,
            readyPollIntervalNanoseconds: 1_000_000,
            pickPort: { 9999 }
        )
    }

    func testRunServesEveryCanaryThenStops() async throws {
        let events = LifecycleRecorder()
        let probe = makeProbe(events: events) { _ in self.sample() }

        let result = try await probe.run(modelPath: "/Models/converted")

        XCTAssertEqual(result.port, 9999)
        XCTAssertEqual(Set(result.samples.keys), Set(CanarySuite.cases.map(\.id)))
        let recorded = await events.values
        XCTAssertEqual(recorded.first, "preview:/Models/converted:9999")
        XCTAssertEqual(recorded.dropFirst().first, "start:/Models/converted:9999:hash-1")
        XCTAssertEqual(recorded.last, "stop:9999")
    }

    func testStopIsCalledWhenACanaryThrows() async {
        let events = LifecycleRecorder()
        let probe = makeProbe(events: events) { id in
            if id == "arithmetic" { throw StubError.boom }
            return self.sample()
        }

        do {
            _ = try await probe.run(modelPath: "/Models/converted")
            XCTFail("expected the canary failure to propagate")
        } catch {
            XCTAssertEqual(error as? StubError, .boom)
        }

        let recorded = await events.values
        XCTAssertEqual(recorded.last, "stop:9999")
    }

    func testNeverReadyThrowsAndStops() async {
        let events = LifecycleRecorder()
        let probe = makeProbe(events: events, ready: false) { _ in self.sample() }

        do {
            _ = try await probe.run(modelPath: "/Models/converted")
            XCTFail("expected serverNeverReady")
        } catch {
            guard case ServeProbeError.serverNeverReady = error else {
                return XCTFail("expected serverNeverReady, got \(error)")
            }
        }

        let recorded = await events.values
        XCTAssertEqual(recorded.last, "stop:9999")
        XCTAssertFalse(recorded.contains { $0.hasPrefix("chat") })
    }

    func testChatsUseServedIdentityWhenListed() async throws {
        let models = ModelListBox(listed: ["mlx-community/Qwen3-0.6B-4bit"])
        let probe = makeProbeWithModels(models)
        let cachePath = "/Users/x/.cache/huggingface/hub/models--mlx-community--Qwen3-0.6B-4bit/snapshots/abc"

        _ = try await probe.run(modelPath: cachePath)

        let used = await models.usedModels
        XCTAssertTrue(used.allSatisfy { $0 == "mlx-community/Qwen3-0.6B-4bit" })
        XCTAssertFalse(used.isEmpty)
    }

    func testChatsFallBackToFirstListedModelWhenIdentityUnlisted() async throws {
        let models = ModelListBox(listed: ["other/loaded-model"])
        let probe = makeProbeWithModels(models)

        _ = try await probe.run(modelPath: "/models/outside-cache")

        let used = await models.usedModels
        XCTAssertTrue(used.allSatisfy { $0 == "other/loaded-model" })
    }

    func testMissingPreviewHashDoesNotStart() async {        let events = LifecycleRecorder()
        let probe = makeProbe(events: events, previewHash: "") { _ in self.sample() }

        do {
            _ = try await probe.run(modelPath: "/Models/converted")
            XCTFail("expected servePreviewMissingHash")
        } catch {
            guard case ServeProbeError.servePreviewMissingHash = error else {
                return XCTFail("expected servePreviewMissingHash, got \(error)")
            }
        }

        let recorded = await events.values
        XCTAssertFalse(recorded.contains { $0.hasPrefix("start") })
    }

    private func makeProbeWithModels(_ models: ModelListBox) -> ServeProbe {
        ServeProbe(
            lifecycle: ServeLifecycle(
                preview: { _, _ in "hash-1" },
                start: { _, _, _ in },
                stop: { _ in }
            ),
            prober: models,
            readyPollIntervalNanoseconds: 1_000_000,
            pickPort: { 9999 }
        )
    }

    private enum StubError: Error { case boom }
}

private actor ModelListBox {
    let listed: [String]
    private(set) var usedModels: [String] = []

    init(listed: [String]) { self.listed = listed }

    func record(_ model: String) { usedModels.append(model) }
}

extension ModelListBox: EndpointProbing {
    func isReady(baseURL: URL) async -> Bool { true }
    func listModels(baseURL: URL) async -> [String] { listed }
    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int) async throws -> ProbeSample {
        record(model)
        return ProbeSample(text: "ok", completionTokens: 5, timeToFirstTokenSeconds: 0.05, durationSeconds: 0.2, metricsEstimated: false)
    }
}

private actor LifecycleRecorder {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

private struct StubProber: EndpointProbing {
    let ready: Bool
    let responder: @Sendable (String) throws -> ProbeSample

    func listModels(baseURL: URL) async -> [String] { [] }

    func isReady(baseURL: URL) async -> Bool { ready }

    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int) async throws -> ProbeSample {
        let id = CanarySuite.cases.first(where: { $0.prompt == prompt })?.id ?? "unknown"
        return try responder(id)
    }
}
