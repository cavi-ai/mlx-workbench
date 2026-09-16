import Foundation
import XCTest

@testable import mlx_workbench

/// Spec 09 P1: fleet store migration + invariants, and the fleet-shaped
/// supervisor internals behind the single-slot shim.
@MainActor
final class EndpointFleetTests: XCTestCase {
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
        XCTAssertEqual(supervisor.fleet.slots.count, EndpointFleetConfig.maxSlots)

        await supervisor.addSlot(modelPath: "/Models/e", port: 8771)
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
