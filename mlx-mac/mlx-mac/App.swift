import SwiftUI
import AppKit

@main
struct MlxWorkbenchApp: App {
    @State private var appHost = AppHost()
    @AppStorage(AppRoute.selectionStorageKey) private var selectedRouteID = AppRoute.overview.rawValue

    var body: some Scene {
        Window("MLX Workbench", id: ServedModelsWindow.mainID) {
            ContentView(appHost: appHost)
                .workbenchTheme()
                .onAppear {
                    appHost.startLiveServices()
                }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: WorkbenchSize.windowDefaultWidth, height: WorkbenchSize.windowDefaultHeight)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MLX Workbench") {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "MLX Workbench"
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
                .workbenchTheme()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 720, height: 640)
        Window("Served models", id: ServedModelsWindow.id) {
            ServedModelsView(appHost: appHost).workbenchTheme()
        }
        .defaultSize(width: 640, height: 620)
        MenuBarExtra("MLX Workbench", systemImage: MenuBarPresentation.fleetIcon(slots: appHost.endpoint.fleet.slots, states: appHost.endpoint.slotStates)) {
            MenuBarView(appHost: appHost)
        }
        .menuBarExtraStyle(.menu)
    }

    private static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
