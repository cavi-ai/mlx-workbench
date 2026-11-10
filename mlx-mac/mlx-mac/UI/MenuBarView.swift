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
    @ObservedObject private var inventory: ServingInventoryCoordinator
    @AppStorage(AppRoute.selectionStorageKey) private var selectedRouteID = AppRoute.overview.rawValue

    init(appHost: AppHost) {
        self.appHost = appHost
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _workflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _comparison = ObservedObject(wrappedValue: appHost.comparison)
        _inventory = ObservedObject(wrappedValue: appHost.servingInventory)
    }

    var body: some View {
        Button {} label: {
            Label(ServingInventoryPresentation.summary(inventory.snapshot), systemImage: ServingInventoryPresentation.icon(inventory.snapshot, slots: endpoint.fleet.slots, states: endpoint.slotStates))
        }
        .disabled(true)
        ServingSystemHeadroom(resources: appHost.resources)
        if case .running = endpoint.state, let latest = latestBenchmark {
            Button {} label: { Label(latest, systemImage: "speedometer") }
                .disabled(true)
        }
        if let error = endpoint.lastError {
            Button {} label: { Label(error, systemImage: "exclamationmark.triangle") }
                .disabled(true)
        }
        if !inventory.snapshot.sourceErrors.isEmpty {
            Button("\(inventory.snapshot.sourceErrors.count) sources unavailable · Open Serving to inspect") { openManager() }
        }
        Divider()
        let models = appHost.librarySnapshot?.models ?? []
        let rows = ServingRows.build(slots: endpoint.fleet.slots, servers: workflow.servers, snapshot: inventory.snapshot)
        ForEach(rows) { row in
            Menu(MenuBarPresentation.rowTitle(row, models: models)) {
                switch row {
                case .endpoint(let slot, _, let service):
                    Text(MenuBarPresentation.availability(slot, state: endpoint.slotStates[slot.id], residency: endpoint.slotResidencies[slot.id]))
                    Text("MLX Workbench")
                    Button(slot.enabled ? "Stop" : "Start…") {
                        if slot.enabled {
                            Task {
                                guard comparison.hasLoadedHistory, !appHost.occupancy.blocksStop(modelIdentity: slot.modelPath) else { return }
                                await endpoint.setSlotEnabled(id: slot.id, false)
                            }
                        } else { openManager(rowID: row.id) }
                    }.disabled(endpoint.isChanging || !comparison.hasLoadedHistory || appHost.occupancy.blocksStop(modelIdentity: slot.modelPath))
                    if let service, service.canUnload {
                        Button("Unload model…") { prepare(.unload, service: service) }
                            .disabled(inventory.isChanging || !inventory.mayChange(service))
                    }
                    Button("Copy base URL") { ServedModelsSelection.copy("http://127.0.0.1:\(slot.port)/v1") }
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
            }
        }
        if rows.isEmpty {
            Button("No Workbench endpoints configured") {}.disabled(true)
        }
        Divider()
        Button("Open Serving") { openManager() }
        Button("Refresh local services") {
            Task {
                await workflow.refreshServers()
                await inventory.refresh(refreshHosts: true)
            }
        }
        .disabled(inventory.isRefreshing)
        Button("Open MLX Workbench") { openApp() }
        Button("Settings…") { selectedRouteID = AppRoute.settings.rawValue; openApp() }
        Divider()
        Button("Quit MLX Workbench") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Last measured tok/s for the served model, when comparison evidence
    /// exists — one honest number, not a dashboard.
    private var latestBenchmark: String? {
        guard case .running(let modelPath, _) = endpoint.state else { return nil }
        let match = appHost.benchmarkResults
            .filter { $0.modelID == modelPath }
            .sorted { $0.measuredAt > $1.measuredAt }
            .first
        guard let tps = match?.tokensPerSecond else { return nil }
        return String(format: "%.1f tok/s measured", tps)
    }

    private func openManager(rowID: String? = nil) {
        appHost.handoffs.send(ServingFocusRequest(rowID: rowID), as: .openServing)
        selectedRouteID = AppRoute.run.rawValue
        openApp()
    }

    /// Opens the main window on Run; a window already presenting a sheet keeps it, so the review waits.
    private func prepare(_ action: ServingActionKind, service: ServingServiceObservation) {
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

struct ServingInventoryMenuLabel: View {
    @ObservedObject var inventory: ServingInventoryCoordinator
    @ObservedObject var endpoint: EndpointSupervisor

    var body: some View {
        Label("MLX Workbench", systemImage: ServingInventoryPresentation.icon(inventory.snapshot, slots: endpoint.fleet.slots, states: endpoint.slotStates))
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
