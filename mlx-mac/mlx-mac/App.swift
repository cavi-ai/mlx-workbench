import SwiftUI
import AppKit
import Darwin

@main
struct MlxWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(WorkbenchApplicationDelegate.self) private var appDelegate
    @State private var appHost = AppHost()
    @AppStorage(AppRoute.selectionStorageKey) private var selectedRouteID = AppRoute.library.rawValue

    init() {
        if CommandLine.arguments.contains("--check-installation") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let result = ["protocol": "workbench-installation/1", "application": Bundle.main.bundleURL.path,
                          "engine": ConfigModule().load().mlxAgentPath,
                          "commit": Bundle.main.object(forInfoDictionaryKey: "MLXWorkbenchCommit") as? String ?? "unknown"]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(0)
            }
            exit(1)
        }
    }

    var body: some Scene {
        Window("MLX Workbench", id: ServedModelsWindow.mainID) {
            ContentView(appHost: appHost)
                .workbenchTheme()
                .onAppear {
                    appDelegate.prepareToQuit = { await appHost.useWorkspace.prepareForQuit() }
                    appHost.startLiveServices()
                }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: WorkbenchSize.windowDefaultWidth, height: WorkbenchSize.windowDefaultHeight)
        .commands {
            UseWorkspaceCommands(appHost: appHost, selectedRouteID: $selectedRouteID)
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
                .onAppear { appHost.startLiveServices() }
        }
        .menuBarExtraStyle(.menu)
    }

    private static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}

@MainActor
final class WorkbenchApplicationDelegate: NSObject, NSApplicationDelegate {
    var prepareToQuit: (() async -> Bool)?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareToQuit else { return .terminateNow }
        Task {
            if await prepareToQuit() { sender.reply(toApplicationShouldTerminate: true) }
            else { confirmQuitWithoutSaving(sender) }
        }
        return .terminateLater
    }
    private func confirmQuitWithoutSaving(_ sender: NSApplication) {
        let alert = NSAlert()
        alert.messageText = "Conversation could not be saved"
        alert.informativeText = "Keep Workbench open to save again or export the conversation."
        alert.addButton(withTitle: "Keep open")
        alert.addButton(withTitle: "Quit without saving")
        sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
