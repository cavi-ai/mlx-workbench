import SwiftUI
import AppKit

@main
struct MlxWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(WorkbenchApplicationDelegate.self) private var appDelegate
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
        WindowGroup("3D mesh", id: ComparisonMeshInspection.windowID, for: ComparisonMeshInspection.self) { $inspection in
            if let inspection { ComparisonMeshInspector(inspection: inspection).workbenchTheme() }
        }
        .defaultSize(width: WorkbenchSize.Compare.meshInspectorWidth, height: WorkbenchSize.Compare.meshInspectorHeight)
        .commandsRemoved()
        MenuBarExtra {
            MenuBarView(appHost: appHost)
        } label: {
            ServingInventoryMenuLabel(inventory: appHost.servingInventory, endpoint: appHost.endpoint)
        }
        .menuBarExtraStyle(.menu)
    }

    private static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}

final class WorkbenchApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
