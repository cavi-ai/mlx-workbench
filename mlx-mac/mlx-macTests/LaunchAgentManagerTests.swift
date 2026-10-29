import Foundation
import XCTest

@testable import mlx_workbench

/// LaunchAgentManager writes launchd plists and drives launchctl through an
/// injected runner — tests use a temp home and a recording runner, never the
/// real launchctl.
final class LaunchAgentManagerTests: XCTestCase {
    private let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/models/qwen")
    private func plan() -> LoginItemPlan {
        LoginItemPlan(slot: slot, fleetURL: URL(fileURLWithPath: "/state/endpoint-fleet.json"), agentPath: "/opt/agent",
            arguments: WorkbenchAPI.serveArguments(model: slot.modelPath, runtime: "auto", port: slot.port, receipts: "/state", previewHash: "reviewed-hash"))
    }

    func testGeneratedStartupArgumentsPassTheVendoredEnginePreviewContract() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let agent = root.appendingPathComponent("vendor/mlx-agent")
        let home = try makeHome(), model = home.appendingPathComponent("local model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data(#"{"model_type":"qwen2","hidden_size":16}"#.utf8).write(to: model.appendingPathComponent("config.json"))
        try Data([0, 0, 0, 0]).write(to: model.appendingPathComponent("model.safetensors"))
        for jit in [false, true] {
            var slot = EndpointSlot(enabled: true, port: 19997, modelPath: model.path,
                loadOnRequest: jit, memoryPolicy: jit ? .automatic : nil)
            slot.acceleration = .init(m5Prefill: true, promptLookup: true)
            let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.path, receiptDirectory: home.path)
            let plan = try await api.loginItemPlan(slot: slot, fleetURL: home.appendingPathComponent("fleet.json"))
            XCTAssertTrue(plan.arguments.contains("--path"))
            XCTAssertTrue(plan.arguments.contains("--confirm"))
            XCTAssertTrue(plan.arguments.contains("--m5-prefill"))
            XCTAssertTrue(plan.arguments.contains("--prompt-lookup"))
            XCTAssertEqual(plan.arguments.contains("--jit"), jit)
            let hashIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--preview-hash")) + 1
            var changed = plan.arguments; changed[hashIndex] = "unreviewed"
            do {
                _ = try CLIProcess().run(agentPath: agent.path, argv: changed)
                XCTFail("A changed hash must not start a server")
            } catch let error as BridgeError { XCTAssertEqual(error.code, "preview_stale") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".mlx-agent-receipts/serve/19997.json").path))
        }
    }

    func testLoginBootstrapExecutesOnlyTheReviewedEnabledSlot() throws {
        let home = try makeHome(), agent = home.appendingPathComponent("agent")
        let scripts = agent.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let marker = home.appendingPathComponent("started.txt")
        let script = "from pathlib import Path\nwith Path(" + String(reflecting: marker.path) + ").open('a') as f: f.write('x')\n"
        try script.write(to: scripts.appendingPathComponent("mlx-agent"), atomically: true, encoding: .utf8)
        let fleet = JSONStore<EndpointFleetConfig>(fileURL: home.appendingPathComponent("fleet.json"))
        var slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/models/local")
        slot.acceleration = .init(m5Prefill: true, promptLookup: true)
        try fleet.replaceAll([EndpointFleetConfig(slots: [slot], installedAtLogin: true)])
        let plan = LoginItemPlan(slot: slot, fleetURL: fleet.url, agentPath: agent.path,
            arguments: WorkbenchAPI.serveArguments(model: slot.modelPath, runtime: "auto", port: slot.port, receipts: home.path, previewHash: "reviewed"))
        let manager = LaunchAgentManager(home: home, run: recordingRunner().run, interpreter: { _ in URL(fileURLWithPath: "/usr/bin/python3") })
        let text = try manager.plistPreview(plan: plan)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any])
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        func execute() throws -> Int32 {
            let process = Process(); process.executableURL = URL(fileURLWithPath: arguments[0])
            process.arguments = Array(arguments.dropFirst()); process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }
        XCTAssertEqual(try execute(), 0)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "x")
        slot.acceleration = .init(m5Prefill: true)
        try fleet.replaceAll([EndpointFleetConfig(slots: [slot], installedAtLogin: true)])
        XCTAssertNotEqual(try execute(), 0)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "x")
        slot = plan.slot
        slot.modelPath = "/models/changed"
        try fleet.replaceAll([EndpointFleetConfig(slots: [slot], installedAtLogin: true)])
        XCTAssertNotEqual(try execute(), 0)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "x")
        slot = plan.slot; slot.enabled = false
        try fleet.replaceAll([EndpointFleetConfig(slots: [slot], installedAtLogin: true)])
        XCTAssertNotEqual(try execute(), 0)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "x")
    }

    func testPreviewPlistIsWellFormedAndDeliberate() throws {
        let manager = LaunchAgentManager(home: try makeHome(), run: recordingRunner().run, uid: 501)
        let text = try manager.plistPreview(plan: plan())

        let data = try XCTUnwrap(text.data(using: .utf8))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["Label"] as? String, LaunchAgentManager.label)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        // KeepAlive must stay off — mlx-agent supervises its own server.
        XCTAssertEqual(plist["KeepAlive"] as? Bool, false)
        let environment = try XCTUnwrap(plist["EnvironmentVariables"] as? [String: String])
        XCTAssertTrue(environment["PATH"]?.hasPrefix(URL(fileURLWithPath: try XCTUnwrap((plist["ProgramArguments"] as? [String])?.first)).deletingLastPathComponent().path + ":") == true)

        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertTrue(arguments.first?.hasPrefix("/") == true)
        XCTAssertEqual(arguments[1], "-c")
        XCTAssertEqual(arguments[6], "/opt/agent/scripts/mlx-agent")
        XCTAssertEqual(Array(arguments.dropFirst(7)), ["serve", "start", "--path", "/models/qwen", "--runtime", "auto", "--receipts-dir", "/state", "--port", "8766", "--confirm", "--preview-hash", "reviewed-hash"])
    }

    func testPlistRunsTheInterpreterResolvedForTheAgentPath() throws {
        let manager = LaunchAgentManager(
            home: try makeHome(),
            run: recordingRunner().run,
            uid: 501,
            interpreter: { agentPath in
                agentPath == "/opt/agent" ? URL(fileURLWithPath: "/checkout/.venv/bin/python") : nil
            }
        )
        let text = try manager.plistPreview(plan: plan())
        let data = try XCTUnwrap(text.data(using: .utf8))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments.first, "/checkout/.venv/bin/python")
    }

    func testInstallWritesPlistAndBootstrapsAfterBootout() throws {
        let home = try makeHome()
        let recorder = Recorder()
        let manager = LaunchAgentManager(home: home, run: recorder.run, uid: 501)

        try manager.install(plan: plan())

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

        XCTAssertThrowsError(try manager.install(plan: plan())) { error in
            guard case LaunchAgentError.launchctlFailed = error else {
                return XCTFail("expected launchctlFailed, got \(error)")
            }
        }
    }

    func testUninstallBootsOutAndRemovesPlist() throws {
        let home = try makeHome()
        let recorder = Recorder()
        let manager = LaunchAgentManager(home: home, run: recorder.run, uid: 501)
        try manager.install(plan: plan())
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
