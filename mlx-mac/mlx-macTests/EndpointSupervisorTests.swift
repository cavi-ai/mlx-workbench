import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class EndpointSupervisorTests: XCTestCase {
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
        let config = EndpointConfig(enabled: true, port: 8766, modelPath: "/Models/q4", installedAtLogin: false)

        let plist = try manager.plistPreview(config: config, agentPath: "/opt/mlx-agent")

        XCTAssertTrue(plist.contains("<string>ai.cavi.mlxworkbench.endpoint</string>"))
        XCTAssertTrue(plist.contains("<string>/opt/mlx-agent/scripts/mlx-agent</string>"))
        XCTAssertTrue(plist.contains("<string>--repo</string>"))
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
        let config = EndpointConfig(enabled: true, port: 8766, modelPath: "/Models/q4", installedAtLogin: false)

        try manager.install(config: config, agentPath: "/opt/mlx-agent")

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
        let config = EndpointConfig(enabled: true, port: 8766, modelPath: "/Models/q4", installedAtLogin: false)
        try manager.install(config: config, agentPath: "/opt/mlx-agent")

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
