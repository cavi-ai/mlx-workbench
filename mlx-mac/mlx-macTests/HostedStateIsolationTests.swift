import Foundation
import XCTest

@testable import mlx_workbench

/// Hosted unit tests run inside the app; no default state location may
/// resolve into the user's Application Support, config, or XDG state directory.
@MainActor
final class HostedStateIsolationTests: XCTestCase {
    func testDefaultStateLocationsAvoidUserDirectories() {
        let defaults = [
            JSONStore<RecommendationPreferences>.defaultFileURL("recommendation-preferences.json"),
            VerificationStore.defaultFileURL(),
            ModelWorkflowStore.defaultFileURL(),
            ComparisonOutputStore.defaultRoot(),
            CatalogStore().cacheURL(),
            ConvertedSourceRecovery.journalURL,
            URL(fileURLWithPath: FleetRouter.defaultTargetPath),
            URL(fileURLWithPath: ConfigModule().configPath()),
            WebConvertQueue.defaultPath(),
        ]

        for url in defaults {
            for directory in userStateDirectories() {
                XCTAssertFalse(Self.isWithin(url, directory), "\(url.path) resolves inside \(directory.path)")
            }
        }
    }

    func testDefaultAppHostPersistsBeneathAFreshPerTestRoot() throws {
        let root = WorkbenchStatePaths.hostedTestRoot
        XCTAssertTrue(Bundle(for: Self.self).principalClass == HostedTestStateRoot.self)
        XCTAssertTrue(Self.isWithin(root, FileManager.default.temporaryDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "each test starts on an empty root")

        let host = AppHost(config: Config.defaults())
        host.setPreferredModel("/models/winner", for: .coding)
        host.usage.recordServed("/models/winner")

        let support = WorkbenchStatePaths.applicationSupport()
        XCTAssertTrue(Self.isWithin(support, root))
        let preferences = try JSONStore<RecommendationPreferences>(
            fileURL: support.appendingPathComponent("recommendation-preferences.json")
        ).load()
        XCTAssertEqual(preferences.first?.preferredModelIDs[.coding], "/models/winner")
        let usage = try JSONStore<UsageStamp>(fileURL: support.appendingPathComponent("usage-stamps.json")).load()
        XCTAssertEqual(usage.map(\.path), ["/models/winner"])
    }

    private func userStateDirectories() -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let config = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        let state = environment["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/state", isDirectory: true)
        return [applicationSupport, config, state].map { $0.appendingPathComponent("mlx-workbench", isDirectory: true) }
    }

    private static func isWithin(_ url: URL, _ directory: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return path == parent || path.hasPrefix(parent + "/")
    }
}
