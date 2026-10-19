import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import mlx_workbench

final class BundledRuntimeTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let canonical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical))
            .appendingPathComponent("bundled-runtime-" + UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let files = ["Makefile", "requirements.txt", "LICENSE", "mlx_workbench/__init__.py",
            "mlx_workbench/config.py", "mlx_workbench/deps.py", "vendor/mlx-agent/LICENSE",
            "vendor/mlx-agent/scripts/mlx-agent", "vendor/mlx-agent/src/mlx_agent/__init__.py"]
        var records: [[String: Any]] = []
        for path in files {
            let data = Data((path + "\n").utf8)
            let file = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            records.append(["path": path, "size": data.count, "executable": false,
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
        }
        try JSONSerialization.data(withJSONObject: ["schema": 1, "engine_revision": String(repeating: "a", count: 40),
            "workbench_version": "1.2.3", "files": records], options: [.sortedKeys])
            .write(to: source.appendingPathComponent("manifest.json"))
        return (source, root.appendingPathComponent("runtimes"))
    }

    func testPreparationCopiesVerifiedSourcesAndReusesThemWithoutChangingTheEnvironment() throws {
        let (source, parent) = try fixture()
        let plan = try BundledRuntime(source: source, parent: parent)
        let root = try plan.prepare()
        XCTAssertEqual(root, plan.destination)
        XCTAssertTrue(WorkbenchPython.isCheckout(root))
        XCTAssertEqual(WorkbenchPython.repoRoot(agentPath: plan.agentPath, buildRoot: nil), root.standardizedFileURL)
        let environment = root.appendingPathComponent(".venv")
        try FileManager.default.createDirectory(at: environment, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: environment.appendingPathComponent("existing"))
        XCTAssertEqual(try plan.prepare(), root)
        XCTAssertEqual(try String(contentsOf: environment.appendingPathComponent("existing")), "keep")
        try Data("changed".utf8).write(to: root.appendingPathComponent("requirements.txt"))
        XCTAssertThrowsError(try plan.prepare())
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("requirements.txt")), "changed")
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("requirements.txt")), "requirements.txt\n")
    }

    func testChangedSourceIsRefusedBeforeCreatingARuntime() throws {
        let (source, parent) = try fixture()
        let plan = try BundledRuntime(source: source, parent: parent)
        try Data("changed".utf8).write(to: source.appendingPathComponent("requirements.txt"))
        XCTAssertThrowsError(try plan.prepare())
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }

    func testLinkedSourcesAndDestinationsAreRefusedWithoutChangingTheirTargets() throws {
        let (source, parent) = try fixture()
        let fm = FileManager.default
        let outside = parent.deletingLastPathComponent().appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: parent, withDestinationURL: outside)
        let plan = try BundledRuntime(source: source, parent: parent)
        XCTAssertThrowsError(try plan.prepare())
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
        try fm.removeItem(at: parent)
        let file = source.appendingPathComponent("requirements.txt")
        try fm.removeItem(at: file)
        try fm.createSymbolicLink(at: file, withDestinationURL: source.appendingPathComponent("LICENSE"))
        XCTAssertThrowsError(try plan.prepare())
        XCTAssertFalse(fm.fileExists(atPath: parent.path))
    }

    func testDuplicateTraversalAndUnsupportedManifestsAreRefused() throws {
        let (source, parent) = try fixture()
        let file = source.appendingPathComponent("manifest.json")
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        for mutation in ["duplicate", "traversal", "schema"] {
            var value = original
            var files = value["files"] as! [[String: Any]]
            if mutation == "duplicate" { files.append(files[0]) }
            if mutation == "traversal" { files[0]["path"] = "../outside" }
            if mutation == "schema" { value["schema"] = 2 }
            value["files"] = files
            try JSONSerialization.data(withJSONObject: value).write(to: file)
            XCTAssertThrowsError(try BundledRuntime(source: source, parent: parent), mutation)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }

    @MainActor
    func testSettingsArePublishedOnlyAfterPreparationAndASuccessfulSave() async throws {
        let (source, parent) = try fixture()
        let plan = try BundledRuntime(source: source, parent: parent)
        let session = BundledRuntimePreparation()
        var selected = "existing-engine"
        let first = try XCTUnwrap(session.prepare(plan) { path in
            XCTAssertEqual(path, plan.agentPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destination.appendingPathComponent("Makefile").path))
            throw BundledRuntime.Failure("Settings could not be saved")
        })
        XCTAssertNil(session.prepare(plan) { _ in XCTFail("A duplicate request must not publish") })
        await first.value
        XCTAssertEqual(selected, "existing-engine")
        XCTAssertNil(session.preparedPath)
        XCTAssertNotNil(session.errorMessage)
        let retry = try XCTUnwrap(session.prepare(plan) { selected = $0 })
        await retry.value
        XCTAssertEqual(selected, plan.agentPath)
        XCTAssertEqual(session.preparedPath, plan.agentPath)
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(session.isPreparing)
    }
}
