import AppKit
import SwiftUI

// MARK: - MenuBarView
//
// Minimal menu-bar surface for the always-on endpoint (premium spec 06,
// phase 3). Status and plumbing actions only — deliberately no chat, no
// prompt field: the menu bar reports the endpoint, it is not a work surface.

struct MenuBarView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var endpoint: EndpointSupervisor

    init(appHost: AppHost) {
        self.appHost = appHost
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
    }

    var body: some View {
        Button {} label: {
            Label(fleetSummary, systemImage: EndpointIcon.name(forStates: endpoint.fleet.slots.map { endpoint.slotStates[$0.id] ?? .disabled }))
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
            Button {
                Task { await endpoint.setSlotEnabled(id: slot.id, !slot.enabled) }
            } label: {
                Label(
                    MenuBarPresentation.slotTitle(slot),
                    systemImage: EndpointIcon.name(for: endpoint.slotStates[slot.id] ?? .disabled)
                )
            }
        }
        if endpoint.fleet.slots.isEmpty {
            Button("No endpoints configured") {}.disabled(true)
        }
        Divider()
        Button("Open MLX Workbench") { openApp() }
        Divider()
        Button("Quit MLX Workbench") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// "N of M endpoints running" across the fleet (spec 09 P2).
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

    private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}

/// Strings the menu draws; pure so no file-system lookup happens during rendering.
enum MenuBarPresentation {
    /// The last path component, without resolving the path.
    static func modelName(_ path: String) -> String {
        NSString(string: path).lastPathComponent
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
