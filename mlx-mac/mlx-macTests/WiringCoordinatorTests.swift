import Foundation
import XCTest
import AppKit
import SwiftUI

@testable import mlx_workbench

@MainActor
final class WiringCoordinatorTests: XCTestCase {
    private let endpoint = WireEndpoint(baseURL: "http://127.0.0.1:8766/v1", modelName: "qwen3-8b")

    func testRollbackPreservesEditsToAnExistingConfig() throws {
        let home = try makeHome()
        let config = home.appendingPathComponent(".config/zed/settings.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"theme\":\"dark\"}".write(to: config, atomically: true, encoding: .utf8)
        let coordinator = makeCoordinator(home: home)
        coordinator.preview(endpoint: endpoint)
        _ = coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash))
        let edited = "{\"theme\":\"light\"}"
        try edited.write(to: config, atomically: true, encoding: .utf8)

        coordinator.rollback()

        XCTAssertEqual(try String(contentsOf: config), edited)
        XCTAssertNotNil(coordinator.lastError)
        XCTAssertTrue(coordinator.rollbackAvailable)
        XCTAssertNil(coordinator.transactions.first?.rolledBackAt)
    }

    func testFailedRollbackCanRetryWithoutTouchingAlreadyRestoredConfigs() throws {
        let home = try makeHome()
        let store = JSONStore<WiringTransaction>(fileURL: temporaryURL("retry.json"))
        let coordinator = makeCoordinator(home: home, store: store, moveToTrash: { url in
            if url.lastPathComponent == "settings.json" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        })
        coordinator.preview(endpoint: endpoint, clientIDs: ["opencode", "zed"])
        _ = coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash))
        coordinator.rollback()
        XCTAssertTrue(coordinator.rollbackAvailable)
        let restored = home.appendingPathComponent(".config/opencode/opencode.jsonc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.path))
        try "{\"new_config\":true}".write(to: restored, atomically: true, encoding: .utf8)
        let reloaded = makeCoordinator(home: home, store: store)
        reloaded.rollback()
        XCTAssertFalse(reloaded.rollbackAvailable)
        XCTAssertNil(reloaded.lastError)
        XCTAssertEqual(try String(contentsOf: restored), "{\"new_config\":true}")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/zed/settings.json").path))
    }

    func testServingStatusPreservesAuthenticationAndRejectsMalformedKeyMetadata() throws {
        let digest = String(repeating: "a", count: 64)
        let row: [String: Any] = ["repo": "org/protected", "runtime": "mlx_lm", "port": 8766,
                                  "pid": 123, "state": "running", "api_key_sha256": digest]
        let server = try XCTUnwrap(WorkbenchAPI.servers(from: ["servers": [row]])?.first)
        XCTAssertEqual(server.apiKeySHA256, digest)
        let malformedValues: [Any] = [42, true, "", "plaintext-not-a-digest"]
        for malformed in malformedValues {
            var changed = row; changed["api_key_sha256"] = malformed
            XCTAssertNil(WorkbenchAPI.servers(from: ["servers": [changed]]))
        }
        var unprotected = row; unprotected["api_key_sha256"] = NSNull()
        XCTAssertNil(try XCTUnwrap(WorkbenchAPI.servers(from: ["servers": [unprotected]])?.first).apiKeySHA256)
    }

    func testMalformedAuthenticationStatusDoesNotBecomeAnEmptyInventory() async throws {
        let home = try makeHome()
        let script = home.appendingPathComponent("scripts/mlx-agent")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        import json
        print(json.dumps({"status":"ok","data":{"servers":[{"repo":"org/protected","runtime":"mlx_lm","port":8766,"pid":123,"state":"running","api_key_sha256":42}]}}))
        """.write(to: script, atomically: true, encoding: .utf8)
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: home.path)
        do {
            _ = try await api.serveStatus()
            XCTFail("Malformed authentication status must remain unavailable")
        } catch BridgeError.remote(let code, _, _) {
            XCTAssertEqual(code, "invalid_service_inventory")
        }
    }

    func testProtectedServerCanBeSelectedWithoutReadingItsKey() throws {
        let server = ServerInfo(repo: "org/protected", runtime: "mlx_lm", port: 8766, pid: 123,
                                state: "running", apiKeySHA256: String(repeating: "a", count: 64))
        let request = try XCTUnwrap(ClientWiringRequest.forServer(server))
        XCTAssertEqual(request.expectedServer, server)
        XCTAssertEqual(ClientWiringSelection.matchingServers(request: request, servers: [server]), [server])
    }

    func testProtectedConfigWritesOnlyInferenceKeyAndKeepsHistoryRedacted() async throws {
        let key = "mlxw_fixture_inference_01234567890123456789"
        let server = protectedServer(key: key)
        let home = try makeHome()
        let storeURL = home.appendingPathComponent("history.json")
        let coordinator = WiringCoordinator(home: home, store: JSONStore(fileURL: storeURL), credential: { _ in key })
        await coordinator.preview(server: server, clientIDs: ["opencode", "aider"])
        XCTAssertEqual(coordinator.plans.count, 2, coordinator.lastError ?? "")
        for plan in coordinator.plans {
            XCTAssertFalse(plan.redactedDiff.contains { $0.text.contains(key) })
            XCTAssertFalse(plan.summary.contains(key))
        }
        let hash = try XCTUnwrap(coordinator.previewHash)
        let applied = await coordinator.confirm(server: server, previewHash: hash, currentServers: { [server] })
        let transaction = try XCTUnwrap(applied)
        XCTAssertEqual(transaction.receipts.count, 2)
        for receipt in transaction.receipts {
            let url = URL(fileURLWithPath: receipt.configPath)
            let contents = try String(contentsOf: url)
            XCTAssertTrue(contents.contains(key))
            XCTAssertFalse(contents.contains("control-key"))
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode.map { $0 & 0o777 }, 0o600)
        }
        XCTAssertFalse(try String(contentsOf: storeURL).contains(key))
    }

    func testProtectedPreviewRefusesMissingOrMismatchedKeyWithoutLeakingErrors() async throws {
        let key = "mlxw_fixture_inference_01234567890123456789"
        let server = protectedServer(key: key)
        let lookups: [(String) throws -> String] = [
            { _ in throw NSError(domain: key, code: 1) },
            { _ in "mlxw_wrong_key_012345678901234567890123456" },
        ]
        for lookup in lookups {
            let home = try makeHome()
            let coordinator = WiringCoordinator(home: home,
                store: JSONStore(fileURL: home.appendingPathComponent("history.json")), credential: lookup)
            await coordinator.preview(server: server, clientIDs: ["opencode"])
            XCTAssertTrue(coordinator.plans.isEmpty)
            XCTAssertNil(coordinator.previewHash)
            XCTAssertNotNil(coordinator.lastError)
            XCTAssertFalse(coordinator.lastError?.contains(key) == true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode/opencode.jsonc").path))
        }
    }

    func testProtectedConfirmationRefusesRotatedKeyAndMissingCredential() async throws {
        let key = "mlxw_fixture_inference_01234567890123456789"
        let server = protectedServer(key: key)
        let rotated = protectedServer(key: "mlxw_rotated_0123456789012345678901234567")
        for changed in [false, true] {
            let home = try makeHome()
            var available = true
            let coordinator = WiringCoordinator(home: home,
                store: JSONStore(fileURL: home.appendingPathComponent("history.json")), credential: { _ in
                    guard available else { throw CocoaError(.fileReadNoPermission) }; return key
                })
            await coordinator.preview(server: server, clientIDs: ["opencode"])
            let hash = try XCTUnwrap(coordinator.previewHash)
            available = changed
            let result = await coordinator.confirm(server: server, previewHash: hash, currentServers: { [changed ? rotated : server] })
            XCTAssertNil(result)
            XCTAssertTrue(coordinator.transactions.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode/opencode.jsonc").path))
        }
    }

    func testProtectedZedReviewKeepsKeyOutOfSettingsAndExplainsNativeSetup() async throws {
        let key = "mlxw_fixture_inference_01234567890123456789"
        let home = try makeHome()
        let coordinator = WiringCoordinator(home: home,
            store: JSONStore(fileURL: home.appendingPathComponent("history.json")), credential: { _ in key })
        await coordinator.preview(server: protectedServer(key: key), clientIDs: ["zed"])
        let plan = try XCTUnwrap(coordinator.plans.first)
        XCTAssertFalse(plan.after.contains(key))
        XCTAssertFalse(plan.after.contains("api_key"))
        XCTAssertNotNil(plan.credentialInstruction)
    }

    func testProtectedBackupAndRollbackKeepOwnerOnlyPermissions() async throws {
        let key = "mlxw_fixture_inference_01234567890123456789"
        let server = protectedServer(key: key)
        let home = try makeHome()
        let config = home.appendingPathComponent(".config/opencode/opencode.jsonc")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "{\"theme\":\"dark\"}"
        try original.write(to: config, atomically: true, encoding: .utf8)
        let coordinator = WiringCoordinator(home: home,
            store: JSONStore(fileURL: home.appendingPathComponent("history.json")), credential: { _ in key })
        await coordinator.preview(server: server, clientIDs: ["opencode"])
        let hash = try XCTUnwrap(coordinator.previewHash)
        let applied = await coordinator.confirm(server: server, previewHash: hash, currentServers: { [server] })
        let transaction = try XCTUnwrap(applied)
        let backup = try XCTUnwrap(transaction.receipts.first?.backupPath)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: backup)[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
        coordinator.rollback()
        XCTAssertEqual(try String(contentsOf: config), original)
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
    }

    func testProtectedKeyTransferRechecksIdentityAndNeverReturnsControlMaterial() async throws {
        let key = "mlxw_fixture_inference_01234567890123456789"
        let server = protectedServer(key: key)
        let home = try makeHome()
        let coordinator = WiringCoordinator(home: home,
            store: JSONStore(fileURL: home.appendingPathComponent("history.json")), credential: { _ in key })
        let transferred = try await coordinator.inferenceKey(server: server, currentServers: { [server] })
        XCTAssertEqual(transferred, key)
        let changed = ServerInfo(repo: "org/protected", runtime: "mlx_lm", port: 8766, pid: 999,
                                 state: "running", apiKeySHA256: EndpointCredentialStore.digest(key))
        for current in [[changed], [server, server], []] {
            do {
                _ = try await coordinator.inferenceKey(server: server, currentServers: { current })
                XCTFail("A changed or ambiguous endpoint cannot transfer a credential")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains(key))
            }
        }
        XCTAssertTrue(coordinator.transactions.isEmpty)
    }

    func testAiderProtectedPlanQuotesKeyAndReplacesEveryOldKey() async throws {
        let key = "mlxw_quoted_key_01234567890123456789\"#:$"
        let server = protectedServer(key: key)
        let home = try makeHome()
        let config = home.appendingPathComponent(".aider.conf.yml")
        try "# retain this comment\nopenai-api-key: old-one\nother: true\nopenai-api-key: old-two\n".write(to: config, atomically: true, encoding: .utf8)
        let coordinator = WiringCoordinator(home: home,
            store: JSONStore(fileURL: home.appendingPathComponent("history.json")), credential: { _ in key })
        await coordinator.preview(server: server, clientIDs: ["aider"])
        let plan = try XCTUnwrap(coordinator.plans.first)
        let keys = plan.after.split(separator: "\n").filter { $0.hasPrefix("openai-api-key:") }
        XCTAssertEqual(keys.count, 1)
        let encoded = keys[0].dropFirst("openai-api-key:".count).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(encoded.utf8), options: .fragmentsAllowed) as? String, key)
        XCTAssertTrue(plan.after.contains("# retain this comment"))
        XCTAssertTrue(plan.after.contains("other: true"))
        XCTAssertFalse(plan.redactedDiff.contains { $0.text.contains("old-one") || $0.text.contains("old-two") || $0.text.contains("quoted_key") })
    }

    func testProtectedLookupCanBeCancelledWithoutPublishingAReview() async throws {
        let key = "mlxw_fixture_inference_01234567890123456789"
        let server = protectedServer(key: key)
        let entered = expectation(description: "credential lookup started")
        let home = try makeHome()
        let coordinator = WiringCoordinator(home: home,
            store: JSONStore(fileURL: home.appendingPathComponent("history.json")), credential: { _ in
                entered.fulfill()
                try await Task.sleep(for: .seconds(60))
                return key
            })
        let pending = Task { await coordinator.preview(server: server, clientIDs: ["opencode"]) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(coordinator.isCheckingServer)
        XCTAssertTrue(coordinator.plans.isEmpty)
        pending.cancel()
        await pending.value
        XCTAssertFalse(coordinator.isCheckingServer)
        XCTAssertNil(coordinator.previewHash)
        XCTAssertTrue(coordinator.plans.isEmpty)
        XCTAssertNil(coordinator.lastError)
    }

    private func protectedServer(key: String) -> ServerInfo {
        ServerInfo(repo: "org/protected", runtime: "mlx_lm", port: 8766, pid: 123,
                   state: "running", apiKeySHA256: EndpointCredentialStore.digest(key))
    }

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
        XCTAssertNil(parsed["provider"])
        let local = try XCTUnwrap((parsed["providers"] as? [String: Any])?["mlx-agent"] as? [String: Any])
        XCTAssertEqual(local["name"] as? String, "mlx-agent (local)")
        XCTAssertEqual(local["package"] as? String, "aisdk:@ai-sdk/openai-compatible")
        XCTAssertNil(local["npm"])
        XCTAssertNil(local["options"])
        XCTAssertEqual((local["settings"] as? [String: Any])?["baseURL"] as? String, "http://127.0.0.1:8766/v1")
        XCTAssertEqual((local["settings"] as? [String: Any])?["apiKey"] as? String, "workbench")
        XCTAssertEqual((local["models"] as? [String: Any])?.keys.sorted(), ["qwen3-8b"])
        XCTAssertEqual(parsed["model"] as? String, "mlx-agent/qwen3-8b")
    }

    func testOpencodePlanMigratesLegacyMlxLocalKeepingModelSettings() throws {
        let before = """
        {"provider": {
          "mlx-local": {"npm": "@ai-sdk/openai-compatible", "options": {"baseURL": "http://127.0.0.1:8766/v1"},
            "models": {"qwen3-8b": {"limit": {"context": 32768}}, "gone": {"name": "Gone"}}},
          "ollama": {"options": {"baseURL": "http://127.0.0.1:11434/v1"}, "models": {"llama3": {}}}}}
        """
        let parsed = try JSONCTolerant.parse(ClientAdapters.opencode.plan(before, endpoint))
        let legacy = try XCTUnwrap(parsed["provider"] as? [String: Any])
        XCTAssertEqual(legacy.keys.sorted(), ["ollama"])
        let models = try XCTUnwrap(((parsed["providers"] as? [String: Any])?["mlx-agent"] as? [String: Any])?["models"] as? [String: Any])
        XCTAssertEqual(models.keys.sorted(), ["qwen3-8b"])
        XCTAssertEqual(((models["qwen3-8b"] as? [String: Any])?["limit"] as? [String: Any])?["context"] as? Int, 32768)

        let onlyLegacy = #"{"provider": {"mlx-local": {"options": {"baseURL": "http://127.0.0.1:8766/v1"}, "models": {"qwen3-8b": {}}}}}"#
        XCTAssertNil(try JSONCTolerant.parse(ClientAdapters.opencode.plan(onlyLegacy, endpoint))["provider"])
    }

    func testOpencodePlanRetainsLegacyModelOverridesWhenRewiring() throws {
        let before = """
        {"provider": {
          "mlx-local": {"npm": "@ai-sdk/openai-compatible", "api": "http://127.0.0.1:8765/v1", "options": {"timeout": 45000},
            "models": {"qwen3-8b": {"id": "qwen3-8b-original", "tool_call": true,
              "variants": {"high": {"reasoningEffort": "high"}}}}}}}
        """
        let token = "mlxw_" + String(repeating: "b", count: 64)
        let protected = WireEndpoint(baseURL: endpoint.baseURL, modelName: endpoint.modelName,
            apiKeySHA256: EndpointCredentialStore.digest(token))
        let parsed = try JSONCTolerant.parse(ClientAdapters.opencode.authenticatedPlan(before, protected, key: token))
        let providers = try XCTUnwrap(parsed["provider"] as? [String: Any])
        let local = try XCTUnwrap(providers["mlx-local"] as? [String: Any])
        let settings = try XCTUnwrap(local["options"] as? [String: Any])
        let model = try XCTUnwrap((local["models"] as? [String: Any])?["qwen3-8b"] as? [String: Any])
        XCTAssertEqual(parsed["model"] as? String, "mlx-local/qwen3-8b")
        XCTAssertEqual(local["api"] as? String, endpoint.baseURL)
        XCTAssertEqual(settings["baseURL"] as? String, endpoint.baseURL)
        XCTAssertEqual(settings["apiKey"] as? String, token)
        XCTAssertEqual(settings["timeout"] as? Int, 45000)
        XCTAssertEqual(model["id"] as? String, "qwen3-8b-original")
        XCTAssertEqual(model["tool_call"] as? Bool, true)
        XCTAssertEqual((model["variants"] as? [String: [String: String]])?["high"]?["reasoningEffort"], "high")
    }

    func testOpencodePlanPreservesUnrelatedKeysAndCommentsAreNormalized() throws {
        let before = "{\n  // keep this intent\n  \"theme\": \"dark\",\n}\n"
        let after = try ClientAdapters.opencode.plan(before, endpoint)
        let parsed = try JSONCTolerant.parse(after)
        XCTAssertEqual(parsed["theme"] as? String, "dark")
        XCTAssertEqual(parsed["model"] as? String, "mlx-agent/qwen3-8b")
    }

    func testOpencodePlanDropsAliasMovesBaseURLAndKeepsOtherProviders() throws {
        let before = """
        {"providers": {
          "mlx-agent": {"name": "mlx-agent (local)", "package": "aisdk:@ai-sdk/openai-compatible",
            "settings": {"baseURL": "http://127.0.0.1:8765/v1", "encoding": "none", "timeout": 45000},
            "models": {"qwen3-8b-alias": {"name": "Qwen alias"}, "qwen3-8b": {"limit": {"context": 32768, "output": 4096}}}},
          "ollama": {"settings": {"baseURL": "http://127.0.0.1:11434/v1"}, "models": {"llama3": {}}}},
         "model": "ollama/llama3"}
        """
        let parsed = try JSONCTolerant.parse(ClientAdapters.opencode.plan(before, endpoint))
        let providers = try XCTUnwrap(parsed["providers"] as? [String: Any])
        let local = try XCTUnwrap(providers["mlx-agent"] as? [String: Any])
        let models = try XCTUnwrap(local["models"] as? [String: Any])
        XCTAssertEqual(models.keys.sorted(), ["qwen3-8b"])
        XCTAssertEqual(((models["qwen3-8b"] as? [String: Any])?["limit"] as? [String: Any])?["context"] as? Int, 32768)
        let settings = try XCTUnwrap(local["settings"] as? [String: Any])
        XCTAssertEqual(settings["baseURL"] as? String, "http://127.0.0.1:8766/v1")
        XCTAssertEqual(settings["encoding"] as? String, "none")
        XCTAssertEqual(settings["timeout"] as? Int, 45000)
        XCTAssertEqual(parsed["model"] as? String, "mlx-agent/qwen3-8b")
        XCTAssertEqual(((providers["ollama"] as? [String: Any])?["models"] as? [String: Any])?.keys.sorted(), ["llama3"])
    }

    func testOpenCodeSetupCheckReadsTheMergedGlobalConfig() async throws {
        let home = try makeHome()
        let folder = home.appendingPathComponent(".config/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) throws {
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let serving = ServerInfo(repo: "qwen3-8b", runtime: "mlx_lm", port: 8766, pid: 123, state: "running")
        XCTAssertEqual(OpenCodeSetupCheck.run(home: home, servers: [serving]), .noWorkbenchEntry)
        try write("opencode.json", """
        {"provider": {"lmstudio": {"options": {"baseURL": "http://127.0.0.1:1234/v1"}, "models": {"qwen": {}}},
          "ollama": {"options": {"baseURL": "http://127.0.0.1:11434/v1"}}}, "model": "lmstudio/qwen"}
        """)
        XCTAssertEqual(OpenCodeSetupCheck.run(home: home, servers: [serving]), .noWorkbenchEntry)

        try write("config.json", #"{"provider": {"mlx-local": {"options": {"baseURL": "http://127.0.0.1:8766/v1"}, "models": {"qwen3-8b": {}}}}}"#)
        XCTAssertEqual(OpenCodeSetupCheck.run(home: home, servers: [serving]), .ready)
        XCTAssertEqual(OpenCodeSetupCheck.run(home: home, servers: []), .notServing(port: 8766))
        let other = ServerInfo(repo: "org/other", runtime: "mlx_lm", port: 8766, pid: 124, state: "running")
        XCTAssertEqual(OpenCodeSetupCheck.run(home: home, servers: [other]), .notServing(port: 8766))
        let tasks = ServerInfo(repo: "qwen3-8b", runtime: "tasks", port: 8766, pid: 125, state: "running")
        XCTAssertEqual(OpenCodeSetupCheck.run(home: home, servers: [tasks]), .notServing(port: 8766))

        try write("opencode.jsonc", #"{"provider": {"mlx-local": {"options": {"baseURL": "http://127.0.0.1:8765/v1"}}}}"#)
        XCTAssertEqual(OpenCodeSetupCheck.run(home: home, servers: [serving]), .notServing(port: 8765))
        let jsonc = try String(contentsOf: folder.appendingPathComponent("opencode.jsonc"), encoding: .utf8)
        try write("opencode.jsonc", ClientAdapters.opencode.plan(jsonc, try XCTUnwrap(WireEndpoint(server: serving))))
        XCTAssertEqual(OpenCodeSetupCheck.run(home: home, servers: [serving]), .ready)
        let checked = await makeCoordinator(home: home).openCodeSetup(servers: [serving])
        XCTAssertEqual(checked, .ready)

        try write("opencode.json", "{ not json")
        XCTAssertEqual(OpenCodeSetupCheck.run(home: home, servers: [serving]), .unreadable("opencode.json isn't valid JSON"))
    }

    func testOpencodePlanListsEveryFrontDoorModelWithTheChosenDefault() throws {
        let token = "mlxw_" + String(repeating: "f", count: 64)
        let door = WireEndpoint(baseURL: "http://127.0.0.1:8939/v1", modelName: "qwen3-8b",
                                apiKeySHA256: EndpointCredentialStore.digest(token), models: ["gemma-3", "org/coder", "qwen3-8b"])
        let parsed = try JSONCTolerant.parse(ClientAdapters.opencode.authenticatedPlan(nil, door, key: token))
        let local = try XCTUnwrap((parsed["providers"] as? [String: Any])?["mlx-agent"] as? [String: Any])
        XCTAssertNil(parsed["provider"])
        XCTAssertEqual((local["models"] as? [String: Any])?.keys.sorted(), ["gemma-3", "org/coder", "qwen3-8b"])
        XCTAssertEqual((local["settings"] as? [String: Any])?["baseURL"] as? String, "http://127.0.0.1:8939/v1")
        XCTAssertEqual((local["settings"] as? [String: Any])?["apiKey"] as? String, token)
        XCTAssertNil(local["options"])
        XCTAssertEqual(parsed["model"] as? String, "mlx-agent/qwen3-8b")
    }

    func testOpenCodeSetupCheckIsReadyOnTheProvidersShape() throws {
        let home = try makeHome()
        let folder = home.appendingPathComponent(".config/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"providers": {"mlx-agent": {"name": "mlx-agent (local)", "package": "aisdk:@ai-sdk/openai-compatible", "settings": {"baseURL": "http://127.0.0.1:8766/v1"}, "models": {"qwen3-8b": {}}}}, "model": "mlx-agent/qwen3-8b"}"#
            .write(to: folder.appendingPathComponent("opencode.jsonc"), atomically: true, encoding: .utf8)
        let serving = ServerInfo(repo: "qwen3-8b", runtime: "mlx_lm", port: 8766, pid: 123, state: "running")
        XCTAssertEqual(OpenCodeSetupCheck.run(home: home, servers: [serving]), .ready)
        XCTAssertEqual(OpenCodeSetupCheck.run(home: home, servers: []), .notServing(port: 8766))
    }

    func testOpenCodeSetupCheckIsReadyThroughTheRunningFrontDoor() throws {
        let home = try makeHome()
        let folder = home.appendingPathComponent(".config/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"provider": {"mlx-local": {"options": {"baseURL": "http://127.0.0.1:8939/v1"}, "models": {"org/coder": {}}}}, "model": "mlx-local/org/coder"}"#
            .write(to: folder.appendingPathComponent("opencode.jsonc"), atomically: true, encoding: .utf8)
        let door = WireEndpoint(baseURL: "http://127.0.0.1:8939/v1", modelName: "gemma-3",
                                apiKeySHA256: String(repeating: "a", count: 64), models: ["gemma-3", "org/coder"])
        XCTAssertEqual(OpenCodeSetupCheck.run(home: home, servers: [], frontDoor: door), .ready)
        XCTAssertEqual(OpenCodeSetupCheck.run(home: home, servers: []), .notServing(port: 8939))
        let other = WireEndpoint(baseURL: "http://127.0.0.1:8939/v1", modelName: "gemma-3",
                                 apiKeySHA256: String(repeating: "a", count: 64), models: ["gemma-3"])
        XCTAssertEqual(OpenCodeSetupCheck.run(home: home, servers: [], frontDoor: other), .notServing(port: 8939))
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

    func testExplicitClientPreviewCreatesOnlyTheChosenConfigAfterConfirmation() async throws {
        let home = try makeHome()
        let coordinator = makeCoordinator(home: home)
        coordinator.preview(endpoint: endpoint, clientIDs: ["opencode"])
        XCTAssertEqual(coordinator.plans.map(\.clientID), ["opencode"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config").path))
        let transaction = coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash))
        XCTAssertEqual(transaction?.receipts.count, 1)
        await coordinator.refreshReadings()
        XCTAssertEqual(coordinator.installations.map(\.clientID), ["opencode"])
        XCTAssertEqual(coordinator.readings["opencode"]?.reading,
                       .entries([ClientConfigEntry(baseURL: endpoint.baseURL, models: [endpoint.modelName])]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/zed").path))
        coordinator.rollback()
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode/opencode.jsonc").path))
    }

    func testExplicitClientPreviewRejectsUnknownAndAdvisoryTargets() throws {
        let coordinator = makeCoordinator(home: try makeHome())
        coordinator.preview(endpoint: endpoint, clientIDs: ["../arbitrary", "lmstudio", "ollama"])
        XCTAssertTrue(coordinator.plans.isEmpty)
        XCTAssertNotNil(coordinator.lastError)
    }

    func testTargetedRepairLeavesOtherDetectedClientsUnplanned() throws {
        let home = try makeHome()
        for directory in [".config/opencode", ".config/zed"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let coordinator = makeCoordinator(home: home)
        coordinator.preview(endpoint: endpoint, clientIDs: ["zed"])
        XCTAssertEqual(coordinator.plans.map(\.clientID), ["zed"])
    }

    func testClientCreationPreservesAnUnreadableFileAddedAfterPreview() throws {
        let home = try makeHome()
        let coordinator = makeCoordinator(home: home)
        coordinator.preview(endpoint: endpoint, clientIDs: ["opencode"])
        let config = home.appendingPathComponent(".config/opencode/opencode.jsonc")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let external = Data([0xFF, 0xFE, 0x00])
        try external.write(to: config)
        let result = coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash))
        XCTAssertEqual(result?.receipts.count, 0)
        XCTAssertEqual(result?.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: config), external)
    }

    func testCreatedConfigRefusesAParentReplacedWithALinkAfterPreview() throws {
        let home = try makeHome()
        let coordinator = makeCoordinator(home: home)
        coordinator.preview(endpoint: endpoint, clientIDs: ["opencode"])
        let outside = home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".config"), withDestinationURL: outside)
        let transaction = coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash))
        XCTAssertEqual(transaction?.receipts.count, 0)
        XCTAssertTrue(transaction?.failures.contains { $0.contains("symbolic link") } == true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testSetupDiagnosisBlocksUnreadableAndLinkedConfigsAndLabelsLegacyContinue() {
        for status in [ClientConfigStatus(reading: .unreadable("Invalid JSON"), isLinked: false),
                       ClientConfigStatus(reading: .noWorkbenchEntry, isLinked: true)] {
            XCTAssertFalse(ClientSetupDiagnosis.make(clientID: "opencode", status: status, servers: []).canPreview)
        }
        let missing = ClientConfigStatus(reading: .fileAbsent, isLinked: false)
        XCTAssertTrue(ClientSetupDiagnosis.make(clientID: "opencode", status: missing, servers: []).canPreview)
        XCTAssertFalse(ClientSetupDiagnosis.make(clientID: "continue", status: missing, servers: []).canPreview)
        let live = ClientConfigStatus(reading: .entries([ClientConfigEntry(baseURL: endpoint.baseURL, models: [endpoint.modelName])]), isLinked: false)
        XCTAssertTrue(ClientSetupDiagnosis.make(clientID: "opencode", status: live, servers: []).message.contains("not running"))
        XCTAssertFalse(ClientSetupDiagnosis.make(clientID: "opencode", status: live, servers: [], serverStatusAvailable: false).canPreview)
    }

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
        await coordinator.preview(server: server)
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

    func testEmptyOrEndpointOnlyPreviewCannotEnableServerConfirmation() async throws {
        let home = try makeHome()
        let coordinator = makeCoordinator(home: home)
        let server = ServerInfo(repo: "org/model", port: 8766, pid: 123, state: "running")
        await coordinator.preview(server: server)
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
        await coordinator.preview(server: server)
        let hash = try XCTUnwrap(coordinator.previewHash)
        let transaction = await coordinator.confirm(server: server, previewHash: hash, currentServers: { [server] })
        XCTAssertEqual(transaction?.receipts.count, 1)
        XCTAssertEqual(try JSONCTolerant.parse(String(contentsOf: config))["model"] as? String, "mlx-agent//models/qwen-converted")
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
            await coordinator.preview(server: server)
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
        await coordinator.preview(server: server)
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
        await coordinator.preview(server: server)
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
        XCTAssertEqual(try JSONCTolerant.parse(written)["model"] as? String, "mlx-agent/qwen3-8b")
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
        XCTAssertNil(coordinator.transactions.first?.rolledBackAt)
        XCTAssertTrue(coordinator.rollbackAvailable)
        XCTAssertEqual(coordinator.transactions.first?.failures.count, 1)
        XCTAssertNotNil(coordinator.lastError)
    }

    func testWiringPreservesUnreadableConfigThatExistedBeforePreview() throws {
        let home = try makeHome()
        let config = home.appendingPathComponent(".config/zed/settings.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data([0x7B, 0xC3, 0x28, 0x7D])
        try original.write(to: config)
        let coordinator = makeCoordinator(home: home)
        coordinator.preview(endpoint: endpoint)
        let transaction = coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash))
        XCTAssertEqual(transaction?.receipts.count, 0)
        XCTAssertEqual(transaction?.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: config), original)

        coordinator.rollback()

        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        XCTAssertEqual(try Data(contentsOf: config), original)
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
        XCTAssertNil(coordinator.transactions.first?.rolledBackAt)
        XCTAssertTrue(coordinator.rollbackAvailable)
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

    func testSymlinkedConfigFileIsFollowedAndALinkSwappedInAfterReviewIsRefused() throws {
        let home = try makeHome()
        let config = home.appendingPathComponent(".config/opencode/opencode.jsonc")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let shared = home.appendingPathComponent("Dotfiles/opencode.jsonc")
        try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"theme\": \"dark\"}".write(to: shared, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: shared)
        let coordinator = makeCoordinator(home: home)

        coordinator.preview(endpoint: endpoint)
        XCTAssertEqual(coordinator.plans.map(\.configPath), [shared.path])
        let transaction = coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash))

        XCTAssertEqual(transaction?.failures, [])
        XCTAssertTrue(try String(contentsOf: shared).contains(endpoint.baseURL))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: config.path), shared.path)

        // The reviewed path is the link's target; a link put there after review is never written through.
        coordinator.preview(endpoint: endpoint)
        let other = home.appendingPathComponent("other.json")
        try "{}".write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: shared)
        try FileManager.default.createSymbolicLink(at: shared, withDestinationURL: other)
        let swapped = coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash))

        XCTAssertEqual(swapped?.receipts.count, 0)
        XCTAssertEqual(swapped?.failures, [try XCTUnwrap(WiringError.symlinkRefused(client: "opencode").errorDescription)])
        XCTAssertEqual(try String(contentsOf: other), "{}")
    }

    func testDanglingConfigLinkCreatesItsTargetAndALoopingLinkIsRefused() throws {
        let home = try makeHome()
        let folder = home.appendingPathComponent(".config/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = home.appendingPathComponent("Volume/opencode.jsonc")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let config = folder.appendingPathComponent("opencode.jsonc")
        try FileManager.default.createSymbolicLink(atPath: config.path, withDestinationPath: "../../Volume/opencode.jsonc")
        let coordinator = makeCoordinator(home: home)

        coordinator.preview(endpoint: endpoint)
        XCTAssertEqual(coordinator.plans.map(\.configPath), [target.path])
        let created = coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash))

        XCTAssertEqual(created?.failures, [])
        XCTAssertTrue(try String(contentsOf: config).contains(endpoint.baseURL))
        coordinator.rollback()
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash(home).appendingPathComponent("opencode.jsonc").path))

        try FileManager.default.removeItem(at: config)
        try FileManager.default.createSymbolicLink(atPath: config.path, withDestinationPath: "loop.jsonc")
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("loop.jsonc").path, withDestinationPath: "opencode.jsonc")
        coordinator.preview(endpoint: endpoint)
        XCTAssertEqual(coordinator.plans.map(\.configPath), [config.path])
        let looped = coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash))

        XCTAssertEqual(looped?.receipts.count, 0)
        XCTAssertEqual(looped?.failures.count, 1)
        XCTAssertTrue(looped?.failures.first?.contains("links loop") == true)
    }

    func testChosenConfigFolderReceivesTheConfigUntilTheStandardFolderIsRestored() throws {
        let home = try makeHome()
        let standard = home.appendingPathComponent(".config/opencode/opencode.jsonc")
        try FileManager.default.createDirectory(at: standard.deletingLastPathComponent(), withIntermediateDirectories: true)
        let chosen = home.appendingPathComponent("Dotfiles/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let locations = makeLocations()
        let coordinator = makeCoordinator(home: home, locations: locations)

        coordinator.setConfigDirectory(chosen.path, for: "opencode")
        XCTAssertEqual(coordinator.configDirectory(for: "opencode"), chosen.path)
        XCTAssertEqual(coordinator.setupClients.first { $0.clientID == "opencode" }?.configPath,
                       chosen.appendingPathComponent("opencode.jsonc").path)
        coordinator.preview(endpoint: endpoint)
        XCTAssertEqual(coordinator.plans.map(\.configPath), [chosen.appendingPathComponent("opencode.jsonc").path])
        let transaction = coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash))

        XCTAssertEqual(transaction?.failures, [])
        XCTAssertTrue(try String(contentsOf: chosen.appendingPathComponent("opencode.jsonc")).contains(endpoint.baseURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: standard.path))
        XCTAssertEqual(makeCoordinator(home: home, locations: locations).configDirectory(for: "opencode"), chosen.path)

        coordinator.setConfigDirectory(nil, for: "opencode")
        XCTAssertNil(coordinator.configDirectory(for: "opencode"))
        XCTAssertEqual(coordinator.setupClients.first { $0.clientID == "opencode" }?.configPath, standard.path)
    }

    func testSymlinkedConfigFolderIsWrittenAtItsRealLocation() throws {
        let home = try makeHome()
        // The standard folder links outside home, as onto another volume.
        let real = try makeHome().appendingPathComponent(".config/opencode", isDirectory: true)
        let config = real.appendingPathComponent("opencode.jsonc")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "{\"theme\": \"dark\"}\n".write(to: config, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config"), withIntermediateDirectories: true)
        let link = home.appendingPathComponent(".config/opencode")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let coordinator = makeCoordinator(home: home)

        coordinator.preview(endpoint: endpoint)
        XCTAssertEqual(coordinator.plans.map(\.configPath), [config.path])
        let transaction = try XCTUnwrap(coordinator.confirm(endpoint: endpoint, previewHash: try XCTUnwrap(coordinator.previewHash)))

        XCTAssertEqual(transaction.failures, [])
        let written = try String(contentsOf: config)
        XCTAssertTrue(written.contains(endpoint.baseURL) && written.contains("\"theme\""))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        XCTAssertEqual(transaction.receipts.first.flatMap(\.backupPath).map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }, real.path)
        coordinator.rollback()
        XCTAssertEqual(try String(contentsOf: config), "{\"theme\": \"dark\"}\n")
        XCTAssertNotNil(coordinator.transactions.first?.rolledBackAt)
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

    func testSecretRedactionPreservesEnvVarReferencesWhileRedactingRawSecrets() {
        let before = "\"apiKey\": \"raw-secret-token-value\","
        let after = "\"apiKey\": \"${MLX_AGENT_API_KEY}\","
        let plan = ClientEditPlan(
            clientID: "openclaw", displayName: "OpenClaw", configPath: "/x",
            before: before,
            after: after,
            summary: "", rewritesFile: true
        )
        let diff = plan.redactedDiff
        XCTAssertTrue(diff.allSatisfy { !$0.text.contains("raw-secret-token-value") })
        XCTAssertTrue(diff.contains { $0.kind == .removed && $0.text.contains("•••") })
        XCTAssertTrue(diff.contains { $0.kind == .added && $0.text.contains("${MLX_AGENT_API_KEY}") })
    }

    func testOpenClawFrontDoorRegistersAllModelsPreservesExistingAndUsesEnvVarRef() async throws {
        let key = "mlxw_fixture_openclaw_frontdoor_0123456789"
        let digest = EndpointCredentialStore.digest(key)
        let home = try makeHome()
        let configURL = home.appendingPathComponent(".openclaw/openclaw.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = """
        {
          "models": {
            "providers": {
              "workbench": {
                "baseUrl": "http://127.0.0.1:8080/v1",
                "apiKey": "old-raw-plaintext-secret",
                "models": [
                  { "id": "user/custom-model", "name": "user/custom-model" }
                ]
              }
            }
          }
        }
        """
        try existing.write(to: configURL, atomically: true, encoding: .utf8)

        let coordinator = WiringCoordinator(home: home,
            store: JSONStore(fileURL: home.appendingPathComponent("history.json")), credential: { _ in key })
        let door = WireEndpoint(baseURL: "http://127.0.0.1:8939/v1", modelName: "gemma-3",
                                apiKeySHA256: digest, models: ["gemma-3", "org/coder", "org/vision"])
        await coordinator.preview(frontDoor: door, clientIDs: ["openclaw"])
        let plan = try XCTUnwrap(coordinator.plans.first)
        XCTAssertFalse(plan.after.contains(key))
        XCTAssertFalse(plan.after.contains("old-raw-plaintext-secret"))
        XCTAssertTrue(plan.after.contains("${MLX_AGENT_API_KEY}"))
        XCTAssertNotNil(plan.credentialInstruction)
        XCTAssertTrue(plan.redactedDiff.contains { $0.kind == .added && $0.text.contains("${MLX_AGENT_API_KEY}") })
        XCTAssertTrue(plan.redactedDiff.allSatisfy { !$0.text.contains("old-raw-plaintext-secret") })

        let parsed = try JSONCTolerant.parse(plan.after)
        XCTAssertNil(parsed["mlx_agent_wire"])
        let providers = try XCTUnwrap((parsed["models"] as? [String: Any])?["providers"] as? [String: Any])
        XCTAssertEqual(Set(providers.keys), ["workbench"])
        let provider = try XCTUnwrap(providers["workbench"] as? [String: Any])
        XCTAssertEqual(provider["apiKey"] as? String, "${MLX_AGENT_API_KEY}")
        XCTAssertEqual(provider["authHeader"] as? Bool, true)
        XCTAssertNil(provider["auth"])
        let modelIDs = (provider["models"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        XCTAssertEqual(modelIDs, ["user/custom-model", "gemma-3", "org/coder", "org/vision"])
    }

    func testOpenClawRecognizesAndUpdatesMLXAgentProviderWithoutDuplicating() throws {
        let existing = """
        {
          "models": {
            "providers": {
              "mlx-agent": {
                "baseUrl": "http://127.0.0.1:8090/v1",
                "api": "openai-completions",
                "apiKey": "${CUSTOM_MLX_KEY}",
                "models": [
                  { "id": "org/existing", "name": "org/existing" }
                ]
              }
            }
          }
        }
        """
        let reading = AgentClientAdapters.openclaw.read(existing)
        XCTAssertEqual(reading, .entries([ClientConfigEntry(baseURL: "http://127.0.0.1:8090/v1", models: ["org/existing"])]))

        let key = "mlxw_fixture_openclaw_mlxagent_0123456789"
        let endpoint = WireEndpoint(baseURL: "http://127.0.0.1:8939/v1", modelName: "gemma-3",
                                    apiKeySHA256: EndpointCredentialStore.digest(key),
                                    models: ["gemma-3", "org/coder"])
        let after = try AgentClientAdapters.openclaw.authenticatedPlan(existing, endpoint, key: key)
        XCTAssertFalse(after.contains(key))
        let parsed = try JSONCTolerant.parse(after)
        XCTAssertNil(parsed["mlx_agent_wire"])
        let providers = try XCTUnwrap((parsed["models"] as? [String: Any])?["providers"] as? [String: Any])
        XCTAssertEqual(Set(providers.keys), ["mlx-agent"])
        let provider = try XCTUnwrap(providers["mlx-agent"] as? [String: Any])
        XCTAssertEqual(provider["apiKey"] as? String, "${CUSTOM_MLX_KEY}")
        let defaults = try XCTUnwrap(((parsed["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["model"] as? [String: Any])
        XCTAssertEqual(defaults["primary"] as? String, "mlx-agent/gemma-3")
        XCTAssertEqual(AgentClientAdapters.openclaw.read(after),
                       .entries([ClientConfigEntry(baseURL: "http://127.0.0.1:8939/v1", models: ["gemma-3"])]))

        XCTAssertThrowsError(try AgentClientAdapters.openclaw.validate?("{\"mlx_agent_wire\": {}}"))
    }

    func testMatchesAppliedConfigUsesInjectedFileManagerAndRefusesAncestorSymlink() async throws {
        final class TrackingFileManager: FileManager {
            var symlinkChecks: [String] = []
            var attributeChecks: [String] = []
            var contentReads: [String] = []
            var forcedSymlinkPath: String?

            override func destinationOfSymbolicLink(atPath path: String) throws -> String {
                symlinkChecks.append(path)
                if path == forcedSymlinkPath {
                    return "/tmp/redirected-target"
                }
                return try super.destinationOfSymbolicLink(atPath: path)
            }

            override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
                attributeChecks.append(path)
                return try super.attributesOfItem(atPath: path)
            }

            override func contents(atPath path: String) -> Data? {
                contentReads.append(path)
                return super.contents(atPath: path)
            }
        }

        let home = try makeHome()
        let opencodeConfig = home.appendingPathComponent(".config/opencode/opencode.jsonc")
        try FileManager.default.createDirectory(at: opencodeConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"theme\": \"dark\"}".write(to: opencodeConfig, atomically: true, encoding: .utf8)
        let trackingFM = TrackingFileManager()
        let trashDirectory = trash(home)
        let coordinator = WiringCoordinator(
            home: home,
            fileManager: trackingFM,
            store: JSONStore<WiringTransaction>(fileURL: temporaryURL("transactions.json")),
            moveToTrash: { url in
                try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: trashDirectory.appendingPathComponent(url.lastPathComponent))
            }
        )

        coordinator.preview(endpoint: endpoint)
        let hash = try XCTUnwrap(coordinator.previewHash)
        let transaction = try XCTUnwrap(coordinator.confirm(endpoint: endpoint, previewHash: hash))
        let receipt = try XCTUnwrap(transaction.receipts.first)

        trackingFM.symlinkChecks.removeAll()
        trackingFM.attributeChecks.removeAll()
        trackingFM.contentReads.removeAll()

        let matched = await coordinator.matchesAppliedConfig(receipt, endpoint: endpoint)
        XCTAssertTrue(matched)
        XCTAssertTrue(trackingFM.symlinkChecks.contains(receipt.configPath))
        XCTAssertTrue(trackingFM.symlinkChecks.contains(opencodeConfig.deletingLastPathComponent().path))
        XCTAssertTrue(trackingFM.attributeChecks.contains(receipt.configPath))
        XCTAssertTrue(trackingFM.contentReads.contains(receipt.configPath))

        trackingFM.forcedSymlinkPath = opencodeConfig.deletingLastPathComponent().path
        let matchedWithAncestorSymlink = await coordinator.matchesAppliedConfig(receipt, endpoint: endpoint)
        XCTAssertFalse(matchedWithAncestorSymlink)
    }

    // MARK: - Helpers

    private var storeURL: URL!
    private var homeURL: URL?

    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // The temporary folder sits behind /var -> /private/var; config paths are reported at their real location.
        let real = try XCTUnwrap(realpath(url.path, nil))
        defer { free(real) }
        let resolved = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        homeURL = resolved
        return resolved
    }

    /// Chosen folders kept in a preferences suite of their own, removed after the test.
    private func makeLocations() -> ClientConfigLocations {
        let suite = "mlx-workbench-wiring-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { defaults?.removePersistentDomain(forName: suite) }
        return ClientConfigLocations(defaults: defaults)
    }

    private func makeCoordinator(
        home: URL, store: JSONStore<WiringTransaction>? = nil, moveToTrash: ((URL) throws -> Void)? = nil,
        locations: ClientConfigLocations = .standardFolders
    ) -> WiringCoordinator {
        let trashDirectory = trash(home)
        return WiringCoordinator(
            home: home,
            locations: locations,
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
