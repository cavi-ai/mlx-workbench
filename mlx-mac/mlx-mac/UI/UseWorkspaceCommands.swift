import SwiftUI

struct UseWorkspaceCommands: Commands {
    let appHost: AppHost
    @ObservedObject private var coordinator: UseWorkspaceCoordinator
    @ObservedObject private var workflow: ModelWorkflowCoordinator
    @Binding var selectedRouteID: String
    init(appHost: AppHost, selectedRouteID: Binding<String>) {
        self.appHost = appHost
        _coordinator = ObservedObject(wrappedValue: appHost.useWorkspace)
        _workflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _selectedRouteID = selectedRouteID
    }
    private var canSend: Bool {
        coordinator.canSend && workflow.serversError == nil && appHost.librarySnapshot?.models.contains {
            !UseMode.modes(for: $0).isEmpty && Quarantine.resolve($0.item.path) == coordinator.selected.map { Quarantine.resolve($0.modelPath) }
        } == true
    }
    var body: some Commands {
        CommandMenu("Conversation") {
            Button("Send message") { coordinator.send() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(AppRoute(rawID: selectedRouteID) != .use || !canSend)
            Button("Stop waiting") { coordinator.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!coordinator.isSending)
        }
    }
}
