import SwiftUI

/// Live observations only. Token totals belong to a gateway process, not a billing history.
struct ServingMonitorView: View {
    let appHost: AppHost
    @ObservedObject private var inventory: ServingInventoryCoordinator
    @ObservedObject private var endpoint: EndpointSupervisor
    @ObservedObject private var workflow: ModelWorkflowCoordinator
    let onRouteSelection: (AppRoute) -> Void
    @Environment(\.isRouteActive) private var isRouteActive
    @State private var selection: String?

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        self.onRouteSelection = onRouteSelection
        _inventory = ObservedObject(wrappedValue: appHost.servingInventory)
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _workflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
    }
    private var rows: [ServingRow] {
        ServingWorkspacePresentation.attentionFirst(
            ServingRows.build(slots: endpoint.fleet.slots, servers: workflow.servers, snapshot: inventory.snapshot)
                .filter { ServingWorkspacePresentation.isRunning($0) })
    }
    private var selected: ServingRow? { rows.first { $0.id == selection } }
    private var models: [LibraryModel] { appHost.librarySnapshot?.models ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    Text("\(rows.count) active model\(rows.count == 1 ? "" : "s")").font(WorkbenchTypography.cardTitle)
                    ServingSystemHeadroom(resources: appHost.resources)
                }
                Spacer()
                if inventory.isRefreshing { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await workflow.refreshServers(); await inventory.refresh(refreshHosts: true) } }
                    .disabled(inventory.isRefreshing)
                Button("Manage endpoints") { onRouteSelection(.run) }
            }
            Table(rows, selection: $selection) {
                TableColumn("Model") { row in
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                        Text(ServingWorkspacePresentation.name(row, models: models)).lineLimit(1).truncationMode(.middle)
                        Text(ServingWorkspacePresentation.provider(row)).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    }
                }.width(min: 160, ideal: 240)
                TableColumn("Status") { row in ServingStatusLabel(row: row, states: endpoint.slotStates) }.width(min: 90, ideal: 125)
                TableColumn("Input tokens") { row in Text(token(telemetry(row)?.inputTokens)).monospacedDigit() }.width(min: 80, ideal: 100)
                TableColumn("Output tokens") { row in Text(token(telemetry(row)?.outputTokens)).monospacedDigit() }.width(min: 80, ideal: 100)
                TableColumn("Response tok/s") { row in
                    Text(telemetry(row)?.lastRequest?.outputTokensPerSecond.map { String(format: "%.1f", $0) } ?? "—").monospacedDigit()
                }.width(min: 100, ideal: 120)
                TableColumn("Active") { row in Text(ServingWorkspacePresentation.server(row)?.activeRequests.map(String.init) ?? "—").monospacedDigit() }.width(55)
            }
            .alternatingRowBackgrounds(.disabled)
            .accessibilityIdentifier("serving-monitor-table")
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No models serving", systemImage: "server.rack", description: Text("Start an endpoint in Serving. Other detected local services appear here too."))
                }
            }
            if let selected { details(selected) }
            Text("Tokens cover completed requests with reported usage, since each gateway started. Response tok/s includes waiting, loading and generation. A dash means the provider has not reported a measurement.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(WorkbenchSpacing.lg)
        .task(id: isRouteActive) {
            guard isRouteActive else { return }
            await workflow.refreshServers()
        }
        .onChange(of: rows.map(\.id), initial: true) { _, ids in
            if selection == nil || !ids.contains(selection ?? "") { selection = ids.first }
        }
    }
    private func telemetry(_ row: ServingRow) -> ServingTelemetry? {
        guard ServingWorkspacePresentation.isRunning(row) else { return nil }
        return ServingTelemetry(raw: ServingWorkspacePresentation.server(row)?.inferenceTelemetry)
    }
    private func token(_ count: Int?) -> String { count.map { $0.formatted() } ?? "—" }
    private func details(_ row: ServingRow) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                Text(ServingWorkspacePresentation.name(row, models: models)).font(WorkbenchTypography.emphasis)
                Spacer()
                Button("Open model settings") {
                    appHost.handoffs.send(ServingFocusRequest(rowID: row.id), as: .openServing)
                    onRouteSelection(.run)
                }.accessibilityIdentifier("monitor-open-settings")
            }
            if let reason = ServingWorkspacePresentation.attentionReason(row) {
                Label {
                    Text(reason + " " + ServingWorkspacePresentation.attentionNextStep).textSelection(.enabled)
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(WorkbenchColor.failure) }
                .accessibilityIdentifier("monitor-attention-reason")
            }
            if let url = ServingWorkspacePresentation.baseURL(row) { Text(url).textSelection(.enabled) }
            if let metrics = telemetry(row) {
                Text("\(metrics.completedRequests.formatted()) completed · \(metrics.failedRequests.formatted()) failed · \(metrics.measuredRequests.formatted()) with token usage")
                if let start = ServingTelemetry.date(metrics.startedAt), let captured = ServingTelemetry.date(metrics.capturedAt) {
                    Text("Gateway started \(start.formatted(date: .abbreviated, time: .standard)) · Status read \(captured.formatted(date: .omitted, time: .standard))")
                }
                if let last = metrics.lastRequest, let seconds = last.responseSeconds {
                    Text("Last response: \(String(format: "%.2f", seconds)) s · \(last.outcome)")
                }
            } else { Text("This provider does not report gateway token metrics.") }
            if let service = ServingWorkspacePresentation.service(row) {
                DisclosureGroup("Memory & source") { ServingServiceDetails(service: service, inventory: inventory) }
            }
        }.font(WorkbenchTypography.secondary).padding(WorkbenchSpacing.md)
            .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
    }
}
