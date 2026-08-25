import SwiftUI

struct RunPresentation: Equatable {
    let workflow: ConversionWorkflow
    let model: LibraryModel?
    let servers: [ServerInfo]
    let runtimeAvailable: Bool
    let runtimeMessage: String

    var modelPath: String? { model?.item.path ?? workflow.completedModelPath }
    var activeServer: ServerInfo? { servers.first(where: { $0.state?.lowercased() == "running" }) }
    var canPreview: Bool { model != nil && runtimeAvailable && workflow.serveState != .previewing && activeServer == nil }
    var canConfirm: Bool { model != nil && runtimeAvailable && workflow.serveState == .readyToConfirm }
    var remediation: String? { runtimeAvailable ? nil : runtimeMessage }
}

struct ServeView: View {
    @ObservedObject var appHost: AppHost
    private let onRouteSelection: (String) -> Void
    @State private var runtime = "mlx_lm"
    @State private var portText = ""

    init(appHost: AppHost, onRouteSelection: @escaping (String) -> Void = { _ in }) {
        self.appHost = appHost
        self.onRouteSelection = onRouteSelection
    }

    private var selectedModel: LibraryModel? {
        let path = appHost.selectedModelPath ?? appHost.modelWorkflow.workflow.completedModelPath
        guard let path else { return nil }
        return appHost.librarySnapshot?.models.first(where: { $0.item.path == path })
    }

    private var presentation: RunPresentation {
        RunPresentation(
            workflow: appHost.modelWorkflow.workflow,
            model: selectedModel,
            servers: appHost.modelWorkflow.servers,
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
            prepareSelectedModel()
            await appHost.modelWorkflow.refreshOperationalStatus()
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
            detailLine("Serve state", appHost.modelWorkflow.workflow.serveState.rawValue)
            if let message = appHost.modelWorkflow.workflow.message {
                Text(message).font(.callout).foregroundColor(.secondary)
            }
            ErrorBanner(text: appHost.modelWorkflow.workflow.errorMessage)
            HStack {
                Button("Preview serve") {
                    Task { await appHost.modelWorkflow.previewServe(runtime: runtime, port: port) }
                }
                .disabled(!presentation.canPreview)
                Button("Confirm and run") {
                    Task {
                        await appHost.modelWorkflow.confirmServe(runtime: runtime, port: port)
                        if appHost.modelWorkflow.workflow.serveState == .running { onRouteSelection("jobs") }
                    }
                }
                .disabled(!presentation.canConfirm)
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
                Button("Refresh") { Task { await appHost.modelWorkflow.refreshOperationalStatus() } }
            }
            if let server = presentation.activeServer {
                HStack {
                    StatusPill(state: server.state ?? "unknown")
                    Text(server.repo ?? "Unknown model").font(.headline)
                    Spacer()
                    Button("Stop server") {
                        Task {
                            await appHost.modelWorkflow.stopServer()
                            if appHost.modelWorkflow.workflow.serveState == .stopped { onRouteSelection("jobs") }
                        }
                    }
                }
                detailLine("Port", server.port.map(String.init) ?? "Not reported")
                detailLine("PID", server.pid.map(String.init) ?? "Not reported")
                detailLine("Receipt", server.receipt ?? "Not reported")
                detailLine("Log path", server.logPath ?? "Not reported")
                detailLine("Started", server.startedAt ?? "Not reported")
            } else {
                Text("No running server is reported.").font(.callout).foregroundColor(.secondary)
            }
        }
        .padding(16).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(12)
    }

    private func prepareSelectedModel() {
        guard let model = selectedModel,
              appHost.modelWorkflow.workflow.completedModelPath != model.item.path else { return }
        appHost.modelWorkflow.prepareServe(model: model)
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
