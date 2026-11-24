import Foundation
import XCTest

@testable import mlx_workbench

/// Spec 09 P1: fleet store migration + invariants, and the fleet-shaped
/// supervisor internals behind the single-slot shim.
@MainActor
final class EndpointFleetTests: XCTestCase {
    func testSplashPresetArgumentsAndFleetReference() throws {
        var slot = EndpointSlot(enabled: false, port: 8766, modelPath: "/models/test", loadOnRequest: true)
        slot.splashPresetName = "editing"
        let decoded = try JSONDecoder().decode(EndpointSlot.self, from: JSONEncoder().encode(slot))
        XCTAssertEqual(decoded.splashPresetName, "editing")
        let args = WorkbenchAPI.serveArguments(model: slot.modelPath, runtime: "splash", port: slot.port,
            receipts: "/receipts", jit: true, profileName: slot.splashPresetName)
        XCTAssertTrue(args.contains("--profile"))
        XCTAssertTrue(args.contains("editing"))
        XCTAssertTrue(args.contains("/receipts"))
    }

    func testSplashPresetIncludesAllSourceSettingsAndDoesNotOverrideProfilePolicy() throws {
        let base: [String: Any] = ["splash_max_memory_gb": 24.0, "splash_max_context_tokens": 8192,
            "min_headroom_gb": 4.0, "idle_timeout": 300, "keep_loaded": false, "unload_under_pressure": true]
        var changed = base
        changed["execution_wait_seconds"] = 30
        let first = try XCTUnwrap(SplashPreset(name: "editing", settings: base))
        let second = try XCTUnwrap(SplashPreset(name: "editing", settings: changed))
        XCTAssertNotEqual(first, second)
        let policy = EndpointMemoryPolicy(idleTimeoutSeconds: 10, keepLoaded: false, minimumHeadroomGB: 2)
        let args = WorkbenchAPI.serveArguments(model: "/models/test", runtime: "splash", port: 8766,
            receipts: "/receipts", jit: true, memoryPolicy: policy, profileName: "editing")
        XCTAssertTrue(args.contains("--profile"))
        XCTAssertFalse(args.contains("--idle-timeout"))
        XCTAssertFalse(args.contains("--min-headroom-gb"))
        XCTAssertNil(ServeLaunch.retainedMemoryPolicy(policy, jit: true, splashPresetName: "editing"))
    }

    func testServeLaunchAgreesOnSplashProfileAndAcceleration() throws {
        let splash = try ServeLaunch.saved(splashPresetName: "editing", hasServingProfile: false, jit: true, accelerationRequested: false, thinkingOff: false)
        XCTAssertEqual(splash.runtime, "splash")
        XCTAssertEqual(splash.splashPresetName, "editing")
        XCTAssertFalse(splash.includesMemoryPolicy)
        XCTAssertThrowsError(try ServeLaunch.saved(splashPresetName: "editing", hasServingProfile: true, jit: true, accelerationRequested: false, thinkingOff: false))
        XCTAssertThrowsError(try ServeLaunch.saved(splashPresetName: "editing", hasServingProfile: false, jit: false, accelerationRequested: false, thinkingOff: false))
        XCTAssertThrowsError(try ServeLaunch.saved(splashPresetName: "editing", hasServingProfile: false, jit: true, accelerationRequested: true, thinkingOff: false))
        let strata = try ServeLaunch.saved(splashPresetName: nil, hasServingProfile: true, jit: true, accelerationRequested: false, thinkingOff: false)
        XCTAssertEqual(strata.runtime, "strata")
        XCTAssertTrue(strata.includesMemoryPolicy)
        XCTAssertThrowsError(try ServeLaunch.saved(splashPresetName: nil, hasServingProfile: true, jit: true, accelerationRequested: false, thinkingOff: true))
        let automatic = try ServeLaunch.saved(splashPresetName: nil, hasServingProfile: false, jit: false, accelerationRequested: false, thinkingOff: false)
        XCTAssertEqual(automatic.runtime, "auto")
        XCTAssertFalse(automatic.includesMemoryPolicy)
        XCTAssertNoThrow(try ServeLaunch.startNow(runtime: "splash", hasServingProfile: false, options: .init()))
        XCTAssertThrowsError(try ServeLaunch.startNow(runtime: "mlx_lm", hasServingProfile: false, options: LocalInferenceOptions(visionCache: true)))
        XCTAssertThrowsError(try ServeLaunch.startNow(runtime: "auto", hasServingProfile: true, options: LocalInferenceOptions(thinkingOff: true)))
        XCTAssertEqual(ServeLaunch.retainedMemoryPolicy(.automatic, jit: true, splashPresetName: nil), .automatic)
    }

    func testObservedIdleStopUsesIdentityBoundEngineOption() {
        let args = WorkbenchAPI.discoveredServiceArguments(action: "stop", port: 8766, receipts: "/receipts",
                                                            pid: 42, processStart: "birth", onlyWhenIdle: true)
        XCTAssertEqual(args, ["serve", "stop", "--port", "8766", "--receipts-dir", "/receipts",
                              "--expected-pid", "42", "--expected-start", "birth", "--if-idle"])
        XCTAssertFalse(WorkbenchAPI.discoveredServiceArguments(action: "stop", port: 8766, receipts: "/receipts",
                                                                 pid: 42, processStart: "birth").contains("--if-idle"))
    }

    func testAuthenticationReferenceIsNotTheCredentialAndRequiresJIT() throws {
        let token = "mlxw_" + String(repeating: "a", count: 64)
        let digest = EndpointCredentialStore.digest(token)
        var slot = EndpointSlot(enabled: false, port: 8766, modelPath: "/models/test", loadOnRequest: true)
        slot.apiKeySHA256 = digest
        let encoded = try JSONEncoder().encode(slot)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(token))
        XCTAssertEqual(try JSONDecoder().decode(EndpointSlot.self, from: encoded), slot)
        XCTAssertNoThrow(try EndpointFleetConfig(slots: [slot], installedAtLogin: false).validated())
        slot.loadOnRequest = false
        XCTAssertThrowsError(try EndpointFleetConfig(slots: [slot], installedAtLogin: false).validated())
        slot.loadOnRequest = true; slot.apiKeySHA256 = "plaintext-key"
        XCTAssertThrowsError(try EndpointFleetConfig(slots: [slot], installedAtLogin: false).validated())
    }

    func testProtectedServeArgumentsContainOnlyVerificationDigest() {
        let token = "mlxw_" + String(repeating: "b", count: 64)
        let digest = EndpointCredentialStore.digest(token)
        let arguments = WorkbenchAPI.serveArguments(model: "/models/test", runtime: "auto", port: 8766,
            receipts: "/receipts", jit: true, apiKeySHA256: digest)
        XCTAssertTrue(arguments.contains("--api-key-sha256"))
        XCTAssertTrue(arguments.contains(digest))
        XCTAssertFalse(arguments.contains(token))
        let unprotected = ServerInfo(path: "/models/test", port: 8766, pid: 42, state: "running")
        let protected = ServerInfo(path: "/models/test", port: 8766, pid: 42, state: "running", apiKeySHA256: digest)
        XCTAssertFalse(unprotected.sameProcess(as: protected))
        XCTAssertEqual(WireEndpoint(server: protected)?.apiKeySHA256, digest)
    }

    func testMemoryPolicySurvivesFleetPersistenceAndRejectsInvalidValues() throws {
        let urls = makeStoreURLs()
        let policy = EndpointMemoryPolicy(idleTimeoutSeconds: 300, keepLoaded: true, minimumHeadroomGB: 4)
        let fleet = EndpointFleetConfig(slots: [EndpointSlot(enabled: true, port: 8766,
            modelPath: "/Models/a", loadOnRequest: true, memoryPolicy: policy)], installedAtLogin: false)
        try makeStore(urls).save(fleet)
        XCTAssertEqual(makeStore(urls).load().config.slots.first?.memoryPolicy, policy)
        var invalid = fleet
        invalid.slots[0].memoryPolicy = EndpointMemoryPolicy(idleTimeoutSeconds: -1, keepLoaded: false, minimumHeadroomGB: nil)
        XCTAssertThrowsError(try invalid.validated())
    }

    // MARK: - Migration

    func testLegacyEnabledConfigMigratesToOneSlotFleet() throws {
        let urls = makeStoreURLs()
        let legacy = EndpointConfig(enabled: true, port: 8767, modelPath: "/Models/q4", installedAtLogin: true)
        try JSONStore<EndpointConfig>(fileURL: urls.legacy).replaceAll([legacy])

        let loaded = makeStore(urls).load()

        XCTAssertNil(loaded.problem)
        XCTAssertEqual(loaded.config.slots.count, 1)
        XCTAssertEqual(loaded.config.slots[0].enabled, true)
        XCTAssertEqual(loaded.config.slots[0].port, 8767)
        XCTAssertEqual(loaded.config.slots[0].modelPath, "/Models/q4")
        XCTAssertNil(loaded.config.slots[0].role)
        XCTAssertFalse(loaded.config.slots[0].usesJIT)
        XCTAssertTrue(loaded.config.installedAtLogin)
        // Migration persists once...
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.fleet.path))
        // ...and the legacy file stays readable and untouched.
        let reread = try JSONStore<EndpointConfig>(fileURL: urls.legacy).load()
        XCTAssertEqual(reread.first, legacy)
    }

    func testDisabledButRememberedLegacyConfigMigrates() throws {
        let urls = makeStoreURLs()
        let legacy = EndpointConfig(enabled: false, port: 9000, modelPath: "/Models/q8", installedAtLogin: false)
        try JSONStore<EndpointConfig>(fileURL: urls.legacy).replaceAll([legacy])

        let loaded = makeStore(urls).load()

        XCTAssertEqual(loaded.config.slots.count, 1)
        XCTAssertFalse(loaded.config.slots[0].enabled)
        XCTAssertEqual(loaded.config.slots[0].port, 9000)
        XCTAssertEqual(loaded.config.slots[0].modelPath, "/Models/q8")
    }

    func testNoLegacyConfigYieldsAnEmptyFleetWithoutCreatingAFile() {
        let urls = makeStoreURLs()

        let loaded = makeStore(urls).load()

        XCTAssertNil(loaded.problem)
        XCTAssertEqual(loaded.config, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls.fleet.path))
    }

    func testExistingFleetFileWinsOverLegacy() throws {
        let urls = makeStoreURLs()
        try JSONStore<EndpointConfig>(fileURL: urls.legacy).replaceAll([
            EndpointConfig(enabled: true, port: 8766, modelPath: "/Models/legacy", installedAtLogin: false),
        ])
        let fleet = EndpointFleetConfig(
            slots: [EndpointSlot(enabled: true, port: 8770, modelPath: "/Models/fleet", role: .coding)],
            installedAtLogin: false
        )
        try JSONStore<EndpointFleetConfig>(fileURL: urls.fleet).replaceAll([fleet])

        let loaded = makeStore(urls).load()

        XCTAssertEqual(loaded.config, fleet)
    }

    func testCorruptFleetFileReportsAProblemAndStaysInPlace() throws {
        let urls = makeStoreURLs()
        try Data("not-json".utf8).write(to: urls.fleet)

        let loaded = makeStore(urls).load()

        XCTAssertEqual(loaded.config, .empty)
        XCTAssertNotNil(loaded.problem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.fleet.path))
    }

    // MARK: - Invariants

    func testDuplicatePortsAreRejected() {
        let config = EndpointFleetConfig(slots: [
            EndpointSlot(enabled: true, port: 8766, modelPath: "/a"),
            EndpointSlot(enabled: true, port: 8766, modelPath: "/b"),
        ], installedAtLogin: false)
        XCTAssertThrowsError(try config.validated()) { error in
            XCTAssertEqual(error as? EndpointFleetValidation, .duplicatePort(8766))
        }
    }

    func testDuplicateRolesAreRejectedButUnassignedIsFirstClass() {
        let config = EndpointFleetConfig(slots: [
            EndpointSlot(enabled: true, port: 8766, modelPath: "/a", role: .coding),
            EndpointSlot(enabled: true, port: 8767, modelPath: "/b", role: .coding),
        ], installedAtLogin: false)
        XCTAssertThrowsError(try config.validated()) { error in
            XCTAssertEqual(error as? EndpointFleetValidation, .duplicateRole(.coding))
        }
        // Two unassigned slots are fine.
        let unassigned = EndpointFleetConfig(slots: [
            EndpointSlot(enabled: true, port: 8766, modelPath: "/a"),
            EndpointSlot(enabled: true, port: 8767, modelPath: "/b"),
        ], installedAtLogin: false)
        XCTAssertNoThrow(try unassigned.validated())
    }

    func testSlotCapIsEnforced() {
        let slots = (0..<EndpointFleetConfig.maxSlots + 1).map {
            EndpointSlot(enabled: false, port: 8766 + $0, modelPath: "/m\($0)")
        }
        XCTAssertThrowsError(try EndpointFleetConfig(slots: slots, installedAtLogin: false).validated()) { error in
            XCTAssertEqual(error as? EndpointFleetValidation, .tooManySlots(EndpointFleetConfig.maxSlots + 1))
        }
    }

    func testInvalidPortIsRejected() {
        let config = EndpointFleetConfig(slots: [
            EndpointSlot(enabled: true, port: 0, modelPath: "/a"),
        ], installedAtLogin: false)
        XCTAssertThrowsError(try config.validated()) { error in
            XCTAssertEqual(error as? EndpointFleetValidation, .invalidPort(0))
        }
    }

    // MARK: - Supervisor: multi-slot reconcile

    func testExplicitStartLeavesOtherMissingSlotsForTheMonitor() async throws {
        let world = FakeServeWorld()
        let lifecycle = LifecycleRecorder()
        world.recorder = lifecycle
        let supervisor = makeSupervisor(world: world)
        await supervisor.addSlot(modelPath: "/Models/first", port: 8766)
        world.kill(port: 8766)
        lifecycle.record("before-request")

        await supervisor.addSlot(modelPath: "/Models/requested", port: 8767)

        let requested = lifecycle.events.drop { $0 != "before-request" }.dropFirst()
        XCTAssertEqual(Array(requested), ["preview:/Models/requested:8767", "start:/Models/requested:8767:hash-1"])
        await supervisor.reconcile()
        XCTAssertEqual(try world.status().compactMap(\.port).sorted(), [8766, 8767])
    }

    func testReconcileStartsOnlyTheMissingSlot() async {
        let world = FakeServeWorld()
        world.preload(repo: "/Models/chat", port: 8767)
        let lifecycle = LifecycleRecorder()
        world.recorder = lifecycle
        let supervisor = makeSupervisor(world: world)

        await supervisor.addSlot(modelPath: "/Models/coding", port: 8766, role: .coding)
        await supervisor.addSlot(modelPath: "/Models/chat", port: 8767, role: .generalChat)
        lifecycle.record("reset-marker")
        world.kill(port: 8766)

        await supervisor.reconcile()

        // coding (8766) crashed out-of-band and restarts; chat (8767) is
        // still running and is left alone.
        let events = lifecycle.events.drop { $0 != "reset-marker" }.dropFirst()
        XCTAssertEqual(Array(events), [
            "preview:/Models/coding:8766",
            "start:/Models/coding:8766:hash-1",
        ])
        XCTAssertEqual(supervisor.slotStates.values.count, 2)
    }

    func testCrashLoopGuardIsPerSlot() async {
        let world = FakeServeWorld()
        world.survives = false
        let supervisor = makeSupervisor(world: world)
        await supervisor.addSlot(modelPath: "/Models/crasher", port: 8766)

        // Three failed attempts put the crasher into degraded on the next
        // pass — before the healthy slot even exists.
        await supervisor.reconcile()
        await supervisor.reconcile()
        await supervisor.reconcile()

        let crasher = supervisor.fleet.slots.first { $0.port == 8766 }!
        guard case .degraded = supervisor.slotStates[crasher.id] else {
            return XCTFail("expected the crashing slot to degrade, got \(String(describing: supervisor.slotStates[crasher.id]))")
        }

        // A degraded slot does not starve the others: the healthy slot gets
        // its own budget and comes up once the world stabilizes.
        world.survives = true
        await supervisor.addSlot(modelPath: "/Models/stable", port: 8767)
        await supervisor.reconcile()

        let stable = supervisor.fleet.slots.first { $0.port == 8767 }!
        XCTAssertEqual(supervisor.slotStates[stable.id], .running(modelPath: "/Models/stable", port: 8767))
        guard case .degraded = supervisor.slotStates[crasher.id] else {
            return XCTFail("expected the crasher to stay degraded")
        }
    }

    func testAddSlotRefusesDuplicatesAndCap() async {
        let supervisor = makeSupervisor()
        await supervisor.addSlot(modelPath: "/Models/a", port: 8766, role: .coding)

        await supervisor.addSlot(modelPath: "/Models/b", port: 8766)
        XCTAssertEqual(supervisor.lastError, EndpointFleetValidation.duplicatePort(8766).localizedDescription)
        XCTAssertEqual(supervisor.fleet.slots.count, 1)

        await supervisor.addSlot(modelPath: "/Models/b", port: 8767, role: .coding)
        XCTAssertEqual(supervisor.lastError, EndpointFleetValidation.duplicateRole(.coding).localizedDescription)
        XCTAssertEqual(supervisor.fleet.slots.count, 1)

        await supervisor.addSlot(modelPath: "/Models/b", port: 8768, role: .generalChat)
        await supervisor.addSlot(modelPath: "/Models/c", port: 8769, role: .reasoning)
        await supervisor.addSlot(modelPath: "/Models/d", port: 8770, role: .vision)
        await supervisor.addSlot(modelPath: "/Models/e", port: 8771)
        await supervisor.addSlot(modelPath: "/Models/f", port: 8772)
        await supervisor.addSlot(modelPath: "/Models/g", port: 8773)
        await supervisor.addSlot(modelPath: "/Models/h", port: 8774)
        XCTAssertEqual(supervisor.fleet.slots.count, EndpointFleetConfig.maxSlots)

        await supervisor.addSlot(modelPath: "/Models/i", port: 8775)
        XCTAssertNotNil(supervisor.lastError)
        XCTAssertEqual(supervisor.fleet.slots.count, EndpointFleetConfig.maxSlots)
    }

    func testAddSlotRespectsTheVerifiedGate() async {
        let supervisor = makeSupervisor()
        supervisor.isVerified = { _ in false }

        await supervisor.addSlot(modelPath: "/Models/unverified", port: 8766)

        XCTAssertEqual(supervisor.lastError, "This model is not verified. Run verification from its details page, or enable anyway.")
        XCTAssertTrue(supervisor.fleet.slots.isEmpty)
    }

    func testRemoveSlotStopsItsServerAndDropsItsState() async {
        let world = FakeServeWorld()
        let lifecycle = LifecycleRecorder()
        world.recorder = lifecycle
        let supervisor = makeSupervisor(world: world)
        await supervisor.addSlot(modelPath: "/Models/a", port: 8766)
        let id = supervisor.fleet.slots[0].id
        lifecycle.record("reset-marker")

        await supervisor.removeSlot(id: id)

        let events = lifecycle.events.drop { $0 != "reset-marker" }.dropFirst()
        XCTAssertEqual(Array(events), ["stop:8766"])
        XCTAssertTrue(supervisor.fleet.slots.isEmpty)
        XCTAssertNil(supervisor.slotStates[id])
        XCTAssertEqual(supervisor.state, .disabled)
    }

    func testSetSlotEnabledStopsAndRestarts() async {
        let world = FakeServeWorld()
        let lifecycle = LifecycleRecorder()
        world.recorder = lifecycle
        let supervisor = makeSupervisor(world: world)
        await supervisor.addSlot(modelPath: "/Models/a", port: 8766)
        let id = supervisor.fleet.slots[0].id

        await supervisor.setSlotEnabled(id: id, false)
        XCTAssertEqual(supervisor.slotStates[id], .disabled)
        XCTAssertTrue(lifecycle.events.contains("stop:8766"))

        await supervisor.setSlotEnabled(id: id, true)
        await supervisor.reconcile()
        XCTAssertEqual(supervisor.slotStates[id], .running(modelPath: "/Models/a", port: 8766))
    }

    func testSwapSlotKeepsThePortStable() async {
        let world = FakeServeWorld()
        let lifecycle = LifecycleRecorder()
        world.recorder = lifecycle
        let supervisor = makeSupervisor(world: world)
        await supervisor.addSlot(modelPath: "/Models/old", port: 8766)
        let id = supervisor.fleet.slots[0].id
        lifecycle.record("reset-marker")

        await supervisor.swapSlot(id: id, to: "/Models/new")
        await supervisor.reconcile()

        let events = lifecycle.events.drop { $0 != "reset-marker" }.dropFirst()
        XCTAssertEqual(Array(events), [
            "stop:8766",
            "preview:/Models/new:8766",
            "start:/Models/new:8766:hash-1",
        ])
        XCTAssertEqual(supervisor.slotStates[id], .running(modelPath: "/Models/new", port: 8766))
    }

    // MARK: - helpers

    private struct StoreURLs {
        let root: URL
        let legacy: URL
        let fleet: URL
    }

    private func makeStoreURLs() -> StoreURLs {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-fleet-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return StoreURLs(
            root: root,
            legacy: root.appendingPathComponent("endpoint-config.json"),
            fleet: root.appendingPathComponent("endpoint-fleet.json")
        )
    }

    private func makeStore(_ urls: StoreURLs) -> EndpointFleetStore {
        EndpointFleetStore(
            fleetStore: JSONStore<EndpointFleetConfig>(fileURL: urls.fleet),
            legacyStore: JSONStore<EndpointConfig>(fileURL: urls.legacy)
        )
    }

    private func makeSupervisor(world: FakeServeWorld = FakeServeWorld()) -> EndpointSupervisor {
        let urls = makeStoreURLs()
        return EndpointSupervisor(
            lifecycle: world.lifecycle,
            statusProvider: { try world.status() },
            store: JSONStore<EndpointConfig>(fileURL: urls.legacy),
            fleetStore: JSONStore<EndpointFleetConfig>(fileURL: urls.fleet),
            maxRestarts: 3,
            restartWindow: 300
        )
    }
}
