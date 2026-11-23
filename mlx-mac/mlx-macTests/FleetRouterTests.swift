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
        role: UseCase?,
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

    func testAuthenticatedEndpointUsesFrontDoorWhenKeyMatchesOrEnvVarOtherwise() {
        let frontDoorID = UUID()
        let envAuthID = UUID()
        let frontDoor = FrontDoorSettings(port: 8700, apiKeySHA256: digest)
        let plan = FleetRouter.plan(
            slots: [
                slot(port: 8766, modelPath: hfPath, role: .coding, apiKeySHA256: digest, id: frontDoorID),
                slot(port: 8767, modelPath: hfPath, role: .reasoning, apiKeySHA256: otherDigest, id: envAuthID),
            ],
            states: [
                frontDoorID: .running(modelPath: hfPath, port: 8766),
                envAuthID: .running(modelPath: hfPath, port: 8767),
            ],
            frontDoor: frontDoor
        )
        XCTAssertTrue(plan.skipped.isEmpty)
        let coding = plan.assignments.first(where: { $0.routeRole == .coding })
        let reasoning = plan.assignments.first(where: { $0.routeRole == .reasoning })
        XCTAssertEqual(coding?.authMode, .frontDoor(port: 8700))
        XCTAssertEqual(coding?.port, 8700)
        XCTAssertEqual(reasoning?.authMode, .envVar(name: "MLX_AGENT_LOCAL_API_KEY"))
        XCTAssertEqual(reasoning?.port, 8767)
        // Never emit raw keys or digests into route guidance.
        XCTAssertFalse(coding?.authMode.guidance?.contains(digest) ?? false)
        XCTAssertFalse(reasoning?.authMode.guidance?.contains(otherDigest) ?? false)

        // When frontDoorRoutes is supplied and does not advertise the model, do not switch ports to Front Door.
        let unadvertisedPlan = FleetRouter.plan(
            slots: [slot(port: 8766, modelPath: hfPath, role: .coding, apiKeySHA256: digest, id: frontDoorID)],
            states: [frontDoorID: .running(modelPath: hfPath, port: 8766)],
            frontDoor: frontDoor,
            frontDoorRoutes: ["other/model"]
        )
        XCTAssertEqual(unadvertisedPlan.assignments.first?.port, 8766)
        XCTAssertEqual(unadvertisedPlan.assignments.first?.authMode, .envVar(name: "MLX_AGENT_LOCAL_API_KEY"))
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

    func testRunningLocalPathModelGetsSafeRouteIdentifier() {
        let id = UUID()
        let plan = FleetRouter.plan(
            slots: [slot(port: 8766, modelPath: localPath, role: .generalChat, id: id)],
            states: running(id, path: localPath, port: 8766)
        )
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertEqual(plan.assignments.count, 1)
        XCTAssertEqual(plan.assignments[0].repo, "local-MLX-4bit")
        XCTAssertTrue(plan.assignments[0].isLocalRoute)
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
        XCTAssertTrue(plan.skipped[0].reason.contains("unsafe"))
    }

    func testFleetRoleVocabulary() {
        XCTAssertEqual(FleetRouter.fleetRoleName(for: .coding), "coding")
        XCTAssertEqual(FleetRouter.fleetRoleName(for: .generalChat), "general")
        XCTAssertEqual(FleetRouter.fleetRoleName(for: .reasoning), "reasoning")
        XCTAssertEqual(FleetRouter.fleetRoleName(for: .vision), "vision")
        XCTAssertEqual(FleetRouter.RouteRole.audio.rawValue, "audio")
        XCTAssertEqual(FleetRouter.RouteRole.media.rawValue, "media")
        XCTAssertEqual(FleetRouter.RouteRole.embedding.rawValue, "embedding")
    }
}
