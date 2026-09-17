import Foundation
import XCTest

@testable import mlx_workbench

/// Spec 09 P4: plan assembly — only running, repo-identifiable slots are
/// assigned; everything else is reported skipped with a reason.
final class FleetRouterTests: XCTestCase {
    private let hfPath = "/Users/x/.cache/huggingface/hub/models--pub--coder/snapshots/rev"
    private let localPath = "/Models/local-MLX-4bit"

    private func slot(
        port: Int,
        modelPath: String,
        role: UseCase?,
        enabled: Bool = true,
        id: UUID = UUID()
    ) -> EndpointSlot {
        EndpointSlot(id: id, enabled: enabled, port: port, modelPath: modelPath, role: role)
    }

    private func running(_ id: UUID, path: String, port: Int) -> [UUID: EndpointState] {
        [id: .running(modelPath: path, port: port)]
    }

    func testRunningSlotWithRepoIDIsAssigned() {
        let id = UUID()
        let plan = FleetRouter.plan(
            slots: [slot(port: 8766, modelPath: hfPath, role: .coding, id: id)],
            states: running(id, path: hfPath, port: 8766),
            targetPath: "/tmp/router.yaml"
        )
        XCTAssertEqual(plan.assignments, [
            FleetRouter.Assignment(role: .coding, repo: "pub/coder", port: 8766),
        ])
        XCTAssertEqual(plan.assignments.first?.fleetRole, "coding")
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertEqual(plan.targetPath, "/tmp/router.yaml")
    }

    func testUnassignedSlotsAreIgnoredNotSkipped() {
        let id = UUID()
        let plan = FleetRouter.plan(
            slots: [slot(port: 8766, modelPath: hfPath, role: nil, id: id)],
            states: running(id, path: hfPath, port: 8766)
        )
        XCTAssertTrue(plan.assignments.isEmpty)
        XCTAssertTrue(plan.skipped.isEmpty)
    }

    func testDisabledAndNotRunningRolesAreSkippedWithReasons() {
        let disabledID = UUID()
        let downID = UUID()
        let plan = FleetRouter.plan(
            slots: [
                slot(port: 8766, modelPath: hfPath, role: .coding, enabled: false, id: disabledID),
                slot(port: 8767, modelPath: hfPath, role: .reasoning, id: downID),
            ],
            states: [downID: .waitingForServer]
        )
        XCTAssertTrue(plan.assignments.isEmpty)
        XCTAssertEqual(plan.skipped.count, 2)
        XCTAssertEqual(plan.skipped.first(where: { $0.role == .coding })?.reason, "endpoint disabled")
        XCTAssertEqual(plan.skipped.first(where: { $0.role == .reasoning })?.reason, "endpoint not running")
    }

    func testRunningLocalPathModelIsSkippedForMissingRepoID() {
        let id = UUID()
        let plan = FleetRouter.plan(
            slots: [slot(port: 8766, modelPath: localPath, role: .generalChat, id: id)],
            states: running(id, path: localPath, port: 8766)
        )
        XCTAssertTrue(plan.assignments.isEmpty)
        XCTAssertEqual(plan.skipped.count, 1)
        XCTAssertTrue(plan.skipped[0].reason.contains("repo id"))
    }

    func testFleetRoleVocabulary() {
        XCTAssertEqual(FleetRouter.fleetRoleName(for: .coding), "coding")
        XCTAssertEqual(FleetRouter.fleetRoleName(for: .generalChat), "general")
        XCTAssertEqual(FleetRouter.fleetRoleName(for: .reasoning), "reasoning")
        XCTAssertEqual(FleetRouter.fleetRoleName(for: .vision), "vision")
    }
}
