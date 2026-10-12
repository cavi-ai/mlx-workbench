import SwiftUI

// MARK: - Tone

extension ClientsTone {
    var textColor: Color {
        switch self {
        case .live: return WorkbenchColor.ink
        case .muted: return WorkbenchColor.muted
        case .warning: return WorkbenchColor.warning
        case .pending: return WorkbenchColor.accent
        }
    }
}

extension ClientsLine {
    var strokeColor: Color { kind == .live || kind == .pending ? WorkbenchColor.accent : WorkbenchColor.muted }

    var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: WorkbenchSize.stageTrack, dash: isDashed ? WorkbenchSize.Clients.lineDash : [])
    }
}

extension View {
    /// The one prominent control of a region gets the filled style; the others are bordered.
    @ViewBuilder
    func clientsProminence(_ isProminent: Bool) -> some View {
        if isProminent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

// MARK: - Connector

enum ClientsAnchor: Hashable {
    case endpoint(String)
    case symbol(String)
    case entry(ClientsEntryKey)
    case gap
}

struct ClientsAnchorKey: PreferenceKey {
    static var defaultValue: [ClientsAnchor: Anchor<CGRect>] = [:]

    static func reduce(value: inout [ClientsAnchor: Anchor<CGRect>], nextValue: () -> [ClientsAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct ClientsConnector: Shape {
    let segments: [ClientsSegment]

    func path(in rect: CGRect) -> SwiftUI.Path {
        var path = SwiftUI.Path()
        for segment in segments {
            path.move(to: segment.from)
            path.addLine(to: segment.to)
        }
        return path
    }
}

/// The board's lines, drawn behind the rows from their measured bounds.
private struct ClientsConnectorLayer: View {
    let placed: [ClientsPlacedLine]
    let endpointOrder: [String]
    let anchors: [ClientsAnchor: Anchor<CGRect>]
    let proxy: GeometryProxy

    private var segments: [ClientsSegment] {
        var endpointRects: [String: CGRect] = [:]
        var symbolRects: [String: CGRect] = [:]
        var entryRects: [ClientsEntryKey: CGRect] = [:]
        var gap: CGRect?
        for (key, anchor) in anchors {
            switch key {
            case .endpoint(let id): endpointRects[id] = proxy[anchor]
            case .symbol(let id): symbolRects[id] = proxy[anchor]
            case .entry(let entry): entryRects[entry] = proxy[anchor]
            case .gap: gap = proxy[anchor]
            }
        }
        return ClientsConnectorPlan.segments(
            placed: placed, endpointOrder: endpointOrder, endpointRects: endpointRects,
            entryRects: entryRects, symbolRects: symbolRects, gap: gap
        )
    }

    var body: some View {
        let segments = segments
        ZStack {
            ClientsConnector(segments: segments.filter { $0.line.kind != .live && $0.line.kind != .pending })
                .stroke(WorkbenchColor.muted, style: StrokeStyle(lineWidth: WorkbenchSize.stageTrack, dash: WorkbenchSize.Clients.lineDash))
            ClientsConnector(segments: segments.filter { $0.line.kind == .live })
                .stroke(WorkbenchColor.accent, style: StrokeStyle(lineWidth: WorkbenchSize.stageTrack))
            ClientsConnector(segments: segments.filter { $0.line.kind == .pending })
                .stroke(WorkbenchColor.accent, style: StrokeStyle(lineWidth: WorkbenchSize.stageTrack, dash: WorkbenchSize.Clients.lineDash))
        }
        .accessibilityHidden(true)
    }
}

/// The narrow board's elbow: a rail down the endpoint's symbol column and a tick into the child.
private struct ClientsElbow: Shape {
    let isFirst: Bool
    let isLast: Bool

    func path(in rect: CGRect) -> SwiftUI.Path {
        var path = SwiftUI.Path()
        let x = ClientsElbowPlan.railX(in: rect)
        path.move(to: CGPoint(x: x, y: ClientsElbowPlan.railStartY(in: rect, isFirst: isFirst)))
        path.addLine(to: CGPoint(x: x, y: isLast ? rect.midY : rect.maxY))
        path.move(to: CGPoint(x: x, y: rect.midY))
        path.addLine(to: CGPoint(x: ClientsElbowPlan.tickEndX(in: rect), y: rect.midY))
        return path
    }
}

private struct ClientsElbowView: View {
    let line: ClientsLine
    let isFirst: Bool
    let isLast: Bool
    @State private var appeared = false

    var body: some View {
        ClientsElbow(isFirst: isFirst, isLast: isLast)
            .stroke(line.strokeColor, style: line.strokeStyle)
            .frame(width: WorkbenchSize.Clients.treeGutter + WorkbenchSpacing.xs)
            .opacity(ClientsElbowPlan.opacity(for: line.kind, appeared: appeared))
            .workbenchAnimation(value: appeared)
            .onAppear { appeared = true }
            .accessibilityHidden(true)
    }
}

// MARK: - Rows

private struct ClientsEndpointRowView: View {
    let row: ClientsEndpointRow
    let isRefreshing: Bool
    let isRouteActive: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous)
    }

    var body: some View {
        switch row.kind {
        case .running: running
        case .ghost: ghost
        }
    }

    private var running: some View {
        HStack(spacing: WorkbenchSize.Clients.rowSymbolGap) {
            Image(systemName: ClientsPresentation.endpointSymbol)
                .font(WorkbenchTypography.section)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(WorkbenchColor.accent)
                .frame(width: WorkbenchSize.Clients.rowSymbol)
                .livePulse(isRefreshing && isRouteActive)
            Text(row.name)
                .font(WorkbenchTypography.cardTitle)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(":\(row.port.map(String.init) ?? "?")")
                .font(WorkbenchTypography.display)
                .foregroundStyle(WorkbenchColor.accent)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, WorkbenchSpacing.xs)
        .padding(.vertical, WorkbenchSpacing.sm)
        .background(row.isSelected ? WorkbenchColor.accent.opacity(.fill) : Color.clear, in: shape)
        .help(row.identity ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private var ghost: some View {
        HStack(spacing: WorkbenchSize.Clients.rowSymbolGap) {
            Image(systemName: ClientsPresentation.endpointSymbol)
                .font(WorkbenchTypography.section)
                .foregroundStyle(WorkbenchColor.muted)
                .frame(width: WorkbenchSize.Clients.rowSymbol)
            Text(row.ghostText)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, WorkbenchSpacing.xs)
        .padding(.vertical, WorkbenchSpacing.sm)
        .frame(minWidth: WorkbenchSize.Clients.ghostRowMinimum, maxWidth: .infinity, alignment: .leading)
        .overlay(shape.strokeBorder(WorkbenchColor.muted, style: StrokeStyle(lineWidth: WorkbenchSpacing.hairline, dash: WorkbenchSize.Clients.lineDash)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}

private struct ClientsClientRowView: View {
    let row: ClientsClientRow

    var body: some View {
        HStack(alignment: .top, spacing: WorkbenchSize.Clients.rowSymbolGap) {
            Image(systemName: row.symbol)
                .font(WorkbenchTypography.section)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(row.isAdvisory ? WorkbenchColor.muted : WorkbenchColor.accent)
                .frame(width: WorkbenchSize.Clients.rowSymbol)
                .anchorPreference(key: ClientsAnchorKey.self, value: .bounds) { [.symbol(row.id): $0] }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                HStack(spacing: WorkbenchSpacing.xs) {
                    Text(row.name)
                        .font(WorkbenchTypography.cardTitle)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if let file = row.fileName {
                        Text(file)
                            .font(WorkbenchTypography.compactValue)
                            .foregroundStyle(WorkbenchColor.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                ForEach(Array(row.states.enumerated()), id: \.offset) { index, state in
                    Text(state.text)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(state.tone.textColor)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .anchorPreference(key: ClientsAnchorKey.self, value: .bounds) {
                            [.entry(ClientsEntryKey(clientID: row.id, index: index)): $0]
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, WorkbenchSpacing.xs)
        .padding(.vertical, WorkbenchSpacing.sm)
        .help(row.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint(row.help)
    }
}

// MARK: - Empty states

private struct ClientsNoServerView: View {
    let onOpenRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack(spacing: WorkbenchSize.Clients.rowSymbolGap) {
                Image(systemName: "bolt.slash")
                    .font(WorkbenchTypography.section)
                    .foregroundStyle(WorkbenchColor.muted)
                    .frame(width: WorkbenchSize.Clients.rowSymbol)
                    .accessibilityHidden(true)
                Text("No running server")
                    .font(WorkbenchTypography.cardTitle)
            }
            Button("Open Run", action: onOpenRun)
                .buttonStyle(.borderless)
                .padding(.leading, WorkbenchSize.Clients.rowSymbol + WorkbenchSize.Clients.rowSymbolGap)
        }
        .padding(.horizontal, WorkbenchSpacing.xs)
        .padding(.vertical, WorkbenchSpacing.sm)
    }
}

private struct ClientsReadingStatusView: View {
    let isPulsing: Bool

    var body: some View {
        HStack(spacing: WorkbenchSize.Clients.rowSymbolGap) {
            Image(systemName: ClientsPresentation.endpointSymbol)
                .font(WorkbenchTypography.section)
                .foregroundStyle(WorkbenchColor.muted)
                .frame(width: WorkbenchSize.Clients.rowSymbol)
                .livePulse(isPulsing)
                .accessibilityHidden(true)
            Text("Reading serve status…")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
        }
        .padding(.horizontal, WorkbenchSpacing.xs)
        .padding(.vertical, WorkbenchSpacing.sm)
    }
}

private struct ClientsNoClientsView: View {
    var body: some View {
        HStack(spacing: WorkbenchSize.Clients.rowSymbolGap) {
            Image(systemName: "app.dashed")
                .font(WorkbenchTypography.section)
                .foregroundStyle(WorkbenchColor.muted)
                .frame(width: WorkbenchSize.Clients.rowSymbol)
                .accessibilityHidden(true)
            Text("No supported clients detected")
                .font(WorkbenchTypography.cardTitle)
        }
        .padding(.horizontal, WorkbenchSpacing.xs)
        .padding(.vertical, WorkbenchSpacing.sm)
        .help("Supported clients: opencode, Continue, Zed, Aider.")
    }
}

// MARK: - Outcome

/// The result of a confirmed wiring and the measurement actions that follow it.
struct ClientsOutcomeView<Notices: View>: View {
    let result: String?
    let hasIssues: Bool
    let prominence: ClientsProminence
    let showsMeasurement: Bool
    let isPreparing: Bool
    let isMeasureDisabled: Bool
    let onMeasure: () -> Void
    let onReview: () -> Void
    @ViewBuilder let notices: () -> Notices

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            if let result {
                Text(result)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(hasIssues ? WorkbenchColor.failure : WorkbenchColor.success)
            }
            if showsMeasurement {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.xs) { actions }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { actions }
                }
                notices()
            }
        }
    }

    @ViewBuilder private var actions: some View {
        Button(isPreparing ? "Checking endpoint…" : "Measure this workflow…", action: onMeasure)
            .clientsProminence(prominence.measure)
            .disabled(isMeasureDisabled)
        Button("Review report in Compare…", action: onReview).buttonStyle(.bordered)
    }
}

// MARK: - Board

/// The wiring board: running endpoints, the clients' config files, and a line from each
/// client to the endpoint its own file points at. `picker` sits over the endpoint column.
struct ClientsBoardView<Selector: View>: View {
    let presentation: ClientsPresentation
    let mode: ClientsLayout.BoardMode
    let isRefreshing: Bool
    let isRouteActive: Bool
    let onOpenRun: () -> Void
    @ViewBuilder let picker: () -> Selector

    var body: some View {
        switch mode {
        case .twoColumn: twoColumn
        case .tree: tree
        }
    }

    @ViewBuilder
    private var endpointHeader: some View {
        switch presentation.endpointHeader {
        case .none: EmptyView()
        case .readingStatus: ClientsReadingStatusView(isPulsing: isRefreshing && isRouteActive)
        case .noServer: ClientsNoServerView(onOpenRun: onOpenRun)
        }
    }

    // MARK: Two columns

    private var twoColumn: some View {
        HStack(alignment: .top, spacing: 0) {
            endpointColumn
                .frame(
                    minWidth: WorkbenchSize.Clients.endpointMinimum, idealWidth: WorkbenchSize.Clients.endpointIdeal,
                    maxWidth: WorkbenchSize.Clients.endpointMaximum, alignment: .topLeading
                )
            Color.clear
                .frame(
                    minWidth: WorkbenchSize.Clients.gapMinimum, idealWidth: WorkbenchSize.Clients.gapIdeal,
                    maxWidth: WorkbenchSize.Clients.gapMaximum
                )
                .anchorPreference(key: ClientsAnchorKey.self, value: .bounds) { [.gap: $0] }
            clientColumn
                .frame(
                    minWidth: WorkbenchSize.Clients.clientMinimum,
                    maxWidth: WorkbenchSize.Clients.endpointMaximum + WorkbenchSize.Clients.gapMaximum,
                    alignment: .topLeading
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .backgroundPreferenceValue(ClientsAnchorKey.self) { anchors in
            GeometryReader { proxy in
                ClientsConnectorLayer(
                    placed: presentation.placedLines, endpointOrder: presentation.endpoints.map(\.id),
                    anchors: anchors, proxy: proxy
                )
            }
        }
    }

    private var endpointColumn: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            picker()
            endpointHeader
            ForEach(presentation.endpoints) { row in
                ClientsEndpointRowView(row: row, isRefreshing: isRefreshing, isRouteActive: isRouteActive)
                    .anchorPreference(key: ClientsAnchorKey.self, value: .bounds) { [.endpoint(row.id): $0] }
            }
        }
    }

    private var clientColumn: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            if presentation.clients.isEmpty { ClientsNoClientsView() }
            ForEach(presentation.clients) { row in
                ClientsClientRowView(row: row)
            }
        }
    }

    // MARK: Tree

    private var tree: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            picker()
            endpointHeader
            ForEach(presentation.treeGroups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    ClientsEndpointRowView(row: group.endpoint, isRefreshing: isRefreshing, isRouteActive: isRouteActive)
                    ForEach(Array(group.children.enumerated()), id: \.element.id) { index, child in
                        ClientsClientRowView(row: child.client)
                            .padding(.leading, WorkbenchSize.Clients.treeGutter)
                            .background(alignment: .leading) {
                                ClientsElbowView(
                                    line: child.line, isFirst: index == 0, isLast: index == group.children.count - 1
                                )
                            }
                    }
                }
            }
            if presentation.clients.isEmpty {
                ClientsNoClientsView()
            } else {
                if !presentation.unconnectedClients.isEmpty {
                    Text(ClientsPresentation.notConnectedCaption)
                        .font(WorkbenchTypography.label)
                        .foregroundStyle(WorkbenchColor.muted)
                        .padding(.top, WorkbenchSpacing.xs)
                    ForEach(presentation.unconnectedClients) { ClientsClientRowView(row: $0) }
                }
                ForEach(presentation.advisoryClients) { ClientsClientRowView(row: $0) }
            }
        }
    }
}
