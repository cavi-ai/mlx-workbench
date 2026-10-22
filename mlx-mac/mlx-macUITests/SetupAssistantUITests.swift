import AppKit
import CryptoKit
import Darwin
import XCTest

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

    private func launch(firstRun: Bool = true, python: String? = nil, home: URL? = nil, environment: [String: String] = [:]) {
        app = XCUIApplication()
        app.launchEnvironment.merge(environment) { _, supplied in supplied }
        app.launchEnvironment["MLX_WORKBENCH_CONFIG"] = configPath
        if let python { app.launchEnvironment["MLX_WORKBENCH_PYTHON"] = python }
        if let home { app.launchEnvironment["CFFIXED_USER_HOME"] = home.path }
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

    func testBundledEnginePreparationConfirmsAndPersistsPackagedSources() throws {
        let configURL = URL(fileURLWithPath: configPath)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = configURL.deletingLastPathComponent().appendingPathComponent("existing-agent").path
        try JSONSerialization.data(withJSONObject: ["mlx_agent_path": original, "bundle_test_marker": true]).write(to: configURL)
        let home = configURL.deletingLastPathComponent().appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        launch(python: "/usr/bin/false", home: home)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        let use = sheet.buttons["setup-bundled-runtime"]
        guard let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_RUNTIME_PAYLOAD"] else {
            XCTAssertFalse(use.exists, "An ordinary development build has no bundled runtime")
            return
        }
        let payload = URL(fileURLWithPath: path)
        let metadata = try Data(contentsOf: payload.appendingPathComponent("manifest.json"))
        let identity = SHA256.hash(data: metadata).map { String(format: "%02x", $0) }.joined()
        let root = home
            .appendingPathComponent("Library/Application Support/mlx-workbench/runtimes/" + identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(use.waitForExistence(timeout: 15))
        use.click()
        app.sheets.buttons["Cancel"].firstMatch.click()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Cancelling confirmation must not copy sources")
        use.click()
        app.sheets.buttons["Prepare engine"].firstMatch.click()
        XCTAssertTrue(sheet.staticTexts["setup-bundled-runtime-prepared"].waitForExistence(timeout: 30))
        let saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        XCTAssertEqual(saved["mlx_agent_path"] as? String, root.appendingPathComponent("vendor/mlx-agent").path)
        XCTAssertEqual(saved["bundle_test_marker"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), metadata)
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        for file in try XCTUnwrap(manifest["files"] as? [[String: Any]]) {
            let name = try XCTUnwrap(file["path"] as? String)
            let digest = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(name)))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, file["sha256"] as? String, name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".venv").path))
        capture("Bundled-engine-prepared")
        sheet.buttons["Continue"].click()
        XCTAssertTrue(sheet.buttons["Install Runtime…"].waitForExistence(timeout: 15))
        capture("Bundled-engine-dependencies-remain-explicit")
    }

    func testRuntimePrerequisitesAreCheckedWithoutStartingInstallation() throws {
        // An unavailable developer directory exercises recovery without changing macOS tools.
        launch(python: "/usr/bin/false", environment: ["DEVELOPER_DIR": "/nonexistent/workbench-ui-check"])
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30))
        sheet.buttons["Continue"].click()
        let status = sheet.staticTexts["runtime-prerequisites-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let scroll = sheet.scrollViews.firstMatch
        func reveal(_ element: XCUIElement) {
            XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription)
            for _ in 0..<10 where !element.isHittable {
                scroll.scroll(byDeltaX: 0, deltaY: element.frame.midY < scroll.frame.minY ? 180 : -180)
            }
            XCTAssertTrue(element.isHittable, app.debugDescription)
        }
        let install = sheet.buttons["runtime-install-start"]
        XCTAssertTrue(install.exists)
        XCTAssertEqual(install.isEnabled, status.label == "Prerequisites found")
        let recheck = sheet.buttons["runtime-prerequisites-recheck"]
        XCTAssertTrue(recheck.isEnabled)
        reveal(recheck)
        recheck.click()
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        XCTAssertFalse(sheet.buttons["runtime-install-cancel"].exists)
        let copy = sheet.buttons["runtime-prerequisite-copy-xcode-select --install"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10), app.debugDescription)
        reveal(copy)
        let previousClipboard = NSPasteboard.general.string(forType: .string)
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "xcode-select --install")
        let copied = expectation(for: NSPredicate(format: "label == %@", "Copied"), evaluatedWith: copy)
        wait(for: [copied], timeout: 5)
        let guide = sheet.descendants(matching: .any)["runtime-prerequisite-guide-uv"].firstMatch
        XCTAssertTrue(guide.exists, app.debugDescription)
        XCTAssertFalse(install.isEnabled)
        XCTAssertFalse(sheet.buttons["runtime-install-cancel"].exists)
        capture("Runtime-prerequisite-copy-and-guide")
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 738, dy: 610)))
        reveal(copy)
        reveal(guide)
        reveal(recheck)
        let bounds = sheet.frame
        XCTAssertGreaterThanOrEqual(bounds.minX, window.frame.minX)
        XCTAssertGreaterThanOrEqual(bounds.minY, window.frame.minY)
        XCTAssertLessThanOrEqual(bounds.maxX, window.frame.maxX)
        XCTAssertLessThanOrEqual(bounds.maxY, window.frame.maxY)
        XCTAssertTrue(sheet.buttons["Continue"].isHittable)
        capture("Runtime-prerequisite-guide-minimum")
        NSPasteboard.general.clearContents()
        if let previousClipboard { NSPasteboard.general.setString(previousClipboard, forType: .string) }
    }

    func testPackagedRuntimeInstallsFromCleanSetup() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let uvPath = environment["MLX_WORKBENCH_RUNTIME_INSTALL_UV"],
              let uvDigest = environment["MLX_WORKBENCH_RUNTIME_INSTALL_UV_SHA256"],
              let payloadPath = environment["MLX_WORKBENCH_RUNTIME_PAYLOAD"] else {
            throw XCTSkip("Requires the explicit packaged-runtime installation runner option.")
        }
        executionTimeAllowance = 2400
        let configURL = URL(fileURLWithPath: configPath)
        let home = configURL.deletingLastPathComponent().appendingPathComponent("home")
        let fm = FileManager.default
        let tool = URL(fileURLWithPath: uvPath)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let uvData = try Data(contentsOf: URL(fileURLWithPath: uvPath))
        XCTAssertEqual(SHA256.hash(data: uvData).map { String(format: "%02x", $0) }.joined(), uvDigest)
        let metadata = try Data(contentsOf: URL(fileURLWithPath: payloadPath).appendingPathComponent("manifest.json"))
        let identity = SHA256.hash(data: metadata).map { String(format: "%02x", $0) }.joined()
        let root = home.appendingPathComponent("Library/Application Support/mlx-workbench/runtimes/" + identity)
        let cache = home.appendingPathComponent("cache/uv")
        let pythonInstall = home.appendingPathComponent("python")
        XCTAssertFalse(fm.fileExists(atPath: root.path))
        XCTAssertFalse(fm.fileExists(atPath: cache.path))
        XCTAssertFalse(fm.fileExists(atPath: pythonInstall.path))
        try JSONSerialization.data(withJSONObject: ["mlx_agent_path": "", "gguf_roots": [], "mlx_roots": [],
            "output_dir": home.appendingPathComponent("outputs").path,
            "quarantine_dir": home.appendingPathComponent("quarantine").path]).write(to: configURL)
        launch(home: home, environment: [
            "PATH": tool.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin", "UV_CACHE_DIR": cache.path,
            "UV_PYTHON_INSTALL_DIR": pythonInstall.path, "UV_NO_CONFIG": "1",
            "PIP_CONFIG_FILE": "/dev/null", "PIP_CACHE_DIR": home.appendingPathComponent("cache/pip").path,
            "HF_HOME": home.appendingPathComponent("cache/huggingface").path, "HF_HUB_OFFLINE": "1",
        ])
        if let expectedApp = environment["MLX_WORKBENCH_RUNTIME_INSTALL_APP"] {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cavi.mlxworkbench")
            XCTAssertEqual(running.count, 1, "Release acceptance must run only the installed candidate")
            let candidate = try XCTUnwrap(running.first)
            XCTAssertEqual(candidate.bundleURL?.resolvingSymlinksInPath().path,
                           URL(fileURLWithPath: expectedApp).resolvingSymlinksInPath().path)
            let executable = try XCTUnwrap(candidate.executableURL)
            let digest = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, environment["MLX_WORKBENCH_RUNTIME_INSTALL_APP_SHA256"])
            let receipt = try JSONSerialization.data(withJSONObject: ["app_path": expectedApp,
                "pid": candidate.processIdentifier, "binary_sha256": digest], options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: receipt, uniformTypeIdentifier: "public.json")
            attachment.name = "Packaged-runtime-running-app.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30))
        XCTAssertTrue(sheet.buttons["setup-bundled-runtime"].waitForExistence(timeout: 30))
        sheet.buttons["setup-bundled-runtime"].click()
        app.sheets.buttons["Prepare engine"].firstMatch.click()
        XCTAssertTrue(sheet.staticTexts["setup-bundled-runtime-prepared"].waitForExistence(timeout: 60))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), metadata)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(".venv").path))
        sheet.buttons["Continue"].click()
        XCTAssertTrue(sheet.staticTexts["runtime-prerequisites-status"].waitForExistence(timeout: 60))
        capture("Packaged-runtime-prerequisites")
        let prerequisiteDetails = XCTAttachment(string: sheet.debugDescription)
        prerequisiteDetails.name = "Packaged-runtime-prerequisites.txt"
        prerequisiteDetails.lifetime = .keepAlways
        add(prerequisiteDetails)
        let install = sheet.buttons["runtime-install-start"]
        XCTAssertTrue(install.waitForExistence(timeout: 15))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: install)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed,
                       "The reused uv tool and system Python must satisfy setup prerequisites")
        install.click()
        app.sheets.buttons["Cancel"].firstMatch.click()
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(".venv").path))
        install.click()
        app.sheets.buttons["Run make install"].firstMatch.click()
        let terminal = NSPredicate { _, _ in
            let status = sheet.staticTexts["runtime-install-status"]
            let text = (status.value as? String) ?? status.label
            return status.exists && (text == "Install command finished" || text.hasPrefix("Install failed:"))
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: terminal, object: nil)], timeout: 1800)
        capture("Packaged-runtime-install-result")
        if sheet.staticTexts["Install log"].firstMatch.exists { sheet.staticTexts["Install log"].firstMatch.click() }
        let log = sheet.staticTexts.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }.joined(separator: "\n")
        let logAttachment = XCTAttachment(string: log)
        logAttachment.name = "Packaged-runtime-install-log"
        logAttachment.lifetime = .keepAlways
        add(logAttachment)
        XCTAssertEqual(result, .completed, "Runtime installation did not reach a terminal state")
        let python = root.appendingPathComponent(".venv/bin/python")
        XCTAssertTrue(fm.isExecutableFile(atPath: python.path))
        let installed = try inspectInstalledRuntime(python: python, root: root)
        let evidence = try JSONSerialization.data(withJSONObject: installed, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: evidence, uniformTypeIdentifier: "public.json")
        attachment.name = "Packaged-runtime-install.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        let completedStatus = sheet.staticTexts["runtime-install-status"]
        XCTAssertEqual((completedStatus.value as? String) ?? completedStatus.label, "Install command finished", log)
        XCTAssertEqual(installed["python"] as? String, "3.12")
        XCTAssertEqual(installed["pins_match"] as? Bool, true)
        let checks = try XCTUnwrap(installed["runtime"] as? [String: Any])
        XCTAssertEqual(checks["ok"] as? Bool, true)
        XCTAssertTrue(sheet.staticTexts["Convert and serve runtimes are ready."].waitForExistence(timeout: 60))
        let saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        XCTAssertEqual(saved["mlx_agent_path"] as? String, root.appendingPathComponent("vendor/mlx-agent").path)
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent("outputs").path))
        capture("Packaged-runtime-ready")
    }

    private func inspectInstalledRuntime(python: URL, root: URL) throws -> [String: Any] {
        let process = Process()
        let output = Pipe()
        process.executableURL = python
        process.currentDirectoryURL = root
        process.arguments = ["-I", "-c", """
        import importlib.metadata, json, pathlib, re, sys
        root = pathlib.Path(sys.argv[1])
        sys.path.insert(0, str(root))
        from mlx_workbench import deps
        pins = {}
        for file in [root / 'requirements.txt', root / 'vendor/mlx-agent/requirements-lab.txt']:
            for name, version in re.findall(r'^([a-zA-Z0-9_.-]+)==([^\\s#]+)', file.read_text(), re.M):
                pins[name] = version
        actual = {}
        for name in pins:
            try: actual[name] = importlib.metadata.version(name)
            except importlib.metadata.PackageNotFoundError: actual[name] = None
        print(json.dumps({'python': f'{sys.version_info.major}.{sys.version_info.minor}',
                          'pins': pins, 'installed': actual, 'pins_match': pins == actual,
                          'runtime': deps.runtime_report()}))
        """, root.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = python.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        let exit = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exit.signal() }
        try process.run()
        if exit.wait(timeout: .now() + 60) == .timedOut {
            process.terminate()
            if exit.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            XCTFail("Installed-runtime inspection timed out")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testFirstLaunchWalksEveryStepAndPersistsCompletion() throws {
        let configURL = URL(fileURLWithPath: configPath)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["mlx_agent_path": configURL.deletingLastPathComponent().appendingPathComponent("missing-engine").path])
            .write(to: configURL)
        launch(firstRun: true, python: "/usr/bin/false")

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
        XCTAssertTrue(sheet.staticTexts["Review setup"].waitForExistence(timeout: 15))
        XCTAssertTrue(sheet.staticTexts["Setup needs attention"].exists)
        XCTAssertFalse(sheet.buttons["Scan my library"].exists)
        capture("04-step-done")

        sheet.buttons["Review engine"].click()
        XCTAssertTrue(sheet.staticTexts["Connect mlx-agent"].waitForExistence(timeout: 15))
        for _ in 0..<3 { sheet.buttons["Continue"].click() }
        XCTAssertTrue(sheet.staticTexts["Review setup"].waitForExistence(timeout: 15))
        sheet.buttons["Review runtime"].click()
        XCTAssertTrue(sheet.staticTexts["Python runtime"].waitForExistence(timeout: 15))
        for _ in 0..<2 { sheet.buttons["Continue"].click() }
        sheet.buttons["Finish for now"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 15), "Assistant did not dismiss after finishing")
        capture("05-after-finish")

        // Completion persists: a relaunch without the first-run override
        // must not re-present the assistant.
        app.terminate()
        launch(firstRun: false, python: "/usr/bin/false")
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

    func testLibraryModelInspectionAndDeletionReviewDoNotMutateTheModel() throws {
        let screen = try XCTUnwrap(NSScreen.main).frame
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
        let modelRow = app.outlines.staticTexts["Qwen3-4B-4bit"].firstMatch
        XCTAssertTrue(modelRow.waitForExistence(timeout: 45))
        capture("08-library-startup-inspector")
        assertLibraryNavigationVisible()
        if screen.width < 1100 {
            let sidebar = app.outlines["Workbench navigation"]
            sidebar.scroll(byDeltaX: 0, deltaY: -300)
            let settings = app.buttons["Settings"]
            let window = app.windows.firstMatch
            XCTAssertTrue(window.frame.contains(settings.frame))
            XCTAssertTrue(settings.isHittable)
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: settings.frame.midX - window.frame.minX, dy: settings.frame.midY - window.frame.minY
            )).click()
            XCTAssertTrue(app.staticTexts["page-heading-settings"].waitForExistence(timeout: 10))
            capture("08a-library-small-desktop-settings")
            sidebar.scroll(byDeltaX: 0, deltaY: 300)
            library.click()
            XCTAssertTrue(app.staticTexts["page-heading-models"].waitForExistence(timeout: 10))
        }
        library.click()
        XCTAssertTrue(app.buttons["Settings"].exists)
        XCTAssertTrue(app.buttons["Discover"].exists)
        let sourcePicker = app.popUpButtons["library-source"].firstMatch
        let heading = app.staticTexts["page-heading-models"]
        XCTAssertTrue(sourcePicker.exists)
        XCTAssertTrue(heading.exists)
        XCTAssertTrue(sourcePicker.isHittable)
        XCTAssertEqual(sourcePicker.value as? String, "All local models")
        XCTAssertTrue(heading.isHittable)
        XCTAssertGreaterThanOrEqual(sourcePicker.frame.minY, app.windows.firstMatch.frame.minY)
        XCTAssertLessThanOrEqual(sourcePicker.frame.maxY, heading.frame.minY)
        capture("08-library-visible-model-and-sidebar")
        modelRow.doubleClick()
        let memoryFit = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Memory fit: ")).firstMatch
        XCTAssertTrue(memoryFit.waitForExistence(timeout: 10))
        capture("08b-library-inspector-after-selection")
        if screen.width < 1100 {
            let details = app.sheets.firstMatch
            XCTAssertTrue(details.waitForExistence(timeout: 10))
            XCTAssertTrue(details.buttons["Done"].isHittable)
            details.buttons["Done"].click()
            XCTAssertTrue(details.waitForNonExistence(timeout: 10))
        } else {
            assertLibraryNavigationVisible()
            app.buttons["Inspector"].click()
            XCTAssertTrue(app.buttons["Run model"].waitForNonExistence(timeout: 10))
            let window = app.windows.firstMatch
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -2, dy: -2))
            corner.press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 1118, dy: 718)))
            XCTAssertEqual(window.frame.width, 1120, accuracy: 2)
            modelRow.doubleClick()
            XCTAssertTrue(app.buttons["Run model"].waitForExistence(timeout: 10))
            capture("08c-library-inspector-at-1120")
        }
        assertLibraryNavigationVisible()
        modelRow.rightClick()
        let delete = app.menuItems["Delete…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        capture("09-library-delete-context-menu")
        delete.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30))
        capture("10-library-delete-review")
        let reviewedPath = sheet.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", model.path, model.path)).firstMatch
        XCTAssertTrue(reviewedPath.waitForExistence(timeout: 5), sheet.debugDescription)
        XCTAssertTrue(sheet.buttons["Move to Trash"].exists)
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))

        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        let target = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 738, dy: 558))
        corner.press(forDuration: 0.1, thenDragTo: target)
        XCTAssertEqual(window.frame.width, 740, accuracy: 2)
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertTrue(app.buttons["Run model"].waitForNonExistence(timeout: 10),
                      "The wide inspector must close before opening compact model details.")
        capture("10b-library-compact-content")
        print("Compact Library bounds: window=\(window.frame), source=\(sourcePicker.frame), heading=\(heading.frame)")
        XCTAssertTrue(sourcePicker.isHittable, app.debugDescription)
        XCTAssertEqual(sourcePicker.value as? String, "All local models")
        XCTAssertTrue(heading.isHittable)
        XCTAssertGreaterThanOrEqual(sourcePicker.frame.minY, app.windows.firstMatch.frame.minY)
        XCTAssertLessThanOrEqual(sourcePicker.frame.maxY, heading.frame.minY)
        app.typeKey("i", modifierFlags: [.command, .option])
        let details = app.sheets.firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        XCTAssertTrue(details.buttons["Done"].isHittable)
        XCTAssertGreaterThanOrEqual(details.frame.minX, window.frame.minX)
        XCTAssertLessThanOrEqual(details.frame.maxX, window.frame.maxX)
        capture("11-library-compact-inspector")
        details.buttons["Done"].click()
        XCTAssertTrue(details.waitForNonExistence(timeout: 10))
        XCTAssertTrue(modelRow.isHittable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))
    }

    private func assertLibraryNavigationVisible(file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        guard let screen = NSScreen.main?.frame else { XCTFail("The guest screen is unavailable.", file: file, line: line); return }
        print("Library inspector bounds: window=\(window.frame), screen=\(screen)")
        XCTAssertGreaterThanOrEqual(window.frame.minX, screen.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(window.frame.maxX, screen.maxX, file: file, line: line)
        for name in ["Library", "Prepare", "Run"] {
            let button = app.buttons[name].firstMatch
            XCTAssertTrue(button.exists, name, file: file, line: line)
            XCTAssertTrue(window.frame.contains(button.frame), "\(name) lies outside the window: \(button.frame)", file: file, line: line)
            XCTAssertTrue(button.isHittable, name, file: file, line: line)
        }
    }
}
