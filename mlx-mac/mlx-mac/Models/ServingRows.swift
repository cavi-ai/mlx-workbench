import Foundation

/// One served thing: a configured endpoint, a running engine server, or another local service.
enum ServingRow: Identifiable, Equatable {
    case endpoint(slot: EndpointSlot, server: ServerInfo?, service: ServingServiceObservation?)
    case server(ServerInfo, service: ServingServiceObservation?)
    case service(ServingServiceObservation)

    var id: String {
        switch self {
        case .endpoint(let slot, _, _): "endpoint-\(slot.id.uuidString)"
        case .server(let server, _): "server-\(server.id)"
        case .service(let service): "service-\(service.id)"
        }
    }
}

enum ServingRows {
    /// Endpoint rows in fleet order, then running-server rows, then the remaining local services in
    /// snapshot order. A running server or inventory service appears in at most one row.
    static func build(slots: [EndpointSlot], servers: [ServerInfo], snapshot: ServingInventorySnapshot) -> [ServingRow] {
        let running = servers.enumerated().filter { $0.element.state?.lowercased() == "running" }
        var claimedServers = Set<Int>()
        var claimedServices = Set<String>()
        var rows: [ServingRow] = []

        for slot in slots {
            let match = running.first {
                !claimedServers.contains($0.offset) && $0.element.port == slot.port
                    && $0.element.matchesUnadaptedModel(slot.modelPath)
            }
            if let match { claimedServers.insert(match.offset) }
            let service = ServingInventoryPresentation.service(for: slot, in: snapshot)
            if let service { claimedServices.insert(service.id) }
            rows.append(.endpoint(slot: slot, server: match?.element, service: service))
        }

        let managed = ServingInventoryPresentation.localServices(snapshot).filter(\.isWorkbenchManaged)
        for (index, server) in running where !claimedServers.contains(index) {
            let candidates = managed.filter { !claimedServices.contains($0.id) && server.port != nil && $0.server?.port == server.port }
            let service = candidates.first { $0.server?.modelIdentity == server.modelIdentity } ?? candidates.first
            if let service { claimedServices.insert(service.id) }
            rows.append(.server(server, service: service))
        }

        for service in ServingInventoryPresentation.localServices(snapshot) where !claimedServices.contains(service.id) {
            rows.append(.service(service))
        }
        return rows
    }
}
