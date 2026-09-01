import SwiftUI
import AppKit

@main
struct MlxWorkbenchApp: App {
    @StateObject private var appHost = AppHost()
    
    var body: some Scene {
        WindowGroup {
            ContentView(appHost: appHost)
                .onAppear {
                    // Premium feature toggles: attach the quality gate when
                    // enabled, start endpoint + watch monitoring per config.
                    appHost.applyFeatureToggles()
                    appHost.endpoint.startMonitoring()
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
        MenuBarExtra("mlx-workbench", systemImage: EndpointIcon.name(for: appHost.endpoint.state)) {
            MenuBarView(appHost: appHost)
        }
        .menuBarExtraStyle(.menu)
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}
