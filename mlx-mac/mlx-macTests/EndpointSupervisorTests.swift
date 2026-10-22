import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class EndpointSupervisorTests: XCTestCase {
    func testFailedFleetWritesPreserveDesiredStateAndRunningServers() async throws {
        for action in ["enable", "add", "disable", "toggle", "swap", "update", "remove"] {
            let fleetURL = temporaryURL("fleet.json")
            let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/Models/a")
            let original = EndpointFleetConfig(slots: [slot], installedAtLogin: false)
            try JSONStore<EndpointFleetConfig>(fileURL: fleetURL).replaceAll([original])
            let world = FakeServeWorld()
            world.preload(repo: "/Models/a", port: 8766)
            let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
                store: JSONStore<EndpointConfig>(fileURL: storeURL),
                fleetStore: JSONStore(fileURL: fleetURL, replaceItem: { _, _ in throw StubError.offline }))
            switch action {
            case "enable": await supervisor.enable(modelPath: "/Models/b", port: 8766)
            case "add": await supervisor.addSlot(modelPath: "/Models/b", port: 8767)
            case "disable": await supervisor.disable()
            case "toggle": await supervisor.setSlotEnabled(id: slot.id, false)
            case "swap": await supervisor.swapSlot(id: slot.id, to: "/Models/b")
            case "update": await supervisor.updateSlot(id: slot.id, modelPath: "/Models/b", port: 8766, role: nil)
            default: await supervisor.removeSlot(id: slot.id)
            }
            XCTAssertEqual(supervisor.fleet, original, action)
            XCTAssertEqual(try world.status().map(\.modelIdentity), ["/Models/a"], action)
            XCTAssertEqual(try JSONStore<EndpointFleetConfig>(fileURL: fleetURL).load(), [original], action)
            XCTAssertNotNil(supervisor.persistenceError, action)
        }
    }

    func testOverlappingFleetMutationIsRejectedWhileServerStopIsPending() async throws {
        let fleetURL = temporaryURL("fleet.json")
        let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/Models/a")
        try JSONStore<EndpointFleetConfig>(fileURL: fleetURL).replaceAll([
            EndpointFleetConfig(slots: [slot], installedAtLogin: false)
        ])
        let entered = expectation(description: "Server stop entered")
        let gate = EndpointStopGate()
        let world = FakeServeWorld()
        world.preload(repo: "/Models/a", port: 8766)
        var lifecycle = world.lifecycle
        let stop = lifecycle.stop
        lifecycle.stop = { port in
            entered.fulfill()
            await gate.wait()
            try await stop(port)
        }
        let supervisor = EndpointSupervisor(lifecycle: lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL), fleetStore: JSONStore(fileURL: fleetURL))
        let removal = Task { await supervisor.removeSlot(id: slot.id) }
        await fulfillment(of: [entered], timeout: 5)
        await supervisor.updateSlot(id: slot.id, modelPath: "/Models/a", port: 8766, role: .coding)
        XCTAssertNotNil(supervisor.lastError, "A concurrent action must explain why it was refused")
        XCTAssertFalse(supervisor.fleet.slots.contains { $0.role == .coding })
        await gate.release()
        await removal.value
        XCTAssertFalse(supervisor.isChanging)
        XCTAssertTrue(supervisor.fleet.slots.isEmpty)
        XCTAssertTrue(try world.status().isEmpty)
    }

    func testUnreadableFleetCannotBeReplacedByEnablingAnEndpoint() async throws {
        let fleetURL = temporaryURL("fleet.json")
        try FileManager.default.createDirectory(at: fleetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("damaged fleet".utf8)
        try original.write(to: fleetURL)
        let world = FakeServeWorld()
        let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL), fleetStore: JSONStore(fileURL: fleetURL))
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        XCTAssertTrue(supervisor.fleet.slots.isEmpty)
        XCTAssertTrue(try world.status().isEmpty)
        XCTAssertEqual(try Data(contentsOf: fleetURL), original)
        XCTAssertNotNil(supervisor.persistenceError)
    }

    func testAdapterStatusCannotMatchAnUnadaptedModelAndProcessIdentityRetainsItsContents() throws {
        let source: [String: Any] = ["repo": "org/base", "port": 8766, "pid": 42, "state": "running",
            "adapter_path": "/adapters/tuned", "adapter_identity": ["adapters.safetensors": ["sha256": "first", "bytes": 4]]]
        let server = try JSONDecoder().decode(ServerInfo.self, from: JSONSerialization.data(withJSONObject: source))
        let bridged = try XCTUnwrap(WorkbenchAPI.servers(from: ["servers": [source]])?.first)
        XCTAssertEqual(bridged.adapterPath, server.adapterPath)
        XCTAssertEqual(bridged.adapterIdentity, server.adapterIdentity)
        XCTAssertFalse(bridged.matchesUnadaptedModel("org/base"))
        XCTAssertEqual(server.adapterPath, "/adapters/tuned")
        XCTAssertFalse(server.matchesUnadaptedModel("org/base"))
        var changed = source
        changed["adapter_identity"] = ["adapters.safetensors": ["sha256": "second", "bytes": 4]]
        let replacement = try JSONDecoder().decode(ServerInfo.self, from: JSONSerialization.data(withJSONObject: changed))
        XCTAssertFalse(server.sameProcess(as: replacement))
        XCTAssertFalse(ClientWiringSelection.sameServer(server, replacement))
        XCTAssertTrue(ClientWiringSelection.matchingServers(request: .init(modelPath: "org/base", preferredPort: nil), servers: [server]).isEmpty)
        let unknown = ServerInfo(repo: "org/base", state: "running", adapterStatus: "unknown")
        XCTAssertFalse(unknown.matchesUnadaptedModel("org/base"))
        XCTAssertTrue(ServerInfo(repo: "org/base", state: "running").matchesUnadaptedModel("org/base"))
        let malformed = try XCTUnwrap(WorkbenchAPI.servers(from: ["servers": [["repo": "org/base", "adapter_path": 42]]])?.first)
        XCTAssertFalse(malformed.matchesUnadaptedModel("org/base"))
    }

    func testBaseEndpointDoesNotAdoptOrConfigureAnAdapterServerOnItsPort() async throws {
        let world = FakeServeWorld(), recorder = LifecycleRecorder()
        world.recorder = recorder
        let adapter = ServerInfo(path: "/Models/a", port: 8766, pid: 42, state: "running", jit: true,
            modelState: "loaded", adapterPath: "/adapters/tuned")
        var lifecycle = world.lifecycle
        lifecycle.configureMemory = { _, _, _ in XCTFail("A base endpoint must not configure an adapter server") }
        let supervisor = EndpointSupervisor(lifecycle: lifecycle, statusProvider: { [adapter] },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        await supervisor.enable(modelPath: "/Models/a", port: 8766, loadOnRequest: true)
        let id = try XCTUnwrap(supervisor.fleet.slots.first?.id)
        guard case .modelMismatch(let name, _)? = supervisor.slotStates[id] else { return XCTFail("Adapter server must not be adopted as the base") }
        XCTAssertTrue(name.contains("Adapter: tuned"))
        XCTAssertTrue(recorder.events.isEmpty)
        await supervisor.setSlotMemoryPolicy(id: id, .init(idleTimeoutSeconds: 60, keepLoaded: true, minimumHeadroomGB: 4))
        XCTAssertNotNil(supervisor.lastError)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testNewEndpointDefaultsToJITWithoutEagerStart() async throws {
        let world = FakeServeWorld()
        let recorder = LifecycleRecorder()
        world.recorder = recorder
        var lifecycle = world.lifecycle
        lifecycle.jitPreview = { _, _, policy in
            XCTAssertEqual(policy, .automatic)
            return "jit-hash"
        }
        lifecycle.jitStart = { model, port, hash, policy in
            XCTAssertEqual(hash, "jit-hash")
            XCTAssertEqual(policy, .automatic)
            world.preload(repo: model, port: port, jit: true, modelState: "unloaded", memoryPolicy: policy)
        }
        let supervisor = EndpointSupervisor(lifecycle: lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        await supervisor.reconcile()
        XCTAssertTrue(try XCTUnwrap(supervisor.fleet.slots.first).usesJIT)
        XCTAssertEqual(supervisor.fleet.slots.first?.memoryPolicy, .automatic)
        XCTAssertEqual(try world.status().first?.modelState, "unloaded")
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testPolicyChangesApplyToLoadedGatewayWithoutStoppingIt() async throws {
        let world = FakeServeWorld()
        let recorder = LifecycleRecorder()
        world.recorder = recorder
        world.preload(repo: "/Models/a", port: 8766, jit: true, modelState: "loaded", activeRequests: 1)
        var lifecycle = world.lifecycle
        lifecycle.configureMemory = { port, pid, policy in
            XCTAssertEqual(pid, 1)
            world.configureMemory(port: port, policy: policy)
        }
        let supervisor = EndpointSupervisor(lifecycle: lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        await supervisor.enable(modelPath: "/Models/a", port: 8766, loadOnRequest: true)
        let id = try XCTUnwrap(supervisor.fleet.slots.first?.id)
        let policy = EndpointMemoryPolicy(idleTimeoutSeconds: 60, keepLoaded: true, minimumHeadroomGB: 4)
        await supervisor.setSlotMemoryPolicy(id: id, policy)
        XCTAssertNil(supervisor.lastError)
        XCTAssertEqual(try world.status().first?.memoryPolicy, policy)
        XCTAssertEqual(try world.status().first?.modelState, "loaded")
        XCTAssertEqual(try world.status().first?.activeRequests, 1)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testPolicySaveFailureDoesNotChangeGateway() async throws {
        let world = FakeServeWorld()
        world.preload(repo: "/Models/a", port: 8766, jit: true, modelState: "loaded")
        let recorder = LifecycleRecorder()
        var lifecycle = world.lifecycle
        lifecycle.configureMemory = { _, _, _ in recorder.record("configure") }
        let fleetURL = temporaryURL("fleet.json")
        let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/Models/a", loadOnRequest: true)
        try JSONStore<EndpointFleetConfig>(fileURL: fleetURL).replaceAll([EndpointFleetConfig(slots: [slot], installedAtLogin: false)])
        let supervisor = EndpointSupervisor(lifecycle: lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL),
            fleetStore: JSONStore<EndpointFleetConfig>(fileURL: fleetURL, replaceItem: { _, _ in throw StubError.offline }))
        await supervisor.setSlotMemoryPolicy(id: slot.id, .automatic)
        XCTAssertNotNil(supervisor.lastError)
        XCTAssertNil(supervisor.fleet.slots.first?.memoryPolicy)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testJITUnloadKeepsDesiredEndpointAndDoesNotStartWorkerAgain() async throws {
        let world = FakeServeWorld()
        world.preload(repo: "/Models/a", port: 8766, jit: true, modelState: "loaded")
        var lifecycle = world.lifecycle
        lifecycle.unload = { port, _ in world.unloadModel(port: port) }
        let supervisor = EndpointSupervisor(lifecycle: lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        await supervisor.enable(modelPath: "/Models/a", port: 8766, loadOnRequest: true)
        let before = try XCTUnwrap(try world.status().first)
        let unloaded = await supervisor.unloadServer(before)
        XCTAssertTrue(unloaded)
        XCTAssertTrue(supervisor.config.enabled)
        await supervisor.reconcile()
        let after = try XCTUnwrap(try world.status().first)
        XCTAssertEqual(after.pid, before.pid)
        XCTAssertEqual(after.state, "running")
        XCTAssertEqual(after.modelState, "unloaded")
    }

    func testFailedJITUnloadKeepsDesiredStateAndReportsLoadedModel() async throws {
        let world = FakeServeWorld()
        world.preload(repo: "/Models/a", port: 8766, jit: true, modelState: "loaded")
        var lifecycle = world.lifecycle
        lifecycle.unload = { _, _ in throw StubError.offline }
        let supervisor = EndpointSupervisor(lifecycle: lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        await supervisor.enable(modelPath: "/Models/a", port: 8766, loadOnRequest: true)
        let server = try XCTUnwrap(try world.status().first)
        let unloaded = await supervisor.unloadServer(server)
        XCTAssertFalse(unloaded)
        XCTAssertTrue(supervisor.config.enabled)
        XCTAssertEqual(try world.status().first?.modelState, "loaded")
        XCTAssertNotNil(supervisor.lastError)
    }

    func testUnloadStandaloneServerAndPreservesOtherPorts() async throws {
        let world = FakeServeWorld()
        let fleetURL = temporaryURL("fleet.json")
        try FileManager.default.createDirectory(at: fleetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let damaged = Data("damaged fleet".utf8)
        try damaged.write(to: fleetURL)
        let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL),
            fleetStore: JSONStore<EndpointFleetConfig>(fileURL: fleetURL))
        world.preload(repo: "/Models/a", port: 8766)
        world.preload(repo: "/Models/b", port: 8767)
        let server = try XCTUnwrap(try world.status().first)
        let unloaded = await supervisor.unloadServer(server)
        XCTAssertTrue(unloaded)
        XCTAssertEqual(try world.status().map(\.port), [8767])
        XCTAssertEqual(try Data(contentsOf: fleetURL), damaged)
        XCTAssertNotNil(supervisor.persistenceError)
    }

    func testUnloadSaveFailureDoesNotStopOrDisableServer() async throws {
        let world = FakeServeWorld()
        let fleetURL = temporaryURL("fleet.json")
        let supervisor = EndpointSupervisor(lifecycle: world.lifecycle, statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL),
            fleetStore: JSONStore<EndpointFleetConfig>(fileURL: fleetURL, replaceItem: { _, _ in throw StubError.offline }))
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        let server = try XCTUnwrap(try world.status().first)
        let unloaded = await supervisor.unloadServer(server)
        XCTAssertFalse(unloaded)
        XCTAssertTrue(supervisor.config.enabled)
        XCTAssertEqual(try world.status(), [server])
        XCTAssertNotNil(supervisor.lastError)
    }

    func testUnloadStopFailureLeavesRestartDisabledAndReportsRunningServer() async throws {
        let world = FakeServeWorld()
        let live = world.lifecycle
        let supervisor = EndpointSupervisor(lifecycle: ServeLifecycle(preview: live.preview, start: live.start,
            stop: { _ in throw StubError.offline }), statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL))
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        let server = try XCTUnwrap(try world.status().first)
        let unloaded = await supervisor.unloadServer(server)
        XCTAssertFalse(unloaded)
        XCTAssertFalse(supervisor.config.enabled)
        XCTAssertEqual(try world.status(), [server])
        XCTAssertNotNil(supervisor.lastError)
    }

    func testUnloadRefusesChangedServerIdentityAndDoesNotDisableEndpoint() async throws {
        let (supervisor, world) = makeSupervisor()
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        let server = try XCTUnwrap(try world.status().first)
        world.kill(port: 8766)
        world.preload(repo: "/Models/b", port: 8766)
        let unloaded = await supervisor.unloadServer(server)
        XCTAssertFalse(unloaded)
        XCTAssertTrue(supervisor.config.enabled)
        XCTAssertEqual(try world.status().first?.modelIdentity, "/Models/b")
    }

    func testUnloadDisablesDesiredEndpointAndDoesNotRestartIt() async throws {
        let (supervisor, world) = makeSupervisor()
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        let server = try XCTUnwrap(try world.status().first)
        let unloaded = await supervisor.unloadServer(server)
        XCTAssertTrue(unloaded)
        XCTAssertFalse(supervisor.config.enabled)
        await supervisor.reconcile()
        XCTAssertFalse(try world.status().contains { $0.state == "running" })
    }

    func testIntentionalEnableSwapAndAddRecordServedButAutomaticRestartsDoNot() async throws {
        let (supervisor, world) = makeSupervisor()
        let tracker = UsageTracker(store: JSONStore<UsageStamp>(fileURL: temporaryURL("usage.json")))
        var served: [String] = []
        supervisor.onUserServeStarted = { path in served.append(path); tracker.recordServed(path) }

        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        await supervisor.reconcile()
        await supervisor.swap(to: "/Models/b")
        await supervisor.reconcile()
        await supervisor.addSlot(modelPath: "/Models/c", port: 8767)
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/a", "/Models/b", "/Models/c"])
        XCTAssertNotNil(tracker.lastServedByPath["/Models/c"])
        let stamps = tracker.lastServedByPath

        world.kill(port: 8766)
        await supervisor.reconcile()
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/a", "/Models/b", "/Models/c"])
        XCTAssertEqual(tracker.lastServedByPath, stamps)
    }

    func testUserEnableExistingMatchingServerRecordsIntentionalSelection() async {
        let (supervisor, world) = makeSupervisor()
        world.preload(repo: "/Models/a", port: 8766)
        var served: [String] = []
        supervisor.onUserServeStarted = { served.append($0) }
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        XCTAssertEqual(served, ["/Models/a"])
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/a"])
    }

    func testDisabledSlotEditsAndRoleOnlyChangesDoNotRecordServing() async throws {
        let (supervisor, _) = makeSupervisor()
        var served: [String] = []
        supervisor.onUserServeStarted = { served.append($0) }
        await supervisor.addSlot(modelPath: "/Models/a", port: 8766)
        await supervisor.reconcile()
        let id = try XCTUnwrap(supervisor.fleet.slots.first?.id)
        served = []
        await supervisor.updateSlot(id: id, modelPath: "/Models/a", port: 8766, role: .coding)
        XCTAssertTrue(served.isEmpty)
        await supervisor.setSlotEnabled(id: id, false)
        await supervisor.swapSlot(id: id, to: "/Models/b")
        await supervisor.updateSlot(id: id, modelPath: "/Models/c", port: 8766, role: .coding)
        XCTAssertTrue(served.isEmpty)
        await supervisor.setSlotEnabled(id: id, true)
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/c"])
        await supervisor.swapSlot(id: id, to: "/Models/d")
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/c", "/Models/d"])
        await supervisor.updateSlot(id: id, modelPath: "/Models/e", port: 8766, role: .coding)
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/c", "/Models/d", "/Models/e"])
    }

    func testFailedStartAndRejectedUserOperationsDoNotRecordServing() async {
        let failing = EndpointSupervisor(lifecycle: ServeLifecycle(preview: { _, _ in "hash" }, start: { _, _, _ in throw StubError.offline }, stop: { _ in }), statusProvider: { [] }, store: JSONStore<EndpointConfig>(fileURL: storeURL))
        var served: [String] = []
        failing.onUserServeStarted = { served.append($0) }
        await failing.enable(modelPath: "/Models/a", port: 8766)
        await failing.swap(to: "/Models/b")
        await failing.addSlot(modelPath: "/Models/c", port: 8767)
        XCTAssertTrue(served.isEmpty)

        let (supervisor, world) = makeSupervisor()
        supervisor.onUserServeStarted = { served.append($0) }
        supervisor.isVerified = { _ in false }
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        XCTAssertTrue(served.isEmpty)
        supervisor.isVerified = nil
        world.statusError = StubError.offline
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        XCTAssertTrue(served.isEmpty)
        world.statusError = nil
        world.preload(repo: "/Models/other", port: 8766)
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        XCTAssertTrue(served.isEmpty)
    }

    func testUnrelatedAutomaticFleetRestartDuringUserAddDoesNotRecordOldModel() async {
        let (supervisor, world) = makeSupervisor()
        var served: [String] = []
        supervisor.onUserServeStarted = { served.append($0) }
        await supervisor.addSlot(modelPath: "/Models/a", port: 8766)
        await supervisor.reconcile()
        served = []
        world.kill(port: 8766)
        await supervisor.addSlot(modelPath: "/Models/b", port: 8767)
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/b"])
    }

    func testAcceptedStartWaitsForAuthoritativeRunningAndRecordsOnce() async {
        let (supervisor, world) = makeSupervisor()
        world.survives = false
        var served: [String] = []
        supervisor.onUserServeStarted = { served.append($0) }
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        XCTAssertEqual(supervisor.state, .waitingForServer)
        XCTAssertTrue(served.isEmpty)
        await supervisor.reconcile()
        XCTAssertTrue(served.isEmpty)
        world.preload(repo: "/Models/a", port: 8766)
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/a"])
        await supervisor.reconcile()
        XCTAssertEqual(served, ["/Models/a"])
    }

    func testPendingIntentClearsAfterStatusFailureOrDisable() async {
        let (supervisor, world) = makeSupervisor()
        world.survives = false
        var served: [String] = []
        supervisor.onUserServeStarted = { served.append($0) }
        await supervisor.enable(modelPath: "/Models/a", port: 8766)
        world.statusError = StubError.offline
        await supervisor.reconcile()
        world.statusError = nil
        world.preload(repo: "/Models/a", port: 8766)
        await supervisor.reconcile()
        XCTAssertTrue(served.isEmpty)

        world.kill(port: 8766)
        await supervisor.enable(modelPath: "/Models/b", port: 8766)
        await supervisor.disable()
        world.preload(repo: "/Models/b", port: 8766)
        await supervisor.reconcile()
        XCTAssertTrue(served.isEmpty)
    }

    // MARK: - Reconcile matrix

    func testDisabledConfigStaysDisabledAndNeverStarts() async {
        let lifecycle = LifecycleRecorder()
        let (supervisor, _) = makeSupervisor(lifecycle: lifecycle)

        await supervisor.reconcile()

        XCTAssertEqual(supervisor.state, .disabled)
        XCTAssertTrue(lifecycle.events.isEmpty)
    }

    func testEnabledWithRunningMatchingServerReportsRunning() async {
        let world = FakeServeWorld()
        world.preload(repo: "/Models/q4", port: 8766)
        let (supervisor, _) = makeSupervisor(world: world)
        await supervisor.enable(modelPath: "/Models/q4", port: 8766)

        XCTAssertEqual(supervisor.state, .running(modelPath: "/Models/q4", port: 8766))
    }

    // MARK: - Port text validation (no silent coercion)

    func testNonNumericPortTextIsRefusedWithoutEnabling() async {
        let lifecycle = LifecycleRecorder()
        let (supervisor, _) = makeSupervisor(lifecycle: lifecycle)

        await supervisor.enable(modelPath: "/Models/q4", portText: "8o80")

        XCTAssertEqual(supervisor.state, .disabled)
        XCTAssertFalse(supervisor.config.enabled)
        XCTAssertEqual(supervisor.lastError, "Port must be a number between 1 and 65535.")
        XCTAssertTrue(lifecycle.events.isEmpty)
    }

    func testOutOfRangePortTextIsRefused() async {
        let (supervisor, _) = makeSupervisor()

        await supervisor.enable(modelPath: "/Models/q4", portText: "99999")

        XCTAssertEqual(supervisor.state, .disabled)
        XCTAssertFalse(supervisor.config.enabled)
        XCTAssertEqual(supervisor.lastError, "Port must be a number between 1 and 65535.")
    }

    func testEmptyPortTextUsesTheDefaultPort() async {
        let lifecycle = LifecycleRecorder()
        let (supervisor, _) = makeSupervisor(lifecycle: lifecycle)

        await supervisor.enable(modelPath: "/Models/q4", portText: "  ")

        XCTAssertEqual(supervisor.config.port, EndpointConfig.defaultPort)
        XCTAssertEqual(supervisor.state, .waitingForServer)
        XCTAssertNil(supervisor.lastError)
    }

    func testEnabledWithoutServerStartsViaPreviewHashFlow() async {
        let lifecycle = LifecycleRecorder()
        let (supervisor, _) = makeSupervisor(lifecycle: lifecycle)
        await supervisor.enable(modelPath: "/Models/q4", port: 8766)

        XCTAssertEqual(supervisor.state, .waitingForServer)
        XCTAssertEqual(lifecycle.events, [
            "preview:/Models/q4:8766",
            "start:/Models/q4:8766:hash-1",
        ])

        // The next reconcile sees the authoritative running server.
        await supervisor.reconcile()
        XCTAssertEqual(supervisor.state, .running(modelPath: "/Models/q4", port: 8766))
    }

    func testRunningDifferentModelOnConfiguredPortIsMismatchNotRestart() async {
        let lifecycle = LifecycleRecorder()
        let world = FakeServeWorld()
        world.preload(repo: "/Models/other", port: 8766)
        let (supervisor, _) = makeSupervisor(world: world, lifecycle: lifecycle)
        await supervisor.enable(modelPath: "/Models/q4", port: 8766)

        XCTAssertEqual(supervisor.state, .modelMismatch(servedModel: "other", port: 8766))
        XCTAssertTrue(lifecycle.events.isEmpty)
    }

    func testCrashLoopGuardStopsRestartingAfterLimit() async {
        let lifecycle = LifecycleRecorder()
        let world = FakeServeWorld()
        world.survives = false
        let (supervisor, _) = makeSupervisor(world: world, lifecycle: lifecycle)
        await supervisor.enable(modelPath: "/Models/q4", port: 8766)
        await supervisor.reconcile()
        await supervisor.reconcile()

        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("start") }.count, 3)

        await supervisor.reconcile()

        if case .degraded = supervisor.state {} else {
            XCTFail("expected degraded, got \(supervisor.state)")
        }
        XCTAssertEqual(lifecycle.events.filter { $0.hasPrefix("start") }.count, 3)
    }

    func testStatusUnavailablePreservesLastKnownState() async {
        let world = FakeServeWorld()
        world.statusError = StubError.offline
        let (supervisor, _) = makeSupervisor(world: world)
        await supervisor.enable(modelPath: "/Models/q4", port: 8766)

        XCTAssertEqual(supervisor.state, .disabled)  // initial state preserved
        XCTAssertTrue(supervisor.lastError?.contains("unavailable") == true)
    }

    // MARK: - Verification gate

    func testEnableRefusesUnverifiedModelWithoutOverride() async {
        let lifecycle = LifecycleRecorder()
        let (supervisor, _) = makeSupervisor(lifecycle: lifecycle)
        supervisor.isVerified = { _ in false }

        await supervisor.enable(modelPath: "/Models/q4", port: 8766)

        XCTAssertFalse(supervisor.config.enabled)
        XCTAssertTrue(supervisor.lastError?.contains("not verified") == true)
        XCTAssertTrue(lifecycle.events.isEmpty)
    }

    func testEnableAllowsUnverifiedWithExplicitOverride() async {
        let lifecycle = LifecycleRecorder()
        let (supervisor, _) = makeSupervisor(lifecycle: lifecycle)
        supervisor.isVerified = { _ in false }

        await supervisor.enable(modelPath: "/Models/q4", port: 8766, allowUnverified: true)

        XCTAssertTrue(supervisor.config.enabled)
        XCTAssertFalse(lifecycle.events.isEmpty)
    }

    // MARK: - Swap and disable

    func testSwapStopsCurrentAndStartsNewModelOnSamePort() async {
        let lifecycle = LifecycleRecorder()
        let world = FakeServeWorld()
        world.preload(repo: "/Models/q4", port: 8766)
        let (supervisor, _) = makeSupervisor(world: world, lifecycle: lifecycle)
        await supervisor.enable(modelPath: "/Models/q4", port: 8766)
        XCTAssertEqual(supervisor.state, .running(modelPath: "/Models/q4", port: 8766))

        await supervisor.swap(to: "/Models/q8")

        XCTAssertEqual(supervisor.config.modelPath, "/Models/q8")
        XCTAssertEqual(lifecycle.events, [
            "stop:8766",
            "preview:/Models/q8:8766",
            "start:/Models/q8:8766:hash-1",
        ])
    }

    func testDisableStopsOurServerAndPersists() async throws {
        let lifecycle = LifecycleRecorder()
        let world = FakeServeWorld()
        world.preload(repo: "/Models/q4", port: 8766)
        let (supervisor, _) = makeSupervisor(world: world, lifecycle: lifecycle)
        await supervisor.enable(modelPath: "/Models/q4", port: 8766)

        await supervisor.disable()

        XCTAssertEqual(supervisor.state, .disabled)
        XCTAssertEqual(lifecycle.events, ["stop:8766"])
        // Persistence moved to the fleet store in spec 09 P1; the legacy
        // endpoint-config.json is now a read-only migration source.
        let fleetURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("endpoint-fleet.json")
        let persisted = try JSONStore<EndpointFleetConfig>(fileURL: fleetURL).load()
        XCTAssertEqual(persisted.first?.slots.first?.enabled, false)
    }

    // MARK: - LaunchAgentManager

    func testPlistPreviewContainsLabelArgumentsAndRunAtLoad() throws {
        let home = try makeHome()
        let manager = LaunchAgentManager(home: home, run: { _, _ in "" }, uid: 501)
        let plan = LoginItemPlan(slot: EndpointSlot(enabled: true, port: 8766, modelPath: "/Models/q4"), fleetURL: storeURL, agentPath: "/opt/mlx-agent", arguments: WorkbenchAPI.serveArguments(model: "/Models/q4", runtime: "auto", port: 8766, receipts: home.path, previewHash: "hash"))

        let plist = try manager.plistPreview(plan: plan)

        XCTAssertTrue(plist.contains("<string>ai.cavi.mlxworkbench.endpoint</string>"))
        XCTAssertTrue(plist.contains("<string>/opt/mlx-agent/scripts/mlx-agent</string>"))
        XCTAssertTrue(plist.contains("<string>--path</string>"))
        XCTAssertTrue(plist.contains("<string>/Models/q4</string>"))
        XCTAssertTrue(plist.contains("<string>8766</string>"))
        XCTAssertTrue(plist.contains("<key>RunAtLoad</key>"))
        XCTAssertTrue(plist.contains("<key>KeepAlive</key>"))
    }

    func testInstallWritesPlistAndBootstrapsViaLaunchctlArgv() throws {
        let home = try makeHome()
        let invocations = InvocationRecorder()
        let manager = LaunchAgentManager(home: home, run: { executable, argv in
            invocations.record(executable: executable, argv: argv)
            return ""
        }, uid: 501)
        let plan = LoginItemPlan(slot: EndpointSlot(enabled: true, port: 8766, modelPath: "/Models/q4"), fleetURL: storeURL, agentPath: "/opt/mlx-agent", arguments: WorkbenchAPI.serveArguments(model: "/Models/q4", runtime: "auto", port: 8766, receipts: home.path, previewHash: "hash"))

        try manager.install(plan: plan)

        XCTAssertTrue(manager.isInstalled)
        let calls = invocations.values
        XCTAssertEqual(calls.last?.executable, "/bin/launchctl")
        XCTAssertEqual(calls.last?.argv, [
            "bootstrap", "gui/501",
            home.appendingPathComponent("Library/LaunchAgents/ai.cavi.mlxworkbench.endpoint.plist").path,
        ])
    }

    func testUninstallBootsOutAndRemovesPlist() throws {
        let home = try makeHome()
        let invocations = InvocationRecorder()
        let manager = LaunchAgentManager(home: home, run: { executable, argv in
            invocations.record(executable: executable, argv: argv)
            return ""
        }, uid: 501)
        let plan = LoginItemPlan(slot: EndpointSlot(enabled: true, port: 8766, modelPath: "/Models/q4"), fleetURL: storeURL, agentPath: "/opt/mlx-agent", arguments: WorkbenchAPI.serveArguments(model: "/Models/q4", runtime: "auto", port: 8766, receipts: home.path, previewHash: "hash"))
        try manager.install(plan: plan)

        try manager.uninstall()

        XCTAssertFalse(manager.isInstalled)
        XCTAssertTrue(invocations.values.contains { $0.argv == ["bootout", "gui/501/ai.cavi.mlxworkbench.endpoint"] })
    }

    // MARK: - Helpers

    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        storeURL = temporaryURL("endpoint-config.json")
    }

    private func makeSupervisor(
        world: FakeServeWorld? = nil,
        lifecycle: LifecycleRecorder? = nil
    ) -> (EndpointSupervisor, FakeServeWorld) {
        let world = world ?? FakeServeWorld()
        let recorder = lifecycle ?? LifecycleRecorder()
        world.recorder = recorder
        let supervisor = EndpointSupervisor(
            lifecycle: world.lifecycle,
            statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: storeURL),
            maxRestarts: 3,
            restartWindow: 300
        )
        return (supervisor, world)
    }

    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-endpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private nonisolated func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-endpoint-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    private enum StubError: Error { case offline }
}

private actor EndpointStopGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class InvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(executable: String, argv: [String])] = []
    var values: [(executable: String, argv: [String])] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func record(executable: String, argv: [String]) {
        lock.lock()
        recorded.append((executable, argv))
        lock.unlock()
    }
}
