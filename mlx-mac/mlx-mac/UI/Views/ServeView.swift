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
                && HFRepoID.serveIdentity(for: $0.modelIdentity) == HFRepoID.serveIdentity(for: modelPath)
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
    @State private var newSlotRole: UseCase?
    @State private var pendingFleetAction: PendingFleetAction?
    @State private var showFleetRouter = false
    @State private var showLoginItemPreview = false

    /// A wont-fit fleet action awaiting the user's explicit override (spec
    /// 09 P3 — same escape-hatch discipline as the quality gate).
    private struct PendingFleetAction: Identifiable {
        let id = UUID()
        let summary: String
        let confirm: () -> Void
    }
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
                endpointPortText = String(suggestedPort)
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

    // MARK: - Endpoints (fleet, spec 09 P2)

    /// Smallest port from the default that no slot claims yet.
    private var suggestedPort: Int {
        var candidate = EndpointConfig.defaultPort
        let used = Set(endpoint.fleet.slots.map(\.port))
        while used.contains(candidate) { candidate += 1 }
        return candidate
    }

    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "Endpoints")
                Spacer()
                Text("\(endpoint.fleet.slots.count)/\(EndpointFleetConfig.maxSlots)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text("Keep models serving on stable loopback ports — one model per endpoint, across restarts and swaps. Clients wired in Wire keep working.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let verdict = prospectiveFleetVerdict(addingModelPath: nil) {
                HStack(spacing: 8) {
                    Image(systemName: fitIcon(verdict))
                        .foregroundColor(fitColor(verdict))
                    Text("Fleet memory: \(verdict.summary)")
                        .font(.caption)
                        .foregroundColor(fitColor(verdict))
                }
            }

            if let pending = pendingFleetAction {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fleet memory: \(pending.summary). Enable anyway?")
                        .font(.caption)
                        .foregroundColor(WorkbenchColor.systemRed)
                    HStack(spacing: 10) {
                        Button("Enable anyway") {
                            pending.confirm()
                            pendingFleetAction = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(WorkbenchColor.systemRed)
                        Button("Cancel") { pendingFleetAction = nil }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
            }

            if endpoint.fleet.slots.isEmpty {
                Text("No endpoints yet. Add one for the selected model.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                ForEach(endpoint.fleet.slots) { slot in
                    slotCard(slot)
                }
            }

            addEndpointControls

            if endpoint.fleet.slots.contains(where: { $0.role != nil }) {
                HStack(spacing: 10) {
                    Button("Wire roles…") { showFleetRouter = true }
                        .buttonStyle(.bordered)
                    Text("Map roles onto running endpoints via mlx-agent fleet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .sheet(isPresented: $showFleetRouter) {
                    FleetRouterSheet(appHost: appHost)
                }
            }

            loginItemSection

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

    private func slotCard(_ slot: EndpointSlot) -> some View {
        let slotState = endpoint.slotStates[slot.id] ?? .disabled
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusPill(state: slotStateLabel(slotState, enabled: slot.enabled))
                Text(URL(fileURLWithPath: slot.modelPath).lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                if let role = slot.role {
                    Text(role.title)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text(":\(slot.port)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                slotFitChip(slot)
                let attempts = endpoint.slotRestartAttempts[slot.id] ?? 0
                if attempts > 0 {
                    Text("\(attempts) restart(s)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Text(slotState.summary)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 10) {
                if case .modelMismatch = slotState {
                    Button("Swap to configured model") {
                        Task { await endpoint.swapSlot(id: slot.id, to: slot.modelPath, allowUnverified: true) }
                    }
                }
                Button(slot.enabled ? "Disable" : "Enable") {
                    if slot.enabled {
                        Task { await endpoint.setSlotEnabled(id: slot.id, false) }
                    } else {
                        enableSlotWithFitCheck(slot)
                    }
                }
                rolePicker(slot)
                Spacer()
                Button("Remove") { Task { await endpoint.removeSlot(id: slot.id) } }
                    .foregroundColor(WorkbenchColor.systemRed)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(WorkbenchSpacing.sm)
        .background(WorkbenchColor.alloyCanvas)
        .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
    }

    private func slotStateLabel(_ state: EndpointState, enabled: Bool) -> String {
        guard enabled else { return "disabled" }
        switch state {
        case .running: return "running"
        case .starting, .waitingForServer: return "starting"
        case .degraded: return "degraded"
        case .modelMismatch: return "mismatch"
        case .disabled: return "disabled"
        }
    }

    @ViewBuilder
    private func slotFitChip(_ slot: EndpointSlot) -> some View {
        if let verdict = slotFitVerdict(slot) {
            Image(systemName: fitIcon(verdict))
                .foregroundColor(fitColor(verdict))
                .help(verdict.summary)
        }
    }

    private func slotFitVerdict(_ slot: EndpointSlot) -> FitVerdict? {
        guard !slot.modelPath.isEmpty else { return nil }
        let model = appHost.librarySnapshot?.models.first(where: {
            $0.item.path == slot.modelPath || $0.outputPaths.contains(slot.modelPath)
        })
        return FitAdvisor.verdict(
            modelBytes: model.flatMap { $0.item.bytes > 0 ? $0.item.bytes : nil },
            contextTokens: FitAdvisor.defaultContextTokens,
            parameters: model?.item.parameters,
            hardware: appHost.hardwareProfile,
            memory: MemorySnapshot.probe(),
            reserveBytes: Int64(appHost.config.fitReserveGB * 1_000_000_000)
        )
    }

    private func rolePicker(_ slot: EndpointSlot) -> some View {
        Picker("Role", selection: Binding(
            get: { slot.role },
            set: { newRole in
                Task { await endpoint.updateSlot(id: slot.id, modelPath: slot.modelPath, port: slot.port, role: newRole) }
            }
        )) {
            Text("Unassigned").tag(UseCase?.none)
            ForEach(UseCase.allCases) { role in
                Text(role.title).tag(UseCase?.some(role))
            }
        }
        .labelsHidden()
        .frame(width: 120)
    }

    @ViewBuilder
    private var addEndpointControls: some View {
        if endpoint.fleet.slots.count >= EndpointFleetConfig.maxSlots {
            Text("Endpoint cap reached (\(EndpointFleetConfig.maxSlots)). Remove one to add another.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { addEndpointFields }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { addEndpointFields }
            }
        }
    }

    @ViewBuilder
    private var addEndpointFields: some View {
        TextField("Port", text: $endpointPortText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
        Picker("Role", selection: $newSlotRole) {
            Text("Unassigned").tag(UseCase?.none)
            ForEach(UseCase.allCases) { role in
                Text(role.title).tag(UseCase?.some(role))
            }
        }
        .labelsHidden()
        .frame(width: 120)
        Button("Add endpoint for selected model") { addEndpoint(allowUnverified: false) }
            .buttonStyle(.borderedProminent)
            .tint(WorkbenchColor.fluxTeal)
            .disabled(selectedModel == nil)
        Button("Add anyway (unverified)") { addEndpoint(allowUnverified: true) }
            .buttonStyle(.bordered)
            .disabled(selectedModel == nil)
            .foregroundColor(WorkbenchColor.thermalAmber)
    }

    private func addEndpoint(allowUnverified: Bool) {
        guard let model = selectedModel else { return }
        let port = Int(endpointPortText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? suggestedPort
        let role = newSlotRole
        let action = {
            _ = Task {
                await endpoint.addSlot(
                    modelPath: model.item.path,
                    port: port,
                    role: role,
                    allowUnverified: allowUnverified
                )
            }
        }
        if let verdict = prospectiveFleetVerdict(addingModelPath: model.item.path),
           case .wontFit = verdict {
            pendingFleetAction = PendingFleetAction(summary: verdict.summary, confirm: action)
            return
        }
        action()
    }

    /// Enabling a slot that tips the fleet past wont-fit needs the explicit
    /// override; tight is warned in place by the header verdict line.
    private func enableSlotWithFitCheck(_ slot: EndpointSlot) {
        let action = { _ = Task { await endpoint.setSlotEnabled(id: slot.id, true) } }
        if let verdict = prospectiveFleetVerdict(addingModelPath: slot.modelPath),
           case .wontFit = verdict {
            pendingFleetAction = PendingFleetAction(summary: verdict.summary, confirm: action)
            return
        }
        action()
    }

    // MARK: - Fleet memory budget (spec 09 P3)

    /// Summed verdict over enabled slots, or over enabled slots plus a
    /// candidate — nil when there is nothing to sum. Derived, never
    /// persisted.
    private func prospectiveFleetVerdict(addingModelPath: String?) -> FitVerdict? {
        var paths = endpoint.fleet.slots
            .filter { $0.enabled && !$0.modelPath.isEmpty }
            .map(\.modelPath)
        if let addingModelPath { paths.append(addingModelPath) }
        guard !paths.isEmpty else { return nil }
        guard let available = availableMemoryBytes else {
            return .unknown(reason: "memory probe unavailable")
        }
        return FleetFitAdvisor.verdict(
            estimates: paths.map { fleetEstimate(for: $0) },
            availableBytes: available,
            reserveBytes: Int64(appHost.config.fitReserveGB * 1_000_000_000)
        )
    }

    private func fleetEstimate(for modelPath: String) -> FleetFitAdvisor.Estimate {
        let model = appHost.librarySnapshot?.models.first(where: {
            $0.item.path == modelPath || $0.outputPaths.contains(modelPath)
        })
        guard let bytes = model?.item.bytes, bytes > 0 else { return .unknown }
        return .known(
            modelBytes: bytes,
            contextTokens: FitAdvisor.defaultContextTokens,
            parameters: model?.item.parameters
        )
    }

    /// Live available memory, with FitAdvisor's 60%-of-total fallback when
    /// the Mach probe fails.
    private var availableMemoryBytes: Int64? {
        if let probed = MemorySnapshot.probe() { return probed.availableBytes }
        guard let total = appHost.hardwareProfile.memoryBytes, total > 0 else { return nil }
        return Int64(Double(total) * 0.6)
    }

    private var loginItemSection: some View {
        HStack(spacing: 10) {
            if appHost.endpoint.fleet.installedAtLogin {
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
        .buttonStyle(.bordered)
        .sheet(isPresented: $showLoginItemPreview) {
            loginItemPreviewSheet
        }
    }

    private var loginItemControls: some View { loginItemSection }

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
                    Text(server.modelIdentity.isEmpty ? "Unknown model" : server.modelIdentity).font(.headline)
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
