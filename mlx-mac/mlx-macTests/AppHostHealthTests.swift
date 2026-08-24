import Foundation
import XCTest

@testable import mlx_workbench

final class AppHostHealthTests: XCTestCase {
    func testNormalizeAgentPathTrimsWhitespace() async {
        let result = await MainActor.run { AppHost.normalizeAgentPath("  /tmp/mlx ") }
        XCTAssertEqual(result, "/tmp/mlx")
    }

    func testCheckAgentHealthReturnsNotConfiguredForBlankPath() async {
        let result = await MainActor.run { AppHost.checkAgentHealth(path: " \n\t ", cli: CLIProcess()) }
        XCTAssertEqual(result, .notConfigured)
    }

    func testCheckAgentHealthAcceptsLeadingAndTrailingWhitespace() async throws {
        let tmp = try makeTempDirectory()
        defer { cleanup(tmp) }

        let scriptsPath = tmp.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsPath, withIntermediateDirectories: true)
        let scriptPath = scriptsPath.appendingPathComponent("mlx-agent", isDirectory: false)
        FileManager.default.createFile(atPath: scriptPath.path, contents: Data("print('ok')".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: scriptPath.path)
        }

        let result = await MainActor.run { AppHost.checkAgentHealth(path: "  \(tmp.path)  ", cli: CLIProcess()) }
        XCTAssertEqual(result, .ready(path: tmp.path, cli: scriptPath.path))
    }

    func testCheckAgentHealthRejectsDirectoryWhereScriptPathShouldBeFile() async throws {
        let tmp = try makeTempDirectory()
        defer { cleanup(tmp) }

        let scriptDir = tmp.appendingPathComponent("scripts/mlx-agent", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)

        let result = await MainActor.run { AppHost.checkAgentHealth(path: tmp.path, cli: CLIProcess()) }
        switch result {
        case .notFound(let path, let cliPath):
            XCTAssertEqual(path, tmp.path)
            XCTAssertEqual(cliPath, scriptDir.path)
        default:
            XCTFail("expected notFound when mlx-agent is a directory, got \(result)")
        }
    }

    func testCLIProcessNormalizesPathBeforeHealthCheck() async throws {
        let tmp = try makeTempDirectory()
        defer { cleanup(tmp) }

        let scriptsPath = tmp.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsPath, withIntermediateDirectories: true)
        let scriptPath = scriptsPath.appendingPathComponent("mlx-agent", isDirectory: false)
        FileManager.default.createFile(atPath: scriptPath.path, contents: Data("print('ok')".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: scriptPath.path)
        }

        let health = await MainActor.run { CLIProcess().agentHealth(agentPath: "  \(tmp.path)  ") }
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.path, tmp.path)
        XCTAssertEqual(health.cli, scriptPath.path)
    }

    func testCatalogRefreshFailurePreservesCorruptStateAndActualDetail() async throws {
        let root = try makeTempDirectory()
        defer { cleanup(root) }

        let store = CatalogStore(appSupportDirectory: { root })
        let cacheDirectory = store.cacheURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: store.cacheURL())

        let client = CatalogClient(
            provider: ThrowingCatalogProvider(error: .invalidPayload("fixture payload rejected"))
        )
        let host = await MainActor.run {
            AppHost(
                catalogStore: store,
                catalogClient: client,
                config: Config.defaults(),
                now: { Date(timeIntervalSinceReferenceDate: 100) }
            )
        }

        await host.refreshCatalog()

        let state = await MainActor.run { host.catalog }
        switch state {
        case .corrupt(let message):
            XCTAssertTrue(message.contains("Metadata validation failed: fixture payload rejected"))
            XCTAssertFalse(message.contains("(message)"))
        default:
            XCTFail("expected corrupt state with refresh detail, got \(state)")
        }
    }

    func testCatalogMissingCacheReflectsProviderConfiguration() async throws {
        let configuredRoot = try makeTempDirectory()
        let unconfiguredRoot = try makeTempDirectory()
        defer {
            cleanup(configuredRoot)
            cleanup(unconfiguredRoot)
        }

        let configuredHost = await MainActor.run {
            AppHost(
                catalogStore: CatalogStore(appSupportDirectory: { configuredRoot }),
                catalogClient: CatalogClient(provider: StaticCatalogProvider()),
                config: Config.defaults(),
                now: { Date(timeIntervalSinceReferenceDate: 100) }
            )
        }
        let unconfiguredHost = await MainActor.run {
            AppHost(
                catalogStore: CatalogStore(appSupportDirectory: { unconfiguredRoot }),
                catalogClient: CatalogClient(),
                config: Config.defaults(),
                now: { Date(timeIntervalSinceReferenceDate: 100) }
            )
        }

        let configuredState = await MainActor.run { configuredHost.catalog }
        let unconfiguredState = await MainActor.run { unconfiguredHost.catalog }

        XCTAssertEqual(configuredState, .missing)
        switch unconfiguredState {
        case .unavailable(let message):
            XCTAssertFalse(message.isEmpty)
        default:
            XCTFail("expected unavailable state without a provider, got \(unconfiguredState)")
        }
    }

    func testRefreshWithoutProviderAndCacheRemainsUnavailable() async throws {
        let root = try makeTempDirectory()
        defer { cleanup(root) }

        let host = await MainActor.run {
            AppHost(
                catalogStore: CatalogStore(appSupportDirectory: { root }),
                catalogClient: CatalogClient(),
                config: Config.defaults(),
                now: { Date(timeIntervalSinceReferenceDate: 100) }
            )
        }

        await host.refreshCatalog()

        let state = await MainActor.run { host.catalog }
        switch state {
        case .unavailable(let message):
            XCTAssertFalse(message.isEmpty)
        default:
            XCTFail("expected unavailable state after no-provider refresh, got \(state)")
        }
    }

    func testRefreshFailurePreservesCurrentAndStaleFreshness() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let currentRoot = try makeTempDirectory()
        let staleRoot = try makeTempDirectory()
        defer {
            cleanup(currentRoot)
            cleanup(staleRoot)
        }

        let currentStore = CatalogStore(appSupportDirectory: { currentRoot })
        try currentStore.save(makeSnapshot(fetchedAt: now.addingTimeInterval(-1)))
        let staleStore = CatalogStore(appSupportDirectory: { staleRoot })
        try staleStore.save(makeSnapshot(fetchedAt: now.addingTimeInterval(-CatalogFreshness.metadataTTL - 1)))

        let failingClient = CatalogClient(
            provider: ThrowingCatalogProvider(error: .unavailable("fixture provider offline"))
        )
        let currentHost = await MainActor.run {
            AppHost(
                catalogStore: currentStore,
                catalogClient: failingClient,
                config: Config.defaults(),
                now: { now }
            )
        }
        let staleHost = await MainActor.run {
            AppHost(
                catalogStore: staleStore,
                catalogClient: failingClient,
                config: Config.defaults(),
                now: { now }
            )
        }

        await currentHost.refreshCatalog()
        await staleHost.refreshCatalog()

        let currentState = await MainActor.run { currentHost.catalog }
        let staleState = await MainActor.run { staleHost.catalog }
        switch currentState {
        case .currentFailure(_, let message):
            XCTAssertTrue(message.contains("fixture provider offline"))
        default:
            XCTFail("expected current freshness after refresh failure, got \(currentState)")
        }
        switch staleState {
        case .staleFailure(_, let message):
            XCTAssertTrue(message.contains("fixture provider offline"))
        default:
            XCTFail("expected stale freshness after refresh failure, got \(staleState)")
        }
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSnapshot(fetchedAt: Date) -> CatalogSnapshot {
        CatalogSnapshot(
            provider: "fixture-provider",
            source: "fixtures/catalog.json",
            revision: "fixture-revision",
            fetchedAt: fetchedAt,
            metadataOnly: true,
            records: []
        )
    }

    private struct StaticCatalogProvider: CatalogMetadataProviding {
        func fetchCatalogMetadata() async throws -> CatalogSnapshot {
            CatalogSnapshot(
                provider: "fixture-provider",
                source: "fixtures/catalog.json",
                revision: "fixture-revision",
                fetchedAt: Date(timeIntervalSinceReferenceDate: 100),
                metadataOnly: true,
                records: []
            )
        }
    }

    private struct ThrowingCatalogProvider: CatalogMetadataProviding {
        let error: CatalogClientError

        func fetchCatalogMetadata() async throws -> CatalogSnapshot {
            throw error
        }
    }
}
