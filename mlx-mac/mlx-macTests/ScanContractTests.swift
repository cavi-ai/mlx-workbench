import Foundation
import XCTest

@testable import mlx_workbench

final class ScanContractTests: XCTestCase {
    func testDecodeScanPreservesLargeModelAndTotalByteCounts() throws {
        let result = try WorkbenchAPI.decodeScan(fixture(named: "convert-scan-valid"))

        XCTAssertEqual(result.models.map(\.bytes), [903_453_952, 29_047_084_448])
        XCTAssertEqual(result.totals.bytes, 29_950_538_400)
        XCTAssertEqual(result.outputs.count, 1)
        XCTAssertEqual(result.models[0].task?.type, .textLLM)
        XCTAssertEqual(result.models[0].task?.useCases, ["coding", "general_chat"])
        XCTAssertEqual(result.outputs[0].task?.type, .speechToText)
    }

    func testDecodeScanCarriesDrafterFacts() throws {
        var payload = fixture(named: "convert-scan-valid")
        var models = try XCTUnwrap(payload["models"] as? [[String: Any]])
        models[1]["draft"] = ["port": "deepseek_v4_dspark", "target": "DeepSeek-V4-Flash-0731", "block_size": 5]
        models[1]["task"] = ["type": "speculative_draft", "use_cases": ["speculative_decoding"], "source": "gguf_architecture", "confidence": "confirmed"]
        payload["models"] = models

        let result = try WorkbenchAPI.decodeScan(payload)

        XCTAssertNil(result.models[0].draft)
        XCTAssertEqual(result.models[1].draft, ModelDraft(port: "deepseek_v4_dspark", target: "DeepSeek-V4-Flash-0731", blockSize: 5))
        XCTAssertEqual(result.models[1].task?.type, .speculativeDraft)
    }

    func testDecodeScanRejectsMissingRequiredModelBytes() throws {
        XCTAssertThrowsError(try WorkbenchAPI.decodeScan(fixture(named: "convert-scan-missing-bytes"))) { error in
            XCTAssertEqual(error as? ScanContractError, .invalidRequiredField("models[0].bytes"))
        }
    }

    func testDecodeScanAcceptsOlderPayloadWithoutReclaimableBytes() throws {
        var payload = fixture(named: "convert-scan-valid")
        var totals = try XCTUnwrap(payload["totals"] as? [String: Any])
        totals.removeValue(forKey: "reclaimable_bytes")
        payload["totals"] = totals

        let result = try WorkbenchAPI.decodeScan(payload)

        XCTAssertEqual(result.totals.reclaimableBytes, 0)
    }

    private func fixture(named name: String) -> [String: Any] {
        // Shared contract fixtures live at the repo root so the Python
        // suite consumes the same files; see tests/fixtures/README.md.
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // mlx-macTests
            .deletingLastPathComponent()  // mlx-mac
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("tests", isDirectory: true)
            .appendingPathComponent("fixtures", isDirectory: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
