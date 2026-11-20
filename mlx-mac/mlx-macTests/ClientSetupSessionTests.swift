import XCTest
import CryptoKit
import TOMLKit
import Yams
@testable import mlx_workbench

@MainActor
final class ClientSetupSessionTests: XCTestCase {
    private let endpoint = WireEndpoint(baseURL: "http://127.0.0.1:8766/v1", modelName: "org/model")
    private let key = "connection-test-private-key-0123456789"

    func testNativeFormatsPreserveUnrelatedSettingsAndSelectModel() throws {
        let claw = try AgentClientAdapters.openclaw.plan("{ agents: {defaults: {model: {primary:'cloud/old', fallbacks:['cloud/backup']}}}, tools: {profile:'coding'}, }", endpoint)
        let clawRoot = try JSONCTolerant.parse(claw)
        XCTAssertEqual((clawRoot["tools"] as? [String: String])?["profile"], "coding")
        let defaults = ((clawRoot["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["model"] as? [String: Any]
        XCTAssertEqual(defaults?["fallbacks"] as? [String], ["cloud/backup"])
        XCTAssertEqual(defaults?["primary"] as? String, "workbench/org/model")

        let hermes = try AgentClientAdapters.hermes.plan("model:\n  provider: cloud\n  key_cmd: secret-command\n  temperature: 0.3\ntoolsets:\n  - terminal\n", endpoint)
        let hermesRoot = try XCTUnwrap(try Yams.load(yaml: hermes) as? [String: Any])
        XCTAssertEqual(hermesRoot["toolsets"] as? [String], ["terminal"])
        let model = try XCTUnwrap(hermesRoot["model"] as? [String: Any])
        XCTAssertEqual(model["temperature"] as? Double, 0.3)
        XCTAssertNil(model["key_cmd"])

        let codex = try AgentClientAdapters.codex.plan("""
        profile = "coding"
        sandbox_mode = "workspace-write"
        custom_date = 2026-11-11T12:00:00Z
        custom_integer = 9223372036854775807
        [profiles.coding]
        model = "old"
        approval_policy = "on-request"
        [model_providers.workbench]
        env_key = "OLD_KEY"
        """, endpoint)
        let toml = try TOMLTable(string: codex)
        XCTAssertEqual(toml["sandbox_mode"]?.string, "workspace-write")
        XCTAssertEqual(toml["custom_integer"]?.int, Int.max)
        XCTAssertNotNil(toml["custom_date"])
        XCTAssertEqual(toml["profiles"]?.table?["coding"]?.table?["approval_policy"]?.string, "on-request")
        XCTAssertEqual(toml["profiles"]?.table?["coding"]?.table?["model"]?.string, endpoint.modelName)
        XCTAssertNil(toml["model_providers"]?.table?["workbench"]?.table?["env_key"])

        let claude = try AgentClientAdapters.claude.plan("{\"permissions\":{\"allow\":[\"Read\"]},\"env\":{\"MY_FLAG\":\"yes\",\"ANTHROPIC_API_KEY\":\"old-secret\"}}", endpoint)
        let claudeRoot = try JSONCTolerant.parse(claude)
        XCTAssertNotNil(claudeRoot["permissions"])
        let env = try XCTUnwrap(claudeRoot["env"] as? [String: String])
        XCTAssertEqual(env["MY_FLAG"], "yes")
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "")
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "http://127.0.0.1:8766")
    }

    func testAllFiveClientsReceiveReviewedCredentialsAndOwnerOnlyFiles() async throws {
        for client in ServingClient.allCases {
            let home = try temporaryHome()
            let server = server(protected: true)
            let wiring = coordinator(home)
            let session = ClientSetupSession(wiring: wiring, client: client, servers: { [server] }, detect: { _ in false })
            await session.load(); await session.preview()
            XCTAssertEqual(session.stage, .review, session.error ?? client.rawValue)
            let plan = try XCTUnwrap(session.plan)
            XCTAssertTrue(plan.after.contains(key))
            XCTAssertFalse(plan.redactedDiff.contains { $0.text.contains(key) })
            await session.apply()
            XCTAssertEqual(session.stage, .saved, session.error ?? client.rawValue)
            let receipt = try XCTUnwrap(session.receipt)
            let matches = await wiring.matchesAppliedConfig(receipt, endpoint: try XCTUnwrap(WireEndpoint(server: server)))
            XCTAssertTrue(matches)
            let permissions = try FileManager.default.attributesOfItem(atPath: receipt.configPath)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
            XCTAssertEqual(wiring.transactions.first?.receipts.count, 1)
        }
    }

    func testWrittenConfigAndServerDriftBlockConnectionTest() async throws {
        let home = try temporaryHome()
        var servers = [server()]
        var calls = 0
        let wiring = coordinator(home)
        let session = ClientSetupSession(wiring: wiring, servers: { servers }, test: { _, _, _ in
            calls += 1; return ClientConnectionResult(protocolName: "Chat Completions", answer: "CONNECTED")
        }, detect: { _ in true })
        await session.load(); await session.preview(); await session.apply()
        let receipt = try XCTUnwrap(session.receipt)
        try "{}".write(toFile: receipt.configPath, atomically: true, encoding: .utf8)
        await session.test()
        XCTAssertEqual(calls, 0); XCTAssertNil(session.result)
        XCTAssertTrue(session.error?.contains("configuration changed") == true)
        session.back(); await session.preview(); await session.apply()
        servers = [ServerInfo(repo: "org/model", runtime: "mlx_lm", port: 8766, pid: 999, state: "running", jit: true)]
        await session.test()
        XCTAssertEqual(calls, 0); XCTAssertNil(session.result)
        XCTAssertTrue(session.error?.contains("changed or stopped") == true)
    }

    func testUnprotectedSetupCanTestWithoutAKeyAndRetryAFailure() async throws {
        let home = try temporaryHome(), wiring = coordinator(home), server = server()
        var attempts = 0
        let session = ClientSetupSession(wiring: wiring, servers: { [server] }, test: { _, _, key in
            XCTAssertNil(key)
            attempts += 1
            if attempts == 1 { throw HostHTTPError.httpStatus(503) }
            return ClientConnectionResult(protocolName: "Chat Completions", answer: "CONNECTED")
        }, detect: { _ in true })
        await session.load(); await session.preview(); await session.apply(); await session.test()
        XCTAssertNil(session.result); XCTAssertTrue(session.error?.contains("503") == true)
        await session.test()
        XCTAssertEqual(attempts, 2); XCTAssertNil(session.error)
        XCTAssertEqual(session.result?.answer, "CONNECTED")
    }

    func testUndoTargetsItsOwnTransaction() async throws {
        let home = try temporaryHome(), wiring = coordinator(home), server = server()
        let first = ClientSetupSession(wiring: wiring, client: .opencode, servers: { [server] }, detect: { _ in true })
        let second = ClientSetupSession(wiring: wiring, client: .hermes, servers: { [server] }, detect: { _ in true })
        await first.load(); await first.preview(); await first.apply()
        await second.load(); await second.preview(); await second.apply()
        let secondPath = try XCTUnwrap(second.receipt?.configPath)
        first.undo()
        XCTAssertNil(first.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondPath))
        XCTAssertTrue(second.canUndo)
        let secondBytes = try Data(contentsOf: URL(fileURLWithPath: secondPath))
        wiring.rollback(transactionID: UUID())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: secondPath)), secondBytes)
    }

    func testOpenCodeSetupThroughTheFrontDoorWritesEveryRoutedModel() async throws {
        let home = try temporaryHome(), wiring = coordinator(home)
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        var door: WireEndpoint? = WireEndpoint(baseURL: "http://127.0.0.1:8939/v1", modelName: "gemma-3",
                                               apiKeySHA256: digest, models: ["gemma-3", "org/coder"])
        var tested: [String] = []
        let session = ClientSetupSession(wiring: wiring, client: .opencode, prefersFrontDoor: true, servers: { [] },
            frontDoor: { door }, testFrontDoor: { [key] _, endpoint, token in
                tested.append("\(endpoint.baseURL) \(token == key)")
                return ClientConnectionResult(protocolName: "Chat Completions", answer: "CONNECTED")
            }, detect: { _ in true })
        await session.load()
        XCTAssertEqual(session.selectedFrontDoor, door)
        await session.preview()
        XCTAssertEqual(session.stage, .review, session.error ?? "")
        await session.apply()
        XCTAssertEqual(session.stage, .saved, session.error ?? "")
        let receipt = try XCTUnwrap(session.receipt)
        let config = try JSONCTolerant.parse(String(contentsOfFile: receipt.configPath, encoding: .utf8))
        let local = try XCTUnwrap((config["provider"] as? [String: Any])?["mlx-local"] as? [String: Any])
        XCTAssertEqual((local["models"] as? [String: Any])?.keys.sorted(), ["gemma-3", "org/coder"])
        XCTAssertEqual((local["options"] as? [String: Any])?["apiKey"] as? String, key)
        XCTAssertEqual(config["model"] as? String, "mlx-local/gemma-3")
        await session.test()
        XCTAssertEqual(session.result?.answer, "CONNECTED", session.error ?? "")
        XCTAssertEqual(tested, ["http://127.0.0.1:8939/v1 true"])

        session.back(); await session.preview()
        XCTAssertEqual(session.stage, .review, session.error ?? "")
        door = WireEndpoint(baseURL: "http://127.0.0.1:8939/v1", modelName: "gemma-3", apiKeySHA256: digest, models: ["gemma-3"])
        await session.apply()
        XCTAssertEqual(session.stage, .review)
        XCTAssertTrue(session.error?.contains("stopped or changed") == true, session.error ?? "")
    }

    func testTOMLAndYAMLMultilineSecretsAreMasked() {
        let source = "experimental_bearer_token = \"\"\"\nprivate-first\nprivate-second\n\"\"\"\napi_key: |\n  another-private-key\nmodel: safe"
        let redacted = SecretRedaction.redact(source)
        XCTAssertFalse(redacted.contains("private-first"))
        XCTAssertFalse(redacted.contains("private-second"))
        XCTAssertFalse(redacted.contains("another-private-key"))
        XCTAssertTrue(redacted.contains("model: safe"))
    }

    func testCaviClientExercisesAllThreeProtocolsWithCredentials() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientConnectionStub.self]
        let transport = HostHTTPClient(session: URLSession(configuration: configuration))
        for client in ServingClient.allCases {
            let result = try await ClientConnectionTest.run(client: client, server: server(protected: true), token: key, http: transport)
            XCTAssertEqual(result.answer, "CONNECTED")
        }
    }

    func testOpenCodeToolCallCheckPreservesConnectionResult() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientConnectionStub.self]
        let transport = HostHTTPClient(session: URLSession(configuration: configuration))
        let unsupported = try await ClientConnectionTest.run(client: .opencode, endpoint: endpoint, token: key, http: transport)
        XCTAssertEqual(unsupported.answer, "CONNECTED")
        XCTAssertEqual(unsupported.toolCall, .notVerified)
        let supportedEndpoint = WireEndpoint(baseURL: endpoint.baseURL, modelName: "tool-supported")
        let supported = try await ClientConnectionTest.run(client: .opencode, endpoint: supportedEndpoint, token: key, http: transport)
        XCTAssertEqual(supported.answer, "CONNECTED")
        XCTAssertEqual(supported.toolCall, .passed)
        let other = try await ClientConnectionTest.run(client: .hermes, endpoint: endpoint, token: key, http: transport)
        XCTAssertEqual(other.answer, "CONNECTED")
        XCTAssertNil(other.toolCall)
    }

    func testCaviBridgeDeadlineCancelsHeldResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldClientConnectionStub.self]
        let transport = HostHTTPClient(session: URLSession(configuration: configuration))
        let finished = expectation(description: "bridge deadline")
        let started = Date()
        let task = Task {
            defer { finished.fulfill() }
            do {
                _ = try await CaviConnectionClient.request(baseURL: "http://127.0.0.1:8766", path: "v1/chat/completions",
                    body: Data("{}".utf8), token: nil, http: transport, timeout: 1)
                XCTFail("Held response must expire")
            } catch {
                XCTAssertEqual(error as? HostHTTPError, .invalidResponse)
                XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.8)
            }
        }
        await fulfillment(of: [finished], timeout: 4)
        task.cancel()
    }

    private func server(protected: Bool = false) -> ServerInfo {
        ServerInfo(repo: "org/model", runtime: "mlx_lm", port: 8766, pid: 123, state: "running", jit: true,
                   apiKeySHA256: protected ? SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() : nil)
    }
    private func temporaryHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func coordinator(_ home: URL) -> WiringCoordinator {
        WiringCoordinator(home: home, store: JSONStore(fileURL: home.appendingPathComponent("transactions.json")),
                          credential: { [key] _ in key }, moveToTrash: { try FileManager.default.removeItem(at: $0) })
    }
}

private final class ClientConnectionStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer connection-test-private-key-0123456789"
        let versionOK = path != "/v1/messages" || request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01"
        let body: [String: Any]
        switch path {
        case "/v1/responses": body = ["status": "completed", "output": [["content": [["text": "CONNECTED"]]]]]
        case "/v1/messages": body = ["type": "message", "content": [["type": "text", "text": "CONNECTED"]]]
        case "/v1/chat/completions":
            let data: Data
            if let bytes = request.httpBody { data = bytes }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                data = bytes
            } else { data = Data() }
            let requestBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let includesTools = requestBody?["tools"] != nil
            XCTAssertEqual(request.timeoutInterval, includesTools ? 10 : 120)
            if requestBody?["model"] as? String == "tool-supported", includesTools {
                body = ["choices": [["message": ["tool_calls": [["id": "call-1", "type": "function", "function": ["name": "workbench_tool_check", "arguments": "{}"]]]]]]]
            } else { body = ["choices": [["message": ["content": "CONNECTED"]]]] }
        default: body = ["error": "incorrect path"]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: authorized && versionOK ? 200 : 401,
                                                           httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class HeldClientConnectionStub: URLProtocol {
    private var timer: DispatchSourceTimer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "held-client-response"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didLoad: Data(" ".utf8))
        }
        self.timer = timer
        timer.resume()
    }
    override func stopLoading() { timer?.cancel(); timer = nil }
}
