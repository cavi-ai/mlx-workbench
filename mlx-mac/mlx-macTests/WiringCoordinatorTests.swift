import Foundation
import XCTest

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
