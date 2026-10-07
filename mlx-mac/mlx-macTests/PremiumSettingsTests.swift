import Foundation
import XCTest

@testable import mlx_workbench

@MainActor
final class PremiumSettingsTests: XCTestCase {
    // MARK: - Config defaults and coercion

    func testDefaultsEnablePremiumFeatures() {
        let config = Config.defaults()
        XCTAssertTrue(config.verificationEnabled)
        XCTAssertTrue(config.watchEnabled)
        XCTAssertEqual(config.fitReserveGB, 4)
        XCTAssertEqual(config.reclaimStaleDays, 60)
        XCTAssertEqual(config.comparisonMaxTokens, 512)
    }

    func testConfigRoundTripsPremiumKeys() throws {
        let url = temporaryConfigURL()
        let module = ConfigModule(pathOverride: url.path)
        var config = Config.defaults()
        config.verificationEnabled = false
        config.watchEnabled = false
        config.fitReserveGB = 8.5
        config.reclaimStaleDays = 30
        config.comparisonMaxTokens = 256

        _ = try module.save(config)
        let loaded = module.load()

        XCTAssertFalse(loaded.verificationEnabled)
        XCTAssertFalse(loaded.watchEnabled)
        XCTAssertEqual(loaded.fitReserveGB, 8.5)
        XCTAssertEqual(loaded.reclaimStaleDays, 30)
        XCTAssertEqual(loaded.comparisonMaxTokens, 256)
    }

    func testOldConfigWithoutPremiumKeysGetsDefaults() throws {
        let url = temporaryConfigURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"q_bits\": 4}".utf8).write(to: url)

        let loaded = ConfigModule(pathOverride: url.path).load()

        XCTAssertTrue(loaded.verificationEnabled)
        XCTAssertTrue(loaded.watchEnabled)
        XCTAssertEqual(loaded.fitReserveGB, 4)
    }

    func testOutOfRangePremiumValuesFallBackToDefaults() throws {
        let url = temporaryConfigURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"fit_reserve_gb\": 99, \"reclaim_stale_days\": 0, \"comparison_max_tokens\": 99999}".utf8).write(to: url)

        let loaded = ConfigModule(pathOverride: url.path).load()

        XCTAssertEqual(loaded.fitReserveGB, 4)
        XCTAssertEqual(loaded.reclaimStaleDays, 60)
        XCTAssertEqual(loaded.comparisonMaxTokens, 512)
    }

    // MARK: - Toggle application

    func testTogglingVerificationDetachesTheGate() async {
        let host = makeHost()

        host.applyFeatureToggles()
        XCTAssertNotNil(host.modelWorkflow.completionVerifier)

        var off = host.config
        off.verificationEnabled = false
        _ = host.saveConfig(off)

        XCTAssertNil(host.modelWorkflow.completionVerifier)
        host.watch.stopMonitoring()
    }

    // MARK: - Launch services

    func testHostedSuiteIsDetectedAsUnitTestHost() {
        XCTAssertTrue(AppHost.isHostedUnitTest())
        XCTAssertFalse(AppHost.isHostedUnitTest([:]))
    }

    func testUnitTestHostSkipsLiveServices() async {
        let scanned = expectation(description: "launch scan")
        scanned.isInverted = true
        let host = makeHost(scanned: scanned)

        host.startLiveServices(environment: ["XCTestConfigurationFilePath": "/tmp/session.xctestconfiguration"])
        await fulfillment(of: [scanned], timeout: 0.5)

        XCTAssertNil(host.modelWorkflow.completionVerifier)
        XCTAssertFalse(host.watch.isMonitoring)
        XCTAssertFalse(host.endpoint.isMonitoring)
        XCTAssertFalse(host.resources.isMonitoring)
    }

    func testNormalLaunchStartsLiveServices() async {
        let scanned = expectation(description: "launch scan")
        let host = makeHost(scanned: scanned)

        host.startLiveServices(environment: [:])
        await fulfillment(of: [scanned], timeout: 5)

        XCTAssertNotNil(host.modelWorkflow.completionVerifier)
        XCTAssertTrue(host.watch.isMonitoring)
        XCTAssertTrue(host.endpoint.isMonitoring)
        XCTAssertTrue(host.resources.isMonitoring)
        host.watch.stopMonitoring()
        host.endpoint.stopMonitoring()
    }

    /// Every live service is a fake or a temp-file store, so starting them
    /// never touches the user's endpoints, watch state, or model roots.
    private func makeHost(scanned: XCTestExpectation? = nil) -> AppHost {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-settings-\(UUID().uuidString)", isDirectory: true)
        let api = ModelWorkflowAPI(
            convertPreview: { _, _, _ in [:] },
            convertStart: { _, _, _, _ in [:] },
            convertStatus: { [] },
            servePreview: { _, _, _ in [:] },
            serveStart: { _, _, _, _ in [:] },
            serveStatus: { [] },
            serveStop: { _ in [:] }
        )
        return AppHost(
            configModule: ConfigModule(pathOverride: temporaryConfigURL().path),
            config: Config.defaults(),
            scanOperation: { _, _, _, _ in
                scanned?.fulfill()
                throw CancellationError()
            },
            modelWorkflowAPI: api,
            modelWorkflowPersistence: .live(store: ModelWorkflowStore(fileURL: root.appendingPathComponent("workflows.json"))),
            endpoint: EndpointSupervisor(
                lifecycle: FakeServeWorld().lifecycle,
                statusProvider: { [] },
                store: JSONStore<EndpointConfig>(fileURL: root.appendingPathComponent("endpoint-config.json"))
            ),
            watch: WatchCoordinator(
                watchDiff: { [] },
                watchSnapshot: {},
                fingerprint: { EnvironmentFingerprint(macOSVersion: "26.5", chip: "M4", mlxLMVersion: "0.24.0") },
                verifiedReports: { [] },
                alertStore: JSONStore<WatchAlert>(fileURL: root.appendingPathComponent("watch-alerts.json")),
                stateStore: JSONStore<WatchState>(fileURL: root.appendingPathComponent("watch-state.json"))
            )
        )
    }

    private func temporaryConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-config-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    // MARK: - Save idempotency

    func testSaveOverExistingConfigSucceeds() throws {
        let url = temporaryConfigURL()
        let module = ConfigModule(pathOverride: url.path)

        var first = Config.defaults()
        first.qBits = 4
        _ = try module.save(first)
        var second = Config.defaults()
        second.qBits = 8
        _ = try module.save(second)

        XCTAssertEqual(module.load().qBits, 8)
    }

    func testStaleFixedNameTempDoesNotBlockSave() throws {
        let url = temporaryConfigURL()
        let module = ConfigModule(pathOverride: url.path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Litter from the pre-replaceItemAt writer.
        try Data("stale".utf8).write(to: url.appendingPathExtension(".tmp"))

        _ = try module.save(Config.defaults())

        XCTAssertEqual(module.load().qBits, Config.defaults().qBits)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.appendingPathExtension(".tmp").path)
        )
    }

    func testSaveLeavesNoTempLitter() throws {
        let url = temporaryConfigURL()
        let module = ConfigModule(pathOverride: url.path)
        _ = try module.save(Config.defaults())
        _ = try module.save(Config.defaults())

        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path
        ).filter { $0.contains(".tmp") }
        XCTAssertEqual(leftovers, [])
    }
}
