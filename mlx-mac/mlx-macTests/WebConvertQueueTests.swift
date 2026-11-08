import Foundation
import XCTest

@testable import mlx_workbench

final class WebConvertQueueTests: XCTestCase {
    // MARK: - defaultPath

    func testDefaultPathFollowsTheConfigOverrideBesideTheProfile() {
        let url = WebConvertQueue.defaultPath(environment: [
            "MLX_WORKBENCH_CONFIG": "/profiles/work/config.json",
            "XDG_STATE_HOME": "/state",
        ])
        XCTAssertEqual(url.path, "/profiles/work/convert-queue.json")
    }

    func testDefaultPathPrefersXdgStateHome() {
        let url = WebConvertQueue.defaultPath(environment: ["XDG_STATE_HOME": "/state"])
        XCTAssertEqual(url.path, "/state/mlx-workbench/convert-queue.json")
    }

    func testDefaultPathFallsBackToLocalState() {
        let home = URL(fileURLWithPath: "/home/tester")
        let url = WebConvertQueue.defaultPath(environment: [:], home: home)
        XCTAssertEqual(url.path, "/home/tester/.local/state/mlx-workbench/convert-queue.json")
    }

    // MARK: - load

    func testMissingFileIsAnEmptySnapshotNotAnError() {
        let snapshot = WebConvertQueue.load(from: URL(fileURLWithPath: "/nonexistent/convert-queue.json"))
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertNil(snapshot.problem)
    }

    func testUnreadableFileSurfacesAProblem() throws {
        let url = try writeTemp("{not json")
        let snapshot = WebConvertQueue.load(from: url)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertNotNil(snapshot.problem)
    }

    func testUnsupportedSchemaVersionSurfacesAProblem() throws {
        let url = try writeTemp(#"{"schema_version": "9.9", "items": []}"#)
        let snapshot = WebConvertQueue.load(from: url)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertNotNil(snapshot.problem)
    }

    func testBooleanQBitsIsRejectedLikeThePythonValidator() throws {
        let item: [String: Any] = [
            "id": "cq-1", "kind": "gguf",
            "preview_hash": String(repeating: "a", count: 64),
            "q_bits": true, "out": "/o", "path": "/p.gguf", "repo": NSNull(),
            "hf_cache": NSNull(), "label": "x", "state": "queued", "failure": NSNull(),
        ]
        let payload: [String: Any] = ["schema_version": "1.1", "items": [item]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertThrowsError(try WebConvertQueue.parse(data)) { error in
            guard case WebConvertQueue.LoadError.invalidSchema = error else {
                return XCTFail("expected invalidSchema, got \(error)")
            }
        }
    }

    func testEveryConversionWidthLoadsAndOthersAreRejected() throws {
        func payload(_ bits: Int) -> [String: Any] {
            ["schema_version": "1.1", "items": [[
                "id": "cq-1", "kind": "repo", "preview_hash": "h", "q_bits": bits, "out": NSNull(), "path": NSNull(),
                "repo": "org/model", "hf_cache": NSNull(), "label": "x", "state": "queued", "failure": NSNull(),
            ]]]
        }
        for bits in [4, 5, 6, 8] {
            let url = try writeTemp(String(decoding: try JSONSerialization.data(withJSONObject: payload(bits)), as: UTF8.self))
            let snapshot = WebConvertQueue.load(from: url)
            XCTAssertNil(snapshot.problem, "\(bits)-bit")
            XCTAssertEqual(snapshot.items.map(\.qBits), [bits])
        }
        XCTAssertThrowsError(try WebConvertQueue.parse(try JSONSerialization.data(withJSONObject: payload(7))))
    }

    func testPreparedRepositoryQueueLoadsPinnedSourceAndFullPrecisionRecipe() throws {
        let item = preparedQueueItem(kind: "repo", bits: 32)
        let values = try WebConvertQueue.parse(queueData(item))
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0].kind, .repo)
        XCTAssertEqual(values[0].qBits, 32)
        XCTAssertEqual(values[0].repo, "org/model")
        XCTAssertEqual(values[0].out, "/models/prepared output")
        XCTAssertNil(values[0].path)
    }

    func testPreparedGGUFQueueLoadsProjectorAndDownloadDirectory() throws {
        let item = preparedQueueItem(kind: "gguf", bits: 8)
        let data = try queueData(item)
        let url = try writeTemp(String(decoding: data, as: UTF8.self))
        let snapshot = WebConvertQueue.load(from: url)
        XCTAssertNil(snapshot.problem)
        XCTAssertEqual(snapshot.items.map(\.path), ["/models/pinned source/main.gguf"])
        XCTAssertEqual(try Data(contentsOf: url), data, "Native queue reads must preserve the durable engine-owned payload")
    }

    func testFullPrecisionWidthIsOnlyAcceptedForPreparedRepositories() throws {
        XCTAssertThrowsError(try WebConvertQueue.parse(queueData(preparedQueueItem(kind: "gguf", bits: 32))))
        let repository = preparedQueueItem(kind: "repo", bits: 32)
        XCTAssertThrowsError(try WebConvertQueue.parse(queueData(repository, version: "1.1")))
        for width: Any in [4.5, 8.9, true] {
            var item = preparedQueueItem(kind: "repo", bits: 8)
            item["q_bits"] = width
            XCTAssertThrowsError(try WebConvertQueue.parse(queueData(item)), "Invalid width \(width) must not be truncated")
        }
    }

    func testPreparedQueueStartingAttemptKeepsExactTransportIdentity() throws {
        var item = preparedQueueItem(kind: "repo", bits: 8)
        item["state"] = "starting"; item["attempt_id"] = String(repeating: "a", count: 32)
        XCTAssertEqual(try WebConvertQueue.parse(queueData(item)).count, 1)
        for value: Any in ["", String(repeating: "A", count: 32), "1234", true, 7] {
            item["attempt_id"] = value
            XCTAssertThrowsError(try WebConvertQueue.parse(queueData(item)))
        }
    }

    func testPreparationLocationsRequireNonemptyStrings() throws {
        for field in ["backend", "model_type", "subfolder", "source_path", "projector", "fetch_receipt", "downloads_dir"] {
            for value: Any in ["", true, 1, ["/models/path"]] {
                var item = preparedQueueItem(kind: "repo", bits: 8)
                item[field] = value
                XCTAssertThrowsError(try WebConvertQueue.parse(queueData(item)), "\(field) must not accept \(value)")
            }
        }
    }

    func testPreparationFlagsRequireJSONBooleans() throws {
        for field in ["require_projector", "require_completion"] {
            for flag in [true, false] {
                var item = preparedQueueItem(kind: "repo", bits: 8)
                item[field] = flag
                XCTAssertEqual(try WebConvertQueue.parse(queueData(item)).count, 1)
            }
            for value: Any in [0, 1, "true", NSNull()] {
                var item = preparedQueueItem(kind: "repo", bits: 8)
                item[field] = value
                XCTAssertThrowsError(try WebConvertQueue.parse(queueData(item)), "\(field) requires a boolean, not \(value)")
            }
        }
    }

    func testPreparationDependencyReceiptsAreFiniteAndNonempty() throws {
        var item = preparedQueueItem(kind: "repo", bits: 8)
        item["dependency_fetch_receipts"] = (0..<32).map { "/state/dependency-\($0).json" }
        XCTAssertEqual(try WebConvertQueue.parse(queueData(item)).count, 1)
        for value: Any in [(0..<33).map { "/state/dependency-\($0).json" }, [""], ["/state/base.json", 1], "/state/base.json"] {
            item["dependency_fetch_receipts"] = value
            XCTAssertThrowsError(try WebConvertQueue.parse(queueData(item)))
        }
    }

    func testPreviousQueueSchemasStillLoadOrdinaryConversions() throws {
        for version in ["1.0", "1.1", "1.2"] {
            var item: [String: Any] = [
                "id": "cq-7", "kind": "gguf", "preview_hash": "ordinary-plan", "q_bits": 5,
                "out": "/models/output", "path": "/models/source.gguf", "repo": NSNull(),
                "hf_cache": NSNull(), "label": "ordinary conversion", "state": "queued",
            ]
            if version != "1.0" { item["failure"] = NSNull() }
            let values = try WebConvertQueue.parse(queueData(item, version: version))
            XCTAssertEqual(values.map(\.id), ["cq-7"])
            XCTAssertEqual(values.map(\.qBits), [5])
        }
    }

    // MARK: - helpers

    private func preparedQueueItem(kind: String, bits: Int) -> [String: Any] {
        ["id": "cq-9", "kind": kind, "preview_hash": "source-bound-plan", "q_bits": bits,
         "out": "/models/prepared output", "path": kind == "gguf" ? "/models/pinned source/main.gguf" : NSNull(),
         "repo": kind == "repo" ? "org/model" : NSNull(), "hf_cache": NSNull(),
         "label": "model update", "state": "queued", "failure": NSNull(),
         "backend": "mlx-embeddings", "model_type": "laya", "subfolder": "multilingual",
         "source_path": "/models/pinned source", "projector": "/models/pinned source/mmproj.gguf",
         "fetch_receipt": "/state/fetch.json", "dependency_fetch_receipts": ["/state/base-fetch.json"],
         "require_completion": true, "require_projector": true, "downloads_dir": "/models/downloads"]
    }

    private func queueData(_ item: [String: Any], version: String = "1.2") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema_version": version, "items": [item]])
    }

    private func writeTemp(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(WebConvertQueue.fileName)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
