import AppKit
import SwiftUI

// MARK: - MenuBarView
//
// Minimal menu-bar surface for the always-on endpoint (premium spec 06,
// phase 3). Status and plumbing actions only — deliberately no chat, no
// prompt field: the menu bar reports the endpoint, it is not a work surface.

struct MenuBarView: View {
    let appHost: AppHost
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var endpoint: EndpointSupervisor
    @ObservedObject private var workflow: ModelWorkflowCoordinator
    @ObservedObject private var comparison: ComparisonCoordinator

    init(appHost: AppHost) {
        self.appHost = appHost
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _workflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _comparison = ObservedObject(wrappedValue: appHost.comparison)
    }

    var body: some View {
        Button {} label: {
            Label(fleetSummary, systemImage: MenuBarPresentation.fleetIcon(slots: endpoint.fleet.slots, states: endpoint.slotStates))
        }
        .disabled(true)
        if case .running = endpoint.state, let latest = latestBenchmark {
            Button {} label: { Label(latest, systemImage: "speedometer") }
                .disabled(true)
        }
        if let error = endpoint.lastError {
            Button {} label: { Label(error, systemImage: "exclamationmark.triangle") }
                .disabled(true)
        }
        Divider()
        ForEach(endpoint.fleet.slots) { slot in
            Menu("\(MenuBarPresentation.modelName(slot.modelPath, models: appHost.librarySnapshot?.models ?? [])) · :\(String(slot.port))") {
                Text(MenuBarPresentation.availability(slot, state: endpoint.slotStates[slot.id], residency: endpoint.slotResidencies[slot.id]))
                Button(slot.enabled ? "Stop" : "Start…") {
                    if slot.enabled {
                        Task {
                            guard comparison.hasLoadedHistory, !appHost.occupancy.blocksStop(modelIdentity: slot.modelPath) else { return }
                            await endpoint.setSlotEnabled(id: slot.id, false)
                        }
                    } else { openManager() }
                }.disabled(endpoint.isChanging || !comparison.hasLoadedHistory || appHost.occupancy.blocksStop(modelIdentity: slot.modelPath))
                Button("Copy base URL") { ServedModelsSelection.copy("http://127.0.0.1:\(slot.port)/v1") }
                if let connection = ServedModelsSelection.connection(slot: slot, state: endpoint.slotStates[slot.id], servers: workflow.servers) {
                    Button("Copy model ID") { ServedModelsSelection.copy(connection.modelName) }
                }
            }
        }
        if endpoint.fleet.slots.isEmpty {
            Button("No endpoints configured") {}.disabled(true)
        }
        Divider()
        Button("Manage served models…") { openManager() }
        Button("Open MLX Workbench") { openApp() }
        Divider()
        Button("Quit MLX Workbench") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// "N of M endpoints running" across the fleet.
    private var fleetSummary: String {
        MenuBarPresentation.fleetSummary(slots: endpoint.fleet.slots, states: endpoint.slotStates)
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

    private func openManager() {
        openWindow(id: ServedModelsWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openApp() {
        openWindow(id: ServedModelsWindow.mainID)
        NSApp.activate(ignoringOtherApps: true)
    }

}

/// Strings the menu draws; pure so no file-system lookup happens during rendering.
enum MenuBarPresentation {
    /// The last path component, without resolving the path; an empty path reads "No model".
    static func modelName(_ path: String, models: [LibraryModel] = []) -> String {
        if let model = models.first(where: { $0.item.path == path || $0.outputPaths.contains(path) }) { return model.displayName }
        return path.isEmpty ? "No model" : NSString(string: path).lastPathComponent
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
