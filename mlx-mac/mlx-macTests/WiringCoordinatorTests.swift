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
        host.clientWiringRequest = ClientWiringRequest(modelPath: server.path!, preferredPort: 8766)
        let view = NSHostingView(rootView: WireView(appHost: host).environment(\.isRouteActive, true)
            .frame(width: 720, height: 720).background(WorkbenchColor.canvas).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        for _ in 0..<10 {
            if host.clientWiringRequest == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(host.clientWiringRequest)
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
        // The user's edit is untouched.
        XCTAssertEqual(try String(contentsOf: opencodeConfig), "{\"theme\": \"light\"}")
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

    private func makeCoordinator(home: URL) -> WiringCoordinator {
        WiringCoordinator(
            home: home,
            store: JSONStore<WiringTransaction>(fileURL: temporaryURL("transactions.json"))
        )
    }

    private nonisolated func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-wiring-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }
}
