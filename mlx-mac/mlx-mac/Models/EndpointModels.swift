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
