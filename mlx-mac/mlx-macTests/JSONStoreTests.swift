import Foundation
import XCTest

@testable import mlx_workbench

/// JSONStore is the shared durable-list pattern: atomic replace, and a throw
/// on corrupt data so a damaged file is never silently overwritten.
final class JSONStoreTests: XCTestCase {
    private struct Item: Codable, Equatable {
        let id: String
        let note: String
    }

    func testLoadReturnsEmptyForMissingFile() throws {
        let store = JSONStore<Item>(fileURL: storeURL())
        XCTAssertEqual(try store.load(), [])
    }

    func testReplaceAllRoundTrips() throws {
        let store = JSONStore<Item>(fileURL: storeURL())
        let items = [Item(id: "a", note: "one"), Item(id: "b", note: "two")]
        try store.replaceAll(items)
        XCTAssertEqual(try store.load(), items)
    }

    func testUpsertInsertsThenUpdatesByIdentity() throws {
        let store = JSONStore<Item>(fileURL: storeURL())
        try store.upsert(Item(id: "a", note: "one"), id: \.id)
        try store.upsert(Item(id: "b", note: "two"), id: \.id)
        try store.upsert(Item(id: "a", note: "updated"), id: \.id)

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first { $0.id == "a" }?.note, "updated")
    }

    func testCorruptFileThrowsAndBlocksWrites() throws {
        let url = storeURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let before = try Data(contentsOf: url)

        let store = JSONStore<Item>(fileURL: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.upsert(Item(id: "a", note: "one"), id: \.id))

        // The damaged file must survive untouched until a human looks.
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testWriteFailureLeavesNoTemporaryLitter() throws {
        let url = storeURL()
        let store = JSONStore<Item>(fileURL: url) { _, _ in
            throw NSError(domain: "test", code: 1, userInfo: nil)
        }
        try store.replaceAll([Item(id: "a", note: "one")])
        // Existing file path goes through the injected replaceItem, which fails.
        XCTAssertThrowsError(try store.replaceAll([Item(id: "a", note: "two")]))

        let directory = url.deletingLastPathComponent()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".tmp-") }
        XCTAssertEqual(leftovers, [])
    }

    private func storeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-jsonstore-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("store.json", isDirectory: false)
    }
}
