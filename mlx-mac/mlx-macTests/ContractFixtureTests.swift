import Foundation
import XCTest

@testable import mlx_workbench

/// Consumers for the shared contract fixtures at <repo>/tests/fixtures.
/// The Python suite asserts the same values; see tests/fixtures/README.md.
final class ContractFixtureTests: XCTestCase {
    // MARK: - config-premium-keys.json

    func testPremiumKeysFixtureLoadsWithExpectedValues() throws {
        let url = try copyFixtureToTemp("config-premium-keys", ext: "json", as: "config.json")
        let loaded = ConfigModule(pathOverride: url.path).load()

        XCTAssertFalse(loaded.verificationEnabled)
        XCTAssertFalse(loaded.watchEnabled)
        XCTAssertEqual(loaded.fitReserveGB, 8)
        XCTAssertEqual(loaded.reclaimStaleDays, 30)
        XCTAssertEqual(loaded.comparisonMaxTokens, 256)
        XCTAssertEqual(loaded.qBits, 8)
    }

    func testPremiumKeysFixtureSurvivesASave() throws {
        let url = try copyFixtureToTemp("config-premium-keys", ext: "json", as: "config.json")
        let module = ConfigModule(pathOverride: url.path)
        _ = try module.save(module.load())
        let reloaded = module.load()

        XCTAssertFalse(reloaded.verificationEnabled)
        XCTAssertFalse(reloaded.watchEnabled)
        XCTAssertEqual(reloaded.fitReserveGB, 8)
        XCTAssertEqual(reloaded.reclaimStaleDays, 30)
        XCTAssertEqual(reloaded.comparisonMaxTokens, 256)
    }

    // MARK: - quarantine-ledger.jsonl

    func testLedgerFixtureReadsNewestFirstWithExpectedFields() throws {
        let dir = try copyFixtureToTemp(
            "quarantine-ledger", ext: "jsonl", as: Quarantine.ledgerName
        ).deletingLastPathComponent()

        let records = Quarantine.ledger(quarantineDir: dir.path)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].from, "/fixtures/gguf/newer.gguf")
        XCTAssertEqual(records[0].bytes, 2048)
        XCTAssertEqual(records[0].movedAt, "2026-08-02T11:00:00+00:00")
        XCTAssertEqual(records[1].from, "/fixtures/gguf/older.gguf")
        XCTAssertEqual(records[1].bytes, 1024)
    }

    // MARK: - convert-queue.json

    func testCurrentQueueFixtureLoadsThreeItemsInOrder() throws {
        let snapshot = WebConvertQueue.load(from: fixtureURL("convert-queue", ext: "json"))

        XCTAssertNil(snapshot.problem)
        XCTAssertEqual(snapshot.items.map(\.id), ["cq-1", "cq-2", "cq-3"])
        XCTAssertEqual(snapshot.items.map(\.state), [.queued, .starting, .failed])
        XCTAssertEqual(snapshot.items[0].kind, .gguf)
        XCTAssertEqual(snapshot.items[1].kind, .repo)
        XCTAssertEqual(snapshot.items[1].repo, "mlx-community/Qwen3-8B-8bit")
        XCTAssertEqual(snapshot.items[2].failure?.code, "convert_failed")
    }

    func testLegacyQueueFixtureMigratesItemsWithNilFailure() throws {
        let snapshot = WebConvertQueue.load(from: fixtureURL("convert-queue-legacy", ext: "json"))

        XCTAssertNil(snapshot.problem)
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0].id, "cq-7")
        XCTAssertEqual(snapshot.items[0].state, .queued)
        XCTAssertNil(snapshot.items[0].failure)
    }

    // MARK: - helpers

    private func fixturesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // mlx-macTests
            .deletingLastPathComponent()  // mlx-mac
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("tests", isDirectory: true)
            .appendingPathComponent("fixtures", isDirectory: true)
    }

    private func fixtureURL(_ name: String, ext: String) -> URL {
        fixturesDirectory()
            .appendingPathComponent(name)
            .appendingPathExtension(ext)
    }

    private func copyFixtureToTemp(_ name: String, ext: String, as finalName: String) throws -> URL {
        let source = fixtureURL(name, ext: ext)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent(finalName)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
