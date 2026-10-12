import Foundation

// MARK: - Wiring models
//
// Cross-client Wiring (premium spec 02): point installed clients at a locally
// served model by writing each client's own config file — atomically, with
// backup and rollback. The app never becomes a runtime authority for any
// client; it only writes the clients' native config formats.

/// What clients get pointed at. Sourced from authoritative serve status
/// (or later the always-on endpoint), never from free-text guesses.
struct WireEndpoint: Equatable, Sendable {
    let baseURL: String        // e.g. http://127.0.0.1:8766/v1
    let modelName: String

    init(baseURL: String, modelName: String) {
        self.baseURL = baseURL
        self.modelName = modelName
    }

    init?(server: ServerInfo) {
        guard server.state?.lowercased() == "running", let port = server.port, (1...65535).contains(port),
              !server.modelIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.init(baseURL: "http://127.0.0.1:\(port)/v1", modelName: server.modelIdentity)
    }
}

struct ClientWiringRequest: Equatable {
    let modelPath: String
    let preferredPort: Int?
}

enum ClientWiringSelection {
    static func matchingServers(request: ClientWiringRequest, servers: [ServerInfo]) -> [ServerInfo] {
        servers.filter { WireEndpoint(server: $0) != nil && HFRepoID.matches($0.modelIdentity, request.modelPath)
            && (request.preferredPort == nil || $0.port == request.preferredPort) }
    }

    static func sameServer(_ before: ServerInfo, _ current: ServerInfo) -> Bool {
        WireEndpoint(server: current) != nil && before.modelIdentity == current.modelIdentity && before.port == current.port
            && before.pid == current.pid && before.runtime == current.runtime
            && before.startedAt == current.startedAt && before.receipt == current.receipt
    }
}

struct ClientInstallation: Equatable, Sendable {
    let clientID: String
    let displayName: String
    /// Absolute config path; nil for advisory-only clients.
    let configPath: String?
    /// Advisory clients own their state (LM Studio, Ollama); the app shows
    /// guidance instead of writing files.
    let advisoryOnly: Bool
    let advisoryNote: String?
}

// MARK: - Current endpoint reading

/// A local endpoint one client config points at: the base URL and the model names beside it.
struct ClientConfigEntry: Equatable, Sendable {
    let baseURL: String
    let models: [String]
}

/// What one client's allowlisted config file says, never what the client uses.
/// Only scheme, host, port, path and model names leave the reader.
enum ClientConfigReading: Equatable, Sendable {
    case fileAbsent
    case unreadable(String)
    case noWorkbenchEntry
    case entries([ClientConfigEntry])
    /// A Workbench entry exists but the client's default model selects another provider.
    case notDefault([ClientConfigEntry])
}

struct ClientConfigStatus: Equatable, Sendable {
    let reading: ClientConfigReading
    /// The config path is a symbolic link; a read follows it, a write refuses it.
    let isLinked: Bool
}

enum ClientEndpointURL {
    /// The port of a base URL a Workbench server can serve: http, 127.0.0.1 or localhost,
    /// an explicit port, path /v1 or /v1/, and no query, fragment or userinfo.
    static func port(of baseURL: String) -> Int? {
        guard let parts = URLComponents(string: baseURL),
              parts.scheme == "http",
              let host = parts.host, host == "127.0.0.1" || host == "localhost",
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path == "/v1" || parts.path == "/v1/",
              let port = parts.port, (1...65535).contains(port) else { return nil }
        return port
    }
}

/// How one config entry relates to the running Workbench servers.
enum ClientEndpointMatch: Equatable, Sendable {
    case live(port: Int, model: String)
    case noWorkbenchServer(port: Int)
    case otherModel(port: Int, configured: String, serving: String)
    case ambiguous(port: Int)

    var port: Int {
        switch self {
        case .live(let port, _), .noWorkbenchServer(let port),
             .otherModel(let port, _, _), .ambiguous(let port): return port
        }
    }

    /// Exactly one running server on the entry's port serving a model the entry names is live.
    static func match(_ entry: ClientConfigEntry, servers: [ServerInfo]) -> ClientEndpointMatch? {
        guard let port = ClientEndpointURL.port(of: entry.baseURL) else { return nil }
        let running = servers.filter { $0.state?.lowercased() == "running" && $0.port == port }
        switch running.count {
        case 0: return .noWorkbenchServer(port: port)
        case 1:
            let serving = running[0].modelIdentity
            if entry.models.contains(serving) { return .live(port: port, model: serving) }
            return .otherModel(port: port, configured: entry.models.first ?? "", serving: serving)
        default: return .ambiguous(port: port)
        }
    }
}

struct ClientEditPlan: Equatable, Identifiable, Sendable {
    let clientID: String
    let displayName: String
    let configPath: String
    /// Current file contents; nil means the file will be created.
    let before: String?
    let after: String
    let summary: String
    /// True when the write normalizes/reformats the file (e.g. JSONC → JSON).
    /// Surfaced in the UI so the user consents to reformatting.
    let rewritesFile: Bool

    var id: String { clientID }

    /// Unified line diff with secret-looking values redacted — display only;
    /// `after` remains the full truth for the write.
    var redactedDiff: [DiffLine] {
        LineDiff.diff(
            before: SecretRedaction.redact(before ?? ""),
            after: SecretRedaction.redact(after)
        )
    }
}

struct ClientEditReceipt: Codable, Equatable, Sendable {
    let clientID: String
    let configPath: String
    let backupPath: String?
    /// SHA-256 of the contents written when this wiring created the file;
    /// nil when the file existed before or the receipt predates this field.
    var createdFileSHA256: String? = nil
    let appliedAt: Date
}

struct WiringTransaction: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let previewHash: String
    let endpointBaseURL: String
    let modelName: String
    let appliedAt: Date
    var receipts: [ClientEditReceipt]
    /// Clients skipped or failed during apply, with the reason.
    var failures: [String]
    var rolledBackAt: Date?
}

// MARK: - Line diff

enum DiffLineKind: Equatable, Sendable {
    case context
    case added
    case removed
}

struct DiffLine: Equatable, Sendable {
    let kind: DiffLineKind
    let text: String
}

/// Minimal LCS line diff — config files are small, so the quadratic DP is fine.
enum LineDiff {
    static func diff(before: String, after: String) -> [DiffLine] {
        let a = before.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = after.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var lines: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                lines.append(DiffLine(kind: .context, text: a[i]))
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                lines.append(DiffLine(kind: .removed, text: a[i]))
                i += 1
            } else {
                lines.append(DiffLine(kind: .added, text: b[j]))
                j += 1
            }
        }
        while i < a.count { lines.append(DiffLine(kind: .removed, text: a[i])); i += 1 }
        while j < b.count { lines.append(DiffLine(kind: .added, text: b[j])); j += 1 }
        return lines
    }
}

// MARK: - Secret redaction

/// Display-side redaction for diffs: any line assigning a key/token/secret
/// value shows `•••` instead of the value.
enum SecretRedaction {
    private static let sensitiveMarkers = ["api_key", "apikey", "api-key", "token", "secret"]

    static func redact(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .map(redactLine)
            .joined(separator: "\n")
    }

    private static func redactLine(_ line: String) -> String {
        let lowered = line.lowercased()
        guard sensitiveMarkers.contains(where: { lowered.contains($0) }),
              let colon = line.firstIndex(of: ":") else { return line }
        let valueStart = line.index(after: colon)
        return String(line[..<valueStart]) + " \"•••\""
    }
}
