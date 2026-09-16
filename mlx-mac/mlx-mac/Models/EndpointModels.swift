import Foundation

// MARK: - Endpoint models
//
// Always-on Endpoint (premium spec 06): a stable loopback port that always
// serves the chosen model, so clients wired via Cross-client Wiring never
// hit a dead port. The supervisor reconciles desired state against
// authoritative serve status; receipts remain the authority.

struct EndpointConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var port: Int
    var modelPath: String
    /// Whether the login LaunchAgent (boot persistence) is installed.
    var installedAtLogin: Bool

    static let defaultPort = 8766

    static var disabled: EndpointConfig {
        EndpointConfig(enabled: false, port: defaultPort, modelPath: "", installedAtLogin: false)
    }
}

// MARK: - Fleet models (spec 09)

/// One supervised endpoint: a model on its own stable loopback port.
/// `role == nil` is first-class — an unassigned stable port, exactly like
/// the original single endpoint.
struct EndpointSlot: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var enabled: Bool
    var port: Int
    var modelPath: String
    var role: UseCase?

    init(id: UUID = UUID(), enabled: Bool, port: Int, modelPath: String, role: UseCase? = nil) {
        self.id = id
        self.enabled = enabled
        self.port = port
        self.modelPath = modelPath
        self.role = role
    }
}

struct EndpointFleetConfig: Codable, Equatable, Sendable {
    var slots: [EndpointSlot]
    /// Whether the login LaunchAgent (boot persistence) is installed.
    var installedAtLogin: Bool

    static let maxSlots = 4

    static var empty: EndpointFleetConfig {
        EndpointFleetConfig(slots: [], installedAtLogin: false)
    }
}

/// Store-layer invariants for the fleet (spec 09): few slots, distinct
/// ports, one slot per role, sane ports.
enum EndpointFleetValidation: Error, Equatable {
    case tooManySlots(Int)
    case invalidPort(Int)
    case duplicatePort(Int)
    case duplicateRole(UseCase)
}

extension EndpointFleetValidation: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .tooManySlots(let count):
            return "The fleet is capped at \(EndpointFleetConfig.maxSlots) endpoints (got \(count))."
        case .invalidPort(let port):
            return "Port \(port) is outside 1–65535."
        case .duplicatePort(let port):
            return "Port \(port) is already used by another endpoint."
        case .duplicateRole(let role):
            return "Role \(role.title) is already assigned to another endpoint."
        }
    }
}

extension EndpointFleetConfig {
    /// Throws the first violated invariant; returns the config otherwise.
    @discardableResult
    func validated() throws -> EndpointFleetConfig {
        if slots.count > EndpointFleetConfig.maxSlots {
            throw EndpointFleetValidation.tooManySlots(slots.count)
        }
        var seenPorts = Set<Int>()
        var seenRoles = Set<UseCase>()
        for slot in slots {
            guard (1...65535).contains(slot.port) else {
                throw EndpointFleetValidation.invalidPort(slot.port)
            }
            guard seenPorts.insert(slot.port).inserted else {
                throw EndpointFleetValidation.duplicatePort(slot.port)
            }
            if let role = slot.role {
                guard seenRoles.insert(role).inserted else {
                    throw EndpointFleetValidation.duplicateRole(role)
                }
            }
        }
        return self
    }
}


enum EndpointState: Equatable, Sendable {
    case disabled
    case starting
    case running(modelPath: String, port: Int)
    /// The configured port is serving a different model than configured.
    case modelMismatch(servedModel: String, port: Int)
    /// Desired on but the server is down; restart attempts exhausted.
    case degraded(reason: String)
    /// Desired on, server not yet confirmed running (start requested).
    case waitingForServer

    var summary: String {
        switch self {
        case .disabled: return "Disabled"
        case .starting: return "Starting…"
        case .running(let modelPath, let port):
            return "Running \(URL(fileURLWithPath: modelPath).lastPathComponent) on :\(port)"
        case .modelMismatch(let served, let port):
            return "Port \(port) is serving a different model (\(served))"
        case .degraded(let reason): return "Degraded: \(reason)"
        case .waitingForServer: return "Waiting for server…"
        }
    }
}
