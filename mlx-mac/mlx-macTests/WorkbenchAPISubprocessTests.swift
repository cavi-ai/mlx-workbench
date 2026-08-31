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

    init(scanPayload: [String: Any]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-fixture-agent-\(UUID().uuidString)", isDirectory: true)
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)

        let envelope: [String: Any] = [
            "status": "ok",
            "data": scanPayload,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: envelope).base64EncodedString()
        let script = """
        import base64
        import sys

        assert "convert" in sys.argv and "scan" in sys.argv and "--json" in sys.argv
        print(base64.b64decode("\(encoded)").decode("utf-8"))
        """
        try Data(script.utf8).write(to: scripts.appendingPathComponent("mlx-agent"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
