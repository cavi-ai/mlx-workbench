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
    @ObservedObject private var servedTasks: ServedTaskSessions
    @ObservedObject private var inventory: ServingInventoryCoordinator
    @ObservedObject private var comparison: ComparisonCoordinator
    @Environment(\.isRouteActive) private var isRouteActive
    @State private var mode = ServeMode.startNow
    @State private var action: EndpointChangeReview?
    @State private var authenticationReview: EndpointAuthenticationReview?
    @State private var actionError: String?
    @State private var keepModelLoaded = false
    @State private var requireAPIKey = false
    @State private var endpointPortError: String?
    @State private var expandedDetails: Set<String> = []
    @State private var revealedModelPath: String?
    @State private var reportedActionError: String?
    private let onRouteSelection: (AppRoute) -> Void
    @State private var runtime = "auto"
    @State private var inferenceOptions = LocalInferenceOptions()
    @State private var revealInferenceRevision = UUID()
    @State private var taskPresentation: ServedTaskPresentation?
    @State private var promptPresentation: EndpointTestPresentation?
    @State private var portText = ""
    @State private var endpointPortText = ""
    @State private var newSlotRole: UseCase?
    @State private var newSlotLoadOnRequest = true
    @StateObject private var fleetHold: FleetOverrideHold
    private var pendingFleetAction: PendingFleetAction? {
        get { fleetHold.pending }
        nonmutating set { fleetHold.pending = newValue }
    }
    @State private var showFleetRouter = false
    @State private var showLoginItemPreview = false
    @State private var loginPlan: LoginItemPlan?
    @State private var inferenceSlot: EndpointSlot?
    @State private var memoryReviewSlot: EndpointSlot?
    @State private var loginPlist = ""
    @State private var loginBusy = false
    @State private var expandedMemorySlots: Set<UUID> = []
    @State private var viewportWidth = WorkbenchSize.assumedContentWidth + WorkbenchSpacing.pageInset * 2
    @State private var loginItemMessage: String?
    @State private var loginItemMessageIsError = false

    enum ServeMode: String, CaseIterable, Identifiable {
        case startNow = "Start now"
        case saveEndpoint = "Save as endpoint"
        var id: String { rawValue }
    }

    init(appHost: AppHost, initialReview: EndpointChangeReview? = nil, fleetHold: FleetOverrideHold? = nil,
         onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        _servedTasks = ObservedObject(wrappedValue: appHost.servedTasks)
        _action = State(initialValue: initialReview)
        _fleetHold = StateObject(wrappedValue: fleetHold ?? FleetOverrideHold())
        _modelWorkflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _profiles = ObservedObject(wrappedValue: appHost.servingProfiles)
        _trainedAdapters = ObservedObject(wrappedValue: appHost.trainedAdapters)
        _endpointTest = ObservedObject(wrappedValue: appHost.endpointTest)
        _inventory = ObservedObject(wrappedValue: appHost.servingInventory)
        _comparison = ObservedObject(wrappedValue: appHost.comparison)
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
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                        if trainedAdapters.selectedJob != nil {
                            TrainedAdapterRunPanel(coordinator: trainedAdapters) { await modelWorkflow.refreshServers() }
                        } else if isCompact {
                            serveSection(presentation)
                            heroRegion(presentation)
                        } else {
                            heroRegion(presentation)
                            serveSection(presentation)
                        }
                        servedModelsSection(presentation, allowAdd: trainedAdapters.selectedJob == nil)
                    }
                    .frame(maxWidth: WorkbenchSize.Run.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(WorkbenchSpacing.pageInset)
                }
                .accessibilityIdentifier("run-content-scroll")
                .onChange(of: viewport.size.width, initial: true) { _, width in viewportWidth = width }
                .onChange(of: shownPath, initial: true) { old, new in
                    if old != new { inferenceOptions = .init() }
                    revealServeBlock(proxy)
                }
                .onChange(of: revealInferenceRevision) { _, _ in proxy.scrollTo("run-serve-primary", anchor: .top) }
                .onChange(of: isRouteActive) { _, _ in revealServeBlock(proxy); revealServing(proxy) }
                .onChange(of: appHost.handoffs[.openServing], initial: true) { _, _ in revealServing(proxy) }
                .onChange(of: pendingFleetAction?.id) { _, id in if id != nil { proxy.scrollTo("run-fleet-pending") } }
                .onChange(of: visibleActionError) { old, new in
                    if old == nil, new != nil, isRouteActive { proxy.scrollTo("run-served-errors") }
                }
            }
        }
        .sheet(item: gated($action)) { pending in confirmation(pending) }
        .sheet(item: gated($authenticationReview)) { review in authenticationConfirmation(review) }
        .sheet(item: $taskPresentation) { presentation in
            ServedTaskSheet(appHost: appHost, presentation: presentation)
        }
        .sheet(item: $promptPresentation) { presentation in
            EndpointTestSheet(presentation: presentation, coordinator: endpointTest) {
                guard let request = ClientWiringRequest.forServer(presentation.server) else { return }
                appHost.handoffs.send(request, as: .wireClient)
                onRouteSelection(.clientSetup)
            }
        }
        .sheet(item: $inferenceSlot) { slot in
            EndpointInferenceEditor(endpoint: endpoint, slot: slot,
                context: ServingInferenceContext.resolve(model: models.first { $0.item.path == slot.modelPath || $0.outputPaths.contains(slot.modelPath) }, profile: slot.servingProfile, chip: appHost.hardwareProfile.chip),
                onManageProfile: { profile in
                    guard let model = models.first(where: { $0.item.path == slot.modelPath || $0.outputPaths.contains(slot.modelPath) }), model.readiness == .ready else { return }
                    appHost.selectedModelPath = model.item.path
                    modelWorkflow.prepareServe(model: model)
                    modelWorkflow.selectServingProfile(profile)
                    inferenceOptions = slot.inferenceOptions
                    inferenceSlot = nil
                    revealInferenceRevision = UUID()
                })
        }
        .sheet(item: $memoryReviewSlot) { slot in
            EndpointMemoryReviewSheet(slot: slot, endpoint: endpoint, api: appHost.api)
        }
        .task { await modelWorkflow.refreshServers() }
        .onChange(of: modelWorkflow.servers) { _, servers in trainedAdapters.receiveServers(servers, error: modelWorkflow.serversError) }
        .onChange(of: modelWorkflow.serversError) { _, error in trainedAdapters.receiveServers(modelWorkflow.servers, error: error) }
        .onChange(of: isRouteActive) { _, active in
            if active { Task { await modelWorkflow.refreshServers() } }
            else { closePrompt() }
        }
        .onDisappear(perform: closePrompt)
        .onChange(of: inferenceOptions) { _, _ in modelWorkflow.invalidateServePreview() }
        .onChange(of: runtime) { _, _ in
            inferenceOptions = inferenceContext.normalized(inferenceOptions)
            modelWorkflow.invalidateServePreview()
        }
        .onChange(of: mode) { _, _ in
            inferenceOptions = inferenceContext.normalized(inferenceOptions)
            modelWorkflow.invalidateServePreview()
        }
        .onChange(of: modelWorkflow.servingProfile) { _, _ in
            inferenceOptions = inferenceContext.normalized(inferenceOptions)
        }
        .onChange(of: portText) { _, _ in modelWorkflow.invalidateServePreview() }
        .onAppear {
            if endpointPortText.isEmpty {
                endpointPortText = String(suggestedPort)
            }
        }
    }

    private var shownPath: String? {
        RunPresentation.shownModelPath(workflow: modelWorkflow.workflow, selectedModelPath: appHost.selectedModelPath)
    }

    private var visibleActionError: String? { actionError ?? inventory.actionError ?? endpoint.lastError }

    /// A sheet binding that stays empty while this route is hidden, so a retained page never presents.
    private func gated<Value>(_ binding: Binding<Value?>) -> Binding<Value?> {
        Binding(get: { isRouteActive ? binding.wrappedValue : nil }, set: { binding.wrappedValue = $0 })
    }

    /// Brings the serve block into view when the shown model changes; no animation.
    private func revealServeBlock(_ proxy: ScrollViewProxy) {
        guard isRouteActive, let path = shownPath, path != revealedModelPath else { return }
        let first = revealedModelPath == nil
        revealedModelPath = path
        if !first { proxy.scrollTo("run-serve-primary") }
    }

    private func revealServing(_ proxy: ScrollViewProxy) {
        guard isRouteActive, let request = appHost.handoffs[.openServing] else { return }
        proxy.scrollTo(request.rowID ?? "run-served-models", anchor: .top)
        appHost.handoffs.finish(request, as: .openServing)
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

    // MARK: - Served models

    /// The memory runway is the page's hero region.
    private func heroRegion(_ presentation: RunPresentation) -> some View {
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
            taskButton(server)
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
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
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
            ServingInferenceEvidenceView(rows: InferenceOptionEvidence.rows(prefill: server.prefillKernel, lookup: server.decodeProfile, vision: server.visionProfile))
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
                if presentation.canAddEndpoint { modePicker }
                if mode == .saveEndpoint && presentation.canAddEndpoint {
                    addEndpointForm(presentation)
                } else {
                    startNowControls(presentation)
                }
                if let message = presentation.visibleMessage {
                    Text(message)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                }
                ErrorBanner(text: presentation.visibleError)
            }
        }
        .id("run-serve-primary")
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.sm) { modeSelector; modeCaption }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) { modeSelector; modeCaption }
            }
        }
    }

    private var modeSelector: some View {
        Picker("Mode", selection: $mode) {
            ForEach(ServeMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityLabel("Serve mode")
    }

    private var modeCaption: some View {
        Text(mode == .startNow ? "Starts one server for this model now."
             : "Keeps a stable port that restarts with Workbench and can load on request.")
            .font(WorkbenchTypography.secondary)
            .foregroundStyle(WorkbenchColor.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func startNowControls(_ presentation: RunPresentation) -> some View {
        Group {
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
                case .notEligible where !presentation.canPrepareSelection:
                    if let error = presentation.selectionError { InlineMessage(kind: .info, text: error) }
                    if presentation.needsWorkflowReview {
                        Button("Review Prepare") { onRouteSelection(.prepare) }.buttonStyle(.bordered)
                    } else {
                        Button("Open Library") { onRouteSelection(.library) }.buttonStyle(.bordered)
                    }
                default:
                    serveControls(presentation)
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
                    .truncationMode(.middle)
                    .help(item.path)
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                launchFields
                Spacer(minLength: WorkbenchSpacing.xs)
                stateWords(presentation)
                serveActions(presentation)
            }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                HStack(spacing: WorkbenchSpacing.sm) {
                    serveActions(presentation)
                    stateWords(presentation)
                }
                launchFields
            }
        }
        inferenceSettings
        if let error = portInput.error {
            Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
        }
    }

    private var inferenceContext: ServingInferenceContext {
        ServingInferenceContext.resolve(model: selectedModel, override: mode == .startNow ? runtime : "auto", profile: modelWorkflow.servingProfile, chip: appHost.hardwareProfile.chip)
    }

    @ViewBuilder
    private var inferenceSettings: some View {
        ServingInferenceControls(options: $inferenceOptions, context: inferenceContext)
            .disabled(modelWorkflow.isServeSubmissionInFlight || profiles.activeID != nil)
        if inferenceContext.isStrata {
            ServingProfileControls(profiles: appHost.servingProfiles, workflow: modelWorkflow, endpoint: endpoint,
                modelPath: shownPath, onCompare: { setup in
                    guard appHost.comparison.activeRunID == nil, !appHost.comparison.savingPromptSet else {
                        return "Wait for the current comparison or prompt-set save to finish."
                    }
                    appHost.handoffs.send(setup, as: .compareServingProfiles)
                    onRouteSelection(.compare)
                    return nil
                }, onPrepareModel: {
                    if let selectedModel { modelWorkflow.prepareServe(model: selectedModel) }
                })
        }
        ServingInferenceEvidenceView(rows: modelWorkflow.inferenceEvidence)
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
                Text("Text · MLX-LM").tag("mlx_lm")
                Text("Vision · MLX-VLM").tag("mlx-vlm")
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
        let options = inferenceOptions
        Task { await modelWorkflow.previewServe(runtime: runtime, port: port, m5Prefill: options.m5Prefill, promptLookup: options.promptLookup, visionCache: options.visionCache, thinkingOff: options.thinkingOff, maximumTokens: options.maximumTokens) }
    }

    private func confirmServeAction() {
        guard portInput.error == nil else { return }
        let port = portInput.port
        let runtime = runtime
        let options = inferenceOptions
        Task {
            await modelWorkflow.confirmServe(runtime: runtime, port: port, m5Prefill: options.m5Prefill, promptLookup: options.promptLookup, visionCache: options.visionCache, thinkingOff: options.thinkingOff, maximumTokens: options.maximumTokens)
            if modelWorkflow.workflow.serveState == .running { onRouteSelection(.activity) }
        }
    }

    @ViewBuilder
    private func serveActions(_ presentation: RunPresentation) -> some View {
        let busy = modelWorkflow.isServeSubmissionInFlight || portInput.error != nil
            || inferenceOptions.validationError != nil || (modelWorkflow.servingProfile.map { !$0.hasPassedVerification } ?? false) || appHost.servingProfiles.activeID != nil
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

    private var servingRows: [ServingRow] {
        ServingRows.build(slots: endpoint.fleet.slots, servers: modelWorkflow.servers, snapshot: inventory.snapshot)
    }

    private func refreshServing() async {
        await modelWorkflow.refreshServers()
        await inventory.refresh(refreshHosts: true)
    }

    private func servedModelsSection(_ presentation: RunPresentation, allowAdd: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                SectionTitle(text: "Served models")
                Spacer()
                Text(verbatim: "\(endpoint.fleet.slots.count) of \(EndpointFleetConfig.maxSlots) endpoints")
                    .font(WorkbenchTypography.secondaryTabular)
                    .foregroundStyle(WorkbenchColor.muted)
                Button {
                    Task { await refreshServing() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(inventory.isRefreshing)
                .help("Refresh serving status")
                .accessibilityLabel("Refresh serving status")
            }
            .id("run-served-models")
            ErrorBanner(text: modelWorkflow.serversError)
            ServingInventoryErrors(inventory: inventory)
            Text("Models serving now, saved endpoints that restart with Workbench, and other local services. Clients wired in Wire keep working.")
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
                .id("run-fleet-pending")
            }
            let rows = servingRows
            if rows.isEmpty {
                ContentUnavailableView("Nothing is serving", systemImage: "moon.zzz",
                    description: Text("Start a model above, or save it as an endpoint that loads on request."))
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if case .service = row, !rows[..<index].contains(where: { if case .service = $0 { return true }; return false }) {
                    Text("Other local services").font(WorkbenchTypography.cardTitle).padding(.top, WorkbenchSpacing.xs)
                }
                servingRowView(row, presentation: presentation).id(row.id)
            }
            if !allowAdd {
                Text("Saved endpoints use Library models. This trained adapter uses explicit serving above.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
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
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                ErrorBanner(text: actionError)
                ErrorBanner(text: inventory.actionError)
                ErrorBanner(text: endpoint.lastError)
                ErrorBanner(text: endpoint.persistenceError)
            }
            .id("run-served-errors")
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

    @ViewBuilder
    private func servingRowView(_ row: ServingRow, presentation: RunPresentation) -> some View {
        switch row {
        case .endpoint(let slot, let server, let service): endpointRow(slot, server: server, service: service)
        case .server(let server, _): servingRow(server, presentation: presentation)
        case .service(let service): serviceRow(service)
        }
    }

    private func serviceRow(_ service: ServingServiceObservation) -> some View {
        let model = service.modelPath.flatMap { path in models.first { $0.item.path == path || $0.outputPaths.contains(path) } }
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            ServingServiceRow(service: service, inventory: inventory, compact: isCompact) { kind in
                Task { await inventory.prepare(kind, service: service) }
            }
            if let server = service.server, service.isWorkbenchManaged || model != nil {
                HStack(spacing: WorkbenchSpacing.xs) { promptButtons(server, name: service.name) }
            }
            if let model {
                Button("Show in Library") { revealModel(model.item.path) }.buttonStyle(.borderless)
            }
        }
        .padding(WorkbenchSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
    }

    @ViewBuilder
    private func taskButton(_ server: ServerInfo) -> some View {
        if let origin = try? ServedTaskOrigin(server: server),
           let model = models.first(where: { $0.readiness == .ready && Quarantine.resolve($0.item.path) == Quarantine.resolve(server.path!) }) {
            Button("Run a task…") { taskPresentation = ServedTaskPresentation(origin: origin, model: model) }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(modelWorkflow.serversError != nil)
                .accessibilityIdentifier("run-model-task-\(server.port ?? 0)")
        }
    }

    private func revealModel(_ path: String) {
        appHost.selectedModelPath = path
        appHost.handoffs.send(LibraryRevealRequest(modelPath: path), as: .revealModel)
        onRouteSelection(.library)
    }

    @ViewBuilder
    private func promptButtons(_ server: ServerInfo, name: String) -> some View {
        taskButton(server)
        Button("Try a prompt…") { promptPresentation = endpointTest.open(server) }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(!EndpointTestCoordinator.supports(server) || modelWorkflow.serversError != nil
                      || appHost.occupancy.blocksStop(server) || endpointTest.isSending || endpointTest.presentationID != nil)
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
            .help("Select this endpoint in Clients. Preview and confirm before changing client configuration.")
        }
    }

    private func endpointRow(_ slot: EndpointSlot, server: ServerInfo?, service: ServingServiceObservation?) -> some View {
        let slotState = endpoint.slotStates[slot.id] ?? .disabled
        let model = RunModels.model(for: slot.modelPath, in: models)
        let name = RunModels.name(for: slot.modelPath, model: model)
        let attempts = endpoint.slotRestartAttempts[slot.id] ?? 0
        let isLoading = modelWorkflow.servers.contains { $0.port == slot.port && RunStateWord.isLoading($0) }
        let rowID = "endpoint-\(slot.id.uuidString)"
        let busy = endpoint.isChanging || !comparison.hasLoadedHistory
        @ViewBuilder func header(_ factsInline: Bool) -> some View {
            HStack(spacing: WorkbenchSpacing.sm) {
                StatusPill(state: slotStateLabel(slotState, enabled: slot.enabled))
                    .frame(minWidth: WorkbenchSize.Run.chip, alignment: .leading)
                Text(name)
                    .font(WorkbenchTypography.emphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                    .frame(minWidth: WorkbenchSize.Run.slotModelMinimum, alignment: .leading)
                    .help(slot.modelPath)
                if let profile = slot.servingProfile {
                    Text(profiles.profiles.first(where: { $0.id == profile.id })?.name ?? profile.name)
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
                if factsInline { slotFacts(slot, attempts: attempts) }
                Spacer(minLength: WorkbenchSpacing.xs)
                Button(slot.enabled ? "Stop" : "Start…") {
                    if slot.enabled { Task { if let refusal = await changes.stop(slot) { actionError = refusal } } }
                    else { prepare(slot: slot, remove: false) }
                }
                .disabled(busy)
                .accessibilityLabel("\(slot.enabled ? "Stop" : "Start") \(name)")
                .help(slot.enabled ? "Stop this endpoint and disable automatic restart." : "Review fit and verification, then start this endpoint.")
                slotMenu(slot, server: server, service: service, name: name)
            }
        }
        @ViewBuilder func twoLine() -> some View {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                header(false)
                ReclaimFlowLayout(spacing: WorkbenchSpacing.sm, lineSpacing: WorkbenchSpacing.xxs) { slotFacts(slot, attempts: attempts) }
            }
        }
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            // Wide rows keep the facts on the header line; they fall back to a second line when they do not fit.
            if isTwoLine { twoLine() } else { ViewThatFits(in: .horizontal) { header(true); twoLine() } }
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
                if slot.apiKeySHA256 != nil {
                    Text("API key required").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
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
            if let service { serviceDetails(service, id: rowID, name: name) }
            if server != nil || !isCompact {
                HStack(spacing: WorkbenchSpacing.xs) {
                    if let server { promptButtons(server, name: name) }
                    if !isCompact {
                        Button("Copy base URL") { ServedModelsSelection.copy("http://127.0.0.1:\(slot.port)/v1") }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .contextMenu { slotMenuItems(slot, server: server, service: service, includeCopyURL: true) }
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
        if slot.inferenceOptions.requested {
            Text(slot.inferenceOptions.summary)
                .font(WorkbenchTypography.metadata)
                .foregroundStyle(WorkbenchColor.muted)
        }
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

    private func slotMenu(_ slot: EndpointSlot, server: ServerInfo?, service: ServingServiceObservation?, name: String) -> some View {
        Menu {
            slotMenuItems(slot, server: server, service: service, includeCopyURL: isCompact)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: WorkbenchSize.Run.overflow)
        .help("Endpoint actions")
        .disabled(endpoint.isChanging)
        .accessibilityLabel("Actions for \(name)")
    }

    /// The endpoint's commands, shared by the overflow menu and the row's context menu.
    @ViewBuilder
    private func slotMenuItems(_ slot: EndpointSlot, server: ServerInfo?, service: ServingServiceObservation?, includeCopyURL: Bool) -> some View {
        let connection = ServedModelsSelection.connection(slot: slot, state: endpoint.slotStates[slot.id], servers: modelWorkflow.servers)
        Group {
            if includeCopyURL {
                Button("Copy base URL") { ServedModelsSelection.copy("http://127.0.0.1:\(slot.port)/v1") }
                Divider()
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
            Button("Inference settings…") { inferenceSlot = slot }
                .disabled(endpoint.pendingStops[slot.id] != nil)
                .help("Review inference settings. Stop the endpoint before changing them.")
            if let connection { Button("Copy model ID") { ServedModelsSelection.copy(connection.modelName) } }
            else if slot.apiKeySHA256 != nil, let server {
                Button("Copy model ID") { ServedModelsSelection.copy(server.modelIdentity) }
            }
            if let hash = slot.apiKeySHA256 {
                Button("Copy API key") {
                    do { ServedModelsSelection.copy(try EndpointCredentialStore.token(for: hash)) }
                    catch { actionError = AppHost.render(error) }
                }
                Button("Reset API key…") { prepareAuthentication(slot, required: true) }
                    .disabled(slot.enabled).help("Stop this endpoint before resetting its key.")
            }
            Button(slot.apiKeySHA256 == nil ? "Require API key…" : "Disable authentication…") {
                prepareAuthentication(slot, required: slot.apiKeySHA256 == nil)
            }.disabled(slot.enabled).help("Stop this endpoint before changing authentication.")
            if modelWorkflow.servers.contains(where: { $0.port == slot.port && $0.runtime == "tasks" }) {
                Button("Copy jobs URL") { ServedModelsSelection.copy("http://127.0.0.1:\(slot.port)/v1/tasks") }
            }
            if let service, service.canUnload {
                Button("Unload model…") { Task { await inventory.prepare(.unload, service: service) } }
                    .disabled(inventory.isChanging || !inventory.mayChange(service))
            }
            if models.contains(where: { $0.item.path == slot.modelPath || $0.outputPaths.contains(slot.modelPath) }) {
                Button("Show in Library") { revealModel(slot.modelPath) }
            }
            Divider()
            Button("Remove…", role: .destructive) { prepare(slot: slot, remove: true) }
                .help("Remove this endpoint. Model files stay in Library.")
        }
    }

    @ViewBuilder
    private func serviceDetails(_ service: ServingServiceObservation, id: String, name: String) -> some View {
        if isCompact {
            DisclosureGroup("Details", isExpanded: Binding(
                get: { expandedDetails.contains(id) },
                set: { if $0 { expandedDetails.insert(id) } else { expandedDetails.remove(id) } })) {
                ServingServiceDetails(service: service, inventory: inventory).padding(.top, WorkbenchSpacing.xxs)
            }
            .font(WorkbenchTypography.secondary)
            .accessibilityLabel("Details for \(name)")
        } else {
            ServingServiceDetails(service: service, inventory: inventory)
        }
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
                    .disabled(policy.keepLoaded || policy.releaseAfterRequest == true)
                    Toggle("Keep loaded after use", isOn: memoryBinding(slot, \.keepLoaded))
                        .toggleStyle(.checkbox)
                        .help("Prevent automatic unload after the first request. Manual unload remains available.")
                }
                Toggle("Release weights after each request", isOn: Binding(
                    get: { policy.releaseAfterRequest == true },
                    set: { enabled in
                        var updated = policy
                        updated.releaseAfterRequest = enabled
                        if enabled { updated.keepLoaded = false; updated.idleTimeoutSeconds = 0 }
                        Task { await endpoint.setSlotMemoryPolicy(id: slot.id, updated) }
                    }))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("endpoint-memory-release-after-request")
                HStack {
                    Toggle("Check memory before loading", isOn: Binding(
                        get: { policy.minimumHeadroomGB != nil },
                        set: { enabled in
                            var updated = policy
                            updated.minimumHeadroomGB = enabled ? 2 : nil
                            if !enabled { updated.unloadUnderPressure = nil; updated.contextTokens = nil; updated.modelMemoryBudgetGB = nil }
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
                Button("Review memory policy…") { memoryReviewSlot = slot }
                    .accessibilityIdentifier("endpoint-memory-review")
            }
            .padding(.top, WorkbenchSpacing.sm)
            .controlSize(.small)
            .disabled(endpoint.isUnloading)
        } label: {
            HStack {
                Text("Memory management")
                Text(policy.releaseAfterRequest == true ? "Release after each request" : policy.keepLoaded ? "Keeps loaded" : (policy.idleTimeoutSeconds == 0 ? "Manual unload" : "Idle unload · \(policy.idleTimeoutSeconds / 60) min"))
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
                    if policy.keepLoaded {
                        policy.unloadUnderPressure = nil
                        if policy.releaseAfterRequest == true { policy.releaseAfterRequest = false }
                    }
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
    private func addEndpointForm(_ presentation: RunPresentation) -> some View {
        if endpoint.fleet.slots.count >= EndpointFleetConfig.maxSlots {
            designedState(symbol: "square.stack.3d.up.slash", text: "Endpoint cap reached (\(EndpointFleetConfig.maxSlots)). Remove one to add another.")
        } else {
            let unverified = selectedModel.map { !appHost.isModelVerified($0.item.path) } ?? false
            ReclaimFlowLayout(spacing: WorkbenchSpacing.sm, lineSpacing: WorkbenchSpacing.xs) {
                addEndpointPortAndRole
                addEndpointLoadToggle
                if newSlotLoadOnRequest {
                    Picker("Model residency", selection: $keepModelLoaded) {
                        Text("Release weights after each request").tag(false)
                        Text("Keep loaded between requests").tag(true)
                    }
                    .fixedSize()
                    .accessibilityIdentifier("serve-model-residency")
                }
            }
            if let endpointPortError {
                Text(endpointPortError).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
            }
            inferenceSettings
            if unverified {
                InlineMessage(kind: .warning, text: "This model has not passed verification. Confirm only if you intend to serve it unverified.")
            }
            HStack(spacing: WorkbenchSpacing.xs) {
                Toggle("Require API key", isOn: $requireAPIKey)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("serve-model-authentication")
                    .help("Only clients with this key can use inference. The endpoint stays on loopback; the key is saved in Keychain when you confirm.")
                Spacer(minLength: WorkbenchSpacing.xs)
                Button(unverified ? "Add unverified endpoint…" : "Add endpoint…") { prepareAddEndpoint() }
                    .buttonStyle(.workbenchPrimary)
                    .disabled(!presentation.canAddEndpoint || endpoint.isChanging || !comparison.hasLoadedHistory || inferenceOptions.validationError != nil || (modelWorkflow.servingProfile.map { !$0.hasPassedVerification } ?? false))
                    .help(presentation.addEndpointBlockedReason ?? "Review and add the model shown above as a saved endpoint.")
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

    /// A port the user may give a new endpoint: 1024 to 65535, unused by any endpoint or server.
    static func isUsablePort(_ port: Int, slots: [EndpointSlot], servers: [ServerInfo]) -> Bool {
        (1024...65535).contains(port) && !slots.contains { $0.port == port } && !servers.contains { $0.port == port }
    }

    private var changes: EndpointChanges { EndpointChanges(appHost: appHost) }

    private func prepareAddEndpoint() {
        switch changes.reviewAdd(model: selectedModel, portText: endpointPortText, suggestedPort: suggestedPort, role: newSlotRole,
                                 loadOnRequest: newSlotLoadOnRequest, keepLoaded: keepModelLoaded, requireKey: requireAPIKey, inference: inferenceOptions, profile: modelWorkflow.servingProfile) {
        case .noModel: return
        case .portRejected(let message): endpointPortError = message
        case .review(let review): endpointPortError = nil; action = review
        }
    }

    private func prepare(slot: EndpointSlot, remove: Bool) {
        action = changes.review(slot: slot, remove: remove)
    }

    private func confirmation(_ pending: EndpointChangeReview) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text(pending.remove ? "Remove endpoint?" : pending.slot == nil ? "Add this endpoint?" : "Start this endpoint?")
                .font(WorkbenchTypography.cardTitle)
            Text(pending.model?.displayName ?? pending.slot?.modelPath ?? "Model").textSelection(.enabled)
            Text(verbatim: pending.remove ? "Its endpoint will stop. Model files stay in Library."
                 : "Other apps can connect to http://127.0.0.1:\(pending.port)/v1.")
            if !pending.remove && pending.slot == nil {
                Text(verbatim: "\(pending.role.map { "Role: \($0.title). " } ?? "")\(pending.loadOnRequest ? (pending.keepLoaded ? "Loads on request and stays loaded." : "Loads on request and releases weights after each request.") : "Always loaded.")")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                if pending.requireKey {
                    Text("Only clients with a new API key can use inference. The endpoint stays on loopback; the key is saved in Keychain.")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
            }
            if !pending.remove, pending.slot == nil {
                Text(pending.inference.summary).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                if let profile = pending.profile { Text("Profile: \(profile.name) · \(profile.options.decodingTitle)").font(WorkbenchTypography.secondary) }
            }
            if pending.unverified { InlineMessage(kind: .warning, text: "This model has not passed verification. Confirm only if you intend to serve it unverified.") }
            if let warning = pending.memoryWarning { InlineMessage(kind: .warning, text: warning) }
            HStack {
                Button("Cancel") { action = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(pending.remove ? "Remove endpoint" : pending.slot != nil ? "Start endpoint" : pending.unverified ? "Add unverified endpoint" : "Add endpoint") {
                    Task { await apply(pending) }
                }.buttonStyle(.workbenchPrimary).disabled(endpoint.isChanging)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 460)
    }

    /// Rechecks the reviewed change against current state, then performs it.
    private func apply(_ pending: EndpointChangeReview) async {
        action = nil; actionError = nil
        actionError = await changes.confirm(pending, holdForOverride: fleetHold.hold)
    }

    private func prepareAuthentication(_ slot: EndpointSlot, required: Bool) {
        Task {
            do { authenticationReview = try await endpoint.previewAuthentication(slot: slot, required: required) }
            catch { actionError = AppHost.render(error) }
        }
    }

    private func authenticationConfirmation(_ review: EndpointAuthenticationReview) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text(review.keySHA256 == nil ? "Disable API key authentication?" : "Require a new API key?")
                .font(WorkbenchTypography.cardTitle)
            Text("Endpoint: 127.0.0.1:\(review.slot.port)").textSelection(.enabled)
            Text(review.keySHA256 == nil ? "Any local client will be able to use this endpoint after you start it."
                 : "Only clients holding the new key can use this endpoint. Copy the key after saving and configure it in each client. Previous keys stop working.")
            Text("The endpoint stays stopped. Model files stay in place.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            HStack {
                Button("Cancel") { authenticationReview = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save authentication") {
                    Task {
                        if await endpoint.confirmAuthentication(review) { authenticationReview = nil }
                        actionError = endpoint.lastError
                    }
                }.buttonStyle(.workbenchPrimary).disabled(endpoint.isChanging)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 460)
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

/// A wont-fit fleet action awaiting the user's explicit override.
struct PendingFleetAction: Identifiable {
    let id = UUID()
    let summary: String
    let confirm: () -> Void
}

/// Holds the wont-fit action the Run page asks the user to override.
@MainActor
final class FleetOverrideHold: ObservableObject {
    @Published var pending: PendingFleetAction?

    func hold(_ summary: String, confirm: @escaping () -> Void) {
        pending = PendingFleetAction(summary: summary, confirm: confirm)
    }
}

/// A reviewed endpoint change: add, start or remove. Confirmation rechecks it before acting.
struct EndpointChangeReview: Identifiable {
    let id = UUID()
    let model: LibraryModel?
    let slot: EndpointSlot?
    let port: Int
    let role: UseCase?
    let loadOnRequest: Bool
    let keepLoaded: Bool
    let requireKey: Bool
    let memoryWarning: String?
    let unverified: Bool
    let remove: Bool
    var inference = LocalInferenceOptions()
    var profile: ServingProfile? = nil
}

/// Reviews endpoint changes and rechecks them against current state when confirmed.
@MainActor
struct EndpointChanges {
    let appHost: AppHost

    enum AddOutcome {
        case review(EndpointChangeReview)
        case portRejected(String)
        case noModel
    }

    private var models: [LibraryModel] { appHost.librarySnapshot?.models ?? [] }

    /// Workbench's servers plus the local servers other tools run, whose ports a new endpoint must not take.
    private var occupiedServers: [ServerInfo] {
        appHost.modelWorkflow.servers + appHost.servingInventory.snapshot.services.compactMap(\.server)
    }

    func reviewAdd(model: LibraryModel?, portText: String, suggestedPort: Int, role: UseCase?, loadOnRequest: Bool,
                   keepLoaded: Bool, requireKey: Bool, inference: LocalInferenceOptions = .init(), profile: ServingProfile? = nil) -> AddOutcome {
        guard let model else { return .noModel }
        if let error = inference.validationError { return .portRejected(error) }
        if let profile, !profile.hasPassedVerification || profile.modelPath != model.item.path {
            return .portRejected("Verify the selected serving profile for this model before adding the endpoint.")
        }
        let text = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = text.isEmpty ? suggestedPort : (Int(text) ?? 0)
        guard ServeView.isUsablePort(port, slots: appHost.endpoint.fleet.slots, servers: occupiedServers) else {
            return .portRejected("Choose a port from 1024 to 65535 that no endpoint or server uses.")
        }
        return .review(EndpointChangeReview(model: model, slot: nil, port: port, role: role, loadOnRequest: loadOnRequest,
            keepLoaded: keepLoaded, requireKey: requireKey, memoryWarning: memoryWarning(for: model.item.path),
            unverified: !appHost.isModelVerified(model.item.path), remove: false, inference: inference, profile: profile))
    }

    func review(slot: EndpointSlot, remove: Bool) -> EndpointChangeReview {
        EndpointChangeReview(model: models.first { $0.item.path == slot.modelPath || $0.outputPaths.contains(slot.modelPath) },
            slot: slot, port: slot.port, role: slot.role, loadOnRequest: slot.usesJIT, keepLoaded: false, requireKey: false,
            memoryWarning: remove ? nil : memoryWarning(for: slot.modelPath),
            unverified: !remove && !appHost.isModelVerified(slot.modelPath), remove: remove)
    }

    private func memoryWarning(for path: String) -> String? {
        guard let verdict = appHost.runFleetVerdict(adding: path) else { return nil }
        if case .fits = verdict { return nil }
        return verdict.summary
    }

    /// Why this endpoint cannot stop or be removed now; nil when it can.
    func stopRefusal(_ slot: EndpointSlot) -> String? {
        guard appHost.comparison.hasLoadedHistory, !appHost.occupancy.blocksStop(modelIdentity: slot.modelPath) else {
            return "Finish the operation using this model before stopping or removing its endpoint."
        }
        return nil
    }

    /// Stops the endpoint unless work holds its model; returns the refusal reason.
    func stop(_ slot: EndpointSlot) async -> String? {
        if let refusal = stopRefusal(slot) { return refusal }
        await appHost.endpoint.setSlotEnabled(id: slot.id, false)
        return nil
    }

    /// Performs the reviewed change when current state still matches it; returns why it did not.
    /// A change that would exceed fleet memory goes to `holdForOverride` instead of running.
    func confirm(_ review: EndpointChangeReview, holdForOverride: (String, @escaping () -> Void) -> Void) async -> String? {
        let endpoint = appHost.endpoint
        if let slot = review.slot {
            guard endpoint.fleet.slots.contains(slot) else { return "Endpoint changed; review it again." }
            if review.remove {
                if let refusal = stopRefusal(slot) { return refusal }
                await endpoint.removeSlot(id: slot.id)
                return nil
            }
            guard review.memoryWarning == memoryWarning(for: slot.modelPath) else { return "Memory conditions changed; review the endpoint again." }
            guard review.unverified == !appHost.isModelVerified(slot.modelPath) else { return "Verification changed; review the endpoint again." }
            await run(adding: slot.modelPath, holdForOverride: holdForOverride) { await endpoint.setSlotEnabled(id: slot.id, true) }
        } else if let model = review.model {
            guard ServedModelsSelection.canConfirm(model: model, models: models),
                  ServedModelsSelection.candidates(models: models, slots: endpoint.fleet.slots, query: "").contains(where: { $0.item.path == model.item.path }),
                  ServeView.isUsablePort(review.port, slots: endpoint.fleet.slots, servers: occupiedServers),
                  review.memoryWarning == memoryWarning(for: model.item.path),
                  review.unverified == !appHost.isModelVerified(model.item.path) else {
                return "Model, port or memory conditions changed; review the endpoint again."
            }
            await run(adding: model.item.path, holdForOverride: holdForOverride) {
                await endpoint.addSlot(modelPath: model.item.path, port: review.port, role: review.role, allowUnverified: review.unverified,
                    loadOnRequest: review.loadOnRequest,
                    memoryPolicy: review.loadOnRequest ? EndpointMemoryPolicy(idleTimeoutSeconds: 0, keepLoaded: review.keepLoaded,
                        minimumHeadroomGB: 2, releaseAfterRequest: !review.keepLoaded) : nil,
                    requireAPIKey: review.requireKey, inference: review.inference, profile: review.profile)
            }
        }
        return nil
    }

    /// Adding a model that tips the fleet past wont-fit needs the explicit override; tight is warned in place.
    private func run(adding path: String, holdForOverride: (String, @escaping () -> Void) -> Void,
                     _ work: @escaping @MainActor () async -> Void) async {
        if let verdict = appHost.runFleetVerdict(adding: path), case .wontFit = verdict {
            holdForOverride(verdict.summary) { _ = Task { await work() } }
            return
        }
        await work()
    }
}

private struct EndpointInferenceEditor: View {
    @ObservedObject var endpoint: EndpointSupervisor
    let slot: EndpointSlot
    let context: ServingInferenceContext
    var onManageProfile: ((ServingProfile) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var options: LocalInferenceOptions
    @State private var preview: EndpointInferencePreview?
    @State private var busy = false
    @State private var error: String?

    init(endpoint: EndpointSupervisor, slot: EndpointSlot, context: ServingInferenceContext, onManageProfile: ((ServingProfile) -> Void)? = nil) {
        self.endpoint = endpoint
        self.slot = slot
        self.context = context
        self.onManageProfile = onManageProfile
        _options = State(initialValue: slot.inferenceOptions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    Text("Endpoint inference settings").font(WorkbenchTypography.cardTitle)
                    Text(verbatim: "\(URL(fileURLWithPath: slot.modelPath).lastPathComponent) · :\(slot.port)")
                        .font(WorkbenchTypography.secondary)
                    if slot.enabled {
                        InlineMessage(kind: .info, text: "Stop this endpoint to change its inference settings.")
                    }
                    ServingInferenceControls(options: $options, context: context).disabled(slot.enabled)
                    if let profile = slot.servingProfile {
                        Text("Profile: \(profile.name) · \(profile.options.decodingTitle)").font(WorkbenchTypography.secondary)
                        if let onManageProfile {
                            Button("Manage profile in Run") { onManageProfile(profile) }.disabled(slot.enabled)
                        }
                    }
                    if let error { InlineMessage(kind: .error, text: error) }
                    if busy { ProgressView("Checking launch configuration…") }
                    if let preview {
                        Text("Launch preview: \(preview.hash)")
                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                            .textSelection(.enabled)
                    }
                    Text("After saving, enable the endpoint. Reinstall an existing login item to capture the changed settings.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
            }
            .frame(maxHeight: 560)
            HStack {
                Button("Cancel") { dismiss() }.disabled(busy)
                Spacer()
                if let preview {
                    Button("Confirm and save") {
                        busy = true
                        Task {
                            if await endpoint.confirmSlotInference(preview) { dismiss() }
                            else { error = endpoint.lastError; self.preview = nil }
                            busy = false
                        }
                    }.buttonStyle(.workbenchPrimary).disabled(slot.enabled || busy || endpoint.isChanging || options.validationError != nil)
                } else {
                    Button("Preview settings") {
                        busy = true; error = nil
                        Task {
                            do {
                                guard endpoint.fleet.slots.contains(slot) else {
                                    throw WorkflowEvidenceError.invalid("Endpoint settings changed. Close and reopen inference settings.")
                                }
                                preview = try await endpoint.previewSlotInference(id: slot.id, options: options)
                            }
                            catch { self.error = AppHost.render(error) }
                            busy = false
                        }
                    }.buttonStyle(.workbenchPrimary).disabled(slot.enabled || busy || endpoint.isChanging || options.validationError != nil)
                }
            }
        }
        .padding(WorkbenchSpacing.md)
        .frame(width: 560)
        .disabled(busy)
        .onChange(of: options) { _, _ in preview = nil; error = nil }
        .interactiveDismissDisabled(busy)
    }
}
