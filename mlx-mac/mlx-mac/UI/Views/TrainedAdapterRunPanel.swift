import SwiftUI

struct TrainedAdapterRunPanel: View {
    @ObservedObject var coordinator: TrainedAdapterServingCoordinator
    let refresh: () async -> Void

    var body: some View {
        if let job = coordinator.selectedJob {
            WorkbenchSurface(.tinted) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    HStack {
                        SectionTitle(text: "Serve trained adapter")
                        Spacer()
                        Button("Use Library model") { coordinator.clear() }
                            .buttonStyle(.bordered).controlSize(.small).disabled(coordinator.isBusy)
                    }
                    Text(job.repo).font(WorkbenchTypography.title).textSelection(.enabled)
                    Text("Review the base snapshot and adapter recorded by this completed training receipt.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    value("Training receipt", job.receipt)
                    value("Adapter", coordinator.preview?.binding.adapterPath ?? job.out)
                    HStack {
                        Text("Port").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        TextField("Default", text: $coordinator.portText)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: WorkbenchSize.Run.portField)
                            .accessibilityLabel("Trained adapter port").disabled(coordinator.isBusy)
                            .help("Leave blank to review the runtime's default port.")
                        Spacer()
                    }
                    ErrorBanner(text: coordinator.portError)
                    ErrorBanner(text: coordinator.errorMessage)
                    if coordinator.isBusy {
                        ProgressView(coordinator.operation == .previewing ? "Checking training artifacts…" : "Starting reviewed adapter server…")
                            .font(WorkbenchTypography.secondary)
                    }
                    if let preview = coordinator.preview {
                        Divider()
                        value("Pinned base", preview.binding.basePath)
                        value("Serving port", String(preview.port))
                        RawJSONDisclosure("Reviewed serve plan", value: preview.plan)
                    }
                    if let server = coordinator.runningServer {
                        Label("Trained adapter running on port \(server.port.map(String.init) ?? "unknown")", systemImage: "server.rack")
                            .font(WorkbenchTypography.emphasis)
                        Text("Stop or unload it in Now serving below.").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    }
                    ReclaimFlowLayout(spacing: WorkbenchSpacing.sm, lineSpacing: WorkbenchSpacing.sm) {
                        if coordinator.canConfirm {
                            previewButton.buttonStyle(.bordered)
                            Button("Confirm and run adapter") { perform(coordinator.confirmServe()) }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("trained-adapter-confirm")
                        } else {
                            previewButton.buttonStyle(.borderedProminent)
                        }
                    }.controlSize(.small)
                }.fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("trained-adapter-run")
        }
    }

    private var previewButton: some View {
        Button("Preview adapter serve") { perform(coordinator.previewServe()) }
            .disabled(!coordinator.canPreview).accessibilityIdentifier("trained-adapter-preview")
            .help("Recheck the completed receipt, pinned base and adapter before serving.")
    }
    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
            Text(label).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            Text(text).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func perform(_ task: Task<Void, Never>?) {
        guard let task else { return }
        Task { await task.value; await refresh() }
    }
}
