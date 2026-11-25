import Foundation

/// Role-first grouping of the Serving list: one row per role, custom endpoints, then other servers.
enum ServingRolesPresentation {
    struct RoleRow: Identifiable, Equatable {
        let role: ServingRole
        let slot: EndpointSlot?
        let row: ServingRow?
        let port: Int

        var id: String { "role-\(role.rawValue)" }
        var title: String { role.title }
        var isAssigned: Bool { slot != nil }
        var portText: String { ":\(port)" }
        /// Shown in place of a model name while the role has no endpoint.
        var unassignedText: String { "Not assigned - :\(port)" }
    }

    static let workbenchAPITitle = "Workbench API"
    static let workbenchAPICaption = "Apps call one address and pick a model by name. Each role keeps its own port."

    /// The first Serving row: the shared address and how many endpoints route through it.
    struct WorkbenchAPIRow: Equatable {
        let address: String
        let stateText: String
        let routedCount: Int
        let isRunning: Bool
        let isConfigured: Bool

        var title: String { ServingRolesPresentation.workbenchAPITitle }
        var routedText: String { routedCount == 1 ? "1 model routed" : "\(routedCount) models routed" }
        var startTitle: String { isConfigured ? "Start" : "Create key and start" }
        var stopTitle: String { "Stop" }
        var copyAddressTitle: String { "Copy address" }
        var keyTitle: String { "Workbench key…" }
        var setupTitle: String { "Set up an app…" }
    }

    /// Routed slots are those whose key digest equals the Workbench API digest.
    static func routedCount(slots: [EndpointSlot], digest: String?) -> Int {
        guard let digest else { return 0 }
        return slots.filter { $0.apiKeySHA256 == digest }.count
    }

    static func workbenchAPIRow(settings: FrontDoorSettings?, isRunning: Bool, slots: [EndpointSlot]) -> WorkbenchAPIRow {
        let port = settings?.port ?? FrontDoorEditor.defaultPort
        return WorkbenchAPIRow(address: "http://127.0.0.1:\(port)/v1",
                               stateText: isRunning ? "Running" : settings == nil ? "Not set up" : "Stopped",
                               routedCount: routedCount(slots: slots, digest: settings?.apiKeySHA256),
                               isRunning: isRunning, isConfigured: settings != nil)
    }

    /// One row per role in catalog order; a role's endpoint is the slot that carries it.
    static func roleRows(slots: [EndpointSlot], rows: [ServingRow]) -> [RoleRow] {
        ServingRole.allCases.map { role in
            let slot = slots.first { $0.role == role }
            let row = slot.flatMap { slot in
                rows.first { if case .endpoint(let candidate, _, _) = $0 { return candidate.id == slot.id } else { return false } }
            }
            return RoleRow(role: role, slot: slot, row: row, port: slot?.port ?? role.defaultPort)
        }
    }

    /// Endpoint slots without a role, plus any further slot of a role already shown in its role row.
    static func customRows(_ rows: [ServingRow]) -> [ServingRow] {
        var shown = Set<ServingRole>()
        return rows.filter { row in
            guard case .endpoint(let slot, _, _) = row else { return false }
            guard let role = slot.role else { return true }
            return !shown.insert(role).inserted
        }
    }

    /// The role title shown beside a custom row that carries a role.
    static func roleLabel(_ row: ServingRow) -> String? {
        if case .endpoint(let slot, _, _) = row { return slot.role?.title }
        return nil
    }

    /// Servers and inventory entries that no endpoint slot owns.
    static func otherRows(_ rows: [ServingRow]) -> [ServingRow] {
        rows.filter { if case .endpoint = $0 { return false } else { return true } }
    }

    static func othersTitle(count: Int) -> String { "Other servers on this Mac (\(count))" }

    /// Ready Library models the role accepts that no endpoint already serves.
    static func candidates(for role: ServingRole, models: [LibraryModel], slots: [EndpointSlot]) -> [LibraryModel] {
        ServedModelsSelection.candidates(models: models, slots: slots, query: "").filter { accepts(role, $0) }
    }

    /// Whether the role's task types include the model's task.
    static func accepts(_ role: ServingRole, _ model: LibraryModel) -> Bool {
        role.eligibleTaskTypes.contains(model.item.task?.type ?? .textLLM)
    }
}
