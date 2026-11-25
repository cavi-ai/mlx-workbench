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
        ServedModelsSelection.candidates(models: models, slots: slots, query: "").filter { model in
            role.eligibleTaskTypes.contains(model.item.task?.type ?? .textLLM)
        }
    }
}
