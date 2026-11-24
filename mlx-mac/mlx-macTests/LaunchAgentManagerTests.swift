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
            slot.acceleration = .init(m5Prefill: true, promptLookup: true, thinkingOff: true, maximumTokens: 2048)
            let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.path, receiptDirectory: home.path)
            let plan = try await api.loginItemPlan(slot: slot, fleetURL: home.appendingPathComponent("fleet.json"))
            XCTAssertTrue(plan.arguments.contains("--path"))
            XCTAssertTrue(plan.arguments.contains("--confirm"))
            XCTAssertTrue(plan.arguments.contains("--m5-prefill"))
            XCTAssertTrue(plan.arguments.contains("--prompt-lookup"))
            XCTAssertEqual(plan.arguments[try XCTUnwrap(plan.arguments.firstIndex(of: "--max-tokens")) + 1], "2048")
            XCTAssertEqual(plan.arguments[try XCTUnwrap(plan.arguments.firstIndex(of: "--thinking")) + 1], "off")
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
        slot.acceleration = .init(m5Prefill: true, promptLookup: true, thinkingOff: true, maximumTokens: 2048)
        try fleet.replaceAll([EndpointFleetConfig(slots: [slot], installedAtLogin: true)])
        XCTAssertNotEqual(try execute(), 0)
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
        XCTAssertEqual(plist["Label"] as? String, LaunchAgentManager.label(for: slot.id))
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.plistURL(for: slot.id).path))

        let commands = recorder.commands
        XCTAssertEqual(commands.map(\.executable), ["/bin/launchctl", "/bin/launchctl", "/bin/launchctl"])
        XCTAssertEqual(commands[0].argv, ["bootout", "gui/501/\(LaunchAgentManager.legacyLabel)"])
        XCTAssertEqual(commands[1].argv, ["bootout", "gui/501/\(LaunchAgentManager.label(for: slot.id))"])
        XCTAssertEqual(commands[2].argv, ["bootstrap", "gui/501", manager.plistURL(for: slot.id).path])
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

    func testUnwritableSecondPlistLeavesNoPartiallyInstalledFleet() throws {
        let manager = LaunchAgentManager(home: try makeHome(), run: recordingRunner().run, uid: 501)
        let first = plan()
        let second = LoginItemPlan(slot: EndpointSlot(enabled: true, port: 8767, modelPath: "/models/other"),
                                   fleetURL: first.fleetURL, agentPath: first.agentPath, arguments: first.arguments)
        let collision = manager.plistURL(for: second.slot.id)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)

        XCTAssertThrowsError(try manager.install(plans: [first, second]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.plistURL(for: first.slot.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: collision.path))
    }

    func testSecondBootstrapFailureRestoresThePreviouslyInstalledPlist() throws {
        let home = try makeHome()
        let original = plan()
        let initial = LaunchAgentManager(home: home, run: recordingRunner().run, uid: 501)
        try initial.install(plan: original)
        let originalURL = initial.plistURL(for: original.slot.id)
        let initialData = try Data(contentsOf: originalURL)
        let replacement = LoginItemPlan(slot: original.slot, fleetURL: original.fleetURL, agentPath: "/new/agent", arguments: original.arguments)
        let second = LoginItemPlan(slot: EndpointSlot(enabled: true, port: 8767, modelPath: "/models/other"),
                                   fleetURL: original.fleetURL, agentPath: original.agentPath, arguments: original.arguments)
        let secondPath = initial.plistURL(for: second.slot.id).path
        let recorder = Recorder()
        let manager = LaunchAgentManager(home: home, run: { executable, argv in
            let output = try recorder.run(executable, argv)
            if argv.first == "bootstrap", argv.last == secondPath { throw LaunchAgentError.launchctlFailed("Second agent refused") }
            return output
        }, uid: 501)

        XCTAssertThrowsError(try manager.install(plans: [replacement, second]))
        XCTAssertEqual(try Data(contentsOf: originalURL), initialData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondPath))
        XCTAssertEqual(recorder.commands.last?.argv, ["bootstrap", "gui/501", originalURL.path])
    }

    func testUninstallBootsOutAndRemovesPlist() throws {
        let home = try makeHome()
        let recorder = Recorder()
        let manager = LaunchAgentManager(home: home, run: recorder.run, uid: 501)
        try manager.install(plan: plan())
        recorder.reset()

        try manager.uninstall()

        XCTAssertFalse(manager.isInstalled)
        XCTAssertEqual(recorder.commands.map(\.argv), [
            ["bootout", "gui/501/\(LaunchAgentManager.legacyLabel)"],
            ["bootout", "gui/501/\(LaunchAgentManager.label(for: slot.id))"],
        ])
    }

    func testUninstallWhenNothingInstalledSucceeds() throws {
        let manager = LaunchAgentManager(home: try makeHome(), run: recordingRunner().run, uid: 501)
        XCTAssertNoThrow(try manager.uninstall())
    }

    func testInstallStartsEachEnabledSlotAndRemovesLegacyAndStaleAgents() throws {
        let home = try makeHome()
        let recorder = Recorder()
        let manager = LaunchAgentManager(home: home, run: recorder.run, uid: 501)
        let first = EndpointSlot(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, enabled: true, port: 8766, modelPath: "/models/a")
        let second = EndpointSlot(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, enabled: true, port: 8767, modelPath: "/models/b")
        let stale = EndpointSlot(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, enabled: true, port: 8768, modelPath: "/models/stale")
        try FileManager.default.createDirectory(at: manager.plistURL(for: stale.id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: manager.plistURL(for: stale.id))
        try Data("legacy".utf8).write(to: home.appendingPathComponent("Library/LaunchAgents/\(LaunchAgentManager.legacyLabel).plist"))
        let plans = [first, second].map { item in
            LoginItemPlan(slot: item, fleetURL: URL(fileURLWithPath: "/state/endpoint-fleet.json"), agentPath: "/opt/agent",
                arguments: WorkbenchAPI.serveArguments(model: item.modelPath, runtime: "auto", port: item.port, receipts: "/state", previewHash: "reviewed-hash"))
        }

        try manager.install(plans: plans)

        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents/\(LaunchAgentManager.legacyLabel).plist").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.plistURL(for: stale.id).path))
        let bootstraps = recorder.commands.filter { $0.argv.first == "bootstrap" }.map(\.argv)
        XCTAssertEqual(bootstraps, [
            ["bootstrap", "gui/501", manager.plistURL(for: first.id).path],
            ["bootstrap", "gui/501", manager.plistURL(for: second.id).path],
        ])
        let firstPlist = try parsedPlist(manager.plistURL(for: first.id))
        let secondPlist = try parsedPlist(manager.plistURL(for: second.id))
        XCTAssertEqual(firstPlist["Label"] as? String, LaunchAgentManager.label(for: first.id))
        XCTAssertEqual(secondPlist["Label"] as? String, LaunchAgentManager.label(for: second.id))
        XCTAssertEqual(firstPlist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(secondPlist["KeepAlive"] as? Bool, false)
        XCTAssertEqual(firstPlist["StandardOutPath"] as? String, home.appendingPathComponent("Library/Logs/mlx-workbench-endpoint-8766.log").path)
        XCTAssertEqual(secondPlist["StandardOutPath"] as? String, home.appendingPathComponent("Library/Logs/mlx-workbench-endpoint-8767.log").path)
    }

    func testInstallRejectsMoreThanTheFleetCap() throws {
        let manager = LaunchAgentManager(home: try makeHome(), run: recordingRunner().run, uid: 501)
        let plans = (0..<(EndpointFleetConfig.maxSlots + 1)).map { index in
            LoginItemPlan(slot: EndpointSlot(enabled: true, port: 8800 + index, modelPath: "/models/\(index)"),
                fleetURL: URL(fileURLWithPath: "/state/fleet.json"), agentPath: "/opt/agent", arguments: ["serve", "start"])
        }
        XCTAssertThrowsError(try manager.install(plans: plans)) { error in
            guard case LaunchAgentError.invalidPlan = error else { return XCTFail("expected invalidPlan, got \(error)") }
        }
    }

    func testLoginInstallRefusesWontFitUntilOverride() {
        let wont = FitVerdict.wontFit(deficitGB: 1.5, suggestedMaxContext: nil)
        XCTAssertEqual(LoginFleetInstall.refusal(verdict: wont, overridden: false), wont.summary)
        XCTAssertNil(LoginFleetInstall.refusal(verdict: wont, overridden: true))
        XCTAssertNil(LoginFleetInstall.refusal(verdict: .fits(headroomGB: 2), overridden: false))
        XCTAssertNil(LoginFleetInstall.refusal(verdict: .tight(headroomGB: 0.4), overridden: false))
        XCTAssertNil(LoginFleetInstall.refusal(verdict: .unknown(reason: "size unknown"), overridden: false))
        XCTAssertNil(LoginFleetInstall.refusal(verdict: nil, overridden: false))
    }

    private func parsedPlist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
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
