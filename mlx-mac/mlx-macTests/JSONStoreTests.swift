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

    func testUpdateRenamesAndRemovesOnlyTheSelectedIdentity() throws {
        let url = storeURL(), store = JSONStore<Item>(fileURL: url)
        XCTAssertFalse(try store.update(id: "missing", keyPath: \.id) { _ in XCTFail("Missing item must not be transformed"); return nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try store.replaceAll([Item(id: "a", note: "one"), Item(id: "b", note: "two")])
        XCTAssertTrue(try store.update(id: "a", keyPath: \.id) { Item(id: $0.id, note: "renamed") })
        XCTAssertEqual(try store.load(), [Item(id: "a", note: "renamed"), Item(id: "b", note: "two")])
        XCTAssertTrue(try store.update(id: "a", keyPath: \.id) { _ in nil })
        XCTAssertEqual(try store.load(), [Item(id: "b", note: "two")])
    }

    func testUpdateWriteFailureLeavesOriginalDataUntouched() throws {
        let url = storeURL()
        let store = JSONStore<Item>(fileURL: url) { _, _ in throw CocoaError(.fileWriteNoPermission) }
        try store.replaceAll([Item(id: "a", note: "one")])
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try store.update(id: "a", keyPath: \.id) { _ in nil })
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

    func testSymlinkedStoreIsRefusedNotWrittenThrough() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-jsonstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let victim = directory.appendingPathComponent("victim.json")
        try Data("{}".utf8).write(to: victim)
        let link = directory.appendingPathComponent("store.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)

        let store = JSONStore<Item>(fileURL: link)
        XCTAssertThrowsError(try store.replaceAll([Item(id: "a", note: "one")]))
        XCTAssertEqual(try String(contentsOf: victim), "{}")
    }

    private func storeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-jsonstore-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("store.json", isDirectory: false)
    }
}
