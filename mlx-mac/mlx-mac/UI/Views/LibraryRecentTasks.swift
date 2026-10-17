import SwiftUI

struct LibraryRecentTasks: View {
    @ObservedObject var coordinator: InferenceTaskCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRouteActive) private var isRouteActive

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack {
                Text("Recent tasks").font(WorkbenchTypography.pageTitle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            RecentTaskList(coordinator: coordinator)
        }
        .padding(WorkbenchSpacing.lg)
        .frame(minWidth: 560, minHeight: 520)
        .task { if isRouteActive { await coordinator.refreshRecent() } }
        .task(id: coordinator.selectedTask?.id) {
            while !Task.isCancelled && isRouteActive {
                guard let task = coordinator.selectedTask, task.state.isActive else { break }
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await coordinator.refresh(id: task.id)
            }
        }
    }
}
