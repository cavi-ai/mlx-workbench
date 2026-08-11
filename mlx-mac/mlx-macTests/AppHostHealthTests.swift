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

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}
