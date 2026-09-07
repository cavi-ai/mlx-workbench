import Foundation
import XCTest

@testable import mlx_workbench

/// LaunchAgentManager writes launchd plists and drives launchctl through an
/// injected runner — tests use a temp home and a recording runner, never the
/// real launchctl.
final class LaunchAgentManagerTests: XCTestCase {
    private let config = EndpointConfig(
        enabled: true, port: 8766, modelPath: "/models/qwen", installedAtLogin: false
    )

    func testPreviewPlistIsWellFormedAndDeliberate() throws {
        let manager = LaunchAgentManager(home: try makeHome(), run: recordingRunner().run, uid: 501)
        let text = try manager.plistPreview(config: config, agentPath: "/opt/agent")

        let data = try XCTUnwrap(text.data(using: .utf8))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["Label"] as? String, LaunchAgentManager.label)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        // KeepAlive must stay off — mlx-agent supervises its own server.
        XCTAssertEqual(plist["KeepAlive"] as? Bool, false)

        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertTrue(arguments.first?.hasPrefix("/") == true)
        XCTAssertEqual(arguments[1], "/opt/agent/scripts/mlx-agent")
        XCTAssertEqual(Array(arguments.dropFirst(2)), ["serve", "start", "--repo", "/models/qwen", "--runtime", "mlx", "--port", "8766"])
    }

    func testInstallWritesPlistAndBootstrapsAfterBootout() throws {
        let home = try makeHome()
        let recorder = Recorder()
        let manager = LaunchAgentManager(home: home, run: recorder.run, uid: 501)

        try manager.install(config: config, agentPath: "/opt/agent")

        XCTAssertTrue(manager.isInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.plistURL.path))

        let commands = recorder.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].executable, "/bin/launchctl")
        XCTAssertEqual(commands[0].argv, ["bootout", "gui/501/\(LaunchAgentManager.label)"])
        XCTAssertEqual(commands[1].argv, ["bootstrap", "gui/501", manager.plistURL.path])
    }

    func testInstallPropagatesBootstrapFailure() throws {
        let home = try makeHome()
        let manager = LaunchAgentManager(home: home, run: { _, argv in
            if argv.first == "bootstrap" {
                throw LaunchAgentError.launchctlFailed("Bootstrap failed: 5")
            }
            return ""
        }, uid: 501)

        XCTAssertThrowsError(try manager.install(config: config, agentPath: "/opt/agent")) { error in
            guard case LaunchAgentError.launchctlFailed = error else {
                return XCTFail("expected launchctlFailed, got \(error)")
            }
        }
    }

    func testUninstallBootsOutAndRemovesPlist() throws {
        let home = try makeHome()
        let recorder = Recorder()
        let manager = LaunchAgentManager(home: home, run: recorder.run, uid: 501)
        try manager.install(config: config, agentPath: "/opt/agent")
        recorder.reset()

        try manager.uninstall()

        XCTAssertFalse(manager.isInstalled)
        XCTAssertEqual(recorder.commands.count, 1)
        XCTAssertEqual(recorder.commands.first?.argv, ["bootout", "gui/501/\(LaunchAgentManager.label)"])
    }

    func testUninstallWhenNothingInstalledSucceeds() throws {
        let manager = LaunchAgentManager(home: try makeHome(), run: recordingRunner().run, uid: 501)
        XCTAssertNoThrow(try manager.uninstall())
    }

    // MARK: - Helpers

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(executable: String, argv: [String])] = []

        var commands: [(executable: String, argv: [String])] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func reset() {
            lock.lock()
            recorded = []
            lock.unlock()
        }

        func run(_ executable: String, _ argv: [String]) throws -> String {
            lock.lock()
            recorded.append((executable, argv))
            lock.unlock()
            return ""
        }
    }

    private func recordingRunner() -> Recorder { Recorder() }

    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-launchagent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
