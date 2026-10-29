import SwiftUI

enum RunPortInput: Equatable {
    case automatic
    case explicit(Int)
    case invalid

    init(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { self = .automatic }
        else if let port = Int(value), (1...65535).contains(port) { self = .explicit(port) }
        else { self = .invalid }
    }

    var port: Int? {
        if case .explicit(let port) = self { return port }
        return nil
    }

    var error: String? {
        self == .invalid ? "Enter a port between 1 and 65535, or leave it blank for automatic selection." : nil
    }
}

struct ServeView: View {
    let appHost: AppHost
    @ObservedObject private var modelWorkflow: ModelWorkflowCoordinator
    @ObservedObject private var endpoint: EndpointSupervisor
    @ObservedObject private var profiles: ServingProfileCoordinator
    @ObservedObject private var trainedAdapters: TrainedAdapterServingCoordinator
    @ObservedObject private var endpointTest: EndpointTestCoordinator
    @Environment(\.isRouteActive) private var isRouteActive
    private let onRouteSelection: (AppRoute) -> Void
    @State private var runtime = "auto"
    @State private var m5Prefill = false
    @State private var promptPresentation: EndpointTestPresentation?
    @State private var portText = ""
    @State private var endpointPortText = ""
    @State private var newSlotRole: UseCase?
    @State private var newSlotLoadOnRequest = true
    @State private var pendingFleetAction: PendingFleetAction?
    @State private var showFleetRouter = false
    @State private var showLoginItemPreview = false
    @State private var loginPlan: LoginItemPlan?
    @State private var loginPlist = ""
    @State private var loginBusy = false
    @State private var expandedMemorySlots: Set<UUID> = []
    @State private var viewportWidth = WorkbenchSize.assumedContentWidth + WorkbenchSpacing.pageInset * 2
    @State private var loginItemMessage: String?
    @State private var loginItemMessageIsError = false

    /// A wont-fit fleet action awaiting the user's explicit override.
    private struct PendingFleetAction: Identifiable {
        let id = UUID()
        let summary: String
        let confirm: () -> Void
    }

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        _modelWorkflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _profiles = ObservedObject(wrappedValue: appHost.servingProfiles)
        _trainedAdapters = ObservedObject(wrappedValue: appHost.trainedAdapters)
        _endpointTest = ObservedObject(wrappedValue: appHost.endpointTest)
        self.onRouteSelection = onRouteSelection
    }

    // MARK: - State

    private var models: [LibraryModel] { appHost.librarySnapshot?.models ?? [] }

    private var selectedModel: LibraryModel? {
        guard let path = RunPresentation.shownModelPath(workflow: modelWorkflow.workflow, selectedModelPath: appHost.selectedModelPath) else { return nil }
        return models.first(where: { $0.item.path == path || $0.outputPaths.contains(path) })
    }

    private var presentation: RunPresentation {
        RunPresentation(
            workflow: modelWorkflow.workflow,
            model: selectedModel,
            servers: modelWorkflow.servers,
            serveInFlight: modelWorkflow.isServeSubmissionInFlight
        )
    }

    private var layout: RunLayout { RunLayout(viewportWidth: viewportWidth) }
    private var portInput: RunPortInput { RunPortInput(portText) }
    private var innerWidth: CGFloat { layout.innerWidth }
    private var isCompact: Bool { layout.isCompact }
    private var isTwoLine: Bool { layout.isTwoLine }
    private var runningServers: [ServerInfo] { modelWorkflow.servers.filter { $0.state?.lowercased() == "running" } }

    var body: some View {
        let presentation = presentation
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                    if trainedAdapters.selectedJob != nil {
                        TrainedAdapterRunPanel(coordinator: trainedAdapters) { await modelWorkflow.refreshServers() }
                        nowServingSection(presentation)
                    } else {
                        heroRegion(presentation)
                        serveSection(presentation)
                    }
                    endpointSection(presentation, allowAdd: trainedAdapters.selectedJob == nil)
                }
                .frame(maxWidth: WorkbenchSize.Run.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(WorkbenchSpacing.pageInset)
            }
            .onChange(of: viewport.size.width, initial: true) { _, width in viewportWidth = width }
        }
        .sheet(item: $promptPresentation) { presentation in
            EndpointTestSheet(presentation: presentation, coordinator: endpointTest) {
                guard let request = ClientWiringRequest.forServer(presentation.server) else { return }
                appHost.handoffs.send(request, as: .wireClient)
                onRouteSelection(.clientSetup)
            }
        }
        .task { await modelWorkflow.refreshServers() }
        .onChange(of: modelWorkflow.servers) { _, servers in trainedAdapters.receiveServers(servers, error: modelWorkflow.serversError) }
        .onChange(of: modelWorkflow.serversError) { _, error in trainedAdapters.receiveServers(modelWorkflow.servers, error: error) }
        .onChange(of: isRouteActive) { _, active in
            if active { Task { await modelWorkflow.refreshServers() } }
            else { closePrompt() }
        }
        .onDisappear(perform: closePrompt)
        .onAppear {
            if endpointPortText.isEmpty {
                endpointPortText = String(suggestedPort)
            }
        }
    }

    private func closePrompt() {
        guard let presentation = promptPresentation else { return }
        endpointTest.close(presentationID: presentation.id)
        promptPresentation = nil
    }

    private func designedState(symbol: String, text: String) -> some View {
        Label {
            Text(text)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
        } icon: {
            Image(systemName: symbol).foregroundStyle(WorkbenchColor.muted)
        }
    }

    // MARK: - Now serving

    /// Now serving and the memory runway share one plain region on the canvas.
    private func heroRegion(_ presentation: RunPresentation) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
            nowServingSection(presentation)
            RunRunwayView(
                resources: appHost.resources,
                servers: modelWorkflow.servers,
                models: models,
                hardware: appHost.hardwareProfile,
                reserveGB: appHost.config.fitReserveGB,
                nextModel: presentation.runwayModel,
                isCompact: isCompact
            )
        }
    }

    private func nowServingSection(_ presentation: RunPresentation) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                SectionTitle(text: "Now serving")
                Spacer()
                Button {
                    Task { await modelWorkflow.refreshServers() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh serving status")
                .accessibilityLabel("Refresh serving status")
            }
            ErrorBanner(text: modelWorkflow.serversError)
            if runningServers.isEmpty {
                designedState(symbol: "moon.zzz", text: "Nothing is serving.")
            } else {
                ForEach(runningServers) { server in
                    servingRow(server, presentation: presentation)
                }
            }
        }
    }

    private func servingRow(_ server: ServerInfo, presentation: RunPresentation) -> some View {
        let model = RunModels.model(for: server.modelIdentity, in: models)
        let baseName = RunModels.name(for: server.modelIdentity, model: model)
        let name = server.adapterSummary.map { baseName + " · " + $0 } ?? baseName
        let isSelected = presentation.activeServer == server
        let protected = appHost.occupancy.blocksStop(server)
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if isTwoLine {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    HStack(spacing: WorkbenchSpacing.xs) {
                        servingChip(server)
                        servingName(name, identity: server.modelIdentity)
                        Spacer(minLength: WorkbenchSpacing.xs)
                        servingAction(server, name: name, isSelected: isSelected, protected: protected)
                    }
                    HStack(spacing: WorkbenchSpacing.sm) {
                        servingPort(server)
                        servingResidency(server)
                    }
                }
            } else {
                HStack(spacing: WorkbenchSpacing.sm) {
                    servingChip(server)
                    servingName(name, identity: server.modelIdentity)
                    servingPort(server)
                    servingResidency(server)
                    Spacer(minLength: WorkbenchSpacing.xs)
                    servingAction(server, name: name, isSelected: isSelected, protected: protected)
                }
            }
            if isSelected { selectedServerDetails(server) }
            Button("Try a prompt…") { promptPresentation = endpointTest.open(server) }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!EndpointTestCoordinator.supports(server) || modelWorkflow.serversError != nil || protected || endpointTest.isSending || endpointTest.presentationID != nil)
                .accessibilityIdentifier("run-try-prompt-\(server.port ?? 0)")
                .accessibilityLabel("Try a prompt with \(name) on port \(String(server.port ?? 0))")
                .help("Send one prompt to this endpoint. Load-on-request endpoints may load the model.")
            if let request = ClientWiringRequest.forServer(server) {
                Button("Configure clients…") {
                    guard modelWorkflow.serversError == nil else { return }
                    appHost.handoffs.send(request, as: .wireClient)
                    onRouteSelection(.clientSetup)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(modelWorkflow.serversError != nil)
                .accessibilityIdentifier("run-configure-clients-\(server.port ?? 0)")
                .accessibilityLabel("Configure clients for \(name) on port \(server.port ?? 0)")
                .help(modelWorkflow.serversError == nil
                      ? "Select this endpoint in Clients. Preview and confirm before changing client configuration."
                      : "Refresh serving status before configuring clients.")
            }
        }
        .padding(WorkbenchSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
    }

    private func servingChip(_ server: ServerInfo) -> some View {
        StatusPill(state: RunStateWord.word(for: server))
            .livePulse(RunStateWord.isLoading(server) && isRouteActive)
            .frame(minWidth: WorkbenchSize.Run.chip, alignment: .leading)
    }

    private func servingResidency(_ server: ServerInfo) -> some View {
        Text(server.residencySummary)
            .font(WorkbenchTypography.metadata)
            .foregroundStyle(WorkbenchColor.muted)
            .lineLimit(1)
            .livePulse(RunStateWord.isLoading(server) && isRouteActive)
    }

    private func servingName(_ name: String, identity: String) -> some View {
        Text(name)
            .font(WorkbenchTypography.emphasis)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(minWidth: WorkbenchSize.Run.nameMinimum, alignment: .leading)
            .help(identity)
    }

    private func servingPort(_ server: ServerInfo) -> some View {
        Text(verbatim: server.port.map { RunFormat.endpoint(port: $0) } ?? "No port")
            .font(WorkbenchTypography.compactValue)
            .textSelection(.enabled)
            .lineLimit(1)
            .frame(width: WorkbenchSize.Run.portColumn, alignment: .leading)
    }

    @ViewBuilder
    private func servingAction(_ server: ServerInfo, name: String, isSelected: Bool, protected: Bool) -> some View {
        if isSelected {
            Button("Stop server") {
                Task {
                    guard let modelPath = presentation.modelPath,
                          await appHost.stopSelectedServer(modelPath: modelPath) else { return }
                    if modelWorkflow.workflow.serveState == .stopped { onRouteSelection(.activity) }
                }
            }
            .disabled(modelWorkflow.isServeSubmissionInFlight || protected)
            .help(protected ? "This model is in use by an active operation." : "Stop this server.")
        } else {
            let unloads = server.jit == true
            Button(unloads ? "Unload" : "Stop") {
                Task {
                    _ = await appHost.unloadServing(server)
                    await modelWorkflow.refreshServers()
                }
            }
            .accessibilityLabel("\(unloads ? "Unload" : "Stop") \(name)")
            .disabled(endpoint.isUnloading || protected || server.port == nil ||
                      ["unloaded", "loading", "unloading"].contains(server.modelState ?? "") ||
                      (server.activeRequests ?? 0) > 0)
            .help(protected ? "This model is in use by an active operation."
                  : (unloads ? "Release model weights while keeping this endpoint reachable." : "Stop this server and disable automatic restart."))
        }
    }

    private func selectedServerDetails(_ server: ServerInfo) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: innerWidth < WorkbenchSize.Run.compactThreshold ? 1 : 2),
            alignment: .leading,
            spacing: WorkbenchSpacing.xxs
        ) {
            detailLine("PID", server.pid.map(String.init), identifier: true)
            detailLine("Started", server.startedAt)
            detailLine("Receipt", server.receipt, identifier: true, accessibilityID: "active-server-receipt")
            detailLine("Log path", server.logPath, identifier: true)
        }
    }

    /// Identifiers (PID, receipt, path) are monospaced; a missing value is plain text.
    private func detailLine(_ title: String, _ value: String?, identifier: Bool = false, accessibilityID: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
            Text(title)
                .font(WorkbenchTypography.metadata)
                .foregroundStyle(WorkbenchColor.muted)
                .frame(width: WorkbenchSize.Run.detailLabel, alignment: .leading)
            Group {
                if let accessibilityID {
                    Text(verbatim: value ?? "Not reported").accessibilityIdentifier(accessibilityID)
                } else {
                    Text(verbatim: value ?? "Not reported")
                }
            }
            .font(identifier && value != nil ? WorkbenchTypography.compactValue : WorkbenchTypography.secondaryTabular)
            .foregroundStyle(value == nil ? WorkbenchColor.muted : WorkbenchColor.ink)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }

    // MARK: - Serve a model

    private func serveSection(_ presentation: RunPresentation) -> some View {
        WorkbenchSurface(.tinted) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                SectionTitle(text: "Serve a model")
                if let model = selectedModel { modelHeader(model) }
                switch presentation.stage {
                case .noModel:
                    designedState(symbol: "tray", text: "Select a completed, ready MLX model from Library or Activity before running it.")
                    Button("Open Library") { onRouteSelection(.library) }
                        .buttonStyle(.bordered)
                case .nonServable:
                    designedState(
                        symbol: "nosign",
                        text: "\(selectedModel?.item.task?.type.title ?? "This kind of") models are not served. Use them from the Library inspector."
                    )
                    Button("Open Library") {
                        if let selectedModel { appHost.handoffs.send(LibraryRevealRequest(modelPath: selectedModel.item.path), as: .revealModel) }
                        onRouteSelection(.library)
                    }
                        .buttonStyle(.bordered)
                case .notEligible:
                    if presentation.canPrepareSelection {
                        serveControls(presentation)
                    } else {
                        if let error = presentation.selectionError { InlineMessage(kind: .info, text: error) }
                        if presentation.needsWorkflowReview {
                            Button("Review Prepare") { onRouteSelection(.prepare) }.buttonStyle(.bordered)
                        } else {
                            Button("Open Library") { onRouteSelection(.library) }.buttonStyle(.bordered)
                        }
                    }
                default:
                    serveControls(presentation)
                }
                if let message = presentation.visibleMessage {
                    Text(message)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                }
                ErrorBanner(text: presentation.visibleError)
            }
        }
    }

    private func modelHeader(_ model: LibraryModel) -> some View {
        let item = model.item
        let facts = [
            item.architecture, item.parameters, item.quantization,
            ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file), item.status,
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
            Image(systemName: item.task?.type.symbolName ?? "cube")
                .font(WorkbenchTypography.section)
                .foregroundStyle(WorkbenchColor.accent)
                .frame(width: WorkbenchSize.symbolTile, height: WorkbenchSize.symbolTile)
                .background(WorkbenchColor.accent.opacity(.fill), in: RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                Text(model.displayName)
                    .font(WorkbenchTypography.emphasis)
                    .lineLimit(1)
                Text(facts.joined(separator: " · "))
                    .font(WorkbenchTypography.metadata)
                    .foregroundStyle(WorkbenchColor.muted)
                    .lineLimit(1)
                Text(item.path)
                    .font(WorkbenchTypography.compactValue)
                    .foregroundStyle(WorkbenchColor.muted)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func serveControls(_ presentation: RunPresentation) -> some View {
        HStack {
            Text("Preview checks this model's serving runtime before confirmation.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            Spacer()
            Button("Open Health") { onRouteSelection(.health) }.buttonStyle(.bordered)
        }
        if isCompact {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                HStack(spacing: WorkbenchSpacing.sm) {
                    serveActions(presentation)
                    stateWords(presentation)
                }
                launchFields
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                launchFields
                Spacer(minLength: WorkbenchSpacing.xs)
                stateWords(presentation)
                serveActions(presentation)
            }
        }
        ServingProfileControls(profiles: appHost.servingProfiles, workflow: modelWorkflow, endpoint: endpoint,
            modelPath: modelWorkflow.workflow.completedModelPath, onCompare: { setup in
                guard appHost.comparison.activeRunID == nil, !appHost.comparison.savingPromptSet else {
                    return "Wait for the current comparison or prompt-set save to finish."
                }
                appHost.handoffs.send(setup, as: .compareServingProfiles)
                onRouteSelection(.compare)
                return nil
            })
        Toggle("Experimental M5 prompt acceleration", isOn: $m5Prefill)
            .toggleStyle(.checkbox)
            .disabled(modelWorkflow.servingProfile != nil || runtime == "mlx-vlm" || modelWorkflow.isServeSubmissionInFlight)
            .help("MLX-LM only. Unsupported hardware and models use native MLX. First load compiles the M5 Q4 prompt kernel.")
            .onChange(of: runtime) { _, value in if value == "mlx-vlm" { m5Prefill = false } }
            .onChange(of: modelWorkflow.servingProfile) { _, value in if value != nil { m5Prefill = false } }
        if let error = portInput.error {
            Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
        }
    }

    @ViewBuilder
    private func stateWords(_ presentation: RunPresentation) -> some View {
        if let words = presentation.stateWords {
            Text(words)
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.muted)
                .livePulse(presentation.stage == .starting && isRouteActive)
        }
    }

    @ViewBuilder
    private var launchFields: some View {
        let fields = Group {
            Picker("Runtime", selection: $runtime) {
                Text("Automatic").tag("auto")
                Text("mlx_lm").tag("mlx_lm")
                Text("mlx-vlm").tag("mlx-vlm")
            }
            .frame(width: WorkbenchSize.Run.runtimeWidth)
            .disabled(modelWorkflow.servingProfile != nil)
            TextField("Port", text: $portText, prompt: Text("Optional"))
                .textFieldStyle(.roundedBorder)
                .frame(width: WorkbenchSize.Run.portField)
                .accessibilityLabel("Serving port")
            RunContextControl(
                resources: appHost.resources,
                model: selectedModel,
                hardware: appHost.hardwareProfile,
                reserveGB: appHost.config.fitReserveGB
            )
        }
        if isCompact {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { fields }
        } else {
            HStack(spacing: WorkbenchSpacing.sm) { fields }
        }
    }

    private func previewServeAction() {
        guard portInput.error == nil, presentation.canPreview else { return }
        if presentation.canPrepareSelection {
            guard let model = selectedModel else { return }
            modelWorkflow.prepareServe(model: model)
        }
        guard presentation.selectedCompletedModel != nil else { return }
        let port = portInput.port
        let runtime = runtime
        let m5Prefill = m5Prefill
        Task { await modelWorkflow.previewServe(runtime: runtime, port: port, m5Prefill: m5Prefill) }
    }

    private func confirmServeAction() {
        guard portInput.error == nil else { return }
        let port = portInput.port
        let runtime = runtime
        let m5Prefill = m5Prefill
        Task {
            await modelWorkflow.confirmServe(runtime: runtime, port: port, m5Prefill: m5Prefill)
            if modelWorkflow.workflow.serveState == .running { onRouteSelection(.activity) }
        }
    }

    @ViewBuilder
    private func serveActions(_ presentation: RunPresentation) -> some View {
        let busy = modelWorkflow.isServeSubmissionInFlight || portInput.error != nil
            || (modelWorkflow.servingProfile.map { !$0.hasPassedVerification } ?? false) || appHost.servingProfiles.activeID != nil
        // Exactly one action is armed at a time: preview until the intent is
        // ready to confirm, then confirm.
        if presentation.canConfirm {
            Button("Preview serve", action: previewServeAction)
                .buttonStyle(.bordered)
                .disabled(!presentation.canPreview || busy)
            Button("Confirm and run", action: confirmServeAction)
                .buttonStyle(.workbenchPrimary)
                .disabled(busy)
        } else if presentation.canPreview {
            Button("Preview serve", action: previewServeAction)
                .buttonStyle(.workbenchPrimary)
                .disabled(busy)
            Button("Confirm and run", action: confirmServeAction)
                .buttonStyle(.bordered)
                .disabled(true)
        } else {
            Button("Preview serve", action: previewServeAction)
                .buttonStyle(.bordered)
                .disabled(true)
            Button("Confirm and run", action: confirmServeAction)
                .buttonStyle(.bordered)
                .disabled(true)
        }
    }

    // MARK: - Endpoints

    /// Smallest port from the default that no slot claims yet.
    private var suggestedPort: Int {
        var candidate = EndpointConfig.defaultPort
        let used = Set(endpoint.fleet.slots.map(\.port))
        while used.contains(candidate) { candidate += 1 }
        return candidate
    }

    private func endpointSection(_ presentation: RunPresentation, allowAdd: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(text: "Endpoints")
                Spacer()
                Text(verbatim: "\(endpoint.fleet.slots.count) of \(EndpointFleetConfig.maxSlots)")
                    .font(WorkbenchTypography.secondaryTabular)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            Text("Keep models serving on stable loopback ports, across restarts and swaps. Clients wired in Wire keep working.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            RunFleetVerdictLine(
                resources: appHost.resources,
                slots: endpoint.fleet.slots,
                servers: modelWorkflow.servers,
                models: models,
                reserveGB: appHost.config.fitReserveGB
            )
            if let pending = pendingFleetAction {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    InlineMessage(kind: .warning, text: "Fleet memory: \(pending.summary). Enable anyway?")
                    HStack(spacing: WorkbenchSpacing.xs) {
                        Button("Enable anyway") {
                            pending.confirm()
                            pendingFleetAction = nil
                        }
                        Button("Cancel") { pendingFleetAction = nil }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if endpoint.fleet.slots.isEmpty {
                if !allowAdd {
                    designedState(symbol: "point.3.connected.trianglepath.dotted", text: "No saved endpoints.")
                } else if let reason = presentation.addEndpointBlockedReason {
                    designedState(symbol: "point.3.connected.trianglepath.dotted", text: reason)
                } else {
                    designedState(symbol: "point.3.connected.trianglepath.dotted", text: "No endpoints yet. Add one for the model above.")
                }
            } else {
                ForEach(endpoint.fleet.slots) { slot in
                    slotRow(slot)
                }
            }
            if allowAdd { addEndpointControls(presentation) }
            else { Text("Always-on endpoints use Library models. This trained adapter uses explicit serving above.").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted) }
            if endpoint.fleet.slots.contains(where: { $0.role != nil }) {
                HStack(spacing: WorkbenchSpacing.xs) {
                    Button("Wire roles…") { showFleetRouter = true }
                        .buttonStyle(.bordered)
                    Text("Map roles onto running endpoints via mlx-agent fleet.")
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                }
            }
            loginItemSection
            if endpoint.isChanging {
                HStack { ProgressView().controlSize(.small); Text("Updating endpoints…") }
                    .font(WorkbenchTypography.secondary)
            }
            ErrorBanner(text: endpoint.lastError)
            ErrorBanner(text: endpoint.persistenceError)
            if !endpoint.pendingStops.isEmpty {
                Button("Retry stopping servers") { Task { await endpoint.retryPendingStops() } }
                    .disabled(endpoint.isChanging)
            }
            if let loginItemMessage {
                InlineMessage(kind: loginItemMessageIsError ? .error : .success, text: loginItemMessage)
            }
        }
        .sheet(isPresented: $showFleetRouter) {
            FleetRouterSheet(appHost: appHost)
        }
    }

    private func slotRow(_ slot: EndpointSlot) -> some View {
        let slotState = endpoint.slotStates[slot.id] ?? .disabled
        let model = RunModels.model(for: slot.modelPath, in: models)
        let name = RunModels.name(for: slot.modelPath, model: model)
        let attempts = endpoint.slotRestartAttempts[slot.id] ?? 0
        let isLoading = modelWorkflow.servers.contains { $0.port == slot.port && RunStateWord.isLoading($0) }
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            HStack(spacing: WorkbenchSpacing.sm) {
                StatusPill(state: slotStateLabel(slotState, enabled: slot.enabled))
                    .frame(minWidth: WorkbenchSize.Run.chip, alignment: .leading)
                Text(name)
                    .font(WorkbenchTypography.emphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: WorkbenchSize.Run.slotModelMinimum, alignment: .leading)
                    .help(slot.modelPath)
                if let profile = slot.servingProfile {
                    Text(profiles.profiles.first(where: { $0.id == profile.id })?.name ?? profile.name)
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
                if !isTwoLine { slotFacts(slot, attempts: attempts) }
                Spacer(minLength: WorkbenchSpacing.xs)
                slotMenu(slot, slotState: slotState)
            }
            if isTwoLine {
                HStack(spacing: WorkbenchSpacing.sm) { slotFacts(slot, attempts: attempts) }
            }
            HStack(spacing: WorkbenchSpacing.xs) {
                Text(slotState.summary)
                    .font(WorkbenchTypography.metadata)
                    .foregroundStyle(WorkbenchColor.muted)
                if let residency = endpoint.slotResidencies[slot.id] {
                    Text(residency)
                        .font(WorkbenchTypography.metadata)
                        .foregroundStyle(WorkbenchColor.muted)
                        .livePulse(isLoading && isRouteActive)
                }
                if case .modelMismatch = slotState {
                    Button("Swap to configured model") {
                        Task { await endpoint.swapSlot(id: slot.id, to: slot.modelPath, allowUnverified: true) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if slot.usesJIT, let reason = endpoint.slotLoadBlockedReasons[slot.id] {
                Label(reason, systemImage: "memorychip")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.warning)
            }
        }
        .padding(WorkbenchSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
        .popover(isPresented: memoryPopoverBinding(slot), arrowEdge: .bottom) {
            memoryManagement(endpoint.fleet.slots.first(where: { $0.id == slot.id }) ?? slot, expanded: .constant(true))
                .padding(WorkbenchSpacing.md)
                .frame(width: WorkbenchSize.Run.memoryPopoverWidth)
        }
    }

    @ViewBuilder
    private func slotFacts(_ slot: EndpointSlot, attempts: Int) -> some View {
        if let role = slot.role {
            Text(role.title)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
        }
        Text(verbatim: RunFormat.port(slot.port))
            .font(WorkbenchTypography.compactValue)
            .foregroundStyle(WorkbenchColor.muted)
        Text(slot.usesJIT ? "Load on request" : "Always loaded")
            .font(WorkbenchTypography.metadata)
            .foregroundStyle(WorkbenchColor.muted)
        if attempts > 0 {
            Text(verbatim: "\(attempts) restart(s)")
                .font(WorkbenchTypography.metadata)
                .foregroundStyle(WorkbenchColor.muted)
        }
        RunSlotFitChip(
            resources: appHost.resources,
            slot: slot,
            servers: modelWorkflow.servers,
            models: models,
            hardware: appHost.hardwareProfile,
            reserveGB: appHost.config.fitReserveGB
        )
    }

    private func slotMenu(_ slot: EndpointSlot, slotState: EndpointState) -> some View {
        Menu {
            Button(slot.enabled ? "Disable" : "Enable") {
                if slot.enabled {
                    Task { await endpoint.setSlotEnabled(id: slot.id, false) }
                } else {
                    enableSlotWithFitCheck(slot)
                }
            }
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
            Toggle("Load on request", isOn: Binding(
                get: { slot.usesJIT },
                set: { value in Task { await endpoint.setSlotLoadOnRequest(id: slot.id, value) } }))
                .help("Keep the endpoint reachable without resident weights. Changing load mode restarts this endpoint.")
                .disabled(endpoint.isUnloading)
            if slot.usesJIT {
                Button("Memory management…") { expandedMemorySlots.insert(slot.id) }
            }
            Divider()
            Button("Remove", role: .destructive) { Task { await endpoint.removeSlot(id: slot.id) } }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: WorkbenchSize.Run.overflow)
        .help("Endpoint actions")
        .disabled(endpoint.isChanging)
        .accessibilityLabel("Actions for \(RunModels.name(for: slot.modelPath, model: RunModels.model(for: slot.modelPath, in: models)))")
    }

    private func memoryPopoverBinding(_ slot: EndpointSlot) -> Binding<Bool> {
        Binding(
            get: { expandedMemorySlots.contains(slot.id) },
            set: { value in
                if value { expandedMemorySlots.insert(slot.id) } else { expandedMemorySlots.remove(slot.id) }
            }
        )
    }

    /// The slot's idle, keep-loaded and headroom controls; `expanded` defaults to the page's per-slot state.
    func memoryManagement(_ slot: EndpointSlot, expanded: Binding<Bool>? = nil) -> some View {
        let policy = slot.memoryPolicy ?? endpoint.slotMemoryPolicies[slot.id] ?? .legacy
        return DisclosureGroup(isExpanded: expanded ?? memoryPopoverBinding(slot)) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                HStack {
                    Picker("Unload when idle", selection: memoryBinding(slot, \.idleTimeoutSeconds)) {
                        Text("Never").tag(0)
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("10 minutes").tag(600)
                        Text("30 minutes").tag(1800)
                        Text("1 hour").tag(3600)
                        if ![0, 60, 300, 600, 1800, 3600].contains(policy.idleTimeoutSeconds) {
                            Text(verbatim: "\(policy.idleTimeoutSeconds) seconds").tag(policy.idleTimeoutSeconds)
                        }
                    }
                    .frame(maxWidth: WorkbenchSize.Run.idlePickerMaximum)
                    .disabled(policy.keepLoaded)
                    Toggle("Keep loaded after use", isOn: memoryBinding(slot, \.keepLoaded))
                        .toggleStyle(.checkbox)
                        .help("Prevent automatic unload after the first request. Manual unload remains available.")
                }
                HStack {
                    Toggle("Check memory before loading", isOn: Binding(
                        get: { policy.minimumHeadroomGB != nil },
                        set: { enabled in
                            var updated = policy
                            updated.minimumHeadroomGB = enabled ? 2 : nil
                            Task { await endpoint.setSlotMemoryPolicy(id: slot.id, updated) }
                        }))
                        .toggleStyle(.checkbox)
                    if let reserve = policy.minimumHeadroomGB {
                        Picker("Reserve after loading", selection: Binding(
                            get: { reserve },
                            set: { value in
                                var updated = policy
                                updated.minimumHeadroomGB = value
                                Task { await endpoint.setSlotMemoryPolicy(id: slot.id, updated) }
                            })) {
                            ForEach([1.0, 2, 4, 8], id: \.self) { value in Text("\(Int(value)) GB").tag(value) }
                            if ![1.0, 2, 4, 8].contains(reserve) { Text("\(reserve, specifier: "%.1f") GB").tag(reserve) }
                        }
                        .frame(maxWidth: WorkbenchSize.Run.reservePickerMaximum)
                    }
                }
                Text("Uses estimated weights + runtime allowance + reserve. Other processes and larger contexts can change actual memory use. Unknown headroom blocks loading.")
                    .font(WorkbenchTypography.metadata)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            .padding(.top, WorkbenchSpacing.sm)
            .controlSize(.small)
            .disabled(endpoint.isUnloading)
        } label: {
            HStack {
                Text("Memory management")
                Text(policy.keepLoaded ? "Keeps loaded" : (policy.idleTimeoutSeconds == 0 ? "Manual unload" : "Idle unload · \(policy.idleTimeoutSeconds / 60) min"))
                    .foregroundStyle(WorkbenchColor.muted)
                if let reserve = policy.minimumHeadroomGB {
                    Text("\(reserve, specifier: "%.1f") GB reserve").foregroundStyle(WorkbenchColor.muted)
                }
            }
        }
        .font(WorkbenchTypography.secondary)
    }

    private func memoryBinding<Value>(_ slot: EndpointSlot, _ keyPath: WritableKeyPath<EndpointMemoryPolicy, Value>) -> Binding<Value> {
        Binding(get: { (slot.memoryPolicy ?? endpoint.slotMemoryPolicies[slot.id] ?? .legacy)[keyPath: keyPath] },
                set: { value in
                    var policy = slot.memoryPolicy ?? endpoint.slotMemoryPolicies[slot.id] ?? .legacy
                    policy[keyPath: keyPath] = value
                    Task { await endpoint.setSlotMemoryPolicy(id: slot.id, policy) }
                })
    }

    private func slotStateLabel(_ state: EndpointState, enabled: Bool) -> String {
        if case .degraded = state { return "degraded" }
        guard enabled else { return "disabled" }
        switch state {
        case .running: return "running"
        case .starting, .waitingForServer: return "starting"
        case .degraded: return "degraded"
        case .modelMismatch: return "mismatch"
        case .disabled: return "disabled"
        }
    }

    // MARK: - Add endpoint

    @ViewBuilder
    private func addEndpointControls(_ presentation: RunPresentation) -> some View {
        if endpoint.fleet.slots.count >= EndpointFleetConfig.maxSlots {
            designedState(symbol: "square.stack.3d.up.slash", text: "Endpoint cap reached (\(EndpointFleetConfig.maxSlots)). Remove one to add another.")
        } else {
            let canAdd = presentation.canAddEndpoint
            if isCompact {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    HStack(spacing: WorkbenchSpacing.sm) {
                        addEndpointPortAndRole
                    }
                    HStack(spacing: WorkbenchSpacing.sm) {
                        addEndpointLoadToggle
                        Spacer(minLength: WorkbenchSpacing.xs)
                        addEndpointButtons(presentation, canAdd: canAdd)
                    }
                }
            } else {
                HStack(spacing: WorkbenchSpacing.sm) {
                    addEndpointPortAndRole
                    addEndpointLoadToggle
                    Spacer(minLength: WorkbenchSpacing.xs)
                    addEndpointButtons(presentation, canAdd: canAdd)
                }
            }
        }
    }

    @ViewBuilder
    private var addEndpointPortAndRole: some View {
        LabeledContent("Port") {
            TextField("Port", text: $endpointPortText)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: WorkbenchSize.Run.portField)
        }
        Picker("Role", selection: $newSlotRole) {
            Text("Unassigned").tag(UseCase?.none)
            ForEach(UseCase.allCases) { role in
                Text(role.title).tag(UseCase?.some(role))
            }
        }
        .frame(width: WorkbenchSize.Run.roleWidth)
    }

    private var addEndpointLoadToggle: some View {
        Toggle("Load on request", isOn: $newSlotLoadOnRequest)
            .toggleStyle(.checkbox)
            .frame(minWidth: WorkbenchSize.Run.loadToggle, alignment: .leading)
            .help("Start a reachable endpoint now; load the selected local model on the first inference request.")
    }

    private func addEndpointButtons(_ presentation: RunPresentation, canAdd: Bool) -> some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            Button("Add endpoint") { addEndpoint(allowUnverified: false) }
                .buttonStyle(.workbenchPrimary)
                .disabled(!canAdd || endpoint.isChanging)
                .help(presentation.addEndpointBlockedReason ?? "Adds the model shown above as a new endpoint.")
            Menu {
                Button("Add anyway (unverified)") { addEndpoint(allowUnverified: true) }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!canAdd || endpoint.isChanging)
            .help("More ways to add")
            .accessibilityLabel("More ways to add an endpoint")
        }
    }

    private func addEndpoint(allowUnverified: Bool) {
        guard let model = selectedModel else { return }
        let port = Int(endpointPortText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? suggestedPort
        let role = newSlotRole
        let loadOnRequest = newSlotLoadOnRequest
        let action = {
            _ = Task {
                await endpoint.addSlot(
                    modelPath: model.item.path,
                    port: port,
                    role: role,
                    allowUnverified: allowUnverified,
                    loadOnRequest: loadOnRequest
                )
            }
        }
        if let verdict = appHost.runFleetVerdict(adding: model.item.path),
           case .wontFit = verdict {
            pendingFleetAction = PendingFleetAction(summary: verdict.summary, confirm: action)
            return
        }
        action()
    }

    /// Enabling a slot that tips the fleet past wont-fit needs the explicit
    /// override; tight is warned in place by the fleet verdict line.
    private func enableSlotWithFitCheck(_ slot: EndpointSlot) {
        let action = { _ = Task { await endpoint.setSlotEnabled(id: slot.id, true) } }
        if let verdict = appHost.runFleetVerdict(adding: slot.modelPath),
           case .wontFit = verdict {
            pendingFleetAction = PendingFleetAction(summary: verdict.summary, confirm: action)
            return
        }
        action()
    }

    // MARK: - Login item

    private var loginItemSection: some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            if appHost.endpoint.fleet.installedAtLogin {
                Button("Remove login item") {
                    loginBusy = true
                    Task {
                        let result = await WorkbenchIO.perform { Result { try LaunchAgentManager().uninstall() } }
                        do {
                            try result.get()
                            appHost.endpoint.markLoginItemInstalled(false)
                            loginItemMessageIsError = false; loginItemMessage = "Login item removed."
                        } catch { loginItemMessageIsError = true; loginItemMessage = AppHost.render(error) }
                        loginBusy = false
                    }
                }
            } else {
                Button("Install login item…") { loginPlan = nil; loginPlist = ""; showLoginItemPreview = true }
            }
        }
        .buttonStyle(.bordered)
        .disabled(loginBusy)
        .sheet(isPresented: $showLoginItemPreview) {
            loginItemPreviewSheet
        }
    }

    private var loginItemPreviewSheet: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text("Login item preview").font(WorkbenchTypography.emphasis)
            Text("This LaunchAgent starts the endpoint once at login (RunAtLoad). The app keeps reconciling while it runs; mlx-agent receipts remain the process authority.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            if loginBusy { ProgressView("Reviewing endpoint startup…") }
            if let loginItemMessage, loginItemMessageIsError { InlineMessage(kind: .error, text: loginItemMessage) }
            ScrollView {
                Text(loginPlist)
                    .font(WorkbenchTypography.value)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { showLoginItemPreview = false }.disabled(loginBusy)
                Spacer()
                Button("Confirm install") { installLoginItem() }
                    .buttonStyle(.workbenchPrimary)
                    .disabled(loginBusy || loginPlan == nil)
            }
        }
        .padding(WorkbenchSpacing.md)
        .frame(width: WorkbenchSize.Run.loginSheetWidth, height: WorkbenchSize.Run.loginSheetHeight)
        .interactiveDismissDisabled(loginBusy)
        .task { await prepareLoginItem() }
    }

    private var agentRootPath: String {
        appHost.config.mlxAgentPath.isEmpty ? appHost.vendorAgentPath : appHost.config.mlxAgentPath
    }

    private func prepareLoginItem() async {
        loginBusy = true; loginItemMessage = nil
        defer { loginBusy = false }
        do {
            guard let slot = endpoint.fleet.slots.first else { throw WorkflowEvidenceError.invalid("Choose an endpoint first.") }
            let plan = try await appHost.api.loginItemPlan(slot: slot, fleetURL: endpoint.fleetFileURL)
            let plist = try await WorkbenchIO.perform { Result { try LaunchAgentManager().plistPreview(plan: plan) } }.get()
            try Task.checkCancellation()
            guard endpoint.fleet.slots.first == slot, agentRootPath == plan.agentPath else {
                throw WorkflowEvidenceError.invalid("Endpoint settings changed. Open the login preview again.")
            }
            loginPlan = plan; loginPlist = plist
        } catch { loginItemMessageIsError = true; loginItemMessage = AppHost.render(error) }
    }

    private func installLoginItem() {
        guard let plan = loginPlan, endpoint.fleet.slots.first == plan.slot, agentRootPath == plan.agentPath else {
            loginPlan = nil; loginItemMessageIsError = true
            loginItemMessage = "Endpoint settings changed. Open the login preview again."; return
        }
        loginBusy = true
        Task {
            let result = await WorkbenchIO.perform { Result { try LaunchAgentManager().install(plan: plan) } }
            do {
                try result.get()
                endpoint.markLoginItemInstalled(true)
                loginItemMessageIsError = false; loginItemMessage = "Login item installed."
                showLoginItemPreview = false
            } catch { loginItemMessageIsError = true; loginItemMessage = AppHost.render(error) }
            loginBusy = false
        }
    }
}
