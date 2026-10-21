import Foundation
import XCTest
import AppKit
import SwiftUI

@testable import mlx_workbench

@MainActor
final class WiringCoordinatorTests: XCTestCase {
    private let endpoint = WireEndpoint(baseURL: "http://127.0.0.1:8766/v1", modelName: "qwen3-8b")

    // MARK: - JSONC tolerance

    func testJSONCStripsCommentsAndTrailingCommasButNotInsideStrings() throws {
        let jsonc = """
        {
          // line comment
          "model": "a//b",
          /* block
             comment */
          "url": "https://x/*y*/",
          "list": [1, 2,],
        }
        """
        let parsed = try JSONCTolerant.parse(jsonc)
        XCTAssertEqual(parsed["model"] as? String, "a//b")
        XCTAssertEqual(parsed["url"] as? String, "https://x/*y*/")
        XCTAssertEqual(parsed["list"] as? [Int], [1, 2])
    }

    func testJSONCParseRejectsNonObject() {
        XCTAssertThrowsError(try JSONCTolerant.parse("[1, 2]"))
        XCTAssertThrowsError(try JSONCTolerant.parse("{ not json"))
    }

    // MARK: - Adapters

    func testOpencodePlanCreatesProviderAndModel() throws {
        let after = try ClientAdapters.opencode.plan(nil, endpoint)
        let parsed = try JSONCTolerant.parse(after)
        let provider = parsed["provider"] as? [String: Any]
        let local = provider?["mlx-local"] as? [String: Any]
        XCTAssertEqual((local?["options"] as? [String: Any])?["baseURL"] as? String, "http://127.0.0.1:8766/v1")
        XCTAssertNotNil(local?["models"] as? [String: Any])
        XCTAssertEqual(parsed["model"] as? String, "mlx-local/qwen3-8b")
    }

    func testOpencodePlanPreservesUnrelatedKeysAndCommentsAreNormalized() throws {
        let before = "{\n  // keep this intent\n  \"theme\": \"dark\",\n}\n"
        let after = try ClientAdapters.opencode.plan(before, endpoint)
        let parsed = try JSONCTolerant.parse(after)
        XCTAssertEqual(parsed["theme"] as? String, "dark")
        XCTAssertEqual(parsed["model"] as? String, "mlx-local/qwen3-8b")
    }

    func testOpencodePlanAddsSchemaOnlyWhenMissingOrEmpty() throws {
        for before in [nil, "{\"$schema\": \"\"}"] {
            let parsed = try JSONCTolerant.parse(ClientAdapters.opencode.plan(before, endpoint))
            XCTAssertEqual(parsed["$schema"] as? String, "https://opencode.ai/config.json")
        }
        let custom = try JSONCTolerant.parse(
            ClientAdapters.opencode.plan("{\"$schema\": \"https://example.com/opencode.json\"}", endpoint))
        XCTAssertEqual(custom["$schema"] as? String, "https://example.com/opencode.json")
        let null = try JSONCTolerant.parse(ClientAdapters.opencode.plan("{\"$schema\": null}", endpoint))
        XCTAssertTrue(null["$schema"] is NSNull)
    }

    func testOpencodeLoadMirrorInsertsSchemaOnlyWhenMissing() throws {
        let home = try makeHome()
        let config = home.appendingPathComponent("opencode.jsonc")
        try "{\"a\":1}".write(to: config, atomically: true, encoding: .utf8)
        try loadAsOpencode(config)
        XCTAssertEqual(try String(contentsOf: config), "{\n  \"$schema\": \"https://opencode.ai/config.json\",\"a\":1}")
        try loadAsOpencode(config)
        XCTAssertEqual(try String(contentsOf: config), "{\n  \"$schema\": \"https://opencode.ai/config.json\",\"a\":1}")
    }

    func testContinuePlanReplacesSameTitledEntry() throws {
        let before = "{\"models\": [{\"title\": \"qwen3-8b\", \"provider\": \"openai\", \"model\": \"old\", \"apiBase\": \"http://old\"}]}"
        let after = try ClientAdapters.continue_.plan(before, endpoint)
        let parsed = try JSONCTolerant.parse(after)
        let models = parsed["models"] as? [[String: Any]]
        XCTAssertEqual(models?.count, 1)
        XCTAssertEqual(models?.first?["apiBase"] as? String, "http://127.0.0.1:8766/v1")
        XCTAssertEqual(models?.first?["model"] as? String, "qwen3-8b")
    }

    func testZedPlanSetsOpenAILanguageModel() throws {
        let after = try ClientAdapters.zed.plan("{\"vim_mode\": true}", endpoint)
        let parsed = try JSONCTolerant.parse(after)
        XCTAssertEqual(parsed["vim_mode"] as? Bool, true)
        let openai = (parsed["language_models"] as? [String: Any])?["openai"] as? [String: Any]
        XCTAssertEqual(openai?["api_url"] as? String, "http://127.0.0.1:8766/v1")
    }

    func testAiderPlanPreservesCommentsAndReplacesKeys() throws {
        let before = "# my aider config\nmodel: openai/old\nopenai-api-base: http://old\n"
        let after = try ClientAdapters.aider.plan(before, endpoint)
        XCTAssertTrue(after.contains("# my aider config"))
        XCTAssertTrue(after.contains("model: openai/qwen3-8b"))
        XCTAssertTrue(after.contains("openai-api-base: http://127.0.0.1:8766/v1"))
        XCTAssertFalse(after.contains("http://old"))
    }

    func testAdvisoryAdaptersAreDetectedButNeverPlanned() throws {
        let home = try makeHome()
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".lmstudio"),
            withIntermediateDirectories: true
        )
        let coordinator = makeCoordinator(home: home)

        coordinator.detect()

        XCTAssertTrue(coordinator.installations.contains(where: { $0.clientID == "lmstudio" && $0.advisoryOnly }))
        coordinator.preview(endpoint: endpoint)
        XCTAssertFalse(coordinator.plans.contains(where: { $0.clientID == "lmstudio" }))
    }

    // MARK: - Coordinator flow

    func testReviewedServerPreviewDoesNotFollowSelectionOrAReplacementProcess() async throws {
        let home = try makeHome()
        let config = home.appendingPathComponent(".config/opencode/opencode.jsonc")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{\"theme\":\"dark\"}".utf8)
        try original.write(to: config)
        let coordinator = makeCoordinator(home: home)
        let server = ServerInfo(repo: "org/model", runtime: "mlx_lm", port: 8766, pid: 123,
                                state: "running", startedAt: "first", receipt: "receipt-a")
        XCTAssertFalse(coordinator.previewMatches(server: server))
        coordinator.preview(server: server)
        XCTAssertTrue(coordinator.previewMatches(server: server))
        let reviewed = try XCTUnwrap(coordinator.reviewedEndpoint)
        for changed in [
            ServerInfo(repo: "org/other", runtime: "mlx_lm", port: 8766, pid: 123, state: "running", startedAt: "first", receipt: "receipt-a"),
            ServerInfo(repo: "org/model", runtime: "mlx_lm", port: 8767, pid: 123, state: "running", startedAt: "first", receipt: "receipt-a"),
            ServerInfo(repo: "org/model", runtime: "mlx_lm", port: 8766, pid: 456, state: "running", startedAt: "first", receipt: "receipt-a"),
            ServerInfo(repo: "org/model", runtime: "mlx_vlm", port: 8766, pid: 123, state: "running", startedAt: "first", receipt: "receipt-a"),
            ServerInfo(repo: "org/model", runtime: "mlx_lm", port: 8766, pid: 123, state: "running", startedAt: "second", receipt: "receipt-a"),
            ServerInfo(repo: "org/model", runtime: "mlx_lm", port: 8766, pid: 123, state: "running", startedAt: "first", receipt: "receipt-b"),
            ServerInfo(repo: "org/model", runtime: "mlx_lm", port: 8766, pid: 123, state: "stopped", startedAt: "first", receipt: "receipt-a")
        ] {
            XCTAssertFalse(coordinator.previewMatches(server: changed))
            XCTAssertEqual(coordinator.reviewedEndpoint, reviewed, "Selection must not relabel a frozen preview")
            let transaction = await coordinator.confirm(server: changed, previewHash: try XCTUnwrap(coordinator.previewHash),
                currentServers: { [changed] })
            XCTAssertNil(transaction)
            XCTAssertEqual(try Data(contentsOf: config), original)
        }
        XCTAssertFalse(coordinator.previewMatches(server: nil))
        let transaction = await coordinator.confirm(server: server, previewHash: try XCTUnwrap(coordinator.previewHash),
            currentServers: { [] })
        XCTAssertNil(transaction)
        XCTAssertNil(coordinator.reviewedEndpoint)
        XCTAssertFalse(coordinator.previewMatches(server: server))
        XCTAssertEqual(try Data(contentsOf: config), original)
    }

    func testEmptyOrEndpointOnlyPreviewCannotEnableServerConfirmation() throws {
        let home = try makeHome()
        let coordinator = makeCoordinator(home: home)
        let server = ServerInfo(repo: "org/model", port: 8766, pid: 123, state: "running")
        coordinator.preview(server: server)
        XCTAssertTrue(coordinator.plans.isEmpty)
        XCTAssertFalse(coordinator.previewMatches(server: server))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/opencode"), withIntermediateDirectories: true)
        coordinator.preview(endpoint: try XCTUnwrap(WireEndpoint(server: server)))
        XCTAssertFalse(coordinator.plans.isEmpty)
        XCTAssertNil(coordinator.reviewedEndpoint)
        XCTAssertFalse(coordinator.previewMatches(server: server))
    }

    func testLocalDirectoryServerCanBeWiredAndRolledBack() async throws {
        let home = try makeHome()
        let config = home.appendingPathComponent(".config/opencode/opencode.jsonc")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "{\"theme\":\"dark\"}"
        try original.write(to: config, atomically: true, encoding: .utf8)
        let server = ServerInfo(path: "/models/qwen-converted", runtime: "mlx_lm", port: 8766, pid: 123, state: "running")
        let endpoint = try XCTUnwrap(WireEndpoint(server: server))
        XCTAssertEqual(endpoint.baseURL, "http://127.0.0.1:8766/v1")
        XCTAssertEqual(endpoint.modelName, "/models/qwen-converted")
        let coordinator = makeCoordinator(home: home)
        coordinator.preview(server: server)
        let hash = try XCTUnwrap(coordinator.previewHash)
        let transaction = await coordinator.confirm(server: server, previewHash: hash, currentServers: { [server] })
        XCTAssertEqual(transaction?.receipts.count, 1)
        XCTAssertEqual(try JSONCTolerant.parse(String(contentsOf: config))["model"] as? String, "mlx-local//models/qwen-converted")
        coordinator.rollback()
        XCTAssertEqual(try String(contentsOf: config), original)
    }

    func testStoppedOrReplacedServerCannotWriteClientConfig() async throws {
        let home = try makeHome()
        let directory = home.appendingPathComponent(".config/zed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = directory.appendingPathComponent("settings.json")
        let coordinator = makeCoordinator(home: home)
        let server = ServerInfo(path: "/models/chosen", runtime: "mlx_lm", port: 8766, pid: 123, state: "running")
        let invalid: [[ServerInfo]] = [[],
            [ServerInfo(path: "/models/chosen", runtime: "mlx_lm", port: 8766, pid: 123, state: "stopped")],
            [ServerInfo(path: "/models/other", runtime: "mlx_lm", port: 8766, pid: 123, state: "running")],
            [ServerInfo(path: "/models/chosen", runtime: "mlx_lm", port: 8766, pid: 456, state: "running")]]
        for servers in invalid {
            coordinator.preview(server: server)
            let hash = try XCTUnwrap(coordinator.previewHash)
            let transaction = await coordinator.confirm(server: server, previewHash: hash, currentServers: { servers })
            XCTAssertNil(transaction)
            XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
            XCTAssertNotNil(coordinator.lastError)
        }
    }

    func testServerStatusFailureAndUncheckedConfirmCannotWrite() async throws {
        let home = try makeHome()
        let directory = home.appendingPathComponent(".config/zed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = makeCoordinator(home: home)
        let server = ServerInfo(repo: "org/model", runtime: "mlx_lm", port: 8766, pid: 123, state: "running")
        coordinator.preview(server: server)
        let hash = try XCTUnwrap(coordinator.previewHash)
        XCTAssertNil(coordinator.confirm(endpoint: try XCTUnwrap(WireEndpoint(server: server)), previewHash: hash))
        let transaction = await coordinator.confirm(server: server, previewHash: hash, currentServers: { throw CocoaError(.fileReadUnknown) })
        XCTAssertNil(transaction)
        XCTAssertNil(coordinator.previewHash)
        XCTAssertTrue(coordinator.transactions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.json").path))
    }

    func testStatusCheckPrecedesWriteAndPreservesConfigDrift() async throws {
        let home = try makeHome()
        let config = home.appendingPathComponent(".config/opencode/opencode.jsonc")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "{\"theme\":\"dark\"}"
        try original.write(to: config, atomically: true, encoding: .utf8)
        let coordinator = makeCoordinator(home: home)
        let server = ServerInfo(path: "/models/chosen", port: 8766, pid: 123, state: "running")
        coordinator.preview(server: server)
        let hash = try XCTUnwrap(coordinator.previewHash)
        let edited = "{\"theme\":\"light\"}"
        let transaction = await coordinator.confirm(server: server, previewHash: hash, currentServers: {
            XCTAssertEqual(try String(contentsOf: config), original)
            try edited.write(to: config, atomically: true, encoding: .utf8)
            return [server]
        })
        XCTAssertEqual(transaction?.receipts.count, 0)
        XCTAssertEqual(transaction?.failures.count, 1)
        XCTAssertEqual(try String(contentsOf: config), edited)
    }

    func testRunHandoffSelectsTheExactAdapterServerAmongMatchingModelEndpoints() throws {
        let base = ServerInfo(repo: "org/base", runtime: "mlx_lm", port: 8766, pid: 1, state: "running")
        let adapter = ServerInfo(repo: "org/base", runtime: "mlx_lm", port: 8767, pid: 2, state: "running",
            receipt: "/receipts/adapter.json", adapterPath: "/adapters/tuned", adapterIdentity: .object(["sha256": .string("first")]))
        let request = try XCTUnwrap(ClientWiringRequest.forServer(adapter))
        XCTAssertEqual(request.modelPath, "org/base")
        XCTAssertEqual(request.preferredPort, 8767)
        XCTAssertEqual(request.expectedServer, adapter)
        XCTAssertEqual(ClientWiringSelection.matchingServers(request: request, servers: [base, adapter]), [adapter])
        XCTAssertTrue(ClientWiringSelection.matchingServers(request: .init(modelPath: "org/base", preferredPort: nil), servers: [adapter]).isEmpty,
                      "A model-only handoff must still exclude adapter substitutions")
    }

    func testRunHandoffRejectsChangedProcessAndAdapterIdentity() throws {
        let source: [String: Any] = ["repo": "org/base", "runtime": "mlx_lm", "port": 8767, "pid": 42, "state": "running",
            "receipt": "/receipts/first.json", "started_at": "first-start", "adapter_path": "/adapters/tuned",
            "adapter_identity": ["adapters.safetensors": ["sha256": "first", "bytes": 4]]]
        func server(_ fields: [String: Any]) throws -> ServerInfo {
            try JSONDecoder().decode(ServerInfo.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        let original = try server(source), request = try XCTUnwrap(ClientWiringRequest.forServer(original))
        let changes: [(String, Any)] = [("pid", 43), ("receipt", "/receipts/second.json"), ("runtime", "other"),
            ("started_at", "second-start"), ("adapter_path", "/adapters/other"),
            ("adapter_identity", ["adapters.safetensors": ["sha256": "second", "bytes": 4]])]
        for (key, value) in changes {
            let replacement = try server(source.merging([key: value]) { _, new in new })
            XCTAssertTrue(ClientWiringSelection.matchingServers(request: request, servers: [replacement]).isEmpty, key)
        }
    }

    func testRunHandoffRequiresAValidEndpointAndConsistentRequest() throws {
        for invalid in [ServerInfo(path: "/models/a", port: 0, state: "running"),
                        ServerInfo(path: "/models/a", port: 70000, state: "running"),
                        ServerInfo(port: 8766, state: "running"),
                        ServerInfo(path: "/models/a", port: 8766, state: "stopped")] {
            XCTAssertNil(ClientWiringRequest.forServer(invalid))
        }
        let server = ServerInfo(path: "/models/a", port: 8766, pid: 42, state: "running")
        for inconsistent in [ClientWiringRequest(modelPath: "/models/other", preferredPort: 8766, expectedServer: server),
                             ClientWiringRequest(modelPath: "/models/a", preferredPort: 8767, expectedServer: server)] {
            XCTAssertTrue(ClientWiringSelection.matchingServers(request: inconsistent, servers: [server]).isEmpty)
        }
    }

    func testRunHandoffSurvivesJITResidencyChangesOnTheSameEndpoint() throws {
        let unloaded = ServerInfo(path: "/models/a", runtime: "mlx_lm", port: 8766, pid: 42, state: "running",
            receipt: "/receipts/first.json", jit: true, modelState: "unloaded")
        let loaded = ServerInfo(path: "/models/a", runtime: "mlx_lm", port: 8766, pid: 42, state: "running",
            receipt: "/receipts/first.json", jit: true, modelState: "loaded", workerPid: 99, activeRequests: 1)
        let request = try XCTUnwrap(ClientWiringRequest.forServer(unloaded))
        XCTAssertEqual(ClientWiringSelection.matchingServers(request: request, servers: [loaded]), [loaded])
    }

    func testHandoffMatchesChosenModelAndPortWithoutCollapsingRevisions() {
        let path = "/cache/models--org--model/snapshots/revision-a"
        let local = ServerInfo(path: path, port: 8766, pid: 1, state: "running")
        let otherRevision = ServerInfo(path: "/cache/models--org--model/snapshots/revision-b", port: 8767, pid: 2, state: "running")
        let legacy = ServerInfo(repo: "org/model", port: 8768, pid: 3, state: "running")
        let request = ClientWiringRequest(modelPath: path, preferredPort: nil)
        XCTAssertEqual(ClientWiringSelection.matchingServers(request: request, servers: [local, otherRevision, legacy]).map(\.port), [8766, 8768])
        let exact = ClientWiringRequest(modelPath: path, preferredPort: 8766)
        XCTAssertEqual(ClientWiringSelection.matchingServers(request: exact, servers: [local, legacy]), [local])
        XCTAssertTrue(ClientWiringSelection.matchingServers(request: exact, servers: [legacy]).isEmpty)
    }

    func testEndpointUsesFullRepositoryIdentityAndRejectsInvalidStatus() {
        let server = ServerInfo(repo: "org/model", port: 8766, pid: 1, state: "running")
        XCTAssertEqual(WireEndpoint(server: server)?.modelName, "org/model")
        for invalid in [ServerInfo(path: "/models/a", port: 0, state: "running"),
                        ServerInfo(path: "/models/a", port: 70000, state: "running"),
                        ServerInfo(port: 8766, state: "running"),
                        ServerInfo(path: "/models/a", port: 8766, state: "stopped")] {
            XCTAssertNil(WireEndpoint(server: invalid))
        }
    }

    func testClientHandoffRendersAndConsumesTheRequestOnEntry() async throws {
        let home = try makeHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/opencode"), withIntermediateDirectories: true)
        let coordinator = makeCoordinator(home: home)
        let server = ServerInfo(path: "/models/Qwen-converted-4bit", runtime: "mlx_lm", port: 8766, pid: 123, state: "running")
        let api = ModelWorkflowAPI(convertPreview: { _, _, _ in [:] }, convertStart: { _, _, _, _ in [:] }, convertStatus: { [] },
            servePreview: { _, _, _ in [:] }, serveStart: { _, _, _, _ in [:] }, serveStatus: { [server] }, serveStop: { _ in [:] })
        let host = AppHost(config: Config.defaults(), modelWorkflowAPI: api,
            modelWorkflowPersistence: ModelWorkflowPersistence(load: { [] }, upsert: { _ in }), wiring: coordinator,
            preferencesStore: JSONStore<RecommendationPreferences>(fileURL: home.appendingPathComponent("preferences.json")))
        host.handoffs.send(ClientWiringRequest(modelPath: server.path!, preferredPort: 8766), as: .wireClient)
        let view = NSHostingView(rootView: WireView(appHost: host).environment(\.isRouteActive, true)
            .frame(width: 720, height: 720).background(WorkbenchColor.canvas).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        for _ in 0..<10 {
            if host.handoffs[.wireClient] == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(host.handoffs[.wireClient])
        XCTAssertEqual(host.modelWorkflow.servers, [server])
        XCTAssertTrue(coordinator.transactions.isEmpty)
        view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let attachment = XCTAttachment(data: try XCTUnwrap(image.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "Chosen local model in Clients"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPreviewConfirmApplyAndRollbackRoundTrip() throws {
        let home = try makeHome()
        let opencodeConfig = home.appendingPathComponent(".config/opencode/opencode.jsonc")
        try FileManager.default.createDirectory(at: opencodeConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"theme\": \"dark\"}".write(to: opencodeConfig, atomically: true, encoding: .utf8)
        let coordinator = makeCoordinator(home: home)

        coordinator.preview(endpoint: endpoint)
        XCTAssertEqual(coordinator.plans.count, 1)
        XCTAssertNotNil(coordinator.previewHash)

        let hash = coordinator.previewHash!
        let transaction = coordinator.confirm(endpoint: endpoint, previewHash: hash)

        XCTAssertNotNil(transaction)
        XCTAssertEqual(transaction?.receipts.count, 1)
        XCTAssertTrue(transaction?.failures.isEmpty == true)
        XCTAssertEqual(transaction?.resultSummary, "Wired 1 client to qwen3-8b.")
        let written = try String(contentsOf: opencodeConfig)
        XCTAssertEqual(try JSONCTolerant.parse(written)["model"] as? String, "mlx-local/qwen3-8b")
        let backup = try XCTUnwrap(transaction?.receipts.first?.backupPath)
        XCTAssertEqual(try String(contentsOfFile: backup), "{\"theme\": \"dark\"}")

        coordinator.rollback()

        XCTAssertEqual(try String(contentsOf: opencodeConfig), "{\"theme\": \"dark\"}")
        XCTAssertEqual(coordinator.transactions.first?.rolledBackAt != nil, true)
        XCTAssertFalse(coordinator.rollbackAvailable)
    }

    func testConfirmRejectsHashMismatchWithoutWriting() throws {
        let home = try makeHome()
        let configDir = home.appendingPathComponent(".config/zed")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let coordinator = makeCoordinator(home: home)
        coordinator.preview(endpoint: endpoint)
        let configPath = configDir.appendingPathComponent("settings.json").path

        let result = coordinator.confirm(endpoint: endpoint, previewHash: "bogus")

        XCTAssertNil(result)
        XCTAssertEqual(coordinator.lastError, WiringError.previewHashMismatch.errorDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))
    }

    func testConfirmSkipsClientWhoseFileChangedAfterPreview() throws {
        let home = try makeHome()
        let opencodeConfig = home.appendingPathComponent(".config/opencode/opencode.jsonc")
        try FileManager.default.createDirectory(at: opencodeConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"theme\": \"dark\"}".write(to: opencodeConfig, atomically: true, encoding: .utf8)
        let coordinator = makeCoordinator(home: home)
        coordinator.preview(endpoint: endpoint)

        // User edits the file between preview and confirm.
        try "{\"theme\": \"light\"}".write(to: opencodeConfig, atomically: true, encoding: .utf8)
        let transaction = coordinator.confirm(endpoint: endpoint, previewHash: coordinator.previewHash!)

        XCTAssertEqual(transaction?.receipts.count, 0)
        XCTAssertEqual(transaction?.failures.count, 1)
        XCTAssertTrue(transaction?.failures.first?.contains("changed after the preview") == true)
        XCTAssertEqual(transaction?.failures, ["opencode: the config file changed after the preview; preview again."])
        XCTAssertEqual(transaction?.resultSummary, "No clients were wired. 1 client failed.")
        XCTAssertFalse(coordinator.rollbackAvailable)
        // The user's edit is untouched.
        XCTAssertEqual(try String(contentsOf: opencodeConfig), "{\"theme\": \"light\"}")
    }

    func testPartialWiringReportsSuccessWithoutRepeatingFailureDetails() throws {
        let home = try makeHome()
        let opencode = home.appendingPathComponent(".config/opencode/opencode.jsonc")
        let zed = home.appendingPathComponent(".config/zed/settings.json")
        for config in [opencode, zed] {
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "{}".write(to: config, atomically: true, encoding: .utf8)
        }
        let coordinator = makeCoordinator(home: home)
        coordinator.preview(endpoint: endpoint)
        try "{\"theme\":\"light\"}".write(to: opencode, atomically: true, encoding: .utf8)
        let transaction = try XCTUnwrap(coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash)))
        XCTAssertEqual(transaction.receipts.map(\.clientID), ["zed"])
        XCTAssertEqual(transaction.failures, ["opencode: the config file changed after the preview; preview again."])
        XCTAssertEqual(transaction.resultSummary, "Wired 1 of 2 clients to qwen3-8b. 1 client failed.")
        XCTAssertEqual(coordinator.lastError, transaction.failures.first)
        XCTAssertTrue(coordinator.rollbackAvailable)
        XCTAssertEqual(try String(contentsOf: opencode), "{\"theme\":\"light\"}")
        XCTAssertNotNil(try JSONCTolerant.parse(String(contentsOf: zed))["language_models"])
        coordinator.rollback()
        XCTAssertEqual(try String(contentsOf: zed), "{}")
        XCTAssertEqual(try String(contentsOf: opencode), "{\"theme\":\"light\"}")
    }

    func testGenericApplyFailureKeepsClientAttributionAndConfigContents() throws {
        let home = try makeHome()
        let config = home.appendingPathComponent(".config/opencode/opencode.jsonc")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "{}"
        try original.write(to: config, atomically: true, encoding: .utf8)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = config.appendingPathExtension("mlxmac-backup-\(formatter.string(from: date))")
        try "existing backup".write(to: backup, atomically: true, encoding: .utf8)
        let coordinator = WiringCoordinator(home: home,
            store: JSONStore<WiringTransaction>(fileURL: temporaryURL("transactions.json")), now: { date })
        coordinator.preview(endpoint: endpoint)
        let transaction = try XCTUnwrap(coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash)))
        XCTAssertTrue(transaction.receipts.isEmpty)
        let failure = try XCTUnwrap(transaction.failures.first)
        XCTAssertTrue(failure.hasPrefix("opencode: "))
        XCTAssertEqual(failure.components(separatedBy: "opencode: ").count, 2)
        XCTAssertEqual(try String(contentsOf: config), original)
        XCTAssertEqual(try String(contentsOf: backup), "existing backup")
    }

    func testWiringOutcomePluralCountsAndEmptyOutcome() {
        let receipt = ClientEditReceipt(clientID: "zed", configPath: "/unused", backupPath: nil, appliedAt: Date())
        var transaction = WiringTransaction(id: UUID(), previewHash: "", endpointBaseURL: endpoint.baseURL,
            modelName: endpoint.modelName, appliedAt: Date(), receipts: [], failures: [], rolledBackAt: nil)
        XCTAssertEqual(transaction.resultSummary, "No clients were wired.")
        transaction.failures = ["one", "two"]
        XCTAssertEqual(transaction.resultSummary, "No clients were wired. 2 clients failed.")
        transaction.receipts = [receipt]
        XCTAssertEqual(transaction.resultSummary, "Wired 1 of 3 clients to qwen3-8b. 2 clients failed.")
        transaction.receipts = [receipt, receipt]
        transaction.failures = []
        XCTAssertEqual(transaction.resultSummary, "Wired 2 clients to qwen3-8b.")
    }

    func testNewConfigIsCreatedAndItsFailureWouldRemoveTheFile() throws {
        let home = try makeHome()
        let configDir = home.appendingPathComponent(".config/zed")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let coordinator = makeCoordinator(home: home)
        coordinator.preview(endpoint: endpoint)

        let plan = try XCTUnwrap(coordinator.plans.first { $0.clientID == "zed" })
        XCTAssertNil(plan.before)
        XCTAssertTrue(plan.summary.contains("Create config"))

        let transaction = coordinator.confirm(endpoint: endpoint, previewHash: coordinator.previewHash!)
        XCTAssertEqual(transaction?.receipts.count, 1)
        XCTAssertNil(transaction?.receipts.first?.backupPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.configPath))
    }

    func testRollbackMovesCreatedConfigToTrash() throws {
        let home = try makeHome()
        let config = home.appendingPathComponent(".config/zed/settings.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let storeURL = temporaryURL("transactions.json")
        let coordinator = makeCoordinator(home: home, store: JSONStore<WiringTransaction>(fileURL: storeURL))
        coordinator.preview(endpoint: endpoint)
        let transaction = coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash))
        XCTAssertNotNil(transaction?.receipts.first?.createdFileSHA256)
        XCTAssertNil(coordinator.persistenceError)
        let written = try String(contentsOf: config)
        let reloaded = makeCoordinator(home: home, store: JSONStore<WiringTransaction>(fileURL: storeURL))

        reloaded.rollback()

        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
        XCTAssertEqual(try String(contentsOf: trash(home).appendingPathComponent("settings.json")), written)
        XCTAssertNotNil(reloaded.transactions.first?.rolledBackAt)
        XCTAssertEqual(reloaded.transactions.first?.failures, [])
        XCTAssertNil(reloaded.lastError)
        XCTAssertFalse(reloaded.rollbackAvailable)
    }

    func testRollbackMovesCreatedOpencodeConfigToTrashAfterOpencodeLoadsIt() throws {
        let home = try makeHome()
        let directory = home.appendingPathComponent(".config/opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = directory.appendingPathComponent("opencode.json")
        let original = "{\"theme\": \"dark\"}"
        try original.write(to: existing, atomically: true, encoding: .utf8)
        let created = directory.appendingPathComponent("opencode.jsonc")
        let coordinator = makeCoordinator(home: home)
        coordinator.preview(endpoint: endpoint)
        XCTAssertEqual(coordinator.plans.map(\.configPath), [created.path])
        XCTAssertNotNil(coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash)))
        let written = try String(contentsOf: created)
        try loadAsOpencode(created)
        XCTAssertEqual(try String(contentsOf: created), written)

        coordinator.rollback()

        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path))
        XCTAssertEqual(try String(contentsOf: trash(home).appendingPathComponent("opencode.jsonc")), written)
        XCTAssertEqual(try String(contentsOf: existing), original)
        XCTAssertEqual(coordinator.transactions.first?.failures, [])
        XCTAssertNil(coordinator.lastError)
    }

    func testRollbackKeepsCreatedConfigWhenTrashFails() throws {
        let home = try makeHome()
        let config = home.appendingPathComponent(".config/zed/settings.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let coordinator = makeCoordinator(home: home, moveToTrash: { _ in throw CocoaError(.fileWriteNoPermission) })
        coordinator.preview(endpoint: endpoint)
        XCTAssertNotNil(coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash)))
        let written = try String(contentsOf: config)

        coordinator.rollback()

        XCTAssertEqual(try String(contentsOf: config), written)
        XCTAssertNotNil(coordinator.transactions.first?.rolledBackAt)
        XCTAssertEqual(coordinator.transactions.first?.failures.count, 1)
        XCTAssertNotNil(coordinator.lastError)
    }

    func testRollbackKeepsUnreadableConfigThatExistedBeforeWiring() throws {
        let home = try makeHome()
        let config = home.appendingPathComponent(".config/zed/settings.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x7B, 0xC3, 0x28, 0x7D]).write(to: config)
        let coordinator = makeCoordinator(home: home)
        coordinator.preview(endpoint: endpoint)
        let transaction = coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash))
        XCTAssertEqual(transaction?.receipts.count, 1)
        XCTAssertNil(transaction?.receipts.first?.createdFileSHA256)

        coordinator.rollback()

        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash(home).path))
    }

    func testRollbackKeepsCreatedConfigEditedAfterWiring() throws {
        let home = try makeHome()
        let config = home.appendingPathComponent(".config/zed/settings.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let coordinator = makeCoordinator(home: home)
        coordinator.preview(endpoint: endpoint)
        XCTAssertNotNil(coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash)))
        let edited = "{\"theme\": \"light\"}"
        try edited.write(to: config, atomically: true, encoding: .utf8)

        coordinator.rollback()

        XCTAssertEqual(try String(contentsOf: config), edited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash(home).path))
        XCTAssertNotNil(coordinator.transactions.first?.rolledBackAt)
        XCTAssertEqual(coordinator.transactions.first?.failures,
                       ["zed: \(WiringError.createdFileChanged.errorDescription ?? "")"])
        XCTAssertEqual(coordinator.lastError, coordinator.transactions.first?.failures.first)
    }

    func testRollbackRefusesSymlinkAtCreatedConfig() throws {
        let home = try makeHome()
        let config = home.appendingPathComponent(".config/zed/settings.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let coordinator = makeCoordinator(home: home)
        coordinator.preview(endpoint: endpoint)
        XCTAssertNotNil(coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash)))
        let written = try String(contentsOf: config)
        let victim = home.appendingPathComponent("victim.json")
        try written.write(to: victim, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: victim)

        coordinator.rollback()

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: config.path), victim.path)
        XCTAssertEqual(try String(contentsOf: victim), written)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash(home).path))
        XCTAssertEqual(coordinator.transactions.first?.failures.count, 1)
        XCTAssertNotNil(coordinator.lastError)
    }

    func testRollbackOfCreatedConfigAlreadyRemovedRecordsNoFailure() throws {
        let home = try makeHome()
        let config = home.appendingPathComponent(".config/zed/settings.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let coordinator = makeCoordinator(home: home)
        coordinator.preview(endpoint: endpoint)
        XCTAssertNotNil(coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash)))
        try FileManager.default.removeItem(at: config)

        coordinator.rollback()

        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash(home).path))
        XCTAssertNotNil(coordinator.transactions.first?.rolledBackAt)
        XCTAssertEqual(coordinator.transactions.first?.failures, [])
        XCTAssertNil(coordinator.lastError)
    }

    func testLegacyTransactionWithoutCreatedFieldKeepsCreatedConfigOnRollback() throws {
        let home = try makeHome()
        let config = home.appendingPathComponent(".config/zed/settings.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = "{\"language_models\": {}}"
        try contents.write(to: config, atomically: true, encoding: .utf8)
        let storeURL = temporaryURL("transactions.json")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = """
        [{"appliedAt":0,"endpointBaseURL":"http://127.0.0.1:8766/v1","failures":[],"id":"\(UUID().uuidString)",\
        "modelName":"qwen3-8b","previewHash":"legacy","receipts":[{"appliedAt":0,"clientID":"zed","configPath":"\(config.path)"}]}]
        """
        try legacy.write(to: storeURL, atomically: true, encoding: .utf8)
        let coordinator = makeCoordinator(home: home, store: JSONStore<WiringTransaction>(fileURL: storeURL))
        let receipt = try XCTUnwrap(coordinator.transactions.first?.receipts.first)
        XCTAssertNil(receipt.backupPath)
        XCTAssertNil(receipt.createdFileSHA256)

        coordinator.rollback()

        XCTAssertEqual(try String(contentsOf: config), contents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash(home).path))
        XCTAssertNotNil(coordinator.transactions.first?.rolledBackAt)
        XCTAssertEqual(coordinator.transactions.first?.failures, [])
        XCTAssertNil(coordinator.lastError)
    }

    func testUndetectedClientsProduceNoPlans() throws {
        let home = try makeHome()
        let coordinator = makeCoordinator(home: home)

        coordinator.preview(endpoint: endpoint)

        XCTAssertTrue(coordinator.installations.isEmpty)
        XCTAssertTrue(coordinator.plans.isEmpty)
        XCTAssertNil(coordinator.confirm(endpoint: endpoint, previewHash: "anything"))
        XCTAssertEqual(coordinator.lastError, WiringError.noPlansPreviewed.errorDescription)
    }

    func testSymlinkedConfigIsRefusedNotWrittenThrough() throws {
        let home = try makeHome()
        let opencodeConfig = home.appendingPathComponent(".config/opencode/opencode.jsonc")
        try FileManager.default.createDirectory(at: opencodeConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        let victim = home.appendingPathComponent("victim.json")
        try "{\"theme\": \"dark\"}".write(to: victim, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: opencodeConfig, withDestinationURL: victim
        )
        let coordinator = makeCoordinator(home: home)

        coordinator.preview(endpoint: endpoint)
        let transaction = coordinator.confirm(endpoint: endpoint, previewHash: coordinator.previewHash!)

        // The plan reads through the link, so `before` matches the victim's
        // content; the write itself must refuse and never touch the victim.
        XCTAssertEqual(transaction?.receipts.count, 0)
        XCTAssertTrue(transaction?.failures.contains { $0.contains("symbolic link") } == true)
        XCTAssertEqual(try String(contentsOf: victim), "{\"theme\": \"dark\"}")
    }

    // MARK: - Hashing, diff, redaction

    func testPreviewHashIsDeterministicAndEndpointSensitive() {
        let plan = ClientEditPlan(
            clientID: "zed", displayName: "Zed", configPath: "/x/settings.json",
            before: nil, after: "{\"a\":1}\n", summary: "", rewritesFile: false
        )
        let first = WiringCoordinator.hash(plans: [plan], endpoint: endpoint)
        let same = WiringCoordinator.hash(plans: [plan], endpoint: endpoint)
        let other = WiringCoordinator.hash(plans: [plan], endpoint: WireEndpoint(baseURL: endpoint.baseURL, modelName: "other"))
        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, other)
    }

    func testLineDiffShowsAddedRemovedAndContext() {
        let diff = LineDiff.diff(before: "a\nb\nc", after: "a\nx\nc")
        XCTAssertEqual(diff, [
            DiffLine(kind: .context, text: "a"),
            DiffLine(kind: .removed, text: "b"),
            DiffLine(kind: .added, text: "x"),
            DiffLine(kind: .context, text: "c"),
        ])
    }

    func testSecretValuesAreRedactedInDiffLines() {
        let plan = ClientEditPlan(
            clientID: "zed", displayName: "Zed", configPath: "/x",
            before: nil,
            after: "\"api_key\": \"sk-supersecret\"",
            summary: "", rewritesFile: false
        )
        let diff = plan.redactedDiff
        XCTAssertTrue(diff.allSatisfy { !$0.text.contains("sk-supersecret") })
        XCTAssertTrue(diff.contains { $0.text.contains("•••") })
    }

    // MARK: - Helpers

    private var storeURL: URL!
    private var homeURL: URL?

    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        homeURL = url
        return url
    }

    private func makeCoordinator(
        home: URL, store: JSONStore<WiringTransaction>? = nil, moveToTrash: ((URL) throws -> Void)? = nil
    ) -> WiringCoordinator {
        let trashDirectory = trash(home)
        return WiringCoordinator(
            home: home,
            store: store ?? JSONStore<WiringTransaction>(fileURL: temporaryURL("transactions.json")),
            moveToTrash: moveToTrash ?? { url in
                try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: trashDirectory.appendingPathComponent(url.lastPathComponent))
            }
        )
    }

    /// Mirrors opencode loading a config: one without a `$schema` is rewritten with it inserted first.
    private func loadAsOpencode(_ url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard (try JSONCTolerant.parse(text)["$schema"] as? String ?? "").isEmpty,
              let brace = text.range(of: #"^\s*\{"#, options: .regularExpression) else { return }
        try text.replacingCharacters(in: brace, with: "{\n  \"$schema\": \"https://opencode.ai/config.json\",")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Stands in for the macOS Trash so tests never touch the user's real one.
    private func trash(_ home: URL) -> URL {
        home.appendingPathComponent("Trash", isDirectory: true)
    }

    private nonisolated func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-wiring-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }
}
