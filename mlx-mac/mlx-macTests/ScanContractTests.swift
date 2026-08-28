import Foundation
import XCTest

@testable import mlx_workbench

final class ScanContractTests: XCTestCase {
    func testDecodeScanPreservesLargeModelAndTotalByteCounts() throws {
        let result = try WorkbenchAPI.decodeScan(fixture(named: "convert-scan-valid"))

        XCTAssertEqual(result.models.map(\.bytes), [903_453_952, 29_047_084_448])
        XCTAssertEqual(result.totals.bytes, 29_950_538_400)
        XCTAssertEqual(result.outputs.count, 1)
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
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        let url = directory.appendingPathComponent(name).appendingPathExtension("json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
