import XCTest

/// Exercises the native host workflow against a controlled loopback HTTP server.
final class HostedModelsUITests: XCTestCase {
    func testHostSetupRefreshFailureAndComparisonCancellation() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("host-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = """
        import http.server, json, pathlib, sys, time
        root = pathlib.Path(sys.argv[1])
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                if (root / 'fail').exists():
                    self.send_error(503); return
                value = {'models': [{'name': 'fixture-model:latest', 'digest': 'fixture-digest', 'size': 4000000,
                    'details': {'family': 'fixture', 'parameter_size': '1B', 'quantization_level': 'Q4'}}]}
                if self.path == '/api/ps': value = {'models': []}
                if self.path == '/api/version': value = {'version': 'fixture'}
                body = json.dumps(value).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
            def do_POST(self):
                self.rfile.read(int(self.headers.get('Content-Length', 0)))
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
                try:
                    self.wfile.write(b'data: {"choices":[{"delta":{"content":"Hello"}}]}\\n\\n'); self.wfile.flush()
                    time.sleep(20)
                    self.wfile.write(b'data: [DONE]\\n\\n')
                except (BrokenPipeError, ConnectionResetError): pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        (root / 'port').write_text(str(server.server_port))
        server.serve_forever()
        """
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", script, root.path]; server.standardOutput = Pipe(); server.standardError = Pipe()
        try server.run()
        let app = XCUIApplication()
        defer { app.terminate(); if server.isRunning { server.terminate(); server.waitUntilExit() }; try? FileManager.default.removeItem(at: root) }
        let portFile = root.appendingPathComponent("port")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: portFile.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        let config = root.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: ["mlx_agent_path": root.appendingPathComponent("missing-agent").path,
            "gguf_roots": [], "mlx_roots": [], "output_dir": root.appendingPathComponent("output").path,
            "verification_enabled": false, "watch_enabled": false]).write(to: config)
        app.launchEnvironment = ["MLX_WORKBENCH_CONFIG": config.path, "CFFIXED_USER_HOME": root.path,
            "XDG_STATE_HOME": root.appendingPathComponent("state").path, "MLX_WORKBENCH_PYTHON": "/usr/bin/python3"]
        app.launchArguments = ["-mlx-workbench.setupCompleted.v1", "YES", "-mlx-workbench.selectedRoute", "library"]
        app.launch()
        let source = app.radioGroups["library-source"].radioButtons["Hosted models"]
        XCTAssertTrue(source.waitForExistence(timeout: 15)); source.click()
        let addHostButton = app.buttons["Add host…"].firstMatch
        XCTAssertTrue(addHostButton.waitForExistence(timeout: 5)); addHostButton.click()
        let url = app.textFields["model-host-url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5)); url.click(); url.typeKey("a", modifierFlags: .command)
        url.typeText("http://127.0.0.1:" + port)
        app.buttons["Save host"].click()
        let refresh = app.buttons["refresh-model-host"].firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 5)); refresh.click()
        let model = app.staticTexts["fixture-model:latest"].firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        try Data().write(to: root.appendingPathComponent("fail")); refresh.click()
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Refresh failed")).firstMatch
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
        let cancelled = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Recorded host comparisons · cancelled")).firstMatch
        XCTAssertTrue(cancelled.waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "hosted-comparison-cancelled"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
