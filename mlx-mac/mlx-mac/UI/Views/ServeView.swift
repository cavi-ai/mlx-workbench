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

private struct ServingPortReview: Identifiable {
    let id = UUID()
    let slot: EndpointSlot
    let port: Int
}

struct ServeView: View {
    let appHost: AppHost
    @ObservedObject private var modelWorkflow: ModelWorkflowCoordinator
    @ObservedObject private var endpoint: EndpointSupervisor
    @ObservedObject private var profiles: ServingProfileCoordinator
    @ObservedObject private var trainedAdapters: TrainedAdapterServingCoordinator
    @ObservedObject private var endpointTest: EndpointTestCoordinator
    @ObservedObject private var servedTasks: ServedTaskSessions
    @ObservedObject private var useWorkspace: UseWorkspaceCoordinator
    @ObservedObject private var inventory: ServingInventoryCoordinator
    @ObservedObject private var comparison: ComparisonCoordinator
    @ObservedObject private var tailnet: TailnetSharingCoordinator
    @ObservedObject private var frontDoor: FrontDoorCoordinator
    @Environment(\.isRouteActive) private var isRouteActive
    @State private var tailnetServer: ServerInfo?
    @State private var mode = ServeMode.saveEndpoint
    @State private var action: EndpointChangeReview?
    @State private var authenticationReview: EndpointAuthenticationReview?
    @State private var keyResetReview: WorkbenchKeyResetReview?
    @State private var showsKeyWizard = false
    @State private var workspaceSelection: String?
    @State private var inspectorScroll: ServingInspectorPresentation.Section?
    @State private var includesAvailable = false
    @State private var showsServerSetup = false
    @State private var showsSourceIssues = false
    @State private var connectionPort = ""
    @State private var portReview: ServingPortReview?
    @State private var actionError: String?
    @State private var openingExistingEndpoint = false
    @State private var keepModelLoaded = false
    @State private var requireAPIKey = false
    @State private var splashPresets: [SplashPreset] = []
    @State private var agentMemoryBudget: AgentMemoryBudget?
    @State private var selectedSplashPresetName = ""
    @State private var showingSplashEditor = false
    @State private var splashPresetSlot: EndpointSlot?
    @State private var splashPresetError: String?
    @State private var endpointPortError: String?
    @State private var expandedDetails: Set<String> = []
    @State private var revealedModelPath: String?
    @State private var reportedActionError: String?
    private let onRouteSelection: (AppRoute) -> Void
    @State private var runtime = "auto"
    @State private var inferenceOptions = LocalInferenceOptions()
    @State private var revealInferenceRevision = UUID()
    @State private var promptPresentation: EndpointTestPresentation?
    @State private var portText = ""
    @State private var endpointPortText = ""
    @State private var newSlotLoadOnRequest = true
    @StateObject private var fleetHold: FleetOverrideHold
    private var pendingFleetAction: PendingFleetAction? {
        get { fleetHold.pending }
        nonmutating set { fleetHold.pending = newValue }
    }
    @State private var showFleetRouter = false
    @State private var showLoginItemPreview = false
    @State private var loginPlans: [LoginItemPlan] = []
    @State private var loginFitOverride = false
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
        _useWorkspace = ObservedObject(wrappedValue: appHost.useWorkspace)
        _action = State(initialValue: initialReview)
        _fleetHold = StateObject(wrappedValue: fleetHold ?? FleetOverrideHold())
        _modelWorkflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _profiles = ObservedObject(wrappedValue: appHost.servingProfiles)
        _trainedAdapters = ObservedObject(wrappedValue: appHost.trainedAdapters)
        _endpointTest = ObservedObject(wrappedValue: appHost.endpointTest)
        _inventory = ObservedObject(wrappedValue: appHost.servingInventory)
        _comparison = ObservedObject(wrappedValue: appHost.comparison)
        _tailnet = ObservedObject(wrappedValue: appHost.tailnetSharing)
        _frontDoor = ObservedObject(wrappedValue: appHost.frontDoor)
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
            Group {
                if viewport.size.width >= WorkbenchSize.Serving.splitMinimum {
                    HStack(spacing: 0) {
                        ServingModelList(appHost: appHost, roleRows: ServingRolesPresentation.roleRows(slots: endpoint.fleet.slots, rows: workspaceRows),
                            endpointRows: ServingRolesPresentation.endpointRows(workspaceRows),
                            otherRows: ServingRolesPresentation.otherRows(workspaceRows),
                            slots: endpoint.fleet.slots, models: models, states: endpoint.slotStates,
                            sourceIssueCount: inventory.snapshot.sourceErrors.count,
                            selectedID: $workspaceSelection, includesAvailable: $includesAvailable,
                            choose: chooseModel, change: changeModel, toggle: toggleEndpoint,
                            add: openServerSetup, monitor: { onRouteSelection(.monitor) },
                            refresh: { Task { await refreshServing() } }, showSources: { showsSourceIssues = true })
                        Divider()
                        workspaceDetail
                    }
                } else {
                    VStack(spacing: 0) {
                        WorkbenchAPIRowView(appHost: appHost, coordinator: appHost.frontDoor, endpoint: appHost.endpoint)
                            .padding(.horizontal, WorkbenchSpacing.md).padding(.top, WorkbenchSpacing.xs)
                        HStack {
                            Menu(selectedWorkspaceRow.map { ServingWorkspacePresentation.name($0, models: models) } ?? "Choose endpoint") {
                                ForEach(workspaceRows) { row in
                                    Button(ServingWorkspacePresentation.name(row, models: models)) { workspaceSelection = row.id; showsServerSetup = false }
                                }
                                Divider()
                                Toggle("Include available models", isOn: $includesAvailable)
                            }
                            Spacer()
                            Button("Serve a model", action: openServerSetup).accessibilityIdentifier("serving-add-model")
                            Button("Monitor") { onRouteSelection(.monitor) }
                            if !inventory.snapshot.sourceErrors.isEmpty {
                                Button { showsSourceIssues = true } label: { Image(systemName: "info.circle") }
                                    .accessibilityLabel(ServingWorkspacePresentation.sourceIssueTitle(inventory.snapshot.sourceErrors.count))
                                    .help(ServingWorkspacePresentation.sourceIssueTitle(inventory.snapshot.sourceErrors.count))
                            }
                        }.padding(WorkbenchSpacing.md)
                        Divider()
                        workspaceDetail
                    }
                }
            }
            .onChange(of: viewport.size.width, initial: true) { _, width in
                viewportWidth = width - (width >= WorkbenchSize.Serving.splitMinimum ? WorkbenchSize.Serving.sidebar : 0)
            }
        }
        .onChange(of: workspaceSelection) { _, new in
            if new != nil { showsServerSetup = false; synchronizeConnectionPort() }
        }
        .onChange(of: workspaceRows.map(\.id), initial: true) { _, ids in
            if isRouteActive, shownPath != revealedModelPath { focusShownModel() }
            if let selection = workspaceSelection, !ids.contains(selection) { workspaceSelection = ids.first }
            else if workspaceSelection == nil && !showsServerSetup { workspaceSelection = ids.first }
        }
        .onChange(of: shownPath, initial: true) { old, _ in
            if old != shownPath { inferenceOptions = .init() }
            focusShownModel()
        }
        .onChange(of: endpoint.fleet.slots.map(\.id)) { old, new in
            if showsServerSetup, let id = new.first(where: { !old.contains($0) }) {
                workspaceSelection = "endpoint-\(id.uuidString)"; showsServerSetup = false
            }
        }
        .onChange(of: appHost.handoffs[.openServing], initial: true) { _, _ in focusRequestedServer() }
        .onChange(of: appHost.handoffs[.serveWithRuntime], initial: true) { _, _ in applyRequestedRuntime() }
        .sheet(item: $tailnetServer) { server in
            TailnetSharingWizard(server: server, coordinator: appHost.tailnetSharing)
        }
        .sheet(isPresented: $showsSourceIssues) { sourceIssuesSheet }
        .sheet(item: $portReview) { review in portReviewSheet(review) }
        .sheet(item: gated($action)) { pending in confirmation(pending) }
        .sheet(item: gated($authenticationReview)) { review in authenticationConfirmation(review) }
        .sheet(item: gated($keyResetReview)) { review in keyResetConfirmation(review) }
        .sheet(isPresented: $showsKeyWizard) { WorkbenchKeyWizard(appHost: appHost) }
        .sheet(item: $promptPresentation) { presentation in
            EndpointTestSheet(presentation: presentation, coordinator: endpointTest) {
                guard let request = ClientWiringRequest.forServer(presentation.server) else { return }
                appHost.handoffs.send(request, as: .wireClient)
                onRouteSelection(.clientSetup)
            }
        }
        .sheet(item: $memoryReviewSlot) { slot in
            EndpointMemoryReviewSheet(slot: slot, endpoint: endpoint, api: appHost.api)
        }
        .sheet(isPresented: $showingSplashEditor) {
            SplashPresetEditor(api: appHost.api) { preset in
                await loadSplashPresets()
                selectedSplashPresetName = preset.name
            }
        }
        .sheet(item: $splashPresetSlot) { slot in
            SplashPresetApplySheet(slot: slot, endpoint: endpoint, api: appHost.api)
        }
        .modifier(ServeViewLifecycleModifier(
            isRouteActive: isRouteActive,
            selectedSplashPresetName: selectedSplashPresetName,
            newSlotLoadOnRequest: newSlotLoadOnRequest,
            requireAPIKey: requireAPIKey,
            selectedModelPath: selectedModel?.item.path,
            servers: modelWorkflow.servers,
            serversError: modelWorkflow.serversError,
            inferenceOptions: inferenceOptions,
            runtime: runtime,
            mode: mode,
            servingProfile: modelWorkflow.servingProfile,
            portText: portText,
            onTask: {
                await loadSplashPresets()
                await refreshAgentMemoryBudget()
            },
            onRouteTask: {
                async let discovery: Void = refreshDiscovery()
                async let budget: Void = refreshAgentMemoryBudget()
                await modelWorkflow.refreshServers()
                await discovery
                await budget
            },
            onSplashPresetChanged: { name in
                if !name.isEmpty { newSlotLoadOnRequest = true; inferenceOptions.sharedPrefixCacheMiB = nil }
                inferenceOptions = inferenceContext.normalized(inferenceOptions)
                modelWorkflow.invalidateServePreview()
            },
            onLoadOnRequestChanged: { enabled in
                if !enabled {
                    inferenceOptions.systemPrompt = ""
                    inferenceOptions.temperature = nil
                    inferenceOptions.topP = nil
                    inferenceOptions.sharedPrefixCacheMiB = nil
                }
            },
            onRequireAPIKeyChanged: { required in
                if !required { inferenceOptions.sharedPrefixCacheMiB = nil }
            },
            onSelectedModelChanged: { selectedSplashPresetName = "" },
            onServersChanged: { servers in trainedAdapters.receiveServers(servers, error: modelWorkflow.serversError) },
            onServersErrorChanged: { error in trainedAdapters.receiveServers(modelWorkflow.servers, error: error) },
            onRouteActiveChanged: { active in
                if active { focusShownModel(); focusRequestedServer(); applyRequestedRuntime() }
                else { closePrompt() }
            },
            onDisappear: closePrompt,
            onInferenceOptionsChanged: { modelWorkflow.invalidateServePreview() },
            onRuntimeChanged: {
                inferenceOptions = inferenceContext.normalized(inferenceOptions)
                modelWorkflow.invalidateServePreview()
            },
            onModeChanged: { value in
                if value == .startNow {
                    inferenceOptions.systemPrompt = ""
                    inferenceOptions.temperature = nil
                    inferenceOptions.topP = nil
                    inferenceOptions.sharedPrefixCacheMiB = nil
                }
                inferenceOptions = inferenceContext.normalized(inferenceOptions)
                modelWorkflow.invalidateServePreview()
            },
            onServingProfileChanged: {
                inferenceOptions = inferenceContext.normalized(inferenceOptions)
            },
            onPortChanged: { modelWorkflow.invalidateServePreview() },
            onAppear: {
                if endpointPortText.isEmpty {
                    endpointPortText = String(suggestedPort)
                }
            }
        ))
    }


    private var workspaceRows: [ServingRow] {
        ServingWorkspacePresentation.rows(servingRows, includeAvailable: includesAvailable)
    }

    private var selectedWorkspaceRow: ServingRow? {
        guard !showsServerSetup, trainedAdapters.selectedJob == nil else { return nil }
        return workspaceRows.first { $0.id == workspaceSelection } ?? workspaceRows.first
    }

    private var workspaceDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let pending = pendingFleetAction {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                        InlineMessage(kind: .warning, text: "Fleet memory: \(pending.summary). Enable anyway?")
                        HStack {
                            Button("Cancel") { pendingFleetAction = nil }
                            Spacer()
                            Button("Enable anyway") { pending.confirm(); pendingFleetAction = nil }
                                .buttonStyle(.workbenchPrimary)
                        }
                    }.padding(WorkbenchSpacing.md).accessibilityIdentifier("serving-memory-override")
                }
                if let error = visibleActionError {
                    InlineMessage(kind: .error, text: error).lineLimit(nil).fixedSize(horizontal: false, vertical: true).padding(WorkbenchSpacing.md)
                }
                workspaceScroll
            }
            .accessibilityIdentifier("serving-model-workspace")
        }
        .sheet(isPresented: $showFleetRouter) { FleetRouterSheet(appHost: appHost) }
    }

    private var workspaceScroll: some View {
        ScrollViewReader { proxy in workspaceContent
            .onChange(of: inspectorScroll) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .top) }
                inspectorScroll = nil
            }
        }
    }

    private var workspaceContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                if let request = appHost.handoffs[.returnToUse] {
                    HStack {
                        Text("Review this server, then return to your session.").font(WorkbenchTypography.secondary)
                        Spacer()
                        Button("Return to Use") { Task { await returnToUse(request) } }.disabled(!useWorkspace.canChange)
                    }
                }
                if trainedAdapters.selectedJob != nil {
                    TrainedAdapterRunPanel(coordinator: trainedAdapters, reviewEndpoint: { preview in
                        try await endpoint.reviewTrainedAdapterEndpoint(
                            binding: preview.binding, port: preview.port,
                            loadOnRequest: preview.loadOnRequest, requireAPIKey: preview.requireAPIKey
                        )
                    }, saveAsEndpoint: { review in
                        await endpoint.addTrainedAdapterSlot(
                            binding: review.binding, port: review.port, allowUnverified: true,
                            loadOnRequest: review.loadOnRequest, requireAPIKey: review.requireAPIKey,
                            review: review
                        )
                        await modelWorkflow.refreshServers()
                        return endpoint.lastError
                    }) { await modelWorkflow.refreshServers() }
                } else if let row = selectedWorkspaceRow {
                    selectedWorkspace(row)
                } else {
                    newServerWorkspace
                }
                if !endpoint.pendingStops.isEmpty {
                    Button("Retry stopping servers") { Task { await endpoint.retryPendingStops() } }.disabled(endpoint.isChanging)
                }
            }
            .padding(WorkbenchSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("run-content-scroll")
        .id(selectedWorkspaceRow?.id ?? "serving-new-model")
    }

    private var newServerWorkspace: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack {
                Text("Serve a model").font(WorkbenchTypography.pageTitle)
                Spacer()
                if !workspaceRows.isEmpty { Button("Back to endpoints") { showsServerSetup = false } }
            }
            Picker("Model", selection: Binding(get: { selectedModel?.item.path ?? "" }, set: { path in
                guard let model = models.first(where: { $0.item.path == path }) else { return }
                appHost.selectedModelPath = path
                modelWorkflow.prepareServe(model: model)
                showsServerSetup = true
            })) {
                Text("Choose a ready model").tag("")
                ForEach(models.filter { $0.readiness == .ready && ModelTaskPresentation.supportsEndpoint($0) }, id: \.item.path) { model in
                    Text(model.displayName).tag(model.item.path)
                }
            }.accessibilityIdentifier("serving-model-picker")
            if selectedModel != nil {
                serveSection(presentation)
            } else {
                Text("Choose a model from Library to configure its API and serving settings.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                Button("Open Library") { onRouteSelection(.library) }
            }
        }
    }

    private func selectedWorkspace(_ row: ServingRow) -> some View {
        var slot: EndpointSlot?
        if case .endpoint(let value, _, _) = row { slot = value }
        let server = ServingWorkspacePresentation.server(row)
        let context = slot.map { slot in
            ServingInferenceContext.resolve(model: RunModels.model(for: slot.modelPath, in: models),
                override: server?.runtime ?? "auto", profile: slot.servingProfile, chip: appHost.hardwareProfile.chip)
        } ?? ServingInferenceContext(runtime: server?.runtime ?? "auto", chip: appHost.hardwareProfile.chip)
        return ServingInspector(
            sections: ServingInspectorPresentation.sections(for: slot?.role, typedTasks: server?.runtime == "tasks"),
            endpoint: endpoint, slot: slot, context: context,
            onManageProfile: { profile in
                guard let slot, let model = models.first(where: { $0.item.path == slot.modelPath || $0.outputPaths.contains(slot.modelPath) }),
                      model.readiness == .ready else { return }
                appHost.selectedModelPath = model.item.path
                modelWorkflow.prepareServe(model: model)
                modelWorkflow.selectServingProfile(profile)
                inferenceOptions = slot.inferenceOptions
                revealInferenceRevision = UUID()
            }
        ) { section in
            switch section {
            case .status: statusSection(row)
            case .load: loadSection(row)
            case .inference, .acceleration: unmanagedInferenceSection(row, section)
            case .access: accessSection(row)
            case .tasks: tasksSection(row)
            }
        }
        .id(row.id)
    }

    private func statusSection(_ row: ServingRow) -> some View {
        let server = ServingWorkspacePresentation.server(row)
        let name = ServingWorkspacePresentation.name(row, models: models)
        var role = ServingWorkspacePresentation.provider(row)
        var port = server?.port
        if case .endpoint(let slot, _, _) = row { role = slot.role?.title ?? "Unassigned"; port = slot.port }
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            LabeledContent("Model") { Text(name).textSelection(.enabled) }
            LabeledContent("Role", value: role)
            if let port { LabeledContent("Port", value: ":\(port)") }
            LabeledContent("State") { ServingStatusLabel(row: row, states: endpoint.slotStates) }
            if let server, server.jit == true {
                LabeledContent("Model state", value: (server.modelState ?? "unknown").capitalized)
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        servingObservabilityBadges(row, server: server)
                        if let reason = ServingWorkspacePresentation.attentionReason(row) {
                            Label {
                                Text(reason + " " + ServingWorkspacePresentation.attentionNextStep).textSelection(.enabled)
                            } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(WorkbenchColor.failure) }
                            .font(WorkbenchTypography.secondary)
                            .accessibilityIdentifier("serving-attention-reason")
                        }
                    }
                    Spacer()
                    if case .endpoint(let slot, _, let service) = row {
                        Button(slot.enabled ? "Stop server" : "Start server…") {
                            if slot.enabled { Task { if let error = await changes.stop(slot) { actionError = error } } }
                            else { prepare(slot: slot, remove: false) }
                        }.buttonStyle(.workbenchPrimary).disabled(slot.enabled ? !changes.mayStop(slot) : (endpoint.isChanging || !comparison.hasLoadedHistory))
                            .accessibilityIdentifier("serving-toggle-server")
                        if slot.usesJIT, slot.enabled, let service, service.canUnload {
                            Button("Unload model…") { Task { await inventory.prepare(.unload, service: service) } }
                                .disabled(inventory.isChanging || !inventory.mayChange(service))
                                .accessibilityIdentifier("serving-unload-model")
                        }
                        slotMenu(slot, server: server, service: service, name: name)
                    } else if let service = ServingWorkspacePresentation.service(row), service.canStop {
                        Button("Stop server…") { Task { await inventory.prepare(.stop, service: service) } }
                            .disabled(!inventory.mayChange(service) || inventory.isChanging)
                    }
                }
                if let server { HStack(spacing: WorkbenchSpacing.sm) { promptButtons(server, name: name) } }
            }
            ServingSiblingEndpoints(row: row, rows: workspaceRows) { workspaceSelection = $0 }
            statusConnection(row)
        }
    }

    @ViewBuilder
    private func statusConnection(_ row: ServingRow) -> some View {
        let server = ServingWorkspacePresentation.server(row)
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                if let url = ServingWorkspacePresentation.baseURL(row) {
                    ServingConnectionField(title: "Base URL", value: url, identifier: "serving-copy-base-url", compact: true)
                }
                ServingConnectionField(title: "Model ID", value: ServingWorkspacePresentation.modelID(row), identifier: "serving-copy-model-id", compact: true)
            }
            if let server {
                Text(server.runtime == "tasks" ? "Typed task API · /v1/tasks" : server.jit == true ? "OpenAI Chat Completions · Responses · Anthropic Messages" : "OpenAI Chat Completions")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            if let quickTarget = quickConnectTarget(for: row) {
                QuickConnectStrip(target: quickTarget, frontDoorTarget: quickConnectFrontDoorTarget(for: row))
            }
            if let server, server.runtime == "splash" {
                if let effective = server.splashEffectiveContextTokens {
                    LabeledContent("Effective context", value: "\(effective.formatted()) tokens")
                } else {
                    LabeledContent("Effective context", value: "Not reported")
                }
                if let configured = server.splashConfiguredContextTokens {
                    LabeledContent("Configured context", value: "\(configured.formatted()) tokens")
                }
                if case .endpoint(let slot, _, _) = row,
                   let presetName = slot.splashPresetName,
                   let preset = splashPresets.first(where: { $0.name == presetName }) {
                    if let cachedStates = preset.tuning.cachedStates {
                        LabeledContent("Cached states", value: cachedStates)
                    }
                    if preset.tuning.persistentCache == true {
                        LabeledContent("Persistent SSD cache", value: "Enabled")
                    }
                    if let maxDiskGB = preset.tuning.maxCacheDiskGB {
                        LabeledContent("SSD cache quota", value: maxDiskGB == 0 ? "Off" : "\(maxDiskGB.formatted()) GB")
                    }
                    if let wait = preset.executionWaitSeconds, wait > 0 {
                        LabeledContent("Execution wait", value: "\(wait) s")
                    }
                }
                if server.modelState == "failed" {
                    InlineMessage(kind: .error, text: "Splash failed to load. Review the server log for details.")
                    if case .endpoint(let slot, _, _) = row, slot.splashPresetName != nil {
                        Button("Review Splash launch…") { splashPresetSlot = slot }
                            .disabled(endpoint.pendingStops[slot.id] != nil)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func accessSection(_ row: ServingRow) -> some View {
        let server = ServingWorkspacePresentation.server(row)
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            if case .endpoint(let slot, _, _) = row {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                        LabeledContent("Address", value: "127.0.0.1 · loopback only")
                        LabeledContent("Port") {
                            TextField("Port", text: $connectionPort).multilineTextAlignment(.trailing).accessibilityIdentifier("serving-endpoint-port")
                            Button("Change…") { reviewConnectionPort(slot) }
                                .disabled(slot.enabled || endpoint.isChanging || server?.state == "running" || Int(connectionPort) == slot.port)
                        }
                        .help(ServingInspectorPresentation.caption(.port))
                        Toggle("Protected by Workbench key", isOn: Binding(get: { slot.apiKeySHA256 != nil }, set: { value in
                            if value != (slot.apiKeySHA256 != nil) { prepareAuthentication(slot, required: value) }
                        })).toggleStyle(.checkbox).disabled(slot.enabled || endpoint.isChanging)
                            .accessibilityIdentifier("serving-require-api-key")
                            .help(ServingInspectorPresentation.caption(.requireKey))
                        if let hash = slot.apiKeySHA256 {
                            HStack {
                                Button("Copy API key") {
                                    do { ServedModelsSelection.copyCredential(try EndpointCredentialStore.token(for: hash)) }
                                    catch { actionError = AppHost.render(error) }
                                }.accessibilityIdentifier("serving-copy-api-key")
                                if hash == endpoint.fleet.frontDoor?.apiKeySHA256 {
                                    Button("Reset Workbench key…") { prepareWorkbenchKeyReset() }.disabled(endpoint.isChanging)
                                        .accessibilityIdentifier("serving-reset-workbench-key")
                                }
                            }
                        }
                        if let door = endpoint.fleet.frontDoor {
                            if slot.apiKeySHA256 == door.apiKeySHA256 {
                                Text("Uses the Workbench key · routed at 127.0.0.1:\(String(door.port)) while the Workbench API runs.")
                                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                            } else if slot.apiKeySHA256 != nil {
                                Button("Use Workbench key…") { prepareAuthentication(slot, required: true) }
                                    .disabled(slot.enabled || endpoint.isChanging)
                                    .accessibilityIdentifier("serving-use-front-door-key")
                            }
                        }
                        if slot.enabled {
                            Text("Stop the server to change its port or authentication. Existing settings remain visible here.")
                                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                        }
                }
            } else if let server {
                LabeledContent("Authentication", value: server.apiKeySHA256 == nil ? "No API key required" : "API key required")
                if let port = server.port { LabeledContent("Port", value: String(port)) }
            }
            if let server, server.jit == true, UseChatClient.supports(server) {
                if let address = tailnet.sharedAddress(port: server.port) {
                    ServingConnectionField(title: "Tailscale URL", value: address, identifier: "serving-copy-tailnet-url", compact: true)
                }
                Button("Share via Tailscale…") { tailnetServer = server }
                    .accessibilityIdentifier("serving-share-tailnet")
            }
            if let server, WireEndpoint(server: server) != nil {
                ServingClientSetup(appHost: appHost, server: server, onRouteSelection: onRouteSelection)
                    .id("clients-\(server.id)")
            } else {
                Text(server?.runtime == "tasks" ? "This model uses the typed task API. Copy its API address and run a task from Tasks." : "Start this endpoint to connect an app.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                if let url = ServingWorkspacePresentation.baseURL(row) { ServingConnectionField(title: "Base URL", value: url) }
            }
        }.onAppear(perform: synchronizeConnectionPort)
    }

    private func quickConnectTarget(for row: ServingRow) -> QuickConnectTarget? {
        let server = ServingWorkspacePresentation.server(row)
        if let server, let target = QuickConnectTarget.direct(server: server, baseURL: ServingWorkspacePresentation.baseURL(row)) {
            return target
        }
        if case .endpoint(let slot, _, _) = row {
            return QuickConnectTarget.direct(slot: slot, server: server)
        }
        if let baseURL = ServingWorkspacePresentation.baseURL(row) {
            let modelID = ServingWorkspacePresentation.modelID(row)
            guard !modelID.isEmpty else { return nil }
            return QuickConnectTarget(
                baseURL: baseURL,
                modelID: modelID,
                requiresAPIKey: false,
                isFrontDoor: false,
                supportsChat: true,
                statusLabel: ServingWorkspacePresentation.status(row, states: endpoint.slotStates)
            )
        }
        return nil
    }

    private func quickConnectFrontDoorTarget(for row: ServingRow) -> QuickConnectTarget? {
        guard let server = ServingWorkspacePresentation.server(row),
              let listener = frontDoor.listening,
              let target = QuickConnectTarget.frontDoor(listener, server: server),
              !frontDoor.collisions.contains(where: { $0.modelName == target.modelID }) else { return nil }
        return target
    }

    /// Inference and Acceleration for rows without a saved endpoint: launch evidence only.
    @ViewBuilder
    private func unmanagedInferenceSection(_ row: ServingRow, _ section: ServingInspectorPresentation.Section) -> some View {
        if let server = ServingWorkspacePresentation.server(row) {
            if section == .acceleration {
                ServingInferenceEvidenceView(rows: InferenceOptionEvidence.rows(prefill: server.prefillKernel, lookup: server.decodeProfile, vision: server.visionProfile))
            } else {
                ServingCaption("This server was started outside a saved endpoint. Its launch settings are owned by the process that started it.")
            }
        } else {
            ServingCaption("Inference settings are managed by \(ServingWorkspacePresentation.provider(row)).")
        }
    }

    @ViewBuilder
    private func tasksSection(_ row: ServingRow) -> some View {
        if let server = ServingWorkspacePresentation.server(row), server.runtime == "tasks",
           let model = RunModels.model(for: server.modelIdentity, in: models), let origin = try? ServedTaskOrigin(server: server) {
            TaskDestinationPanel(appHost: appHost, model: model, initialOrigin: origin)
        } else {
            ServingCaption("Start this endpoint to run a task. Generation settings belong to each task request.")
        }
    }

    @ViewBuilder
    private func loadSection(_ row: ServingRow) -> some View {
        let server = ServingWorkspacePresentation.server(row)
        LabeledContent("Runtime", value: server?.runtime ?? "Chosen when the endpoint starts")
            .help(ServingInspectorPresentation.caption(.runtime))
        if case .endpoint(let slot, _, _) = row, server?.runtime == "splash" || slot.splashPresetName != nil {
            LabeledContent("Splash preset", value: slot.splashPresetName ?? "None")
                .help(ServingInspectorPresentation.caption(.splashPreset))
            Button("Splash presets…") { splashPresetSlot = slot }.disabled(endpoint.pendingStops[slot.id] != nil)
        }
        ServingSystemHeadroom(resources: appHost.resources)
        fleetCoResidencyBudgetBar
        if case .endpoint(let slot, _, _) = row {
            Toggle("Load on request", isOn: Binding(get: { slot.usesJIT }, set: { value in
                Task { await endpoint.setSlotLoadOnRequest(id: slot.id, value) }
            })).toggleStyle(.checkbox).disabled(endpoint.isChanging)
                .help(ServingInspectorPresentation.caption(.loadOnRequest))
            if slot.usesJIT {
                memoryManagement(slot, inline: true)
            }
        }
        if let service = ServingWorkspacePresentation.service(row) {
            ServingServiceDetails(service: service, inventory: inventory)
            if service.canUnload {
                Button(ServingInventoryPresentation.unloadTitle(for: service)) { Task { await inventory.prepare(.unload, service: service) } }
                    .disabled(inventory.isChanging || !inventory.mayChange(service))
            }
        }
        Button("Model router…") { showFleetRouter = true }
        loginItemSection
    }

    private func openServerSetup() {
        showsServerSetup = true; workspaceSelection = nil
        actionError = nil
    }

    private func focusShownModel() {
        guard isRouteActive, let path = shownPath, path != revealedModelPath else { return }
        revealedModelPath = path
        if let row = workspaceRows.first(where: { HFRepoID.matches(ServingWorkspacePresentation.modelID($0), path) }) {
            workspaceSelection = row.id; showsServerSetup = false
        } else { workspaceSelection = nil; showsServerSetup = true }
    }

    private func applyRequestedRuntime() {
        guard isRouteActive, let request = appHost.handoffs[.serveWithRuntime] else { return }
        revealedModelPath = request.modelPath
        openServerSetup()
        mode = .startNow
        runtime = request.runtime
        appHost.handoffs.finish(request, as: .serveWithRuntime)
    }

    private func focusRequestedServer() {
        guard isRouteActive, let request = appHost.handoffs[.openServing] else { return }
        if let id = request.rowID {
            if !workspaceRows.contains(where: { $0.id == id }) { includesAvailable = true }
            workspaceSelection = id
        } else if workspaceSelection == nil { workspaceSelection = workspaceRows.first?.id }
        showsServerSetup = false
        appHost.handoffs.finish(request, as: .openServing)
    }

    private func synchronizeConnectionPort() {
        if let row = selectedWorkspaceRow, case .endpoint(let slot, _, _) = row { connectionPort = String(slot.port) }
    }

    private func reviewConnectionPort(_ slot: EndpointSlot) {
        guard let port = Int(connectionPort), ServingPortBounds.range.contains(port),
              !endpoint.fleet.slots.contains(where: { $0.id != slot.id && $0.port == port }) else {
            actionError = "Choose an unused endpoint port from \(ServingPortBounds.range.lowerBound) to \(ServingPortBounds.range.upperBound)."; return
        }
        portReview = ServingPortReview(slot: slot, port: port)
    }

    private func portReviewSheet(_ review: ServingPortReview) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Change endpoint port?").font(WorkbenchTypography.cardTitle)
            Text("Port \(review.slot.port) → \(review.port). Update connected apps to use the new address.")
            HStack {
                Button("Cancel") { portReview = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save port") {
                    Task {
                        guard endpoint.fleet.slots.contains(review.slot), !review.slot.enabled,
                              endpoint.pendingStops[review.slot.id] == nil,
                              !runningServers.contains(where: { $0.port == review.slot.port || $0.port == review.port }),
                              !endpoint.fleet.slots.contains(where: { $0.id != review.slot.id && $0.port == review.port }) else {
                            actionError = "Endpoint or port changed. Review the port again."; portReview = nil; return
                        }
                        await endpoint.updateSlot(id: review.slot.id, modelPath: review.slot.modelPath, port: review.port, role: review.slot.role)
                        synchronizeConnectionPort(); portReview = nil
                    }
                }.buttonStyle(.workbenchPrimary)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: WorkbenchSize.MediaReuse.reviewWidth)
    }

    private var sourceIssuesSheet: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack {
                Text("Connections").font(WorkbenchTypography.cardTitle)
                Spacer()
                Button("Refresh") { Task { await refreshServing() } }.disabled(inventory.isRefreshing)
                Button("Done") { showsSourceIssues = false }.keyboardShortcut(.cancelAction)
            }
            Text("These sources did not answer the latest refresh. Other endpoints remain available.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    ForEach(inventory.snapshot.sourceErrors.keys.sorted(), id: \.self) { source in
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                            Text(source).font(WorkbenchTypography.label).textSelection(.enabled)
                            Text(inventory.snapshot.sourceErrors[source] ?? "Unavailable").font(WorkbenchTypography.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }.padding(WorkbenchSpacing.lg).frame(minWidth: WorkbenchSize.Run.memoryPopoverWidth, idealWidth: WorkbenchSize.windowDefaultWidth / 2, minHeight: WorkbenchSize.Serving.promptMaximum * 2)
    }

    private var shownPath: String? {
        RunPresentation.shownModelPath(workflow: modelWorkflow.workflow, selectedModelPath: appHost.selectedModelPath)
    }

    private var visibleActionError: String? { actionError ?? inventory.actionError(for: .window) ?? endpoint.lastError }

    /// A sheet binding that stays empty while this route is hidden, so a retained page never presents.
    private func gated<Value>(_ binding: Binding<Value?>) -> Binding<Value?> {
        Binding(get: { isRouteActive ? binding.wrappedValue : nil }, set: { binding.wrappedValue = $0 })
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
    private func serveSection(_ presentation: RunPresentation) -> some View {
        WorkbenchSurface() {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                SectionTitle(text: "Endpoint setup")
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
                        text: selectedModel?.item.isCompanion == true
                            ? "A vision projector runs only beside its matching base model."
                            : "\(selectedModel?.item.task?.type.title ?? "This kind of") models are not served. Use them from the Library inspector."
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
        if modelWorkflow.discoveryCoverageLimited {
            Text("This engine checks Workbench servers only.").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
        }
        if !modelWorkflow.existingServers.isEmpty {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Text("This model is already serving").font(WorkbenchTypography.emphasis)
                Text("The existing endpoint keeps its own settings.").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                ForEach(Array(modelWorkflow.existingServers.enumerated()), id: \.offset) { _, server in
                    HStack {
                        Text("\(server.runtime ?? "Runtime unavailable") · port \(server.port.map(String.init) ?? "—") · Running")
                        Spacer()
                        Button("Open existing endpoint") { Task { await openExistingEndpoint(server) } }
                            .buttonStyle(.workbenchPrimary).disabled(openingExistingEndpoint)
                            .accessibilityIdentifier("open-existing-endpoint")
                    }
                }
            }.accessibilityIdentifier("existing-serving-endpoints")
        }
        inferenceSettings
        if let error = portInput.error {
            Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
        }
    }

    private func loadSplashPresets() async {
        do { splashPresets = try await appHost.api.splashPresets(); splashPresetError = nil }
        catch { splashPresetError = AppHost.render(error) }
    }

    private var selectedSplashPreset: SplashPreset? {
        splashPresets.first { $0.name == selectedSplashPresetName }
    }

    private var inferenceContext: ServingInferenceContext {
        let selectedRuntime = mode == .startNow ? runtime : ServingInferenceContext.savedEndpointOverride(model: selectedModel, presetSelected: selectedSplashPreset != nil, profile: modelWorkflow.servingProfile)
        return ServingInferenceContext.resolve(model: selectedModel, override: selectedRuntime, profile: modelWorkflow.servingProfile, chip: appHost.hardwareProfile.chip)
    }

    @ViewBuilder
    private func servingObservabilityBadges(_ row: ServingRow, server: ServerInfo?) -> some View {
        let slot: EndpointSlot? = {
            if case .endpoint(let s, _, _) = row { return s }
            return nil
        }()
        let preset = slot?.splashPresetName.flatMap { name in splashPresets.first { $0.name == name } }
        let badges: [String] = {
            var items: [String] = []
            if server?.runtime == "splash" || slot?.splashPresetName != nil {
                if let effective = server?.splashEffectiveContextTokens, let configured = server?.splashConfiguredContextTokens, effective != configured {
                    items.append("Context \(effective.formatted()) / \(configured.formatted())")
                } else if let effective = server?.splashEffectiveContextTokens {
                    items.append("Context \(effective.formatted())")
                } else if let configured = server?.splashConfiguredContextTokens ?? preset?.contextTokens {
                    items.append("Context \(configured.formatted()) configured")
                }
                if let cachedStates = preset?.tuning.cachedStates {
                    items.append("States \(cachedStates)")
                }
                if preset?.tuning.persistentCache == true {
                    if let disk = preset?.tuning.maxCacheDiskGB, disk > 0 {
                        items.append("SSD cache \(disk.formatted()) GB · persistent")
                    } else {
                        items.append("Persistent SSD cache")
                    }
                } else if let disk = preset?.tuning.maxCacheDiskGB {
                    items.append(disk == 0 ? "SSD cache off" : "SSD cache \(disk.formatted()) GB")
                }
            }
            if let mib = slot?.inferenceOptions.sharedPrefixCacheMiB {
                items.append("Prefix cache \(mib) MiB")
            }
            let wait = server?.memoryPolicy?.executionWaitSeconds ?? slot?.memoryPolicy?.executionWaitSeconds ?? preset?.executionWaitSeconds
            if let wait, wait > 0 {
                items.append("Queue wait \(wait) s")
            }
            return items
        }()
        if !badges.isEmpty {
            ReclaimFlowLayout(spacing: WorkbenchSpacing.xs, lineSpacing: WorkbenchSpacing.xs) {
                ForEach(badges, id: \.self) { badge in
                    Text(badge)
                        .font(WorkbenchTypography.metadata)
                        .foregroundStyle(WorkbenchColor.muted)
                        .padding(.horizontal, WorkbenchSpacing.xs)
                        .padding(.vertical, WorkbenchSpacing.xxxs)
                        .background(WorkbenchColor.well, in: Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private var inferenceSettings: some View {
        ServingInferenceControls(options: $inferenceOptions, context: inferenceContext, allowRequestDefaults: mode == .saveEndpoint && newSlotLoadOnRequest,
                                 showsAcceleration: mode != .saveEndpoint)
            .disabled(modelWorkflow.isServeSubmissionInFlight || profiles.activeID != nil)
        if mode == .saveEndpoint && newSlotLoadOnRequest && requireAPIKey && selectedSplashPreset == nil && modelWorkflow.servingProfile == nil && !inferenceContext.isStrata && !inferenceContext.isSplash {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                HStack(spacing: WorkbenchSpacing.sm) {
                    Toggle("Shared prefix cache (MLX-LM)", isOn: Binding(
                        get: { inferenceOptions.sharedPrefixCacheMiB != nil },
                        set: { enabled in inferenceOptions.sharedPrefixCacheMiB = enabled ? 256 : nil }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(inferenceOptions.accelerationRequested || !inferenceOptions.systemPrompt.isEmpty)
                    if let mib = inferenceOptions.sharedPrefixCacheMiB {
                        Picker("Budget", selection: Binding(
                            get: { mib },
                            set: { inferenceOptions.sharedPrefixCacheMiB = $0 }
                        )) {
                            ForEach([64, 128, 256, 512, 1024, 2048], id: \.self) { value in
                                Text("\(value) MiB").tag(value)
                            }
                            if ![64, 128, 256, 512, 1024, 2048].contains(mib) {
                                Text("\(mib) MiB").tag(mib)
                            }
                        }
                        .frame(maxWidth: 140)
                    }
                }
                Text("Reuses identical system-prompt prefixes across multi-agent requests on keyed MLX-LM endpoints (16–2048 MiB).")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
        }
        if mode == .saveEndpoint && ServingInferenceContext.supportsSavedSplashPreset(model: selectedModel, profile: modelWorkflow.servingProfile) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                HStack {
                    Picker("Splash preset", selection: $selectedSplashPresetName) {
                        Text("Default settings").tag("")
                        ForEach(splashPresets) { preset in Text(preset.name).tag(preset.name) }
                    }
                    Button("New preset…") { showingSplashEditor = true }
                }
                if let preset = selectedSplashPreset {
                    Text(preset.summary).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
                if let splashPresetError { InlineMessage(kind: .warning, text: splashPresetError) }
            }
        }
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
        if modelWorkflow.existingServers.isEmpty, let words = presentation.stateWords {
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
                Text("Text · Splash").tag("splash")
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
        guard portInput.error == nil, presentation.canPreview || !modelWorkflow.existingServers.isEmpty else { return }
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
        if !modelWorkflow.existingServers.isEmpty {
            Button("Check again", action: previewServeAction).buttonStyle(.bordered).disabled(busy || openingExistingEndpoint)
        } else if presentation.canConfirm {
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

    private func openExistingEndpoint(_ expected: ServerInfo) async {
        guard !openingExistingEndpoint else { return }
        openingExistingEndpoint = true
        defer { openingExistingEndpoint = false }
        let workflowID = modelWorkflow.workflow.id
        let modelPath = modelWorkflow.workflow.completedModelPath
        await inventory.refresh()
        guard isRouteActive, modelWorkflow.workflow.id == workflowID,
              modelWorkflow.workflow.completedModelPath == modelPath else { return }
        guard let row = ServingRows.existingEndpoint(expected, in: servingRows) else {
            actionError = "The endpoint changed or is unavailable. Refresh and try again."; return
        }
        workspaceSelection = row.id; showsServerSetup = false; actionError = nil
    }

    private func refreshServing() async {
        await modelWorkflow.refreshServers()
        await inventory.refresh(refreshHosts: true)
        await refreshAgentMemoryBudget()
    }

    private func refreshAgentMemoryBudget() async {
        agentMemoryBudget = try? await appHost.api.agentMemoryBudget()
    }

    private var fleetBudgetSummary: FleetFitAdvisor.BudgetSummary? {
        let enabledSlots = endpoint.fleet.slots.filter { $0.enabled && !$0.modelPath.isEmpty }
        guard !enabledSlots.isEmpty, let memory = appHost.resources.memory else { return nil }
        let estimates = enabledSlots.map { slot -> FleetFitAdvisor.Estimate in
            let model = RunModels.model(for: slot.modelPath, in: models)
            let server = modelWorkflow.servers.first(where: { $0.port == slot.port })
            let modality = FleetFitAdvisor.modality(for: model, server: server, role: slot.role)
            let residency: FleetFitAdvisor.Residency
            if let presetName = slot.splashPresetName,
               let cap = splashPresets.first(where: { $0.name == presetName })?.memoryGB,
               cap > 0 {
                residency = .splashCapped(maxMemoryGB: cap)
            } else if slot.usesJIT {
                let state = server?.modelState?.lowercased()
                residency = (state == "unloaded" || state == "idle" || server == nil) ? .jitUnloaded : .resident
            } else {
                residency = .resident
            }
            let modelBytes: Int64? = (model?.item.bytes ?? 0) > 0 ? model?.item.bytes : nil
            let contextTokens = slot.memoryPolicy?.contextTokens ?? appHost.resources.contextTokens
            return FleetFitAdvisor.Estimate.slot(
                modelBytes: modelBytes,
                contextTokens: contextTokens,
                parameters: model?.item.parameters,
                modality: modality,
                residency: residency
            )
        }
        return FleetFitAdvisor.assess(
            estimates: estimates,
            availableBytes: memory.availableBytes,
            reserveBytes: Int64(max(0, appHost.config.fitReserveGB) * 1e9),
            agentBudget: agentMemoryBudget
        )
    }

    @ViewBuilder
    private var fleetCoResidencyBudgetBar: some View {
        if let summary = fleetBudgetSummary {
            let tint: Color = {
                switch summary.verdict {
                case .fits: return WorkbenchColor.success
                case .tight: return WorkbenchColor.warning
                case .wontFit: return WorkbenchColor.failure
                case .unknown: return WorkbenchColor.muted
                }
            }()
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                HStack {
                    Text("Fleet co-residency budget")
                        .font(WorkbenchTypography.label)
                    Spacer()
                    Text("\(summary.totalSlotCount)/\(EndpointFleetConfig.maxSlots) slots")
                        .font(WorkbenchTypography.metadata)
                        .foregroundStyle(WorkbenchColor.muted)
                }
                ProgressView(value: min(1.0, max(0.0, summary.utilizationFraction)))
                    .tint(tint)
                Text(summary.summaryText)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(summary.isPartial ? WorkbenchColor.warning : WorkbenchColor.muted)
                if !summary.modalityBreakdown.isEmpty {
                    let breakdown = FleetFitAdvisor.Modality.allCases.compactMap { modality -> String? in
                        guard let bytes = summary.modalityBreakdown[modality], bytes > 0 else { return nil }
                        return String(format: "%@ %.1f GB", modality.title, Double(bytes) / 1e9)
                    }
                    if !breakdown.isEmpty {
                        Text(breakdown.joined(separator: " · "))
                            .font(WorkbenchTypography.metadata)
                            .foregroundStyle(WorkbenchColor.muted)
                    }
                }
                if let admission = summary.agentAdmissionBytes, let accounted = summary.agentAccountedBytes {
                    Text(String(format: "Shared agent budget: %.1f GB accounted / %.1f GB admission",
                                Double(accounted) / 1e9, Double(admission) / 1e9))
                        .font(WorkbenchTypography.metadata)
                        .foregroundStyle(summary.agentWithinBudget == false ? WorkbenchColor.failure : WorkbenchColor.muted)
                }
            }
            .padding(WorkbenchSpacing.sm)
            .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
            .accessibilityIdentifier("serving-coresidency-budget-bar")
        }
    }

    private func refreshDiscovery() async {
        if appHost.liveServicesStarted { await inventory.refresh(refreshHosts: true) }
    }

    @ViewBuilder
    private func useButton(_ server: ServerInfo) -> some View {
        if let model = models.first(where: { $0.readiness == .ready && UseChatClient.matches(server, modelPath: $0.item.path) }),
           !UseMode.modes(for: model).isEmpty {
            Button("Use…") {
                appHost.handoffs.send(UseModelRequest(modelPath: model.item.path, server: server), as: .useModel)
                onRouteSelection(.use)
            }.buttonStyle(.bordered).controlSize(.small)
                .disabled(modelWorkflow.serversError != nil)
                .accessibilityIdentifier("run-use-model-\(server.port ?? 0)")
        }
    }

    @ViewBuilder
    private func taskButton(_ server: ServerInfo) -> some View {
        if (try? ServedTaskOrigin(server: server)) != nil,
           models.contains(where: { $0.readiness == .ready && Quarantine.resolve($0.item.path) == Quarantine.resolve(server.path!) }) {
            Button("Run a task…") { inspectorScroll = .tasks }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(modelWorkflow.serversError != nil)
                .accessibilityIdentifier("run-model-task-\(server.port ?? 0)")
        }
    }

    private func returnToUse(_ request: UseServerReviewRequest) async {
        do {
            if useWorkspace.selected?.id != request.sessionID { try await useWorkspace.select(id: request.sessionID) }
            let candidates = modelWorkflow.servers.filter { server in
                guard UseChatClient.matches(server, modelPath: request.modelPath) else { return false }
                return useWorkspace.selected?.mode == .tasks ? (try? ServedTaskOrigin(server: server)) != nil : UseChatClient.supports(server)
            }
            if candidates.count == 1, let current = candidates.first { try await useWorkspace.setEndpoint(current) }
            appHost.handoffs.finish(request, as: .returnToUse)
            onRouteSelection(.use)
        } catch { useWorkspace.showError(error); onRouteSelection(.use) }
    }

    private func revealModel(_ path: String) {
        appHost.selectedModelPath = path
        appHost.handoffs.send(LibraryRevealRequest(modelPath: path), as: .revealModel)
        onRouteSelection(.library)
    }

    @ViewBuilder
    private func promptButtons(_ server: ServerInfo, name: String) -> some View {
        useButton(server)
        taskButton(server)
        if EndpointTestCoordinator.supports(server) {
        Button("Try a prompt…") { promptPresentation = endpointTest.open(server) }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(!EndpointTestCoordinator.supports(server) || modelWorkflow.serversError != nil
                      || appHost.occupancy.blocksStop(server) || endpointTest.isSending || endpointTest.presentationID != nil)
            .accessibilityIdentifier("run-try-prompt-\(server.port ?? 0)")
            .accessibilityLabel("Try a prompt with \(name) on port \(String(server.port ?? 0))")
            .help("Send one prompt to this endpoint. Load-on-request endpoints may load the model.")
        }
        if let request = ClientWiringRequest.forServer(server) {
            Button("Configure clients…") {
                guard modelWorkflow.serversError == nil else { return }
                appHost.handoffs.send(request, as: .wireClient)
                inspectorScroll = .access
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(modelWorkflow.serversError != nil)
            .accessibilityIdentifier("run-configure-clients-\(server.port ?? 0)")
            .accessibilityLabel("Configure clients for \(name) on port \(server.port ?? 0)")
            .help("Select this endpoint in Clients. Preview and confirm before changing client configuration.")
        }
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
            Toggle("Load on request", isOn: Binding(
                get: { slot.usesJIT },
                set: { value in Task { await endpoint.setSlotLoadOnRequest(id: slot.id, value) } }))
                .help("Keep the endpoint reachable without resident weights. Changing load mode restarts this endpoint.")
                .disabled(endpoint.isUnloading)
            if slot.usesJIT {
                Button("Memory management…") { inspectorScroll = .load }
            }
            if server?.runtime == "splash" || slot.splashPresetName != nil {
                Button("Splash presets…") { splashPresetSlot = slot }
                    .disabled(endpoint.pendingStops[slot.id] != nil)
            }
            Button("Inference settings…") { inspectorScroll = .inference }
                .disabled(endpoint.pendingStops[slot.id] != nil)
                .help("Review inference settings. Stop the endpoint before changing them.")
            if let connection { Button("Copy model ID") { ServedModelsSelection.copy(connection.modelName) } }
            else if slot.apiKeySHA256 != nil, let server {
                Button("Copy model ID") { ServedModelsSelection.copy(server.modelIdentity) }
            }
            if let hash = slot.apiKeySHA256 {
                Button("Copy API key") {
                    do { ServedModelsSelection.copyCredential(try EndpointCredentialStore.token(for: hash)) }
                    catch { actionError = AppHost.render(error) }
                }
                if hash == endpoint.fleet.frontDoor?.apiKeySHA256 {
                    Button("Reset Workbench key…") { prepareWorkbenchKeyReset() }
                        .disabled(endpoint.isChanging)
                }
            }
            Button(slot.apiKeySHA256 == nil ? "Protect with Workbench key…" : "Disable authentication…") {
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

    private func memoryPopoverBinding(_ slot: EndpointSlot) -> Binding<Bool> {
        Binding(
            get: { expandedMemorySlots.contains(slot.id) },
            set: { value in
                if value { expandedMemorySlots.insert(slot.id) } else { expandedMemorySlots.remove(slot.id) }
            }
        )
    }

    @ViewBuilder
    func memoryManagement(_ slot: EndpointSlot, expanded: Binding<Bool>? = nil, inline: Bool = false) -> some View {
        if inline { memoryFields(slot) }
        else {
            DisclosureGroup("Memory management", isExpanded: expanded ?? memoryPopoverBinding(slot)) { memoryFields(slot) }
                .font(WorkbenchTypography.secondary)
        }
    }

    private func memoryFields(_ slot: EndpointSlot) -> some View {
        let policy = slot.memoryPolicy ?? endpoint.slotMemoryPolicies[slot.id] ?? .legacy
        return
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                if slot.splashPresetName != nil {
                    Text("Memory settings come from the selected Splash preset. Review another preset to change them.")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
                HStack {
                    Picker("Unload when idle", selection: memoryBinding(slot, \.idleTimeoutSeconds)) {
                        Text("Never").tag(0)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                        Text("5 minutes").tag(300)
                        Text("10 minutes").tag(600)
                        Text("30 minutes").tag(1800)
                        Text("1 hour").tag(3600)
                        if ![0, 60, 120, 300, 600, 1800, 3600].contains(policy.idleTimeoutSeconds) {
                            Text(verbatim: "\(policy.idleTimeoutSeconds) seconds").tag(policy.idleTimeoutSeconds)
                        }
                    }
                    .frame(maxWidth: WorkbenchSize.Run.idlePickerMaximum)
                    .disabled(policy.keepLoaded || policy.releaseAfterRequest == true)
                    .help(ServingInspectorPresentation.caption(.idleUnload))
                    Toggle("Keep loaded after use", isOn: memoryBinding(slot, \.keepLoaded))
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .help(ServingInspectorPresentation.caption(.keepLoaded))
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
                    .fixedSize()
                    .accessibilityIdentifier("endpoint-memory-release-after-request")
                    .help(ServingInspectorPresentation.caption(.releaseAfterRequest))
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
                .help(ServingInspectorPresentation.caption(.memoryPolicy) + " Uses estimated weights + runtime allowance + reserve; other processes and larger contexts can change actual use. Unknown headroom blocks loading.")
                HStack {
                    Picker("Execution wait", selection: Binding(
                        get: { policy.executionWaitSeconds ?? 0 },
                        set: { value in
                            var updated = policy
                            updated.executionWaitSeconds = value == 0 ? nil : value
                            Task { await endpoint.setSlotMemoryPolicy(id: slot.id, updated) }
                        })) {
                        Text("Off (0 s)").tag(0)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                        Text("5 minutes").tag(300)
                        Text("10 minutes").tag(600)
                        Text("30 minutes").tag(1800)
                        Text("1 hour").tag(3600)
                        if let current = policy.executionWaitSeconds, ![0, 30, 60, 120, 300, 600, 1800, 3600].contains(current) {
                            Text(verbatim: "\(current) seconds").tag(current)
                        }
                    }
                    .frame(maxWidth: WorkbenchSize.Run.idlePickerMaximum)
                    .help("Wait up to this many seconds for host compute before rejecting a queued request (0–3600 s).")
                }
                Button("Review memory policy…") { memoryReviewSlot = slot }
                    .accessibilityIdentifier("endpoint-memory-review")
            }
            .padding(.top, WorkbenchSpacing.sm)
            .controlSize(.small)
            .disabled(endpoint.isUnloading || slot.splashPresetName != nil)
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

    @ViewBuilder
    private func addEndpointForm(_ presentation: RunPresentation) -> some View {
        if endpoint.fleet.slots.count >= EndpointFleetConfig.maxSlots {
            designedState(symbol: "square.stack.3d.up.slash", text: "Endpoint cap reached (\(EndpointFleetConfig.maxSlots)). Remove one to add another.")
        } else {
            let unverified = selectedModel.map { !appHost.isModelVerified($0.item.path) } ?? false
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: WorkbenchSpacing.lg) {
                    addEndpointLoadColumn.frame(width: 320, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) { inferenceSettings }
                        .frame(minWidth: 420, maxWidth: 620, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    addEndpointLoadColumn
                    inferenceSettings
                }
            }
            if unverified {
                InlineMessage(kind: .warning, text: "This model has not passed verification. Confirm only if you intend to serve it unverified.")
            }
            HStack(spacing: WorkbenchSpacing.xs) {
                Spacer(minLength: WorkbenchSpacing.xs)
                Button(unverified ? "Add unverified endpoint…" : "Add endpoint…") { prepareAddEndpoint() }
                    .buttonStyle(.workbenchPrimary)
                    .disabled(!presentation.canAddEndpoint || endpoint.isChanging || !comparison.hasLoadedHistory || inferenceOptions.validationError != nil || (modelWorkflow.servingProfile.map { !$0.hasPassedVerification } ?? false))
                    .help(presentation.addEndpointBlockedReason ?? "Review and add the model shown above as a saved endpoint.")
            }
        }
    }

    /// Load and server settings for a new endpoint, then the runtime's experimental features.
    private var addEndpointLoadColumn: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            addEndpointLoadCard
            ServingExperimentalCard(options: $inferenceOptions, context: inferenceContext)
                .disabled(modelWorkflow.isServeSubmissionInFlight || profiles.activeID != nil)
        }
    }

    private var addEndpointLoadCard: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Label("Load", systemImage: "memorychip").font(WorkbenchTypography.cardTitle)
            addEndpointPortAndRole
            if let endpointPortError {
                Text(endpointPortError).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
            }
            addEndpointLoadToggle
            if newSlotLoadOnRequest {
                Text("After each request").font(WorkbenchTypography.label)
                Picker("After each request", selection: $keepModelLoaded) {
                    Text("Release weights").tag(false)
                    Text("Keep loaded").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityIdentifier("serve-model-residency")
                .help("Release weights after each request, or keep them loaded between requests.")
            }
            Toggle("Require API key", isOn: $requireAPIKey)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("serve-model-authentication")
                .help("Only clients with this key can use inference. The endpoint stays on loopback; the key is saved in Keychain when you confirm.")
        }
        .padding(WorkbenchSpacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
    }

    @ViewBuilder
    private var addEndpointPortAndRole: some View {
        LabeledContent("Port") {
            TextField("Port", text: $endpointPortText)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: WorkbenchSize.Run.portField)
        }
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
        switch changes.reviewAdd(model: selectedModel, portText: endpointPortText, suggestedPort: suggestedPort, role: nil,
                                 loadOnRequest: newSlotLoadOnRequest, keepLoaded: keepModelLoaded, requireKey: requireAPIKey, inference: inferenceOptions, profile: modelWorkflow.servingProfile, splashPreset: inferenceContext.isSplash ? selectedSplashPreset : nil) {
        case .noModel, .chooseRole: return
        case .portRejected(let message): endpointPortError = message
        case .review(let review): endpointPortError = nil; action = review
        }
    }

    /// Reviews a new endpoint for a role on that role's canonical port.
    private func chooseModel(for role: ServingRole, _ model: LibraryModel) {
        switch changes.reviewAdd(model: model, portText: "", suggestedPort: endpoint.fleet.port(for: role), role: role,
                                 loadOnRequest: true, keepLoaded: false, requireKey: false) {
        case .noModel, .chooseRole: return
        case .portRejected(let message): actionError = message
        case .review(let review): actionError = nil; action = review
        }
    }

    private func changeModel(of slot: EndpointSlot, to model: LibraryModel) {
        actionError = nil
        action = changes.reviewSwap(slot: slot, to: model)
    }

    private func toggleEndpoint(_ slot: EndpointSlot) {
        if slot.enabled { Task { actionError = await changes.stop(slot) } }
        else { prepare(slot: slot, remove: false) }
    }

    private func prepare(slot: EndpointSlot, remove: Bool) {
        action = changes.review(slot: slot, remove: remove)
    }

    private func confirmation(_ pending: EndpointChangeReview) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text(pending.remove ? "Remove endpoint?" : pending.slot == nil ? "Add this endpoint?" : pending.swapTo != nil ? "Change this endpoint's model?" : "Start this endpoint?")
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
            if !pending.remove, let name = pending.slot?.splashPresetName {
                Text("Splash preset: \(name)").font(WorkbenchTypography.secondary)
            }
            if !pending.remove, pending.slot == nil {
                Text(pending.inference.summary).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                if let profile = pending.profile { Text("Profile: \(profile.name) · \(profile.options.decodingTitle)").font(WorkbenchTypography.secondary) }
                if let preset = pending.splashPreset { Text("Splash preset: \(preset.name) · \(preset.summary)").font(WorkbenchTypography.secondary) }
            }
            if pending.unverified { InlineMessage(kind: .warning, text: "This model has not passed verification. Confirm only if you intend to serve it unverified.") }
            if let warning = pending.memoryWarning { InlineMessage(kind: .warning, text: warning) }
            HStack {
                Button("Cancel") { action = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(pending.remove ? "Remove endpoint" : pending.swapTo != nil ? (pending.unverified ? "Change to unverified model" : "Change model") : pending.slot != nil ? "Start endpoint" : pending.unverified ? "Add unverified endpoint" : "Add endpoint") {
                    Task { await apply(pending) }
                }.buttonStyle(.workbenchPrimary).disabled(endpoint.isChanging)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 460)
    }

    /// Rechecks the reviewed change against current state, then performs it.
    private func apply(_ pending: EndpointChangeReview, overrideMemory: Bool = false) async {
        action = nil; actionError = nil
        switch await changes.confirm(pending, overrideMemory: overrideMemory) {
        case .completed:
            break
        case .memoryHold(let summary):
            fleetHold.hold(summary) { Task { await apply(pending, overrideMemory: true) } }
        case .refused(let message):
            actionError = message
        }
    }

    private func prepareAuthentication(_ slot: EndpointSlot, required: Bool) {
        if required, endpoint.fleet.frontDoor == nil { showsKeyWizard = true; return }
        Task {
            do { authenticationReview = try await endpoint.previewAuthentication(slot: slot, required: required) }
            catch { actionError = AppHost.render(error) }
        }
    }

    private func prepareWorkbenchKeyReset() {
        Task {
            do { keyResetReview = try await endpoint.resetWorkbenchKeyPreview() }
            catch { actionError = AppHost.render(error) }
        }
    }

    private func keyResetConfirmation(_ review: WorkbenchKeyResetReview) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Reset the Workbench key?").font(WorkbenchTypography.cardTitle)
            Text("These restart in order, then the previous key stops working:")
            ForEach(review.endpoints, id: \.slot.id) { entry in
                Text("Endpoint 127.0.0.1:\(entry.slot.port)\(entry.slot.enabled ? " (running)" : " (stopped)")").textSelection(.enabled)
            }
            Text("Workbench API 127.0.0.1:\(review.workbenchAPIPort)").textSelection(.enabled)
            Text("Copy the new key after saving and update each client. If a restart fails, the previous key stays in Keychain.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            HStack {
                Button("Cancel") { keyResetReview = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Reset key") {
                    Task {
                        let done = await endpoint.confirmWorkbenchKeyReset(review)
                        if done { keyResetReview = nil }
                        actionError = endpoint.lastError
                    }
                }.buttonStyle(.workbenchPrimary).disabled(endpoint.isChanging)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 460)
    }

    private func authenticationConfirmation(_ review: EndpointAuthenticationReview) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text(review.keySHA256 == nil ? "Disable API key authentication?" : "Protect with the Workbench key?")
                .font(WorkbenchTypography.cardTitle)
            Text("Endpoint: 127.0.0.1:\(review.slot.port)").textSelection(.enabled)
            Text(review.keySHA256 == nil ? "Any local client will be able to use this endpoint after you start it."
                 : "Clients holding the Workbench key can use this endpoint directly or through the Workbench API. Previous keys for this endpoint stop working.")
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
                Button("Install login item…") { loginPlans = []; loginPlist = ""; loginFitOverride = false; showLoginItemPreview = true }
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
            Text("One LaunchAgent per enabled endpoint starts that endpoint once at login (RunAtLoad). The preview lists every command. The app keeps reconciling while it runs; mlx-agent receipts remain the process authority.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            if loginBusy { ProgressView("Reviewing endpoint startup…") }
            if let refusal = loginFitRefusal {
                InlineMessage(kind: .warning, text: "Fleet memory: \(refusal). Install anyway?")
            }
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
                if loginFitRefusal != nil {
                    Button("Install anyway") { installLoginItem(fitOverride: true) }
                        .disabled(loginBusy || loginPlans.isEmpty)
                }
                Button("Confirm install") { installLoginItem() }
                    .buttonStyle(.workbenchPrimary)
                    .disabled(loginBusy || loginPlans.isEmpty || loginFitRefusal != nil)
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

    private var loginFitRefusal: String? {
        LoginFleetInstall.refusal(verdict: appHost.loginFleetVerdict(), overridden: loginFitOverride)
    }

    private func loginPlansAreCurrent(_ plans: [LoginItemPlan]) -> Bool {
        let slots = endpoint.fleet.slots.filter(\.enabled)
        guard plans.count == slots.count, !plans.isEmpty else { return false }
        return zip(plans, slots).allSatisfy { plan, slot in
            plan.slot == slot && plan.agentPath == agentRootPath && plan.fleetURL == endpoint.fleetFileURL
        }
    }

    private func prepareLoginItem() async {
        loginBusy = true; loginItemMessage = nil; loginFitOverride = false
        defer { loginBusy = false }
        do {
            let slots = endpoint.fleet.slots.filter(\.enabled)
            guard !slots.isEmpty else { throw WorkflowEvidenceError.invalid("Enable an endpoint before installing its login item.") }
            var plans: [LoginItemPlan] = []
            var texts: [String] = []
            for slot in slots {
                let plan = try await appHost.api.loginItemPlan(slot: slot, fleetURL: endpoint.fleetFileURL)
                let plist = try await WorkbenchIO.perform { Result { try LaunchAgentManager().plistPreview(plan: plan) } }.get()
                let name = URL(fileURLWithPath: slot.modelPath).lastPathComponent
                plans.append(plan)
                texts.append("Endpoint \(slot.port) · \(name)\n\(plist)")
            }
            try Task.checkCancellation()
            guard loginPlansAreCurrent(plans) else {
                throw WorkflowEvidenceError.invalid("Endpoint settings changed. Open the login preview again.")
            }
            loginPlans = plans; loginPlist = texts.joined(separator: "\n\n")
        } catch { loginItemMessageIsError = true; loginItemMessage = AppHost.render(error) }
    }

    private func installLoginItem(fitOverride: Bool = false) {
        let plans = loginPlans
        guard loginPlansAreCurrent(plans) else {
            loginPlans = []; loginItemMessageIsError = true
            loginItemMessage = "Endpoint settings changed. Open the login preview again."; return
        }
        if fitOverride { loginFitOverride = true }
        if let refusal = LoginFleetInstall.refusal(verdict: appHost.loginFleetVerdict(), overridden: fitOverride || loginFitOverride) {
            loginItemMessageIsError = true
            loginItemMessage = "Fleet memory: \(refusal). Install anyway?"
            return
        }
        loginBusy = true
        Task {
            let result = await WorkbenchIO.perform { Result { try LaunchAgentManager().install(plans: plans) } }
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
    let role: ServingRole?
    let loadOnRequest: Bool
    let keepLoaded: Bool
    let requireKey: Bool
    let memoryWarning: String?
    let unverified: Bool
    let remove: Bool
    var inference = LocalInferenceOptions()
    var profile: ServingProfile? = nil
    var splashPreset: SplashPreset? = nil
    /// Set for a model change on `slot`: confirmation swaps the slot to this model on its port.
    var swapTo: LibraryModel? = nil
}

/// Reviews endpoint changes and rechecks them against current state when confirmed.
@MainActor
struct EndpointChanges {
    let appHost: AppHost

    enum AddOutcome {
        case review(EndpointChangeReview)
        case portRejected(String)
        case noModel
        /// The model has no endpoint yet; the caller picks one of the chat roles.
        case chooseRole(LibraryModel)
    }

    enum Confirmation: Equatable {
        case completed
        case memoryHold(String)
        case refused(String)
    }

    private var models: [LibraryModel] { appHost.librarySnapshot?.models ?? [] }

    /// Workbench's servers plus the local servers other tools run, whose ports a new endpoint must not take.
    var occupiedServers: [ServerInfo] {
        appHost.modelWorkflow.servers + appHost.servingInventory.snapshot.services.compactMap(\.server)
    }

    func reviewAdd(model: LibraryModel?, portText: String, suggestedPort: Int, role: ServingRole?, loadOnRequest: Bool,
                   keepLoaded: Bool, requireKey: Bool, inference: LocalInferenceOptions = .init(), profile: ServingProfile? = nil, splashPreset: SplashPreset? = nil) -> AddOutcome {
        guard let model else { return .noModel }
        if let error = inference.validationError { return .portRejected(error) }
        if splashPreset != nil && (!loadOnRequest || profile != nil) { return .portRejected("Splash presets require a load-on-request endpoint.") }
        if inference.sharedPrefixCacheRequested && !ServeLaunch.sharedPrefixCacheIsLegal(runtime: "mlx_lm", jit: loadOnRequest, hasAPIKey: requireKey, hasSplashPreset: splashPreset != nil, hasServingProfile: profile != nil, options: inference) {
            return .portRejected("Shared prefix cache requires a keyed MLX-LM load-on-request endpoint with a 16–2048 MiB budget and no incompatible options.")
        }
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
            unverified: !appHost.isModelVerified(model.item.path), remove: false, inference: inference, profile: profile, splashPreset: splashPreset))
    }

    func review(slot: EndpointSlot, remove: Bool) -> EndpointChangeReview {
        EndpointChangeReview(model: models.first { $0.item.path == slot.modelPath || $0.outputPaths.contains(slot.modelPath) },
            slot: slot, port: slot.port, role: slot.role, loadOnRequest: slot.usesJIT, keepLoaded: false, requireKey: false,
            memoryWarning: remove ? nil : memoryWarning(for: slot.modelPath),
            unverified: !remove && !appHost.isModelVerified(slot.modelPath), remove: remove)
    }

    /// Reviews moving an endpoint to another model on the same port.
    func reviewSwap(slot: EndpointSlot, to model: LibraryModel) -> EndpointChangeReview {
        EndpointChangeReview(model: model, slot: slot, port: slot.port, role: slot.role, loadOnRequest: slot.usesJIT,
            keepLoaded: false, requireKey: false, memoryWarning: memoryWarning(for: model.item.path),
            unverified: !appHost.isModelVerified(model.item.path), remove: false, swapTo: model)
    }

    private func memoryWarning(for path: String) -> String? {
        guard let verdict = appHost.runFleetVerdict(adding: path) else { return nil }
        if case .fits = verdict { return nil }
        return verdict.summary
    }

    func mayStop(_ slot: EndpointSlot) -> Bool {
        appHost.servedModelChange(identity: slot.modelPath, workbenchManaged: true).allowed
    }

    /// Why this endpoint cannot stop or be removed now; nil when it can.
    func stopRefusal(_ slot: EndpointSlot) -> String? {
        guard mayStop(slot) else {
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

    /// Rechecks the review before changing the fleet, including after a memory override.
    func confirm(_ review: EndpointChangeReview, overrideMemory: Bool = false) async -> Confirmation {
        let endpoint = appHost.endpoint
        if let slot = review.slot {
            guard endpoint.fleet.slots.contains(slot) else { return .refused("Endpoint changed; review it again.") }
            if review.remove {
                if let refusal = stopRefusal(slot) { return .refused(refusal) }
                await endpoint.removeSlot(id: slot.id)
                return endpoint.lastError.map(Confirmation.refused) ?? .completed
            }
            if let target = review.swapTo {
                if let refusal = stopRefusal(slot) { return .refused(refusal) }
                guard ServedModelsSelection.canConfirm(model: target, models: models),
                      ServedModelsSelection.candidates(models: models, slots: endpoint.fleet.slots.filter { $0.id != slot.id }, query: "")
                          .contains(where: { $0.item.path == target.item.path }) else {
                    return .refused("The model changed; review it again.")
                }
                guard review.memoryWarning == memoryWarning(for: target.item.path) else { return .refused("Memory conditions changed; review the endpoint again.") }
                guard review.unverified == !appHost.isModelVerified(target.item.path) else { return .refused("Verification changed; review the endpoint again.") }
                if !overrideMemory, let hold = memoryHold(for: target.item.path) { return .memoryHold(hold) }
                await endpoint.swapSlot(id: slot.id, to: target.item.path, allowUnverified: review.unverified)
                if let error = endpoint.lastError, endpoint.fleet.slots.first(where: { $0.id == slot.id })?.modelPath != target.item.path {
                    return .refused(error)
                }
                return startResult(slotID: slot.id)
            }
            guard review.memoryWarning == memoryWarning(for: slot.modelPath) else { return .refused("Memory conditions changed; review the endpoint again.") }
            guard review.unverified == !appHost.isModelVerified(slot.modelPath) else { return .refused("Verification changed; review the endpoint again.") }
            if !overrideMemory, let hold = memoryHold(for: slot.modelPath) { return .memoryHold(hold) }
            guard await endpoint.setSlotEnabled(id: slot.id, true) else {
                return .refused(endpoint.lastError ?? "The endpoint could not be enabled.")
            }
            return startResult(slotID: slot.id)
        }
        guard let model = review.model, ServedModelsSelection.canConfirm(model: model, models: models),
              ServedModelsSelection.candidates(models: models, slots: endpoint.fleet.slots, query: "").contains(where: { $0.item.path == model.item.path }),
              ServeView.isUsablePort(review.port, slots: endpoint.fleet.slots, servers: occupiedServers),
              review.memoryWarning == memoryWarning(for: model.item.path),
              review.unverified == !appHost.isModelVerified(model.item.path) else {
            return .refused("Model, port or memory conditions changed; review the endpoint again.")
        }
        if !overrideMemory, let hold = memoryHold(for: model.item.path) { return .memoryHold(hold) }
        let slotID = await endpoint.addSlot(modelPath: model.item.path, port: review.port, role: review.role, allowUnverified: review.unverified,
            loadOnRequest: review.loadOnRequest,
            memoryPolicy: review.loadOnRequest ? EndpointMemoryPolicy(idleTimeoutSeconds: 0, keepLoaded: review.keepLoaded,
                minimumHeadroomGB: 2, releaseAfterRequest: !review.keepLoaded) : nil,
            requireAPIKey: review.requireKey, inference: review.inference, profile: review.profile, splashPreset: review.splashPreset)
        guard let slotID else { return .refused(endpoint.lastError ?? "The endpoint could not be saved.") }
        return startResult(slotID: slotID)
    }

    private func memoryHold(for path: String) -> String? {
        guard let verdict = appHost.runFleetVerdict(adding: path), case .wontFit = verdict else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent + ": " + verdict.summary
    }

    private func startResult(slotID: UUID) -> Confirmation {
        let endpoint = appHost.endpoint
        switch endpoint.slotStates[slotID] {
        case .degraded(let reason):
            return .refused(reason)
        case .modelMismatch(let served, let port):
            return .refused(EndpointState.modelMismatch(servedModel: served, port: port).summary)
        case .running, .waitingForServer:
            return .completed
        default:
            return .refused(endpoint.lastError ?? "The endpoint did not start.")
        }
    }
}

private struct SplashPresetEditor: View {
    let api: WorkbenchAPI
    let saved: (SplashPreset) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var start = SplashTuning.StartingPoint.balanced
    @State private var tuning = SplashTuning()
    @State private var thinkingBudget = ""
    @State private var cacheQuota = ""
    @State private var memory = ""
    @State private var context = ""
    @State private var headroom = "2"
    @State private var idle = "300"
    @State private var executionWait = ""
    @State private var keepLoaded = false
    @State private var releaseAfterRequest = false
    @State private var pressure = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("New Splash preset").font(WorkbenchTypography.cardTitle)
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Start from", selection: $start) {
                        ForEach(SplashTuning.StartingPoint.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .onChange(of: start) { _, point in
                        tuning = point.tuning
                        thinkingBudget = point.tuning.thinkingBudget.map(String.init) ?? ""
                        cacheQuota = ""
                    }
                    Text(start.detail).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
                Section("Decoding") {
                    choice("Verify draft rows", $tuning.verifyRows, [("auto", "Adaptive, faster"), ("all", "Every row, repeatable")])
                    Picker("Reasoning effort", selection: $tuning.reasoningEffort) {
                        Text("Each request sets it").tag(String?.none)
                        ForEach(SplashTuning.efforts, id: \.self) { effort in
                            Text(effort == "none" ? "None, thinking off" : effort.capitalized).tag(String?.some(effort))
                        }
                    }
                    TextField("Thinking budget in tokens (optional)", text: $thinkingBudget)
                }
                Section("Cache") {
                    choice("KV cache", $tuning.kvFormat, [("int8", "int8, half the memory"), ("bf16", "bf16, full precision")])
                    choice("Cached states", $tuning.cachedStates, [("int8", "int8 codes"), ("exact", "Exact")])
                    Toggle("Keep the SSD cache across restarts", isOn: Binding(
                        get: { tuning.persistentCache == true }, set: { tuning.persistentCache = $0 ? true : nil }))
                    TextField("SSD cache quota in GB (optional, 0 turns it off)", text: $cacheQuota)
                }
                Section("Limits") {
                    TextField("Maximum memory in GB (optional)", text: $memory)
                    TextField("Maximum context tokens (optional)", text: $context)
                }
                Section("Residency") {
                    TextField("Headroom reserve in GB", text: $headroom)
                    TextField("Idle timeout in seconds", text: $idle).disabled(keepLoaded || releaseAfterRequest)
                    TextField("Execution wait in seconds (optional, 0–3600)", text: $executionWait)
                    Toggle("Keep loaded", isOn: $keepLoaded).onChange(of: keepLoaded) { _, value in
                        if value { pressure = false; releaseAfterRequest = false }
                    }
                    Toggle("Release weights after each request", isOn: $releaseAfterRequest).onChange(of: releaseAfterRequest) { _, value in
                        if value { keepLoaded = false }
                    }
                    Toggle("Unload under memory pressure", isOn: $pressure).disabled(keepLoaded)
                }
            }.formStyle(.grouped)
            if let error { InlineMessage(kind: .warning, text: error) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save preset") { Task { await save() } }.buttonStyle(.workbenchPrimary).disabled(busy)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 540, height: 640)
    }

    private func choice(_ title: String, _ selection: Binding<String?>, _ options: [(value: String, label: String)]) -> some View {
        Picker(title, selection: selection) {
            Text("Splash default").tag(String?.none)
            ForEach(options, id: \.value) { option in Text(option.label).tag(String?.some(option.value)) }
        }
    }

    private func save() async {
        guard let reserve = Double(headroom), let seconds = Int(idle),
              memory.isEmpty || Double(memory) != nil, context.isEmpty || Int(context) != nil,
              thinkingBudget.isEmpty || Int(thinkingBudget) != nil, cacheQuota.isEmpty || Double(cacheQuota) != nil,
              executionWait.isEmpty || Int(executionWait) != nil else {
            error = "Enter numbers for the values you set, a headroom reserve, and an idle timeout."; return
        }
        if let wait = Int(executionWait), !(0...3600).contains(wait) {
            error = "Execution wait must be between 0 and 3,600 seconds."; return
        }
        var chosen = tuning
        chosen.thinkingBudget = Int(thinkingBudget)
        chosen.maxCacheDiskGB = Double(cacheQuota)
        if let problem = chosen.problem { error = problem; return }
        var values: [String: Any] = ["min_headroom_gb": reserve, "idle_timeout": seconds,
                                     "keep_loaded": keepLoaded, "unload_under_pressure": pressure]
        if releaseAfterRequest { values["release_after_request"] = true }
        if let wait = Int(executionWait) { values["execution_wait_seconds"] = wait }
        if let value = Double(memory) { values["splash_max_memory_gb"] = value }
        if let value = Int(context) { values["splash_max_context_tokens"] = value }
        values.merge(chosen.settings) { _, tuned in tuned }
        guard let preset = SplashPreset(name: name, settings: values) else {
            error = "Set a limit or a Splash setting; with none, choose Default settings instead."; return
        }
        busy = true
        defer { busy = false }
        do { try await api.saveSplashPreset(preset); await saved(preset); dismiss() }
        catch { self.error = AppHost.render(error) }
    }
}

private struct SplashPresetApplySheet: View {
    let slot: EndpointSlot
    @ObservedObject var endpoint: EndpointSupervisor
    let api: WorkbenchAPI
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [SplashPreset] = []
    @State private var selected = ""
    @State private var review: SplashPresetReview?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Splash preset").font(WorkbenchTypography.cardTitle)
            Text("Endpoint on port \(slot.port)")
            Picker("Preset", selection: $selected) {
                Text("Choose a preset").tag("")
                ForEach(presets) { preset in Text(preset.name).tag(preset.name) }
            }.onChange(of: selected) { _, _ in review = nil }
            if let preset = presets.first(where: { $0.name == selected }) {
                Text(preset.summary).font(WorkbenchTypography.secondary)
            }
            if review != nil {
                Text("The endpoint will restart with these settings. Requests must be idle when you confirm.")
                    .font(WorkbenchTypography.secondary)
            }
            if let error { InlineMessage(kind: .warning, text: error) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if let review {
                    Button("Apply preset") {
                        Task { busy = true; if await endpoint.confirmSplashPreset(review) { dismiss() } else { error = endpoint.lastError }; busy = false }
                    }.buttonStyle(.workbenchPrimary).disabled(busy)
                } else {
                    Button("Review change") { Task { await prepare() } }.buttonStyle(.workbenchPrimary).disabled(busy || selected.isEmpty)
                }
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 460)
        .task {
            do { presets = try await api.splashPresets(); selected = slot.splashPresetName ?? "" }
            catch { self.error = AppHost.render(error) }
        }
    }

    private func prepare() async {
        guard let preset = presets.first(where: { $0.name == selected }) else { return }
        busy = true; defer { busy = false }
        do { review = try await endpoint.previewSplashPreset(slot: slot, preset: preset); error = nil }
        catch { self.error = AppHost.render(error) }
    }
}

private struct ServeViewLifecycleModifier<Runtime: Equatable, Mode: Equatable>: ViewModifier {
    let isRouteActive: Bool
    let selectedSplashPresetName: String
    let newSlotLoadOnRequest: Bool
    let requireAPIKey: Bool
    let selectedModelPath: String?
    let servers: [ServerInfo]
    let serversError: String?
    let inferenceOptions: LocalInferenceOptions
    let runtime: Runtime
    let mode: Mode
    let servingProfile: ServingProfile?
    let portText: String

    let onTask: () async -> Void
    let onRouteTask: () async -> Void
    let onSplashPresetChanged: (String) -> Void
    let onLoadOnRequestChanged: (Bool) -> Void
    let onRequireAPIKeyChanged: (Bool) -> Void
    let onSelectedModelChanged: () -> Void
    let onServersChanged: ([ServerInfo]) -> Void
    let onServersErrorChanged: (String?) -> Void
    let onRouteActiveChanged: (Bool) -> Void
    let onDisappear: () -> Void
    let onInferenceOptionsChanged: () -> Void
    let onRuntimeChanged: () -> Void
    let onModeChanged: (Mode) -> Void
    let onServingProfileChanged: () -> Void
    let onPortChanged: () -> Void
    let onAppear: () -> Void

    func body(content: Content) -> some View {
        content
            .task { await onTask() }
            .task(id: isRouteActive) {
                guard isRouteActive else { return }
                await onRouteTask()
            }
            .onChange(of: selectedSplashPresetName) { _, name in onSplashPresetChanged(name) }
            .onChange(of: newSlotLoadOnRequest) { _, enabled in onLoadOnRequestChanged(enabled) }
            .onChange(of: requireAPIKey) { _, required in onRequireAPIKeyChanged(required) }
            .onChange(of: selectedModelPath) { _, _ in onSelectedModelChanged() }
            .onChange(of: servers) { _, value in onServersChanged(value) }
            .onChange(of: serversError) { _, value in onServersErrorChanged(value) }
            .onChange(of: isRouteActive) { _, active in onRouteActiveChanged(active) }
            .onDisappear(perform: onDisappear)
            .onChange(of: inferenceOptions) { _, _ in onInferenceOptionsChanged() }
            .onChange(of: runtime) { _, _ in onRuntimeChanged() }
            .onChange(of: mode) { _, value in onModeChanged(value) }
            .onChange(of: servingProfile) { _, _ in onServingProfileChanged() }
            .onChange(of: portText) { _, _ in onPortChanged() }
            .onAppear(perform: onAppear)
    }
}
