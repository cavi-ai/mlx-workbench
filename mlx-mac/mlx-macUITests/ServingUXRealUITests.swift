import AppKit
import CryptoKit
import Darwin
import Foundation
import XCTest

/// Inspects an archived comparison and real idle gateways in an isolated guest.
final class ServingUXRealUITests: XCTestCase {
    private enum CommandFailure: Error { case timedOut, exit(Int32), invalidEnvelope }
    private var app: XCUIApplication?
    private var root: URL?
    private var ownedPorts: [Int] = []
    private var commandNumber = 0
    private var engine = URL(fileURLWithPath: "/")
    private var python = URL(fileURLWithPath: "/")
    private var receipts = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        try NativeUITestEnvironment.requireIsolatedAquaSession()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        var cleaned = true
        for port in ownedPorts {
            if (try? command(["serve", "stop", "--port", String(port), "--receipts-dir", receipts.path])) == nil { cleaned = false }
        }
        if let root {
            for file in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix("command-") {
                guard let data = try? Data(contentsOf: file) else { continue }
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = file.lastPathComponent; attachment.lifetime = .keepAlways; add(attachment)
            }
            if cleaned { try? FileManager.default.removeItem(at: root) }
            else { XCTFail("Gateway cleanup failed; receipts retained at \(receipts.path)") }
        }
    }

    private func command(_ args: [String], expectingPreview: Bool = false) throws -> [String: Any] {
        let root = try XCTUnwrap(root)
        commandNumber += 1
        let stdout = root.appendingPathComponent("command-\(commandNumber)-stdout")
        let stderr = root.appendingPathComponent("command-\(commandNumber)-stderr")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let out = try FileHandle(forWritingTo: stdout), err = try FileHandle(forWritingTo: stderr)
        let process = Process(); process.executableURL = python
        process.arguments = [engine.appendingPathComponent("scripts/mlx-agent").path] + args + ["--json"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = python.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env; process.standardOutput = out; process.standardError = err
        let started = Date(); try process.run()
        let deadline = started.addingTimeInterval(120)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try out.close(); try err.close()
        let data = try Data(contentsOf: stdout), error = try Data(contentsOf: stderr)
        let record: [String: Any] = ["executable": python.path, "argv": process.arguments ?? [], "pid": process.processIdentifier,
            "started": started.timeIntervalSince1970, "finished": Date().timeIntervalSince1970,
            "status": process.terminationStatus, "stdout_base64": data.base64EncodedString(), "stderr_base64": error.base64EncodedString()]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: root.appendingPathComponent("command-\(commandNumber).json"))
        if timedOut { throw CommandFailure.timedOut }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["status"] as? String == "ok", let payload = envelope["data"] as? [String: Any] else {
            throw CommandFailure.invalidEnvelope
        }
        if expectingPreview {
            guard process.terminationStatus == 2, payload["requires_confirmation"] as? Bool == true,
                  let plan = payload["plan"] as? [String: Any],
                  let hash = plan["preview_hash"] as? String, !hash.isEmpty else { throw CommandFailure.invalidEnvelope }
        } else if process.terminationStatus != 0 { throw CommandFailure.exit(process.terminationStatus) }
        return payload
    }

    func testRealIdleEndpointsAndArchivedFailure() throws {
        let env = ProcessInfo.processInfo.environment
        let model = try XCTUnwrap(env["MLX_UX_MODEL_ROOT"])
        let archive = URL(fileURLWithPath: try XCTUnwrap(env["MLX_UX_ARCHIVE_PATH"]))
        let archiveHash = try XCTUnwrap(env["MLX_UX_ARCHIVE_SHA256"])
        let archiveID = try XCTUnwrap(env["MLX_UX_ARCHIVE_ID"])
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        engine = source.appendingPathComponent("vendor/mlx-agent"); python = source.appendingPathComponent(".venv/bin/python")
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("serving-ux-\(UUID().uuidString)")
        root = temporary
        let home = temporary.appendingPathComponent("home"), state = temporary.appendingPathComponent("state"), cache = temporary.appendingPathComponent("cache")
        receipts = home.appendingPathComponent("Library/Application Support/mlx-workbench")
        for dir in [home, state, cache, receipts] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let bytes = try Data(contentsOf: archive)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), archiveHash)
        let archived = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(archived["id"] as? String, archiveID)
        try (Data("[".utf8) + bytes + Data("]".utf8)).write(to: receipts.appendingPathComponent("comparison-runs.json"))
        let config: [String: Any] = ["mlx_agent_path": engine.path, "gguf_roots": [model], "mlx_roots": [model],
            "output_dir": model, "verification_enabled": false, "watch_enabled": false]
        let configURL = temporary.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: config).write(to: configURL)
        for port in [19081, 19082] {
            let args = ["serve", "start", "--runtime", "mlx_lm", "--path", model, "--port", String(port), "--jit", "--receipts-dir", receipts.path]
            let preview = try command(args, expectingPreview: true)
            let plan = try XCTUnwrap(preview["plan"] as? [String: Any]); let hash = try XCTUnwrap(plan["preview_hash"] as? String)
            ownedPorts.append(port)
            _ = try command(args + ["--confirm", "--preview-hash", hash])
        }
        try assertIdle()

        let application = XCUIApplication(); app = application
        application.launchEnvironment["MLX_WORKBENCH_CONFIG"] = configURL.path
        application.launchEnvironment["MLX_WORKBENCH_PYTHON"] = python.path
        application.launchEnvironment["CFFIXED_USER_HOME"] = home.path
        application.launchEnvironment["XDG_STATE_HOME"] = state.path
        application.launchEnvironment["XDG_CACHE_HOME"] = cache.path
        application.launchArguments = ["-mlx-workbench.setupCompleted.v1", "YES", "-sidebar.systemExpanded", "YES"]
        application.launch(); XCTAssertTrue(application.windows.firstMatch.waitForExistence(timeout: 30))
        let serving = application.buttons["Serving"].firstMatch
        XCTAssertTrue(serving.waitForExistence(timeout: 20)); serving.click()
        let first = text(":19081", in: application)
        XCTAssertTrue(first.waitForExistence(timeout: 30)); first.click()
        let sibling = application.buttons.matching(NSPredicate(format: "label CONTAINS %@", ":19082")).firstMatch
        XCTAssertTrue(sibling.waitForExistence(timeout: 15))
        resize(width: 1380, height: 850); XCTAssertGreaterThanOrEqual(application.windows.firstMatch.frame.width, 1300); capture("Serving real idle endpoints wide")
        resize(width: 1000, height: 720); XCTAssertLessThan(application.windows.firstMatch.frame.width, 1100); capture("Serving real idle endpoints ordinary")
        sibling.click()
        XCTAssertTrue(text("http://127.0.0.1:19082/v1", in: application).waitForExistence(timeout: 10))
        let monitor = application.buttons["Monitor"].firstMatch
        XCTAssertTrue(monitor.waitForExistence(timeout: 10)); monitor.click()
        XCTAssertTrue(text("live endpoint", in: application).waitForExistence(timeout: 20))
        resize(width: 1380, height: 850); capture("Monitor real idle endpoints wide")
        resize(width: 1000, height: 720); capture("Monitor real idle endpoints ordinary")
        let compare = application.buttons["Compare"].firstMatch
        XCTAssertTrue(compare.waitForExistence(timeout: 10)); compare.click()
        XCTAssertTrue(text("No comparison output", in: application).waitForExistence(timeout: 30))
        let started = try XCTUnwrap(archived["startedAt"] as? Double)
        let date = Date(timeIntervalSinceReferenceDate: started).formatted(date: .abbreviated, time: .shortened)
        XCTAssertTrue(text(date, in: application).exists)
        let results = try XCTUnwrap(archived["results"] as? [[String: Any]])
        let firstError = try XCTUnwrap(results.compactMap { $0["error"] as? String }.first)
        let firstLine = try XCTUnwrap(firstError.split(separator: "\n").first).description
        XCTAssertTrue(text(firstLine, in: application).exists)
        resize(width: 1380, height: 850); capture("Archived comparison failure wide")
        resize(width: 1000, height: 720); capture("Archived comparison failure ordinary")
        try assertIdle()
    }

    private func assertIdle() throws {
        let status = try command(["serve", "status", "--receipts-dir", receipts.path])
        let servers = try XCTUnwrap(status["servers"] as? [[String: Any]])
        let observed = servers.filter { [19081, 19082].contains($0["port"] as? Int ?? 0) }
        XCTAssertEqual(observed.count, 2)
        XCTAssertTrue(observed.allSatisfy { $0["model_state"] as? String == "unloaded" && ($0["worker_pid"] == nil || $0["worker_pid"] is NSNull) })
        XCTAssertEqual(Set(observed.compactMap { $0["pid"] as? Int }).count, 2)
    }

    private func text(_ fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)).firstMatch
    }

    private func resize(width: CGFloat, height: CGFloat) {
        guard let window = app?.windows.firstMatch else { return }
        let screen = NSScreen.main?.frame
        func moveHorizontally(_ delta: CGFloat) {
            let titlebar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 20))
            titlebar.press(forDuration: 0.1, thenDragTo: titlebar.withOffset(CGVector(dx: delta, dy: 0)))
        }
        if let screen, window.frame.maxX > screen.maxX { moveHorizontally(screen.maxX - window.frame.maxX - 8) }
        let fittedWidth = min(width, screen?.width ?? width)
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        let target = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: fittedWidth - 2, dy: height - 2))
        corner.press(forDuration: 0.1, thenDragTo: target)
        if let screen, window.frame.minX < screen.minX { moveHorizontally(screen.minX - window.frame.minX) }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
