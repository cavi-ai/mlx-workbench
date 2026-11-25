import AppKit
import SwiftUI

// MARK: - MenuBarView
//
// Cached local serving observations and the same rows and actions as Run.

struct MenuBarView: View {
    let appHost: AppHost
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var endpoint: EndpointSupervisor
    @ObservedObject private var workflow: ModelWorkflowCoordinator
    @ObservedObject private var comparison: ComparisonCoordinator
    @ObservedObject private var servedTasks: ServedTaskSessions
    @ObservedObject private var useWorkspace: UseWorkspaceCoordinator
    @ObservedObject private var inventory: ServingInventoryCoordinator
    @ObservedObject private var tailnet: TailnetSharingCoordinator
    @ObservedObject private var frontDoor: FrontDoorCoordinator
    @AppStorage(AppRoute.selectionStorageKey) private var selectedRouteID = AppRoute.library.rawValue

    init(appHost: AppHost) {
        self.appHost = appHost
        _servedTasks = ObservedObject(wrappedValue: appHost.servedTasks)
        _useWorkspace = ObservedObject(wrappedValue: appHost.useWorkspace)
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _workflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _comparison = ObservedObject(wrappedValue: appHost.comparison)
        _inventory = ObservedObject(wrappedValue: appHost.servingInventory)
        _tailnet = ObservedObject(wrappedValue: appHost.tailnetSharing)
        _frontDoor = ObservedObject(wrappedValue: appHost.frontDoor)
    }

    var body: some View {
        let models = appHost.librarySnapshot?.models ?? []
        let rows = ServingWorkspacePresentation.rows(ServingRows.build(slots: endpoint.fleet.slots, servers: workflow.servers, snapshot: inventory.snapshot), includeAvailable: false)
        let sections = MenuBarPresentation.sections(slots: endpoint.fleet.slots, rows: rows)
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                Text("Workbench").font(WorkbenchTypography.title)
                Spacer()
                ServingSystemHeadroom(resources: appHost.resources)
            }
            Text(MenuBarPresentation.fleetSummary(slots: endpoint.fleet.slots, states: endpoint.slotStates))
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            workbenchAPIRow()
            ForEach(sections.roles) { item in
                roleRow(item, models: models)
            }
            tailscaleRow()
            if let review = inventory.actionReview, review.surface == .menuBar {
                Divider()
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    Text(review.action.title).font(WorkbenchTypography.emphasis)
                    Text(review.service.name)
                    Text(ServingInventoryPresentation.actionNote(review.action))
                        .font(WorkbenchTypography.secondary).fixedSize(horizontal: false, vertical: true)
                    ErrorBanner(text: inventory.actionError(for: .menuBar))
                    HStack {
                        Button("Cancel") { inventory.cancelReview(surface: .menuBar) }.disabled(inventory.isChanging)
                        Spacer()
                        Button("Unload") { Task { await inventory.confirm(surface: .menuBar) } }
                            .disabled(inventory.isChanging || !inventory.mayChange(review.service))
                    }
                }
            } else if let error = inventory.actionError(for: .menuBar) {
                Divider()
                ErrorBanner(text: error)
            }
            if let error = endpoint.lastError {
                Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
            }
            if !inventory.snapshot.sourceErrors.isEmpty {
                Button("\(inventory.snapshot.sourceErrors.count) sources unavailable · Open Serving to inspect") { openManager() }
            }
            if !sections.others.isEmpty {
                Divider()
                DisclosureGroup(MenuBarPresentation.otherServersTitle(count: sections.others.count)) {
                    if sections.others.count > 5 {
                        ScrollView { modelActions(rows: sections.others, models: models) }.frame(height: 178)
                    } else {
                        modelActions(rows: sections.others, models: models)
                    }
                }
                .accessibilityIdentifier("serving-menu-other-servers")
            }
            Divider()
            HStack {
                Button("Open Serving") { openManager() }
                Button("Live Monitor") { selectedRouteID = AppRoute.monitor.rawValue; openApp() }
                Spacer()
                Button { Task { await workflow.refreshServers(); await inventory.refresh(refreshHosts: true, fresh: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh local services")
                .disabled(inventory.isRefreshing)
            }
            HStack {
                Button("Open Workbench") { openApp() }.accessibilityLabel("Open MLX Workbench")
                Button("Settings…") { selectedRouteID = AppRoute.settings.rawValue; openApp() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.accessibilityLabel("Quit MLX Workbench").keyboardShortcut("q")
            }
        }
        .padding(WorkbenchSpacing.md)
        .frame(width: 380, alignment: .leading)
        .task {
            if appHost.liveServicesStarted { await inventory.refresh(refreshHosts: true) }
        }
        .onDisappear { inventory.cancelReview(surface: .menuBar) }
    }

    @ViewBuilder
    private func modelActions(rows: [ServingRow], models: [LibraryModel]) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    ForEach(rows) { row in
                        HStack(spacing: WorkbenchSpacing.xs) {
                        if case .endpoint(let slot, _, _) = row {
                            Circle().fill(menuStateColor(slot)).frame(width: 8, height: 8).accessibilityHidden(true)
                        }
                        Text(MenuBarPresentation.rowTitle(row, models: models)).font(WorkbenchTypography.secondary)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: WorkbenchSpacing.xs)
                        Menu {
                            switch row {
                            case .endpoint(let slot, _, let service):
                                Text(MenuBarPresentation.availability(slot, state: endpoint.slotStates[slot.id], residency: endpoint.slotResidencies[slot.id]))
                                Text("MLX Workbench")
                                Button(slot.enabled ? "Stop" : "Start…") {
                                    if slot.enabled {
                                        Task {
                                            guard appHost.servedModelChange(identity: slot.modelPath, workbenchManaged: true).allowed else { return }
                                            await endpoint.setSlotEnabled(id: slot.id, false)
                                        }
                                    } else { openManager(rowID: row.id) }
                                }.disabled(slot.enabled
                                    ? !appHost.servedModelChange(identity: slot.modelPath, workbenchManaged: true).allowed
                                    : (endpoint.isChanging || !comparison.hasLoadedHistory || appHost.occupancy.blocksStop(modelIdentity: slot.modelPath)))
                                if let service, service.canUnload {
                                    Button("Unload model…") { prepare(.unload, service: service) }
                                        .disabled(inventory.isChanging || !inventory.mayChange(service))
                                }
                                Button("Copy base URL") { ServedModelsSelection.copy("http://127.0.0.1:\(slot.port)/v1") }
                                tailnetItems(port: slot.port)
                                if let connection = ServedModelsSelection.connection(slot: slot, state: endpoint.slotStates[slot.id], servers: workflow.servers) {
                                    Button("Copy model ID") { ServedModelsSelection.copy(connection.modelName) }
                                }
                            case .server(let server, let service):
                                Text(server.residencySummary)
                                if let service, service.canUnload || service.canStop {
                                    if service.canUnload {
                                        Button(ServingInventoryPresentation.unloadTitle(for: service)) { prepare(.unload, service: service) }
                                            .disabled(inventory.isChanging || !inventory.mayChange(service))
                                    }
                                    if service.canStop {
                                        Button("Stop server…") { prepare(.stop, service: service) }
                                            .disabled(inventory.isChanging || !inventory.mayChange(service))
                                    }
                                } else {
                                    Button("Open Serving") { openManager(rowID: row.id) }
                                }
                                if let port = server.port {
                                    Button("Copy base URL") { ServedModelsSelection.copy("http://127.0.0.1:\(port)/v1") }
                                }
                                tailnetItems(port: server.port)
                                Button("Copy model ID") { ServedModelsSelection.copy(server.modelIdentity) }
                            case .service(let service):
                                Text(service.statusText)
                                if let endpoint = service.baseURL { Text(endpoint) }
                                if let path = service.modelPath { Text(path) }
                                else { Text("Model/cache path not reported") }
                                if service.canUnload {
                                    Button(ServingInventoryPresentation.unloadTitle(for: service)) { prepare(.unload, service: service) }
                                        .disabled(inventory.isChanging || !inventory.mayChange(service))
                                }
                                if service.canStop {
                                    Button("Stop server…") { prepare(.stop, service: service) }
                                        .disabled(inventory.isChanging || !inventory.mayChange(service))
                                }
                                if let endpoint = service.baseURL {
                                    Button("Copy base URL") { ServedModelsSelection.copy(endpoint) }
                                }
                                if service.server != nil || service.hostedModel != nil {
                                    Button("Copy model ID") { ServedModelsSelection.copy(service.modelID) }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").accessibilityLabel("Actions")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                        .accessibilityIdentifier("serving-menu-endpoint-\(row.id)")
                    }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The shared Workbench API address and its copy action, shown once it is set up.
    @ViewBuilder
    private func workbenchAPIRow() -> some View {
        let row = ServingRolesPresentation.workbenchAPIRow(settings: endpoint.fleet.frontDoor, isRunning: frontDoor.isRunning, slots: endpoint.fleet.slots)
        if row.isConfigured {
            HStack {
                Label(row.title, systemImage: "point.3.connected.trianglepath.dotted").font(WorkbenchTypography.emphasis)
                Text(row.address).font(WorkbenchTypography.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: WorkbenchSpacing.xs)
                Text(row.stateText).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                Button(row.copyAddressTitle) { ServedModelsSelection.copy(row.address) }
            }
            .accessibilityIdentifier("serving-menu-workbench-api")
        }
    }

    @ViewBuilder
    private func tailscaleRow() -> some View {
        if let address = tailnet.sharedAddress(port: tailnet.status?.endpointPort) {
            HStack {
                Label("Tailscale", systemImage: "network").font(WorkbenchTypography.emphasis)
                Text(address).font(WorkbenchTypography.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: WorkbenchSpacing.xs)
                Button("Copy Tailscale URL") { ServedModelsSelection.copy(address) }
                Button("Stop sharing") { Task { await tailnet.stop() } }.disabled(tailnet.busy)
            }
            .accessibilityIdentifier("serving-menu-tailscale")
        }
    }

    /// One role: symbol, title, model, port and residency, then its copy and Unload or Stop actions.
    @ViewBuilder
    private func roleRow(_ item: ServingRolesPresentation.RoleRow, models: [LibraryModel]) -> some View {
        if let slot = item.slot {
            let service = ServingInventoryPresentation.service(for: slot, in: inventory.snapshot)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Button { openManager(rowID: "endpoint-\(slot.id.uuidString)") } label: {
                    HStack {
                        Label(item.title, systemImage: item.role.symbolName).font(WorkbenchTypography.emphasis)
                        Text(MenuBarPresentation.modelName(slot.modelPath, models: models)).lineLimit(1)
                        Text(item.portText).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        Spacer()
                        Text(roleAvailability(slot)).font(WorkbenchTypography.secondary)
                    }
                }.buttonStyle(.plain)
                HStack {
                    Button("Copy base URL") { ServedModelsSelection.copy("http://127.0.0.1:\(slot.port)/v1") }
                    if let connection = ServedModelsSelection.connection(slot: slot, state: endpoint.slotStates[slot.id], servers: workflow.servers) {
                        Button("Copy model ID") { ServedModelsSelection.copy(connection.modelName) }
                    }
                    if let service, service.canUnload, service.residency == .loaded {
                        Button("Unload") { prepare(.unload, service: service) }
                            .disabled(inventory.isChanging || !inventory.mayChange(service))
                    } else if slot.enabled {
                        Button("Stop") {
                            Task {
                                guard appHost.servedModelChange(identity: slot.modelPath, workbenchManaged: true).allowed else { return }
                                await endpoint.setSlotEnabled(id: slot.id, false)
                            }
                        }.disabled(!appHost.servedModelChange(identity: slot.modelPath, workbenchManaged: true).allowed)
                    }
                    Spacer()
                }
                .buttonStyle(.borderless).controlSize(.small).font(WorkbenchTypography.secondary)
            }
            .accessibilityIdentifier("serving-menu-role-\(item.role.rawValue)")
        }
    }

    private func menuStateColor(_ slot: EndpointSlot) -> Color {
        if case .running = endpoint.slotStates[slot.id] { return WorkbenchColor.success }
        return slot.enabled ? WorkbenchColor.warning : WorkbenchColor.muted
    }

    private func roleAvailability(_ slot: EndpointSlot) -> String {
        guard let state = endpoint.slotStates[slot.id], case .running = state else { return "Unavailable" }
        switch ServingInventoryPresentation.service(for: slot, in: inventory.snapshot)?.residency {
        case .loaded: return "Loaded"
        case .unloaded: return "Unloaded"
        case .loading: return "Loading"
        default: return MenuBarPresentation.availability(slot, state: endpoint.slotStates[slot.id], residency: endpoint.slotResidencies[slot.id])
        }
    }

    /// The Tailscale address and stop action for the endpoint this app shares on `port`.
    @ViewBuilder
    private func tailnetItems(port: Int?) -> some View {
        if let address = tailnet.sharedAddress(port: port) {
            Text("Shared via Tailscale")
            Button("Copy Tailscale URL") { ServedModelsSelection.copy(address) }
            Button("Stop sharing") { Task { await tailnet.stop() } }.disabled(tailnet.busy)
        }
    }

    private func openManager(rowID: String? = nil) {
        appHost.handoffs.send(ServingFocusRequest(rowID: rowID), as: .openServing)
        selectedRouteID = AppRoute.run.rawValue
        openApp()
    }

    /// Opens the main window on Run; a window already presenting a sheet keeps it, so the review waits.
    private func prepare(_ action: ServingActionKind, service: ServingServiceObservation) {
        if action == .unload, service.isWorkbenchManaged {
            Task { await inventory.prepare(action, service: service, surface: .menuBar) }
            return
        }
        selectedRouteID = AppRoute.run.rawValue
        openApp()
        guard !NSApp.windows.contains(where: { $0.attachedSheet != nil }) else { return }
        Task { await inventory.prepare(action, service: service) }
    }

    private func openApp() {
        openWindow(id: ServedModelsWindow.mainID)
        NSApp.activate(ignoringOtherApps: true)
    }

}

enum WorkbenchMenuBarItem {
    static let title = "MLX Workbench"
    static let systemImage = "cpu"
    static let storageKey = "showsWorkbenchMenuBarItem"

    /// Writes only a changed value; returns whether it wrote. An absent key reads as shown.
    static func store(_ shown: Bool, in defaults: UserDefaults) -> Bool {
        guard shown != (defaults.object(forKey: storageKey) as? Bool ?? true) else { return false }
        defaults.set(shown, forKey: storageKey)
        return true
    }
}

/// Strings the menu draws; pure so no file-system lookup happens during rendering.
enum MenuBarPresentation {
    /// The last path component, without resolving the path; an empty path reads "No model".
    static func modelName(_ path: String, models: [LibraryModel] = []) -> String {
        if let model = models.first(where: { $0.item.path == path || $0.outputPaths.contains(path) }) { return model.displayName }
        return path.isEmpty ? "No model" : NSString(string: path).lastPathComponent
    }

    /// The menu title for one served row: endpoints and servers read "name · :port", other services "name · provider · status".
    static func rowTitle(_ row: ServingRow, models: [LibraryModel] = []) -> String {
        switch row {
        case .endpoint(let slot, _, _): "\(modelName(slot.modelPath, models: models)) · :\(slot.port)"
        case .server(let server, _):
            (HFRepoID.forPath(server.modelIdentity) ?? modelName(server.modelIdentity))
                + (server.adapterSummary.map { " · " + $0 } ?? "") + (server.port.map { " · :\($0)" } ?? "")
        case .service(let service): service.name + " · " + service.providerName + " · " + service.statusText
        }
    }

    /// Assigned roles get top-level rows; role-less slots and servers outside the fleet go under "Other servers".
    struct Sections {
        let roles: [ServingRolesPresentation.RoleRow]
        let others: [ServingRow]
    }

    static func sections(slots: [EndpointSlot], rows: [ServingRow]) -> Sections {
        let roles = ServingRolesPresentation.roleRows(slots: slots, rows: rows).filter(\.isAssigned)
        let shown = Set(roles.compactMap { $0.slot?.id })
        let others = rows.filter { row in
            if case .endpoint(let slot, _, _) = row { return !shown.contains(slot.id) }
            return true
        }
        return Sections(roles: roles, others: others)
    }

    static func otherServersTitle(count: Int) -> String { "Other servers (\(count))" }

    static func availability(_ slot: EndpointSlot, state: EndpointState?, residency: String?) -> String {
        guard slot.enabled else { return "Stopped" }
        switch state {
        case .running:
            return slot.usesJIT ? "Available · \(residency ?? "residency unknown")" : "Running"
        case .some(let state): return state.summary
        case nil: return "Checking status…"
        }
    }

    /// The icon for the enabled slots; the header and the status item share it.
    static func fleetIcon(slots: [EndpointSlot], states: [UUID: EndpointState]) -> String {
        EndpointIcon.name(forStates: slots.filter(\.enabled).compactMap { states[$0.id] })
    }

    /// The menu item for one slot: the action it performs, then the model and port.
    static func slotTitle(_ slot: EndpointSlot) -> String {
        "\(slot.enabled ? "Stop" : "Start") \(modelName(slot.modelPath)) · :\(slot.port)"
    }

    static func fleetSummary(slots: [EndpointSlot], states: [UUID: EndpointState]) -> String {
        let enabled = slots.filter { $0.enabled && !$0.modelPath.isEmpty }
        guard !enabled.isEmpty else { return "No always-on endpoints" }
        let running = enabled.filter { slot in
            if case .running = states[slot.id] { return true }
            return false
        }.count
        let noun = enabled.count == 1 ? "endpoint" : "endpoints"
        return "\(running) of \(enabled.count) \(noun) running"
    }
}

/// Menu-bar icon reflects endpoint state at a glance.
enum EndpointIcon {
    static func name(for state: EndpointState) -> String {
        switch state {
        case .running: return "bolt.fill"
        case .starting, .waitingForServer: return "bolt.horizontal"
        case .degraded, .modelMismatch: return "exclamationmark.triangle"
        case .disabled: return "bolt.slash"
        }
    }

    /// Fleet aggregate: the worst state wins (degraded > starting > running
    /// > idle), so the icon never hides a problem behind a healthy slot.
    static func name(forStates states: [EndpointState]) -> String {
        var sawStarting = false
        var sawRunning = false
        for state in states {
            switch state {
            case .degraded, .modelMismatch: return "exclamationmark.triangle"
            case .starting, .waitingForServer: sawStarting = true
            case .running: sawRunning = true
            case .disabled: break
            }
        }
        if sawStarting { return "bolt.horizontal" }
        if sawRunning { return "bolt.fill" }
        return "bolt.slash"
    }
}
