import CryptoKit
import Foundation
import XCTest
@testable import mlx_workbench

final class ServedTaskTests: XCTestCase {
    func testOriginRejectsMissingIdentityAndChangedProcess() throws {
        let origin = try ServedTaskOrigin(server: Self.server())
        XCTAssertEqual(origin.artifactRoot.path, "/state/.mlx-agent-receipts/tasks/8085")
        XCTAssertTrue(origin.matches(Self.server()))
        XCTAssertFalse(origin.matches(Self.server(pid: 52)))
        XCTAssertFalse(origin.matches(Self.server(key: String(repeating: "a", count: 64))))
        XCTAssertThrowsError(try ServedTaskOrigin(server: ServerInfo(runtime: "tasks", port: 8085, state: "running")))
        XCTAssertThrowsError(try ServedTaskOrigin(server: Self.server(receipt: "/other/8085.json")))
    }

    func testSubmissionUsesBoundEndpointAndPersistsHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try Self.record()
        let transport = Transport(server: Self.server(), record: record)
        let api = fixture.api(transport)
        let request = TaskRequest(kind: .embedding, modelPath: "/Models/embed", parameters: ["input": .array([.string("Hello")])])
        let accepted = try await api.taskStart(request)
        XCTAssertEqual(accepted.id, record.id)
        let body = await transport.lastBody
        XCTAssertEqual(Set(try XCTUnwrap(body).keys), ["kind", "parameters"])
        XCTAssertEqual(body?["kind"]?.stringValue, "embedding")
        let reloaded = ServedTaskStore(url: fixture.url)
        let bindings = try await reloaded.entry(fixture.origin).records
        XCTAssertEqual(bindings.map(\.id), [record.id])
    }

    func testDriftAndMissingKeySendNoSubmission() async throws {
        let fixture = try Fixture(server: Self.server(key: String(repeating: "a", count: 64)))
        defer { fixture.remove() }
        let transport = Transport(server: Self.server(pid: 52), record: try Self.record())
        let api = fixture.api(transport)
        do { _ = try await api.taskStart(Self.request); XCTFail("Changed server accepted a job") } catch {}
        var count = await transport.posts
        XCTAssertEqual(count, 0)
        await transport.setServer(fixture.origin.server)
        let noKey = fixture.api(transport, credential: { _ in throw HostHTTPError.requestFailed })
        do { _ = try await noKey.taskStart(Self.request); XCTFail("Missing key accepted a job") } catch {}
        count = await transport.posts
        XCTAssertEqual(count, 0)
    }

    func testLostResponseBlocksResubmissionAcrossRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = Transport(server: Self.server(), record: try Self.record())
        await transport.failPOST(HostHTTPError.requestFailed)
        do { _ = try await fixture.api(transport).taskStart(Self.request); XCTFail("Expected uncertain outcome") }
        catch { XCTAssertTrue(error is TaskStartOutcomeUnknown) }
        do { _ = try await fixture.api(transport).taskStart(Self.request); XCTFail("Retried an uncertain submission") }
        catch {}
        let count = await transport.posts
        XCTAssertEqual(count, 1)
        let unresolved = try await fixture.store.entry(fixture.origin).submissionUnresolved
        XCTAssertTrue(unresolved)
    }

    func testBusyRefusalRetainsRetryAndCancellationChecksOwnership() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = Transport(server: Self.server(), record: try Self.record())
        let api = fixture.api(transport)
        await transport.failPOST(HostHTTPError.httpStatus(409))
        do { _ = try await api.taskStart(Self.request); XCTFail("Expected busy") } catch { XCTAssertFalse(error is TaskStartOutcomeUnknown) }
        let unresolved = try await fixture.store.entry(fixture.origin).submissionUnresolved
        XCTAssertFalse(unresolved)
        await transport.failPOST(nil)
        let record = try await api.taskStart(Self.request)
        await transport.setServer(Self.server(pid: 52))
        do { _ = try await api.taskCancel(id: record.id); XCTFail("Cancelled on a replacement process") } catch {}
        let count = await transport.posts
        XCTAssertEqual(count, 2)
    }

    func testHistoryRejectsAnotherSupervisorAndKeepsVerifiedJobsOffline() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try Self.record()
        let transport = Transport(server: Self.server(), record: record)
        let api = fixture.api(transport)
        _ = try await api.taskStart(Self.request)
        await transport.setServer(Self.server(pid: 52))
        let page = try await api.taskList(limit: 100)
        XCTAssertEqual(page.tasks.map(\.id), [record.id])
        XCTAssertThrowsError(try fixture.origin.validate(try Self.record(owner: "different process")))
    }

    func testProtectedSubmissionUsesMatchingKeyWithoutPersistingIt() async throws {
        let token = "test-key"
        let hash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        let fixture = try Fixture(server: Self.server(key: hash))
        defer { fixture.remove() }
        let transport = Transport(server: fixture.origin.server, record: try Self.record())
        _ = try await fixture.api(transport).taskStart(Self.request)
        let sent = await transport.lastToken
        XCTAssertEqual(sent, token)
        let saved = try String(contentsOf: fixture.url, encoding: .utf8)
        XCTAssertFalse(saved.contains(token))
        XCTAssertTrue(saved.contains(hash))
    }

    func testScopedStatusUsesOriginalStoreAndRejectsUnknownCancellation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try Self.record()
        try await fixture.store.remember(record, origin: fixture.origin)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        raw["supervisor"] = ["pid": 51] // The CLI intentionally omits process identity.
        let summary = try JSONSerialization.data(withJSONObject: raw)
        let engine = WorkbenchAPI(cli: CLIProcess(), agentPath: "/engine", taskEnvelopeCommand: { _, argv, _ in
            XCTAssertEqual(Array(argv.prefix(2)), ["task", "status"])
            let index = try XCTUnwrap(argv.firstIndex(of: "--state-dir"))
            XCTAssertEqual(argv[index + 1], fixture.origin.artifactRoot.path)
            return ["status": "ok", "data": ["task": try JSONSerialization.jsonObject(with: summary)]]
        })
        let transport = Transport(server: Self.server(pid: 52), record: record)
        let api = ServedTaskAPI(origin: fixture.origin, engine: engine, store: fixture.store,
            client: ServedTaskClient(servers: { _ in [await transport.server] }, credential: { _ in "test-key" },
              request: { _, path, method, body, token in try await transport.request(path, method, body, token) }))
        let read = try await api.taskStatus(id: record.id)
        XCTAssertEqual(read.supervisor, record.supervisor)
        do { _ = try await api.taskCancel(id: "22222222-2222-4222-8222-222222222222"); XCTFail("Unknown job cancelled") } catch {}
        let count = await transport.posts
        XCTAssertEqual(count, 0)
    }

    func testDiscoveryVerifiesProcessBeforeSavingOriginAndCancelUsesHTTP() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try Self.record()
        let alien = Transport(server: Self.server(), record: try Self.record(owner: "another process"))
        let rejected = try await fixture.api(alien, listing: [record]).taskList(limit: 100)
        XCTAssertTrue(rejected.tasks.isEmpty)
        let transport = Transport(server: Self.server(), record: record)
        let api = fixture.api(transport, listing: [record])
        let discovered = try await api.taskList(limit: 100)
        XCTAssertEqual(discovered.tasks.map(\.id), [record.id])
        _ = try await api.taskCancel(id: record.id)
        let body = await transport.lastBody
        let posts = await transport.posts
        XCTAssertEqual(body, [:])
        XCTAssertEqual(posts, 1)
    }

    func testLateResponseCannotResolveANewerSubmission() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.store.begin(fixture.origin)
        try await fixture.store.resolve(fixture.origin)
        _ = try await fixture.store.begin(fixture.origin)
        try await fixture.store.remember(Self.record(), origin: fixture.origin, resolvingSubmission: first)
        let unresolved = try await fixture.store.entry(fixture.origin).submissionUnresolved
        XCTAssertTrue(unresolved)
    }

    static var request: TaskRequest { TaskRequest(kind: .embedding, modelPath: "/Models/embed", parameters: ["input": .array([.string("Hello")])]) }
    static func server(pid: Int = 51, key: String? = nil, receipt: String = "/state/.mlx-agent-receipts/serve/8085.json") -> ServerInfo {
        ServerInfo(path: "/Models/embed", runtime: "tasks", port: 8085, pid: pid, state: "running", startedAt: "2026-11-10T12:00:00+00:00", receipt: receipt,
                   receiptsDirectory: "/state", processStartedAt: "Tue Nov 10 07:00:00 2026", taskKinds: ["embedding"], apiKeySHA256: key)
    }
    static func record(owner: String = "Tue Nov 10 07:00:00 2026 python task_serve.py") throws -> TaskRecord {
        let object: [String: Any] = ["schema": "task-run/2", "id": "11111111-1111-4111-8111-111111111111", "kind": "embedding", "state": "running", "model_path": "/Models/embed", "created_at": "2026-11-10T12:01:00+00:00", "cancel_requested": false,
            "identity": ["backend": "mlx-embeddings"], "request": ["path": "/state/.mlx-agent-receipts/tasks/8085/artifacts/11111111-1111-4111-8111-111111111111/request.json", "sha256": String(repeating: "a", count: 64), "bytes": 10],
            "supervisor": ["pid": 51, "identity": owner], "execution_unresolved": false]
        return try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }

    struct Fixture {
        let url: URL
        let origin: ServedTaskOrigin
        let store: ServedTaskStore
        init(server: ServerInfo = ServedTaskTests.server()) throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("served-jobs-\(UUID().uuidString)/origins.json")
            origin = try ServedTaskOrigin(server: server)
            store = ServedTaskStore(url: url)
        }
        func remove() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func api(_ transport: Transport, listing: [TaskRecord] = [], credential: @escaping @Sendable (String) async throws -> String = { _ in "test-key" }) -> ServedTaskAPI {
            let listed = try! JSONEncoder().encode(listing)
            let status = try! JSONEncoder().encode(ServedTaskTests.record())
            let engine = WorkbenchAPI(cli: CLIProcess(), agentPath: "/engine", taskEnvelopeCommand: { _, argv, _ in
                if argv.contains("list") { return ["status": "ok", "data": ["tasks": try JSONSerialization.jsonObject(with: listed), "has_more": false]] }
                if argv.contains("status") { return ["status": "ok", "data": ["task": try JSONSerialization.jsonObject(with: status)]] }
                throw HostHTTPError.requestFailed
            })
            return ServedTaskAPI(origin: origin, engine: engine, store: store,
                                 client: ServedTaskClient(servers: { _ in [await transport.server] }, credential: credential,
                                   request: { _, path, method, body, token in try await transport.request(path, method, body, token) }))
        }
    }

    actor Transport {
        var server: ServerInfo
        let record: TaskRecord
        var posts = 0
        var lastBody: [String: JSONValue]?
        var lastToken: String?
        var failure: HostHTTPError?
        init(server: ServerInfo, record: TaskRecord) { self.server = server; self.record = record }
        func setServer(_ value: ServerInfo) { server = value }
        func failPOST(_ error: HostHTTPError?) { failure = error }
        func request(_ path: String, _ method: String, _ body: Data?, _ token: String?) throws -> Data {
            lastToken = token
            if method == "POST" {
                posts += 1
                lastBody = try body.map { try JSONDecoder().decode([String: JSONValue].self, from: $0) }
                if let failure { throw failure }
                return try JSONEncoder().encode(record)
            }
            if path == "/v1/models" {
                return try JSONSerialization.data(withJSONObject: ["data": [["id": server.modelIdentity, "api": "/v1/tasks", "task_kinds": ["embedding"]]]])
            }
            return try JSONEncoder().encode(record)
        }
    }
}
