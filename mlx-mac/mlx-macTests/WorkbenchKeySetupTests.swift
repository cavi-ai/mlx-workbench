import XCTest
@testable import mlx_workbench

final class WorkbenchKeySetupTests: XCTestCase {
    private let digest = EndpointCredentialStore.digest("mlxw_" + String(repeating: "1", count: 64))

    private func slot(_ port: Int, key: String?) -> EndpointSlot {
        var slot = EndpointSlot(enabled: false, port: port, modelPath: "/Models/m\(port)", loadOnRequest: true)
        slot.apiKeySHA256 = key
        return slot
    }

    func testNoKeyStartsAtCreateKey() {
        let setup = WorkbenchKeySetup(keyDigest: nil, slots: [slot(8930, key: nil)])
        XCTAssertEqual(setup.step, .createKey)
        XCTAssertNil(setup.keySummary)
    }

    func testKeyWithUnprotectedEndpointsListsThemAtProtectStep() {
        let own = EndpointCredentialStore.digest("mlxw_" + String(repeating: "3", count: 64))
        let setup = WorkbenchKeySetup(keyDigest: digest, slots: [slot(8932, key: own), slot(8931, key: digest), slot(8930, key: nil)])
        XCTAssertEqual(setup.step, .protectEndpoints)
        XCTAssertEqual(setup.unprotected.map(\.port), [8930, 8932])
        XCTAssertEqual(setup.unprotected.map(\.hasOwnKey), [false, true])
        XCTAssertEqual(setup.keySummary, "…" + digest.suffix(4))
    }

    func testAllProtectedShowsTheEnvironmentVariableAtConnectStep() {
        let setup = WorkbenchKeySetup(keyDigest: digest, slots: [slot(8930, key: digest), slot(8931, key: digest)])
        XCTAssertEqual(setup.step, .connectApps)
        XCTAssertTrue(setup.unprotected.isEmpty)
        XCTAssertEqual(setup.envVarName, "MLX_AGENT_API_KEY")
    }

    func testChosenExcludesSelectedEndpointsThatAreNowProtected() {
        let a = slot(8932, key: nil), b = slot(8930, key: nil), protected = slot(8931, key: digest)
        let setup = WorkbenchKeySetup(keyDigest: digest, slots: [a, b, protected])
        XCTAssertEqual(setup.chosen([a.id, b.id, protected.id]).map(\.port), [8930, 8932])
        XCTAssertEqual(setup.chosen(nil).map(\.port), [8930, 8932])
        XCTAssertEqual(setup.chosen([]).map(\.port), [])
    }

    func testExportTemplateNamesTheVariableAndNeverTheKey() {
        let setup = WorkbenchKeySetup(keyDigest: digest, slots: [])
        XCTAssertEqual(setup.exportTemplate, "export MLX_AGENT_API_KEY=\"<paste copied key>\"")
        XCTAssertTrue(setup.exportTemplate.contains("MLX_AGENT_API_KEY"))
        XCTAssertFalse(setup.exportTemplate.contains(digest))
        XCTAssertFalse(setup.exportTemplate.contains("mlxw_"))
    }
}
