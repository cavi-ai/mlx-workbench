import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class EndpointSupervisorTests: XCTestCase {
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
        let persisted = try JSONStore<EndpointConfig>(fileURL: storeURL).load()
        XCTAssertEqual(persisted.first?.enabled, false)
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

/// A mutable fake serve world: start adds a running server (unless the run
/// is configured to crash), stop removes it, status reports the truth.
private final class FakeServeWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [ServerInfo] = []
    var recorder: LifecycleRecorder?
    /// When false, started servers vanish immediately (crash-loop scenario).
    var survives = true
    var statusError: Error?

    func preload(repo: String, port: Int) {
        lock.lock()
        servers.append(ServerInfo(repo: repo, runtime: "mlx", port: port, pid: 1, state: "running", logPath: nil, startedAt: nil, receipt: "r"))
        lock.unlock()
    }

    func status() throws -> [ServerInfo] {
        if let statusError { throw statusError }
        lock.lock()
        defer { lock.unlock() }
        return servers
    }

    var lifecycle: ServeLifecycle {
        ServeLifecycle(
            preview: { modelPath, port in
                self.recorder?.record("preview:\(modelPath):\(port)")
                return "hash-1"
            },
            start: { modelPath, port, hash in
                self.recorder?.record("start:\(modelPath):\(port):\(hash)")
                self.lock.lock()
                if self.survives {
                    self.servers.append(ServerInfo(repo: modelPath, runtime: "mlx", port: port, pid: 1, state: "running", logPath: nil, startedAt: nil, receipt: "r"))
                }
                self.lock.unlock()
            },
            stop: { port in
                self.recorder?.record("stop:\(port)")
                self.lock.lock()
                self.servers.removeAll { $0.port == port }
                self.lock.unlock()
            }
        )
    }
}

private final class LifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func record(_ event: String) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
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
