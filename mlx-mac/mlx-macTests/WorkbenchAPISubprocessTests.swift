import Foundation
import XCTest

@testable import mlx_workbench

final class WorkbenchAPISubprocessTests: XCTestCase {
    func testScanRunsFixtureAgentAndPreservesReportedBytes() async throws {
        let payload = try fixture(named: "convert-scan-valid")
        let agent = try FixtureAgent(scanPayload: payload)
        defer { agent.remove() }

        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path)
        let result = try await api.scan(
            ggufRoots: ["/fixtures/gguf"], mlxRoots: [], signatures: true
        )

        XCTAssertEqual(result.models[1].bytes, 29_047_084_448)
        XCTAssertEqual(result.totals.bytes, 29_950_538_400)
    }

    func testConfiguredScanMatchesFilesystemBytesWhenEnabled() async throws {
#if !MLX_WORKBENCH_LIVE_SCAN
        throw XCTSkip("run make test-swift-live-scan to validate the configured local inventory")
#else

        let config = ConfigModule().load()
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: config.mlxAgentPath)
        let result = try await api.scan(
            ggufRoots: ConfigModule().scanRoots(value: config),
            mlxRoots: config.mlxRoots,
            signatures: config.signatures
        )
        if result.models.isEmpty {
            throw XCTSkip("no GGUF models exist in the configured scan roots")
        }

        let manager = FileManager.default
        var modelBytes: Int64 = 0
        for model in result.models {
            let attributes = try manager.attributesOfItem(atPath: model.path)
            let filesystemBytes = try XCTUnwrap(attributes[.size] as? NSNumber).int64Value
            XCTAssertGreaterThan(model.bytes, 0, model.path)
            XCTAssertEqual(model.bytes, filesystemBytes, model.path)
            modelBytes += model.bytes
        }
        XCTAssertEqual(result.totals.bytes, modelBytes)
#endif
    }

    func testConvertPreviewUnwrapsPlanEnvelope() async throws {
        // mlx-agent ≥ 0.5.x wraps previews in {plan, requires_confirmation}.
        let agent = try FixtureAgent(
            convertPreviewPayload: [
                "plan": ["preview_hash": "hash-plan", "out": "/out"],
                "requires_confirmation": true,
            ]
        )
        defer { agent.remove() }

        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path)
        let result = try await api.convertPreview(ggufPath: "/m/a.gguf", qBits: 4, out: nil)

        XCTAssertEqual(result["preview_hash"] as? String, "hash-plan")
        XCTAssertEqual(result["out"] as? String, "/out")
    }

    func testConvertPreviewAcceptsFlatLegacyShape() async throws {
        let agent = try FixtureAgent(
            convertPreviewPayload: ["preview_hash": "hash-flat", "out": "/out"]
        )
        defer { agent.remove() }

        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path)
        let result = try await api.convertPreview(ggufPath: "/m/a.gguf", qBits: 4, out: nil)

        XCTAssertEqual(result["preview_hash"] as? String, "hash-flat")
    }

    func testRunPrependsInterpreterDirectoryToPath() async throws {
        let agent = try FixtureAgent(pathProbe: true)
        defer { agent.remove() }

        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent.root.path)
        let result = try await api.raw(["probe"])

        let reported = try XCTUnwrap(result["process_path"] as? String)
        // Expect the interpreter the bridge actually resolves (env override →
        // repo .venv → PATH), not a hard-coded python3.
        let resolvedPython = try XCTUnwrap(WorkbenchPython.preferredExecutable())
        let expectedDir = resolvedPython.deletingLastPathComponent().path
        XCTAssertTrue(
            reported.hasPrefix(expectedDir + ":"),
            "agent PATH should start with the interpreter's directory; got \(reported)"
        )
    }

    private func fixture(named name: String) throws -> [String: Any] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("json")
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

private final class FixtureAgent {
    let root: URL

    private init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-fixture-agent-\(UUID().uuidString)", isDirectory: true)
    }

    convenience init(scanPayload: [String: Any]) throws {
        self.init()
        try write(scriptAssertion: "\"convert\" in sys.argv and \"scan\" in sys.argv", payload: scanPayload)
    }

    convenience init(convertPreviewPayload: [String: Any]) throws {
        self.init()
        try write(scriptAssertion: "\"convert\" in sys.argv and \"start\" in sys.argv and \"--confirm\" not in sys.argv", payload: convertPreviewPayload)
    }

    /// Emits the child process PATH in the payload, for the PATH-prepend test.
    convenience init(pathProbe: Bool) throws {
        self.init()
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = """
        import json
        import os
        print(json.dumps({"status": "ok", "data": {"process_path": os.environ.get("PATH", "")}}))
        """
        try Data(script.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
    }

    private func write(scriptAssertion: String, payload: [String: Any]) throws {
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let envelope: [String: Any] = [
            "status": "ok",
            "data": payload,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: envelope).base64EncodedString()
        let script = """
        import base64
        import sys

        assert \(scriptAssertion) and "--json" in sys.argv
        print(base64.b64decode("\(encoded)").decode("utf-8"))
        """
        try Data(script.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
