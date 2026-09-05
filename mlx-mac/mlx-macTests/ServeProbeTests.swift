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

    // MARK: - OpenAIEndpointProber parsing

    func testChatCapturesPromptTokensAndDerivesPrefill() async throws {
        let sse = [
            #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"data: {"choices":[{"delta":{"content":" world"}}],"usage":{"prompt_tokens":96,"completion_tokens":2}}"#,
            "data: [DONE]",
        ].joined(separator: "\n")
        let session = stubSession(body: sse)
        let prober = OpenAIEndpointProber(session: session)

        let sample = try await prober.chat(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            model: "m",
            prompt: "p",
            maxTokens: 16
        )

        XCTAssertEqual(sample.text, "Hello world")
        XCTAssertEqual(sample.promptTokens, 96)
        XCTAssertEqual(sample.completionTokens, 2)
        XCTAssertFalse(sample.metricsEstimated)
        XCTAssertNil(sample.toolCalls)
        let ttft = try XCTUnwrap(sample.timeToFirstTokenSeconds)
        XCTAssertEqual(sample.prefillTokensPerSecond ?? 0, 96 / ttft, accuracy: 1)
    }

    func testChatCountsStreamedToolCallsByIndex() async throws {
        let sse = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"get_current_weather","arguments":""}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":\"Paris\"}"}}]}}],"finish_reason":"tool_calls"}"#,
            #"data: {"usage":{"prompt_tokens":40,"completion_tokens":9}}"#,
            "data: [DONE]",
        ].joined(separator: "\n")
        let session = stubSession(body: sse)
        let prober = OpenAIEndpointProber(session: session)
        let tool = PromptToolSpec(
            name: "get_current_weather",
            description: "Get the current weather for a city.",
            parametersJSON: #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#
        )

        let sample = try await prober.chat(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            model: "m",
            prompt: "Weather in Paris?",
            maxTokens: 64,
            tool: tool
        )

        XCTAssertEqual(sample.toolCalls, 1)
        XCTAssertEqual(sample.toolNames, ["get_current_weather"])
        XCTAssertEqual(sample.promptTokens, 40)
    }

    func testToolSpecWithUnreadableSchemaDropsTool() {
        let spec = PromptToolSpec(name: "broken", description: "d", parametersJSON: "not json")
        XCTAssertNil(spec.openAITool)
    }

    /// URLProtocol-backed session that replays a canned SSE body.
    private func stubSession(body: String) -> URLSession {
        SSEStub.body = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SSEStub.self]
        return URLSession(configuration: configuration)
    }

    private final class SSEStub: URLProtocol {
        static var body = ""

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
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
