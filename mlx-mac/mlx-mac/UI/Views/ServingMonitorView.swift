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
            let summary = ServingMemory.summary(rows.map(memoryRow))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: WorkbenchSpacing.lg) {
                    overviewFacts(summary)
                    Spacer(minLength: WorkbenchSpacing.sm)
                    overviewControls
                }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.lg) { overviewFacts(summary) }
                    HStack { Spacer(); overviewControls }
                }
            }
            GeometryReader { geometry in
                if geometry.size.width >= 1050 {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                        monitorTable.frame(maxWidth: .infinity, maxHeight: .infinity)
                        inspector.frame(width: 320).frame(maxHeight: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                        monitorTable.frame(maxWidth: .infinity, maxHeight: .infinity)
                        inspector.frame(height: min(230, max(150, geometry.size.height * 0.4)))
                    }
                }
            }
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
    private var monitorTable: some View {
        Table(rows, selection: $selection) {
                TableColumn("Model") { row in
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                        Text(ServingWorkspacePresentation.name(row, models: models)).lineLimit(1).truncationMode(.middle)
                        let port = ServingWorkspacePresentation.server(row)?.port ?? URL(string: ServingWorkspacePresentation.baseURL(row) ?? "")?.port
                        Text((port.map { ":\($0) · " } ?? "") + ServingWorkspacePresentation.provider(row))
                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                            .help(ServingWorkspacePresentation.baseURL(row) ?? "Address unavailable")
                    }
                }.width(min: 150, ideal: 240)
                TableColumn("Status") { row in
                    let full = ServingWorkspacePresentation.status(row, states: endpoint.slotStates)
                    ServingStatusLabel(row: row, states: endpoint.slotStates, text: shortStatus(full)).help(full)
                }.width(min: 80, ideal: 125)
                TableColumn("Memory") { row in
                    let display = memoryDisplay(memoryRow(row))
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                        Text(display.amount).monospacedDigit()
                        Text(display.origin).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    }
                }.width(min: 110, ideal: 150)
                TableColumn("Tokens in / out") { row in
                    let input = telemetry(row)?.inputTokens, output = telemetry(row)?.outputTokens
                    Text(compactToken(input) + " / " + compactToken(output)).monospacedDigit()
                        .help("Input: " + token(input) + " · Output: " + token(output))
                }.width(min: 95, ideal: 120)
                TableColumn("Response tok/s") { row in
                    Text(telemetry(row)?.lastRequest?.outputTokensPerSecond.map { String(format: "%.1f", $0) } ?? "—").monospacedDigit()
                }.width(min: 90, ideal: 120)
                TableColumn("Active") { row in Text(ServingWorkspacePresentation.server(row)?.activeRequests.map(String.init) ?? "—").monospacedDigit() }.width(55)
            }
            .alternatingRowBackgrounds(.disabled)
            .accessibilityIdentifier("serving-monitor-table")
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No models serving", systemImage: "server.rack", description: Text("Start an endpoint in Serving. Other detected local services appear here too."))
                }
            }
    }
    private func shortStatus(_ status: String) -> String {
        switch status {
        case "Ready on request": return "On request"
        case "Running · residency unknown": return "Unknown"
        case "Needs attention": return "Attention"
        default: return status
        }
    }
    private func memoryRow(_ row: ServingRow) -> ServingMemory.Row {
        let service = ServingWorkspacePresentation.service(row)
        let server = ServingWorkspacePresentation.server(row)
        let modelPID = service?.modelProcessID ?? (server?.jit == true ? server?.workerPid : server?.pid)
        let gatewayPID = server?.jit == true ? server?.pid : nil
        let unknownModel = (server?.jit == true && server?.modelState == "loaded" && modelPID == nil)
            || (service?.isWorkbenchManaged == false && service?.residency == .loaded && modelPID == nil)
        return ServingMemory.row(.init(modelPID: modelPID, gatewayPID: gatewayPID,
                                       hostPID: service?.hostProcessID, reportedBytes: service?.reportedMemoryBytes,
                                       unknownOwnership: unknownModel, stale: service?.stale == true), readings: inventory.processMemory)
    }
    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }
    private func memoryDisplay(_ memory: ServingMemory.Row) -> (amount: String, origin: String) {
        if let reported = memory.reportedBytes { return (bytes(reported), "Provider allocation") }
        if let pid = memory.modelPID { return (bytes(memory.readings[pid]), "Model process") }
        if let pid = memory.gatewayPID { return (bytes(memory.readings[pid]), "Gateway") }
        if let pid = memory.hostPID { return (bytes(memory.readings[pid]), "Shared host") }
        return ("—", "Unknown")
    }
    private func memorySummary(_ summary: ServingMemory.Summary) -> String {
        let amount = summary.overflow ? "Unavailable" : bytes(summary.measuredBytes)
        return "\(amount) · \(summary.measuredProcesses)/\(summary.identifiedProcesses) measured"
    }
    @ViewBuilder
    private func overviewFacts(_ summary: ServingMemory.Summary) -> some View {
        let tally = ServingWorkspacePresentation.tally(rows)
        overviewFact("Live endpoints", "\(rows.count) · \(tally.loaded) loaded")
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text("Observed process RAM").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
            Text(memorySummary(summary)).font(WorkbenchTypography.emphasis).monospacedDigit()
            if summary.unknownOwners > 0 {
                Text("\(summary.unknownOwners) unknown ownership").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
        }.help("Unique observed process RSS may share physical pages and excludes unknown workers. Provider allocations are separate.")
            .accessibilityIdentifier("monitor-memory-summary")
        MonitorHeadroomFact(resources: appHost.resources)
    }
    @ViewBuilder
    private var overviewControls: some View {
        if inventory.isRefreshing { ProgressView().controlSize(.small) }
        Button("Refresh") { Task { await workflow.refreshServers(); await inventory.refresh(refreshHosts: true) } }
            .disabled(inventory.isRefreshing)
        Button("Manage endpoints") { onRouteSelection(.run) }
    }
    private func overviewFact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(title).font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
            Text(value).font(WorkbenchTypography.emphasis).monospacedDigit()
        }
    }
    private var inspector: some View {
        Group {
            if let selected { ScrollView { details(selected) } }
            else { ContentUnavailableView("Select an endpoint", systemImage: "server.rack") }
        }.accessibilityIdentifier("monitor-inspector")
    }
    private func telemetry(_ row: ServingRow) -> ServingTelemetry? {
        guard ServingWorkspacePresentation.isRunning(row) else { return nil }
        return ServingTelemetry(raw: ServingWorkspacePresentation.server(row)?.inferenceTelemetry)
    }
    private func token(_ count: Int?) -> String { count.map { $0.formatted() } ?? "—" }
    private func compactToken(_ count: Int?) -> String { count.map { $0.formatted(.number.notation(.compactName)) } ?? "—" }
    private func details(_ row: ServingRow) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text(ServingWorkspacePresentation.name(row, models: models)).font(WorkbenchTypography.emphasis)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open model settings") {
                appHost.handoffs.send(ServingFocusRequest(rowID: row.id), as: .openServing)
                onRouteSelection(.run)
            }.accessibilityIdentifier("monitor-open-settings")
            if let reason = ServingWorkspacePresentation.attentionReason(row) {
                Label {
                    Text(reason + " " + ServingWorkspacePresentation.attentionNextStep).textSelection(.enabled)
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(WorkbenchColor.failure) }
                .accessibilityIdentifier("monitor-attention-reason")
            }
            if let url = ServingWorkspacePresentation.baseURL(row) {
                ServingConnectionField(title: "Address", value: url, identifier: "monitor-copy-address", compact: true)
            }
            let memory = memoryRow(row)
            if let value = memory.reportedBytes { LabeledContent("Provider model allocation", value: bytes(value)) }
            if let pid = memory.modelPID { LabeledContent("Model process RAM · PID \(pid)", value: bytes(memory.readings[pid])) }
            if let pid = memory.gatewayPID { LabeledContent("Gateway RAM · PID \(pid)", value: bytes(memory.readings[pid])) }
            if let pid = memory.hostPID { LabeledContent("Shared host RAM · PID \(pid)", value: bytes(memory.readings[pid])) }
            if memory.unknownOwnership { Text("Model process ownership not reported").foregroundStyle(WorkbenchColor.muted) }
            if let captured = inventory.processMemoryCapturedAt { Text("Process memory read \(captured.formatted(date: .omitted, time: .standard))").foregroundStyle(WorkbenchColor.muted) }
            Text("Model ID: " + ServingWorkspacePresentation.modelID(row)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            ServingSiblingEndpoints(row: row, rows: rows) { selection = $0 }
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

private struct MonitorHeadroomFact: View {
    @ObservedObject var resources: SystemResourceMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text("System headroom").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
            if let memory = resources.memory {
                Text(String(format: "~%.1f GB available", Double(memory.availableBytes) / 1e9))
                    .font(WorkbenchTypography.emphasis).monospacedDigit()
                    .foregroundStyle(memory.availableBytes < FitAdvisor.reserveBytes ? WorkbenchColor.warning : WorkbenchColor.ink)
            } else {
                Text("Unavailable").font(WorkbenchTypography.emphasis).foregroundStyle(WorkbenchColor.muted)
            }
        }
    }
}
