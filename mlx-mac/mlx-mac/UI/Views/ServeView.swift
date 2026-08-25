import SwiftUI

struct RunPresentation: Equatable {
    let workflow: ConversionWorkflow
    let model: LibraryModel?
    let servers: [ServerInfo]
    let runtimeAvailable: Bool
    let runtimeMessage: String

    var selectedCompletedModel: LibraryModel? {
        guard workflow.state == .completed,
              let completedPath = workflow.completedModelPath,
              let model,
              model.item.path == completedPath || model.outputPaths.contains(completedPath),
              model.readiness == .ready else { return nil }
        return model
    }
    var modelPath: String? { workflow.completedModelPath }
    var activeServer: ServerInfo? {
        guard let modelPath else { return nil }
        return servers.first(where: {
            $0.state?.lowercased() == "running" && $0.repo == modelPath
        })
    }
    var canPreview: Bool {
        selectedCompletedModel != nil && runtimeAvailable && workflow.serveState != .previewing && activeServer == nil
    }
    var canConfirm: Bool {
        selectedCompletedModel != nil && runtimeAvailable && workflow.serveState == .readyToConfirm
    }
    var remediation: String? { runtimeAvailable ? nil : runtimeMessage }
    var selectionError: String? {
        selectedCompletedModel == nil
            ? "Run requires a ready Library model that exactly matches the completed workflow output."
            : nil
    }
}

struct ServeView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var modelWorkflow: ModelWorkflowCoordinator
    private let onRouteSelection: (String) -> Void
    @State private var runtime = "mlx_lm"
    @State private var portText = ""

    init(appHost: AppHost, onRouteSelection: @escaping (String) -> Void = { _ in }) {
        self.appHost = appHost
        _modelWorkflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        self.onRouteSelection = onRouteSelection
    }

    private var selectedModel: LibraryModel? {
        let path = modelWorkflow.workflow.completedModelPath ?? appHost.selectedModelPath
        guard let path else { return nil }
        return appHost.librarySnapshot?.models.first(where: { $0.item.path == path || $0.outputPaths.contains(path) })
    }

    private var presentation: RunPresentation {
        RunPresentation(
            workflow: modelWorkflow.workflow,
            model: selectedModel,
            servers: modelWorkflow.servers,
            runtimeAvailable: appHost.runtimeReport.serve.ok,
            runtimeMessage: appHost.runtimeReport.serve.message
        )
    }

    private var port: Int? { Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Run").font(.title2)
                    Text("Preview and confirm serving the selected completed MLX model.")
                        .font(.callout).foregroundColor(.secondary)
                }
                selectedModelSection
                launchSection
                serverSection
            }
            .padding(24)
        }
        .task {
            await appHost.refreshWorkflowStatus()
        }
    }

    private var selectedModelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Selected completed model")
            if let model = selectedModel {
                Text(model.displayName).font(.title3).fontWeight(.semibold)
                detailLine("Model path", model.item.path)
                detailLine("Architecture", model.item.architecture ?? "Not reported")
                detailLine("Parameters", model.item.parameters ?? "Not reported")
                detailLine("Quantization", model.item.quantization ?? "Not reported")
                detailLine("Observed size", ByteCountFormatter.string(fromByteCount: model.item.bytes, countStyle: .file))
                detailLine("Library status", model.item.status)
                ErrorBanner(text: presentation.selectionError)
            } else {
                Text("Select a completed, ready MLX model from Library or Activity before running it.")
                    .font(.callout).foregroundColor(.secondary)
                Button("Open Library") { onRouteSelection("models") }
            }
        }
        .padding(16).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(12)
    }

    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Serve intent")
            if let remediation = presentation.remediation {
                ErrorBanner(text: "Run runtime unavailable: \(remediation). Open Settings after installing the required runtime.")
                Button("Open Settings") { onRouteSelection("settings") }
            }
            HStack {
                Picker("Runtime", selection: $runtime) {
                    Text("mlx_lm").tag("mlx_lm")
                    Text("mlx-vlm").tag("mlx-vlm")
                }
                .frame(width: 180)
                TextField("Port (optional)", text: $portText).textFieldStyle(.roundedBorder).frame(width: 140)
                Spacer()
            }
            detailLine("Serve state", modelWorkflow.workflow.serveState.rawValue)
            if let message = modelWorkflow.workflow.message {
                Text(message).font(.callout).foregroundColor(.secondary)
            }
            ErrorBanner(text: modelWorkflow.workflow.errorMessage)
            HStack {
                Button("Preview serve") {
                    Task { await modelWorkflow.previewServe(runtime: runtime, port: port) }
                }
                .disabled(!presentation.canPreview || modelWorkflow.isServeSubmissionInFlight)
                Button("Confirm and run") {
                    Task {
                        await modelWorkflow.confirmServe(runtime: runtime, port: port)
                        if modelWorkflow.workflow.serveState == .running { onRouteSelection("jobs") }
                    }
                }
                .disabled(!presentation.canConfirm || modelWorkflow.isServeSubmissionInFlight)
            }
            .buttonStyle(.bordered)
        }
        .padding(16).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(12)
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "Authoritative server state")
                Spacer()
                Button("Refresh") { Task { await appHost.refreshWorkflowStatus() } }
            }
            if let server = presentation.activeServer {
                HStack {
                    StatusPill(state: server.state ?? "unknown")
                    Text(server.repo ?? "Unknown model").font(.headline)
                    Spacer()
                    Button("Stop server") {
                        Task {
                            guard let modelPath = presentation.modelPath else { return }
                            await modelWorkflow.stopServer(modelPath: modelPath)
                            if modelWorkflow.workflow.serveState == .stopped { onRouteSelection("jobs") }
                        }
                    }
                    .disabled(modelWorkflow.isServeSubmissionInFlight)
                }
                detailLine("Port", server.port.map(String.init) ?? "Not reported")
                detailLine("PID", server.pid.map(String.init) ?? "Not reported")
                Text(server.receipt ?? "Not reported")
                    .accessibilityIdentifier("active-server-receipt")
                detailLine("Receipt", server.receipt ?? "Not reported")
                detailLine("Log path", server.logPath ?? "Not reported")
                detailLine("Started", server.startedAt ?? "Not reported")
            } else {
                Text("No running server is reported.").font(.callout).foregroundColor(.secondary)
            }
        }
        .padding(16).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(12)
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundColor(.secondary).frame(width: 120, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }
}
