import Foundation
import XCTest

@testable import mlx_workbench

/// Decodes the goldens mlx-agent validates against its JSON Schemas.
final class IntakeContractTests: XCTestCase {
    func testAudio8ResolutionDecodes() throws {
        let value = try WorkbenchAPI.decode(IntakeResolution.self, from: try vendoredFixture("intake-resolve-audio8"))
        XCTAssertEqual(value.verdict, .unsupported)
        XCTAssertEqual(value.reasons, ["arch_not_in_registry", "custom_code"])
        XCTAssertEqual(value.task?.type, .speechToText)
        XCTAssertEqual(value.components.map(\.role), ["model", "audio", "text"])
        XCTAssertTrue(value.components[1].matches.contains { $0.module == "mlx_audio.stt.models.voxtral_realtime" })
        XCTAssertGreaterThan(value.bytes, 8_000_000_000)
    }

    func testBackendListDecodes() throws {
        let value = try WorkbenchAPI.decode(BackendList.self, from: try vendoredFixture("backend-list"))
        XCTAssertEqual(value.backends.map(\.id), ["mlx-audio", "mlx-lm", "mlx-vlm"])
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
