import SwiftUI

/// Live observations only. Token totals belong to a gateway process, not a billing history.
struct ServingMonitorView: View {
    let appHost: AppHost
    @ObservedObject private var inventory: ServingInventoryCoordinator
    @ObservedObject private var endpoint: EndpointSupervisor
    @ObservedObject private var workflow: ModelWorkflowCoordinator
    @ObservedObject private var tailnet: TailnetSharingCoordinator
    let onRouteSelection: (AppRoute) -> Void
    @Environment(\.isRouteActive) private var isRouteActive
    @State private var selection: String?

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        self.onRouteSelection = onRouteSelection
        _inventory = ObservedObject(wrappedValue: appHost.servingInventory)
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _workflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _tailnet = ObservedObject(wrappedValue: appHost.tailnetSharing)
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
            MonitorHeadroomFact(resources: appHost.resources)
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
                if geometry.size.width >= 800 {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                        monitorTable.frame(maxWidth: .infinity, maxHeight: .infinity)
                        inspector.frame(width: max(300, geometry.size.width * 0.42)).frame(maxHeight: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                        monitorTable.frame(maxWidth: .infinity, maxHeight: .infinity)
                        inspector.frame(height: max(200, geometry.size.height * 0.55))
                    }
                }
            }
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
                    MonitorTableCell { selected in
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                        Text(ServingWorkspacePresentation.name(row, models: models)).lineLimit(1).truncationMode(.middle)
                        let port = ServingWorkspacePresentation.server(row)?.port ?? URL(string: ServingWorkspacePresentation.baseURL(row) ?? "")?.port
                        Text((port.map { ":\($0) · " } ?? "") + ServingWorkspacePresentation.provider(row))
                            .font(WorkbenchTypography.metadata).foregroundStyle(selected ? WorkbenchColor.onSelection : WorkbenchColor.muted)
                            .help(ServingWorkspacePresentation.baseURL(row) ?? "Address unavailable")
                    }}
                }.width(min: 110, ideal: 160)
                TableColumn("Status / memory") { row in
                    let full = ServingWorkspacePresentation.status(row, states: endpoint.slotStates)
                    let display = memoryDisplay(memoryRow(row))
                    MonitorTableCell { selected in
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                            ServingStatusLabel(row: row, states: endpoint.slotStates, text: shortStatus(full)).help(full)
                            Text(display.amount == "—" ? "Memory unknown" : "\(display.amount) · \(display.origin)")
                                .font(WorkbenchTypography.metadata).monospacedDigit()
                                .foregroundStyle(selected ? WorkbenchColor.onSelection : WorkbenchColor.muted)
                        }
                    }
                }.width(min: 125, ideal: 170)

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
    private func details(_ row: ServingRow) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text(ServingWorkspacePresentation.name(row, models: models)).font(WorkbenchTypography.emphasis)
                .fixedSize(horizontal: false, vertical: true)
            Text(ServingWorkspacePresentation.provider(row) + " · " + ServingWorkspacePresentation.status(row, states: endpoint.slotStates))
                .foregroundStyle(WorkbenchColor.muted)
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
            if let address = tailnet.sharedAddress(port: ServingWorkspacePresentation.server(row)?.port) {
                ServingConnectionField(title: "Tailscale address", value: address, identifier: "monitor-copy-tailnet-address", compact: true)
            }
            if let active = ServingWorkspacePresentation.server(row)?.activeRequests {
                LabeledContent("Active requests", value: active.formatted())
            }
            if let metrics = telemetry(row) {
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.lg) {
                        responseMetric(metrics)
                        gatewayMetrics(metrics)
                    }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                        responseMetric(metrics)
                        gatewayMetrics(metrics)
                    }
                }
                Text("\(metrics.completedRequests.formatted()) completed · \(metrics.failedRequests.formatted()) failed · \(metrics.measuredRequests.formatted()) with token usage")
                if let start = ServingTelemetry.date(metrics.startedAt), let captured = ServingTelemetry.date(metrics.capturedAt) {
                    Text("Gateway started \(start.formatted(date: .abbreviated, time: .standard)) · Status read \(captured.formatted(date: .omitted, time: .standard))")
                }
                if let last = metrics.lastRequest, let seconds = last.responseSeconds {
                    Text("Last response: \(String(format: "%.2f", seconds)) s · \(last.outcome)")
                }
            } else { Text("This provider does not report gateway token metrics.") }
            ServingSiblingEndpoints(row: row, rows: rows) { selection = $0 }
            DisclosureGroup("Memory & source") {
                let memory = memoryRow(row)
                if let value = memory.reportedBytes { LabeledContent("Provider model allocation", value: bytes(value)) }
                if let pid = memory.modelPID { LabeledContent("Model process RAM · PID \(pid)", value: bytes(memory.readings[pid])) }
                if let pid = memory.gatewayPID { LabeledContent("Gateway RAM · PID \(pid)", value: bytes(memory.readings[pid])) }
                if let pid = memory.hostPID { LabeledContent("Shared host RAM · PID \(pid)", value: bytes(memory.readings[pid])) }
                if memory.unknownOwnership { Text("Model process ownership not reported").foregroundStyle(WorkbenchColor.muted) }
                if let captured = inventory.processMemoryCapturedAt { Text("Process memory read \(captured.formatted(date: .omitted, time: .standard))").foregroundStyle(WorkbenchColor.muted) }
                Text("Model ID: " + ServingWorkspacePresentation.modelID(row)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let service = ServingWorkspacePresentation.service(row) {
                    ServingServiceDetails(service: service, inventory: inventory)
                }
            }

        }.font(WorkbenchTypography.secondary).padding(WorkbenchSpacing.md)
            .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
    }
    private func responseMetric(_ metrics: ServingTelemetry) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text("Last response").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
            Text(metrics.lastRequest?.outputTokensPerSecond.map { String(format: "%.1f", $0) } ?? "—")
                .font(WorkbenchTypography.display)
            Text("output tok/s").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
        }.help("Response speed includes waiting, loading and generation. A dash means no measurement was reported.")
    }
    private func gatewayMetrics(_ metrics: ServingTelemetry) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text("Gateway totals").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
            HStack(alignment: .top, spacing: WorkbenchSpacing.lg) {
                metricValue("Input tokens", token(metrics.inputTokens))
                metricValue("Output tokens", token(metrics.outputTokens))
            }
            Text("Since gateway start").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
        }.help("Totals cover completed requests with reported usage. A dash means no measurement was reported.")
    }
    private func metricValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(value).font(WorkbenchTypography.section).monospacedDigit()
            Text(label).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
        }
    }

}

private struct MonitorHeadroomFact: View {
    @ObservedObject var resources: SystemResourceMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("System headroom").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
            if let memory = resources.memory, memory.totalBytes > 0 {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "~%.1f GB available", Double(memory.availableBytes) / 1e9))
                        .font(WorkbenchTypography.hero)
                        .foregroundStyle(memory.availableBytes < FitAdvisor.reserveBytes ? WorkbenchColor.warning : WorkbenchColor.ink)
                    Spacer()
                    Text(String(format: "%.1f GB total", Double(memory.totalBytes) / 1e9))
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).monospacedDigit()
                }
                ProgressView(value: Double(memory.availableBytes), total: Double(memory.totalBytes))
                    .accessibilityLabel("Available system memory")
                    .accessibilityValue(String(format: "%.1f of %.1f GB", Double(memory.availableBytes) / 1e9, Double(memory.totalBytes) / 1e9))
            } else {
                Text("Unavailable").font(WorkbenchTypography.title).foregroundStyle(WorkbenchColor.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WorkbenchSpacing.md)
        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
    }
}

private struct MonitorTableCell<Content: View>: View {
    @Environment(\.backgroundProminence) private var prominence
    @ViewBuilder let content: (Bool) -> Content
    var body: some View {
        let selected = prominence == .increased
        content(selected).foregroundStyle(selected ? WorkbenchColor.onSelection : WorkbenchColor.ink)
    }
}
