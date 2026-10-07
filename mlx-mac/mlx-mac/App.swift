import SwiftUI
import AppKit

@main
struct MlxWorkbenchApp: App {
    @StateObject private var appHost = AppHost()
    @AppStorage(AppRoute.selectionStorageKey) private var selectedRouteID = AppRoute.overview.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView(appHost: appHost)
                .onAppear {
                    // Premium feature toggles: attach the quality gate when
                    // enabled, start endpoint + watch monitoring per config.
                    appHost.applyFeatureToggles()
                    appHost.endpoint.startMonitoring()
                    appHost.resources.startMonitoring()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About mlx-workbench") {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "mlx-workbench"
                    alert.informativeText = "Version \(Self.marketingVersion)\nLocal MLX model management for Apple Silicon."
                    alert.runModal()
                }
            }
            CommandGroup(after: .windowList) {
                Button("Rescan Models") {
                    appHost.requestRescan()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            CommandGroup(after: .pasteboard) {
                IntakeMenuCommand(intake: appHost.intake)
            }
            // Settings is a workbench destination, so one draft state exists;
            // ⌘, selects it instead of opening a second Settings window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    selectedRouteID = AppRoute.settings.rawValue
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
        Window("Add from Hugging Face", id: IntakeWindow.id) {
            IntakeSheet(intake: appHost.intake, appHost: appHost, onRouteSelection: { selectedRouteID = $0.rawValue })
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 720, height: 640)
        MenuBarExtra("mlx-workbench", systemImage: EndpointIcon.name(forStates: appHost.endpoint.fleet.slots.filter(\.enabled).compactMap { appHost.endpoint.slotStates[$0.id] })) {
            MenuBarView(appHost: appHost)
        }
        .menuBarExtraStyle(.menu)
    }

    private static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
