import Foundation

// MARK: - FleetRouter
//
// Role router (spec 09 P4): map fleet-slot roles onto running endpoints via
// `mlx-agent fleet render/apply --port-map`. Pure plan assembly here; the
// agent call lives in WorkbenchAPI, the preview/confirm UI in
// FleetRouterSheet.
//
// Honest boundaries: only running slots are assigned (a role whose endpoint
// is down is reported skipped, never pointed at a dead port), and only
// models with a Hugging Face repo id can be assigned — fleet's model
// vocabulary is publisher/model, so local-path models are skipped with the
// reason shown.

enum FleetRouter {
    struct Assignment: Equatable, Sendable, Identifiable {
        let role: UseCase
        let repo: String
        let port: Int

        var id: String { fleetRole }
        var fleetRole: String { FleetRouter.fleetRoleName(for: role) }
    }

    struct SkippedRole: Equatable, Sendable, Identifiable {
        let role: UseCase
        let reason: String

        var id: String { role.rawValue }
    }

    struct Plan: Equatable, Sendable {
        let assignments: [Assignment]
        let skipped: [SkippedRole]
        let targetPath: String

        var isEmpty: Bool { assignments.isEmpty }
    }

    /// Where the router config lives. Written exclusively through
    /// `fleet apply`, so the file carries fleet's managed header and later
    /// `fleet` runs (app or CLI) can keep managing it; the path is distinct
    /// from any hand-maintained router config, which fleet would refuse.
    static let defaultTargetPath =
        NSHomeDirectory() + "/Library/Application Support/mlx-workbench/fleet-router.yaml"

    /// App UseCase → fleet's canonical role vocabulary.
    static func fleetRoleName(for useCase: UseCase) -> String {
        switch useCase {
        case .coding: return "coding"
        case .generalChat: return "general"
        case .reasoning: return "reasoning"
        case .vision: return "vision"
        }
    }

    static func plan(
        slots: [EndpointSlot],
        states: [UUID: EndpointState],
        targetPath: String = defaultTargetPath
    ) -> Plan {
        var assignments: [Assignment] = []
        var skipped: [SkippedRole] = []
        for slot in slots {
            guard let role = slot.role else { continue }
            guard slot.enabled else {
                skipped.append(SkippedRole(role: role, reason: "endpoint disabled"))
                continue
            }
            guard case .running = states[slot.id] else {
                skipped.append(SkippedRole(role: role, reason: "endpoint not running"))
                continue
            }
            guard let repo = HFRepoID.forPath(slot.modelPath) else {
                skipped.append(SkippedRole(
                    role: role,
                    reason: "no Hugging Face repo id (model lives outside the HF cache)"
                ))
                continue
            }
            assignments.append(Assignment(role: role, repo: repo, port: slot.port))
        }
        return Plan(assignments: assignments, skipped: skipped, targetPath: targetPath)
    }
}
