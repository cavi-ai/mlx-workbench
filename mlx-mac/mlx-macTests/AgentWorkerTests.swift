import Darwin
import XCTest

@testable import mlx_workbench

final class AgentWorkerTests: XCTestCase {
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
