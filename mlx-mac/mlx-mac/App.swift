import SwiftUI
import AppKit

@main
struct MlxWorkbenchApp: App {
    @StateObject private var appHost = AppHost()
    
    var body: some Scene {
        WindowGroup {
            ContentView(appHost: appHost)
                .onAppear {
                    // Conversion Quality Gate: route completed conversions
                    // through canary verification. Idempotent.
                    appHost.verification.attach(to: appHost.modelWorkflow)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.expanded)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About mlx-workbench") {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "mlx-workbench"
                    alert.informativeText = "Version 1.0.0\nLocal MLX model management for Apple Silicon."
                    alert.runModal()
                }
            }
            CommandGroup(after: .windowList) {
                Button("Rescan Models") {
                    appHost.requestRescan()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
        Settings {
            SettingsView(appHost: appHost)
        }
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}
