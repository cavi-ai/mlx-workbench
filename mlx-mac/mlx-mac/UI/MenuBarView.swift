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
            Text(endpoint.state.summary)
                .font(.headline)
            if case .running = endpoint.state, let latest = latestBenchmark {
                Text(latest)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let error = endpoint.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(WorkbenchColor.systemRed)
            }
            Divider()
            Button("Open mlx-workbench") { openApp() }
            if endpoint.config.enabled {
                Button("Restart endpoint") {
                    Task {
                        await appHost.endpoint.disable()
                        await appHost.endpoint.enable(
                            modelPath: endpoint.config.modelPath,
                            port: endpoint.config.port,
                            allowUnverified: true
                        )
                    }
                }
                Button("Stop endpoint") { Task { await endpoint.disable() } }
            }
            Divider()
            Button("Quit mlx-workbench") { NSApp.terminate(nil) }
        }
        .padding(8)
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
}
