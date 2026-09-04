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
            $0.state?.lowercased() == "running"
                && HFRepoID.serveIdentity(for: $0.repo ?? "") == HFRepoID.serveIdentity(for: modelPath)
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
    @State private var contextText = String(FitAdvisor.defaultContextTokens)
    @State private var endpointPortText = ""
    @State private var showLoginItemPreview = false
    @State private var loginItemMessage: String?
    @State private var loginItemMessageIsError = false

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
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                selectedModelSection
                launchSection
                endpointSection
                serverSection
            }
            .padding(WorkbenchSpacing.pageInset)
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

    // MARK: - Memory fit

    private var contextTokens: Int {
        Int(contextText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? FitAdvisor.defaultContextTokens
    }

    private var fitVerdict: FitVerdict? {
        guard let model = selectedModel else { return nil }
        return FitAdvisor.verdict(
            modelBytes: model.item.bytes > 0 ? model.item.bytes : nil,
            contextTokens: contextTokens,
            parameters: model.item.parameters,
            hardware: appHost.hardwareProfile,
            memory: MemorySnapshot.probe(),
            reserveBytes: Int64(appHost.config.fitReserveGB * 1_000_000_000)
        )
    }

    @ViewBuilder
    private var fitVerdictLine: some View {
        if let verdict = fitVerdict {
            HStack(spacing: 8) {
                Image(systemName: fitIcon(verdict))
                    .foregroundColor(fitColor(verdict))
                Text(verdict.summary)
                    .font(.caption)
                    .foregroundColor(fitColor(verdict))
                if case .wontFit(_, let suggestion) = verdict, let suggestion {
                    Button("Use \(suggestion) instead") {
                        contextText = String(suggestion)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func fitIcon(_ verdict: FitVerdict) -> String {
        switch verdict {
        case .fits: return "checkmark.circle.fill"
        case .tight: return "exclamationmark.circle.fill"
        case .wontFit: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func fitColor(_ verdict: FitVerdict) -> Color {
        switch verdict {
        case .fits: return WorkbenchColor.fluxTeal
        case .tight: return WorkbenchColor.thermalAmber
        case .wontFit: return WorkbenchColor.systemRed
        case .unknown: return .secondary
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.xs) { endpointEnableControls }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { endpointEnableControls }
                }
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
                Text(loginItemMessage)
                    .font(.caption)
                    .foregroundColor(loginItemMessageIsError ? WorkbenchColor.systemRed : WorkbenchColor.verifiedGreen)
            }
        }
        .formSection {}
    }

    private var loginItemControls: some View {
        HStack(spacing: 10) {
            if appHost.endpoint.config.installedAtLogin {
                Button("Remove login item") {
                    do {
                        try LaunchAgentManager().uninstall()
                        appHost.endpoint.markLoginItemInstalled(false)
                        loginItemMessageIsError = false
                        loginItemMessage = "Login item removed."
                    } catch {
                        loginItemMessageIsError = true
                        loginItemMessage = AppHost.render(error)
                    }
                }
            } else {
                Button("Install login item…") { showLoginItemPreview = true }
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
            loginItemMessageIsError = false
            loginItemMessage = "Login item installed."
            showLoginItemPreview = false
        } catch {
            loginItemMessageIsError = true
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
        .formSection {}
    }

    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Serve intent")
            if let remediation = presentation.remediation {
                ErrorBanner(text: "Run runtime unavailable: \(remediation). Open Settings after installing the required runtime.")
                Button("Open Settings") { onRouteSelection("settings") }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { launchFields }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { launchFields }
            }
            fitVerdictLine
            detailLine("Serve state", modelWorkflow.workflow.serveState.rawValue)
            if let message = modelWorkflow.workflow.message {
                Text(message).font(.callout).foregroundColor(.secondary)
            }
            ErrorBanner(text: modelWorkflow.workflow.errorMessage)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { serveActions }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { serveActions }
            }
        }
        .formSection {}
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
                detailLine("Receipt", server.receipt ?? "Not reported", accessibilityID: "active-server-receipt")
                detailLine("Log path", server.logPath ?? "Not reported")
                detailLine("Started", server.startedAt ?? "Not reported")
            } else {
                Text("No running server is reported.").font(.callout).foregroundColor(.secondary)
            }
        }
        .formSection {}
    }

    private func detailLine(_ title: String, _ value: String, accessibilityID: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundColor(WorkbenchColor.graphiteMuted).frame(width: 120, alignment: .leading)
            Group {
                if let accessibilityID {
                    Text(value).accessibilityIdentifier(accessibilityID)
                } else {
                    Text(value)
                }
            }
            .font(WorkbenchTypography.monoUtility)
            .foregroundColor(WorkbenchColor.graphiteInk)
            .textSelection(.enabled)
            Spacer()
        }
        .font(WorkbenchTypography.body)
    }

    @ViewBuilder
    private var endpointEnableControls: some View {
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
        .buttonStyle(.borderedProminent)
        .tint(WorkbenchColor.fluxTeal)
        .disabled(selectedModel == nil)
        Button("Enable anyway (unverified)") {
            Task {
                guard let model = selectedModel else { return }
                let port = Int(endpointPortText) ?? EndpointConfig.defaultPort
                await endpoint.enable(modelPath: model.item.path, port: port, allowUnverified: true)
            }
        }
        .buttonStyle(.bordered)
        .disabled(selectedModel == nil)
        .foregroundColor(WorkbenchColor.thermalAmber)
    }

    @ViewBuilder
    private var launchFields: some View {
        Picker("Runtime", selection: $runtime) {
            Text("mlx_lm").tag("mlx_lm")
            Text("mlx-vlm").tag("mlx-vlm")
        }
        .frame(maxWidth: 180, alignment: .leading)
        TextField("Port (optional)", text: $portText).textFieldStyle(.roundedBorder).frame(width: 140)
        TextField("Context", text: $contextText).textFieldStyle(.roundedBorder).frame(width: 90)
    }

    private func previewServeAction() {
        Task { await modelWorkflow.previewServe(runtime: runtime, port: port) }
    }

    private func confirmServeAction() {
        Task {
            await modelWorkflow.confirmServe(runtime: runtime, port: port)
            if modelWorkflow.workflow.serveState == .running { onRouteSelection("jobs") }
        }
    }

    @ViewBuilder
    private var serveActions: some View {
        // Exactly one action is armed at a time: preview until the intent is
        // ready to confirm, then confirm. The armed action is prominent.
        if presentation.canConfirm {
            Button("Preview serve", action: previewServeAction)
                .buttonStyle(.bordered)
                .disabled(!presentation.canPreview || modelWorkflow.isServeSubmissionInFlight)
            Button("Confirm and run", action: confirmServeAction)
                .buttonStyle(.borderedProminent)
                .tint(WorkbenchColor.fluxTeal)
                .disabled(modelWorkflow.isServeSubmissionInFlight)
        } else {
            Button("Preview serve", action: previewServeAction)
                .buttonStyle(.borderedProminent)
                .tint(WorkbenchColor.fluxTeal)
                .disabled(!presentation.canPreview || modelWorkflow.isServeSubmissionInFlight)
            Button("Confirm and run", action: confirmServeAction)
                .buttonStyle(.bordered)
                .disabled(!presentation.canConfirm || modelWorkflow.isServeSubmissionInFlight)
        }
    }
}
