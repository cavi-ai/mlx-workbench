import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class FrontDoorTests: XCTestCase {
    private let token = "mlxw_" + String(repeating: "f", count: 64)
    private var digest: String { EndpointCredentialStore.digest(token) }

    func testRunBindsPortAndKeyDigestAndStopsWithTheApp() async throws {
        let calls = FrontDoorCalls()
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: "/fixture", command: { _, argv, _, timeout in
            calls.record(argv.joined(separator: " ") + " timeout=\(timeout.map { String($0) } ?? "none")")
            return ["state": "listening"]
        })
        try await api.frontDoorRun(port: 8939, keySHA256: digest)
        XCTAssertEqual(calls.values, ["serve front-door --port 8939 --api-key-sha256 \(digest) --json --watch-parent timeout=inf"])
    }

    func testStartPublishesRoutedModelsAndStopEndsTheChild() async throws {
        let calls = FrontDoorCalls()
        let coordinator = FrontDoorCoordinator(api: Self.unusedAPI(), token: { [token] hash in
            calls.record("token \(hash)"); return token
        }, run: { port, key in
            calls.record("run \(port) \(key)")
            do { try await Task.sleep(nanoseconds: 3_600_000_000_000) } catch { calls.record("ended"); throw error }
        }, models: { port, presented in
            calls.record("models \(port) \(presented)")
            guard calls.count("models") > 1 else { throw HostHTTPError.requestFailed }
            return ["gemma-3", "org/coder"]
        }, portInUse: { _ in false })

        await coordinator.start(FrontDoorSettings(port: 8939, apiKeySHA256: digest))
        XCTAssertNil(coordinator.error)
        XCTAssertEqual(coordinator.listening?.models, ["gemma-3", "org/coder"])
        XCTAssertEqual(coordinator.endpoint, WireEndpoint(baseURL: "http://127.0.0.1:8939/v1", modelName: "gemma-3",
                                                          apiKeySHA256: digest, models: ["gemma-3", "org/coder"]))
        XCTAssertEqual(calls.values.first, "token \(digest)")
        XCTAssertEqual(calls.values.filter { $0.hasPrefix("run") }, ["run 8939 \(digest)"])
        XCTAssertEqual(Set(calls.values.filter { $0.hasPrefix("models") }), ["models 8939 \(token)"])

        await coordinator.stop()
        XCTAssertNil(coordinator.listening)
        XCTAssertNil(coordinator.endpoint)
        XCTAssertNil(coordinator.error)
        XCTAssertEqual(calls.values.last, "ended")
    }

    func testStartRefusesAPortInUseAndReportsAChildThatExits() async {
        let calls = FrontDoorCalls()
        func make(portInUse: Bool) -> FrontDoorCoordinator {
            FrontDoorCoordinator(api: Self.unusedAPI(), token: { [token] _ in token }, run: { port, _ in
                calls.record("run \(port)")
                throw BridgeError.remote(code: "front_door_port_unavailable", message: "Port \(port) is unavailable on 127.0.0.1.",
                                         remediation: "Choose another port or stop the process using it.")
            }, models: { _, _ in throw HostHTTPError.requestFailed }, portInUse: { _ in portInUse })
        }
        let busy = make(portInUse: true)
        await busy.start(FrontDoorSettings(port: 8939, apiKeySHA256: digest))
        XCTAssertTrue(busy.error?.contains("8939") == true, busy.error ?? "")
        XCTAssertTrue(calls.values.isEmpty)

        let coordinator = make(portInUse: false)
        await coordinator.start(FrontDoorSettings(port: 8939, apiKeySHA256: digest))
        XCTAssertEqual(calls.values, ["run 8939"])
        XCTAssertNil(coordinator.listening)
        XCTAssertTrue(coordinator.error?.contains("Choose another port") == true, coordinator.error ?? "")
        XCTAssertFalse(coordinator.busy)
    }

    func testParseRoutesPreservesChatAndTypedTaskKinds() throws {
        let payload = """
        {
          "object": "list",
          "data": [
            {"id": "org/chat-model", "object": "model", "owned_by": "mlx-agent"},
            {"id": "org/embed-small", "object": "model", "owned_by": "mlx-agent", "task_kinds": ["embedding"]},
            {"id": "org/systemone-clf", "object": "model", "owned_by": "mlx-agent", "task_kinds": ["classification"]},
            {"id": "org/audio-box", "object": "model", "owned_by": "mlx-agent", "task_kinds": ["audio_transcription", "music_generation"]},
            {"id": "plain-chat", "object": "model", "owned_by": "mlx-agent", "task_kinds": []},
            {"id": "", "object": "model", "owned_by": "mlx-agent"}
          ]
        }
        """
        let routes = try FrontDoorCoordinator.parseRoutes(from: Data(payload.utf8))
        XCTAssertEqual(routes, [
            FrontDoorRoute(id: "org/chat-model"),
            FrontDoorRoute(id: "org/embed-small", taskKinds: ["embedding"]),
            FrontDoorRoute(id: "org/systemone-clf", taskKinds: ["classification"]),
            FrontDoorRoute(id: "org/audio-box", taskKinds: ["audio_transcription", "music_generation"]),
            FrontDoorRoute(id: "plain-chat"),
        ])

        let listener = FrontDoorListener(port: 8939, apiKeySHA256: digest, routes: routes)
        XCTAssertEqual(listener.models, ["org/chat-model", "plain-chat"])
        XCTAssertEqual(listener.chatModels, ["org/chat-model", "plain-chat"])
        XCTAssertEqual(listener.typedRoutes.map(\.id), ["org/embed-small", "org/systemone-clf", "org/audio-box"])
        XCTAssertEqual(listener.allModelIDs, ["org/chat-model", "org/embed-small", "org/systemone-clf", "org/audio-box", "plain-chat"])
    }

    func testEndpointDefaultsToFirstChatModelWhileExposingAllRoutedModels() async throws {
        let mixedRoutes = [
            FrontDoorRoute(id: "bge-small", taskKinds: ["embedding"]),
            FrontDoorRoute(id: "gemma-3"),
            FrontDoorRoute(id: "systemone-clf", taskKinds: ["classification"]),
        ]
        let coordinator = FrontDoorCoordinator(api: Self.unusedAPI(), token: { [token] _ in token }, run: { _, _ in
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }, routes: { _, _ in mixedRoutes }, portInUse: { _ in false })

        await coordinator.start(FrontDoorSettings(port: 8939, apiKeySHA256: digest))
        XCTAssertEqual(coordinator.listening?.routes, mixedRoutes)
        XCTAssertEqual(coordinator.listening?.chatModels, ["gemma-3"])
        XCTAssertEqual(coordinator.listening?.typedRoutes.map(\.id), ["bge-small", "systemone-clf"])
        XCTAssertEqual(coordinator.endpoint, WireEndpoint(
            baseURL: "http://127.0.0.1:8939/v1",
            modelName: "gemma-3",
            apiKeySHA256: digest,
            models: ["bge-small", "gemma-3", "systemone-clf"]
        ))
        await coordinator.stop()

        let typedOnly = [FrontDoorRoute(id: "bge-small", taskKinds: ["embedding"])]
        let typedCoordinator = FrontDoorCoordinator(api: Self.unusedAPI(), token: { [token] _ in token }, run: { _, _ in
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }, routes: { _, _ in typedOnly }, portInUse: { _ in false })

        await typedCoordinator.start(FrontDoorSettings(port: 8940, apiKeySHA256: digest))
        XCTAssertEqual(typedCoordinator.listening?.typedRoutes, typedOnly)
        XCTAssertTrue(typedCoordinator.listening?.chatModels.isEmpty == true)
        XCTAssertNil(typedCoordinator.endpoint)
        await typedCoordinator.stop()
    }

    func testDetectCollisionsMatchesBackendPublicModelNameAndKeyDigest() {
        let otherDigest = EndpointCredentialStore.digest("mlxw_" + String(repeating: "a", count: 64))
        var hfSlotA = EndpointSlot(enabled: true, port: 8802, modelPath: "/cache/hub/models--org--gemma-3/snapshots/aaa111")
        hfSlotA.apiKeySHA256 = digest
        var hfSlotB = EndpointSlot(enabled: true, port: 8801, modelPath: "/cache/hub/models--org--gemma-3/snapshots/bbb222")
        hfSlotB.apiKeySHA256 = digest
        var dirSlotA = EndpointSlot(enabled: true, port: 8803, modelPath: "/models/a/bge-small")
        dirSlotA.apiKeySHA256 = digest
        var dirSlotB = EndpointSlot(enabled: true, port: 8804, modelPath: "/models/b/bge-small")
        dirSlotB.apiKeySHA256 = digest
        var disabledSlot = EndpointSlot(enabled: false, port: 8805, modelPath: "/models/c/unique-model")
        disabledSlot.apiKeySHA256 = digest
        var uniqueSlot = EndpointSlot(enabled: true, port: 8806, modelPath: "/models/d/unique-model")
        uniqueSlot.apiKeySHA256 = digest
        var differentKeySlot = EndpointSlot(enabled: true, port: 8807, modelPath: "/models/e/unique-model")
        differentKeySlot.apiKeySHA256 = otherDigest

        let slots = [hfSlotA, hfSlotB, dirSlotA, dirSlotB, disabledSlot, uniqueSlot, differentKeySlot]
        let collisions = FrontDoorCoordinator.detectCollisions(slots: slots, frontDoorKeySHA256: digest)
        XCTAssertEqual(collisions, [
            FrontDoorCollision(modelName: "bge-small", ports: [8803, 8804]),
            FrontDoorCollision(modelName: "org/gemma-3", ports: [8801, 8802]),
        ])
        XCTAssertTrue(collisions[1].warningMessage.contains("org/gemma-3"))
        XCTAssertTrue(collisions[1].warningMessage.contains("409 ambiguous_model"))
        XCTAssertFalse(collisions[1].warningMessage.contains(token))
        XCTAssertTrue(FrontDoorCoordinator.detectCollisions(slots: slots, frontDoorKeySHA256: nil).isEmpty)
    }

    func testAppHostRefreshesRunningFrontDoorOnSlotStateChange() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("front-door-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let keyDigest = digest
        var slot = EndpointSlot(enabled: true, port: 8810, modelPath: "/models/gemma-3", loadOnRequest: true)
        slot.apiKeySHA256 = keyDigest
        let fleetStore = JSONStore<EndpointFleetConfig>(fileURL: tempDir.appendingPathComponent("endpoint-fleet.json"))
        try fleetStore.replaceAll([EndpointFleetConfig(slots: [slot], installedAtLogin: false, frontDoor: FrontDoorSettings(port: 8939, apiKeySHA256: keyDigest))])

        let supervisor = EndpointSupervisor(
            lifecycle: ServeLifecycle(preview: { _, _ in "unused" }, start: { _, _, _ in }, stop: { _ in }),
            statusProvider: { [ServerInfo(path: slot.modelPath, port: slot.port, pid: 42, state: "running", apiKeySHA256: keyDigest)] },
            store: JSONStore<EndpointConfig>(fileURL: tempDir.appendingPathComponent("endpoint.json")),
            fleetStore: fleetStore
        )

        let calls = FrontDoorCalls()
        let coordinator = FrontDoorCoordinator(api: Self.unusedAPI(), token: { [token] _ in token }, run: { _, _ in
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }, routes: { _, _ in
            calls.record("routes")
            return calls.count("routes") == 1
                ? [FrontDoorRoute(id: "gemma-3")]
                : [FrontDoorRoute(id: "gemma-3"), FrontDoorRoute(id: "bge-small", taskKinds: ["embedding"])]
        }, portInUse: { _ in false })

        let app = AppHost(
            config: .defaults(ggufRoots: []),
            discoveredRoots: [],
            vendorAgentPath: "",
            agentHealth: .notConfigured,
            runtimeReport: .checking,
            endpoint: supervisor,
            frontDoor: coordinator
        )
        _ = app

        await coordinator.start(FrontDoorSettings(port: 8939, apiKeySHA256: digest))
        XCTAssertEqual(calls.count("routes"), 1)
        XCTAssertEqual(coordinator.listening?.routes, [FrontDoorRoute(id: "gemma-3")])

        await supervisor.reconcile()
        let deadline = Date().addingTimeInterval(2.0)
        while calls.count("routes") < 2 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertGreaterThanOrEqual(calls.count("routes"), 2)
        XCTAssertEqual(coordinator.listening?.typedRoutes, [FrontDoorRoute(id: "bge-small", taskKinds: ["embedding"])])
        await coordinator.stop()
    }

    private static func unusedAPI() -> WorkbenchAPI {
        WorkbenchAPI(cli: CLIProcess(), agentPath: "/fixture", command: { _, argv, _, _ in
            XCTFail("Unexpected engine call: \(argv)"); return [:]
        })
    }
}

private final class FrontDoorCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.withLock { recorded } }
    func record(_ value: String) { lock.withLock { recorded.append(value) } }
    func count(_ prefix: String) -> Int { lock.withLock { recorded.filter { $0.hasPrefix(prefix) }.count } }
}
