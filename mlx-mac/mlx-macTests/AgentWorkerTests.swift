import Darwin
import XCTest

@testable import mlx_workbench

final class AgentWorkerTests: XCTestCase {
    func testWorkerStartupConsumesTheInvocationDeadline() throws {
        try Data("import time\ntime.sleep(0.5)\ndef main(argv):\n print('{\"status\":\"ok\",\"data\":{}}')\n".utf8)
            .write(to: root.appendingPathComponent("src/mlx_agent/cli.py"))
        XCTAssertThrowsError(try CLIProcess(worker: worker).run(agentPath: root.path, argv: ["serve", "status"], timeout: 0.05)) {
            guard case BridgeError.skillTimeout = $0 else { return XCTFail("Expected timeout, got \($0)") }
        }
        XCTAssertNil(worker.processIdentifier)
    }

    func testQueuedStatusCannotOutliveItsOwnDeadline() async throws {
        let marker = root.appendingPathComponent("started")
        try Data("""
        import json, time
        from pathlib import Path
        calls = 0
        def main(argv):
            global calls
            calls += 1
            if calls == 2:
                Path(\(String(reflecting: marker.path))).touch()
                time.sleep(0.5)
            print(json.dumps({"status": "ok", "data": {"calls": calls}}))
        """.utf8).write(to: root.appendingPathComponent("src/mlx_agent/cli.py"))
        let cli = CLIProcess(worker: worker), path = root.path
        _ = try cli.run(agentPath: path, argv: ["serve", "status"])
        let first = Task { await WorkbenchIO.perform { Result { try cli.run(agentPath: path, argv: ["serve", "status"], timeout: 3) } } }
        try await waitForMarker(marker)
        let queued = await WorkbenchIO.perform { Result { try cli.run(agentPath: path, argv: ["serve", "status"], timeout: 0.05) } }
        XCTAssertThrowsError(try queued.get()) {
            guard case BridgeError.skillTimeout = $0 else { return XCTFail("Expected timeout, got \($0)") }
        }
        let completed = await first.value
        XCTAssertEqual(try completed.get()["calls"] as? Int, 2)
    }

    func testCancellationStopsTheOwnedWorkerBeforeItsDelayedReply() async throws {
        let marker = root.appendingPathComponent("started")
        try Data("""
        import time
        from pathlib import Path
        def main(argv):
            Path(\(String(reflecting: marker.path))).touch()
            time.sleep(5)
            print('{"status":"ok","data":{}}')
        """.utf8).write(to: root.appendingPathComponent("src/mlx_agent/cli.py"))
        let cli = CLIProcess(worker: worker), path = root.path
        let cancellation = CLIInvocationCancellation()
        let invocation = Task { await WorkbenchIO.perform {
            Result { try cli.run(agentPath: path, argv: ["serve", "status"], timeout: 10, cancellation: cancellation) }
        } }
        try await waitForMarker(marker)
        let started = ProcessInfo.processInfo.systemUptime
        cancellation.cancel()
        let result = await invocation.value
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        XCTAssertNil(worker.processIdentifier)
    }

    func testFallbackUsesOnlyTheRemainingInvocationBudget() throws {
        let script = root.appendingPathComponent("broken-worker.py")
        try Data("""
        import sys, time
        time.sleep(0.3)
        print('{"ready":true}', flush=True)
        sys.stdin.readline()
        print('{}', flush=True)
        """.utf8).write(to: script)
        worker = AgentWorker(script: script)
        try Data("import time\ntime.sleep(0.4)\nprint('{\"status\":\"ok\",\"data\":{}}')\n".utf8)
            .write(to: root.appendingPathComponent("scripts/mlx-agent"))
        XCTAssertThrowsError(try CLIProcess(worker: worker).run(agentPath: root.path, argv: ["serve", "status"], timeout: 0.5)) {
            guard case BridgeError.skillTimeout = $0 else { return XCTFail("Expected timeout, got \($0)") }
        }
    }

    private func waitForMarker(_ url: URL) async throws {
        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "AgentWorkerTests", code: 1)
    }

    private var root: URL!
    private var worker: AgentWorker!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-worker-\(UUID().uuidString)", isDirectory: true)
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        let package = root.appendingPathComponent("src/mlx_agent", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("""
        import json, os, sys
        print(json.dumps({"status": "ok", "data": {"pid": os.getpid(), "argv": sys.argv[1:]}}))
        """.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
        try Data().write(to: package.appendingPathComponent("__init__.py"))
        try Data("""
        import json, os
        calls = 0
        def main(argv):
            global calls
            calls += 1
            print(json.dumps({"status": "ok", "data": {"pid": os.getpid(), "calls": calls, "argv": argv}}))
            return 0
        """.utf8).write(to: package.appendingPathComponent("cli.py"))
        worker = AgentWorker()
    }

    override func tearDown() {
        worker.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func testServeStatusReusesOneEngineProcessWhileOtherCommandsLaunchTheirOwn() throws {
        let cli = CLIProcess(worker: worker)
        let first = try cli.run(agentPath: root.path, argv: ["serve", "status"])
        let second = try cli.run(agentPath: root.path, argv: ["serve", "status"])
        XCTAssertEqual(first["calls"] as? Int, 1)
        XCTAssertEqual(second["calls"] as? Int, 2)
        XCTAssertEqual(second["argv"] as? [String], ["serve", "status", "--json"])
        let workerPID = try XCTUnwrap(worker.processIdentifier)
        XCTAssertEqual(first["pid"] as? Int, Int(workerPID))
        XCTAssertEqual(second["pid"] as? Int, Int(workerPID))

        let scan = try cli.run(agentPath: root.path, argv: ["convert", "scan"])
        XCTAssertNil(scan["calls"])
        XCTAssertNotEqual(scan["pid"] as? Int, Int(workerPID))
    }

    func testAnExitedWorkerIsReplacedOnTheNextStatusCall() throws {
        let cli = CLIProcess(worker: worker)
        _ = try cli.run(agentPath: root.path, argv: ["serve", "status"])
        let firstPID = try XCTUnwrap(worker.processIdentifier)
        kill(firstPID, SIGKILL)
        let replacement = try cli.run(agentPath: root.path, argv: ["serve", "status"])
        XCTAssertNil(replacement["calls"], "the failed request is answered by the CLI")
        let next = try cli.run(agentPath: root.path, argv: ["serve", "status"])
        XCTAssertEqual(next["calls"] as? Int, 1)
        XCTAssertNotEqual(next["pid"] as? Int, Int(firstPID))
    }

    func testAnEngineWithoutAnImportableCoreUsesItsCLI() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("src"))
        let cli = CLIProcess(worker: worker)
        let status = try cli.run(agentPath: root.path, argv: ["serve", "status"])
        XCTAssertNil(status["calls"])
        XCTAssertEqual(status["argv"] as? [String], ["serve", "status", "--json"])
        XCTAssertNil(worker.processIdentifier)
    }
}
