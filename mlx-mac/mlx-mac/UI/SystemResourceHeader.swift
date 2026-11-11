import AppKit
import SwiftUI

/// One compact toolbar entry; model controls and estimation settings live
/// in its popover so charts keep their space.
struct SystemResourceHeader: View {
    @ObservedObject var resources: SystemResourceMonitor
    @ObservedObject var endpoint: EndpointSupervisor
    var hosts: ModelHostsCoordinator? = nil
    var servingInventory: ServingInventoryCoordinator? = nil
    /// Running engine servers, as the workflow reports them.
    var servers: [ServerInfo] = []
    var libraryModels: [LibraryModel] = []
    /// Shows the short memory label when the window is too narrow for the loaded count.
    var compactLabel = false
    /// False until saved histories have loaded; stopping an endpoint waits for them.
    var historyLoaded = true
    /// Selects Run, scrolling to the row when one is given.
    var onManageServing: (String?) -> Void = { _ in }
    var onRefreshServers: () async -> Void = {}
    var onOpenHost: (ModelHost?) -> Void = { _ in }
    var occupancy = ModelOccupancy()
    let onUnload: (ServerInfo) async -> Bool
    @State private var expanded = false
    @State private var inspectingProcesses = false
    @State private var unloadError: String?

    private func gb(_ bytes: Int64) -> String { ResourceHeaderPresentation.gigabytes(bytes) }

    var body: some View {
        Group {
            if let servingInventory {
                ObservedInventorySnapshot(inventory: servingInventory) { snapshot in
                    toggleButton(loaded: snapshot.capturedAt == nil ? nil : snapshot.loadedCount,
                                 serving: snapshot.capturedAt == nil ? nil : snapshot.servingCount)
                }
            } else {
                toggleButton(loaded: nil, serving: nil)
            }
        }
        .popover(isPresented: $expanded, arrowEdge: .bottom) { panel }
        .sheet(isPresented: $inspectingProcesses) { ProcessMemorySheet(resources: resources) }
    }

    private func toggleButton(loaded: Int?, serving: Int?) -> some View {
        let attention = ResourceHeaderPresentation.attentionState(slots: endpoint.fleet.slots, state: endpoint.state)
        let available = resources.memory?.availableBytes
        return Button { expanded.toggle() } label: {
            HStack(spacing: WorkbenchSpacing.xs) {
                Image(systemName: attention.map(EndpointIcon.name(for:)) ?? "memorychip")
                    .foregroundStyle(attention.map { ResourceHeaderPresentation.status(for: $0).color } ?? WorkbenchColor.muted)
                if let available {
                    Text(ResourceHeaderPresentation.memoryText(availableBytes: available, loaded: loaded, serving: serving, compact: compactLabel))
                        .foregroundStyle(available < FitAdvisor.reserveBytes ? WorkbenchColor.warning : WorkbenchColor.ink)
                        .contentTransition(.numericText())
                } else {
                    Text("RAM unavailable").foregroundStyle(WorkbenchColor.muted)
                }
            }
            .font(WorkbenchTypography.label.monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .workbenchAnimation(value: available)
        }
        .buttonStyle(.plain)
        .help("Memory headroom and serving")
        .accessibilityLabel(ResourceHeaderPresentation.accessibilityLabel(availableBytes: available, loaded: loaded, serving: serving, attention: attention))
        .accessibilityIdentifier("system-memory-header")
    }

    var panel: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            CardHeader("Memory & serving", systemImage: "memorychip") {
                Button { Task {
                    await resources.refreshMemory()
                    if let servingInventory { await servingInventory.refresh(refreshHosts: true) }
                    else { await resources.refreshServers() }
                    await onRefreshServers()
                } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh readings and serving status")
                .disabled(resources.refreshingServers || endpoint.isUnloading)
            }
            if let memory = resources.memory {
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.md) {
                    memoryValue("Available headroom", bytes: memory.availableBytes, color: WorkbenchColor.accent)
                    memoryValue("Estimated in use", bytes: memory.unavailableBytes, color: WorkbenchColor.ink)
                }
                ProgressView(value: Double(memory.unavailableBytes), total: Double(memory.totalBytes))
                    .tint(memory.availableBytes < FitAdvisor.reserveBytes ? WorkbenchColor.warning : WorkbenchColor.accent)
                Text("\(gb(memory.totalBytes)) GB unified memory · system-wide estimates including reclaimable pages. Per-model GPU allocation is unavailable.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                if let date = resources.capturedAt {
                    Text("Read \(date.formatted(date: .omitted, time: .standard))")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
            } else {
                Text("Memory readings unavailable").foregroundStyle(WorkbenchColor.muted)
            }
            Divider()
            if let servingInventory {
                ServingInventoryResourceSection(
                    inventory: servingInventory, endpoint: endpoint, servers: servers, models: libraryModels,
                    occupancy: occupancy, historyLoaded: historyLoaded,
                    onManage: { rowID in
                        expanded = false
                        onManageServing(rowID)
                    },
                    onReview: { action, service in
                        expanded = false
                        Task { await servingInventory.prepare(action, service: service) }
                    })
            } else {
                Text("Serving models").font(WorkbenchTypography.metadata.weight(.semibold))
                    .foregroundStyle(WorkbenchColor.muted)
                if let error = resources.serverError {
                    Text(error).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
                } else if let servers = resources.servers {
                    if servers.isEmpty { Text("No serving models").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted) }
                    ForEach(servers) { server in
                        HStack(spacing: WorkbenchSpacing.sm) {
                            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                                Text((HFRepoID.forPath(server.modelIdentity) ?? URL(fileURLWithPath: server.modelIdentity).lastPathComponent)
                                    + (server.adapterSummary.map { " · " + $0 } ?? ""))
                                    .font(WorkbenchTypography.label).lineLimit(1)
                                    .help(server.modelIdentity)
                                Text("Port \(server.port.map(String.init) ?? "unknown") · PID \(server.pid.map(String.init) ?? "unknown")")
                                    .font(WorkbenchTypography.compactValue).foregroundStyle(WorkbenchColor.muted)
                                Text(server.residencySummary + ((server.activeRequests ?? 0) > 0 ? " · \(server.activeRequests ?? 0) active" : ""))
                                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                            }
                            Spacer()
                            Button(server.jit == true ? "Unload" : "Stop") {
                                Task {
                                    unloadError = nil
                                    if !(await onUnload(server)) { unloadError = endpoint.lastError ?? "Unload failed." }
                                    await resources.refreshServers()
                                    await resources.refreshMemory()
                                }
                            }
                            .controlSize(.small)
                            .disabled(endpoint.isUnloading || resources.refreshingServers || server.port == nil ||
                                      server.modelState == "unloaded" || server.modelState == "loading" || server.modelState == "unloading" ||
                                      (server.activeRequests ?? 0) > 0 ||
                                      occupancy.blocksStop(server))
                            .help(server.jit == true
                                  ? "Release model weights while keeping this endpoint reachable. The next request loads the same local files."
                                  : "Stop this server and disable automatic restart. Enable Load on request in Run for JIT unload.")
                        }
                    }
                } else {
                    Text("Reading serving status…").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
                if resources.servers?.contains(where: { occupancy.blocksStop($0) }) == true {
                    Text("Models in use by active operations cannot be unloaded here. Finish or cancel the operation first.")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
                if endpoint.isUnloading { ProgressView("Unloading…").controlSize(.small) }
                if let unloadError { Text(unloadError).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning) }
            }
            Divider()
            ProcessMemoryButton {
                expanded = false
                inspectingProcesses = true
            }
            Picker("Context for model fit", selection: $resources.contextTokens) {
                ForEach(SystemResourceMonitor.contextOptions, id: \.self) { tokens in
                    Text(RunContext.title(tokens)).tag(tokens)
                }
            }
            .font(WorkbenchTypography.metadata)
            Text("Used for model-fit reviews; does not change a running server’s context limit.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            if servingInventory != nil, hosts != nil {
                Button("Manage host connections…") { expanded = false; onOpenHost(nil) }
                    .buttonStyle(.borderless).font(WorkbenchTypography.secondary)
            }
            if let hosts, servingInventory == nil {
                Divider()
                SavedModelHostsSection(hosts: hosts) { host in
                    expanded = false
                    onOpenHost(host)
                }
            }
        }
        .padding(WorkbenchSpacing.md)
        }
        .frame(width: WorkbenchSize.ResourceHeader.popoverWidth)
        .frame(maxHeight: WorkbenchSize.ResourceHeader.popoverMaxHeight)
        .task {
            guard servingInventory == nil else { return }
            while !Task.isCancelled {
                await resources.refreshServers()
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            }
        }
    }

    private func memoryValue(_ label: String, bytes: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
            Text(label).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            Text("~\(gb(bytes)) GB").font(WorkbenchTypography.display)
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .workbenchAnimation(value: bytes)
        }
    }
}

/// Strings and states the toolbar label draws; pure so each variant can be read without a window.
enum ResourceHeaderPresentation {
    static func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1e9) }

    /// The endpoint state worth showing on every route: only a non-empty fleet, and only while it needs attention.
    static func attentionState(slots: [EndpointSlot], state: EndpointState) -> EndpointState? {
        guard !slots.isEmpty else { return nil }
        switch state {
        case .starting, .waitingForServer, .modelMismatch, .degraded: return state
        case .running, .disabled: return nil
        }
    }

    static func status(for state: EndpointState) -> WorkbenchStatus {
        switch state {
        case .disabled: return .disabled
        case .starting, .waitingForServer: return .pending
        case .running: return .running
        case .modelMismatch: return .warning
        case .degraded: return .failure
        }
    }

    /// `loaded` is nil until the inventory has been read; a compact label never shows it.
    /// `serving` counts the services a Library row marks Serving; it is named when some of them are not loaded.
    static func memoryText(availableBytes: Int64, loaded: Int?, serving: Int? = nil, compact: Bool) -> String {
        let available = "~\(gigabytes(availableBytes)) GB available"
        guard !compact, let loaded else { return available }
        if let serving, serving > loaded {
            return "\(serving) serving · \(loaded) loaded · \(available)"
        }
        return "\(loaded) loaded · \(available)"
    }

    static func accessibilityLabel(availableBytes: Int64?, loaded: Int?, serving: Int? = nil, attention: EndpointState?) -> String {
        let memory = availableBytes.map { memoryText(availableBytes: $0, loaded: loaded, serving: serving, compact: false) } ?? "RAM unavailable"
        guard let attention else { return memory }
        return memory + ", endpoint: " + attention.summary
    }
}

/// A reviewed or navigating command on a served row; none stops or unloads without a review.
enum ServingRowAction: Equatable {
    case unload(title: String), stop, openServing

    var title: String {
        switch self {
        case .unload(let title): title
        case .stop: "Stop server…"
        case .openServing: "Open Serving"
        }
    }
}

extension ResourceHeaderPresentation {
    static func reviewActions(for service: ServingServiceObservation) -> [ServingRowAction] {
        (service.canUnload ? [.unload(title: ServingInventoryPresentation.unloadTitle(for: service))] : [])
            + (service.canStop ? [.stop] : [])
    }

    /// A running server's inline commands: the reviewed ones when an inventory service is attached, else Open Serving.
    static func serverActions(service: ServingServiceObservation?) -> [ServingRowAction] {
        let reviewed = service.map(reviewActions(for:)) ?? []
        return reviewed.isEmpty ? [.openServing] : reviewed
    }
}

/// Re-renders its content when the inventory snapshot changes.
private struct ObservedInventorySnapshot<Content: View>: View {
    @ObservedObject var inventory: ServingInventoryCoordinator
    let content: (ServingInventorySnapshot) -> Content

    var body: some View { content(inventory.snapshot) }
}

private struct ServingInventoryResourceSection: View {
    @ObservedObject var inventory: ServingInventoryCoordinator
    @ObservedObject var endpoint: EndpointSupervisor
    let servers: [ServerInfo]
    let models: [LibraryModel]
    let occupancy: ModelOccupancy
    let historyLoaded: Bool
    let onManage: (String?) -> Void
    let onReview: (ServingActionKind, ServingServiceObservation) -> Void

    var body: some View {
        let rows = ServingWorkspacePresentation.rows(ServingRows.build(slots: endpoint.fleet.slots, servers: servers, snapshot: inventory.snapshot), includeAvailable: false)
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack {
                Text("Local serving models").font(WorkbenchTypography.label)
                Spacer()
                Button("Open Serving") { onManage(nil) }.buttonStyle(.borderless)
                    .accessibilityIdentifier("popover-open-serving")
            }
            ServingInventoryErrors(inventory: inventory)
            if rows.isEmpty {
                Text(inventory.isRefreshing ? "Reading local services…" : "No local serving models reported")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            ForEach(rows) { row in
                ServingPopoverRow(row: row, inventory: inventory, endpoint: endpoint, servers: servers, models: models,
                                  occupancy: occupancy, historyLoaded: historyLoaded, onManage: onManage, onReview: onReview)
                if row.id != rows.last?.id { Divider() }
            }
            Text("Process RAM is observed resident memory and may share pages. Provider readings and source estimates are separate; none are added to system headroom.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            if let date = inventory.processMemoryCapturedAt {
                Text("Process RAM read " + date.formatted(date: .omitted, time: .standard))
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
        }
    }
}

/// One served row: name, facts, the actions that stay reachable from any route, and the rest in a menu.
private struct ServingPopoverRow: View {
    let row: ServingRow
    @ObservedObject var inventory: ServingInventoryCoordinator
    @ObservedObject var endpoint: EndpointSupervisor
    let servers: [ServerInfo]
    let models: [LibraryModel]
    let occupancy: ModelOccupancy
    let historyLoaded: Bool
    let onManage: (String?) -> Void
    let onReview: (ServingActionKind, ServingServiceObservation) -> Void
    @State private var detailsOpen = false

    private var service: ServingServiceObservation? {
        switch row {
        case .endpoint(_, _, let service), .server(_, let service): service
        case .service(let service): .some(service)
        }
    }

    private var name: String {
        switch row {
        case .endpoint(let slot, _, let service):
            service?.name ?? MenuBarPresentation.modelName(slot.modelPath, models: models)
        case .server(let server, _):
            (HFRepoID.forPath(server.modelIdentity) ?? URL(fileURLWithPath: server.modelIdentity).lastPathComponent)
                + (server.adapterSummary.map { " · " + $0 } ?? "")
        case .service(let service): service.name
        }
    }

    private var identity: String {
        switch row {
        case .endpoint(let slot, _, _): slot.modelPath
        case .server(let server, _): server.modelIdentity
        case .service(let service): service.modelPath ?? service.modelID
        }
    }

    private var facts: String {
        switch row {
        case .endpoint(let slot, _, _):
            "MLX Workbench · :\(slot.port) · "
                + MenuBarPresentation.availability(slot, state: endpoint.slotStates[slot.id], residency: endpoint.slotResidencies[slot.id])
        case .server(let server, _):
            [server.port.map { ":\($0)" }, server.residencySummary + ((server.activeRequests ?? 0) > 0 ? " · \(server.activeRequests ?? 0) active" : "")]
                .compactMap { $0 }.joined(separator: " · ")
        case .service(let service): service.providerName + " · " + service.statusText
        }
    }

    private var baseURL: String? {
        switch row {
        case .endpoint(let slot, _, _): "http://127.0.0.1:\(slot.port)/v1"
        case .server(let server, _): server.port.map { "http://127.0.0.1:\($0)/v1" }
        case .service(let service): service.baseURL
        }
    }

    private var modelID: String? {
        switch row {
        case .endpoint(let slot, _, _):
            ServedModelsSelection.connection(slot: slot, state: endpoint.slotStates[slot.id], servers: servers)?.modelName
        case .server(let server, _): server.modelIdentity
        case .service(let service): service.server != nil || service.hostedModel != nil ? service.modelID : nil
        }
    }

    private var factsColor: Color {
        if let service, service.stale || service.residency == .unknown { return WorkbenchColor.warning }
        return WorkbenchColor.muted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(name).font(WorkbenchTypography.label).lineLimit(1).truncationMode(.middle).help(identity)
            Text(facts).font(WorkbenchTypography.metadata).foregroundStyle(factsColor).lineLimit(2)
            HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
                ReclaimFlowLayout(spacing: WorkbenchSpacing.xs, lineSpacing: WorkbenchSpacing.xxs) { inlineActions }
                Spacer(minLength: WorkbenchSpacing.xs)
                Menu { copyActions } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: WorkbenchSize.Run.overflow)
                    .accessibilityLabel("Actions for \(name)")
            }
            .controlSize(.small)
            if let service {
                DisclosureGroup("Details", isExpanded: $detailsOpen) {
                    ServingServiceDetails(service: service, inventory: inventory)
                        .padding(.top, WorkbenchSpacing.xxs)
                }
                .font(WorkbenchTypography.metadata)
                .accessibilityLabel("Details for \(name)")
            }
        }
        .contextMenu { inlineActions; Divider(); copyActions }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("popover-serving-\(row.id)")
    }

    private func actionButtons(_ actions: [ServingRowAction], service: ServingServiceObservation?) -> some View {
        ForEach(actions, id: \.title) { action in
            switch action {
            case .unload:
                Button(action.title) { if let service { onReview(.unload, service) } }
                    .disabled(service.map { inventory.isChanging || !inventory.mayChange($0) } ?? true)
            case .stop:
                Button(action.title) { if let service { onReview(.stop, service) } }
                    .disabled(service.map { inventory.isChanging || !inventory.mayChange($0) } ?? true)
            case .openServing:
                Button(action.title) { onManage(row.id) }
            }
        }
    }

    @ViewBuilder private var inlineActions: some View {
        switch row {
        case .endpoint(let slot, _, let service):
            if slot.enabled {
                Button("Stop") {
                    Task {
                        guard historyLoaded, !occupancy.blocksStop(modelIdentity: slot.modelPath) else { return }
                        await endpoint.setSlotEnabled(id: slot.id, false)
                    }
                }
                .disabled(endpoint.isChanging || !historyLoaded || occupancy.blocksStop(modelIdentity: slot.modelPath))
            } else {
                Button("Start…") { onManage(row.id) }
                    .disabled(endpoint.isChanging || !historyLoaded || occupancy.blocksStop(modelIdentity: slot.modelPath))
            }
            if let service, service.canUnload {
                Button("Unload model…") { onReview(.unload, service) }
                    .disabled(inventory.isChanging || !inventory.mayChange(service))
            }
        case .server(_, let service):
            actionButtons(ResourceHeaderPresentation.serverActions(service: service), service: service)
        case .service(let service):
            actionButtons(ResourceHeaderPresentation.reviewActions(for: service), service: service)
        }
    }

    @ViewBuilder private var copyActions: some View {
        if let baseURL { Button("Copy base URL") { ServedModelsSelection.copy(baseURL) } }
        if let modelID { Button("Copy model ID") { ServedModelsSelection.copy(modelID) } }
    }
}

/// Shared entry point from Run and the toolbar resource popover.
struct ProcessMemoryButton: View {
    let onOpen: () -> Void
    var body: some View {
        Button(action: onOpen) {
            Label("What’s using memory…", systemImage: "list.bullet.rectangle")
        }
        .buttonStyle(.borderless)
        .font(WorkbenchTypography.secondary)
        .accessibilityIdentifier("inspect-process-memory")
        .help("Read the largest processes by resident memory without stopping anything")
    }
}

struct ProcessMemorySheet: View {
    @ObservedObject var resources: SystemResourceMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var activityMonitorError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    Text("What’s using memory").font(WorkbenchTypography.title)
                    Text("Largest processes by resident memory")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await resources.refreshProcesses() }
                }
                .disabled(resources.refreshingProcesses)
            }
            Text("Resident memory can include shared pages and omit GPU allocations. These values do not add up to system memory use or change the model-fit estimate.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            if let error = resources.processError {
                Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                    .accessibilityIdentifier("process-memory-error")
            }
            HStack {
                if resources.refreshingProcesses { ProgressView().controlSize(.small) }
                if let date = resources.processCapturedAt {
                    Text("Read \(date.formatted(date: .omitted, time: .standard)) · Refresh to update")
                        .accessibilityIdentifier("process-memory-timestamp")
                } else { Text(resources.processError == nil ? "Reading processes…" : "No reading available") }
            }
            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            Table(Array((resources.processMemory?.processes ?? []).prefix(15))) {
                TableColumn("Process") { process in
                    Text(process.name).lineLimit(1).help(process.name)
                }
                TableColumn("PID") { process in Text(String(process.pid)).monospacedDigit() }
                    .width(65)
                TableColumn("Resident RAM") { process in
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: process.residentBytes), countStyle: .memory))
                        .monospacedDigit()
                }.width(110)
            }
            .accessibilityIdentifier("process-memory-table")
            .frame(minHeight: 160, maxHeight: .infinity)
            Text("Up to 15 readable processes. Exited or unreadable processes are omitted. Process names may be shortened by macOS; they do not identify individual models or clients.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            if let activityMonitorError {
                Text(activityMonitorError).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
            }
            HStack {
                Button("Open Activity Monitor") {
                    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else {
                        activityMonitorError = "Activity Monitor could not be found."
                        return
                    }
                    NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
                        Task { @MainActor in
                            activityMonitorError = error == nil ? nil : "Activity Monitor could not be opened."
                        }
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(WorkbenchSpacing.lg)
        .frame(minWidth: 480, idealWidth: 580, maxWidth: 640, minHeight: 460, idealHeight: 520, maxHeight: 560)
        .task { await resources.refreshProcesses() }
    }
}

/// A cached view of explicit connections. Only its Refresh buttons read a host.
struct SavedModelHostsSection: View {
    @ObservedObject var hosts: ModelHostsCoordinator
    let onOpenHost: (ModelHost?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Saved model hosts").font(WorkbenchTypography.label)
            Text("Snapshots, refreshed individually. Reported model memory is separate from system headroom.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            if let error = hosts.storageError {
                Text(error).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
            }
            if hosts.hosts.isEmpty {
                Text("No saved connections").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                Button("Manage hosts…") { onOpenHost(nil) }.buttonStyle(.borderless)
            }
            ForEach(hosts.hosts) { host in
                hostRow(host)
            }
        }
        .accessibilityIdentifier("saved-model-hosts")
    }

    private func hostRow(_ host: ModelHost) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(host.name).font(WorkbenchTypography.label).lineLimit(2).help(host.baseURL)
                Spacer(minLength: WorkbenchSpacing.xs)
                Button("Open host") { onOpenHost(host) }
                    .accessibilityLabel("Open \(host.name) in Library")
                    .accessibilityIdentifier("open-resource-host-\(host.id)")
                Button { Task { await hosts.refresh(host.id) } } label: {
                    if hosts.refreshing.contains(host.id) { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(hosts.refreshing.contains(host.id))
                .help("Refresh this host's inventory and activity")
                .accessibilityLabel("Refresh \(host.name)")
                .accessibilityIdentifier("refresh-resource-host-\(host.id)")
            }
            Text(host.provider.title + " · " + host.baseURL)
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted).lineLimit(2)
            if let error = hosts.errors[host.id] {
                Text(error).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
            }
            if let inventory = hosts.inventories[host.id] {
                Text("Inventory read " + inventory.capturedAt.formatted(date: .abbreviated, time: .standard))
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                Text(inventory.activity.map { activity in
                    activity.state.title + " · checked " + activity.checkedAt.formatted(date: .abbreviated, time: .standard)
                } ?? "Activity unknown")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                Text(inventory.loadedStateSummary).font(WorkbenchTypography.secondary)
                if host.provider.adapter.reportsDeviceMemory { HostDeviceMemoryDisclosure(snapshot: inventory.deviceMemory) }
                ForEach(Array(inventory.reportedLoadedModels.prefix(3))) { model in
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                        Text(model.name).font(WorkbenchTypography.secondary).lineLimit(2)
                        Text(model.memoryBytes.map { "Host-reported memory: " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) }
                             ?? "Model memory unknown")
                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    }
                }
                if inventory.reportedLoadedModels.count > 3 {
                    Text("\(inventory.reportedLoadedModels.count - 3) more reported loaded · Open host to inspect")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
                if !inventory.warnings.isEmpty {
                    Text("Inventory has warnings · Open host for details")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
                }
            } else {
                Text("Not refreshed · loaded state and activity unknown")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
        }
        .buttonStyle(.borderless)
    }
}
