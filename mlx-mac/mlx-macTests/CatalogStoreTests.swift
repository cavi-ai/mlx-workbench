import Foundation
import XCTest

@testable import mlx_workbench

final class CatalogStoreTests: XCTestCase {
    func testSaveAndLoadRoundTripsMetadataSnapshot() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let store = fixture.store()
        let snapshot = makeSnapshot(fetchedAt: Date(timeIntervalSinceReferenceDate: 10))

        try store.save(snapshot)
        let loaded = store.load()

        XCTAssertEqual(loaded, .snapshot(snapshot))
    }

    func testLoadDistinguishesCorruptCacheFromMissingCache() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let store = fixture.store()
        XCTAssertEqual(store.load(), .missing)

        let directory = store.cacheURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: store.cacheURL())

        switch store.load() {
        case .corrupt(let message):
            XCTAssertFalse(message.isEmpty)
        default:
            XCTFail("expected corrupt cache state")
        }
    }

    func testSaveFailurePreservesPreviousValidCache() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let store = fixture.store(maxBytes: 512)
        let valid = makeSnapshot(
            revision: "r1",
            fetchedAt: Date(timeIntervalSinceReferenceDate: 20),
            recordCount: 1
        )
        try store.save(valid)

        let oversized = makeSnapshot(
            revision: "r2",
            fetchedAt: Date(timeIntervalSinceReferenceDate: 40),
            recordCount: 24
        )

        XCTAssertThrowsError(try store.save(oversized))
        XCTAssertEqual(store.load(), .snapshot(valid))
    }

    func testCatalogFreshnessClassificationUsesNamedTTLDeterministically() {
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 100)
        let ttl = CatalogFreshness.metadataTTL

        XCTAssertEqual(
            CatalogFreshness.classify(
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(ttl - 1),
                ttl: ttl
            ),
            .current
        )
        XCTAssertEqual(
            CatalogFreshness.classify(
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(ttl + 1),
                ttl: ttl
            ),
            .stale
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-catalog-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root)
    }

    private func makeSnapshot(
        revision: String = "rev-1",
        fetchedAt: Date,
        recordCount: Int = 2
    ) -> CatalogSnapshot {
        CatalogSnapshot(
            provider: "fixture-provider",
            source: "fixtures/catalog.json",
            revision: revision,
            fetchedAt: fetchedAt,
            metadataOnly: true,
            records: (0..<recordCount).map { index in
                CatalogRecord(
                    repoIdentity: "mlx-community/model-\(index)",
                    revision: "model-rev-\(index)",
                    updatedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index)),
                    roles: index.isMultiple(of: 2) ? [.generalChat] : [.coding],
                    estimatedMemoryBytes: Int64(4_096 + index),
                    formats: ["gguf", "mlx"],
                    sourceURL: URL(string: "https://example.com/catalog/\(index)")!
                )
            }
        )
    }

    private struct Fixture {
        let root: URL

        func store(maxBytes: Int = CatalogStore.defaultMaxBytes) -> CatalogStore {
            CatalogStore(
                fileManager: .default,
                maxBytes: maxBytes,
                appSupportDirectory: { root }
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
