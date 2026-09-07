import Foundation
import XCTest

@testable import mlx_workbench

/// WorkbenchPython resolution order: env override → repo .venv → PATH.
/// Everything is injectable; tests build fake interpreters in temp dirs.
final class WorkbenchPythonTests: XCTestCase {
    func testAbsoluteEnvOverrideWins() throws {
        let override = try makeExecutable("override-python")
        let venvRoot = try makeRepoWithVenv()
        let pathDir = try makePathDir(with: ["python3"])

        let resolved = WorkbenchPython.preferredExecutable(
            environment: ["MLX_WORKBENCH_PYTHON": override.path, "PATH": pathDir.path],
            repoRoot: venvRoot
        )
        XCTAssertEqual(resolved?.path, override.path)
    }

    func testNonExecutableEnvOverrideFallsThroughToVenv() throws {
        let dead = try makeRoot().appendingPathComponent("not-there")
        let venvRoot = try makeRepoWithVenv()

        let resolved = WorkbenchPython.preferredExecutable(
            environment: ["MLX_WORKBENCH_PYTHON": dead.path, "PATH": "/nonexistent"],
            repoRoot: venvRoot
        )
        XCTAssertEqual(resolved?.path, venvRoot.appendingPathComponent(".venv/bin/python").path)
    }

    func testRelativeEnvOverrideResolvesViaPATH() throws {
        let pathDir = try makePathDir(with: ["custom-python"])

        let resolved = WorkbenchPython.preferredExecutable(
            environment: ["PYTHON": "custom-python", "PATH": pathDir.path],
            repoRoot: nil
        )
        XCTAssertEqual(resolved?.path, pathDir.appendingPathComponent("custom-python").path)
    }

    func testTildeOverrideExpands() throws {
        // "~/anything" expands under the real home; it won't exist, so it must
        // be treated as absolute-and-missing (fall through), never as PATH-relative.
        let resolved = WorkbenchPython.preferredExecutable(
            environment: ["PYTHON": "~/no/such/python", "PATH": "/nonexistent"],
            repoRoot: nil
        )
        XCTAssertNil(resolved)
    }

    func testVenvPreferredOverPATH() throws {
        let venvRoot = try makeRepoWithVenv()
        let pathDir = try makePathDir(with: ["python3"])

        let resolved = WorkbenchPython.preferredExecutable(
            environment: ["PATH": pathDir.path],
            repoRoot: venvRoot
        )
        XCTAssertEqual(resolved?.path, venvRoot.appendingPathComponent(".venv/bin/python").path)
    }

    func testPATHIsLastResort() throws {
        let pathDir = try makePathDir(with: ["python3"])

        let resolved = WorkbenchPython.preferredExecutable(
            environment: ["PATH": pathDir.path],
            repoRoot: nil
        )
        XCTAssertEqual(resolved?.path, pathDir.appendingPathComponent("python3").path)
    }

    func testNothingResolvableReturnsNil() throws {
        let resolved = WorkbenchPython.preferredExecutable(
            environment: ["PATH": "/nonexistent"],
            repoRoot: nil
        )
        XCTAssertNil(resolved)
    }

    func testResolveOnPathScansInOrder() throws {
        let first = try makePathDir(with: ["target"])
        let second = try makePathDir(with: ["target"])

        let resolved = WorkbenchPython.resolveOnPath(
            "target",
            environment: ["PATH": "\(first.path):\(second.path)"]
        )
        XCTAssertEqual(resolved?.path, first.appendingPathComponent("target").path)
    }

    func testResolveOnPathSkipsNonExecutables() throws {
        let dir = try makeRoot()
        let file = dir.appendingPathComponent("target")
        try Data("x".utf8).write(to: file) // not executable

        XCTAssertNil(WorkbenchPython.resolveOnPath("target", environment: ["PATH": dir.path]))
    }

    // MARK: - Helpers

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-python-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutable(_ name: String) throws -> URL {
        let url = try makeRoot().appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makePathDir(with names: [String]) throws -> URL {
        let dir = try makeRoot()
        for name in names {
            let file = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: file.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return dir
    }

    private func makeRepoWithVenv() throws -> URL {
        let root = try makeRoot()
        let python = root.appendingPathComponent(".venv/bin/python")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: python.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        return root
    }
}
