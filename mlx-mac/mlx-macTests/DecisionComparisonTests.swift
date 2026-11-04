import os
import XCTest
@testable import mlx_workbench

/// Serves canned System One responses and records each request that leaves the HTTP client.
private final class SystemOneStubProtocol: URLProtocol {
    struct Seen: Sendable { let method: String; let path: String; let body: Data }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Data] = [:]
    nonisolated(unsafe) private static var seen: [Seen] = []

    static func reset(_ responses: [String: Data]) { lock.withLock { self.responses = responses; seen = [] } }
    static var requests: [Seen] { lock.withLock { seen } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SystemOneStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let path = request.url?.path ?? ""
        let payload = Self.lock.withLock { () -> Data? in
            Self.seen.append(Seen(method: request.httpMethod ?? "", path: path, body: body))
            return Self.responses[path]
        }
        let status = payload == nil ? 404 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Classification lanes never serve a model; any chat request is a failure.
private struct NoChatProber: EndpointProbing {
    struct ChatNotExpected: Error {}
    func listModels(baseURL: URL) async -> [String] { [] }
    func isReady(baseURL: URL) async -> Bool { true }
    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int) async throws -> ProbeSample { throw ChatNotExpected() }
}

final class DecisionComparisonTests: XCTestCase {
    private var root: URL!

    /// Kev-4B's `/v1/systemone` answer to the double-charge ticket, recorded from `kev.serve` on 127.0.0.1:8009.
    private static let kevAnswer = Data("""
    {"model":"kev-latest","answers":{"department":{"type":"choice","choice":"billing","confidence":0.87,"probabilities":{"billing":0.91,"technical":0.01,"sales":0.08}},"urgency":{"type":"score","score":1.11,"legend":{"0":"not urgent","1":"somewhat urgent","2":"very urgent"},"probabilities":{"0":0.29,"1":0.32,"2":0.39},"confidence":0.55},"refund":{"type":"noul","noul":0.93}},"usage":{"input_tokens":84,"output_tokens":159},"latency_ms":4086.4}
    """.utf8)
    private static let kevModels = Data("""
    {"models":[{"id":"kev-latest","aliases":["jev-latest"],"run":"models/kev-4b-qwen3","base":"Qwen/Qwen3-4B-Base"}]}
    """.utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("decision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var routing: PromptSet {
        var set = ComparisonMediaFixtures.supportRoutingSet
        set.prompts = set.prompts.filter { ["routing-double-charge", "routing-outage"].contains($0.id) }
        return set
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSystemOneRequestKeepsQuestionAndOptionOrderAndSendsChoiceCriteriaAsAnObject() throws {
        let entry = routing.prompts[0]
        let body = try DecisionRequest.body(state: entry.text, questions: try XCTUnwrap(entry.decisionQuestions), model: "kev-latest")
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertTrue(text.hasPrefix(#"{"model":"kev-latest","state":"I was charged twice"#))
        let order = ["\"department\"", "\"billing\"", "\"technical\"", "\"sales\"", "\"account\"", "\"urgency\"", "\"refund\""]
        let positions = try order.map { try XCTUnwrap(text.range(of: $0)?.lowerBound, $0) }
        XCTAssertEqual(positions, positions.sorted(), "questions and options must keep their editor order")

        let questions = try XCTUnwrap(try json(body)["questions"] as? [String: [String: Any]])
        let department = try XCTUnwrap(questions["department"]?["criteria"] as? [String: String])
        XCTAssertEqual(department["billing"], "payments, invoices and refunds")
        XCTAssertEqual(questions["urgency"]?["criteria"] as? [String], ["not urgent", "somewhat urgent", "very urgent"])
        XCTAssertEqual(questions["refund"]?["criteria"] as? [String: String],
                       ["true": "the customer asks for a refund", "false": "the customer does not ask for a refund"])

        let engine = try json(try DecisionRequest.body(state: entry.text, questions: try XCTUnwrap(entry.decisionQuestions)))
        XCTAssertNil(engine["model"], "convert decide takes no model name")
        let bare = DecisionQuestion(name: "sentiment", kind: .choice, instructions: "Tone?", options: [.init(label: "positive"), .init(label: "negative")])
        let criteria = try json(try DecisionRequest.body(state: "Great", questions: [bare]))["questions"] as? [String: [String: Any]]
        XCTAssertEqual((criteria?["sentiment"]?["criteria"] as? [String: Any])?.keys.sorted(), ["negative", "positive"])
        XCTAssertTrue((criteria?["sentiment"]?["criteria"] as? [String: Any])?["positive"] is NSNull)
    }

    func testKevsRecordedAnswerGradesScoreByItsMostLikelyLevel() throws {
        let result = try JSONDecoder().decode(DecisionResult.self, from: Self.kevAnswer)
        var questions = try XCTUnwrap(routing.prompts[0].decisionQuestions)
        questions[1].expected = "1"

        let evidence = DecisionScoring.grade(questions, answers: result.answers)

        XCTAssertEqual(evidence.grades.map(\.answer), ["billing", "2", "true"])
        XCTAssertEqual(evidence.grades.map(\.correct), [true, false, true])
        XCTAssertEqual(evidence.grades[1].score, 1.11)
        XCTAssertEqual(evidence.grades[1].expectedProbability, 0.32)
        XCTAssertEqual(evidence.grades[2].probability, 0.93)
        XCTAssertEqual(try XCTUnwrap(evidence.accuracy), 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(evidence.summary(questions: questions), "department: billing ✓ · urgency: 2 · very urgent ✗ · refund: True ✓")
    }

    func testSystemOneInventoryListsDecisionModelsThatOnlyClassificationAccepts() async throws {
        SystemOneStubProtocol.reset(["/v1/models": Self.kevModels])
        let host = ModelHost(name: "Kev", provider: .systemOne, baseURL: "http://127.0.0.1:8009")
        let inventory = try await SystemOneHostAdapter().inventory(
            from: HostReader(host: host, token: nil, http: HostHTTPClient(session: SystemOneStubProtocol.session())))

        let model = try XCTUnwrap(inventory.models.first)
        XCTAssertEqual(inventory.models.count, 1)
        XCTAssertEqual(model.modelID, "kev-latest")
        XCTAssertEqual(model.family, "Qwen/Qwen3-4B-Base")
        let target = HostedComparisonTarget(host: host, model: model, capturedAt: inventory.capturedAt)
        XCTAssertNoThrow(try target.validate(mode: .classification))
        XCTAssertThrowsError(try target.validate(mode: .chat))
    }

    @MainActor
    func testLocalClassificationSendsTheEngineTheRequestAndSavesGradedAnswers() async throws {
        let requests = OSAllocatedUnfairLock<[(argv: [String], body: Data)]>(initialState: [])
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: "/agent", command: { _, argv, _, _ in
            let path = try XCTUnwrap(argv.firstIndex(of: "--request").map { argv[$0 + 1] })
            let body = try Data(contentsOf: URL(fileURLWithPath: path))
            requests.withLock { $0.append((argv, body)) }
            let outage = String(data: body, encoding: .utf8)?.contains("500 error") == true
            return ["seconds": 0.057, "load_seconds": 0.25, "answers": [
                "department": ["type": "choice", "choice": outage ? "technical" : "billing",
                               "probabilities": outage ? ["billing": 0.05, "technical": 0.9, "sales": 0.03, "account": 0.02]
                                                       : ["billing": 0.88, "technical": 0.09, "sales": 0.02, "account": 0.01]],
                "urgency": ["type": "score", "score": 1.8, "probabilities": ["0": 0.03, "1": 0.17, "2": 0.8]],
                "refund": ["type": "noul", "noul": outage ? 0.1 : 0.83],
            ]]
        })
        let runsURL = root.appendingPathComponent("runs.json")
        let probe = ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "h" }, start: { _, _, _ in }, stop: { _ in }),
                               prober: NoChatProber(), readyPollIntervalNanoseconds: 1_000_000, pickPort: { 9997 })
        let coordinator = ComparisonCoordinator(probe: probe, runStore: JSONStore<ComparisonRun>(fileURL: runsURL),
            promptSetStore: JSONStore<PromptSet>(fileURL: root.appendingPathComponent("sets.json")),
            mediaRunner: LiveComparisonMediaRunner(api: api),
            outputStore: ComparisonOutputStore(root: root.appendingPathComponent("outputs")))

        coordinator.start(variants: [(path: "/m/laya", signature: String?.none)], promptSet: routing)
        for _ in 0..<2000 where coordinator.activeRunID != nil { try await Task.sleep(nanoseconds: 5_000_000) }

        let sent = requests.withLock { $0 }
        XCTAssertEqual(sent.map { Array($0.argv.prefix(4)) }, Array(repeating: ["convert", "decide", "--path", "/m/laya"], count: 2))
        let entry = routing.prompts[0]
        XCTAssertEqual(sent.first?.body, try DecisionRequest.body(state: entry.text, questions: try XCTUnwrap(entry.decisionQuestions)))

        let saved = try XCTUnwrap(try JSONStore<ComparisonRun>(fileURL: runsURL).load().first)
        XCTAssertEqual(saved.state, .completed)
        XCTAssertEqual(saved.mode, .classification)
        let lane = try XCTUnwrap(saved.results.first)
        XCTAssertEqual(try XCTUnwrap(lane.aggregateMetric), 1.0, accuracy: 1e-9, "5 of 5 scored answers match")
        XCTAssertEqual(lane.samples.map { $0.decision?.correctCount }, [2, 3])
        XCTAssertEqual(lane.samples.first?.seconds, 0.057)
        XCTAssertEqual(lane.samples.first?.loadSeconds, 0.25)
        let artifact = try XCTUnwrap(lane.samples.first?.artifact)
        let recorded = try Data(contentsOf: try XCTUnwrap(ComparisonOutputStore(root: root.appendingPathComponent("outputs"))
            .artifactURL(runID: saved.id, artifact: artifact)))
        XCTAssertEqual(try JSONDecoder().decode([String: DecisionAnswer].self, from: recorded)["department"]?.choice, "billing")
        XCTAssertEqual(ComparisonMode.classification.metricValue(of: lane), 1.0)
    }

    @MainActor
    func testHostedClassificationRunsSystemOneAndNativeLanesAgainstTheSameQuestions() async throws {
        SystemOneStubProtocol.reset(["/v1/models": Self.kevModels, "/v1/systemone": Self.kevAnswer])
        let http = HostHTTPClient(session: SystemOneStubProtocol.session())
        let host = ModelHost(name: "Kev", provider: .systemOne, baseURL: "http://127.0.0.1:8009")
        let inventory = try await SystemOneHostAdapter().inventory(from: HostReader(host: host, token: nil, http: http))
        let kev = HostedComparisonTarget(host: host, model: try XCTUnwrap(inventory.models.first), capturedAt: inventory.capturedAt)
        let laya = try JSONDecoder().decode(HostedComparisonTarget.self, from: Data("""
            {"localPath":"/m/laya-MLX-8bit/typed-decisions","displayName":"typed-decisions · MLX Workbench","capturedAt":0}
            """.utf8))
        let nativeBodies = OSAllocatedUnfairLock<[Data]>(initialState: [])
        let storeURL = root.appendingPathComponent("hosted.json")
        let coordinator = HostedComparisonCoordinator(
            store: JSONStore(fileURL: storeURL), outputStore: ComparisonOutputStore(root: root.appendingPathComponent("hosted-outputs")),
            nativeDecide: { path, body in
                XCTAssertEqual(path, "/m/laya-MLX-8bit/typed-decisions")
                nativeBodies.withLock { $0.append(body) }
                let outage = String(data: body, encoding: .utf8)?.contains("500 error") == true
                return DecisionResult(answers: [
                    "department": DecisionAnswer(type: "choice", choice: outage ? "technical" : "billing", probabilities: nil),
                    "urgency": DecisionAnswer(type: "score", choice: nil, probabilities: ["0": 0.1, "1": 0.2, "2": 0.7], score: 1.6),
                    "refund": DecisionAnswer(type: "noul", choice: nil, probabilities: nil, noul: outage ? 0.2 : 0.8),
                ], seconds: 0.06)
            },
            readToken: { _ in nil },
            freshInventory: { host, token in try await SystemOneHostAdapter().inventory(from: HostReader(host: host, token: token, http: http)) },
            hostedDecide: { host, token, model, prompt in
                try await SystemOneHostAdapter.decide(HostReader(host: host, token: token, http: http), model: model,
                                                      state: prompt.text, questions: try XCTUnwrap(prompt.decisionQuestions))
            },
            memoryProbe: { nil })

        try await coordinator.start(targets: [kev, laya], promptSet: routing)
        for _ in 0..<2000 where coordinator.activeRunID != nil { try await Task.sleep(nanoseconds: 5_000_000) }

        let decisions = SystemOneStubProtocol.requests.filter { $0.path == "/v1/systemone" }
        XCTAssertEqual(decisions.map(\.method), ["POST", "POST"])
        let first = try json(try XCTUnwrap(decisions.first?.body))
        XCTAssertEqual(first["model"] as? String, "kev-latest")
        XCTAssertEqual(first["state"] as? String, routing.prompts[0].text)
        let native = nativeBodies.withLock { $0 }
        XCTAssertEqual(native.count, 2)
        XCTAssertEqual(try json(native[0])["questions"] as? NSDictionary, first["questions"] as? NSDictionary,
                       "every lane receives the same questions")

        let record = try XCTUnwrap(try JSONStore<HostedComparisonRecord>(fileURL: storeURL).load().first)
        XCTAssertEqual(record.run.state, .completed)
        XCTAssertEqual(record.run.mode, .classification)
        XCTAssertEqual(record.run.results.map(\.id), [kev.id, laya.id])
        // Kev answers billing and a refund for both tickets: 2 of 2, then 1 of 3 on the outage.
        XCTAssertEqual(try XCTUnwrap(record.run.results[0].aggregateMetric), 0.6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(record.run.results[1].aggregateMetric), 1.0, accuracy: 1e-9)
        XCTAssertEqual(record.run.results[0].samples.map { $0.decision?.grades.map(\.correct) },
                       [[true, nil, true], [false, true, false]])
        XCTAssertEqual(record.run.results[1].samples.first?.seconds, 0.06)
        XCTAssertNotNil(record.run.results[0].samples.first?.seconds)
    }

    func testClassificationDraftNeedsAStateAndValidQuestionsBeforeItSaves() throws {
        var draft = PromptSetDraft(mode: .classification)
        draft.name = "Tickets"
        XCTAssertNotNil(draft.validationError)

        draft.prompts[0].text = "The app crashes on launch."
        draft.prompts[0].questions = [DecisionQuestion(name: "team", kind: .choice, instructions: "Which team?",
                                                       options: [.init(label: "billing"), .init(label: "technical")], expected: "support")]
        XCTAssertEqual(draft.validationError, "Prompt 1: Question team expects an answer that is not one of its options.")

        draft.prompts[0].questions[0].expected = "technical"
        XCTAssertNil(draft.validationError)
        let set = try draft.promptSet()
        XCTAssertEqual(set.mode, .classification)
        XCTAssertEqual(set.prompts[0].text, "The app crashes on launch.")
        XCTAssertEqual(set.prompts[0].decisionQuestions?.first?.expected, "technical")
    }
}
