import XCTest
@testable import mlx_workbench

final class LabWorkspaceTests: XCTestCase {
    func testRequestPreservesFrozenRecipeAndChangesOneVariable() throws {
        let baseline = try JSONDecoder().decode(LabValue.self, from: Data(#"{"prompt":"A kite","seed":42,"inference_steps":4,"model_revision":"frozen"}"#.utf8))
        let draft = LabDraft(baseline: baseline, variablePath: "inference_steps", alternateValue: .integer(8))
        let request = LabRequest(operation: "preview", draft: draft)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let emitted = try XCTUnwrap(object["draft"] as? [String: Any])
        XCTAssertEqual(emitted["variable_path"] as? String, "inference_steps")
        XCTAssertEqual((emitted["baseline"] as? [String: Any])?["model_revision"] as? String, "frozen")
        XCTAssertEqual(emitted["alternate_value"] as? Int, 8)
    }

    func testSealedSnapshotDecodesWithoutCanonicalMetadata() throws {
        let data = Data(#"{"history":{"items":[{"id":"exp_one","sealed":true,"states":["queued","queued"],"evidence_completeness":"pending"}]},"queue":[{"id":"job_one","experiment_id":"exp_one","state":"queued","error":null}]}"#.utf8)
        let response = try JSONDecoder().decode(LabResponse.self, from: data)
        XCTAssertEqual(response.history?.items.first?.id, "exp_one")
        XCTAssertTrue(try XCTUnwrap(response.history?.items.first?.sealed))
        XCTAssertEqual(response.queue?.first?.state, "queued")
    }

    func testLiveAgentWorkspaceSnapshot() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let agent = environment["MLX_LAB_TEST_AGENT"] else {
            throw XCTSkip("Set MLX_LAB_TEST_AGENT to exercise the shared engine.")
        }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: store) }
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent)
        let response = try await api.labWorkspace(request: LabRequest(operation: "snapshot"),
                                                  store: store, reviewer: "native-contract")
        XCTAssertEqual(response.history?.items.count, 0)
        XCTAssertEqual(response.queue?.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent("experiments.sqlite3").path))
    }
}
