import XCTest
@testable import mlx_workbench

final class WorkbenchKeySetupTests: XCTestCase {
    private let digest = EndpointCredentialStore.digest("mlxw_" + String(repeating: "1", count: 64))

    private func slot(_ port: Int, key: String?) -> EndpointSlot {
        var slot = EndpointSlot(enabled: false, port: port, modelPath: "/Models/m\(port)", loadOnRequest: true)
        slot.apiKeySHA256 = key
        return slot
    }

    func testChosenExcludesSelectedEndpointsThatAreNowProtected() {
        let a = slot(8932, key: nil), b = slot(8930, key: nil), protected = slot(8931, key: digest)
        let setup = WorkbenchKeySetup(keyDigest: digest, slots: [a, b, protected])
        XCTAssertEqual(setup.chosen([a.id, b.id, protected.id]).map(\.port), [8930, 8932])
        XCTAssertEqual(setup.chosen(nil).map(\.port), [8930, 8932])
        XCTAssertEqual(setup.chosen([]).map(\.port), [])
    }
}
