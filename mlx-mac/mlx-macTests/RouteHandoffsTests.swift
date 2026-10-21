import XCTest

@testable import mlx_workbench

final class RouteHandoffsTests: XCTestCase {
    func testFinishingAnOlderRequestKeepsTheNewerOneAndKindsStayIndependent() {
        var handoffs = RouteHandoffs()
        let older = LibraryRevealRequest(modelPath: "/models/a")
        let newer = LibraryRevealRequest(modelPath: "/models/a")
        let wiring = ClientWiringRequest(modelPath: "/models/a", preferredPort: 8080)

        handoffs.send(older, as: .revealModel)
        handoffs.send(wiring, as: .wireClient)
        handoffs.send(newer, as: .revealModel)
        handoffs.finish(older, as: .revealModel)
        XCTAssertEqual(handoffs[.revealModel], newer, "A late finish must not drop a newer request")
        XCTAssertEqual(handoffs[.wireClient], wiring)

        handoffs.finish(newer, as: .revealModel)
        XCTAssertNil(handoffs[.revealModel])
        XCTAssertEqual(handoffs.take(.wireClient), wiring)
        XCTAssertNil(handoffs.take(.wireClient))
    }

    @MainActor
    func testHostedModelsRequestWithoutAHostIsTakenOnceAndLeavesOtherKinds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handoffs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = AppHost(catalogStore: CatalogStore(appSupportDirectory: { root }), config: Config.defaults())
        let importRequest = WorkflowReportImportRequest()
        host.handoffs.send(importRequest, as: .importWorkflowReport)
        host.handoffs.send(HostedModelsRequest(), as: .openHostedModels)
        XCTAssertNil(try host.takeHostedModelsHost())
        XCTAssertNil(host.handoffs[.openHostedModels], "A request without a host is still taken once")
        XCTAssertEqual(host.handoffs[.importWorkflowReport], importRequest)
    }
}
