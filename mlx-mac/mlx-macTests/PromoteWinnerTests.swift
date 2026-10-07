import Foundation
import XCTest

@testable import mlx_workbench

/// "Promote winner" chains a comparison verdict into a durable preferred
/// model; these pin the write path and its persistence across relaunch.
@MainActor
final class PromoteWinnerTests: XCTestCase {
    func testSetPreferredModelUpdatesPreferences() {
        let host = AppHost(config: Config.defaults())

        host.setPreferredModel("/models/winner", for: .coding)

        XCTAssertEqual(host.recommendationPreferences.preferredModelIDs[.coding], "/models/winner")
    }

    func testSetPreferredModelKeepsOtherUseCases() {
        let host = AppHost(config: Config.defaults())

        host.setPreferredModel("/models/a", for: .coding)
        host.setPreferredModel("/models/b", for: .reasoning)

        XCTAssertEqual(host.recommendationPreferences.preferredModelIDs[.coding], "/models/a")
        XCTAssertEqual(host.recommendationPreferences.preferredModelIDs[.reasoning], "/models/b")
    }

    func testPreferredModelSurvivesRelaunchViaTheStore() throws {
        let storeURL = try temporaryStoreURL()

        let first = AppHost(
            config: Config.defaults(),
            preferencesStore: JSONStore<RecommendationPreferences>(fileURL: storeURL)
        )
        first.setPreferredModel("/models/winner", for: .reasoning)

        let relaunched = AppHost(
            config: Config.defaults(),
            preferencesStore: JSONStore<RecommendationPreferences>(fileURL: storeURL)
        )
        XCTAssertEqual(relaunched.recommendationPreferences.preferredModelIDs[.reasoning], "/models/winner")
    }

    func testMissingPreferencesStoreYieldsDefaults() throws {
        let storeURL = try temporaryStoreURL()

        let host = AppHost(
            config: Config.defaults(),
            preferencesStore: JSONStore<RecommendationPreferences>(fileURL: storeURL)
        )

        XCTAssertEqual(host.recommendationPreferences, .defaults)
    }

    func testFailedPreferenceSaveKeepsPreviouslySavedChoice() throws {
        let url = try temporaryStoreURL()
        let durable = JSONStore<RecommendationPreferences>(fileURL: url)
        try durable.replaceAll([.defaults])
        let failing = JSONStore<RecommendationPreferences>(fileURL: url, replaceItem: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        let host = AppHost(config: Config.defaults(), preferencesStore: failing)

        host.setPreferredModel("/models/unsaved", for: .coding)

        XCTAssertEqual(host.recommendationPreferences, .defaults)
        XCTAssertEqual(try durable.load(), [.defaults])
        XCTAssertNotNil(host.lastError)
    }

    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("recommendation-preferences.json")
    }
}
