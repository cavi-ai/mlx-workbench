import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

// MARK: - Fixtures

private enum ClientsFixtures {
    static let local = WireEndpoint(baseURL: "http://127.0.0.1:8766/v1", modelName: "org/name")
    static let absolute = WireEndpoint(baseURL: "http://127.0.0.1:8766/v1", modelName: "/Users/someone/Models/Qwen-4bit")

    static func entry(_ endpoint: WireEndpoint) -> ClientConfigEntry {
        ClientConfigEntry(baseURL: endpoint.baseURL, models: [endpoint.modelName])
    }

    static func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-clients-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ text: String, _ relative: String, in home: URL) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func makeDirectory(_ relative: String, in home: URL) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    static func server(_ path: String, port: Int, pid: Int = 1, state: String = "running", jit: Bool? = nil, modelState: String? = nil) -> ServerInfo {
        ServerInfo(path: path, runtime: "mlx_lm", port: port, pid: pid, state: state, jit: jit, modelState: modelState)
    }

    static func installation(_ id: String, name: String, path: String?, advisory: Bool = false) -> ClientInstallation {
        ClientInstallation(clientID: id, displayName: name, configPath: path, advisoryOnly: advisory,
            advisoryNote: advisory ? "\(name) owns its model state." : nil)
    }

    static func status(_ reading: ClientConfigReading, linked: Bool = false) -> ClientConfigStatus {
        ClientConfigStatus(reading: reading, isLinked: linked)
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.lock(); defer { lock.unlock() }; return value }

    @discardableResult
    func hit() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

private actor ReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - Manual wiring review

@MainActor
final class ManualWiringSessionTests: XCTestCase {
    private let original = ManualWiringDraft(model: " org/model ", path: " /configs/client.json ", target: " mlx_lm ")
    private let reviewed = ManualWiringRequest(model: "org/model", path: "/configs/client.json", target: "mlx_lm")

    private func wire(hash: String? = "reviewed-hash", applied: Bool? = nil) -> WireResult {
        WireResult(preview_hash: hash, config: ["model": "org/model"], applied: applied)
    }

    func testMissingInputsNeverLaunchAnOperation() {
        let session = ManualWiringSession(preview: { _ in XCTFail("Invalid draft previewed"); return self.wire() },
            apply: { _, _ in XCTFail("Missing review applied"); return self.wire(applied: true) })
        XCTAssertFalse(session.canPreview)
        XCTAssertNil(session.previewWiring())
        XCTAssertNil(session.confirmWiring())
        for field in [\ManualWiringDraft.model, \.path, \.target] {
            session.draft = original
            session.draft[keyPath: field] = " \n "
            XCTAssertFalse(session.canPreview)
            XCTAssertNil(session.previewWiring())
            XCTAssertNil(session.confirmWiring())
            XCTAssertFalse(session.isBusy)
        }
    }

    func testCapturedReviewAndEveryEditedInputInvalidateConfirmation() async {
        var requests: [ManualWiringRequest] = []
        let session = ManualWiringSession(preview: { requests.append($0); return self.wire() },
            apply: { _, _ in XCTFail("Edited review applied"); return self.wire(applied: true) })
        for field in [\ManualWiringDraft.model, \.path, \.target] {
            session.draft = original
            await session.previewWiring()?.value
            XCTAssertEqual(session.preview?.request, reviewed)
            XCTAssertEqual(session.preview?.hash, "reviewed-hash")
            XCTAssertEqual(session.preview?.payload?["model"] as? String, "org/model")
            XCTAssertTrue(session.canConfirm)
            session.draft[keyPath: field] += "changed"
            XCTAssertNil(session.preview)
            XCTAssertFalse(session.canConfirm)
            XCTAssertNil(session.confirmWiring())
            XCTAssertEqual(session.guidance, "Inputs changed. Preview again before confirming.")
            session.draft = original
            XCTAssertFalse(session.canConfirm, "Returning to old input must not restore authority")
        }
        XCTAssertEqual(requests, [reviewed, reviewed, reviewed])
    }

    func testDelayedPreviewCannotReviveAfterEachInputIsEditedAndReverted() async {
        for field in [\ManualWiringDraft.model, \.path, \.target] {
            var continuation: CheckedContinuation<WireResult, Never>?
            let started = expectation(description: "preview started")
            var calls = 0
            let session = ManualWiringSession(preview: { request in
                XCTAssertEqual(request, self.reviewed)
                calls += 1
                return await withCheckedContinuation { continuation = $0; started.fulfill() }
            }, apply: { _, _ in XCTFail("Obsolete preview applied"); return self.wire(applied: true) })
            session.draft = original
            let task = session.previewWiring()
            XCTAssertEqual(session.operation, .previewing)
            XCTAssertNil(session.previewWiring())
            XCTAssertNil(session.confirmWiring())
            await fulfillment(of: [started], timeout: 2)
            session.draft[keyPath: field] += "changed"
            session.draft = original
            continuation?.resume(returning: wire())
            await task?.value
            XCTAssertEqual(calls, 1)
            XCTAssertNil(session.preview)
            XCTAssertFalse(session.canConfirm)
            XCTAssertTrue(session.canPreview)
            XCTAssertNil(session.errorMessage)
            XCTAssertEqual(session.guidance, "Inputs changed. Preview again before confirming.")
        }
    }

    func testMissingEmptyAndWhitespaceHashesCannotAuthorizeApply() async {
        let hashes: [String?] = [nil, "", " \n "]
        for hash in hashes {
            let session = ManualWiringSession(preview: { _ in self.wire(hash: hash) },
                apply: { _, _ in XCTFail("Missing hash applied"); return self.wire(applied: true) })
            session.draft = original
            await session.previewWiring()?.value
            XCTAssertNil(session.preview)
            XCTAssertFalse(session.canConfirm)
            XCTAssertNil(session.confirmWiring())
            XCTAssertTrue(session.canPreview)
            XCTAssertEqual(session.errorMessage, "Wiring preview did not include a confirmation hash. Preview again before confirming.")
            XCTAssertNil(session.notice)
        }
    }

    func testApplyLocksSynchronouslyUsesCapturedArgumentsAndConsumesReview() async {
        var continuation: CheckedContinuation<WireResult, Never>?
        let started = expectation(description: "apply started")
        var calls: [(ManualWiringRequest, String)] = []
        let session = ManualWiringSession(preview: { _ in self.wire() }, apply: { request, hash in
            calls.append((request, hash))
            return await withCheckedContinuation { continuation = $0; started.fulfill() }
        })
        session.draft = original
        await session.previewWiring()?.value
        let task = session.confirmWiring()
        XCTAssertEqual(session.operation, .applying)
        XCTAssertNil(session.preview)
        XCTAssertNil(session.confirmWiring())
        XCTAssertNil(session.previewWiring())
        session.draft = ManualWiringDraft(model: "other/model", path: "/other.json", target: "ollama")
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, reviewed)
        XCTAssertEqual(calls.first?.1, "reviewed-hash")
        continuation?.resume(returning: wire(applied: true))
        await task?.value
        XCTAssertFalse(session.isBusy)
        XCTAssertFalse(session.canConfirm)
        XCTAssertNil(session.confirmWiring())
        XCTAssertEqual(session.notice, "Wiring applied.")
        XCTAssertNil(session.errorMessage)
    }

    func testFalseAndUnconfirmedApplyResultsRequireFreshPreviewAndCanRecover() async {
        let outcomes: [(Bool?, String)] = [
            (false, "Wiring was not applied. Review the config file and preview again before confirming."),
            (nil, "Wiring application was not confirmed. Check the config file, then preview again before confirming."),
        ]
        for (applied, message) in outcomes {
            var calls = 0
            let session = ManualWiringSession(preview: { _ in self.wire() }, apply: { _, _ in
                calls += 1
                return self.wire(applied: calls == 1 ? applied : true)
            })
            session.draft = original
            await session.previewWiring()?.value
            await session.confirmWiring()?.value
            XCTAssertEqual(session.errorMessage, message)
            XCTAssertNil(session.notice)
            XCTAssertNil(session.preview)
            XCTAssertNil(session.confirmWiring())
            XCTAssertTrue(session.canPreview)
            await session.previewWiring()?.value
            XCTAssertNil(session.errorMessage)
            XCTAssertTrue(session.canConfirm)
            await session.confirmWiring()?.value
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(session.notice, "Wiring applied.")
            XCTAssertNil(session.errorMessage)
        }
    }

    func testPreviewAndApplyErrorsOfferRecoveryWithoutReusingAuthority() async {
        struct Rejected: LocalizedError { var errorDescription: String? { "config changed" } }
        var previews = 0
        var applies = 0
        let session = ManualWiringSession(preview: { _ in
            previews += 1
            if previews == 1 { throw Rejected() }
            return self.wire()
        }, apply: { _, _ in
            applies += 1
            if applies == 1 { throw Rejected() }
            return self.wire(applied: true)
        })
        session.draft = original
        await session.previewWiring()?.value
        XCTAssertEqual(session.errorMessage, "Wiring preview failed: config changed Preview again before confirming.")
        XCTAssertNil(session.confirmWiring())
        XCTAssertTrue(session.canPreview)
        await session.previewWiring()?.value
        await session.confirmWiring()?.value
        XCTAssertEqual(session.errorMessage, "Wiring failed: config changed Check the config file, then preview again before confirming.")
        XCTAssertNil(session.notice)
        XCTAssertNil(session.confirmWiring())
        XCTAssertTrue(session.canPreview)
        await session.previewWiring()?.value
        await session.confirmWiring()?.value
        XCTAssertEqual(session.notice, "Wiring applied.")
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(previews, 3)
        XCTAssertEqual(applies, 2)
    }

    func testDelayedPreviewErrorDoesNotReplaceEditedDraftGuidance() async {
        struct Rejected: LocalizedError { var errorDescription: String? { "obsolete failure" } }
        var continuation: CheckedContinuation<WireResult, Error>?
        let started = expectation(description: "preview started")
        let session = ManualWiringSession(preview: { _ in
            try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() }
        }, apply: { _, _ in XCTFail("No review applied"); return self.wire(applied: true) })
        session.draft = original
        let task = session.previewWiring()
        await fulfillment(of: [started], timeout: 2)
        session.draft.model += "changed"
        session.draft = original
        continuation?.resume(throwing: Rejected())
        await task?.value
        XCTAssertNil(session.preview)
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(session.guidance, "Inputs changed. Preview again before confirming.")
        XCTAssertTrue(session.canPreview)
    }

    func testManualWiringSubprocessUsesOnlyTheCapturedRequestOnce() async throws {
        let root = try ClientsFixtures.makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("client config.json")
        let record = root.appendingPathComponent("argv.jsonl")
        try "original config".write(to: config, atomically: true, encoding: .utf8)
        let script = """
        import json
        import sys

        args = sys.argv[1:]
        expected = ["wire", "apply", "org/reviewed-model", "--path", \(String(reflecting: config.path)), "--target", "ollama"]
        confirmed = "--confirm" in args
        assert args == expected + (["--confirm", "--preview-hash", "fixture-hash"] if confirmed else []) + ["--json"]
        with open(\(String(reflecting: record.path)), "a") as record:
            record.write(json.dumps(args) + "\\n")
        data = {"preview": {"preview_hash": "fixture-hash", "config": {"model": "org/reviewed-model"}}}
        if confirmed:
            with open(\(String(reflecting: config.path))) as config:
                assert config.read() == "original config"
            with open(\(String(reflecting: config.path)), "w") as config:
                config.write("applied fixture config")
            data["applied"] = True
        print(json.dumps({"status": "ok", "data": data}))
        """
        try ClientsFixtures.write(script, "scripts/mlx-agent", in: root)
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: root.path)
        let session = ManualWiringSession(preview: { request in
            try await api.wirePreview(model: request.model, path: request.path, target: request.target)
        }, apply: { request, hash in
            try await api.wireApply(model: request.model, path: request.path, previewHash: hash, target: request.target)
        })
        session.draft = ManualWiringDraft(model: "org/reviewed-model", path: config.path, target: "ollama")
        let preview = session.previewWiring()
        XCTAssertNil(session.previewWiring())
        XCTAssertNil(session.confirmWiring())
        await preview?.value
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "original config")
        XCTAssertTrue(session.canConfirm, session.errorMessage ?? "preview absent")
        let apply = session.confirmWiring()
        XCTAssertNil(session.confirmWiring())
        XCTAssertNil(session.previewWiring())
        session.draft = ManualWiringDraft(model: "org/edited-model", path: "/unused.json", target: "mlx_lm")
        await apply?.value
        XCTAssertEqual(session.notice, "Wiring applied.")
        XCTAssertNil(session.confirmWiring())
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "applied fixture config")
        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n")
        let arguments = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String]) }
        let expected = ["wire", "apply", "org/reviewed-model", "--path", config.path, "--target", "ollama"]
        XCTAssertEqual(arguments, [
            expected + ["--json"],
            expected + ["--confirm", "--preview-hash", "fixture-hash", "--json"],
        ])
    }
}

// MARK: - Reader (AC1)

final class ClientsReaderTests: XCTestCase {
    private typealias F = ClientsFixtures

    private let writable: [(name: String, adapter: ClientAdapter)] = [
        ("opencode", ClientAdapters.opencode), ("continue", ClientAdapters.continue_),
        ("zed", ClientAdapters.zed), ("aider", ClientAdapters.aider),
    ]

    private func befores(for id: String) -> [String?] {
        switch id {
        case "aider":
            return [nil, "", "# keep\nmodel: gpt-4\n", "other: 1\n",
                    "openai-api-base: \"http://127.0.0.1:9000/v1\"  # old\nmodel: 'openai/old'\n"]
        case "opencode":
            return [nil, "", "{\n  // comment\n  \"theme\": \"dark\",\n}\n", "{\"unrelated\": 1}",
                    "{\"provider\":{\"mlx-local\":{\"options\":{\"baseURL\":\"http://127.0.0.1:9000/v1\"},\"models\":{\"old\":{}}}},\"model\":\"mlx-local/old\"}"]
        case "continue":
            return [nil, "", "{\n  // comment\n  \"models\": [],\n}\n", "{\"unrelated\": 1}",
                    "{\"models\":[{\"title\":\"old\",\"provider\":\"openai\",\"model\":\"old\",\"apiBase\":\"http://127.0.0.1:9000/v1\"}]}"]
        default:
            return [nil, "", "{\n  // comment\n  \"theme\": \"dark\",\n}\n", "{\"unrelated\": 1}",
                    "{\"language_models\":{\"openai\":{\"api_url\":\"http://127.0.0.1:9000/v1\",\"available_models\":[{\"name\":\"old\"}]}}}"]
        }
    }

    func testReadingInvertsPlanForEveryAdapterBeforeAndIdentity() throws {
        for (name, adapter) in writable {
            for before in befores(for: name) {
                for endpoint in [F.local, F.absolute] {
                    let after = try adapter.plan(before, endpoint)
                    guard case .entries(let entries) = adapter.read(after) else {
                        return XCTFail("\(name) did not read back its own plan for \(String(describing: before))")
                    }
                    // Continue accumulates entries on other ports; the planned entry is the last one.
                    XCTAssertEqual(entries.last, F.entry(endpoint), "\(name) \(String(describing: before))")
                    if name != "continue" { XCTAssertEqual(entries, [F.entry(endpoint)], "\(name) \(String(describing: before))") }
                }
            }
        }
    }

    func testAdvisoryAdaptersReadNothing() {
        for adapter in [ClientAdapters.lmStudio, ClientAdapters.ollama] {
            XCTAssertEqual(adapter.read("{\"provider\":{}}"), .noWorkbenchEntry)
        }
    }

    func testContinueReadsEveryOpenAIEntryOnEveryPort() {
        let config = """
        {"models":[
          {"title":"a","provider":"openai","model":"org/a","apiBase":"http://127.0.0.1:8766/v1"},
          {"title":"b","provider":"openai","model":"org/b","apiBase":"http://localhost:8767/v1/"},
          {"title":"c","provider":"openai","model":"org/c2","apiBase":"http://127.0.0.1:8766/v1"},
          {"title":"d","provider":"anthropic","model":"claude","apiBase":"http://127.0.0.1:8768/v1"},
          {"title":"e","provider":"openai","model":"org/e","apiBase":"https://127.0.0.1:8769/v1"}
        ]}
        """
        XCTAssertEqual(ClientAdapters.continue_.read(config), .entries([
            ClientConfigEntry(baseURL: "http://127.0.0.1:8766/v1", models: ["org/a", "org/c2"]),
            ClientConfigEntry(baseURL: "http://localhost:8767/v1/", models: ["org/b"]),
        ]))
    }

    func testZedReadsEveryAvailableModel() {
        let config = """
        {"language_models":{"openai":{"api_url":"http://127.0.0.1:8766/v1","available_models":[{"name":"a","max_tokens":1},{"name":"b"},{"display_name":"no name"}]}}}
        """
        XCTAssertEqual(ClientAdapters.zed.read(config), .entries([ClientConfigEntry(baseURL: "http://127.0.0.1:8766/v1", models: ["a", "b"])]))
    }

    func testAiderReadsQuotedCommentedValuesAndFlagsNonOpenAIModels() {
        let live = "# aider\nopenai-api-base: \"http://127.0.0.1:8766/v1\"   # local\nmodel: openai/org/name # default\ndark-mode: true\n"
        XCTAssertEqual(ClientAdapters.aider.read(live), .entries([ClientConfigEntry(baseURL: "http://127.0.0.1:8766/v1", models: ["org/name"])]))
        let other = "openai-api-base: 'http://127.0.0.1:8766/v1'\nmodel: gpt-4o\n"
        XCTAssertEqual(ClientAdapters.aider.read(other), .notDefault([ClientConfigEntry(baseURL: "http://127.0.0.1:8766/v1", models: [])]))
        XCTAssertEqual(ClientAdapters.aider.read("openai-api-base: http://127.0.0.1:8766/v1\n"),
            .entries([ClientConfigEntry(baseURL: "http://127.0.0.1:8766/v1", models: [])]))
        XCTAssertEqual(ClientAdapters.aider.read("model: openai/org/name\n"), .noWorkbenchEntry)
    }

    func testOpencodeFlagsADefaultModelOnAnotherProvider() {
        let config = """
        {"provider":{"mlx-local":{"options":{"baseURL":"http://127.0.0.1:8766/v1"},"models":{"b":{},"a":{}}}},"model":"anthropic/claude"}
        """
        XCTAssertEqual(ClientAdapters.opencode.read(config),
            .notDefault([ClientConfigEntry(baseURL: "http://127.0.0.1:8766/v1", models: ["a", "b"])]))
        let noDefault = """
        {"provider":{"mlx-local":{"options":{"baseURL":"http://127.0.0.1:8766/v1"},"models":{"a":{}}}}}
        """
        XCTAssertEqual(ClientAdapters.opencode.read(noDefault), .entries([ClientConfigEntry(baseURL: "http://127.0.0.1:8766/v1", models: ["a"])]))
    }

    func testMissingKeysAndNonLoopbackURLsCountAsNoEntry() {
        for (name, adapter) in writable {
            XCTAssertEqual(adapter.read(name == "aider" ? "theme: dark\n" : "{}"), .noWorkbenchEntry, name)
            XCTAssertEqual(adapter.read(""), .noWorkbenchEntry, name)
        }
        let remote = ["https://127.0.0.1:8766/v1", "http://192.168.1.4:8766/v1", "http://[::1]:8766/v1", "http://127.0.0.1/v1"]
        for url in remote {
            XCTAssertEqual(ClientAdapters.opencode.read("{\"provider\":{\"mlx-local\":{\"options\":{\"baseURL\":\"\(url)\"}}}}"), .noWorkbenchEntry, url)
            XCTAssertEqual(ClientAdapters.zed.read("{\"language_models\":{\"openai\":{\"api_url\":\"\(url)\"}}}"), .noWorkbenchEntry, url)
            XCTAssertEqual(ClientAdapters.aider.read("openai-api-base: \(url)\n"), .noWorkbenchEntry, url)
        }
    }

    func testInvalidConfigsAreUnreadableWithFixedReasons() {
        for adapter in [ClientAdapters.opencode, ClientAdapters.continue_, ClientAdapters.zed] {
            XCTAssertEqual(adapter.read("{ not json"), .unreadable("Isn't valid JSON"))
            XCTAssertEqual(adapter.read("[1, 2]"), .unreadable("Top level isn't an object"))
        }
    }

    func testSecretsNeverLeaveTheReader() throws {
        let secret = "sk-SECRET-0123456789"
        let configs: [(ClientAdapter, String)] = [
            (ClientAdapters.opencode, "{\"provider\":{\"mlx-local\":{\"options\":{\"baseURL\":\"http://127.0.0.1:8766/v1\",\"apiKey\":\"\(secret)\"},\"models\":{\"a\":{}}}},\"apiKey\":\"\(secret)\"}"),
            (ClientAdapters.continue_, "{\"apiKey\":\"\(secret)\",\"models\":[{\"title\":\"a\",\"provider\":\"openai\",\"model\":\"a\",\"apiBase\":\"http://127.0.0.1:8766/v1\",\"apiKey\":\"\(secret)\"}]}"),
            (ClientAdapters.zed, "{\"language_models\":{\"openai\":{\"api_url\":\"http://127.0.0.1:8766/v1\",\"api_key\":\"\(secret)\",\"available_models\":[{\"name\":\"a\"}]}}}"),
            (ClientAdapters.aider, "openai-api-key: \(secret)\nopenai-api-base: http://127.0.0.1:8766/v1\nmodel: openai/a\n"),
            (ClientAdapters.opencode, "{ \"apiKey\": \"\(secret)\" "),
        ]
        for (adapter, contents) in configs {
            XCTAssertFalse(String(describing: adapter.read(contents)).contains(secret))
        }
    }

    func testFileLoaderReportsAbsentLinkedOversizedAndBinaryFiles() throws {
        let home = try F.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let adapter = ClientAdapters.opencode
        let path = home.appendingPathComponent("opencode.jsonc").path

        XCTAssertEqual(ClientConfigFile.load(path: path, adapter: adapter), F.status(.fileAbsent))

        let wired = try adapter.plan(nil, F.local)
        try F.write(wired, "real.jsonc", in: home)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: home.appendingPathComponent("real.jsonc").path)
        XCTAssertEqual(ClientConfigFile.load(path: path, adapter: adapter), F.status(.entries([F.entry(F.local)]), linked: true))

        let binary = home.appendingPathComponent("binary.jsonc")
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: binary)
        XCTAssertEqual(ClientConfigFile.load(path: binary.path, adapter: adapter), F.status(.unreadable("Isn't UTF-8 text")))

        let big = home.appendingPathComponent("big.jsonc")
        try Data(repeating: 0x20, count: ClientConfigFile.sizeLimit + 1).write(to: big)
        XCTAssertEqual(ClientConfigFile.load(path: big.path, adapter: adapter), F.status(.unreadable("Larger than 1 MB")))

        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent("broken.jsonc").path, withDestinationPath: home.appendingPathComponent("nowhere").path)
        XCTAssertEqual(ClientConfigFile.load(path: home.appendingPathComponent("broken.jsonc").path, adapter: adapter).reading, .fileAbsent)
    }
}

// MARK: - Matcher (AC2)

final class ClientsMatcherTests: XCTestCase {
    private typealias F = ClientsFixtures

    func testBaseURLTable() {
        let valid: [(String, Int)] = [
            ("http://127.0.0.1:8766/v1", 8766), ("http://127.0.0.1:8766/v1/", 8766),
            ("http://localhost:8767/v1", 8767), ("http://localhost:65535/v1/", 65535),
        ]
        for (url, port) in valid { XCTAssertEqual(ClientEndpointURL.port(of: url), port, url) }
        let invalid = [
            "http://[::1]:8766/v1", "http://127.0.0.2:8766/v1", "http://0.0.0.0:8766/v1", "http://192.168.1.4:8766/v1",
            "https://127.0.0.1:8766/v1", "http://127.0.0.1/v1", "http://127.0.0.1:/v1", "http://127.0.0.1:8766",
            "http://127.0.0.1:8766/", "http://127.0.0.1:8766/v2", "http://127.0.0.1:8766/V1", "http://127.0.0.1:8766/v1//",
            "http://127.0.0.1:8766/v1?x=1", "http://127.0.0.1:8766/v1#frag", "http://user@127.0.0.1:8766/v1",
            "http://user:pw@127.0.0.1:8766/v1", "http://127.0.0.1:0/v1", "http://127.0.0.1:70000/v1",
            "http://localhost.:8766/v1", "http://example.com:8766/v1", " http://127.0.0.1:8766/v1", "", "127.0.0.1:8766/v1",
        ]
        for url in invalid { XCTAssertNil(ClientEndpointURL.port(of: url), url) }
    }

    func testMatchTable() {
        let qwen = F.server("org/Qwen", port: 8766, pid: 1)
        let entry = { (url: String, models: [String]) in ClientConfigEntry(baseURL: url, models: models) }
        let base = "http://127.0.0.1:8766/v1"
        XCTAssertEqual(ClientEndpointMatch.match(entry(base, ["org/Qwen"]), servers: [qwen]), .live(port: 8766, model: "org/Qwen"))
        XCTAssertEqual(ClientEndpointMatch.match(entry(base, ["x", "org/Qwen"]), servers: [qwen]), .live(port: 8766, model: "org/Qwen"))
        XCTAssertEqual(ClientEndpointMatch.match(entry("http://localhost:8766/v1/", ["org/Qwen"]), servers: [qwen]), .live(port: 8766, model: "org/Qwen"))
        for wrong in ["org/Other", "Qwen", "org/qwen", "org/Qwen ", ""] {
            XCTAssertEqual(ClientEndpointMatch.match(entry(base, [wrong]), servers: [qwen]),
                .otherModel(port: 8766, configured: wrong, serving: "org/Qwen"), wrong)
        }
        XCTAssertEqual(ClientEndpointMatch.match(entry(base, []), servers: [qwen]), .otherModel(port: 8766, configured: "", serving: "org/Qwen"))
        XCTAssertEqual(ClientEndpointMatch.match(entry("http://127.0.0.1:9000/v1", ["org/Qwen"]), servers: [qwen]), .noWorkbenchServer(port: 9000))
        XCTAssertEqual(ClientEndpointMatch.match(entry(base, ["org/Qwen"]), servers: []), .noWorkbenchServer(port: 8766))
        let stopped = F.server("org/Qwen", port: 8766, state: "stopped")
        XCTAssertEqual(ClientEndpointMatch.match(entry(base, ["org/Qwen"]), servers: [stopped]), .noWorkbenchServer(port: 8766))
        let second = F.server("org/Other", port: 8766, pid: 2)
        XCTAssertEqual(ClientEndpointMatch.match(entry(base, ["org/Qwen"]), servers: [qwen, second]), .ambiguous(port: 8766))
        let unloaded = F.server("org/Qwen", port: 8766, jit: true, modelState: "unloaded")
        XCTAssertEqual(ClientEndpointMatch.match(entry(base, ["org/Qwen"]), servers: [unloaded]), .live(port: 8766, model: "org/Qwen"))
        XCTAssertNil(ClientEndpointMatch.match(entry("https://127.0.0.1:8766/v1", ["org/Qwen"]), servers: [qwen]))
    }
}

// MARK: - Layout

final class ClientsLayoutTests: XCTestCase {
    private func layout(board: CGFloat, previous: ClientsLayout? = nil) -> ClientsLayout {
        ClientsLayout(viewportWidth: board + WorkbenchSpacing.pageInset * 2, previous: previous)
    }

    func testMeasuredWindows() {
        let narrow = ClientsLayout(viewportWidth: 514)
        XCTAssertEqual(narrow.boardWidth, 466); XCTAssertEqual(narrow.innerWidth, 426)
        XCTAssertEqual(narrow.boardMode, .tree)
        XCTAssertTrue(narrow.wrapsPreviewHeader); XCTAssertFalse(narrow.wrapsActions)
        let standard = ClientsLayout(viewportWidth: 824)
        XCTAssertEqual(standard.boardWidth, 776); XCTAssertEqual(standard.innerWidth, 736)
        XCTAssertEqual(standard.boardMode, .twoColumn)
        XCTAssertFalse(standard.wrapsPreviewHeader); XCTAssertFalse(standard.wrapsActions)
        for viewport: CGFloat in [1220, 4000] {
            let wide = ClientsLayout(viewportWidth: viewport)
            XCTAssertEqual(wide.boardWidth, 1100); XCTAssertEqual(wide.innerWidth, 1060)
            XCTAssertEqual(wide.boardMode, .twoColumn)
        }
    }

    func testThresholdsFlipAndReturnWithHysteresis() {
        XCTAssertEqual(layout(board: 555).boardMode, .tree)
        XCTAssertEqual(layout(board: 556).boardMode, .twoColumn)
        for board: CGFloat in [556, 571] { XCTAssertEqual(layout(board: board, previous: layout(board: 500)).boardMode, .tree) }
        XCTAssertEqual(layout(board: 555, previous: layout(board: 800)).boardMode, .tree)
        XCTAssertEqual(layout(board: 572, previous: layout(board: 500)).boardMode, .twoColumn)

        XCTAssertTrue(layout(board: 499).wrapsPreviewHeader); XCTAssertFalse(layout(board: 500).wrapsPreviewHeader)
        XCTAssertTrue(layout(board: 515, previous: layout(board: 400)).wrapsPreviewHeader)
        XCTAssertFalse(layout(board: 516, previous: layout(board: 400)).wrapsPreviewHeader)

        XCTAssertTrue(layout(board: 331).wrapsActions); XCTAssertFalse(layout(board: 332).wrapsActions)
        XCTAssertTrue(layout(board: 347, previous: layout(board: 300)).wrapsActions)
        XCTAssertFalse(layout(board: 348, previous: layout(board: 300)).wrapsActions)
    }

    func testEveryWidthIsMonotonicAndNonNegative() {
        for width in 0...4000 {
            let current = ClientsLayout(viewportWidth: CGFloat(width))
            XCTAssertGreaterThanOrEqual(current.innerWidth, 0)
            if current.boardWidth < WorkbenchSize.Clients.boardThreshold { XCTAssertEqual(current.boardMode, .tree, "\(width)") }
        }
    }

    func testTokensAndSingleWidthOwner() {
        XCTAssertEqual(WorkbenchSize.Clients.boardThreshold, 556)
        XCTAssertEqual(WorkbenchSize.Clients.boardThreshold,
            WorkbenchSize.Clients.endpointMinimum + WorkbenchSize.Clients.gapMinimum + WorkbenchSize.Clients.clientMinimum)
        for viewport: CGFloat in [514, 824, 1220] {
            XCTAssertEqual(ClientsLayout(viewportWidth: viewport).boardWidth,
                RunLayout(viewportWidth: viewport).innerWidth + WorkbenchSize.Run.surfaceChrome)
        }
    }
}

// MARK: - Presentation (AC5, AC6, AC8, AC9)

final class ClientsPresentationTests: XCTestCase {
    private typealias F = ClientsFixtures

    private let qwen = F.server("org/Qwen-first", port: 8766, pid: 1)
    private let second = F.server("org/Second", port: 8767, pid: 2)

    private func present(
        _ readings: [String: ClientConfigStatus], servers: [ServerInfo]? = nil, selected: ServerInfo? = nil,
        pending: ServerInfo? = nil, planned: Set<String> = [], extra: [ClientInstallation] = []
    ) -> ClientsPresentation {
        ClientsPresentation.make(
            installations: [F.installation("opencode", name: "opencode", path: "/h/.config/opencode/opencode.jsonc"),
                            F.installation("continue", name: "Continue", path: "/h/.continue/config.json")] + extra,
            readings: readings, servers: servers ?? [qwen, second], selectedServerID: selected?.id,
            pendingTargetID: pending?.id, plannedClientIDs: planned
        )
    }

    private func entry(_ port: Int, _ models: [String]) -> ClientConfigEntry {
        ClientConfigEntry(baseURL: "http://127.0.0.1:\(port)/v1", models: models)
    }

    func testEachReadingStateHasItsRowTextAndLine() {
        let presentation = present([
            "opencode": F.status(.entries([entry(8766, ["org/Qwen-first"])])),
            "continue": F.status(.entries([entry(8767, ["org/Elsewhere"])])),
        ])
        XCTAssertEqual(presentation.clients[0].states, [ClientsStateText(text: "org/Qwen-first on :8766", tone: .live)])
        XCTAssertEqual(presentation.clients[0].lines, [ClientsLine(clientID: "opencode", endpointID: qwen.id, kind: .live)])
        XCTAssertEqual(presentation.clients[1].states,
            [ClientsStateText(text: "Configured for org/Elsewhere; :8767 serves org/Second", tone: .warning)])
        XCTAssertEqual(presentation.clients[1].lines.map(\.kind), [.otherModel])

        let ghost = present(["opencode": F.status(.entries([entry(8800, ["x"])])), "continue": F.status(.noWorkbenchEntry)])
        XCTAssertEqual(ghost.clients[0].states, [ClientsStateText(text: "No Workbench server on :8800", tone: .muted)])
        XCTAssertEqual(ghost.clients[0].lines, [ClientsLine(clientID: "opencode", endpointID: "ghost-8800", kind: .noWorkbenchServer)])
        XCTAssertEqual(ghost.endpoints.map(\.id), [qwen.id, second.id, "ghost-8800"])
        XCTAssertEqual(ghost.endpoints.last?.kind, .ghost)
        XCTAssertEqual(ghost.endpoints.last?.ghostText, ":8800 · No Workbench server")
        XCTAssertEqual(ghost.clients[1].states, [ClientsStateText(text: "No Workbench entry in config.json", tone: .muted)])

        let notDefault = present(["opencode": F.status(.notDefault([entry(8766, ["a"])])), "continue": F.status(.fileAbsent)])
        XCTAssertEqual(notDefault.clients[0].states,
            [ClientsStateText(text: "Workbench entry present; the default model is another provider", tone: .muted)])
        XCTAssertEqual(notDefault.clients[0].lines.map(\.kind), [.notDefault])
        XCTAssertEqual(notDefault.clients[1].states, [ClientsStateText(text: "config.json not created yet", tone: .muted)])
        XCTAssertTrue(notDefault.clients[1].lines.isEmpty)

        let unreadable = present(["opencode": F.status(.unreadable("Isn't valid JSON"))])
        XCTAssertEqual(unreadable.clients[0].states, [ClientsStateText(text: "Can't read opencode.jsonc: Isn't valid JSON", tone: .warning)])
        XCTAssertEqual(unreadable.clients[1].states, [ClientsStateText(text: "Reading config.json…", tone: .muted)])
        XCTAssertTrue(unreadable.lines.isEmpty)
    }

    func testAmbiguousPortDrawsNoLine() {
        let clash = F.server("org/Other", port: 8766, pid: 9)
        let presentation = present(["opencode": F.status(.entries([entry(8766, ["org/Qwen-first"])]))], servers: [qwen, clash])
        XCTAssertEqual(presentation.clients[0].states, [ClientsStateText(text: "Several servers on :8766", tone: .warning)])
        XCTAssertTrue(presentation.clients[0].lines.isEmpty)
        XCTAssertFalse(presentation.endpoints.contains { $0.kind == .ghost })
    }

    func testContinueOnTwoPortsDrawsTwoLinesAndCapsAtThree() {
        let two = present(["continue": F.status(.entries([entry(8766, ["org/Qwen-first"]), entry(8801, ["z"])]))])
        XCTAssertEqual(two.clients[1].lines.map(\.endpointID), [qwen.id, "ghost-8801"])
        XCTAssertEqual(two.clients[1].lines.map(\.kind), [.live, .noWorkbenchServer])

        let many = present(["continue": F.status(.entries((8766...8770).map { entry($0, ["m"]) }))])
        XCTAssertEqual(many.clients[1].lines.count, 3)
        XCTAssertEqual(many.clients[1].states.last, ClientsStateText(text: "+2 more", tone: .muted))
    }

    func testPendingLinesOnlyFromPlannedClientsToTheReviewedEndpoint() {
        let readings = ["opencode": F.status(.noWorkbenchEntry), "continue": F.status(.noWorkbenchEntry)]
        let pending = present(readings, pending: qwen, planned: ["opencode"])
        XCTAssertEqual(pending.lines, [ClientsLine(clientID: "opencode", endpointID: qwen.id, kind: .pending)])
        XCTAssertTrue(pending.clients[0].states.contains { $0.tone == .pending && $0.text.contains("opencode.jsonc") && $0.text.contains(":8766") })
        XCTAssertTrue(present(readings, pending: nil, planned: ["opencode"]).lines.isEmpty, "no current preview, no pending line")
        XCTAssertTrue(present(readings, pending: qwen, planned: []).lines.isEmpty, "clients outside the plans get none")
        XCTAssertTrue(present(readings, pending: F.server("org/Gone", port: 9999), planned: ["opencode"]).lines.isEmpty,
            "a reviewed server that left the running list has no row to anchor to")
        let both = present(["opencode": F.status(.entries([entry(8766, ["org/Qwen-first"])]))], pending: qwen, planned: ["opencode"])
        XCTAssertEqual(both.clients[0].lines.map(\.kind), [.live], "an existing line to the reviewed endpoint is not doubled")
    }

    func testAdvisoryRowsAndLinkedFiles() {
        let presentation = present(
            ["opencode": F.status(.entries([entry(8766, ["org/Qwen-first"])]), linked: true), "continue": F.status(.fileAbsent, linked: true)],
            extra: [F.installation("lmstudio", name: "LM Studio", path: nil, advisory: true)]
        )
        let advisory = presentation.clients[2]
        XCTAssertTrue(advisory.isAdvisory)
        XCTAssertEqual(advisory.states, [ClientsStateText(text: "Manages its own models", tone: .muted)])
        XCTAssertEqual(advisory.help, "LM Studio owns its model state.")
        XCTAssertTrue(advisory.lines.isEmpty)
        XCTAssertTrue(presentation.clients[0].states.contains(ClientsStateText(text: "Linked file; Workbench won't write through it", tone: .muted)))
        XCTAssertFalse(presentation.clients[1].states.contains { $0.text.hasPrefix("Linked file") })
    }

    func testEndpointRowsAreRunningByPortThenGhostsAndMarkSelection() {
        let presentation = present(["opencode": F.status(.entries([entry(8700, ["a"])]))], servers: [second, qwen, F.server("org/Down", port: 8000, state: "stopped")], selected: second)
        XCTAssertEqual(presentation.endpoints.map(\.id), [qwen.id, second.id, "ghost-8700"])
        XCTAssertEqual(presentation.endpoints.map(\.isSelected), [false, true, false])
        XCTAssertEqual(presentation.endpoints[0].name, "Qwen-first")
        XCTAssertEqual(presentation.endpoints[0].identity, "org/Qwen-first")
        XCTAssertTrue(presentation.hasRunningServer)
        let none = present([:], servers: [])
        XCTAssertFalse(none.hasRunningServer)
    }

    func testTreeGroupsPlaceEachClientUnderEveryEndpointItPointsAt() {
        let presentation = present([
            "opencode": F.status(.entries([entry(8766, ["org/Qwen-first"]), entry(8767, ["org/Second"])])),
            "continue": F.status(.noWorkbenchEntry),
        ])
        XCTAssertEqual(presentation.treeGroups.map { $0.children.map(\.client.id) }, [["opencode"], ["opencode"]])
        XCTAssertEqual(presentation.treeGroups.map { $0.children.map(\.line.kind) }, [[.live], [.live]])
        XCTAssertEqual(presentation.unconnectedClients.map(\.id), ["continue"])
    }

    func testConnectorLinesAreOrthogonalAndEndAtTheirOwnStateText() {
        let placed = [
            ClientsPlacedLine(line: ClientsLine(clientID: "c", endpointID: "e1", kind: .live), stateIndex: 0),
            ClientsPlacedLine(line: ClientsLine(clientID: "c", endpointID: "e2", kind: .noWorkbenchServer), stateIndex: 1),
            ClientsPlacedLine(line: ClientsLine(clientID: "d", endpointID: "e1", kind: .live), stateIndex: 0),
            ClientsPlacedLine(line: ClientsLine(clientID: "x", endpointID: "missing", kind: .live), stateIndex: 0),
        ]
        let endpoints = ["e1": CGRect(x: 0, y: 0, width: 100, height: 20), "e2": CGRect(x: 0, y: 40, width: 100, height: 20)]
        let symbols = ["c": CGRect(x: 200, y: 0, width: 24, height: 24), "d": CGRect(x: 200, y: 60, width: 24, height: 24),
                       "x": CGRect(x: 200, y: 120, width: 24, height: 24)]
        let entries = [
            ClientsEntryKey(clientID: "c", index: 0): CGRect(x: 232, y: 4, width: 200, height: 14),
            ClientsEntryKey(clientID: "c", index: 1): CGRect(x: 232, y: 22, width: 200, height: 14),
            ClientsEntryKey(clientID: "d", index: 0): CGRect(x: 232, y: 64, width: 200, height: 14),
            ClientsEntryKey(clientID: "x", index: 0): CGRect(x: 232, y: 124, width: 200, height: 14),
        ]
        let gap = CGRect(x: 100, y: 0, width: 100, height: 200)
        let segments = ClientsConnectorPlan.segments(
            placed: placed, endpointOrder: ["e1", "e2"], endpointRects: endpoints, entryRects: entries, symbolRects: symbols, gap: gap
        )
        XCTAssertEqual(segments.count, 9, "the line to a missing endpoint is dropped; each line is three segments")
        for segment in segments {
            XCTAssertTrue(segment.from.x == segment.to.x || segment.from.y == segment.to.y, "\(segment)")
        }
        let ends = segments.filter { $0.to.x == 200 - WorkbenchSpacing.xxs }
        XCTAssertEqual(ends.map(\.to.y), [11, 29, 71])
        XCTAssertEqual(segments[0].from, CGPoint(x: 100, y: 10))
        XCTAssertEqual(segments[0].to.x, gap.minX + WorkbenchSize.Clients.lineFan)
        XCTAssertEqual(segments[3].to.x, gap.minX + WorkbenchSize.Clients.lineFan * 2, "each endpoint has its own bus")
        XCTAssertTrue(ClientsConnectorPlan.segments(placed: placed, endpointOrder: ["e1", "e2"], endpointRects: endpoints,
            entryRects: entries, symbolRects: symbols, gap: nil).isEmpty)
    }

    func testPlacedLinesPointAtTheStateTextThatDescribesThem() {
        let presentation = present(["continue": F.status(.entries([entry(8766, ["org/Qwen-first"]), entry(8801, ["z"])]))])
        XCTAssertEqual(presentation.placedLines.map(\.stateIndex), [0, 1])
        let pending = present(["opencode": F.status(.noWorkbenchEntry)], pending: qwen, planned: ["opencode"])
        XCTAssertEqual(pending.placedLines.map(\.stateIndex), [1], "the pending line ends at the preview text")
    }

    func testTreeElbowAlignsWithTheEndpointSymbolAndTheChildSymbol() {
        let rect = CGRect(x: 10, y: 100, width: 300, height: 60)
        XCTAssertEqual(ClientsElbowPlan.railX(in: rect), 10 + WorkbenchSpacing.xs + WorkbenchSize.Clients.rowSymbol / 2)
        XCTAssertEqual(ClientsElbowPlan.tickEndX(in: rect),
            10 + WorkbenchSize.Clients.treeGutter + WorkbenchSpacing.xs - WorkbenchSpacing.xxs)
        XCTAssertEqual(ClientsElbowPlan.railStartY(in: rect, isFirst: true), 100 - WorkbenchSpacing.sm)
        XCTAssertEqual(ClientsElbowPlan.railStartY(in: rect, isFirst: false), 100)
    }

    func testOnlyPendingElbowsFadeIn() {
        XCTAssertEqual(ClientsElbowPlan.opacity(for: .pending, appeared: false), 0)
        XCTAssertEqual(ClientsElbowPlan.opacity(for: .pending, appeared: true), 1)
        for kind in [ClientsLineKind.live, .noWorkbenchServer, .otherModel, .notDefault] {
            XCTAssertEqual(ClientsElbowPlan.opacity(for: kind, appeared: false), 1)
        }
    }

    func testPendingTextNamesTheFileAndPortAndKeepsTheIdentityInHelp() {
        let pending = present(["opencode": F.status(.noWorkbenchEntry)], pending: qwen, planned: ["opencode"])
        let texts = pending.clients[0].states.map(\.text)
        XCTAssertTrue(texts.contains("Preview points opencode.jsonc at :8766"))
        XCTAssertFalse(texts.contains { $0.contains("org/Qwen-first") })
        XCTAssertTrue(pending.clients[0].help.contains("org/Qwen-first"))
    }

    func testClientSymbolsAreDisjointFromRoutesAndTheEndpointSymbol() {
        let ids = ["opencode", "continue", "zed", "aider", "lmstudio", "ollama"]
        let symbols = ids.map(ClientsPresentation.symbol(for:))
        XCTAssertEqual(Set(symbols).count, ids.count)
        XCTAssertTrue(Set(symbols).isDisjoint(with: AppRoute.allCases.map(\.symbolName) + [ClientsPresentation.endpointSymbol]))
    }

    func testServeStatusPlaceholderNeverAssertsNoServer() {
        let readings: [String: ClientConfigStatus] = [:]
        func header(servers: [ServerInfo], status: Bool) -> ClientsEndpointHeader {
            ClientsPresentation.make(
                installations: [F.installation("opencode", name: "opencode", path: "/h/o.jsonc")], readings: readings,
                servers: servers, selectedServerID: nil, pendingTargetID: nil, plannedClientIDs: [], hasServerStatus: status
            ).endpointHeader
        }
        XCTAssertEqual(header(servers: [], status: false), .readingStatus)
        XCTAssertEqual(header(servers: [], status: true), .noServer)
        XCTAssertEqual(header(servers: [qwen], status: false), .none)
        XCTAssertEqual(header(servers: [qwen], status: true), .none)
    }

    @MainActor
    func testStatusIsReadWhileTheConfigReadIsStillRunning() async {
        let gate = ReadGate()
        var statusRead = false
        let refresh = Task { @MainActor in
            await ClientsRefresh.run(readConfigs: { await gate.wait() }, readStatus: { statusRead = true; return true })
        }
        for _ in 0..<100 where !statusRead { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(statusRead, "status does not wait behind the config read")
        await gate.open()
        let result = await refresh.value
        XCTAssertTrue(result)
    }

    func testAdvisoryRowsAreNotListedAsNotConnected() {
        let presentation = present(
            ["opencode": F.status(.noWorkbenchEntry), "continue": F.status(.noWorkbenchEntry)],
            extra: [F.installation("lmstudio", name: "LM Studio", path: nil, advisory: true)]
        )
        XCTAssertEqual(presentation.unconnectedClients.map(\.id), ["opencode", "continue"])
        XCTAssertEqual(presentation.advisoryClients.map(\.id), ["lmstudio"])
    }

    func testOutcomeAfterConfirmMakesMeasureProminentAndPreviewBordered() {
        let prominence = ClientsProminence.make(showsPreview: false, hasCurrentPreview: false, showsMeasurement: true)
        XCTAssertEqual(prominence, ClientsProminence(preview: false, confirm: false, measure: true))
    }

    @MainActor
    func testOutcomeViewRendersTheResultAndBothMeasurementActions() throws {
        let view = ClientsOutcomeView(
            result: "Wired 1 client(s) to Qwen.", hasIssues: false,
            prominence: ClientsProminence(preview: false, confirm: false, measure: true), showsMeasurement: true,
            isPreparing: false, isMeasureDisabled: false, onMeasure: {}, onReview: {}
        ) { EmptyView() }
        let hosting = NSHostingView(rootView: view.frame(width: 600))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        XCTAssertGreaterThan(hosting.fittingSize.width, 0)
    }

    func testProminenceStateTable() {
        // showsPreview, hasCurrentPreview, showsMeasurement -> preview, confirm, measure
        let table: [(Bool, Bool, Bool, Bool, Bool, Bool)] = [
            (false, false, false, true, false, false),
            (true, true, false, false, true, false),
            (true, false, false, true, false, false),
            (false, false, true, false, false, true),
            (true, true, true, false, true, false),
            (true, false, true, true, false, false),
        ]
        for (shows, current, measurement, preview, confirm, measure) in table {
            let value = ClientsProminence.make(showsPreview: shows, hasCurrentPreview: current, showsMeasurement: measurement)
            XCTAssertEqual(value, ClientsProminence(preview: preview, confirm: confirm, measure: measure), "\(shows) \(current) \(measurement)")
        }
        for shows in [false, true] { for current in [false, true] { for measurement in [false, true] where !current || shows {
            XCTAssertLessThanOrEqual(ClientsProminence.make(showsPreview: shows, hasCurrentPreview: current, showsMeasurement: measurement).prominentCount, 1)
        } } }
    }

    func testEachMessageRendersOnce() {
        let notices = ClientsNotice.make(serverMessage: "Server status unavailable.", lastError: "Disk full", persistenceError: "Disk full", captureError: "No model")
        XCTAssertEqual(notices.map(\.text), ["Server status unavailable.", "Disk full", "No model"])
        XCTAssertEqual(notices.map(\.slot), [.header, .actions, .measurement])
        XCTAssertEqual(notices.map(\.isError), [false, true, true])
        XCTAssertTrue(ClientsNotice.make(serverMessage: nil, lastError: "", persistenceError: nil, captureError: nil).isEmpty)
    }
}

// MARK: - Coordinator reads (AC3, AC4)

@MainActor
final class ClientsCoordinatorTests: XCTestCase {
    private typealias F = ClientsFixtures

    private var home: URL!

    override func setUpWithError() throws {
        home = try F.makeHome()
        try F.makeDirectory(".config/opencode", in: home)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeCoordinator(source: @escaping ClientConfigSource) -> WiringCoordinator {
        WiringCoordinator(
            home: home, configSource: source,
            store: JSONStore<WiringTransaction>(fileURL: home.appendingPathComponent("transactions/wiring.json"))
        )
    }

    private func countingSource(_ counter: ReadCounter) -> ClientConfigSource {
        { path, adapter in
            counter.hit()
            return ClientConfigFile.load(path: path, adapter: adapter)
        }
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 250_000_000) }

    func testRefreshDetectsAddedAndRemovedClientsWithoutWriting() async throws {
        let directory = home.appendingPathComponent(".config/opencode")
        let config = directory.appendingPathComponent("opencode.jsonc")
        try FileManager.default.removeItem(at: directory)
        let coordinator = makeCoordinator(source: ClientConfigFile.live)

        await coordinator.refreshReadings()
        XCTAssertTrue(coordinator.installations.isEmpty)

        let original = "{\"theme\":\"dark\"}"
        try F.write(original, ".config/opencode/opencode.jsonc", in: home)
        await coordinator.refreshReadings()
        XCTAssertEqual(coordinator.installations.map(\.clientID), ["opencode"])
        XCTAssertEqual(coordinator.readings["opencode"]?.reading, .noWorkbenchEntry)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
        XCTAssertTrue(coordinator.plans.isEmpty)
        XCTAssertNil(coordinator.previewHash)
        XCTAssertTrue(coordinator.transactions.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["opencode.jsonc"])

        try FileManager.default.removeItem(at: directory)
        await coordinator.refreshReadings()
        XCTAssertTrue(coordinator.installations.isEmpty)
        XCTAssertTrue(coordinator.readings.isEmpty)
    }

    func testReadsRunOncePerTriggerAndNeverOnDetectOrPreview() async throws {
        try F.write("{\"theme\":\"dark\"}", ".config/opencode/opencode.jsonc", in: home)
        let counter = ReadCounter()
        let coordinator = makeCoordinator(source: countingSource(counter))

        coordinator.detect()
        XCTAssertEqual(counter.count, 0)
        await coordinator.refreshReadings()
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(coordinator.readings["opencode"]?.reading, .noWorkbenchEntry)

        coordinator.preview(endpoint: F.local)
        await settle()
        XCTAssertEqual(counter.count, 1, "previewing is not a read trigger")

        let hash = try XCTUnwrap(coordinator.previewHash)
        XCTAssertNotNil(coordinator.confirm(endpoint: F.local, previewHash: hash))
        await waitUntil { counter.count >= 2 }
        await settle()
        XCTAssertEqual(counter.count, 2, "one read after the confirm outcome")
        XCTAssertEqual(coordinator.readings["opencode"]?.reading, .entries([F.entry(F.local)]))

        coordinator.rollback()
        await waitUntil { counter.count >= 3 }
        await settle()
        XCTAssertEqual(counter.count, 3, "one read after the rollback, however many times the transaction changed")
        XCTAssertEqual(coordinator.readings["opencode"]?.reading, .noWorkbenchEntry)
    }

    func testConfirmOutcomeWithADriftedFileReadsToo() async throws {
        try F.write("{\"theme\":\"dark\"}", ".config/opencode/opencode.jsonc", in: home)
        let counter = ReadCounter()
        let coordinator = makeCoordinator(source: countingSource(counter))
        coordinator.detect()
        coordinator.preview(endpoint: F.local)
        try F.write("{\"theme\":\"light\"}", ".config/opencode/opencode.jsonc", in: home)
        let transaction = coordinator.confirm(endpoint: F.local, previewHash: try XCTUnwrap(coordinator.previewHash))
        XCTAssertEqual(transaction?.failures.count, 1)
        await waitUntil { counter.count >= 1 }
        await settle()
        XCTAssertEqual(counter.count, 1)
    }

    func testAReadStartedBeforeConfirmNeverOverwritesALaterRead() async throws {
        try F.write("{\"theme\":\"dark\"}", ".config/opencode/opencode.jsonc", in: home)
        let counter = ReadCounter()
        let gate = ReadGate()
        let coordinator = makeCoordinator(source: { path, adapter in
            if counter.hit() == 1 {
                await gate.wait()
                return ClientConfigStatus(reading: .unreadable("stale"), isLinked: false)
            }
            return ClientConfigFile.load(path: path, adapter: adapter)
        })
        coordinator.detect()
        let first = Task { await coordinator.refreshReadings() }
        await waitUntil { counter.count >= 1 }

        coordinator.preview(endpoint: F.local)
        XCTAssertNotNil(coordinator.confirm(endpoint: F.local, previewHash: try XCTUnwrap(coordinator.previewHash)))
        await waitUntil { coordinator.readings["opencode"] != nil }
        XCTAssertEqual(coordinator.readings["opencode"]?.reading, .entries([F.entry(F.local)]))

        await gate.open()
        await first.value
        XCTAssertEqual(coordinator.readings["opencode"]?.reading, .entries([F.entry(F.local)]), "the stale read was discarded")
    }

    func testAnInactiveRouteReadsNothingAndAnActiveRouteReadsOnce() async throws {
        let counter = ReadCounter()
        let coordinator = makeCoordinator(source: countingSource(counter))
        let host = ClientsRenderTests.makeHost(coordinator: coordinator, servers: [], home: home)
        let view = NSHostingView(rootView: ClientsRenderTests.root(host: host, active: false, viewport: 824, dark: true))
        let window = ClientsRenderTests.window(for: view, viewport: 824, dark: true)
        defer { window.close() }
        await settle()
        await settle()
        XCTAssertEqual(counter.count, 0, "an inactive route reads nothing")
        view.rootView = ClientsRenderTests.root(host: host, active: true, viewport: 824, dark: true)
        view.layoutSubtreeIfNeeded()
        await waitUntil { counter.count >= 1 }
        await settle()
        XCTAssertEqual(counter.count, 1, "activating the route reads once")
    }

    func testADefaultHostedAppHostReadsOnlyBeneathTheTestRoot() async throws {
        let host = AppHost(config: Config.defaults())
        let root = WorkbenchStatePaths.hostedTestRoot
        let hostedHome = WorkbenchStatePaths.userHome()
        XCTAssertTrue(hostedHome.path.hasPrefix(root.path))
        XCTAssertNotEqual(hostedHome.path, NSHomeDirectory())

        host.wiring.detect()
        XCTAssertTrue(host.wiring.installations.isEmpty, "the real home's clients are not detected in a hosted process")

        try F.makeDirectory(".config/opencode", in: hostedHome)
        try F.write(try ClientAdapters.opencode.plan(nil, F.local), ".config/opencode/opencode.jsonc", in: hostedHome)
        host.wiring.detect()
        XCTAssertEqual(host.wiring.installations.map(\.clientID), ["opencode"])
        XCTAssertTrue(host.wiring.installations.allSatisfy { ($0.configPath ?? "").hasPrefix(hostedHome.path) })
        await host.wiring.refreshReadings()
        XCTAssertEqual(host.wiring.readings["opencode"]?.reading, .entries([F.entry(F.local)]))
    }
}

// MARK: - Renders (AC13)

@MainActor
final class ClientsRenderTests: XCTestCase {
    private typealias F = ClientsFixtures

    func testEmptyClientSetupRendersAtNarrowAndWideWidths() throws {
        let home = try F.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let coordinator = WiringCoordinator(home: home,
            store: JSONStore<WiringTransaction>(fileURL: home.appendingPathComponent("transactions/wiring.json")))
        let host = Self.makeHost(coordinator: coordinator, servers: [], home: home)
        for width: CGFloat in [514, 824] {
            let view = NSHostingView(rootView: Self.root(host: host, active: false, viewport: width, dark: true))
            let window = Self.window(for: view, viewport: width, dark: true)
            defer { window.close() }
            view.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "empty-clients-\(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_CLIENTS_CAPTURE"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("empty-clients-\(Int(width)).png"))
            }
        }
        XCTAssertTrue(coordinator.installations.isEmpty)
        XCTAssertTrue(coordinator.plans.isEmpty)
        XCTAssertTrue(coordinator.transactions.isEmpty)
    }

    static func makeHost(coordinator: WiringCoordinator, servers: [ServerInfo], home: URL) -> AppHost {
        let api = ModelWorkflowAPI(convertPreview: { _, _, _ in [:] }, convertStart: { _, _, _, _ in [:] }, convertStatus: { [] },
            servePreview: { _, _, _ in [:] }, serveStart: { _, _, _, _ in [:] }, serveStatus: { servers }, serveStop: { _ in [:] })
        return AppHost(config: Config.defaults(), modelWorkflowAPI: api,
            modelWorkflowPersistence: ModelWorkflowPersistence(load: { [] }, upsert: { _ in }), wiring: coordinator,
            preferencesStore: JSONStore<RecommendationPreferences>(fileURL: home.appendingPathComponent("preferences.json")))
    }

    static func root(host: AppHost, active: Bool, viewport: CGFloat, dark: Bool) -> some View {
        WireView(appHost: host).environment(\.isRouteActive, active)
            .frame(width: viewport, height: 1000).background(WorkbenchColor.canvas).preferredColorScheme(dark ? .dark : .light)
    }

    static func show(host: AppHost, active: Bool, viewport: CGFloat, dark: Bool) -> NSWindow {
        window(for: NSHostingView(rootView: root(host: host, active: active, viewport: viewport, dark: dark)), viewport: viewport, dark: dark)
    }

    static func window<Content: View>(for view: NSHostingView<Content>, viewport: CGFloat, dark: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: viewport, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    private struct Scenario {
        let name: String
        let servers: [ServerInfo]
        let selected: ServerInfo?
        let expected: [ClientsLineKind]
        let prepare: @MainActor (URL, WiringCoordinator) async throws -> Void
    }

    private let qwen = F.server("/models/Qwen-converted-4bit", port: 8766, pid: 1)
    private let other = F.server("/models/Llama-3-8B-4bit", port: 8767, pid: 2)

    private func endpoint(_ server: ServerInfo, port: Int? = nil, model: String? = nil) -> WireEndpoint {
        WireEndpoint(baseURL: "http://127.0.0.1:\(port ?? server.port ?? 0)/v1", modelName: model ?? server.modelIdentity)
    }

    private func opencode(_ endpoint: WireEndpoint, in home: URL) throws {
        try F.write(try ClientAdapters.opencode.plan(nil, endpoint), ".config/opencode/opencode.jsonc", in: home)
    }

    private func scenarios() -> [Scenario] {
        let qwen = self.qwen, other = self.other
        let plain = "{\"theme\":\"dark\"}"
        return [
            Scenario(name: "live", servers: [qwen, other], selected: nil, expected: [.live]) { [self] home, _ in
                try opencode(endpoint(qwen), in: home)
                try F.makeDirectory(".lmstudio", in: home)
                try F.makeDirectory(".config/zed", in: home)
            },
            Scenario(name: "noWorkbenchServer", servers: [qwen], selected: nil, expected: [.noWorkbenchServer]) { [self] home, _ in
                try opencode(endpoint(qwen, port: 8800), in: home)
            },
            Scenario(name: "otherModel", servers: [qwen], selected: nil, expected: [.otherModel]) { [self] home, _ in
                try opencode(endpoint(qwen, model: "/models/Mistral-7B-4bit"), in: home)
            },
            Scenario(name: "notDefault", servers: [qwen], selected: nil, expected: [.notDefault]) { home, _ in
                let config = "{\"provider\":{\"mlx-local\":{\"options\":{\"baseURL\":\"http://127.0.0.1:8766/v1\"},\"models\":{\"/models/Qwen-converted-4bit\":{}}}},\"model\":\"anthropic/claude\"}"
                try F.write(config, ".config/opencode/opencode.jsonc", in: home)
            },
            Scenario(name: "unreadable", servers: [qwen], selected: nil, expected: []) { home, _ in
                try F.write("{ not json", ".config/opencode/opencode.jsonc", in: home)
            },
            Scenario(name: "fileAbsent", servers: [qwen], selected: nil, expected: []) { home, _ in
                try F.makeDirectory(".config/opencode", in: home)
            },
            Scenario(name: "continueTwoPorts", servers: [qwen], selected: nil, expected: [.live, .live, .noWorkbenchServer]) { [self] home, _ in
                let first = try ClientAdapters.continue_.plan(nil, endpoint(qwen))
                try F.write(try ClientAdapters.continue_.plan(first, endpoint(qwen, port: 8801, model: "org/Remote")), ".continue/config.json", in: home)
                try opencode(endpoint(qwen), in: home)
            },
            Scenario(name: "pendingPreview", servers: [qwen, other], selected: qwen, expected: [.pending]) { home, coordinator in
                try F.write(plain, ".config/opencode/opencode.jsonc", in: home)
                coordinator.detect()
                coordinator.preview(server: qwen)
            },
            Scenario(name: "stalePreview", servers: [qwen, other], selected: qwen, expected: []) { home, coordinator in
                try F.write(plain, ".config/opencode/opencode.jsonc", in: home)
                coordinator.detect()
                coordinator.preview(server: other)
            },
            Scenario(name: "afterConfirm", servers: [qwen, other], selected: qwen, expected: [.live]) { home, coordinator in
                try F.write(plain, ".config/opencode/opencode.jsonc", in: home)
                coordinator.detect()
                coordinator.preview(server: qwen)
                let hash = try XCTUnwrap(coordinator.previewHash)
                let transaction = await coordinator.confirm(server: qwen, previewHash: hash, currentServers: { [qwen, other] })
                XCTAssertNotNil(transaction)
            },
            Scenario(name: "afterRollback", servers: [qwen, other], selected: qwen, expected: []) { home, coordinator in
                try F.write(plain, ".config/opencode/opencode.jsonc", in: home)
                coordinator.detect()
                coordinator.preview(server: qwen)
                let hash = try XCTUnwrap(coordinator.previewHash)
                _ = await coordinator.confirm(server: qwen, previewHash: hash, currentServers: { [qwen, other] })
                coordinator.rollback()
            },
            Scenario(name: "noServer", servers: [], selected: nil, expected: [.noWorkbenchServer]) { [self] home, _ in
                try opencode(endpoint(qwen), in: home)
            },
            Scenario(name: "noClients", servers: [qwen], selected: nil, expected: []) { _, _ in },
        ]
    }

    private func presentation(host: AppHost, coordinator: WiringCoordinator, selected: ServerInfo?) -> ClientsPresentation {
        ClientsPresentation.make(
            installations: coordinator.installations, readings: coordinator.readings, servers: host.modelWorkflow.servers,
            selectedServerID: selected?.id,
            pendingTargetID: coordinator.previewMatches(server: selected) ? selected?.id : nil,
            plannedClientIDs: Set(coordinator.plans.map(\.clientID))
        )
    }

    /// The confirmed-wiring result and measurement row hang on view state, so they render from values.
    private func attachOutcome(dark: Bool) throws {
        let outcome = ClientsOutcomeView(
            result: "Wired 1 client(s) to Qwen-converted-4bit.", hasIssues: false,
            prominence: ClientsProminence.make(showsPreview: false, hasCurrentPreview: false, showsMeasurement: true),
            showsMeasurement: true, isPreparing: false, isMeasureDisabled: false, onMeasure: {}, onReview: {}
        ) { EmptyView() }
        let view = NSHostingView(rootView: outcome.padding(WorkbenchSpacing.pageInset).frame(width: 700, alignment: .leading)
            .background(WorkbenchColor.canvas).preferredColorScheme(dark ? .dark : .light))
        let window = Self.window(for: view, viewport: 700, dark: dark)
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let attachment = XCTAttachment(data: try XCTUnwrap(image.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "afterConfirmOutcome-\(dark ? "dark" : "light")-700"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEveryStateRendersDarkAndLightAtEveryWidth() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let widths: [(label: Int, viewport: CGFloat)] = [(1556, 1220), (1050, 824), (740, 514)]
        for scenario in scenarios() {
            let home = try F.makeHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let coordinator = WiringCoordinator(home: home, store: JSONStore<WiringTransaction>(fileURL: home.appendingPathComponent("transactions/wiring.json")))
            try await scenario.prepare(home, coordinator)
            let host = Self.makeHost(coordinator: coordinator, servers: scenario.servers, home: home)

            for dark in [true, false] {
                for width in widths {
                    _ = host.handoffs.take(.wireClient)
                    if let selected = scenario.selected {
                        host.handoffs.send(ClientWiringRequest(modelPath: selected.path ?? "", preferredPort: selected.port), as: .wireClient)
                    }
                    let window = Self.show(host: host, active: true, viewport: width.viewport, dark: dark)
                    defer { window.close() }
                    let deadline = Date().addingTimeInterval(4)
                    var current = presentation(host: host, coordinator: coordinator, selected: scenario.selected)
                    while Date() < deadline {
                        current = presentation(host: host, coordinator: coordinator, selected: scenario.selected)
                        let loaded = host.modelWorkflow.servers == scenario.servers && host.handoffs[.wireClient] == nil
                        let hasReadings = coordinator.installations.filter { !$0.advisoryOnly }.allSatisfy { coordinator.readings[$0.clientID] != nil }
                        if loaded && hasReadings && current.lines.map(\.kind) == scenario.expected { break }
                        try await Task.sleep(nanoseconds: 25_000_000)
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                    XCTAssertEqual(current.lines.map(\.kind), scenario.expected, scenario.name)
                    if scenario.name == "noClients" { XCTAssertTrue(current.clients.isEmpty) }
                    if scenario.name == "noServer" { XCTAssertFalse(current.hasRunningServer) }

                    let view = try XCTUnwrap(window.contentView)
                    view.layoutSubtreeIfNeeded()
                    let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: image)
                    let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    XCTAssertGreaterThan(png.count, 1_000)
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = "\(scenario.name)-\(dark ? "dark" : "light")-\(width.label)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                if scenario.name == "afterConfirm" { try attachOutcome(dark: dark) }
            }
        }
    }
}
