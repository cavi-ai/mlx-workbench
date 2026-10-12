import Darwin
import SystemConfiguration
import XCTest
import AppKit

enum NativeUITestEnvironment {
    private struct IsolationError: LocalizedError {
        let reason: String
        var errorDescription: String? {
            "Native UI tests require a macOS VM with this user's active Aqua console. \(reason) Run the tests inside the isolated VM after logging in to its desktop."
        }
    }

    static func requireIsolatedAquaSession() throws {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            throw IsolationError(reason: "Cannot verify the hardware model.")
        }
        var model = [CChar](repeating: 0, count: size)
        let result = model.withUnsafeMutableBufferPointer { buffer in
            sysctlbyname("hw.model", buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0, String(cString: model).hasPrefix("VirtualMac") else {
            throw IsolationError(reason: "The hardware model is not VirtualMac.")
        }

        var consoleUID: uid_t = 0
        guard let consoleUser = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil),
              (consoleUser as String) != "loginwindow",
              getuid() != 0, consoleUID == getuid() else {
            throw IsolationError(reason: "The active console does not belong to the test user.")
        }

        let session = Process()
        let output = Pipe()
        session.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        session.arguments = ["managername"]
        session.standardOutput = output
        session.standardError = FileHandle.nullDevice
        do {
            try session.run()
        } catch {
            throw IsolationError(reason: "Cannot verify the Aqua session.")
        }
        session.waitUntilExit()
        let manager = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.terminationStatus == 0, manager == "Aqua" else {
            throw IsolationError(reason: "The test process is not in an Aqua session.")
        }
    }
}

/// Native presentation checks use an isolated home and a deterministic CLI.
/// No model operation or external discovery is executed by these fixtures.
final class WorkbenchReviewUITests: XCTestCase {
    private var app: XCUIApplication!
    private var root: URL!

    override func setUpWithError() throws {
        try NativeUITestEnvironment.requireIsolatedAquaSession()
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Disposable VM screen-capture consent") { dialog in
            let text = dialog.staticTexts.allElementsBoundByIndex
                .map { $0.label + " " + (($0.value as? String) ?? "") }.joined(separator: " ")
            guard text.contains("tart-guest-agent"), text.contains("private window picker") else { return false }
            let allow = dialog.buttons["Allow"].firstMatch
            guard allow.exists else { return false }
            allow.click()
            return true
        }
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workbench-review-\(UUID().uuidString)")
        let script = root.appendingPathComponent("agent/scripts/mlx-agent")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        let python = """
        import hashlib, json, pathlib, sys, time
        root = pathlib.Path(__file__).resolve().parents[2]
        args = sys.argv[1:]
        with (root / 'calls.jsonl').open('a') as f:
            f.write(json.dumps(args) + '\\n')
        if args[:2] == ['convert', 'scan']:
            if (root / 'fail-scan').exists():
                print('Fixture scan failed: choose a readable model root.', file=sys.stderr)
                sys.exit(2)
            data = {'models': [], 'outputs': [], 'pending': [], 'duplicates': [],
                    'totals': {'gguf': 0, 'pending': 0, 'converted': 0, 'unreadable': 0, 'bytes': 0, 'reclaimable_bytes': 0}}
        elif args and args[0] == 'doctor':
            time.sleep(0.5)
            if (root / 'fail-doctor').exists():
                print('Fixture doctor failed: inventory unavailable.', file=sys.stderr)
                sys.exit(2)
            data = {'findings': [], 'prune_count': 0}
        elif args and args[0] == 'discover':
            time.sleep(0.5)
            if (root / 'fail-discover').exists():
                print('Fixture discovery failed: catalog unavailable.', file=sys.stderr)
                sys.exit(2)
            data = {'candidates': []}
        elif args[:2] == ['serve', 'status'] and (root / 'servers.json').exists():
            time.sleep(2 if (root / 'slow-server-status').exists() else 0.3)
            if (root / 'fail-server-status').exists():
                print('Fixture server status failed.', file=sys.stderr)
                sys.exit(2)
            data = {'servers': json.loads((root / 'servers.json').read_text())}
        elif args[:2] == ['lora', 'start'] and '--confirm' not in args:
            time.sleep(0.5)
            data = {'preview_hash': 'fixture-training-preview'}
        elif args[:2] == ['wire', 'apply']:
            time.sleep(1.5)
            model = args[2]
            config_path = pathlib.Path(args[args.index('--path') + 1])
            assert config_path.is_absolute() and root in config_path.parents
            target = args[args.index('--target') + 1]
            original = config_path.read_text()
            digest = hashlib.sha256(json.dumps([model, str(config_path), target, original]).encode()).hexdigest()
            preview = {'preview_hash': digest, 'diff': 'Configure ' + model + ' for ' + target}
            confirming = '--confirm' in args
            if (root / ('fail-wire-apply' if confirming else 'fail-wire-preview')).exists():
                print('Fixture manual wiring failed: inspect the config file and preview again.', file=sys.stderr)
                sys.exit(2)
            if confirming:
                assert args[args.index('--preview-hash') + 1] == digest
                applied = not (root / 'false-wire-apply').exists()
                if applied:
                    config_path.write_text(json.dumps({'model': model, 'target': target}))
                data = {'preview': preview, 'applied': applied}
            else:
                if (root / 'missing-wire-hash').exists():
                    preview.pop('preview_hash')
                data = {'preview': preview, 'requires_confirmation': True}
        elif args[:2] in (['adopt', 'start'], ['adopt', 'status']):
            time.sleep(1.5)
            if '--state' not in args:
                print('No adoption state path was supplied.', file=sys.stderr)
                sys.exit(2)
            state_path = pathlib.Path(args[args.index('--state') + 1])
            assert state_path.is_absolute() and state_path.parent.is_dir()
            if args[1] == 'start':
                if (root / 'fail-adopt-start').exists():
                    print('Fixture adoption failed: inspect the saved handoff and retry.', file=sys.stderr)
                    sys.exit(2)
                assert not state_path.exists(), 'A previous adoption must not be overwritten'
                role = args[args.index('--role') + 1]
                assert role in ['vision', 'embedding', 'coding', 'reasoning', 'general', 'tool-use']
                recommendation = [] if (root / 'adopt-no-recommendation').exists() else [
                    {'role': role, 'repo': 'mlx-community/Qwen-Coding-Long-Repository-Name-For-Local-Adoption-4bit',
                     'evidence_strength': 'verified'}]
                state = {'workflow_id': 'workflow-' + state_path.stem, 'status': 'complete', 'phase': 'complete',
                         'request': {'roles': [role]}, 'recommendations': recommendation,
                         'shortlist': [{'repo': 'shortlisted-only/model'}]}
                if (root / 'adopt-unknown').exists():
                    state = {'workflow_id': 'workflow-' + state_path.stem, 'request': {'roles': [role]}}
                state_path.write_text(json.dumps(state))
            else:
                assert state_path.is_file(), 'Status must read the actual adoption handoff'
                if (root / 'fail-adopt-status').exists():
                    print('Fixture adoption status failed: the handoff is temporarily unreadable. Refresh to try again.', file=sys.stderr)
                    sys.exit(2)
                state = json.loads(state_path.read_text())
            data = {'state': state}
        else:
            data = {'servers': [], 'jobs': [], 'changes': []}
        print(json.dumps({'status': 'ok', 'data': data}))
        """
        try python.write(to: script, atomically: true, encoding: .utf8)
        let config: [String: Any] = [
            "mlx_agent_path": root.appendingPathComponent("agent").path,
            "mlx_roots": [root.appendingPathComponent("models").path], "gguf_roots": [],
            "output_dir": root.appendingPathComponent("output").path,
            "verification_enabled": false, "watch_enabled": false
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("config.json"))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func launch(appearance: String, route: String = "doctor", isolatedHome: Bool = false, configURL: URL? = nil) {
        if appearance == "Light" || appearance == "Dark" {
            let requested: XCUIDevice.Appearance = appearance == "Dark" ? .dark : .light
            XCUIDevice.shared.appearance = requested
            XCTAssertEqual(XCUIDevice.shared.appearance, requested, "Guest appearance did not change")
        }
        app = XCUIApplication()
        app.launchEnvironment["MLX_WORKBENCH_CONFIG"] = (configURL ?? root.appendingPathComponent("config.json")).path
        app.launchEnvironment["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        app.launchEnvironment["MLX_WORKBENCH_PYTHON"] = "/usr/bin/python3"
        if isolatedHome { app.launchEnvironment["CFFIXED_USER_HOME"] = root.path }
        // NSArgumentDomain overrides writes to AppStorage. A mutable route
        // must be selected through the UI rather than forced as a launch default.
        app.launchArguments = ["-mlx-workbench.setupCompleted.v1", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
        resizeWindow(width: 1050, height: 720)
        let destinations = ["doctor": "Health", "models": "Library", "training-studio": "Training", "settings": "Settings"]
        if let destination = destinations[route] { select(destination) }
    }

    private func capture(_ name: String) {
        app.activate()
        XCTAssertEqual(app.state, .runningForeground, "Capture requires the guest app in the foreground")
        let window = app.windows.firstMatch
        let size = window.frame.size
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "\(name)-\(Int(size.width))x\(Int(size.height))"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func resizeWindow(width: CGFloat, height: CGFloat) {
        let window = app.windows.firstMatch
        let screen = NSScreen.main?.frame
        func moveHorizontally(_ delta: CGFloat) {
            let titlebar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                .withOffset(CGVector(dx: 0, dy: 20))
            titlebar.press(forDuration: 0.1, thenDragTo: titlebar.withOffset(CGVector(dx: delta, dy: 0)))
        }
        // A restored window may extend past the guest display. Bring its
        // resize handle on-screen before dragging, then keep the capture visible.
        if let screen, window.frame.maxX > screen.maxX - 4 {
            moveHorizontally(screen.maxX - window.frame.maxX - 8)
        }
        let fittedWidth = min(width, screen?.width ?? width)
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        let target = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: fittedWidth - 2, dy: height - 2))
        corner.press(forDuration: 0.1, thenDragTo: target)
        if let screen, window.frame.minX < screen.minX {
            moveHorizontally(screen.minX - window.frame.minX)
        }
    }

    private func select(_ route: String) {
        app.activate()
        let button = app.buttons[route].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), route)
        button.click()
    }

    private func replace(_ field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
    }

    private var routes: [String] {
        ["Overview", "Library", "Prepare", "Compare", "Run", "Activity", "Reclaim", "Clients",
         "Health", "Discover", "LM Studio", "Training", "Adopt", "Settings"]
    }

    private func assertPageContent(_ route: String) {
        let titles = ["Library": "No models found", "Prepare": "Choose a model to prepare",
                      "Run": "Serve a model", "Activity": "Servers", "Reclaim": "Quarantine",
                      "Clients": "Client wiring", "Health": "Model inventory findings",
                      "Discover": "Discovery", "Training": "LoRA fine-tune", "Adopt": "Adopt a role"]
        let element: XCUIElement
        if let title = titles[route] { element = app.staticTexts[title].firstMatch }
        else if route == "Settings" { element = app.staticTexts["Engine status"].firstMatch }
        else if route == "LM Studio" { element = app.buttons["Scan LM Studio"] }
        else if route == "Overview" { element = app.buttons["Open Health"] }
        else { element = app.buttons["New set…"] }
        XCTAssertTrue(element.waitForExistence(timeout: 20), "Missing \(route) content")
    }

    func testRealAgentInventoryAndPages() throws {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let agent = checkout.appendingPathComponent("vendor/mlx-agent")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: agent.appendingPathComponent("scripts/mlx-agent").path))
        let config: [String: Any] = [
            "mlx_agent_path": agent.path,
            "mlx_roots": [root.appendingPathComponent("models").path],
            "gguf_roots": [root.appendingPathComponent("models").path],
            "output_dir": root.appendingPathComponent("output").path,
            "verification_enabled": false, "watch_enabled": false
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("config.json"))
        launch(appearance: "System", route: "models")
        XCTAssertTrue(app.staticTexts["No models found"].waitForExistence(timeout: 30))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls.jsonl").path),
                       "The real-agent test must not call the fixture backend")
        for route in routes {
            select(route)
            assertPageContent(route)
            capture("Real-agent-\(route)")
        }
    }

    func testLibraryFirstFailureCanRetry() throws {
        try Data().write(to: root.appendingPathComponent("fail-scan"))
        launch(appearance: "Light", route: "models")
        XCTAssertTrue(app.staticTexts["Library scan failed"].waitForExistence(timeout: 20))
        let failure = text(containing: "Fixture scan failed")
        if !failure.exists, app.buttons["Details"].exists { app.buttons["Details"].click() }
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        capture("Library-first-scan-error-details")
        if app.popovers.firstMatch.exists { app.typeKey(XCUIKeyboardKey.escape, modifierFlags: []) }
        XCTAssertTrue(app.buttons["Open Settings"].isHittable)
        capture("Library-first-scan-failed")
        try FileManager.default.removeItem(at: root.appendingPathComponent("fail-scan"))
        app.buttons["Retry scan"].click()
        XCTAssertTrue(app.buttons["Retry scan"].waitForNonExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["No models found"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Library scan failed"].exists)
        capture("Library-retry-empty-success")
    }

    func testHealthAndDiscoveryResultsAndRecovery() throws {
        defer {
            if let calls = try? String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8) {
                let attachment = XCTAttachment(string: calls)
                attachment.name = "Recovery CLI requests"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        launch(appearance: "Light")
        let idle = "Inventory has not been checked. Run doctor to check local model files."
        XCTAssertTrue(app.staticTexts[idle].waitForExistence(timeout: 10))
        app.buttons["Run doctor"].click()
        XCTAssertTrue(app.staticTexts["No inventory issues found in the latest doctor run."].waitForExistence(timeout: 15))
        capture("Health-clean-success")
        app.buttons["Clear"].click()
        XCTAssertTrue(app.staticTexts[idle].exists)
        try Data().write(to: root.appendingPathComponent("fail-doctor"))
        app.buttons["Run doctor"].click()
        XCTAssertTrue(text(containing: "Fixture doctor failed").waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["No inventory issues found in the latest doctor run."].exists)
        capture("Health-failed-recovery")

        select("Discover")
        let discover = app.scrollViews.containing(.staticText, identifier: "Discovery")
            .buttons["Discover"].firstMatch
        XCTAssertTrue(discover.waitForExistence(timeout: 5))
        XCTAssertTrue(discover.isHittable)
        discover.click()
        let empty = "No candidates matched. Try another role or adjust the limit, then Discover again."
        XCTAssertTrue(app.staticTexts[empty].waitForExistence(timeout: 15))
        capture("Discover-empty-success")
        try Data().write(to: root.appendingPathComponent("fail-discover"))
        discover.click()
        XCTAssertTrue(text(containing: "Fixture discovery failed").waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts[empty].exists)
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] }
        XCTAssertEqual(calls.filter { $0.first == "discover" }.count, 2,
                       "Both Discover actions must reach the CLI")
        capture("Discover-failed-recovery")

        select("LM Studio")
        replace(app.textFields.firstMatch, with: root.appendingPathComponent("missing").path)
        app.buttons["Scan LM Studio"].click()
        XCTAssertTrue(text(containing: "Scan failed").waitForExistence(timeout: 15))
        capture("LMStudio-invalid-source-recovery")
    }

    func testTrainingEditsRequireNewPreview() throws {
        launch(appearance: "Light", route: "training-studio")
        replace(app.textFields["Base model repo id"], with: "fixture/base")
        replace(app.textFields["Dataset path"], with: root.path)
        app.buttons["Preview Training"].click()
        XCTAssertTrue(app.buttons["Confirm & Train"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Confirm & Train"].isEnabled)
        capture("Training-reviewed-request")
        replace(app.textFields["Iterations"], with: "200")
        XCTAssertTrue(!app.buttons["Confirm & Train"].exists || !app.buttons["Confirm & Train"].isEnabled)
        capture("Training-edited-preview-invalidated")
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        XCTAssertFalse(calls.contains("--confirm"))
    }

    private func text(containing value: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)).firstMatch
    }

    func testSettingsInputsExposeSemanticLabels() {
        launch(appearance: "Light", route: "settings")
        XCTAssertTrue(app.textFields["mlx-agent checkout"].waitForExistence(timeout: 10))
        let labels = ["Output directory", "Quarantine directory", "Workbench API host", "Workbench API port",
                      "Fit reserve in gigabytes", "Stale after days", "Comparison maximum tokens"]
        for label in labels {
            let field = app.textFields[label]
            for _ in 0..<8 where !field.isHittable {
                app.scrollViews.allElementsBoundByIndex.last?.scroll(byDeltaX: 0, deltaY: -350)
            }
            XCTAssertTrue(field.exists, label)
            XCTAssertTrue(field.isHittable, label)
        }
        capture("Settings-scrolled-semantic-inputs")
    }

    func testSettingsValidationRecoveryAndSaveFeedback() throws {
        let before = ProcessInfo.processInfo.environment["MLX_WORKBENCH_CAPTURE_STAGE"] == "before"
        let configURL = root.appendingPathComponent(String(repeating: "settings-", count: 18) + "config.json")
        var initial = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("config.json"))) as? [String: Any])
        initial["future_feature"] = "preserve-me"
        let original = try JSONSerialization.data(withJSONObject: initial)
        for appearance in ["Light", "Dark"] {
            try original.write(to: configURL)
            launch(appearance: appearance, route: "settings", isolatedHome: true, configURL: configURL)
            resizeWindow(width: 1024, height: 680)
            capture("Settings-\(appearance)-clean")
            let host = app.textFields["Workbench API host"]
            let port = app.textFields["Workbench API port"]
            let reserve = app.textFields["Fit reserve in gigabytes"]
            let scroll = app.scrollViews.containing(.textField, identifier: "Workbench API host").firstMatch
            func reveal(_ field: XCUIElement) {
                XCTAssertTrue(field.waitForExistence(timeout: 10))
                for _ in 0..<8 where !scroll.frame.contains(field.frame) || !field.isHittable {
                    scroll.scroll(byDeltaX: 0, deltaY: field.frame.minY < scroll.frame.minY ? 300 : -300)
                }
                XCTAssertTrue(scroll.frame.contains(field.frame), "Input must be inside the editor before clicking")
                XCTAssertTrue(field.isHittable)
            }
            func focusedReplace(_ value: String) {
                app.typeKey("a", modifierFlags: .command)
                app.typeText(value)
            }
            func feedbackText(_ identifier: String) -> String {
                let element = app.staticTexts[identifier]
                XCTAssertTrue(element.waitForExistence(timeout: 5))
                return element.value as? String ?? element.label
            }
            reveal(host)
            replace(host, with: "example.com")
            reveal(port)
            replace(port, with: "abc")
            reveal(reserve)
            replace(reserve, with: "invalid")
            app.typeText("!")
            XCTAssertEqual(reserve.value as? String, "invalid!", "Validation feedback must not steal input focus")
            XCTAssertEqual(host.value as? String, "example.com")
            XCTAssertFalse(host.isHittable, "Editing a later field must not jump to the first invalid input")
            let save = before ? app.buttons["Save"].firstMatch : app.buttons["settings-save"]
            XCTAssertFalse(save.isEnabled)
            XCTAssertEqual(try Data(contentsOf: configURL), original)
            capture("Settings-\(appearance)-multiple-invalid")
            resizeWindow(width: 740, height: 680)
            XCTAssertEqual(app.windows.firstMatch.frame.width, 740, accuracy: 2)
            XCTAssertEqual(app.windows.firstMatch.frame.height, 680, accuracy: 2)
            reveal(reserve)
            XCTAssertFalse(host.isHittable, "Recovery must begin with the first invalid input offscreen")
            capture("Settings-\(appearance)-multiple-invalid-narrow")
            if before {
                reveal(host); replace(host, with: "localhost")
                reveal(port); replace(port, with: "8788 ")
                reveal(reserve); replace(reserve, with: "8")
            } else {
                let fix = app.buttons["settings-fix-field"]
                let guidance = app.staticTexts["settings-save-guidance"]
                let windowFrame = app.windows.firstMatch.frame
                let guidanceFrame = guidance.frame
                if !windowFrame.contains(guidanceFrame) {
                    let hierarchy = XCTAttachment(string: app.debugDescription)
                    hierarchy.name = "Settings feedback layout"
                    hierarchy.lifetime = .keepAlways
                    add(hierarchy)
                }
                XCTAssertTrue(windowFrame.contains(guidanceFrame), "Feedback \(guidanceFrame) must remain inside window \(windowFrame); Save \(save.frame)")
                XCTAssertTrue(app.windows.firstMatch.frame.contains(save.frame), "Save must remain inside the window")
                XCTAssertTrue(fix.isHittable, "Recovery must remain visible in the pinned bar")
                XCTAssertTrue(feedbackText("settings-save-guidance").contains("Host"))
                fix.click()
                XCTAssertTrue(host.isHittable)
                XCTAssertEqual(host.value as? String, "example.com")
                XCTAssertEqual(port.value as? String, "abc")
                XCTAssertEqual(reserve.value as? String, "invalid!")
                XCTAssertEqual(try Data(contentsOf: configURL), original)
                focusedReplace("localhos")
                app.typeText("t")
                XCTAssertEqual(host.value as? String, "localhost", "Fix field must focus the actual input")
                XCTAssertTrue(feedbackText("settings-save-guidance").contains("Port"))
                fix.click()
                focusedReplace("8788")
                app.typeText(" ")
                XCTAssertEqual(port.value as? String, "8788 ")
                XCTAssertTrue(feedbackText("settings-save-guidance").contains("Fit reserve"))
                fix.click()
                focusedReplace("8")
                XCTAssertEqual(reserve.value as? String, "8")
                XCTAssertFalse(fix.exists)
            }
            XCTAssertTrue(save.isEnabled)
            XCTAssertEqual(try Data(contentsOf: configURL), original, "Recovery must not save the draft")
            capture("Settings-\(appearance)-valid-draft-narrow")
            save.click()
            XCTAssertTrue(text(containing: "Saved to").waitForExistence(timeout: 10))
            let savedBytes = try Data(contentsOf: configURL)
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: savedBytes) as? [String: Any])
            XCTAssertEqual(saved["host"] as? String, "localhost")
            XCTAssertEqual(saved["port"] as? Int, 8788)
            XCTAssertEqual(saved["fit_reserve_gb"] as? Double, 8)
            XCTAssertEqual(saved["future_feature"] as? String, "preserve-me")
            capture("Settings-\(appearance)-saved-narrow")
            resizeWindow(width: 1024, height: 680)
            capture("Settings-\(appearance)-saved")
            reveal(port)
            replace(port, with: "abc")
            if !before {
                XCTAssertTrue(feedbackText("settings-save-guidance").contains("Port"), "A prior success must not obscure validation")
            }
            replace(port, with: "8789")
            // A real read failure on a test-owned config exercises the existing
            // persistence boundary without a production error-injection seam.
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: configURL.path)
            let expectedFailure: String
            do {
                _ = try Data(contentsOf: configURL)
                XCTFail("The owned config must be unreadable")
                return
            } catch { expectedFailure = error.localizedDescription }
            XCTAssertGreaterThan(expectedFailure.count, 180)
            save.click()
            XCTAssertTrue(text(containing: expectedFailure).waitForExistence(timeout: 10))
            if !before {
                XCTAssertEqual(feedbackText("settings-save-error"), expectedFailure)
                XCTAssertTrue(app.windows.firstMatch.frame.contains(app.staticTexts["settings-save-error"].frame))
            }
            XCTAssertEqual(port.value as? String, "8789", "Save failure must retain the draft")
            XCTAssertTrue(save.isEnabled)
            capture("Settings-\(appearance)-save-failed")
            resizeWindow(width: 740, height: 680)
            if !before {
                XCTAssertEqual(feedbackText("settings-save-error"), expectedFailure)
                XCTAssertTrue(app.windows.firstMatch.frame.contains(app.staticTexts["settings-save-error"].frame))
                XCTAssertTrue(app.windows.firstMatch.frame.contains(save.frame))
            }
            capture("Settings-\(appearance)-save-failed-narrow")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            XCTAssertEqual(try Data(contentsOf: configURL), savedBytes, "Failed Save must not write")
            save.click()
            XCTAssertTrue(text(containing: "Saved to").waitForExistence(timeout: 10))
            let retried = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
            XCTAssertEqual(retried["port"] as? Int, 8789)
            XCTAssertEqual(retried["future_feature"] as? String, "preserve-me")
            app.terminate()
        }
    }

    func testClientWiringPreviewAndEndpointSelection() throws {
        let config = root.appendingPathComponent(".config/opencode/opencode.jsonc")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{\"theme\":\"dark\"}".utf8)
        try original.write(to: config)
        let servers: [[String: Any]] = [
            ["repo": "org/Qwen-first", "runtime": "mlx_lm", "port": 8766, "pid": 123, "state": "running"],
            ["repo": "org/Qwen-second", "runtime": "mlx_lm", "port": 8767, "pid": 456, "state": "running"]
        ]
        try JSONSerialization.data(withJSONObject: servers).write(to: root.appendingPathComponent("servers.json"))
        let isBeforeCapture = ProcessInfo.processInfo.environment["MLX_WORKBENCH_CAPTURE_STAGE"] == "before"
        for appearance in ["Light", "Dark"] {
            try original.write(to: config)
            launch(appearance: appearance, isolatedHome: true)
            select("Clients")
            // The preserved app exposes its endpoint picker without an AX label.
            let endpoint = isBeforeCapture ? app.popUpButtons.firstMatch : app.popUpButtons["client-wiring-endpoint"].firstMatch
            XCTAssertTrue(endpoint.waitForExistence(timeout: 10))
            endpoint.click()
            app.menuItems["Qwen-first :8766"].click()
            XCTAssertFalse(app.buttons["Confirm client wiring"].exists)
            capture("Clients-\(appearance)-before-preview")
            app.buttons["Preview client wiring"].click()
            let confirm = app.buttons["Confirm client wiring"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            XCTAssertTrue(confirm.isEnabled)
            if isBeforeCapture {
                XCTAssertEqual(try Data(contentsOf: config), original)
                capture("Clients-\(appearance)-matching-preview")
                resizeWindow(width: 740, height: 680)
                for _ in 0..<6 where !confirm.isHittable {
                    app.scrollViews.allElementsBoundByIndex.last?.scroll(byDeltaX: 0, deltaY: -220)
                }
                XCTAssertTrue(confirm.isHittable)
                capture("Clients-\(appearance)-matching-preview-narrow")
                app.terminate()
                continue
            }
            let refreshPreview = app.buttons["Refresh preview"]
            XCTAssertTrue(refreshPreview.exists)
            XCTAssertFalse(app.buttons["Preview client wiring"].exists)
            let reviewedModel = app.staticTexts["client-wiring-reviewed-model"]
            let reviewedEndpoint = app.staticTexts["client-wiring-reviewed-endpoint"]
            XCTAssertEqual(reviewedModel.value as? String, "org/Qwen-first")
            XCTAssertEqual(reviewedEndpoint.value as? String, "http://127.0.0.1:8766/v1")
            XCTAssertEqual(try Data(contentsOf: config), original, "Preview must not write a client config")
            capture("Clients-\(appearance)-matching-preview")

            try Data().write(to: root.appendingPathComponent("slow-server-status"))
            refreshPreview.click()
            XCTAssertTrue(app.buttons["Refreshing servers…"].waitForExistence(timeout: 10))
            XCTAssertFalse(confirm.isEnabled)
            XCTAssertFalse(refreshPreview.isEnabled)
            capture("Clients-\(appearance)-refreshing-preview")
            try FileManager.default.removeItem(at: root.appendingPathComponent("slow-server-status"))
            XCTAssertTrue(app.buttons["Refresh servers"].waitForExistence(timeout: 10))
            XCTAssertEqual(try Data(contentsOf: config), original, "Refreshing a preview must not write")

            endpoint.click()
            app.menuItems["Qwen-second :8767"].click()
            XCTAssertFalse(confirm.isEnabled)
            XCTAssertEqual(reviewedModel.value as? String, "org/Qwen-first")
            XCTAssertEqual(reviewedEndpoint.value as? String, "http://127.0.0.1:8766/v1")
            XCTAssertTrue(text(containing: "Endpoint changed. Preview client wiring again.").exists)
            capture("Clients-\(appearance)-changed-endpoint")
            app.buttons["Preview client wiring"].click()
            XCTAssertTrue(app.buttons["Refresh preview"].waitForExistence(timeout: 10))
            XCTAssertEqual(reviewedModel.value as? String, "org/Qwen-second")
            XCTAssertEqual(reviewedEndpoint.value as? String, "http://127.0.0.1:8767/v1")
            resizeWindow(width: 740, height: 680)
            for _ in 0..<6 where !confirm.isHittable {
                app.scrollViews.allElementsBoundByIndex.last?.scroll(byDeltaX: 0, deltaY: -220)
            }
            XCTAssertTrue(confirm.isHittable)
            capture("Clients-\(appearance)-matching-preview-narrow")

            confirm.click()
            XCTAssertTrue(text(containing: "Wired 1 client to org/Qwen-second.").waitForExistence(timeout: 10))
            let landed = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
            let provider = landed?["provider"] as? [String: Any]
            let local = provider?["mlx-local"] as? [String: Any]
            XCTAssertEqual((local?["options"] as? [String: Any])?["baseURL"] as? String, "http://127.0.0.1:8767/v1")
            XCTAssertEqual(landed?["theme"] as? String, "dark")
            XCTAssertFalse(confirm.exists)
            capture("Clients-\(appearance)-confirmed")
            app.buttons["Roll back last wiring"].click()
            XCTAssertEqual(try Data(contentsOf: config), original)

            app.buttons["Preview client wiring"].click()
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            let externalEdit = Data("{\"theme\":\"light\"}".utf8)
            try externalEdit.write(to: config)
            confirm.click()
            XCTAssertTrue(text(containing: "config file changed after the preview").waitForExistence(timeout: 10))
            XCTAssertEqual(try Data(contentsOf: config), externalEdit, "Failed confirmation must retain external edits")
            capture("Clients-\(appearance)-confirmation-file-drift")

            app.buttons["Preview client wiring"].click()
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            try Data().write(to: root.appendingPathComponent("fail-server-status"))
            app.buttons["Refresh servers"].click()
            XCTAssertTrue(text(containing: "Server status unavailable.").waitForExistence(timeout: 10))
            XCTAssertFalse(confirm.isEnabled)
            XCTAssertEqual(reviewedModel.value as? String, "org/Qwen-second")
            XCTAssertEqual(try Data(contentsOf: config), externalEdit)
            capture("Clients-\(appearance)-status-unavailable")
            try FileManager.default.removeItem(at: root.appendingPathComponent("fail-server-status"))
            app.terminate()
        }
    }

    func testClientWiringOutcomesAndRecovery() throws {
        let opencode = root.appendingPathComponent(".config/opencode/opencode.jsonc")
        let zed = root.appendingPathComponent(".config/zed/settings.json")
        let original = Data("{\"theme\":\"dark\"}".utf8)
        let externalEdit = Data("{\"theme\":\"light\"}".utf8)
        try FileManager.default.createDirectory(at: opencode.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [["repo": "org/Qwen-first", "runtime": "mlx_lm",
            "port": 8766, "pid": 123, "state": "running"]]).write(to: root.appendingPathComponent("servers.json"))
        let isBefore = ProcessInfo.processInfo.environment["MLX_WORKBENCH_CAPTURE_STAGE"] == "before"
        for appearance in ["Light", "Dark"] {
            try? FileManager.default.removeItem(at: zed.deletingLastPathComponent())
            try original.write(to: opencode)
            launch(appearance: appearance, isolatedHome: true)
            select("Clients")
            let endpoint = isBefore ? app.popUpButtons.firstMatch : app.popUpButtons["client-wiring-endpoint"]
            XCTAssertTrue(endpoint.waitForExistence(timeout: 10))
            endpoint.click()
            app.menuItems["Qwen-first :8766"].click()
            app.buttons["Preview client wiring"].click()
            let confirm = app.buttons["Confirm client wiring"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            try externalEdit.write(to: opencode)
            confirm.click()
            XCTAssertTrue(text(containing: "config file changed after the preview").waitForExistence(timeout: 10))
            XCTAssertEqual(try Data(contentsOf: opencode), externalEdit)
            let result = app.staticTexts["client-wiring-result"]
            if !isBefore {
                XCTAssertEqual(result.value as? String ?? result.label, "No clients were wired. 1 client failed.")
                XCTAssertFalse(app.buttons["Roll back last wiring"].exists)
                XCTAssertFalse(app.buttons["Measure this workflow…"].exists)
                let failures = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "config file changed after the preview", "config file changed after the preview"))
                XCTAssertEqual(failures.count, 1)
                XCTAssertEqual(failures.firstMatch.value as? String ?? failures.firstMatch.label, "opencode: the config file changed after the preview; preview again.")
            }
            capture("Clients-\(appearance)-zero-wired")
            resizeWindow(width: 740, height: 680)
            XCTAssertEqual(app.windows.firstMatch.frame.width, 740, accuracy: 2)
            XCTAssertEqual(app.windows.firstMatch.frame.height, 680, accuracy: 2)
            capture("Clients-\(appearance)-zero-wired-narrow")
            resizeWindow(width: 1024, height: 680)

            try FileManager.default.createDirectory(at: zed.deletingLastPathComponent(), withIntermediateDirectories: true)
            let zedOriginal = Data("{\"vim_mode\":true}".utf8)
            try zedOriginal.write(to: zed)
            app.buttons["Preview client wiring"].click()
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            if !isBefore { XCTAssertFalse(result.exists) }
            try original.write(to: opencode)
            confirm.click()
            XCTAssertTrue(text(containing: "config file changed after the preview").waitForExistence(timeout: 10))
            XCTAssertEqual(try Data(contentsOf: opencode), original)
            let zedConfig = try JSONSerialization.jsonObject(with: Data(contentsOf: zed)) as? [String: Any]
            XCTAssertNotNil(zedConfig?["language_models"])
            if !isBefore {
                XCTAssertEqual(result.value as? String ?? result.label, "Wired 1 of 2 clients to org/Qwen-first. 1 client failed.")
                XCTAssertTrue(app.buttons["Measure this workflow…"].exists)
                XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "config file changed after the preview", "config file changed after the preview")).count, 1)
            }
            capture("Clients-\(appearance)-partial-wiring")
            app.buttons["Roll back last wiring"].click()
            XCTAssertEqual(try Data(contentsOf: zed), zedOriginal)
            XCTAssertEqual(try Data(contentsOf: opencode), original)
            if !isBefore {
                XCTAssertFalse(result.exists)
                XCTAssertFalse(app.buttons["Measure this workflow…"].exists)
            }
            capture("Clients-\(appearance)-after-rollback")

            app.buttons["Preview client wiring"].click()
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            confirm.click()
            let success = isBefore ? "Wired 2 client(s) to org/Qwen-first." : "Wired 2 clients to org/Qwen-first."
            XCTAssertTrue(text(containing: success).waitForExistence(timeout: 10))
            for config in [opencode, zed] {
                XCTAssertTrue(try String(contentsOf: config).contains("127.0.0.1:8766/v1"))
            }
            capture("Clients-\(appearance)-full-wiring")
            app.buttons["Preview client wiring"].click()
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            if !isBefore {
                XCTAssertFalse(result.exists)
                XCTAssertFalse(app.buttons["Measure this workflow…"].exists)
            }
            capture("Clients-\(appearance)-new-preview")
            app.terminate()
        }
    }

    func testManualWiringRequiresCurrentReview() throws {
        let before = ProcessInfo.processInfo.environment["MLX_WORKBENCH_CAPTURE_STAGE"] == "before"
        let config = root.appendingPathComponent("manual-runtime-configuration-with-a-long-filename.json")
        let original = Data("{}".utf8)
        for appearance in ["Light", "Dark"] {
            for flag in ["fail-wire-preview", "fail-wire-apply", "false-wire-apply", "missing-wire-hash"] {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(flag))
            }
            try original.write(to: config)
            let installed = root.appendingPathComponent(".config/opencode/opencode.jsonc")
            try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: installed)
            let servers: [[String: Any]] = [["repo": "fixture/ReviewedModel", "runtime": "mlx_lm", "port": 8766, "pid": 123, "state": "running"]]
            try JSONSerialization.data(withJSONObject: servers).write(to: root.appendingPathComponent("servers.json"))
            launch(appearance: appearance, isolatedHome: true)
            select("Clients")
            resizeWindow(width: 1024, height: 680)
            XCTAssertEqual(app.windows.firstMatch.frame.width, 1024, accuracy: 2)
            XCTAssertEqual(app.windows.firstMatch.frame.height, 680, accuracy: 2)
            var scroll: XCUIElement { app.scrollViews.containing(.disclosureTriangle, identifier: "Advanced: manual single-file wiring").firstMatch }
            var advanced: XCUIElement { app.disclosureTriangles["Advanced: manual single-file wiring"] }
            for _ in 0..<6 where !advanced.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -300) }
            XCTAssertTrue(advanced.isHittable)
            capture("ManualWire-\(appearance)-collapsed-standard")
            // The native disclosure's accessibility frame includes the scroll
            // page inset. Only its leading arrow toggles the section on macOS.
            let window = app.windows.firstMatch
            let frame = advanced.frame.intersection(scroll.frame)
            XCTAssertFalse(frame.isNull)
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: frame.minX + 24 + frame.height / 4 - window.frame.minX,
                dy: frame.midY - window.frame.minY
            )).click()
            XCTAssertEqual(advanced.value as? Int, 1)
            var model: XCUIElement { app.textFields[before ? "Model repo id" : "manual-wire-model"] }
            var path: XCUIElement { app.textFields[before ? "Config file path" : "manual-wire-path"] }
            func reveal(_ element: XCUIElement) {
                XCTAssertTrue(element.waitForExistence(timeout: 10))
                for _ in 0..<6 where !element.isHittable {
                    let above = element.frame.midY < scroll.frame.minY
                    scroll.scroll(byDeltaX: 0, deltaY: above ? 300 : -300)
                }
                XCTAssertTrue(element.isHittable)
            }
            reveal(model)
            replace(model, with: "fixture/ReviewedModel")
            reveal(path)
            replace(path, with: config.path)
            capture("ManualWire-\(appearance)-unreviewed-standard")
            var preview: XCUIElement { before ? app.buttons["Preview Wire"] : app.buttons["manual-wire-preview"] }
            var confirm: XCUIElement { before ? app.buttons["Apply Wiring"] : app.buttons["manual-wire-confirm"] }
            reveal(preview)
            preview.click()
            if !before {
                XCTAssertTrue(app.descendants(matching: .any)["manual-wire-progress"].waitForExistence(timeout: 5))
                XCTAssertFalse(preview.isEnabled)
                capture("ManualWire-\(appearance)-previewing")
            }
            reveal(confirm)
            XCTAssertTrue(confirm.isEnabled)
            XCTAssertEqual(try Data(contentsOf: config), original)
            capture("ManualWire-\(appearance)-reviewed-standard")
            resizeWindow(width: 740, height: 680)
            XCTAssertEqual(app.windows.firstMatch.frame.width, 740, accuracy: 2)
            XCTAssertEqual(app.windows.firstMatch.frame.height, 680, accuracy: 2)
            reveal(confirm)
            capture("ManualWire-\(appearance)-reviewed-scrolled-narrow")
            if before { app.terminate(); continue }

            let capturedPath = app.staticTexts["manual-wire-reviewed-path"]
            XCTAssertTrue(capturedPath.exists)
            reveal(model)
            replace(model, with: "fixture/ChangedModel")
            XCTAssertTrue(!confirm.exists || !confirm.isEnabled)
            capture("ManualWire-\(appearance)-edited-review-invalidated")
            reveal(preview)
            preview.click()
            reveal(confirm)
            XCTAssertTrue(confirm.isEnabled)
            try Data().write(to: root.appendingPathComponent("false-wire-apply"))
            confirm.click()
            XCTAssertTrue(app.descendants(matching: .any)["manual-wire-progress"].waitForExistence(timeout: 5))
            XCTAssertFalse(preview.isEnabled)
            capture("ManualWire-\(appearance)-applying")
            XCTAssertTrue(text(containing: "Wiring was not applied.").waitForExistence(timeout: 15))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: preview)
            waitForExpectations(timeout: 15)
            XCTAssertEqual(try Data(contentsOf: config), original)
            XCTAssertFalse(text(containing: "Wiring applied.").exists)
            XCTAssertTrue(!confirm.exists || !confirm.isEnabled)
            capture("ManualWire-\(appearance)-not-applied")
            try FileManager.default.removeItem(at: root.appendingPathComponent("false-wire-apply"))
            reveal(preview)
            preview.click()
            reveal(confirm)
            confirm.click()
            XCTAssertTrue(text(containing: "Wiring applied.").waitForExistence(timeout: 15))
            XCTAssertTrue(!confirm.exists || !confirm.isEnabled)
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: String]
            XCTAssertEqual(saved["model"], "fixture/ChangedModel")
            XCTAssertEqual(saved["target"], "mlx_lm")
            let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl")).split(separator: "\n")
                .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String] }
                .filter { $0.prefix(2) == ["wire", "apply"] && $0.contains("--confirm") }
            XCTAssertEqual(calls.count, appearance == "Light" ? 2 : 4)
            XCTAssertTrue(calls.allSatisfy { $0[2] == "fixture/ChangedModel" && $0.contains(config.path) })
            capture("ManualWire-\(appearance)-applied")

            try Data().write(to: root.appendingPathComponent("fail-wire-preview"))
            reveal(preview)
            preview.click()
            XCTAssertTrue(text(containing: "Fixture manual wiring failed").waitForExistence(timeout: 15))
            capture("ManualWire-\(appearance)-preview-error")
            app.terminate()
        }
    }

    func testAdoptionHandoffAndRecovery() throws {
        let before = ProcessInfo.processInfo.environment["MLX_WORKBENCH_CAPTURE_STAGE"] == "before"
        let repository = "mlx-community/Qwen-Coding-Long-Repository-Name-For-Local-Adoption-4bit"
        for appearance in ["Light", "Dark"] {
            for flag in ["fail-adopt-start", "fail-adopt-status", "adopt-no-recommendation", "adopt-unknown"] {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(flag))
            }
            launch(appearance: appearance, isolatedHome: true)
            select("Adopt")
            resizeWindow(width: 1024, height: 680)
            XCTAssertEqual(app.windows.firstMatch.frame.width, 1024, accuracy: 2)
            XCTAssertEqual(app.windows.firstMatch.frame.height, 680, accuracy: 2)
            capture("Adopt-\(appearance)-idle-standard")
            if before { app.terminate(); continue }

            let callsURL = root.appendingPathComponent("calls.jsonl")
            func calls() throws -> [[String]] {
                guard FileManager.default.fileExists(atPath: callsURL.path) else { return [] }
                return try String(contentsOf: callsURL).split(separator: "\n").map {
                    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String]
                }.filter { $0.first == "adopt" }
            }

            var picker: XCUIElement { app.popUpButtons["adopt-role"] }
            func chooseRole(_ title: String) {
                XCTAssertTrue(picker.waitForExistence(timeout: 10))
                XCTAssertTrue(picker.isEnabled)
                let frame = picker.frame
                XCTAssertTrue(frame.midX.isFinite && frame.midY.isFinite && frame.width > 0 && frame.height > 0)
                let control = XCTAttachment(string: "Role picker: frame=\(frame), enabled=\(picker.isEnabled), hittable=\(picker.isHittable)")
                control.name = "Adopt-\(appearance)-role-\(title)-bounds"
                control.lifetime = .keepAlways
                add(control)
                let window = app.windows.firstMatch
                window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                    dx: frame.midX - window.frame.minX, dy: frame.midY - window.frame.minY
                )).click()
                let item = picker.menuItems[title]
                XCTAssertTrue(item.waitForExistence(timeout: 5))
                item.click()
                XCTAssertEqual(picker.value as? String, title)
            }
            chooseRole("Coding")
            let fast = app.checkBoxes["Fast"]
            fast.click()
            XCTAssertEqual(fast.value as? Int, 1)
            app.checkBoxes["Offline"].click()
            var start: XCUIElement { app.buttons["adopt-start"] }
            var refresh: XCUIElement { app.buttons["adopt-refresh"] }
            let callsBeforeHiddenReturn = try calls()
            select("Library")
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            select("Adopt")
            XCTAssertEqual(try calls(), callsBeforeHiddenReturn, "A hidden Adopt route must not handle Return")
            start.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            XCTAssertTrue(app.descendants(matching: .any)["adopt-progress"].waitForExistence(timeout: 5))
            XCTAssertFalse(start.isEnabled)
            XCTAssertFalse(picker.isEnabled)
            capture("Adopt-\(appearance)-starting")
            select("Library")
            select("Adopt")
            XCTAssertTrue(text(containing: repository).waitForExistence(timeout: 15))
            capture("Adopt-\(appearance)-recommendation-standard")
            XCTAssertTrue(refresh.isEnabled)

            let firstStart = try XCTUnwrap(calls().last { $0.prefix(2) == ["adopt", "start"] })
            XCTAssertTrue(firstStart.contains("--fast"))
            XCTAssertTrue(firstStart.contains("--offline"))
            let stateIndex = try XCTUnwrap(firstStart.firstIndex(of: "--state")) + 1
            let firstPath = firstStart[stateIndex]
            XCTAssertTrue(firstPath.hasPrefix(root.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: firstPath))

            chooseRole("Reasoning")
            XCTAssertTrue(text(containing: repository).exists, "Draft edits retain the recorded recommendation")
            let recordedRole = app.staticTexts["adopt-requested-role"]
            XCTAssertEqual(recordedRole.value as? String ?? recordedRole.label, "Coding")
            refresh.click()
            XCTAssertTrue(app.descendants(matching: .any)["adopt-progress"].waitForExistence(timeout: 5))
            XCTAssertFalse(refresh.isEnabled)
            capture("Adopt-\(appearance)-refreshing")
            XCTAssertTrue(refresh.waitForExistence(timeout: 10))
            XCTAssertTrue(text(containing: repository).waitForExistence(timeout: 10))
            let predicate = NSPredicate(format: "enabled == true")
            expectation(for: predicate, evaluatedWith: refresh)
            waitForExpectations(timeout: 10)
            let statusCall = try XCTUnwrap(calls().last { $0.prefix(2) == ["adopt", "status"] })
            XCTAssertEqual(statusCall[try XCTUnwrap(statusCall.firstIndex(of: "--state")) + 1], firstPath)

            try Data().write(to: root.appendingPathComponent("fail-adopt-status"))
            refresh.click()
            XCTAssertTrue(text(containing: "Fixture adoption status failed").waitForExistence(timeout: 15))
            XCTAssertTrue(app.descendants(matching: .any)["adopt-last-known"].exists)
            XCTAssertTrue(text(containing: repository).exists)
            capture("Adopt-\(appearance)-refresh-error")
            resizeWindow(width: 740, height: 680)
            XCTAssertEqual(app.windows.firstMatch.frame.width, 740, accuracy: 2)
            XCTAssertEqual(app.windows.firstMatch.frame.height, 680, accuracy: 2)
            XCTAssertTrue(start.isHittable)
            XCTAssertTrue(picker.isHittable)
            capture("Adopt-\(appearance)-recommendation-narrow")
            var outcome: XCUIElement { app.scrollViews.containing(.staticText, identifier: "adopt-model").firstMatch }
            var details: XCUIElement { app.disclosureTriangles["Workflow details"] }
            func toggleDetails(expectedValue: Int) {
                let frame = details.frame.intersection(outcome.frame)
                XCTAssertFalse(frame.isNull)
                XCTAssertTrue(details.isHittable)
                let window = app.windows.firstMatch
                window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                    dx: frame.minX + frame.height / 4 - window.frame.minX,
                    dy: frame.midY - window.frame.minY
                )).click()
                XCTAssertEqual(details.value as? Int, expectedValue)
            }
            outcome.scroll(byDeltaX: 0, deltaY: -outcome.frame.height)
            toggleDetails(expectedValue: 1)
            outcome.scroll(byDeltaX: 0, deltaY: -outcome.frame.height)
            XCTAssertTrue(app.staticTexts["adopt-state-path"].waitForExistence(timeout: 5))
            capture("Adopt-\(appearance)-details-scrolled")
            toggleDetails(expectedValue: 0)
            outcome.scroll(byDeltaX: 0, deltaY: outcome.frame.height)
            try FileManager.default.removeItem(at: root.appendingPathComponent("fail-adopt-status"))
            resizeWindow(width: 1024, height: 680)

            try Data().write(to: root.appendingPathComponent("adopt-no-recommendation"))
            start.click()
            XCTAssertTrue(text(containing: "No recommendation reported").waitForExistence(timeout: 15))
            XCTAssertFalse(text(containing: "shortlisted-only/model").exists)
            let secondStart = try XCTUnwrap(calls().last { $0.prefix(2) == ["adopt", "start"] })
            let secondPath = secondStart[try XCTUnwrap(secondStart.firstIndex(of: "--state")) + 1]
            XCTAssertNotEqual(firstPath, secondPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: firstPath))
            capture("Adopt-\(appearance)-no-recommendation")

            try Data().write(to: root.appendingPathComponent("fail-adopt-start"))
            start.click()
            XCTAssertTrue(text(containing: "Fixture adoption failed").waitForExistence(timeout: 15))
            XCTAssertTrue(start.isEnabled)
            capture("Adopt-\(appearance)-start-error")
            try FileManager.default.removeItem(at: root.appendingPathComponent("fail-adopt-start"))
            try Data().write(to: root.appendingPathComponent("adopt-unknown"))
            start.click()
            XCTAssertTrue(text(containing: "No recommendation reported").waitForExistence(timeout: 15))
            XCTAssertFalse(text(containing: repository).exists)
            capture("Adopt-\(appearance)-missing-fields")
            app.terminate()
        }
    }

    func testRouteCaptures() throws {
        // XCUIDevice changes only the disposable VM's appearance.
        for appearance in [ProcessInfo.processInfo.environment["MLX_WORKBENCH_CAPTURE_APPEARANCE"] ?? "System"] {
            launch(appearance: appearance)
            for route in routes {
                select(route)
                assertPageContent(route)
                capture("\(appearance)-standard-\(route)")
            }
            resizeWindow(width: 740, height: 560)
            for route in routes {
                select(route)
                assertPageContent(route)
                capture("\(appearance)-minimum-\(route)")
            }
            app.terminate()
        }
    }

    func testOverviewPanelsRemainInsideWindowAndDoNotOverlap() {
        launch(appearance: ProcessInfo.processInfo.environment["MLX_WORKBENCH_CAPTURE_APPEARANCE"] ?? "Light")
        for narrow in [false, true] {
            if narrow { resizeWindow(width: 740, height: 560) }
            select("Overview")
            let budget = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", "Model budget")).firstMatch
            let title = app.staticTexts["Review the model library"].firstMatch
            let action = app.buttons["Open Library"].firstMatch
            XCTAssertTrue(budget.waitForExistence(timeout: 10))
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            let bounds = app.windows.firstMatch.frame
            for element in [budget, title, action, app.buttons["Library"].firstMatch] {
                XCTAssertGreaterThanOrEqual(element.frame.minX, bounds.minX - 1)
                XCTAssertLessThanOrEqual(element.frame.maxX, bounds.maxX + 1)
            }
            XCTAssertTrue(action.isHittable)
            XCTAssertTrue(app.buttons["Library"].firstMatch.isHittable)
            XCTAssertFalse(budget.frame.intersects(title.frame))
            XCTAssertFalse(budget.frame.intersects(action.frame))
            capture(narrow ? "Overview-window-boundary-narrow" : "Overview-window-boundary-standard")
        }
    }
}

/// Dogfoods the first-launch setup assistant with real clicks: sheet appears,
/// every step is navigable, skip and finish behave, and completion persists
/// across relaunch. Runs with an isolated config path; the launch argument
/// forces first-launch state without touching real user defaults.
final class SetupAssistantUITests: XCTestCase {
    private var app: XCUIApplication!
    private var configPath: String!

    override func setUpWithError() throws {
        try NativeUITestEnvironment.requireIsolatedAquaSession()
        continueAfterFailure = false
        configPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mlx-workbench-uitest-\(UUID().uuidString)")
            .appendingPathComponent("config.json")
            .path
    }

    private func launch(firstRun: Bool = true) {
        app = XCUIApplication()
        app.launchEnvironment["MLX_WORKBENCH_CONFIG"] = configPath
        if firstRun {
            app.launchArguments = ["-mlx-workbench.setupCompleted.v1", "NO"]
        }
        app.launch()
        app.activate()
        _ = app.windows.firstMatch.waitForExistence(timeout: 30)
    }

    /// Attach a screenshot to the test result for dogfood evidence.
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFirstLaunchWalksEveryStepAndPersistsCompletion() throws {
        launch(firstRun: true)

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "Setup assistant did not appear on first launch")
        XCTAssertTrue(sheet.staticTexts["Connect mlx-agent"].exists)
        capture("01-step-agent")

        // Every middle step is reachable and navigable both ways.
        sheet.buttons["Continue"].click()
        XCTAssertTrue(sheet.staticTexts["Python runtime"].waitForExistence(timeout: 15))
        capture("02-step-runtime")
        sheet.buttons["Back"].click()
        XCTAssertTrue(sheet.staticTexts["Connect mlx-agent"].waitForExistence(timeout: 15))
        sheet.buttons["Continue"].click()
        sheet.buttons["Continue"].click()
        XCTAssertTrue(sheet.staticTexts["Choose model roots"].waitForExistence(timeout: 15))
        capture("03-step-roots")
        sheet.buttons["Continue"].click()
        XCTAssertTrue(sheet.staticTexts["Ready"].waitForExistence(timeout: 15))
        capture("04-step-done")

        sheet.buttons["Scan my library"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 15), "Assistant did not dismiss after finishing")
        capture("05-after-finish")

        // Completion persists: a relaunch without the first-run override
        // must not re-present the assistant.
        app.terminate()
        launch(firstRun: false)
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 15),
                      "Assistant re-appeared after completion")
    }

    func testSkipDismissesWithoutPersisting() throws {
        launch(firstRun: true)

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30))
        capture("06-skip-before")
        sheet.buttons["Skip setup"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 15))

        app.terminate()
        launch(firstRun: true)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 30),
                      "Assistant did not return after being skipped")
        capture("07-skip-returned")
    }

    func testLibraryFamilyContextMenuReviewsDeletionWithoutDeletingOnCancel() throws {
        let root = URL(fileURLWithPath: configPath).deletingLastPathComponent()
        let model = root.appendingPathComponent("models/Qwen3-4B-4bit")
        let script = root.appendingPathComponent("agent/scripts/mlx-agent")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"quantization\":{\"bits\":4}}".utf8).write(to: model.appendingPathComponent("config.json"))
        try Data("fixture weights".utf8).write(to: model.appendingPathComponent("model.safetensors"))
        let scan: [String: Any] = ["models": [], "outputs": [["path": model.path, "name": "Qwen3-4B-4bit", "model_key": "qwen3-4b", "quantization": ["bits": 4]]], "pending": [], "duplicates": [], "totals": ["gguf": 0, "pending": 0, "converted": 1, "unreadable": 0, "bytes": 14, "reclaimable_bytes": 0]]
        try JSONSerialization.data(withJSONObject: scan).write(to: root.appendingPathComponent("scan.json"))
        let python = """
        import json, pathlib, sys
        root = pathlib.Path(__file__).resolve().parents[2]
        if sys.argv[1:3] == ['convert', 'scan']:
            data = json.loads((root / 'scan.json').read_text())
        else:
            data = {'servers': [], 'jobs': [], 'changes': []}
        print(json.dumps({'status': 'ok', 'data': data}))
        """
        try python.write(to: script, atomically: true, encoding: .utf8)
        let config: [String: Any] = ["mlx_agent_path": root.appendingPathComponent("agent").path, "mlx_roots": [model.deletingLastPathComponent().path], "gguf_roots": [], "output_dir": root.appendingPathComponent("output").path, "verification_enabled": false, "watch_enabled": false]
        try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: configPath))
        defer { app?.terminate(); try? FileManager.default.removeItem(at: root) }
        app = XCUIApplication()
        app.launchEnvironment["MLX_WORKBENCH_CONFIG"] = configPath
        app.launchEnvironment["CFFIXED_USER_HOME"] = root.path
        app.launchEnvironment["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        app.launchEnvironment["MLX_WORKBENCH_PYTHON"] = "/usr/bin/python3"
        app.launchArguments = ["-mlx-workbench.setupCompleted.v1", "YES", "-library.groupMode", "family"]
        app.launch(); app.activate()
        let library = app.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 45))
        library.click()
        let family = app.staticTexts["Qwen3"].firstMatch
        XCTAssertTrue(family.waitForExistence(timeout: 45))
        XCTAssertTrue(app.buttons["Settings"].exists)
        XCTAssertTrue(app.buttons["Discover"].exists)
        capture("08-library-visible-family-and-sidebar")
        family.click()
        capture("08b-library-inspector-after-selection")
        family.rightClick()
        let delete = app.menuItems["Delete…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        capture("09-library-delete-context-menu")
        delete.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30))
        XCTAssertTrue(sheet.staticTexts[model.path].exists)
        XCTAssertTrue(sheet.buttons["Move to Trash"].exists)
        capture("10-library-delete-review")
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))
    }
}
