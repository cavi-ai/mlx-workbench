import Foundation
import XCTest

@testable import mlx_workbench

/// Spec 09 P4 + Phase 2.3: plan assembly covering chat, vision, embedding,
/// audio, and media roles, authenticated endpoints (Front Door or env-var
/// without raw keys), and local/converted models with safe route identifiers.
final class FleetRouterTests: XCTestCase {
    private let hfPath = "/Users/x/.cache/huggingface/hub/models--pub--coder/snapshots/rev"
    private let localPath = "/Models/local-MLX-4bit"
    private let digest = String(repeating: "a", count: 64)
    private let otherDigest = String(repeating: "b", count: 64)

    private func slot(
        port: Int,
        modelPath: String,
        role: ServingRole?,
        enabled: Bool = true,
        apiKeySHA256: String? = nil,
        id: UUID = UUID()
    ) -> EndpointSlot {
        var s = EndpointSlot(id: id, enabled: enabled, port: port, modelPath: modelPath, role: role, loadOnRequest: apiKeySHA256 != nil ? true : nil)
        s.apiKeySHA256 = apiKeySHA256
        return s
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
        XCTAssertEqual(plan.cliAssignments.count, 1)
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertEqual(plan.targetPath, "/tmp/router.yaml")
    }

    func testTypedAudioMediaAndEmbeddingEndpointsAreRoutedNotSkipped() {
        let audioID = UUID()
        let mediaID = UUID()
        let embedID = UUID()
        let plan = FleetRouter.plan(
            slots: [
                slot(port: 8766, modelPath: hfPath, role: nil, id: audioID),
                slot(port: 8767, modelPath: localPath, role: nil, id: mediaID),
                slot(port: 8768, modelPath: hfPath, role: nil, id: embedID),
            ],
            states: [
                audioID: .running(modelPath: hfPath, port: 8766),
                mediaID: .running(modelPath: localPath, port: 8767),
                embedID: .running(modelPath: hfPath, port: 8768),
            ],
            servers: [
                ServerInfo(path: hfPath, runtime: "tasks", port: 8766, pid: 41, state: "running", taskKinds: ["music_generation", "sound_effects"]),
                ServerInfo(path: localPath, runtime: "tasks", port: 8767, pid: 42, state: "running", taskKinds: ["video_generation"]),
                ServerInfo(path: hfPath, runtime: "tasks", port: 8768, pid: 43, state: "running", taskKinds: ["embedding"]),
            ]
        )
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertEqual(plan.assignments.map(\.routeRole), [.audio, .media, .embedding])
        XCTAssertEqual(plan.assignments.first(where: { $0.routeRole == .media })?.repo, "local-MLX-4bit")
        XCTAssertEqual(plan.cliAssignments.map(\.routeRole), [.embedding])
        XCTAssertEqual(plan.multimodalAssignments.map(\.routeRole), [.audio, .media])
    }

    func testManagedRoutesShareOneCredentialAcrossFrontDoorAndDirectPorts() {
        let frontDoorID = UUID()
        let directID = UUID()
        let frontDoor = FrontDoorSettings(port: 8700, apiKeySHA256: digest)
        let slots = [
            slot(port: 8766, modelPath: hfPath, role: .coding, apiKeySHA256: digest, id: frontDoorID),
            slot(port: 8767, modelPath: hfPath, role: .reasoning, apiKeySHA256: otherDigest, id: directID),
        ]
        let states = [
            frontDoorID: EndpointState.running(modelPath: hfPath, port: 8766),
            directID: .running(modelPath: hfPath, port: 8767),
        ]
        let plan = FleetRouter.plan(slots: slots, states: states, frontDoor: frontDoor,
                                    frontDoorRoutes: ["pub/coder"])
        XCTAssertEqual(plan.cliAssignments.map(\.port), [8700])
        XCTAssertEqual(plan.cliAssignments.map(\.repo), ["pub/coder"])
        XCTAssertEqual(plan.skipped.map(\.routeRole), [.reasoning])

        let reversed = FleetRouter.plan(slots: Array(slots.reversed()), states: states,
                                        frontDoor: frontDoor, frontDoorRoutes: ["pub/coder"])
        XCTAssertEqual(reversed.cliAssignments.map(\.port), [8767])
        XCTAssertEqual(reversed.skipped.map(\.routeRole), [.coding])
    }

    func testFrontDoorWithoutAnAdvertisedRouteKeepsDirectEndpoint() {
        let id = UUID()
        let settings = FrontDoorSettings(port: 8700, apiKeySHA256: digest)
        let endpoint = slot(port: 8766, modelPath: hfPath, role: .coding, apiKeySHA256: digest, id: id)
        for routes: Set<String> in [[], ["other/model"]] {
            let plan = FleetRouter.plan(slots: [endpoint], states: running(id, path: hfPath, port: 8766),
                                        frontDoor: settings, frontDoorRoutes: routes)
            XCTAssertEqual(plan.cliAssignments.first?.port, 8766)
        }
    }

    func testUnassignedChatSlotsAreIgnoredNotSkipped() {
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

    func testFilesystemModelWithoutUpstreamRepoIDIsExcludedFromEngineRender() {
        let id = UUID()
        let plan = FleetRouter.plan(
            slots: [slot(port: 8766, modelPath: localPath, role: .general, id: id)],
            states: running(id, path: localPath, port: 8766)
        )
        XCTAssertTrue(plan.cliAssignments.isEmpty)
        XCTAssertEqual(plan.skipped.map(\.routeRole), [.general])
    }

    func testUnsafeLocalPathsAreRejectedAndSkipped() {
        XCTAssertNil(FleetRouter.safeLocalRouteIdentifier(for: "/Models/../../etc/passwd"))
        XCTAssertNil(FleetRouter.safeLocalRouteIdentifier(for: "/Models/bad\nname"))
        XCTAssertNil(FleetRouter.safeLocalRouteIdentifier(for: "/Models/bad\0name"))
        XCTAssertNil(FleetRouter.safeLocalRouteIdentifier(for: "/Models/a\\b"))
        XCTAssertNil(FleetRouter.safeLocalRouteIdentifier(for: "   "))

        let id = UUID()
        let badPath = "/Models/../../etc/passwd"
        let plan = FleetRouter.plan(
            slots: [slot(port: 8766, modelPath: badPath, role: .coding, id: id)],
            states: running(id, path: badPath, port: 8766)
        )
        XCTAssertTrue(plan.assignments.isEmpty)
        XCTAssertEqual(plan.skipped.count, 1)
        XCTAssertEqual(plan.skipped.first?.routeRole, .coding)
    }

    func testClassifierSlotRoutesFromItsRoleWhenServerReportsNoTaskKinds() {
        let id = UUID()
        let plan = FleetRouter.plan(
            slots: [slot(port: 8766, modelPath: hfPath, role: .classification, id: id)],
            states: running(id, path: hfPath, port: 8766),
            servers: [ServerInfo(path: hfPath, runtime: "tasks", port: 8766, pid: 41, state: "running", taskKinds: nil)]
        )
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertEqual(plan.assignments.map(\.routeRole), [.embedding])
        XCTAssertEqual(plan.assignments.map(\.role), [.classification])
        XCTAssertEqual(plan.assignments.map(\.port), [8766])
    }

    func testStoppedImageAndMeshSlotsGetDistinctSkippedIDs() {
        let plan = FleetRouter.plan(
            slots: [slot(port: 8766, modelPath: hfPath, role: .image),
                    slot(port: 8767, modelPath: localPath, role: .mesh)],
            states: [:]
        )
        XCTAssertEqual(plan.skipped.count, 2)
        XCTAssertEqual(Set(plan.skipped.map(\.id)).count, 2)
    }

    func testMeshSlotRoutesToMediaFromItsRole() {
        let id = UUID()
        let plan = FleetRouter.plan(
            slots: [slot(port: 8767, modelPath: localPath, role: .mesh, id: id)],
            states: running(id, path: localPath, port: 8767),
            servers: [ServerInfo(path: localPath, runtime: "tasks", port: 8767, pid: 42, state: "running", taskKinds: ["transcribe"])]
        )
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertEqual(plan.assignments.map(\.routeRole), [.media])
        XCTAssertEqual(plan.assignments.map(\.port), [8767])
    }
}
