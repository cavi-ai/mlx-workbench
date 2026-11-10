import SwiftUI

struct LibraryRecentTasks: View {
    let appHost: AppHost
    @ObservedObject private var oneOff: InferenceTaskCoordinator
    @ObservedObject private var sessions: ServedTaskSessions
    @State private var selectedID = "local"
    private var coordinator: InferenceTaskCoordinator {
        sessions.origins.first(where: { $0.id == selectedID }).flatMap { sessions.coordinator(for: $0) } ?? oneOff
    }
    init(appHost: AppHost, model: LibraryModel?) {
        self.appHost = appHost; self.model = model
        _oneOff = ObservedObject(wrappedValue: appHost.inferenceTasks)
        _sessions = ObservedObject(wrappedValue: appHost.servedTasks)
    }
    var model: LibraryModel?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRouteActive) private var isRouteActive

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack {
                Text("Recent tasks").font(WorkbenchTypography.pageTitle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("History", selection: $selectedID) {
                Text("One-off runs").tag("local")
                ForEach(sessions.origins) { origin in
                    Text("\(URL(fileURLWithPath: origin.server.path!).lastPathComponent) · :\(origin.server.port!) · \(origin.server.startedAt!)").tag(origin.id)
                }
            }.accessibilityIdentifier("task-history-destination")
            RecentTaskList(coordinator: coordinator, filterModel: nil, reuseModel: model).id(selectedID)
        }
        .padding(WorkbenchSpacing.lg)
        .frame(minWidth: 560, minHeight: 520)
        .task(id: selectedID) { if isRouteActive { await sessions.load(); await coordinator.refreshRecent() } }
        .task(id: "\(isRouteActive):\(coordinator.selectedTask?.id ?? ""):\(coordinator.selectedTask?.state.wireValue ?? "")") {
            guard isRouteActive, let task = coordinator.selectedTask, task.state.isActive else {
                coordinator.stopPolling(owner: "recent-task-sheet")
                return
            }
            coordinator.startPolling(id: task.id, owner: "recent-task-sheet")
        }
        .onChange(of: selectedID) { old, _ in
            let prior = sessions.origins.first(where: { $0.id == old }).flatMap { sessions.coordinator(for: $0) } ?? oneOff
            prior.stopPolling(owner: "recent-task-sheet"); prior.stopPlayback()
        }
        .onChange(of: isRouteActive) { _, active in
            if !active { coordinator.stopPolling(owner: "recent-task-sheet"); coordinator.stopPlayback() }
        }
        .onDisappear { coordinator.stopPolling(owner: "recent-task-sheet"); coordinator.stopPlayback() }
    }
}
