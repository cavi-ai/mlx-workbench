import SwiftUI

/// Live observations only. Token totals belong to a gateway process, not a billing history.
struct ServingMonitorView: View {
    let appHost: AppHost
    @ObservedObject private var inventory: ServingInventoryCoordinator
    @ObservedObject private var endpoint: EndpointSupervisor
    @ObservedObject private var workflow: ModelWorkflowCoordinator
    @ObservedObject private var tailnet: TailnetSharingCoordinator
    @ObservedObject private var resources: SystemResourceMonitor
    let onRouteSelection: (AppRoute) -> Void
    @Environment(\.isRouteActive) private var isRouteActive
    @State private var selection: String?
    @State private var inspectingProcesses = false

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        self.onRouteSelection = onRouteSelection
        _inventory = ObservedObject(wrappedValue: appHost.servingInventory)
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _workflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _tailnet = ObservedObject(wrappedValue: appHost.tailnetSharing)
        _resources = ObservedObject(wrappedValue: appHost.resources)
    }
    private var rows: [ServingRow] {
        ServingWorkspacePresentation.attentionFirst(
            ServingRows.build(slots: endpoint.fleet.slots, servers: workflow.servers, snapshot: inventory.snapshot)
                .filter { ServingWorkspacePresentation.isRunning($0) })
    }
    private var selected: ServingRow? { rows.first { $0.id == selection } }
    private var models: [LibraryModel] { appHost.librarySnapshot?.models ?? [] }

    var body: some View {
        let current = rows
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            MonitorMemoryCard(resources: resources, owners: owners(current), onShowAll: { inspectingProcesses = true }) {
                statTiles(current)
            }
            HStack(spacing: WorkbenchSpacing.sm) {
                Text("Live endpoints").font(WorkbenchTypography.section)
                Spacer(minLength: WorkbenchSpacing.sm)
                overviewControls
            }
            GeometryReader { geometry in
                if geometry.size.width >= 800 {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                        monitorTable.frame(maxWidth: .infinity, maxHeight: .infinity)
                        inspector.frame(width: max(340, geometry.size.width * 0.45)).frame(maxHeight: .infinity)
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
        .sheet(isPresented: $inspectingProcesses) { ProcessMemorySheet(resources: resources) }
        .task(id: isRouteActive) {
            guard isRouteActive else { return }
            async let discovery: Void = refreshDiscovery()
            async let processes: Void = resources.refreshProcesses()
            await workflow.refreshServers()
            await discovery
            await processes
        }
        .onChange(of: rows.map(\.id), initial: true) { _, ids in
            if selection == nil || !ids.contains(selection ?? "") { selection = ids.first }
        }
    }

    private func refreshDiscovery() async {
        if appHost.liveServicesStarted { await inventory.refresh(refreshHosts: true) }
    }

    /// The served model each measured process belongs to, for tagging the memory list.
    private func owners(_ rows: [ServingRow]) -> [Int32: String] {
        var owners: [Int32: String] = [:]
        for row in rows {
            let memory = memoryRow(row), name = ServingWorkspacePresentation.name(row, models: models)
            if let pid = memory.modelPID { owners[Int32(pid)] = name }
            if let pid = memory.gatewayPID, owners[Int32(pid)] == nil { owners[Int32(pid)] = name + " gateway" }
            if let pid = memory.hostPID, owners[Int32(pid)] == nil { owners[Int32(pid)] = ServingWorkspacePresentation.provider(row) }
        }
        return owners
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
                TableColumn("Decode") { row in
                    MonitorTableCell { selected in
                        Text(MonitorFormat.rate(telemetry(row)?.lastRequest?.decodeTokensPerSecond ?? telemetry(row)?.lastRequest?.outputTokensPerSecond))
                            .font(WorkbenchTypography.secondaryTabular)
                            .foregroundStyle(selected ? WorkbenchColor.onSelection : WorkbenchColor.ink)
                            .help("Output tokens per second of the last request")
                    }
                }.width(min: 60, ideal: 70)
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
    private func memoryDisplay(_ memory: ServingMemory.Row) -> (amount: String, origin: String) {
        if let reported = memory.reportedBytes { return (MonitorFormat.bytes(reported), "Provider allocation") }
        if let pid = memory.modelPID { return (MonitorFormat.bytes(memory.readings[pid]), "Model process") }
        if let pid = memory.gatewayPID { return (MonitorFormat.bytes(memory.readings[pid]), "Gateway") }
        if let pid = memory.hostPID { return (MonitorFormat.bytes(memory.readings[pid]), "Shared host") }
        return ("—", "Unknown")
    }
    @ViewBuilder
    private func statTiles(_ rows: [ServingRow]) -> some View {
        let tally = ServingWorkspacePresentation.tally(rows)
        let summary = ServingMemory.summary(rows.map(memoryRow))
        let metrics = rows.compactMap(telemetry)
        let completed = metrics.reduce(0) { $0 + $1.completedRequests }, failed = metrics.reduce(0) { $0 + $1.failedRequests }
        let output = metrics.compactMap(\.outputTokens).reduce(0, +)
        MonitorStatTile(title: "Endpoints", symbol: "server.rack", value: rows.count.formatted(),
                        detail: "\(tally.loaded.formatted()) loaded")
        MonitorStatTile(title: "Serving memory", symbol: "memorychip",
                        value: summary.overflow ? "Unavailable" : MonitorFormat.bytes(summary.measuredBytes),
                        detail: "\(summary.measuredProcesses) of \(summary.identifiedProcesses) processes measured"
                            + (summary.unknownOwners > 0 ? " · \(summary.unknownOwners) unknown" : ""))
            .help("Memory of the processes that serve these models. Provider allocations are listed per endpoint.")
            .accessibilityIdentifier("monitor-memory-summary")
        MonitorStatTile(title: "Requests", symbol: "arrow.left.arrow.right", value: completed.formatted(),
                        detail: "\(failed.formatted()) failed · \(output.formatted()) output tokens")
            .help("Completed requests and output tokens since each gateway started")
    }
    @ViewBuilder
    private var overviewControls: some View {
        if inventory.isRefreshing { ProgressView().controlSize(.small) }
        Button("Refresh") {
            Task {
                await workflow.refreshServers()
                async let processes: Void = resources.refreshProcesses()
                await inventory.refresh(refreshHosts: true, fresh: true)
                await processes
            }
        }
        .disabled(inventory.isRefreshing)
        Button("Manage endpoints") { onRouteSelection(.run) }
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
    private func openSettings(_ row: ServingRow) {
        appHost.handoffs.send(ServingFocusRequest(rowID: row.id), as: .openServing)
        onRouteSelection(.run)
    }
    private func details(_ row: ServingRow) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            headerCard(row)
            performanceCard(row)
            if case .endpoint(let slot, _, _) = row { settingsCard(endpoint.effectiveSlot(slot), row: row) }
            else if let server = ServingWorkspacePresentation.server(row) { reportedSettingsCard(server, row: row) }
            memoryCard(row)
            connectionCard(row)
            ServingSiblingEndpoints(row: row, rows: rows) { selection = $0 }
            sourceCard(row)
        }
        .font(WorkbenchTypography.secondary)
    }

    private func headerCard(_ row: ServingRow) -> some View {
        WorkbenchSurface(padding: WorkbenchSpacing.sm) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Text(ServingWorkspacePresentation.name(row, models: models)).font(WorkbenchTypography.section)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: WorkbenchSpacing.xs) {
                    ServingStatusLabel(row: row, states: endpoint.slotStates)
                    let runtime = ServingWorkspacePresentation.service(row)?.runtime ?? ServingWorkspacePresentation.server(row)?.runtime
                    if let title = ServingWorkspacePresentation.runtimeTitle(runtime) ?? runtime { MonitorChip(text: title) }
                    if let port = ServingWorkspacePresentation.server(row)?.port { MonitorChip(text: ":\(port)") }
                    Spacer(minLength: WorkbenchSpacing.xs)
                    Button("Edit settings…") { openSettings(row) }.accessibilityIdentifier("monitor-open-settings")
                }
                if let reason = ServingWorkspacePresentation.attentionReason(row) {
                    Label {
                        Text(reason + " " + ServingWorkspacePresentation.attentionNextStep).textSelection(.enabled)
                    } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(WorkbenchColor.failure) }
                    .accessibilityIdentifier("monitor-attention-reason")
                }
            }
        }
    }

    private func performanceCard(_ row: ServingRow) -> some View {
        MonitorCard(title: "Performance") {
            if let metrics = telemetry(row) {
                let last = metrics.lastRequest
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.lg) { performanceMetrics(last) }
                    Grid(alignment: .leading, horizontalSpacing: WorkbenchSpacing.lg, verticalSpacing: WorkbenchSpacing.sm) {
                        GridRow { MonitorMetric.decode(last); MonitorMetric.prompt(last) }
                        GridRow { MonitorMetric.firstToken(last); MonitorMetric.response(last) }
                    }
                }
                if let stages = last?.stages {
                    MonitorStageBar(wait: stages.wait, prompt: stages.prompt, decode: stages.decode)
                } else if last != nil {
                    Text("This gateway reports whole-response speed only; prompt and decode time are not split.")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: WorkbenchSpacing.lg, verticalSpacing: WorkbenchSpacing.xxs) {
                    GridRow {
                        MonitorCount(label: "Completed", value: metrics.completedRequests.formatted())
                        MonitorCount(label: "Failed", value: metrics.failedRequests.formatted())
                        MonitorCount(label: "Input tokens", value: metrics.inputTokens?.formatted() ?? "—")
                        MonitorCount(label: "Output tokens", value: metrics.outputTokens?.formatted() ?? "—")
                    }
                }
                .help("Totals cover requests since the gateway started. A dash means no usage was reported.")
                if let start = ServingTelemetry.date(metrics.startedAt) {
                    Text("Since gateway start \(start.formatted(date: .abbreviated, time: .shortened))"
                         + (ServingWorkspacePresentation.server(row)?.activeRequests.map { " · \($0) active now" } ?? ""))
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
            } else {
                Text("This provider does not report request metrics.").foregroundStyle(WorkbenchColor.muted)
            }
        }
        .accessibilityIdentifier("monitor-performance")
    }

    @ViewBuilder
    private func performanceMetrics(_ last: ServingTelemetry.Request?) -> some View {
        MonitorMetric.decode(last)
        MonitorMetric.prompt(last)
        MonitorMetric.firstToken(last)
        MonitorMetric.response(last)
    }

    private static let settingGroups: [(title: String, keys: [ServingSettingKey])] = [
        ("Loading", [.loadOnRequest, .memoryPolicy, .splashPreset, .servingProfile]),
        ("Generation", [.temperature, .topP, .maximumTokens, .thinkingOff, .systemPrompt]),
        ("Acceleration", [.m5Prefill, .promptLookup, .visionCache, .sharedPrefixCacheMiB]),
    ]

    private func settingsCard(_ slot: EndpointSlot, row: ServingRow) -> some View {
        MonitorCard(title: "Settings") {
            Button("Edit…") { openSettings(row) }
        } content: {
            ForEach(Self.settingGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text(group.title).font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.accent)
                    ForEach(group.keys, id: \.self) { key in
                        MonitorField(label: ServingInspectorPresentation.label(key),
                                     value: ServingInspectorPresentation.value(key, slot: slot))
                    }
                }
            }
        }
        .accessibilityIdentifier("monitor-settings")
    }

    private func reportedSettingsCard(_ server: ServerInfo, row: ServingRow) -> some View {
        MonitorCard(title: "Settings") {
            Button("Edit…") { openSettings(row) }
        } content: {
            Text("Reported by the running server").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                ForEach(MonitorSettings.reported(server), id: \.label) { field in
                    MonitorField(label: field.label, value: field.value)
                }
            }
        }
        .accessibilityIdentifier("monitor-settings")
    }

    private func memoryCard(_ row: ServingRow) -> some View {
        let memory = memoryRow(row)
        let server = ServingWorkspacePresentation.server(row)
        return MonitorCard(title: "Memory") {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                if let value = memory.reportedBytes { MonitorField(label: "Provider allocation", value: MonitorFormat.bytes(value)) }
                if let pid = memory.modelPID { MonitorField(label: "Model process", value: MonitorFormat.bytes(memory.readings[pid]) + " · PID \(pid)") }
                if let pid = memory.gatewayPID { MonitorField(label: "Gateway", value: MonitorFormat.bytes(memory.readings[pid]) + " · PID \(pid)") }
                if let pid = memory.hostPID { MonitorField(label: "Shared host", value: MonitorFormat.bytes(memory.readings[pid]) + " · PID \(pid)") }
                if let reading = server?.workerMemory { MonitorField(label: "MLX allocator", value: ServingInventoryPresentation.allocatorSummary(reading)) }
                if let allocation = server?.memoryAllocation {
                    if let bytes = allocation.estimatedResidentBytes { MonitorField(label: "Source estimate", value: MonitorFormat.bytes(bytes)) }
                    if let bytes = allocation.budgetBytes { MonitorField(label: "Memory budget", value: MonitorFormat.bytes(bytes)) }
                    if let mode = allocation.mode { MonitorField(label: "Allocation mode", value: mode) }
                }
            }
            if memory.unknownOwnership {
                Text("The model process was not reported, so its memory is not included.").foregroundStyle(WorkbenchColor.muted)
            }
            if let captured = inventory.processMemoryCapturedAt {
                Text("Process memory read \(captured.formatted(date: .omitted, time: .standard))")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
        }
        .help("Process values are the physical footprint macOS reports. Provider allocations and source estimates are separate measurements.")
        .accessibilityIdentifier("monitor-endpoint-memory")
    }

    @ViewBuilder
    private func connectionCard(_ row: ServingRow) -> some View {
        let url = ServingWorkspacePresentation.baseURL(row)
        let shared = tailnet.sharedAddress(port: ServingWorkspacePresentation.server(row)?.port)
        if url != nil || shared != nil {
            MonitorCard(title: "Connection") {
                if let url { ServingConnectionField(title: "Address", value: url, identifier: "monitor-copy-address", compact: true) }
                if let shared { ServingConnectionField(title: "Tailscale address", value: shared, identifier: "monitor-copy-tailnet-address", compact: true) }
            }
        }
    }

    private func modelPath(_ row: ServingRow) -> String? {
        if let path = ServingWorkspacePresentation.service(row)?.modelPath { return path }
        if case .endpoint(let slot, _, _) = row { return slot.modelPath }
        return nil
    }

    private func sourceCard(_ row: ServingRow) -> some View {
        let service = ServingWorkspacePresentation.service(row)
        let path = modelPath(row)
        return MonitorCard(title: "Source") {
            if let path, path.hasPrefix("/") {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
        } content: {
            if let service {
                ServingServiceDetails(service: service, inventory: inventory, sections: [.source])
            } else {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    MonitorField(label: "Model", value: ServingWorkspacePresentation.modelID(row))
                    if let path { MonitorField(label: "Model path", value: path, monospaced: true) }
                }
            }
        }
        .accessibilityIdentifier("monitor-source")
    }
}

/// The settings a running server reports in discovery, for servers without a saved endpoint.
enum MonitorSettings {
    static func reported(_ server: ServerInfo) -> [(label: String, value: String)] {
        func gigabytes(_ value: Double) -> String { String(format: "%g GB", value) }
        func sampling(_ value: LabValue?) -> String { value?.decimal.map { String(format: "%.2f", $0) } ?? "Model default" }
        var fields: [(label: String, value: String)] = []
        if let runtime = server.runtime {
            fields.append(("Runtime", ServingWorkspacePresentation.runtimeTitle(runtime) ?? runtime))
        }
        if let kinds = server.taskKinds, !kinds.isEmpty {
            fields.append(("Tasks", kinds.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }.joined(separator: ", ")))
        }
        if let jit = server.jit { fields.append(("Load on request", jit ? "On" : "Off")) }
        if let policy = server.memoryPolicy {
            fields.append(("Residency", EndpointResidency(policy).title))
            if let reserve = policy.minimumHeadroomGB { fields.append(("Reserve", gigabytes(reserve))) }
            if let budget = policy.modelMemoryBudgetGB { fields.append(("Model memory budget", gigabytes(budget))) }
            if let context = policy.contextTokens { fields.append(("Context", "\(context.formatted()) tokens")) }
            if policy.unloadUnderPressure == true { fields.append(("Memory pressure", "Unload")) }
        }
        if server.supportsChatCompletions {
            let defaults = server.requestDefaults?.object ?? [:]
            fields.append(("Temperature", sampling(defaults["temperature"])))
            fields.append(("Top-p", sampling(defaults["top_p"])))
            fields.append(("System prompt", defaults["system_prompt_sha256"]?.text == nil ? "None" : "Set"))
        }
        if let context = server.splashEffectiveContextTokens ?? server.splashConfiguredContextTokens {
            fields.append(("Splash context", "\(context.formatted()) tokens"))
        }
        if let adapter = server.adapterPath { fields.append(("Adapter", URL(fileURLWithPath: adapter).lastPathComponent)) }
        fields.append(("API key", server.apiKeySHA256 == nil ? "Not required" : "Required"))
        return fields
    }
}

enum MonitorFormat {
    static func bytes(_ value: UInt64?) -> String {
        value.map { bytes(Int64(clamping: $0)) } ?? "—"
    }
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
    static func rate(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
    static func seconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: value < 10 ? "%.2f" : "%.1f", value)
    }
    static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
}

/// System memory by Activity Monitor category, then the processes holding the most.
private struct MonitorMemoryCard<Tiles: View>: View {
    @ObservedObject var resources: SystemResourceMonitor
    let owners: [Int32: String]
    let onShowAll: () -> Void
    @ViewBuilder let tiles: () -> Tiles

    var body: some View {
        WorkbenchSurface {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: WorkbenchSpacing.xl) {
                    composition.frame(minWidth: 380, idealWidth: 420, maxWidth: .infinity, alignment: .leading)
                    consumers.frame(width: 340)
                }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                    composition
                    consumers
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("monitor-memory")
    }

    private struct Segment: Identifiable {
        let title: String
        let bytes: Int64
        let color: Color
        let help: String
        var id: String { title }
    }

    private func segments(_ parts: MemorySnapshot.Composition) -> [Segment] {
        [Segment(title: "App memory", bytes: parts.appBytes, color: WorkbenchColor.accent,
                 help: "Memory apps and model servers hold for their own data."),
         Segment(title: "Wired", bytes: parts.wiredBytes, color: WorkbenchColor.accent.opacity(.stroke),
                 help: "Memory macOS keeps in RAM and cannot compress or page out. It includes the kernel and can include GPU buffers of loaded models."),
         Segment(title: "Compressed", bytes: parts.compressedBytes, color: WorkbenchColor.warning,
                 help: "Memory macOS compressed to make room. A large share means memory pressure."),
         Segment(title: "Cached files", bytes: parts.cachedFilesBytes, color: WorkbenchColor.muted.opacity(.stroke),
                 help: "Recently used files kept in memory. macOS frees it when an app needs memory.")]
    }

    @ViewBuilder
    private var composition: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Memory").font(WorkbenchTypography.cardTitle)
            if let memory = resources.memory, memory.totalBytes > 0 {
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
                    Text(MonitorFormat.bytes(memory.availableBytes)).font(WorkbenchTypography.hero)
                        .foregroundStyle(memory.availableBytes < FitAdvisor.reserveBytes ? WorkbenchColor.warning : WorkbenchColor.ink)
                    Text("available").font(WorkbenchTypography.section).foregroundStyle(WorkbenchColor.muted)
                    Spacer(minLength: WorkbenchSpacing.sm)
                    Text(MonitorFormat.bytes(memory.totalBytes) + " total")
                        .font(WorkbenchTypography.secondaryTabular).foregroundStyle(WorkbenchColor.muted)
                }
                .help("Free plus reclaimable memory: what a new model can use without other apps swapping.")
                if let parts = memory.composition {
                    let segments = segments(parts)
                    MonitorSegmentBar(shares: segments.map { (value: Double($0.bytes), color: $0.color, title: $0.title) },
                                      total: Double(memory.totalBytes))
                        .accessibilityLabel("Memory composition")
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: WorkbenchSpacing.lg) { legend(segments, free: parts.freeBytes) }
                        Grid(alignment: .leading, horizontalSpacing: WorkbenchSpacing.lg, verticalSpacing: WorkbenchSpacing.xs) {
                            GridRow { legendItem(segments[0]); legendItem(segments[1]); legendItem(segments[2]) }
                            GridRow { legendItem(segments[3]); freeItem(parts.freeBytes) }
                        }
                    }
                } else {
                    ProgressView(value: Double(memory.availableBytes), total: Double(memory.totalBytes))
                        .accessibilityLabel("Available system memory")
                }
            } else {
                Text("Unavailable").font(WorkbenchTypography.title).foregroundStyle(WorkbenchColor.muted)
            }
            Spacer(minLength: WorkbenchSpacing.sm)
            HStack(alignment: .top, spacing: WorkbenchSpacing.sm) { tiles() }
        }
    }

    @ViewBuilder
    private func legend(_ segments: [Segment], free: Int64) -> some View {
        ForEach(segments) { legendItem($0) }
        freeItem(free)
    }

    private func legendItem(_ segment: Segment) -> some View {
        MonitorLegendItem(color: segment.color, title: segment.title, value: MonitorFormat.bytes(segment.bytes)).help(segment.help)
    }

    private func freeItem(_ bytes: Int64) -> some View {
        MonitorLegendItem(color: WorkbenchColor.well, title: "Free", value: MonitorFormat.bytes(bytes))
            .help("Memory no process is using.")
    }

    @ViewBuilder
    private var consumers: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack(spacing: WorkbenchSpacing.xs) {
                Text("Using the most").font(WorkbenchTypography.cardTitle)
                Spacer(minLength: WorkbenchSpacing.xs)
                if resources.refreshingProcesses { ProgressView().controlSize(.small) }
                Button("All processes…", action: onShowAll).accessibilityIdentifier("monitor-all-processes")
            }
            let top = Array((resources.processMemory?.processes ?? []).prefix(6))
            if top.isEmpty {
                Text(resources.processError ?? "Reading processes…").foregroundStyle(WorkbenchColor.muted)
            } else {
                let largest = Double(max(top[0].memoryBytes, 1))
                ForEach(top) { process in
                    MonitorConsumerRow(process: process, owner: owners[process.pid], fraction: Double(process.memoryBytes) / largest)
                }
            }
            if let date = resources.processCapturedAt {
                Text("Read \(date.formatted(date: .omitted, time: .standard)) · values are physical footprint and may share pages")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("monitor-memory-consumers")
    }
}

private struct MonitorSegmentBar: View {
    let shares: [(value: Double, color: Color, title: String)]
    let total: Double

    var body: some View {
        GeometryReader { geometry in
            let scale = max(total, shares.reduce(0) { $0 + $1.value }, 1)
            HStack(spacing: WorkbenchSpacing.hairline) {
                ForEach(Array(shares.enumerated()), id: \.offset) { _, share in
                    Rectangle().fill(share.color)
                        .frame(width: max(0, geometry.size.width * share.value / scale - WorkbenchSpacing.hairline))
                        .help(share.title)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: WorkbenchSpacing.sm)
        .background(WorkbenchColor.well)
        .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.chip, style: .continuous))
    }
}

private struct MonitorLegendItem: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
            RoundedRectangle(cornerRadius: WorkbenchRadius.chip / 2, style: .continuous)
                .fill(color)
                .overlay { RoundedRectangle(cornerRadius: WorkbenchRadius.chip / 2, style: .continuous).stroke(WorkbenchColor.hairline) }
                .frame(width: WorkbenchSpacing.sm, height: WorkbenchSpacing.sm)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
                Text(value).font(WorkbenchTypography.secondaryTabular).foregroundStyle(WorkbenchColor.ink)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MonitorConsumerRow: View {
    let process: ProcessMemorySnapshot.Entry
    let owner: String?
    let fraction: Double

    var body: some View {
        HStack(alignment: .center, spacing: WorkbenchSpacing.xs) {
            Image(systemName: owner == nil ? "cpu" : "server.rack")
                .foregroundStyle(owner == nil ? WorkbenchColor.muted : WorkbenchColor.accent)
                .frame(width: WorkbenchSpacing.md)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                HStack(spacing: WorkbenchSpacing.xs) {
                    Text(process.name).font(WorkbenchTypography.secondary).lineLimit(1).truncationMode(.middle)
                    if let owner { MonitorChip(text: owner, tinted: true) }
                    Spacer(minLength: WorkbenchSpacing.xs)
                    Text(MonitorFormat.bytes(process.memoryBytes)).font(WorkbenchTypography.secondaryTabular)
                }
                GeometryReader { geometry in
                    Capsule().fill(owner == nil ? WorkbenchColor.muted.opacity(.stroke) : WorkbenchColor.accent)
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
                .frame(height: WorkbenchSpacing.xxs)
                .background(WorkbenchColor.well, in: Capsule())
            }
        }
        .help(owner.map { "\(process.name) · PID \(process.pid) · serves \($0)" } ?? "\(process.name) · PID \(process.pid)")
        .accessibilityElement(children: .combine)
    }
}

private struct MonitorStatTile: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String

    var body: some View {
        WorkbenchSurface(padding: WorkbenchSpacing.sm) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Label(title, systemImage: symbol).font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
                    .symbolRenderingMode(.hierarchical)
                Text(value).font(WorkbenchTypography.display).foregroundStyle(WorkbenchColor.ink).lineLimit(1)
                Text(detail).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).lineLimit(1)
            }
        }
        .frame(minWidth: WorkbenchSize.tileMinimum, maxWidth: 260)
    }
}

private struct MonitorCard<Accessory: View, Content: View>: View {
    let title: String
    let accessory: () -> Accessory
    let content: () -> Content

    init(title: String, @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        WorkbenchSurface(padding: WorkbenchSpacing.sm) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                HStack(spacing: WorkbenchSpacing.xs) {
                    Text(title).font(WorkbenchTypography.cardTitle)
                    Spacer(minLength: WorkbenchSpacing.xs)
                    accessory()
                }
                content()
            }
        }
    }
}

extension MonitorCard where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

private struct MonitorChip: View {
    let text: String
    var tinted = false

    var body: some View {
        Text(text).font(WorkbenchTypography.metadata).lineLimit(1)
            .foregroundStyle(tinted ? WorkbenchColor.accent : WorkbenchColor.muted)
            .padding(.horizontal, WorkbenchSpacing.xs)
            .padding(.vertical, WorkbenchSpacing.xxxs)
            .background(tinted ? WorkbenchColor.accent.opacity(.fill) : WorkbenchColor.well, in: Capsule())
    }
}

private struct MonitorMetric: View {
    let title: String
    let value: String
    let unit: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
            Text(title).font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
            HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xxs) {
                Text(value).font(WorkbenchTypography.display).foregroundStyle(value == "—" ? WorkbenchColor.muted : WorkbenchColor.ink)
                Text(unit).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
        }
        .help(help)
        .accessibilityElement(children: .combine)
    }

    static func decode(_ last: ServingTelemetry.Request?) -> Self {
        if let rate = last?.decodeTokensPerSecond {
            return Self(title: "Decode", value: MonitorFormat.rate(rate), unit: "tok/s",
                        help: "Output tokens per second after the first token of the last request: generation speed.")
        }
        return Self(title: "Output", value: MonitorFormat.rate(last?.outputTokensPerSecond), unit: "tok/s",
                    help: "Output tokens per second over the whole last response, including waiting and prompt processing.")
    }
    static func prompt(_ last: ServingTelemetry.Request?) -> Self {
        Self(title: "Prompt", value: MonitorFormat.rate(last?.promptTokensPerSecond), unit: "tok/s",
             help: "Prompt tokens per second before the first output token of the last request: input processing speed.")
    }
    static func firstToken(_ last: ServingTelemetry.Request?) -> Self {
        Self(title: "First token", value: MonitorFormat.seconds(last?.firstTokenSeconds), unit: "s",
             help: "Time from the request to its first streamed token, including queue and load wait.")
    }
    static func response(_ last: ServingTelemetry.Request?) -> Self {
        Self(title: "Response", value: MonitorFormat.seconds(last?.responseSeconds), unit: "s",
             help: "Whole response time of the last request.")
    }
}

/// Where the last response's time went, as shares of its total.
private struct MonitorStageBar: View {
    let wait: Double
    let prompt: Double
    let decode: Double

    var body: some View {
        let stages: [(value: Double, color: Color, title: String)] = [
            (wait, WorkbenchColor.muted.opacity(.stroke), "Wait"),
            (prompt, WorkbenchColor.accent.opacity(.stroke), "Prompt"),
            (decode, WorkbenchColor.accent, "Decode"),
        ]
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text("Last response time").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
            MonitorSegmentBar(shares: stages, total: 1)
            HStack(alignment: .top, spacing: WorkbenchSpacing.lg) {
                MonitorLegendItem(color: stages[0].color, title: "Wait", value: MonitorFormat.percent(wait))
                    .help("Queued or loading the model before the prompt started.")
                MonitorLegendItem(color: stages[1].color, title: "Prompt", value: MonitorFormat.percent(prompt))
                    .help("Reading the prompt until the first token.")
                MonitorLegendItem(color: stages[2].color, title: "Decode", value: MonitorFormat.percent(decode))
                    .help("Generating the answer after the first token.")
            }
        }
        .accessibilityIdentifier("monitor-stage-bar")
    }
}

private struct MonitorCount: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(WorkbenchTypography.secondaryTabular).foregroundStyle(WorkbenchColor.ink)
            Text(label).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
        }
    }
}

/// One label and value in a card's two-column field list.
struct MonitorField: View {
    static let labelWidth: CGFloat = 132
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
            Text(label).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                .frame(width: Self.labelWidth, alignment: .leading)
            Text(value).font(monospaced ? WorkbenchTypography.compactValue : WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.ink)
                .lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .help(value)
        }
        .accessibilityElement(children: .combine)
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
