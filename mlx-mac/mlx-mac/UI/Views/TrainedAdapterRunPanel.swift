import SwiftUI

struct TrainedAdapterRunPanel: View {
    @ObservedObject var coordinator: TrainedAdapterServingCoordinator
    var saveAsEndpoint: ((TrainedAdapterServePreview, String?) async -> String?)? = nil
    let refresh: () async -> Void
    @State private var confirmingSave = false
    @State private var saveError: String?

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
                    if coordinator.supportsJIT {
                        Toggle("Load on request", isOn: $coordinator.loadOnRequest)
                            .disabled(coordinator.isBusy || coordinator.runningServer != nil)
                        Toggle("Require API key", isOn: $coordinator.requireAPIKey)
                            .disabled(coordinator.isBusy || coordinator.runningServer != nil)
                    }
                    ErrorBanner(text: coordinator.portError)
                    ErrorBanner(text: coordinator.errorMessage)
                    ErrorBanner(text: saveError)
                    if confirmingSave, let preview = coordinator.preview {
                        InlineMessage(kind: .warning, text: "This adapter does not inherit \(URL(fileURLWithPath: preview.binding.basePath).lastPathComponent)'s quality verdict. Saving enables an unverified MLX-LM endpoint on port \(preview.port).")
                    }
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
                        Text("Stop or unload it in Served models below.").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        if let digest = server.apiKeySHA256 {
                            Button("Copy API key") {
                                do { ServedModelsSelection.copyCredential(try EndpointCredentialStore.token(for: digest)) }
                                catch { saveError = AppHost.render(error) }
                            }
                        }
                    }
                    ReclaimFlowLayout(spacing: WorkbenchSpacing.sm, lineSpacing: WorkbenchSpacing.sm) {
                        if coordinator.canConfirm {
                            previewButton.buttonStyle(.bordered)
                            Button("Confirm and run adapter") { perform(coordinator.confirmServe()) }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("trained-adapter-confirm")
                            if saveAsEndpoint != nil {
                                if confirmingSave {
                                    Button("Save unverified endpoint") { saveEndpoint() }
                                        .accessibilityIdentifier("trained-adapter-save-endpoint")
                                } else {
                                    Button("Save as endpoint…") { saveError = nil; confirmingSave = true }
                                        .accessibilityIdentifier("trained-adapter-save-endpoint")
                                }
                            }
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
        Button("Preview adapter serve") { confirmingSave = false; saveError = nil; perform(coordinator.previewServe()) }
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
    private func saveEndpoint() {
        guard let preview = coordinator.preview, let saveAsEndpoint else { return }
        let key = coordinator.reviewedAPIKey
        confirmingSave = false
        Task {
            saveError = await saveAsEndpoint(preview, key)
            if saveError == nil { coordinator.clear() }
            await refresh()
        }
    }
}
