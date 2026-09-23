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
        VStack(alignment: .leading, spacing: 6) {
            Text(fleetSummary)
                .font(WorkbenchTypography.emphasis)
            if case .running = endpoint.state, let latest = latestBenchmark {
                Text(latest)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            if let error = endpoint.lastError {
                Text(error)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.failure)
            }
            Divider()
            ForEach(endpoint.fleet.slots) { slot in
                slotRow(slot)
            }
            if endpoint.fleet.slots.isEmpty {
                Text("No endpoints configured")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            Divider()
            Button("Open mlx-workbench") { openApp() }
            Divider()
            Button("Quit mlx-workbench") { NSApp.terminate(nil) }
        }
        .padding(8)
    }

    /// "N of M endpoints running" across the fleet (spec 09 P2).
    private var fleetSummary: String {
        let enabled = endpoint.fleet.slots.filter { $0.enabled && !$0.modelPath.isEmpty }
        guard !enabled.isEmpty else { return "No always-on endpoints" }
        let running = enabled.filter { isRunning(endpoint.slotStates[$0.id]) }.count
        let noun = enabled.count == 1 ? "endpoint" : "endpoints"
        return "\(running) of \(enabled.count) \(noun) running"
    }

    private func slotRow(_ slot: EndpointSlot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: EndpointIcon.name(for: endpoint.slotStates[slot.id] ?? .disabled))
                .frame(width: 14)
            Text("\(URL(fileURLWithPath: slot.modelPath).lastPathComponent) :\(slot.port)")
                .font(WorkbenchTypography.secondary)
                .lineLimit(1)
            Spacer()
            Button(slot.enabled ? "Stop" : "Start") {
                Task { await endpoint.setSlotEnabled(id: slot.id, !slot.enabled) }
            }
            .controlSize(.small)
        }
    }

    private func isRunning(_ state: EndpointState?) -> Bool {
        guard case .running = state else { return false }
        return true
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
