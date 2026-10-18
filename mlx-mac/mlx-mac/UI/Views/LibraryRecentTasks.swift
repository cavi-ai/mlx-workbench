import SwiftUI

struct LibraryRecentTasks: View {
    @ObservedObject var coordinator: InferenceTaskCoordinator
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
            RecentTaskList(coordinator: coordinator, filterModel: nil, reuseModel: model)
        }
        .padding(WorkbenchSpacing.lg)
        .frame(minWidth: 560, minHeight: 520)
        .task { if isRouteActive { await coordinator.refreshRecent() } }
        .task(id: "\(isRouteActive):\(coordinator.selectedTask?.id ?? ""):\(coordinator.selectedTask?.state.wireValue ?? "")") {
            guard isRouteActive, let task = coordinator.selectedTask, task.state.isActive else {
                coordinator.stopPolling(owner: "recent-task-sheet")
                return
            }
            coordinator.startPolling(id: task.id, owner: "recent-task-sheet")
        }
        .onChange(of: isRouteActive) { _, active in
            if !active { coordinator.stopPolling(owner: "recent-task-sheet"); coordinator.stopPlayback() }
        }
        .onDisappear { coordinator.stopPolling(owner: "recent-task-sheet"); coordinator.stopPlayback() }
    }
}
