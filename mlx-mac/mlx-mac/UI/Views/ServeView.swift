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
    var modelPath: String? {
        guard selectedCompletedModel != nil else { return nil }
        return workflow.completedModelPath
    }
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
    @ObservedObject private var endpoint: EndpointSupervisor
    private let onRouteSelection: (String) -> Void
    @State private var runtime = "mlx_lm"
    @State private var portText = ""
    @State private var endpointPortText = ""
    @State private var showLoginItemPreview = false
    @State private var loginItemMessage: String?

    init(appHost: AppHost, onRouteSelection: @escaping (String) -> Void = { _ in }) {
        self.appHost = appHost
        _modelWorkflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
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
                endpointSection
                serverSection
            }
            .padding(24)
        }
        .task {
            await appHost.refreshWorkflowStatus()
        }
        .onAppear {
            if endpointPortText.isEmpty {
                endpointPortText = String(appHost.endpoint.config.port)
            }
        }
    }

    // MARK: - Always-on endpoint

    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Always-on endpoint")
            Text("Keep the selected model serving on a stable loopback port, across restarts and model swaps. Clients wired in Wire keep working.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                StatusPill(state: endpoint.config.enabled ? "enabled" : "disabled")
                Text(endpoint.state.summary).font(.callout)
                Spacer()
                if endpoint.restartAttempts > 0 && endpoint.config.enabled {
                    Text("\(endpoint.restartAttempts) restart(s)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if case .modelMismatch = endpoint.state {
                Button("Swap to configured model") {
                    Task { await endpoint.swap(to: endpoint.config.modelPath, allowUnverified: true) }
                }
                .buttonStyle(.bordered)
            }

            if !endpoint.config.enabled {
                HStack(spacing: 10) {
                    TextField("Port", text: $endpointPortText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Button("Enable for selected model") {
                        Task {
                            guard let model = selectedModel else { return }
                            let port = Int(endpointPortText) ?? EndpointConfig.defaultPort
                            await endpoint.enable(modelPath: model.item.path, port: port)
                        }
                    }
                    .disabled(selectedModel == nil)
                    Button("Enable anyway (unverified)") {
                        Task {
                            guard let model = selectedModel else { return }
                            let port = Int(endpointPortText) ?? EndpointConfig.defaultPort
                            await endpoint.enable(modelPath: model.item.path, port: port, allowUnverified: true)
                        }
                    }
                    .disabled(selectedModel == nil)
                    .foregroundColor(.orange)
                }
                .buttonStyle(.bordered)
            } else {
                HStack(spacing: 10) {
                    Button("Disable endpoint") {
                        Task { await endpoint.disable() }
                    }
                    loginItemControls
                }
                .buttonStyle(.bordered)
            }

            ErrorBanner(text: endpoint.lastError)
            ErrorBanner(text: endpoint.persistenceError)
            if let loginItemMessage {
                Text(loginItemMessage).font(.caption).foregroundColor(.green)
            }
        }
        .padding(16).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(12)
    }

    private var loginItemControls: some View {
        HStack(spacing: 10) {
            if appHost.endpoint.config.installedAtLogin {
                Button("Remove login item") {
                    do {
                        try LaunchAgentManager().uninstall()
                        appHost.endpoint.markLoginItemInstalled(false)
                        loginItemMessage = "Login item removed."
                    } catch {
                        loginItemMessage = AppHost.render(error)
                    }
                }
            } else {
                Button("Install login item…") { showLoginItemPreview.toggle() }
            }
            if showLoginItemPreview, !appHost.endpoint.config.installedAtLogin {
                Button("Confirm install") { installLoginItem() }
            }
        }
        .sheet(isPresented: $showLoginItemPreview) {
            loginItemPreviewSheet
        }
    }

    private var loginItemPreviewSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Login item preview").font(.headline)
            Text("This LaunchAgent starts the endpoint once at login (RunAtLoad). The app keeps reconciling while it runs; mlx-agent receipts remain the process authority.")
                .font(.caption)
                .foregroundColor(.secondary)
            ScrollView {
                Text(loginItemPlistText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { showLoginItemPreview = false }
                Spacer()
                Button("Confirm install") { installLoginItem() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 640, height: 420)
    }

    private var agentRootPath: String {
        appHost.config.mlxAgentPath.isEmpty ? appHost.vendorAgentPath : appHost.config.mlxAgentPath
    }

    private var loginItemPlistText: String {
        (try? LaunchAgentManager().plistPreview(
            config: appHost.endpoint.config,
            agentPath: agentRootPath
        )) ?? "plist preview unavailable"
    }

    private func installLoginItem() {
        do {
            try LaunchAgentManager().install(
                config: appHost.endpoint.config,
                agentPath: agentRootPath
            )
            appHost.endpoint.markLoginItemInstalled(true)
            loginItemMessage = "Login item installed."
            showLoginItemPreview = false
        } catch {
            loginItemMessage = AppHost.render(error)
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
