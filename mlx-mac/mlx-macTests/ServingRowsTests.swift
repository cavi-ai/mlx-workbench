import Foundation
import XCTest

@testable import mlx_workbench

final class ServingRowsTests: XCTestCase {
    private let managed = "/receipts/workbench"
    private let capturedAt = Date(timeIntervalSince1970: 1_000)

    private func server(_ path: String, port: Int, pid: Int, state: String = "running", managed isManaged: Bool = true) -> ServerInfo {
        ServerInfo(path: path, port: port, pid: pid, state: state, modelState: "loaded",
                   receiptsDirectory: isManaged ? managed : "/receipts/other")
    }

    private func snapshot(_ engine: [ServerInfo]) -> ServingInventorySnapshot {
        ServingInventorySnapshot.make(engine: engine, hosts: [], managedReceipts: managed, capturedAt: capturedAt)
    }

    func testSlotWithItsRunningServerAndServiceGivesOneEndpointRow() throws {
        let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/models/owned")
        let owned = server(slot.modelPath, port: slot.port, pid: 10)
        let rows = ServingRows.build(slots: [slot], servers: [owned], snapshot: snapshot([owned]))
        XCTAssertEqual(rows.count, 1)
        guard case .endpoint(let rowSlot, let rowServer, let service) = try XCTUnwrap(rows.first) else {
            return XCTFail("expected an endpoint row")
        }
        XCTAssertEqual(rowSlot, slot)
        XCTAssertEqual(rowServer, owned)
        XCTAssertEqual(service?.modelID, slot.modelPath)
        XCTAssertEqual(rows.first?.id, "endpoint-\(slot.id.uuidString)")
    }

    func testThirdPartyServiceGivesOneServiceRow() throws {
        let other = server("/models/ollama", port: 11434, pid: 30, managed: false)
        let rows = ServingRows.build(slots: [], servers: [], snapshot: snapshot([other]))
        XCTAssertEqual(rows.count, 1)
        guard case .service(let service) = try XCTUnwrap(rows.first) else { return XCTFail("expected a service row") }
        XCTAssertEqual(service.modelID, "/models/ollama")
        XCTAssertTrue(rows[0].id.hasPrefix("service-"))
    }

    func testRunningServerWithoutSlotOrServiceGivesOneServerRow() throws {
        let bare = server("/models/bare", port: 9001, pid: 40)
        let rows = ServingRows.build(slots: [], servers: [bare], snapshot: .empty)
        XCTAssertEqual(rows.count, 1)
        guard case .server(let rowServer, let service) = try XCTUnwrap(rows.first) else { return XCTFail("expected a server row") }
        XCTAssertEqual(rowServer, bare)
        XCTAssertNil(service)
        XCTAssertEqual(rows[0].id, "server-\(bare.id)")
    }

    func testManagedServiceAndItsRunningServerGiveOneServerRowWithTheServiceAttached() throws {
        let launched = server("/models/launched", port: 9002, pid: 50)
        let rows = ServingRows.build(slots: [], servers: [launched], snapshot: snapshot([launched]))
        XCTAssertEqual(rows.count, 1)
        guard case .server(let rowServer, let service) = try XCTUnwrap(rows.first) else { return XCTFail("expected a server row") }
        XCTAssertEqual(rowServer, launched)
        XCTAssertEqual(service?.modelID, launched.modelIdentity)
        XCTAssertEqual(rows[0].id, "server-\(launched.id)")
    }

    func testStoppedServerGivesNoServerRowAndExactlyOneServiceRow() throws {
        let stopped = server("/models/stopped", port: 9003, pid: 60, state: "stopped")
        let rows = ServingRows.build(slots: [], servers: [stopped], snapshot: snapshot([stopped]))
        XCTAssertEqual(rows.count, 1)
        guard case .service(let service) = try XCTUnwrap(rows.first) else { return XCTFail("expected a service row") }
        XCTAssertEqual(service.server?.state, "stopped")
        XCTAssertEqual(ServingRows.build(slots: [], servers: [stopped], snapshot: .empty).count, 0)
    }

    func testSlotPortHeldByAnotherModelLeavesThatServerItsOwnRow() throws {
        let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/models/owned")
        let squatter = server("/models/squatter", port: slot.port, pid: 70, managed: false)
        let rows = ServingRows.build(slots: [slot], servers: [squatter], snapshot: .empty)
        XCTAssertEqual(rows.count, 2)
        guard case .endpoint(_, let claimed, let service) = rows[0] else { return XCTFail("expected an endpoint row first") }
        XCTAssertNil(claimed)
        XCTAssertNil(service)
        guard case .server(let rowServer, _) = rows[1] else { return XCTFail("expected the squatting server second") }
        XCTAssertEqual(rowServer, squatter)
    }

    func testRowsAreEndpointsThenServersThenServices() {
        let slot = EndpointSlot(enabled: true, port: 8766, modelPath: "/models/owned")
        let owned = server(slot.modelPath, port: slot.port, pid: 10)
        let bare = server("/models/bare", port: 9001, pid: 40)
        let thirdParty = server("/models/ollama", port: 11434, pid: 30, managed: false)
        let rows = ServingRows.build(slots: [slot], servers: [bare, owned], snapshot: snapshot([thirdParty, owned]))
        XCTAssertEqual(rows.map(\.id).map { $0.split(separator: "-").first.map(String.init) ?? "" }, ["endpoint", "server", "service"])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }
}
