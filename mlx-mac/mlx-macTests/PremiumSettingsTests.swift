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
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-settings-\(UUID().uuidString)")
            .appendingPathComponent("workflows.json")
        let api = ModelWorkflowAPI(
            convertPreview: { _, _, _ in [:] },
            convertStart: { _, _, _, _ in [:] },
            convertStatus: { [] },
            servePreview: { _, _, _ in [:] },
            serveStart: { _, _, _, _ in [:] },
            serveStatus: { [] },
            serveStop: { _ in [:] }
        )
        let host = AppHost(
            configModule: ConfigModule(pathOverride: temporaryConfigURL().path),
            config: Config.defaults(),
            modelWorkflowAPI: api,
            modelWorkflowPersistence: .live(store: ModelWorkflowStore(fileURL: storeURL))
        )

        host.applyFeatureToggles()
        XCTAssertNotNil(host.modelWorkflow.completionVerifier)

        var off = host.config
        off.verificationEnabled = false
        _ = host.saveConfig(off)

        XCTAssertNil(host.modelWorkflow.completionVerifier)
    }

    private func temporaryConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-config-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }
}
