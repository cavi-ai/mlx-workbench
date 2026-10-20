import Network
import XCTest

/// Exercises the native host workflow against a controlled loopback HTTP server.
final class HostedModelsUITests: XCTestCase {
    func testHostSetupRefreshFailureAndComparisonCancellation() throws {
        continueAfterFailure = false
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
        let model = app.staticTexts["fixture-model:latest"].firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 10))
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
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
                queue.asyncAfter(deadline: .now() + 20) {
                    connection.send(content: Data("data: [DONE]\n\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
                return
            }
            let failing = FileManager.default.fileExists(atPath: root.appendingPathComponent("fail").path)
            let body: String
            if failing { body = "{}" }
            else if request.hasPrefix("GET /api/ps ") { body = "{\"models\":[]}" }
            else if request.hasPrefix("GET /api/version ") { body = "{\"version\":\"fixture\"}" }
            else { body = "{\"models\":[{\"name\":\"fixture-model:latest\",\"digest\":\"fixture-digest\",\"size\":4000000,\"details\":{\"family\":\"fixture\",\"parameter_size\":\"1B\",\"quantization_level\":\"Q4\"}}]}" }
            let response = "HTTP/1.1 \(failing ? "503 Unavailable" : "200 OK")\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() {
        queue.sync { listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() }
    }
}
