import Foundation
import XCTest

@testable import mlx_workbench

/// Decodes the goldens mlx-agent validates against its JSON Schemas.
final class IntakeContractTests: XCTestCase {
    func testAudio8ResolutionDecodes() throws {
        let value = try WorkbenchAPI.decode(IntakeResolution.self, from: try vendoredFixture("intake-resolve-audio8"))
        XCTAssertEqual(value.verdict, .convertibleAfterInstall)
        XCTAssertEqual(value.backend, "mlx-audio")
        XCTAssertEqual(value.reasons, [])
        XCTAssertEqual(value.task?.type, .speechToText)
        XCTAssertEqual(value.components.map(\.role), ["model", "audio", "text"])
        XCTAssertEqual(value.components[0].matches.map(\.module), ["mlx_audio.stt.models.audio8_asr_infinite"])
        XCTAssertTrue(value.components[1].matches.contains { $0.module == "mlx_audio.stt.models.voxtral_realtime" })
        XCTAssertGreaterThan(value.bytes, 8_000_000_000)
    }

    /// Laya has no root config: the agent resolves it through the port's file signature.
    func testLayaResolvesAsAClassificationPortWithANarrowedDownload() throws {
        let value = try WorkbenchAPI.decode(IntakeResolution.self, from: try vendoredFixture("intake-resolve-laya"))
        XCTAssertEqual(value.verdict, .convertibleAfterInstall)
        XCTAssertEqual(value.backend, "mlx-embeddings")
        XCTAssertEqual(value.modelType, "laya")
        XCTAssertEqual(value.task?.type, .classification)
        XCTAssertEqual(value.downloadBytes, 846_195_574)
        XCTAssertEqual(value.qBits, [8])
        XCTAssertNil(value.source.subfolder)
        XCTAssertEqual(value.source.reference, "convaiinnovations/laya")
        let rows = IntakePresentation.summaryRows(value, qBits: 4)
        XCTAssertEqual(rows.first { $0.label == "Download" }?.value, LibraryTablePresentation.byteCount(846_195_574))
        XCTAssertEqual(rows.first { $0.label == "Type" }?.value, "Classification")
    }

    /// The estimate comes from the agent's header-based sizes; without them
    /// there is no row rather than a guess that assumes every weight quantizes.
    func testEstimatedOutputUsesTheAgentSizes() throws {
        let value = try WorkbenchAPI.decode(IntakeResolution.self, from: try vendoredFixture("intake-resolve-audio8"))
        XCTAssertEqual(value.estimatedOutputBytes?["4"], 3_748_321_085)
        let rows = IntakePresentation.summaryRows(value, qBits: 4)
        XCTAssertEqual(rows.first { $0.label == "Estimated 4-bit output" }?.value, LibraryTablePresentation.byteCount(3_748_321_085))
        XCTAssertEqual(IntakePresentation.summaryRows(value, qBits: 8).first { $0.label == "Estimated 8-bit output" }?.value,
                       LibraryTablePresentation.byteCount(5_291_169_597))

        let json = """
        {"schema":"intake/1","source":{"input":"x","repo":"org/thing","revision":"main","file":null,"url":"u"},
         "verdict":"convertible","reasons":[],"backend":"mlx-lm","backend_installed":true,
         "model_type":"qwen2","components":[],"task":null,"custom_code":false,"gated":false,"library_name":null,
         "pipeline_tag":null,"transformers_version":null,"bytes":1000000,"estimated_output_bytes":null,
         "files":{"safetensors":1,"gguf":[],"python":[]},"warnings":[]}
        """
        let unknown = try JSONDecoder().decode(IntakeResolution.self, from: Data(json.utf8))
        XCTAssertFalse(IntakePresentation.summaryRows(unknown, qBits: 4).contains { $0.label.hasPrefix("Estimated") })
    }

    func testBackendListDecodes() throws {
        let value = try WorkbenchAPI.decode(BackendList.self, from: try vendoredFixture("backend-list"))
        XCTAssertEqual(value.backends.map(\.id), ["mlx-audio", "mlx-embeddings", "mlx-lm", "mlx-vlm"])
        XCTAssertTrue(value.backends.allSatisfy { $0.state == .absent })
    }

    func testPortAnalysisDecodes() throws {
        let value = try WorkbenchAPI.decode(PortAnalysis.self, from: try vendoredFixture("port-analysis-synthetic"))
        XCTAssertEqual(value.components.map(\.status), ["missing", "exists", "exists"])
        XCTAssertTrue(value.missing.contains(PortMissing(kind: "file", name: "vad_heads.safetensors")))
    }

    func testUnknownVerdictDecodesAsUnknown() throws {
        let data = Data(#""brand_new""#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(IntakeVerdict.self, from: data), .unknown)
    }

    private func vendoredFixture(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // mlx-macTests
            .deletingLastPathComponent()   // mlx-mac
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("vendor/mlx-agent/tests/fixtures/\(name).json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }
}
