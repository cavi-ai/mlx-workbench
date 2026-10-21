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

    func testStreamingObjectFramingAcrossEveryChunkBoundary() throws {
        let url = try streamingStoreURL()
        let objects: [[String: Any]] = [
            ["id": "a", "note": "\"quoted\" \\ [nested] {braces} 🐈", "future": ["array": [1, 2]]],
            ["id": "b", "note": String(repeating: "large\n", count: 15_000)]
        ]
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
        let expected = try JSONDecoder().decode([Item].self, from: data)
        for size in [1, 2, 3, 7, 64, 65_536] {
            var actual: [Item] = []
            try JSONRecordStream.forEach(at: url, chunkSize: size) { actual.append(try JSONDecoder().decode(Item.self, from: $0)) }
            XCTAssertEqual(actual, expected)
        }
        let store = JSONStore<Item>(fileURL: url)
        XCTAssertEqual(try store.loadStreaming(), expected)
        XCTAssertEqual(try store.findStreaming(id: "b", keyPath: \.id), expected[1])
    }

    func testStreamingMutationsPreserveUntouchedFieldsAndAtomicFailures() throws {
        let url = try streamingStoreURL()
        let raw = #"{"id":"a","note":"keep","future":{"untouched":[1,2,3]}}"#
        try Data(("[" + raw + "," + #"{"id":"b","note":"before"}"# + "]").utf8).write(to: url)
        let store = JSONStore<Item>(fileURL: url)
        try store.upsertStreaming(Item(id: "b", note: "after"), id: \.id)
        XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(raw))
        let before = try Data(contentsOf: url)
        XCTAssertFalse(try store.updateStreaming(id: "missing", keyPath: \.id) { _ in nil })
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertThrowsError(try store.updateStreaming(id: "a", keyPath: \.id) { _ in throw CocoaError(.fileWriteUnknown) })
        XCTAssertEqual(try Data(contentsOf: url), before)
        let failing = JSONStore<Item>(fileURL: url, replaceItem: { _, _ in throw CocoaError(.fileWriteUnknown) })
        XCTAssertThrowsError(try failing.upsertStreaming(Item(id: "b", note: "failed"), id: \.id))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(try store.updateStreaming(id: "b", keyPath: \.id) { _ in nil })
        XCTAssertEqual(try store.load(), [Item(id: "a", note: "keep")])
        let children = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertFalse(children.contains { $0.contains("tmp-") })
    }

    func testStreamingCorruptionAnywhereBlocksPublicationAndLeavesBytes() throws {
        for corrupt in ["", "{}", "[{}]", "[null]", "[1]", "[true]", "[{},]", "[] []",
                        #"[{"id":"a","note":"first"},bad]"#,
                        #"[{"id":"a","note":"first"}] trailing"#,
                        #"[{"id":"a","note":"unfinished"}"#] {
            let url = try streamingStoreURL()
            let data = Data(corrupt.utf8)
            try data.write(to: url)
            let store = JSONStore<Item>(fileURL: url)
            XCTAssertThrowsError(try store.loadStreaming(), corrupt)
            XCTAssertThrowsError(try store.findStreaming(id: "a", keyPath: \.id), corrupt)
            XCTAssertThrowsError(try store.upsertStreaming(Item(id: "b", note: "new"), id: \.id), corrupt)
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testStreamingMissingStoreAndSymlinkRefusal() throws {
        let url = try streamingStoreURL(), target = try streamingStoreURL()
        let store = JSONStore<Item>(fileURL: url)
        XCTAssertTrue(try store.loadStreaming().isEmpty)
        try store.upsertStreaming(Item(id: "a", note: "first"), id: \.id)
        XCTAssertEqual(try store.load(), [Item(id: "a", note: "first")])
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: url)
        let linked = JSONStore<Item>(fileURL: target)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try linked.upsertStreaming(Item(id: "b", note: "unsafe"), id: \.id))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testLoadReturnsEmptyForMissingFile() throws {
        let store = JSONStore<Item>(fileURL: storeURL())
        XCTAssertEqual(try store.load(), [])
    }

    func testInsertRequiresUnchangedSourceAndUniqueIdentity() throws {
        let store = JSONStore<Item>(fileURL: storeURL())
        let original = Item(id: "a", note: "one"), copy = Item(id: "b", note: "copy")
        XCTAssertFalse(try store.insert(copy, requiring: original, id: \.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        try store.upsert(original, id: \.id)
        XCTAssertFalse(try store.insert(copy, requiring: Item(id: "a", note: "stale"), id: \.id))
        XCTAssertTrue(try store.insert(copy, requiring: original, id: \.id))
        let bytes = try Data(contentsOf: store.url)
        XCTAssertFalse(try store.insert(copy, requiring: original, id: \.id))
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        XCTAssertEqual(try store.load(), [original, copy])
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
        XCTAssertThrowsError(try store.insert(Item(id: "b", note: "copy"), requiring: Item(id: "a", note: "one"), id: \.id))

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
        XCTAssertThrowsError(try store.insert(Item(id: "b", note: "copy"), requiring: Item(id: "a", note: "one"), id: \.id))
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

    private func streamingStoreURL() throws -> URL {
        let url = storeURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    private func storeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-jsonstore-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("store.json", isDirectory: false)
    }
}
