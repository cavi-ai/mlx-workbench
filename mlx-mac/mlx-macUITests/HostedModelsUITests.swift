import Network
import XCTest

/// Exercises the native host workflow against a controlled loopback HTTP server.
final class HostedModelsUITests: XCTestCase {
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
    }

    func testHostSetupRefreshFailureAndComparisonCancellation() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
            .appendingPathComponent("host-ui-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let server = try HostedUIFixture(root: root)
        let app = XCUIApplication()
        defer { app.terminate(); server.stop(); try? FileManager.default.removeItem(at: root) }
        let port = try server.start()
        let config = root.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: ["mlx_agent_path": root.appendingPathComponent("missing-agent").path,
            "gguf_roots": [], "mlx_roots": [], "output_dir": root.appendingPathComponent("output").path,
            "verification_enabled": false, "watch_enabled": false]).write(to: config)
        app.launchEnvironment = ["MLX_WORKBENCH_CONFIG": config.path, "CFFIXED_USER_HOME": root.path,
            "XDG_STATE_HOME": root.appendingPathComponent("state").path, "MLX_WORKBENCH_PYTHON": "/usr/bin/python3"]
        app.launchArguments = ["-mlx-workbench.setupCompleted.v1", "YES"]
        app.launch()
        let library = app.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 15)); library.click()
        let source = app.radioGroups["library-source"].radioButtons["Hosted models"]
        XCTAssertTrue(source.waitForExistence(timeout: 15)); source.click()
        let addHostButton = app.buttons["Add host…"].firstMatch
        XCTAssertTrue(addHostButton.waitForExistence(timeout: 5)); addHostButton.click()
        let url = app.textFields["model-host-url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5)); url.click(); url.typeKey("a", modifierFlags: .command)
        url.typeText("http://127.0.0.1:\(port)")
        app.buttons["Save host"].click()
        let refresh = app.buttons["refresh-model-host"].firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 5)); refresh.click()
        let installedModels = app.outlines["hosted-model-table"]
        let model = installedModels.staticTexts["fixture-model:latest"].firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        let runningDisclosure = app.disclosureTriangles["host-running-models"]
        XCTAssertTrue(runningDisclosure.waitForExistence(timeout: 5))
        clickRunningDisclosure(runningDisclosure)
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (runningDisclosure.value as? String) == "1" || (runningDisclosure.value as? NSNumber)?.intValue == 1
        }, object: nil)
        wait(for: [expanded], timeout: 5)
        runningDisclosure.scroll(byDeltaX: 0, deltaY: -240)
        let runningOnly = app.staticTexts["orphan-running:latest"].firstMatch
        XCTAssertTrue(runningOnly.waitForExistence(timeout: 5))
        XCTAssertFalse(installedModels.staticTexts["orphan-running:latest"].exists)
        let runningImage = XCTAttachment(screenshot: app.screenshot()); runningImage.name = "ollama-running-separate-from-tags"; runningImage.lifetime = .keepAlways; add(runningImage)
        clickRunningDisclosure(runningDisclosure)
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (runningDisclosure.value as? String) == "0" || (runningDisclosure.value as? NSNumber)?.intValue == 0
        }, object: nil)
        wait(for: [collapsed], timeout: 5)
        runningDisclosure.scroll(byDeltaX: 0, deltaY: 240)
        try Data().write(to: root.appendingPathComponent("fail")); refresh.click()
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Refresh failed", "Refresh failed")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10)); XCTAssertTrue(model.exists)
        try FileManager.default.removeItem(at: root.appendingPathComponent("fail")); refresh.click()
        XCTAssertTrue(model.waitForExistence(timeout: 10)); model.click()
        let compare = app.buttons["Compare…"].firstMatch
        let canCompare = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in compare.isEnabled }, object: nil)
        wait(for: [canCompare], timeout: 10); compare.click()
        let run = app.buttons["run-hosted-comparison"]
        XCTAssertTrue(run.waitForExistence(timeout: 10)); XCTAssertTrue(run.isEnabled); run.click()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.click()
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        let cancelled = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Recorded host comparisons · cancelled", "Recorded host comparisons · cancelled")).firstMatch
        XCTAssertTrue(cancelled.waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "hosted-comparison-cancelled"; attachment.lifetime = .keepAlways; add(attachment)

        library.click()
        // A different selected connection must not win over an explicit toolbar request.
        clickVisibleControl(app.buttons["Add host…"].firstMatch, in: app)
        let secondName = app.sheets.textFields.matching(NSPredicate(format: "value == %@", "Ollama")).firstMatch
        XCTAssertTrue(secondName.waitForExistence(timeout: 5))
        secondName.click(); secondName.typeKey("a", modifierFlags: .command); secondName.typeText("Other host")
        let secondURL = app.textFields["model-host-url"]
        secondURL.click(); secondURL.typeKey("a", modifierFlags: .command); secondURL.typeText("http://127.0.0.1:1")
        app.buttons["Save host"].click()
        let hostPicker = app.popUpButtons["model-host-picker"]
        XCTAssertTrue(hostPicker.waitForExistence(timeout: 5)); clickVisibleControl(hostPicker, in: app)
        app.menuItems["Other host"].click()
        app.buttons["Overview"].firstMatch.click()
        let memory = app.buttons["system-memory-header"]
        XCTAssertTrue(memory.waitForExistence(timeout: 5)); memory.click()
        let openHost = app.buttons["Open Ollama in Library"]
        XCTAssertTrue(openHost.waitForExistence(timeout: 5))
        let refreshHost = app.buttons["Refresh Ollama"]
        XCTAssertTrue(refreshHost.exists); clickVisibleControl(refreshHost, in: app)
        XCTAssertTrue(app.staticTexts["2 models reported loaded"].firstMatch.waitForExistence(timeout: 5))
        let memoryImage = XCTAttachment(screenshot: app.screenshot()); memoryImage.name = "memory-saved-hosts"; memoryImage.lifetime = .keepAlways; add(memoryImage)
        clickVisibleControl(openHost, in: app)
        XCTAssertTrue(hostPicker.waitForExistence(timeout: 5))
        XCTAssertEqual(hostPicker.value as? String, "Ollama")
        XCTAssertTrue(model.waitForExistence(timeout: 5)); clickVisibleControl(model, in: app)
        let unload = app.buttons["host-resource-open"]
        XCTAssertTrue(unload.waitForExistence(timeout: 5)); clickVisibleControl(unload, in: app)
        let confirm = app.buttons["host-resource-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        let warning = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Other clients may be using", "Other clients may be using")).firstMatch
        XCTAssertTrue(warning.exists)
        clickVisibleControl(app.buttons["Cancel"].firstMatch, in: app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("released").path))

        clickVisibleControl(unload, in: app); XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        let previewImage = XCTAttachment(screenshot: app.screenshot()); previewImage.name = "unload-activity-unknown"; previewImage.lifetime = .keepAlways; add(previewImage)
        try Data().write(to: root.appendingPathComponent("changed-digest"))
        clickVisibleControl(confirm, in: app)
        let changed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Review the updated check", "Review the updated check")).firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("released").path))
        clickVisibleControl(confirm, in: app)
        let unloaded = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "no longer loaded", "no longer loaded")).firstMatch
        XCTAssertTrue(unloaded.waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("released"), encoding: .utf8), "1")
        let resultImage = XCTAttachment(screenshot: app.screenshot()); resultImage.name = "unload-readback"; resultImage.lifetime = .keepAlways; add(resultImage)
        clickVisibleControl(app.buttons["Close"].firstMatch, in: app)
    }

    private func clickRunningDisclosure(_ control: XCUIElement) {
        // The macOS AX frame includes 22 points before the painted chevron and the full label.
        control.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 26, dy: 0)).click()
    }

    private func clickVisibleControl(_ control: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // Retained SwiftUI pages can lack an accessibility hit point after navigation.
        // Use the reported control frame without automatic ancestor scrolling.
        let frame = control.frame
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width > 0, frame.height > 0,
              app.windows.firstMatch.frame.contains(frame) else {
            XCTFail("The requested control is not inside the visible window", file: file, line: line); return
        }
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }
}

/// The UI runner is sandboxed, so the fixture runs in process without launching developer tools.
private final class HostedUIFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "hosted-ui-http-fixture")
    private let root: URL
    private var connections: [NWConnection] = []

    init(root: URL) throws {
        self.root = root
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() throws -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        var result: Result<UInt16, Error>?
        listener.stateUpdateHandler = { [self] state in
            guard result == nil else { return }
            switch state {
            case .ready: result = .success(listener.port!.rawValue); ready.signal()
            case .failed(let error): result = .failure(error); ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [self] connection in
            connections.append(connection)
            connection.start(queue: queue)
            receive(connection, data: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let result else { throw URLError(.timedOut) }
        return try result.get()
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] chunk, _, complete, error in
            guard error == nil else { connection.cancel(); return }
            var data = data; data.append(chunk ?? Data())
            guard data.count < 1_048_576, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            guard let end = request.range(of: "\r\n\r\n") else {
                if complete { connection.cancel() } else { receive(connection, data: data) }; return
            }
            let header = String(request[..<end.lowerBound])
            let length = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last!.trimmingCharacters(in: .whitespaces)) } ?? 0
            guard request[end.upperBound...].utf8.count >= length else { receive(connection, data: data); return }
            if request.hasPrefix("POST ") {
                if request.hasPrefix("POST /api/generate ") {
                    do {
                        let file = root.appendingPathComponent("released")
                        let previous = (try? String(contentsOf: file, encoding: .utf8)).flatMap(Int.init) ?? 0
                        try Data(String(previous + 1).utf8).write(to: file)
                    }
                    catch { XCTFail("Could not record fixture unload: \(error)") }
                    let body = "{\"model\":\"fixture-model:latest\",\"done\":true,\"done_reason\":\"unload\"}"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
                queue.asyncAfter(deadline: .now() + 20) {
                    connection.send(content: Data("data: [DONE]\n\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
                return
            }
            let failing = FileManager.default.fileExists(atPath: root.appendingPathComponent("fail").path)
            let released = FileManager.default.fileExists(atPath: root.appendingPathComponent("released").path)
            let digest = FileManager.default.fileExists(atPath: root.appendingPathComponent("changed-digest").path) ? "changed" : "fixture-digest"
            let body: String
            if failing { body = "{}" }
            else if request.hasPrefix("GET /api/ps ") { body = released ? "{\"models\":[]}" : "{\"models\":[{\"name\":\"fixture-model:latest\",\"digest\":\"\(digest)\",\"size_vram\":4000000},{\"name\":\"orphan-running:latest\",\"digest\":\"orphan-digest\",\"size_vram\":2000000}]}" }
            else if request.hasPrefix("GET /api/version ") { body = "{\"version\":\"fixture\"}" }
            else { body = "{\"models\":[{\"name\":\"fixture-model:latest\",\"digest\":\"\(digest)\",\"size\":4000000,\"details\":{\"family\":\"fixture\",\"parameter_size\":\"1B\",\"quantization_level\":\"Q4\"}}]}" }
            let response = "HTTP/1.1 \(failing ? "503 Unavailable" : "200 OK")\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() {
        queue.sync { listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() }
    }
}
