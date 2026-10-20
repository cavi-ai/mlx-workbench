import Foundation
import XCTest

@testable import mlx_workbench

final class RuntimeInstallPrerequisitesTests: XCTestCase {
    private actor ShimCalls {
        var count = 0
        func record() { count += 1 }
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func executable(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    func testMissingToolsAndPythonHaveSpecificRemediesWithoutCreatingAnEnvironment() async throws {
        let root = try root()
        let report = await RuntimeInstallPrerequisites.inspect(root: root, environment: ["PATH": "/missing"],
            searchDirectories: [], probe: { _, _, _ in nil })
        XCTAssertFalse(report.canInstall)
        XCTAssertTrue(report.issues.contains { $0.command == "xcode-select --install" })
        XCTAssertTrue(report.issues.contains { $0.detail.contains("Python 3.12") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".venv").path))
    }

    func testMissingHomebrewUsesOfficialSetupHelpInsteadOfAnUnavailableCommand() async throws {
        let root = try root()
        let report = await RuntimeInstallPrerequisites.inspect(root: root, environment: ["PATH": "/missing"],
            searchDirectories: [], probe: { _, _, _ in nil })
        let python = try XCTUnwrap(report.issues.first { $0.guide == .uv })
        XCTAssertNil(python.command)
        XCTAssertEqual(python.guide?.url.absoluteString, "https://docs.astral.sh/uv/getting-started/installation/")
        XCTAssertTrue(python.detail.contains("Homebrew"))
        XCTAssertFalse(report.canInstall)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".venv").path))
    }

    func testDetectedHomebrewKeepsAnExplicitCopyablePythonCommand() async throws {
        let root = try root()
        let tools = root.appendingPathComponent("tools")
        try executable(tools.appendingPathComponent("brew"))
        let report = await RuntimeInstallPrerequisites.inspect(root: root, environment: ["PATH": tools.path],
            searchDirectories: [], probe: { _, _, _ in nil })
        let python = try XCTUnwrap(report.issues.first { $0.guide == .uv })
        XCTAssertEqual(python.command, "brew install python@3.12")
        XCTAssertFalse(report.canInstall)
    }

    func testMissingDeveloperToolsNeverLaunchTheSystemPythonInstallerShim() async throws {
        let root = try root()
        let calls = ShimCalls()
        let report = await RuntimeInstallPrerequisites.inspect(root: root, environment: ["PATH": "/usr/bin:/bin"],
            searchDirectories: [], probe: { url, _, _ in
                if url.path == "/usr/bin/python3" { await calls.record() }
                return nil
            })
        let count = await calls.count
        XCTAssertFalse(report.canInstall)
        XCTAssertEqual(count, 0)
    }

    func testFinderSearchFindsToolsAndPassesTheirDirectoriesToMake() async throws {
        let root = try root()
        let tools = root.appendingPathComponent("tools with spaces")
        for name in ["uv", "python3"] { try executable(tools.appendingPathComponent(name)) }
        let report = await RuntimeInstallPrerequisites.inspect(root: root, environment: ["PATH": "/usr/bin:/bin", "KEEP": "value"],
            searchDirectories: [tools], probe: { url, _, _ in
                switch url.lastPathComponent {
                case "xcode-select": return root.path
                case "uv": return "uv 0.10.0"
                case "python3": return "3.9"
                default: return nil
                }
            })
        XCTAssertTrue(report.canInstall, report.issues.map(\.detail).joined(separator: "\n"))
        XCTAssertTrue(report.environment["PATH"]?.contains(tools.path + ":") == true)
        XCTAssertEqual(report.environment["KEEP"], "value")
        XCTAssertTrue(report.pythonSummary.contains("uv"))
    }

    func testExistingWrongVersionEnvironmentIsRefusedEvenWhenUvIsAvailable() async throws {
        let root = try root()
        try executable(root.appendingPathComponent(".venv/bin/python"))
        let tools = root.appendingPathComponent("tools")
        try executable(tools.appendingPathComponent("uv"))
        try executable(tools.appendingPathComponent("python3"))
        let report = await RuntimeInstallPrerequisites.inspect(root: root, environment: ["PATH": tools.path],
            searchDirectories: [], probe: { url, _, _ in
                if url.lastPathComponent == "xcode-select" { return root.path }
                if url.lastPathComponent == "uv" { return "uv 0.10.0" }
                return "3.14"
            })
        XCTAssertFalse(report.canInstall)
        XCTAssertTrue(report.issues.contains { $0.detail.contains("existing Python environment") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".venv/bin/python").path))
    }

    func testExistingCompatibleEnvironmentDoesNotRequireUvOrAnotherPython() async throws {
        let root = try root()
        try executable(root.appendingPathComponent(".venv/bin/python"))
        let report = await RuntimeInstallPrerequisites.inspect(root: root, environment: ["PATH": "/missing"],
            searchDirectories: [], probe: { url, _, _ in
                url.lastPathComponent == "xcode-select" ? root.path : "3.12"
            })
        XCTAssertTrue(report.canInstall)
        XCTAssertTrue(report.pythonSummary.contains("existing"))
    }

    func testBrokenUvCannotSilentlyOverrideACompatiblePython() async throws {
        let root = try root()
        let tools = root.appendingPathComponent("tools")
        for name in ["uv", "python3", "python3.12"] { try executable(tools.appendingPathComponent(name)) }
        let report = await RuntimeInstallPrerequisites.inspect(root: root, environment: ["PATH": tools.path],
            searchDirectories: [], probe: { url, _, _ in
                if url.lastPathComponent == "xcode-select" { return root.path }
                if url.lastPathComponent == "uv" { return nil }
                return "3.12"
            })
        XCTAssertFalse(report.canInstall)
        XCTAssertTrue(report.issues.contains { $0.detail.contains("uv command") })
    }
}
