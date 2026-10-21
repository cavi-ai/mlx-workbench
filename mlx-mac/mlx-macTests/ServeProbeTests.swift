import Foundation
import Network
import XCTest

@testable import mlx_workbench

final class ServeProbeTests: XCTestCase {
    func testInlineReasoningIsSplitFromTheAnswer() {
        XCTAssertNil(InlineReasoning.split("def fib(n): ..."))
        let finished = InlineReasoning.split("<think>\nplan the recursion\n</think>\n\ndef fib(n): ...")
        XCTAssertEqual(finished?.reasoning, "\nplan the recursion\n")
        XCTAssertEqual(finished?.answer, "def fib(n): ...")
        XCTAssertEqual(InlineReasoning.split("<think>\nOkay, I need to write")?.answer, "")
        XCTAssertTrue(InlineReasoning.isInside("<think>still planning"))
        XCTAssertTrue(InlineReasoning.isInside("<think>plan</think>\n"))
        XCTAssertFalse(InlineReasoning.isInside("<think>plan</think>def"))
        XCTAssertFalse(InlineReasoning.isInside("def"))
    }

    func testIncrementalReasoningHandlesEveryTagBoundaryAndLiteralMarkup() {
        let cases: [(String, Bool)] = [
            ("<think>still planning", false), ("  <think>plan</think>\n", false),
            ("\u{2003}<think>plan<</think>\nHello", true), ("<think>plan</think>答え 🐈", true),
            ("Hello", true), ("<div>literal markup", true), ("<thinking>literal", true),
            ("<thin", false), (" \n", false)
        ]
        for (text, expected) in cases {
            for boundary in text.indices {
                var tracker = InlineReasoning.StreamTracker()
                tracker.consume(String(text[..<boundary]))
                tracker.consume(String(text[boundary...]))
                XCTAssertEqual(tracker.hasAnswer, expected, text)
            }
            var scalarTracker = InlineReasoning.StreamTracker()
            for scalar in text.unicodeScalars { scalarTracker.consume(String(scalar)) }
            XCTAssertEqual(scalarTracker.hasAnswer, expected, text)
        }
    }

    func testFragmentedInlineTagsDoNotRecordReasoningAsAnAnswer() async throws {
        for includeAnswer in [false, true] {
            var fragments = ["<", "thi", "nk>", "Plan the answer.", "</th", "ink>", "\n"]
            if includeAnswer { fragments.append("Hello") }
            let body = try fragments.map { content -> String in
                let data = try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": content]]]])
                return "data: " + String(decoding: data, as: UTF8.self) + "\n"
            }.joined() + "data: [DONE]\n"
            let session = stubSession(body: body)
            defer { session.invalidateAndCancel() }
            let sample = try await OpenAIEndpointProber(session: session).chat(
                baseURL: URL(string: "http://127.0.0.1:9999")!, model: "model", prompt: "hello", maxTokens: 64)
            XCTAssertEqual(sample.text, includeAnswer ? "Hello" : "")
            XCTAssertEqual(sample.reasoningText, "Plan the answer.")
            XCTAssertEqual(sample.timeToFirstAnswerSeconds != nil, includeAnswer)
            XCTAssertNotNil(sample.timeToFirstTokenSeconds)
        }
    }

    func testOpenHTTPStreamsCloseAfterDoneErrorsLimitsAndCancellation() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for mode in ["done", "error", "limit", "status", "cancel", "done"] {
            let opened = expectation(description: "stream opened: " + mode)
            let closed = expectation(description: "stream closed: " + mode)
            let body: String
            switch mode {
            case "done": body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\ndata: [DONE]\n\n"
            case "error": body = "data: {\"error\":{\"message\":\"failed\"}}\n\n"
            case "limit": body = String(repeating: "x", count: 256)
            default: body = ": waiting\n\n"
            }
            let server = try await ProbeStreamPeer.start(body: body, status: mode == "status" ? 503 : 200,
                opened: { opened.fulfill() }, closed: { closed.fulfill() })
            defer { server.stop() }
            let task = Task {
                try await OpenAIEndpointProber(session: session, maximumResponseBytes: 128, maximumLineBytes: 128).chat(
                    baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, model: "model", prompt: "hello", maxTokens: 8)
            }
            await fulfillment(of: [opened], timeout: 5)
            if mode == "cancel" { task.cancel() }
            do {
                let sample = try await task.value
                XCTAssertEqual(mode, "done")
                XCTAssertEqual(sample.text, "Hello")
            } catch {
                switch mode {
                case "error": XCTAssertEqual(error as? ProbeHTTPError, .invalidResponse)
                case "limit": XCTAssertEqual(error as? ProbeHTTPError, .responseTooLarge)
                case "status": XCTAssertEqual(error as? ProbeHTTPError, .httpStatus(503))
                case "cancel": XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
                default: XCTFail("Unexpected error: \(error)")
                }
            }
            // The peer never sends EOF: closure must come from the request owner,
            // before this test invalidates the shared session or stops the peer.
            await fulfillment(of: [closed], timeout: 5)
            server.stop()
        }
    }

    func testDecodeRateIsWithheldWhenDeltasArriveInABurst() {
        var burst = ProbeSample(text: "x", completionTokens: 87, timeToFirstTokenSeconds: 3.094,
                                durationSeconds: 3.103, metricsEstimated: false)
        burst.streamedDeltas = 87
        burst.deltaWindowSeconds = 0.009
        XCTAssertNil(burst.decodeTokensPerSecond)
        XCTAssertNil(CanarySuite.tokensPerSecond(burst))

        var steady = ProbeSample(text: "x", completionTokens: 75, timeToFirstTokenSeconds: 0.214,
                                 durationSeconds: 0.980, metricsEstimated: false)
        steady.streamedDeltas = 75
        steady.deltaWindowSeconds = 0.76
        XCTAssertEqual(steady.decodeTokensPerSecond ?? 0, 97.9, accuracy: 0.1)

        let recorded = ProbeSample(text: "x", completionTokens: 10, timeToFirstTokenSeconds: 0.1,
                                   durationSeconds: 1.1, metricsEstimated: false)
        XCTAssertEqual(recorded.decodeTokensPerSecond ?? 0, 10, accuracy: 0.001)
    }

    func testLocalPerPromptWarmupWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_PROMPT_WARMUP_MANIFEST"] else {
            throw XCTSkip("Set MLX_WORKBENCH_PROMPT_WARMUP_MANIFEST for local per-prompt warm-up acceptance.")
        }
        struct Manifest: Decodable { let agentPath: String; let profilesFile: String; let evidenceRoot: String }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let source = JSONStore<ServingProfile>(fileURL: URL(fileURLWithPath: manifest.profilesFile))
        let before = try Data(contentsOf: source.url)
        let profile = try XCTUnwrap(try source.load().first { $0.hasPassedVerification })
        let root = URL(fileURLWithPath: manifest.evidenceRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: manifest.agentPath, receiptDirectory: root.path)
        let probe = ServeProbe(lifecycle: .verifiedProfile(profile, api: api),
            prober: OpenAIEndpointProber(requestTimeout: 900), readyTimeout: 900)
        let prompts = [("first", "17 times 19", 323), ("second", "23 times 17", 391)].map { id, question, _ in
            ProbePrompt(id: id, prompt: "Calculate \(question). In your final answer, return only JSON with one key named answer and its numeric value.", maxTokens: 1024)
        }
        let outcome = try await probe.run(modelPath: profile.modelPath, prompts: prompts,
            warmup: [ProbePrompt(id: "startup", prompt: "Say OK.", maxTokens: 4)], warmEachPrompt: true)
        XCTAssertEqual(Set(outcome.samples.keys), ["first", "second"])
        let samples = try prompts.enumerated().map { index, prompt in
            let sample = ComparisonAggregation.sample(from: try XCTUnwrap(outcome.samples[prompt.id]), promptID: prompt.id)
            XCTAssertTrue(sample.hasCompletedAnswer)
            let work = try XCTUnwrap(sample.promptProcessing)
            XCTAssertTrue(work.isValid); XCTAssertEqual(work.promptTokens, sample.promptTokens)
            XCTAssertGreaterThan(work.cachedTokens, 0)
            XCTAssertLessThanOrEqual(work.processedTokens, 1)
            let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((sample.fullOutput ?? sample.outputExcerpt).utf8)) as? [String: Int])
            XCTAssertEqual(answer, ["answer": index == 0 ? 323 : 391])
            return sample
        }
        struct Evidence: Encodable {
            let warmEachPrompt: Bool
            let servingEvidence: ProbeServingEvidence?
            let samples: [ComparisonSample]
        }
        try JSONEncoder().encode(Evidence(warmEachPrompt: true, servingEvidence: outcome.servingEvidence, samples: samples))
            .write(to: root.appendingPathComponent("samples.json"), options: .atomic)
        XCTAssertEqual(try Data(contentsOf: source.url), before)
        let servers = try await api.serveStatus()
        XCTAssertTrue(servers.isEmpty)
    }
    func testPerPromptWarmupRunsImmediatelyBeforeItsMeasurementAndPreservesTools() async throws {
        let events = ProbeEventRecorder(), prober = WarmupRecordingProber()
        let probe = ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "hash" }, start: { _, _, _ in },
            stop: { _ in await events.record("stop") }), prober: prober, pickPort: { 9999 })
        let tool = PromptToolSpec(name: "lookup", description: "Lookup", parametersJSON: "{\"type\":\"object\"}")
        let prompts = [ProbePrompt(id: "a", prompt: "First", maxTokens: 32, tool: tool),
                       ProbePrompt(id: "b", prompt: "Second", maxTokens: 64)]
        let result = try await probe.run(modelPath: "/Models/strata", prompts: prompts,
            warmup: [ProbePrompt(id: "startup", prompt: "Say OK.", maxTokens: 4)], warmEachPrompt: true)
        let requests = await prober.requests
        XCTAssertEqual(requests.map(\.prompt), ["Say OK.", "First", "First", "Second", "Second"])
        XCTAssertEqual(requests.map(\.maxTokens), [4, 1, 32, 1, 64])
        XCTAssertEqual(requests.map(\.model), Array(repeating: "served-model", count: 5))
        XCTAssertEqual(requests.map(\.tool), [nil, tool, tool, nil, nil])
        XCTAssertEqual(Set(result.samples.keys), ["a", "b"])
        XCTAssertEqual(result.samples["a"]?.text, "measured First")
        XCTAssertEqual(result.samples["b"]?.text, "measured Second")
        let lifecycle = await events.values
        XCTAssertEqual(lifecycle, ["stop"])
    }
    func testPerPromptWarmupIsOptInAndFailuresStopBeforeMeasurement() async throws {
        let prompts = [ProbePrompt(id: "a", prompt: "First", maxTokens: 32)]
        let ordinary = WarmupRecordingProber()
        let base = ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "hash" }, start: { _, _, _ in }, stop: { _ in }),
            prober: ordinary, pickPort: { 9999 })
        _ = try await base.run(modelPath: "/Models/strata", prompts: prompts)
        let ordinaryRequests = await ordinary.requests
        XCTAssertEqual(ordinaryRequests.map(\.maxTokens), [32])
        for cancel in [false, true] {
            let events = ProbeEventRecorder()
            let prober = WarmupRecordingProber(failOnCall: cancel ? nil : 1, cancelOnCall: cancel ? 1 : nil)
            let probe = ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "hash" }, start: { _, _, _ in },
                stop: { _ in await events.record("stop") }), prober: prober, pickPort: { 9999 })
            let task = Task { try await probe.run(modelPath: "/Models/strata", prompts: prompts, warmEachPrompt: true) }
            do { _ = try await task.value; XCTFail("Warm-up failure or cancellation must stop the run") }
            catch {
                if cancel { XCTAssertTrue(error is ServeProbeCancelled) }
                else { XCTAssertEqual(error as? WarmupRecordingProber.Failure, .warmup) }
            }
            let requests = await prober.requests, lifecycle = await events.values
            XCTAssertEqual(requests.map(\.maxTokens), [1])
            XCTAssertEqual(lifecycle, ["stop"])
        }
    }
    func testChangedSuggestedFingerprintIsRefusedBeforeStarting() async throws {
        let expected = try XCTUnwrap(ProbeServingEvidence(plan: ["runtime": "strata", "preview_hash": "old",
            "strata_model_fingerprint": "model", "strata_runtime_fingerprint": "old-runtime",
            "strata_speculation": false, "strata_expert_memory_gb": 2.0, "strata_context_tokens": 8192]))
        let actual = try XCTUnwrap(ProbeServingEvidence(plan: ["runtime": "strata", "preview_hash": "new",
            "strata_model_fingerprint": "model", "strata_runtime_fingerprint": "new-runtime",
            "strata_speculation": false, "strata_expert_memory_gb": 2.0, "strata_context_tokens": 8192]))
        var probe = ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "unused" },
            start: { _, _, _ in XCTFail("A stale suggestion must not load") }, stop: { _ in XCTFail("No server started") },
            reviewedPreview: { _, _ in ProbeServePreview(hash: "new", evidence: actual) }), prober: OpenAIEndpointProber())
        probe.expectedServingEvidence = expected
        do { _ = try await probe.run(modelPath: "/Models/strata"); XCTFail("Expected stale runtime rejection") } catch { }
    }
    func testTradeoffLatencyRequiresCompleteAnswersAndFiniteTimings() {
        func result(_ samples: [ComparisonSample]) -> VariantResult {
            VariantResult(modelPath: "/m", modelSignature: nil, samples: samples, aggregateTokensPerSecond: nil,
                aggregateTTFTSeconds: nil, error: nil)
        }
        let first = ComparisonSample(promptID: "a", outputExcerpt: "ok", tokensPerSecond: nil, timeToFirstTokenSeconds: nil,
            error: nil, finishReason: "stop", timeToFirstAnswerSeconds: 2)
        let second = ComparisonSample(promptID: "b", outputExcerpt: "ok", tokensPerSecond: nil, timeToFirstTokenSeconds: nil,
            error: nil, finishReason: "stop", timeToFirstAnswerSeconds: 4)
        XCTAssertEqual(result([first, second]).memoryTradeoffAnswerSeconds, 3)
        let unfinished = ComparisonSample(promptID: "b", outputExcerpt: "", tokensPerSecond: nil, timeToFirstTokenSeconds: nil,
            error: nil, reasoningText: "thinking", finishReason: "length", timeToFirstAnswerSeconds: 1)
        XCTAssertNil(result([first, unfinished]).memoryTradeoffAnswerSeconds)
        XCTAssertNil(result([ComparisonSample(promptID: "a", outputExcerpt: "ok", tokensPerSecond: nil,
            timeToFirstTokenSeconds: nil, error: nil, finishReason: "stop", timeToFirstAnswerSeconds: .nan)]).memoryTradeoffAnswerSeconds)
        XCTAssertNil(result([]).memoryTradeoffAnswerSeconds)
    }

    func testMemoryEvidenceIsRecordedAndLegacyResultsRemainUnknown() async throws {
        let events = ProbeEventRecorder()
        var probe = makeProbe(events: events, responder: { _ in self.sample() })
        probe.memoryProbe = { MemorySnapshot(totalBytes: 128_000_000_000, availableBytes: 40_000_000_000) }
        let outcome = try await probe.run(modelPath: "/Models/model", prompts: [ProbePrompt(id: "p", prompt: "hello", maxTokens: 8)])
        let evidence = try XCTUnwrap(outcome.systemMemory)
        XCTAssertEqual(evidence.baselineAvailableBytes, 40_000_000_000)
        XCTAssertEqual(evidence.minimumAvailableBytes, 40_000_000_000)
        XCTAssertGreaterThanOrEqual(evidence.sampleCount, 2)
        let result = VariantResult(modelPath: "/Models/model", modelSignature: nil, samples: [],
            aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil, systemMemory: evidence)
        let data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(VariantResult.self, from: data).systemMemory, evidence)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "systemMemory")
        XCTAssertNil(try JSONDecoder().decode(VariantResult.self, from: JSONSerialization.data(withJSONObject: legacy)).systemMemory)
        probe.memoryProbe = { MemorySnapshot(totalBytes: 1, availableBytes: 2) }
        let unavailable = try await probe.run(modelPath: "/Models/model", prompts: [])
        XCTAssertNil(unavailable.systemMemory)
    }

    func testMemorySamplingEndsWhenStartFails() async throws {
        let readings = MemoryReadCounter()
        var probe = ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "hash" },
            start: { _, _, _ in throw StubError.boom }, stop: { _ in XCTFail("A failed start owns its cleanup") }),
            prober: StubProber(ready: true, responder: { _ in self.sample() }), pickPort: { 9999 })
        probe.memoryProbe = { readings.read() }
        do { _ = try await probe.run(modelPath: "/Models/model"); XCTFail("Expected a start failure") } catch { }
        let ended = readings.count
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(readings.count, ended)
    }

    func testMemorySamplingCoversLoadingAndKeepsUnavailableReadingsSeparate() async throws {
        for invalidSecond in [false, true] {
            let readings = MemoryReadCounter(invalidSecond: invalidSecond)
            var probe = ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "hash" },
                start: { _, _, _ in
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while readings.count < 2 && ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    XCTAssertGreaterThanOrEqual(readings.count, 2, "A loading sample must precede server readiness")
                }, stop: { _ in }),
                prober: StubProber(ready: true, responder: { _ in self.sample() }), pickPort: { 9999 })
            probe.memoryProbe = { readings.read() }
            let outcome = try await probe.run(modelPath: "/Models/model", prompts: [])
            let memory = try XCTUnwrap(outcome.systemMemory)
            XCTAssertEqual(memory.baselineAvailableBytes, 40_000_000_000)
            XCTAssertEqual(memory.minimumAvailableBytes, invalidSecond ? 35_000_000_000 : 10_000_000_000)
            XCTAssertEqual(memory.endingAvailableBytes, 35_000_000_000)
            XCTAssertEqual(memory.missedSamples, invalidSecond ? 1 : 0)
        }
    }
    func testProfileReceiptRequiresTheConfirmedPlanAndProcessIdentity() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let receipt: [String: Any] = ["preview_hash": "confirmed", "pid": 123, "port": 9999, "path": "/Models/strata"]
        try JSONSerialization.data(withJSONObject: receipt).write(to: file)
        let server = ServerInfo(path: "/Models/strata", runtime: "strata", port: 9999, pid: 123, receipt: file.path)
        XCTAssertTrue(ServingProfile.matchesReceipt(server, previewHash: "confirmed"))
        XCTAssertFalse(ServingProfile.matchesReceipt(server, previewHash: "old"))
        XCTAssertFalse(ServingProfile.matchesReceipt(server, previewHash: nil))
        XCTAssertFalse(ServingProfile.matchesReceipt(ServerInfo(path: "/Models/strata", port: 9999, pid: 456, receipt: file.path), previewHash: "confirmed"))
        XCTAssertFalse(ServingProfile.matchesReceipt(ServerInfo(path: "/Models/other", port: 9999, pid: 123, receipt: file.path), previewHash: "confirmed"))
        XCTAssertFalse(ServingProfile.matchesReceipt(ServerInfo(path: "/Models/strata", receipt: file.path), previewHash: "confirmed"))
    }
    @MainActor
    func testVerifiedServingProfileUsesReviewedOptionsForEagerAndJIT() async throws {
        let options = StrataComparisonOptions(speculation: true, expertMemoryGB: 2, contextTokens: 8192)
        var profile = ServingProfile(id: UUID(), name: "Paged", modelPath: "/Models/strata", options: options)
        profile.verification = ServingProfileVerification(options: options, modelFingerprint: "model", runtimeFingerprint: "runtime",
            suiteVersion: CanarySuite.version, canaries: CanarySuite.cases.map {
                CanaryResult(id: $0.id, title: $0.title, passed: true, failureReason: nil, responseExcerpt: "fixture",
                             tokensPerSecond: nil, timeToFirstTokenSeconds: nil)
            }, verifiedAt: Date())
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: "/fixture", command: { _, argv, _, _ in
            XCTAssertEqual(argv[try XCTUnwrap(argv.firstIndex(of: "--strata-speculation")) + 1], "on")
            XCTAssertEqual(argv[try XCTUnwrap(argv.firstIndex(of: "--strata-expert-memory-gb")) + 1], "2.0")
            XCTAssertEqual(argv[try XCTUnwrap(argv.firstIndex(of: "--strata-context-tokens")) + 1], "8192")
            if argv.contains("--confirm") {
                XCTAssertEqual(argv[try XCTUnwrap(argv.firstIndex(of: "--preview-hash")) + 1], "reviewed")
                return [:]
            }
            return ["plan": ["runtime": "strata", "preview_hash": "reviewed", "strata_model_fingerprint": "model",
                "strata_runtime_fingerprint": "runtime", "strata_speculation": true, "strata_expert_memory_gb": 2.0,
                "strata_context_tokens": 8192]]
        })
        let lifecycle = ServeLifecycle.verifiedProfile(profile, api: api)
        let hash = try await lifecycle.preview(profile.modelPath, 9999)
        try await lifecycle.start(profile.modelPath, 9999, hash)
        let jitHash = try await XCTUnwrap(lifecycle.jitPreview)(profile.modelPath, 9999, .automatic)
        try await XCTUnwrap(lifecycle.jitStart)(profile.modelPath, 9999, jitHash, .automatic)
        var changed = profile; changed.options.contextTokens = 2048
        do { _ = try await changed.preview(api: api, port: 9999); XCTFail("Changed profile settings must require verification") }
        catch { XCTAssertFalse(changed.hasPassedVerification) }
    }
    func testServingProfileVerificationBindsSettingsAndBothFingerprints() throws {
        let options = StrataComparisonOptions(expertMemoryGB: 2, contextTokens: 8192)
        let canaries = CanarySuite.cases.map { CanaryResult(id: $0.id, title: $0.title, passed: true,
            failureReason: nil, responseExcerpt: "fixture", tokensPerSecond: nil, timeToFirstTokenSeconds: nil) }
        var profile = ServingProfile(id: UUID(), name: "Paged", modelPath: "/Models/strata", options: options)
        let plan: [String: Any] = ["runtime": "strata", "preview_hash": "preview", "strata_model_fingerprint": "model",
            "strata_runtime_fingerprint": "runtime", "strata_speculation": false,
            "strata_expert_memory_gb": 2.0, "strata_context_tokens": 8192]
        XCTAssertThrowsError(try profile.validate(plan: plan))
        profile.verification = ServingProfileVerification(options: options, modelFingerprint: "model", runtimeFingerprint: "runtime",
            suiteVersion: CanarySuite.version, canaries: canaries, verifiedAt: Date())
        XCTAssertNoThrow(try profile.validate(plan: plan))
        for key in ["strata_model_fingerprint", "strata_runtime_fingerprint"] {
            var changed = plan; changed[key] = "changed"
            XCTAssertThrowsError(try profile.validate(plan: changed))
        }
        profile.options.speculation = true
        XCTAssertThrowsError(try profile.validate(plan: plan))
    }
    private func sample(text: String = "ok") -> ProbeSample {
        ProbeSample(text: text, completionTokens: 10, timeToFirstTokenSeconds: 0.05, durationSeconds: 0.5, metricsEstimated: false)
    }

    private func makeProbe(
        events: ProbeEventRecorder,
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

    func testStopFailureIsReportedInsteadOfSuccessfulMeasurements() async throws {
        let probe = ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "hash" },
            start: { _, _, _ in }, stop: { _ in throw StubError.boom }),
            prober: StubProber(ready: true, responder: { _ in self.sample() }), pickPort: { 9999 })
        do {
            _ = try await probe.run(modelPath: "/Models/strata")
            XCTFail("Stop failure must not return a successful result")
        } catch { guard case ServeProbeError.stopFailed = error else { return XCTFail("Unexpected error: \(error)") } }
    }

    func testStreamedServerErrorDoesNotBecomeAnEstimatedMeasurement() async throws {
        let prober = OpenAIEndpointProber(session: stubSession(body: "data: {\"error\":{\"message\":\"context exceeded\"}}\n\n"))
        do {
            _ = try await prober.chat(baseURL: URL(string: "http://127.0.0.1:9999")!, model: "model", prompt: "hello", maxTokens: 8)
            XCTFail("Server error must fail the sample")
        } catch { guard case ProbeHTTPError.invalidResponse = error else { return XCTFail("Unexpected error: \(error)") } }
    }

    func testStrataReasoningStreamRecordsOutputAndFirstTokenTime() async throws {
        let body = #"data: {"choices":[{"delta":{"reasoning_content":"Checking the example."}}]}"#
            + "\n" + #"data: {"usage":{"completion_tokens":4,"prompt_tokens":10},"choices":[]}"# + "\ndata: [DONE]\n"
        let sample = try await OpenAIEndpointProber(session: stubSession(body: body)).chat(
            baseURL: URL(string: "http://127.0.0.1:9999")!, model: "strata", prompt: "hello", maxTokens: 8)
        XCTAssertEqual(sample.text, "")
        XCTAssertEqual(sample.reasoningText, "Checking the example.")
        XCTAssertNotNil(sample.timeToFirstTokenSeconds)
        XCTAssertEqual(sample.completionTokens, 4)
        XCTAssertFalse(sample.metricsEstimated)
    }

    func testStreamDraftCountsPersistWithoutChangingAnswerMetrics() async throws {
        let body = #"data: {"choices":[{"delta":{"content":"323"}}]}"# + "\n"
            + #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"completion_tokens":12},"timings":{"draft_n":18,"draft_n_accepted":8}}"#
            + "\ndata: [DONE]\n"
        let sample = try await OpenAIEndpointProber(session: stubSession(body: body)).chat(
            baseURL: URL(string: "http://127.0.0.1:9999")!, model: "strata", prompt: "17 * 19", maxTokens: 128)
        XCTAssertEqual(sample.draftTokens?.offered, 18)
        XCTAssertEqual(sample.draftTokens?.accepted, 8)
        XCTAssertEqual(try XCTUnwrap(sample.draftTokens?.acceptanceFraction), 8.0 / 18.0, accuracy: 0.000001)
        XCTAssertEqual(sample.text, "323"); XCTAssertEqual(sample.completionTokens, 12)
        let recorded = ComparisonAggregation.sample(from: sample, promptID: "p")
        let data = try JSONEncoder().encode(recorded)
        let restored = try JSONDecoder().decode(ComparisonSample.self, from: data)
        XCTAssertEqual(restored.draftTokens, sample.draftTokens)
        XCTAssertTrue(restored.hasCompletedAnswer)
        let label = ComparisonDraftTokenEvidenceView.description(restored.draftTokens)
        XCTAssertTrue(label.contains("8 of 18")); XCTAssertTrue(label.contains("44.4%"))
        var legacy = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "draftTokens")
        let old = try JSONDecoder().decode(ComparisonSample.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.draftTokens)
        XCTAssertEqual(ComparisonDraftTokenEvidenceView.description(old.draftTokens), "Draft counts not reported")
    }

    func testDraftCountsRequireValidReportedPairsAndDoNotInventAcceptance() throws {
        XCTAssertNil(DraftTokenEvidence(timings: [:]))
        for timings: [String: Any] in [["draft_n": 10], ["draft_n": 10, "draft_n_accepted": 11],
            ["draft_n": -1, "draft_n_accepted": 0], ["draft_n": true, "draft_n_accepted": 0],
            ["draft_n": 1.5, "draft_n_accepted": 0], ["draft_n": "10", "draft_n_accepted": 1]] {
            XCTAssertNil(DraftTokenEvidence(timings: timings))
        }
        let zero = try XCTUnwrap(DraftTokenEvidence(timings: ["draft_n": 0, "draft_n_accepted": 0]))
        XCTAssertNil(zero.acceptanceFraction)
        XCTAssertEqual(ComparisonDraftTokenEvidenceView.description(zero), "Server reported 0 draft tokens")
    }

    func testReportedPromptProcessingSeparatesCachedTokensAndServerClock() async throws {
        let body = #"data: {"choices":[{"delta":{"content":"323"}}]}"# + "\n"
            + #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":12},"timings":{"cache_n":80,"prompt_n":20,"prompt_ms":200}}"#
            + "\ndata: [DONE]\n"
        let sample = try await OpenAIEndpointProber(session: stubSession(body: body)).chat(
            baseURL: URL(string: "http://127.0.0.1:9999")!, model: "strata", prompt: "17 * 19", maxTokens: 128)
        let evidence = try XCTUnwrap(sample.promptProcessing)
        XCTAssertEqual(evidence.cachedTokens, 80); XCTAssertEqual(evidence.processedTokens, 20)
        XCTAssertEqual(evidence.processingSeconds, 0.2)
        XCTAssertEqual(evidence.tokensPerSecond, 100)
        let ttft = try XCTUnwrap(sample.timeToFirstTokenSeconds)
        XCTAssertEqual(try XCTUnwrap(sample.prefillTokensPerSecond), 20 / ttft, accuracy: 1)
        let recorded = ComparisonAggregation.sample(from: sample, promptID: "p")
        let saved = try JSONDecoder().decode(ComparisonSample.self, from: JSONEncoder().encode(recorded))
        XCTAssertEqual(saved.promptProcessing, evidence)
        XCTAssertTrue(ComparisonPromptProcessingEvidenceView.description(saved.promptProcessing).contains("80 cached"))
        var legacy = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(recorded)) as? [String: Any])
        legacy.removeValue(forKey: "promptProcessing")
        let old = try JSONDecoder().decode(ComparisonSample.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.promptProcessing)
        XCTAssertEqual(ComparisonPromptProcessingEvidenceView.description(old.promptProcessing), "Prompt cache and server timing not reported")
    }

    func testPromptProcessingValidatesCountsAndDoesNotInventZeroWorkSpeed() throws {
        let usage: [String: Any] = ["prompt_tokens": 100]
        let cached = try XCTUnwrap(PromptProcessingEvidence(usage: usage, timings: ["cache_n": 100, "prompt_n": 0, "prompt_ms": 0]))
        XCTAssertNil(cached.tokensPerSecond)
        let sample = ProbeSample(text: "323", completionTokens: 1, promptTokens: 100, timeToFirstTokenSeconds: 2,
            durationSeconds: 3, metricsEstimated: false, promptProcessing: cached)
        XCTAssertNil(sample.prefillTokensPerSecond)
        XCTAssertTrue(ComparisonPromptProcessingEvidenceView.description(cached).contains("No new prompt tokens"))
        for timings: [String: Any] in [["cache_n": 80, "prompt_n": 21, "prompt_ms": 200],
            ["cache_n": -1, "prompt_n": 101, "prompt_ms": 200], ["cache_n": 80, "prompt_n": 20, "prompt_ms": -1],
            ["cache_n": 80, "prompt_n": 20, "prompt_ms": true], ["cache_n": "80", "prompt_n": 20, "prompt_ms": 200]] {
            XCTAssertNil(PromptProcessingEvidence(usage: usage, timings: timings))
        }
    }

    func testConflictingPromptProcessingRemainsUnreported() async throws {
        let body = #"data: {"usage":{"prompt_tokens":100},"timings":{"cache_n":80,"prompt_n":20,"prompt_ms":200},"choices":[]}"#
            + "\n" + #"data: {"usage":{"prompt_tokens":100},"timings":{"cache_n":90,"prompt_n":10,"prompt_ms":100},"choices":[]}"#
            + "\ndata: [DONE]\n"
        let sample = try await OpenAIEndpointProber(session: stubSession(body: body)).chat(
            baseURL: URL(string: "http://127.0.0.1:9999")!, model: "strata", prompt: "hello", maxTokens: 32)
        XCTAssertNil(sample.promptProcessing)
    }

    func testConflictingStreamDraftCountsRemainUnreported() async throws {
        let body = #"data: {"usage":{"completion_tokens":12},"timings":{"draft_n":18,"draft_n_accepted":8},"choices":[]}"#
            + "\n" + #"data: {"usage":{"completion_tokens":13},"timings":{"draft_n":20,"draft_n_accepted":9},"choices":[]}"#
            + "\ndata: [DONE]\n"
        let sample = try await OpenAIEndpointProber(session: stubSession(body: body)).chat(
            baseURL: URL(string: "http://127.0.0.1:9999")!, model: "strata", prompt: "hello", maxTokens: 32)
        XCTAssertNil(sample.draftTokens)
    }

    func testReasoningAndAnswerInOneDeltaRemainSeparateWithFinishAndUsage() async throws {
        let body = #"data: {"choices":[{"delta":{"reasoning_content":"Compute.","content":"323"}}]}"#
            + "\n" + #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#
            + "\n" + #"data: {"usage":{"completion_tokens":7,"prompt_tokens":12},"choices":[]}"# + "\ndata: [DONE]\n"
        let sample = try await OpenAIEndpointProber(session: stubSession(body: body)).chat(
            baseURL: URL(string: "http://127.0.0.1:9999")!, model: "strata", prompt: "17 * 19", maxTokens: 128)
        XCTAssertEqual(sample.text, "323")
        XCTAssertEqual(sample.reasoningText, "Compute.")
        XCTAssertEqual(sample.finishReason, "stop")
        XCTAssertNotNil(sample.timeToFirstAnswerSeconds)
        let recorded = ComparisonAggregation.sample(from: sample, promptID: "p")
        XCTAssertEqual(recorded.fullOutput, "323")
        XCTAssertEqual(recorded.reasoningText, "Compute.")
        XCTAssertEqual(recorded.completionTokens, 7)
        XCTAssertEqual(recorded.finishReason, "stop")
        XCTAssertEqual(recorded.metricsEstimated, false)
    }

    func testReasoningOnlyLengthFinishIsNotACompletedAnswer() async throws {
        let body = #"data: {"choices":[{"delta":{"reasoning":"Still calculating."}}]}"#
            + "\n" + #"data: {"choices":[{"finish_reason":"length","delta":{}}]}"# + "\ndata: [DONE]\n"
        let sample = try await OpenAIEndpointProber(session: stubSession(body: body)).chat(
            baseURL: URL(string: "http://127.0.0.1:9999")!, model: "strata", prompt: "compute", maxTokens: 8)
        let recorded = ComparisonAggregation.sample(from: sample, promptID: "p")
        XCTAssertEqual(recorded.fullOutput, "")
        XCTAssertEqual(recorded.finishReason, "length")
        XCTAssertNil(recorded.timeToFirstAnswerSeconds)
        XCTAssertFalse(recorded.hasCompletedAnswer)
        XCTAssertTrue(recorded.metricsEstimated == true)
    }

    func testRunServesEveryCanaryThenStops() async throws {
        let events = ProbeEventRecorder()
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
        let events = ProbeEventRecorder()
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

    func testFailedWarmupStopsServerWithoutMeasuringPrompts() async throws {
        let events = ProbeEventRecorder()
        let probe = makeProbe(events: events) { id in
            if id == "unknown" { throw StubError.boom }
            XCTFail("Measured a canary after warm-up failed")
            return self.sample()
        }
        do {
            _ = try await probe.run(modelPath: "/Models/strata",
                prompts: [ProbePrompt(id: "arithmetic", prompt: CanarySuite.cases[0].prompt, maxTokens: 8)],
                warmup: [ProbePrompt(id: "warmup", prompt: "Say OK.", maxTokens: 4)])
            XCTFail("Expected warm-up failure")
        } catch {
            XCTAssertEqual(error as? StubError, .boom)
        }
        let recorded = await events.values
        XCTAssertEqual(recorded, ["preview:/Models/strata:9999", "start:/Models/strata:9999:hash-1", "stop:9999"])
    }

    func testNeverReadyThrowsAndStops() async {
        let events = ProbeEventRecorder()
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

    func testMissingPreviewHashDoesNotStart() async {        let events = ProbeEventRecorder()
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

    func testToolSpecValidatesArgumentsAgainstRequiredKeys() {
        let spec = PromptToolSpec(
            name: "get_current_weather",
            description: "Get the current weather for a city.",
            parametersJSON: #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#
        )
        XCTAssertTrue(spec.argumentsAreValid(#"{"city":"Paris"}"#))
        XCTAssertFalse(spec.argumentsAreValid(#"{"location":"Paris"}"#))  // missing required key
        XCTAssertFalse(spec.argumentsAreValid("not json"))
        XCTAssertFalse(spec.argumentsAreValid(""))
        XCTAssertFalse(spec.argumentsAreValid(#"["city"]"#))  // not an object
    }

    func testChatValidatesStreamedToolCallArguments() async throws {
        let sse = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"get_current_weather","arguments":""}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Paris\"}"}}]}}]}"#,
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
        XCTAssertEqual(sample.toolCallsValid, 1)
    }

    func testChatFlagsToolCallWithMissingRequiredKeysAsInvalid() async throws {
        let sse = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"get_current_weather","arguments":"{\"wrong\":\"key\"}"}}]}}]}"#,
            "data: [DONE]",
        ].joined(separator: "\n")
        let session = stubSession(body: sse)
        let prober = OpenAIEndpointProber(session: session)
        let tool = PromptToolSpec(
            name: "get_current_weather",
            description: "d",
            parametersJSON: #"{"type":"object","required":["city"]}"#
        )

        let sample = try await prober.chat(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            model: "m",
            prompt: "Weather?",
            maxTokens: 64,
            tool: tool
        )

        XCTAssertEqual(sample.toolCalls, 1)
        XCTAssertEqual(sample.toolCallsValid, 0)
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

private actor WarmupRecordingProber: EndpointProbing {
    enum Failure: Error, Equatable { case warmup }
    struct Request: Sendable {
        let model: String
        let prompt: String
        let maxTokens: Int
        let tool: PromptToolSpec?
    }
    private(set) var requests: [Request] = []
    let failOnCall: Int?
    let cancelOnCall: Int?
    init(failOnCall: Int? = nil, cancelOnCall: Int? = nil) {
        self.failOnCall = failOnCall; self.cancelOnCall = cancelOnCall
    }
    func isReady(baseURL: URL) async -> Bool { true }
    func listModels(baseURL: URL) async -> [String] { ["served-model"] }
    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int) async throws -> ProbeSample {
        try await chat(baseURL: baseURL, model: model, prompt: prompt, maxTokens: maxTokens, tool: nil)
    }
    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int, tool: PromptToolSpec?) async throws -> ProbeSample {
        requests.append(Request(model: model, prompt: prompt, maxTokens: maxTokens, tool: tool))
        if requests.count == failOnCall { throw Failure.warmup }
        if requests.count == cancelOnCall { withUnsafeCurrentTask { $0?.cancel() } }
        return ProbeSample(text: maxTokens == 1 ? "warm" : "measured \(prompt)", completionTokens: maxTokens == 1 ? 1 : 10,
            timeToFirstTokenSeconds: 0.1, durationSeconds: 1, metricsEstimated: false,
            finishReason: maxTokens == 1 ? "length" : "stop", timeToFirstAnswerSeconds: 0.1)
    }
}

private actor ProbeEventRecorder {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

private final class MemoryReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private let invalidSecond: Bool
    init(invalidSecond: Bool = false) { self.invalidSecond = invalidSecond }
    var count: Int { lock.withLock { value } }
    func read() -> MemorySnapshot? {
        let reading = lock.withLock { value += 1; return value }
        if invalidSecond && reading == 2 { return nil }
        return MemorySnapshot(totalBytes: 128_000_000_000,
            availableBytes: reading == 1 ? 40_000_000_000 : reading == 2 ? 10_000_000_000 : 35_000_000_000)
    }
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

/// Sends an HTTP stream without its terminating chunk, and observes the client's close.
private final class ProbeStreamPeer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "probe-stream-peer")
    private var connections: [NWConnection] = []
    private let body: String
    private let status: Int
    private let opened: @Sendable () -> Void
    private let closed: @Sendable () -> Void
    var port: UInt16 { listener.port!.rawValue }

    private init(body: String, status: Int, opened: @escaping @Sendable () -> Void,
                 closed: @escaping @Sendable () -> Void) throws {
        self.body = body; self.status = status; self.opened = opened; self.closed = closed
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start(body: String, status: Int, opened: @escaping @Sendable () -> Void,
                      closed: @escaping @Sendable () -> Void) async throws -> ProbeStreamPeer {
        let peer = try ProbeStreamPeer(body: body, status: status, opened: opened, closed: closed)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: peer.listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): peer.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            peer.listener.newConnectionHandler = { connection in
                peer.connections.append(connection)
                connection.start(queue: peer.queue)
                peer.receiveRequest(connection, data: Data())
            }
            peer.listener.start(queue: peer.queue)
        }
        return peer
    }

    private func receiveRequest(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] chunk, _, complete, error in
            guard error == nil else { connection.cancel(); return }
            var data = data; data.append(chunk ?? Data())
            guard data.count < 1_048_576, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            guard let end = request.range(of: "\r\n\r\n") else {
                if complete { connection.cancel() } else { receiveRequest(connection, data: data) }; return
            }
            let header = String(request[..<end.lowerBound])
            let length = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last!.trimmingCharacters(in: .whitespaces)) } ?? 0
            guard request[end.upperBound...].utf8.count >= length else { receiveRequest(connection, data: data); return }
            let response = "HTTP/1.1 \(status) Response\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
                + String(body.utf8.count, radix: 16) + "\r\n" + body + "\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [self] error in
                guard error == nil else { connection.cancel(); return }
                opened()
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [self] _, _, complete, error in
                    if complete || error != nil { closed() }
                    connection.cancel()
                }
            })
        }
    }

    func stop() {
        queue.sync {
            listener.newConnectionHandler = nil
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}
