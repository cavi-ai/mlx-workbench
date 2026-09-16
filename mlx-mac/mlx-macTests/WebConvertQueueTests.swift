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

    // MARK: - helpers

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
