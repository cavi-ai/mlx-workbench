import SwiftUI

// MARK: - Layout

/// Clients' width thresholds, derived from the width the page is offered and built
/// on the Run content width, never from measured children.
struct ClientsLayout: Equatable {
    enum BoardMode: Equatable {
        /// Endpoints, a drawn connector gap and clients side by side.
        case twoColumn
        /// Endpoints as group headers with their clients indented beneath.
        case tree
    }

    /// The page content width.
    private(set) var boardWidth: CGFloat
    /// The width inside the preview surface.
    private(set) var innerWidth: CGFloat
    private(set) var boardMode: BoardMode = .twoColumn
    private(set) var wrapsPreviewHeader = false
    private(set) var wrapsActions = false

    static let assumedViewportWidth = WorkbenchSize.assumedContentWidth + WorkbenchSpacing.pageInset * 2

    /// A compact layout flips back to wide only once the width clears the threshold by the hysteresis.
    static func isCompact(width: CGFloat, threshold: CGFloat, wasCompact: Bool) -> Bool {
        width < (wasCompact ? threshold + WorkbenchSize.Clients.hysteresis : threshold)
    }

    init(viewportWidth: CGFloat = Self.assumedViewportWidth, previous: ClientsLayout? = nil) {
        let raw = RunLayout(viewportWidth: viewportWidth).innerWidth
        innerWidth = max(raw, 0)
        boardWidth = max(raw + WorkbenchSize.Clients.surfaceChrome, 0)
        let tree = Self.isCompact(
            width: boardWidth, threshold: WorkbenchSize.Clients.boardThreshold,
            wasCompact: previous?.boardMode == .tree
        )
        boardMode = tree ? .tree : .twoColumn
        wrapsPreviewHeader = Self.isCompact(
            width: innerWidth, threshold: WorkbenchSize.Clients.previewHeaderThreshold,
            wasCompact: previous?.wrapsPreviewHeader ?? false
        )
        wrapsActions = Self.isCompact(
            width: boardWidth, threshold: WorkbenchSize.Clients.actionsThreshold,
            wasCompact: previous?.wrapsActions ?? false
        )
    }
}

// MARK: - Rows and lines

enum ClientsTone: Equatable {
    case live
    case muted
    case warning
    case pending
}

/// An endpoint on the board: a running Workbench server, or the port a client file names with none running.
struct ClientsEndpointRow: Equatable, Identifiable {
    enum Kind: Equatable { case running, ghost }

    let id: String
    let kind: Kind
    /// The picker's name for a running server; empty for a ghost.
    let name: String
    let port: Int?
    /// The full model identity of a running server.
    let identity: String?
    let isSelected: Bool

    var ghostText: String { ":\(port.map(String.init) ?? "?") · No Workbench server" }

    var accessibilityLabel: String {
        switch kind {
        case .running: return "\(name), port \(port.map(String.init) ?? "unknown")\(isSelected ? ", selected" : "")"
        case .ghost: return "Port \(port.map(String.init) ?? "unknown"), no Workbench server"
        }
    }
}

enum ClientsLineKind: Equatable {
    case live
    case noWorkbenchServer
    case otherModel
    case notDefault
    case pending
}

/// A line from one client to one endpoint row. Every line has both anchors on the board.
struct ClientsLine: Equatable {
    let clientID: String
    let endpointID: String
    let kind: ClientsLineKind

    var tone: ClientsTone {
        switch kind {
        case .live: return .live
        case .noWorkbenchServer, .otherModel, .notDefault: return .muted
        case .pending: return .pending
        }
    }

    /// Live is solid; every other state is dashed.
    var isDashed: Bool { kind != .live }
}

struct ClientsStateText: Equatable {
    let text: String
    let tone: ClientsTone
}

struct ClientsClientRow: Equatable, Identifiable {
    let id: String
    let name: String
    let fileName: String?
    let path: String?
    let symbol: String
    let states: [ClientsStateText]
    let lines: [ClientsLine]
    /// For each line, the index of the state text that describes it.
    let lineStates: [Int]
    let help: String
    let isAdvisory: Bool

    var accessibilityLabel: String {
        ([name] + (fileName.map { [$0] } ?? []) + states.map(\.text)).joined(separator: ", ")
    }
}

/// A line with the state text it ends at.
struct ClientsPlacedLine: Equatable {
    let line: ClientsLine
    let stateIndex: Int
}

/// What the endpoint column shows before any endpoint row: nothing, the loading placeholder, or the no-server prompt.
enum ClientsEndpointHeader: Equatable {
    case none
    case readingStatus
    case noServer
}

/// One endpoint with the clients that point at it, for the narrow board.
struct ClientsTreeGroup: Equatable, Identifiable {
    struct Child: Equatable, Identifiable {
        let client: ClientsClientRow
        let line: ClientsLine
        var id: String { client.id }
    }

    let endpoint: ClientsEndpointRow
    let children: [Child]
    var id: String { endpoint.id }
}

// MARK: - Presentation

struct ClientsPresentation: Equatable {
    static let notConnectedCaption = "Not connected"

    let endpoints: [ClientsEndpointRow]
    let clients: [ClientsClientRow]
    /// False until the current activation's first serve status has returned.
    let hasServerStatus: Bool

    static let endpointSymbol = "server.rack"

    var lines: [ClientsLine] { clients.flatMap(\.lines) }
    var placedLines: [ClientsPlacedLine] {
        clients.flatMap { client in
            zip(client.lines, client.lineStates).map { ClientsPlacedLine(line: $0, stateIndex: $1) }
        }
    }
    var hasRunningServer: Bool { endpoints.contains { $0.kind == .running } }

    var endpointHeader: ClientsEndpointHeader {
        if hasRunningServer { return .none }
        return hasServerStatus ? .noServer : .readingStatus
    }

    var treeGroups: [ClientsTreeGroup] {
        endpoints.map { endpoint in
            ClientsTreeGroup(endpoint: endpoint, children: clients.compactMap { client in
                client.lines.first { $0.endpointID == endpoint.id }.map { ClientsTreeGroup.Child(client: client, line: $0) }
            })
        }
    }

    var unconnectedClients: [ClientsClientRow] { clients.filter { $0.lines.isEmpty && !$0.isAdvisory } }
    var advisoryClients: [ClientsClientRow] { clients.filter(\.isAdvisory) }

    static func make(
        installations: [ClientInstallation],
        readings: [String: ClientConfigStatus],
        servers: [ServerInfo],
        selectedServerID: String?,
        pendingTargetID: String?,
        plannedClientIDs: Set<String>,
        hasServerStatus: Bool = true
    ) -> ClientsPresentation {
        let running = servers.filter { $0.state?.lowercased() == "running" }
        var ghostPorts: [Int] = []

        func endpointID(for port: Int) -> String? {
            let onPort = running.filter { $0.port == port }
            switch onPort.count {
            case 0:
                if !ghostPorts.contains(port) { ghostPorts.append(port) }
                return ghostID(port)
            case 1: return onPort[0].id
            default: return nil
            }
        }

        var rows: [ClientsClientRow] = []
        for installation in installations {
            if installation.advisoryOnly {
                rows.append(ClientsClientRow(
                    id: installation.clientID, name: installation.displayName, fileName: nil, path: nil,
                    symbol: symbol(for: installation.clientID),
                    states: [ClientsStateText(text: "Manages its own models", tone: .muted)], lines: [], lineStates: [],
                    help: installation.advisoryNote ?? "Advisory only", isAdvisory: true
                ))
                continue
            }
            let path = installation.configPath
            let file = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "config file"
            var states: [ClientsStateText] = []
            var lines: [ClientsLine] = []
            var lineStates: [Int] = []
            let status = readings[installation.clientID]

            func addLine(_ endpointID: String, _ kind: ClientsLineKind, state: Int) {
                lines.append(ClientsLine(clientID: installation.clientID, endpointID: endpointID, kind: kind))
                lineStates.append(state)
            }

            switch status?.reading {
            case .none:
                states = [ClientsStateText(text: "Reading \(file)…", tone: .muted)]
            case .fileAbsent:
                states = [ClientsStateText(text: "\(file) not created yet", tone: .muted)]
            case .unreadable(let reason):
                states = [ClientsStateText(text: "Can't read \(file): \(reason)", tone: .warning)]
            case .noWorkbenchEntry:
                states = [ClientsStateText(text: "No Workbench entry in \(file)", tone: .muted)]
            case .notDefault(let entries):
                states = [ClientsStateText(text: "Workbench entry present; the default model is another provider", tone: .muted)]
                for entry in entries.prefix(WorkbenchSize.Clients.maximumLines) {
                    guard let port = ClientEndpointURL.port(of: entry.baseURL), let target = endpointID(for: port) else { continue }
                    addLine(target, .notDefault, state: 0)
                }
            case .entries(let entries):
                for entry in entries.prefix(WorkbenchSize.Clients.maximumLines) {
                    guard let match = ClientEndpointMatch.match(entry, servers: running) else { continue }
                    let port = match.port
                    let target = endpointID(for: port)
                    switch match {
                    case .live(_, let model):
                        states.append(ClientsStateText(text: "\(model) on :\(port)", tone: .live))
                        if let target { addLine(target, .live, state: states.count - 1) }
                    case .noWorkbenchServer:
                        states.append(ClientsStateText(text: "No Workbench server on :\(port)", tone: .muted))
                        if let target { addLine(target, .noWorkbenchServer, state: states.count - 1) }
                    case .otherModel(_, let configured, let serving):
                        let named = configured.isEmpty ? "no model" : configured
                        states.append(ClientsStateText(text: "Configured for \(named); :\(port) serves \(serving)", tone: .warning))
                        if let target { addLine(target, .otherModel, state: states.count - 1) }
                    case .ambiguous:
                        states.append(ClientsStateText(text: "Several servers on :\(port)", tone: .warning))
                    }
                }
                if entries.count > WorkbenchSize.Clients.maximumLines {
                    states.append(ClientsStateText(text: "+\(entries.count - WorkbenchSize.Clients.maximumLines) more", tone: .muted))
                }
                if states.isEmpty { states = [ClientsStateText(text: "No Workbench entry in \(file)", tone: .muted)] }
            }

            var reviewedIdentity: String?
            if let pendingTargetID, plannedClientIDs.contains(installation.clientID),
               !lines.contains(where: { $0.endpointID == pendingTargetID }),
               let server = running.first(where: { $0.id == pendingTargetID }) {
                states.append(ClientsStateText(
                    text: "Preview points \(file) at :\(server.port.map(String.init) ?? "?")", tone: .pending
                ))
                addLine(pendingTargetID, .pending, state: states.count - 1)
                reviewedIdentity = server.modelIdentity
            }
            if status?.isLinked == true, status?.reading != .fileAbsent {
                states.append(ClientsStateText(text: "Linked file; Workbench won't write through it", tone: .muted))
            }
            let help = ([path ?? file] + states.map(\.text) + (reviewedIdentity.map { ["Reviewed model: \($0)"] } ?? []))
                .joined(separator: "\n")
            rows.append(ClientsClientRow(
                id: installation.clientID, name: installation.displayName, fileName: file, path: path,
                symbol: symbol(for: installation.clientID), states: states, lines: lines, lineStates: lineStates,
                help: help, isAdvisory: false
            ))
        }

        var endpoints = running.sorted { ($0.port ?? 0) < ($1.port ?? 0) }.map { server in
            ClientsEndpointRow(
                id: server.id, kind: .running, name: URL(fileURLWithPath: server.modelIdentity).lastPathComponent,
                port: server.port, identity: server.modelIdentity, isSelected: server.id == selectedServerID
            )
        }
        endpoints += ghostPorts.sorted().map {
            ClientsEndpointRow(id: ghostID($0), kind: .ghost, name: "", port: $0, identity: nil, isSelected: false)
        }
        return ClientsPresentation(endpoints: endpoints, clients: rows, hasServerStatus: hasServerStatus)
    }

    static func ghostID(_ port: Int) -> String { "ghost-\(port)" }

    static func symbol(for clientID: String) -> String {
        switch clientID {
        case "opencode": return "terminal"
        case "continue": return "curlybraces"
        case "zed": return "text.cursor"
        case "aider": return "text.badge.plus"
        case "lmstudio": return "macwindow"
        case "ollama": return "pawprint"
        default: return "app"
        }
    }
}

// MARK: - Prominence

/// The one prominent control per state: Confirm while a current preview exists, otherwise
/// Preview while no measurement is on offer or a stale preview is showing, otherwise Measure.
struct ClientsProminence: Equatable {
    let preview: Bool
    let confirm: Bool
    let measure: Bool

    static func make(showsPreview: Bool, hasCurrentPreview: Bool, showsMeasurement: Bool) -> ClientsProminence {
        ClientsProminence(
            preview: !hasCurrentPreview && (showsPreview || !showsMeasurement),
            confirm: hasCurrentPreview,
            measure: showsMeasurement && !showsPreview
        )
    }

    var prominentCount: Int { [preview, confirm, measure].filter { $0 }.count }
}

// MARK: - Notices

/// Each distinct message renders once, in the slot it belongs to.
struct ClientsNotice: Equatable, Identifiable {
    enum Slot: Equatable { case header, actions, measurement }

    let slot: Slot
    let text: String
    let isError: Bool
    var id: String { text }

    static func make(serverMessage: String?, lastError: String?, persistenceError: String?, captureError: String?) -> [ClientsNotice] {
        let candidates: [(Slot, String?, Bool)] = [
            (.header, serverMessage, false),
            (.actions, lastError, true),
            (.actions, persistenceError, true),
            (.measurement, captureError, true),
        ]
        var seen: Set<String> = []
        return candidates.compactMap { slot, text, isError in
            guard let text, !text.isEmpty, seen.insert(text).inserted else { return nil }
            return ClientsNotice(slot: slot, text: text, isError: isError)
        }
    }
}

// MARK: - Connector

struct ClientsSegment: Equatable {
    let from: CGPoint
    let to: CGPoint
    let line: ClientsLine
}

enum ClientsRefresh {
    /// Reads the config files and the serve status concurrently, so status never waits behind file reads.
    @MainActor
    static func run(
        readConfigs: @escaping @MainActor () async -> Void, readStatus: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        async let readings: Void = readConfigs()
        async let status = readStatus()
        let ok = await status
        await readings
        return ok
    }
}

/// A client's state text, addressed by the client and the text's index in its row.
struct ClientsEntryKey: Hashable {
    let clientID: String
    let index: Int
}

enum ClientsConnectorPlan {
    /// Orthogonal segments in the board's coordinates: a stub from the endpoint row's trailing edge
    /// to a bus inside the gap (one bus per endpoint), a run along the bus, and a stub ending just
    /// before the client's symbol at the midline of the state text the line describes.
    /// A line missing any anchor is not drawn.
    static func segments(
        placed: [ClientsPlacedLine], endpointOrder: [String], endpointRects: [String: CGRect],
        entryRects: [ClientsEntryKey: CGRect], symbolRects: [String: CGRect], gap: CGRect?
    ) -> [ClientsSegment] {
        guard let gap else { return [] }
        return placed.flatMap { item -> [ClientsSegment] in
            let line = item.line
            guard let endpoint = endpointRects[line.endpointID], let symbol = symbolRects[line.clientID],
                  let entry = entryRects[ClientsEntryKey(clientID: line.clientID, index: item.stateIndex)],
                  let order = endpointOrder.firstIndex(of: line.endpointID) else { return [] }
            let bus = min(
                gap.minX + WorkbenchSize.Clients.lineFan * CGFloat(order + 1), gap.maxX - WorkbenchSpacing.xxs
            )
            let end = symbol.minX - WorkbenchSpacing.xxs
            return [
                ClientsSegment(from: CGPoint(x: endpoint.maxX, y: endpoint.midY), to: CGPoint(x: bus, y: endpoint.midY), line: line),
                ClientsSegment(from: CGPoint(x: bus, y: endpoint.midY), to: CGPoint(x: bus, y: entry.midY), line: line),
                ClientsSegment(from: CGPoint(x: bus, y: entry.midY), to: CGPoint(x: end, y: entry.midY), line: line),
            ]
        }
    }
}

/// The narrow board's elbow geometry, relative to a child row's frame.
enum ClientsElbowPlan {
    /// The rail runs down the endpoint's symbol centre.
    static func railX(in rect: CGRect) -> CGFloat {
        rect.minX + WorkbenchSpacing.xs + WorkbenchSize.Clients.rowSymbol / 2
    }

    /// The tick stops just before the child's symbol.
    static func tickEndX(in rect: CGRect) -> CGFloat {
        rect.minX + WorkbenchSize.Clients.treeGutter + WorkbenchSpacing.xs - WorkbenchSpacing.xxs
    }

    /// The first child's rail starts at the endpoint symbol's bottom edge.
    static func railStartY(in rect: CGRect, isFirst: Bool) -> CGFloat {
        isFirst ? rect.minY - WorkbenchSpacing.sm : rect.minY
    }

    /// A pending elbow fades in; every other elbow is fully drawn.
    static func opacity(for kind: ClientsLineKind, appeared: Bool) -> Double {
        kind == .pending && !appeared ? 0 : 1
    }
}
