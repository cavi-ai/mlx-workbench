import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    private let appHost: AppHost
    @ObservedObject private var endpoint: EndpointSupervisor
    @ObservedObject private var servingInventory: ServingInventoryCoordinator
    @ObservedObject private var modelWorkflow: ModelWorkflowCoordinator
    @ObservedObject private var setup: SetupCoordinator
    @ObservedObject private var comparison: ComparisonCoordinator
    @ObservedObject private var verification: VerificationCoordinator
    @ObservedObject private var trainedAdapters: TrainedAdapterServingCoordinator
    @ObservedObject private var reclaim: ReclaimCoordinator
    @ObservedObject private var watch: WatchCoordinator
    /// Persisted across launches; a missing or unknown value resolves to Library.
    @AppStorage(AppRoute.selectionStorageKey) private var selectedRouteID = AppRoute.library.rawValue
    /// The workflow outcome last seen on Prepare or Activity; a failure stays in the toolbar until then.
    @AppStorage(Self.acknowledgedOutcomeStorageKey) private var acknowledgedOutcome = ""
    @State private var visitedRoutes: Set<AppRoute> = []
    @State private var viewport = CGSize(width: WorkbenchSize.windowDefaultWidth, height: WorkbenchSize.windowDefaultHeight)

    init(appHost: AppHost) {
        self.appHost = appHost
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _servingInventory = ObservedObject(wrappedValue: appHost.servingInventory)
        _modelWorkflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _setup = ObservedObject(wrappedValue: appHost.setup)
        _comparison = ObservedObject(wrappedValue: appHost.comparison)
        _verification = ObservedObject(wrappedValue: appHost.verification)
        _trainedAdapters = ObservedObject(wrappedValue: appHost.trainedAdapters)
        _reclaim = ObservedObject(wrappedValue: appHost.reclaim)
        _watch = ObservedObject(wrappedValue: appHost.watch)
    }

    private var selectedRoute: AppRoute {
        AppRoute(rawID: selectedRouteID).navigationDestination
    }

    private var selectedRouteBinding: Binding<AppRoute> {
        Binding(
            get: { selectedRoute },
            set: { selectedRouteID = $0.rawValue }
        )
    }

    var body: some View {
        NavigationSplitView {
            AppSidebar(selectedRoute: selectedRouteBinding, badges: sidebarBadges,
                       models: appHost.librarySnapshot?.models ?? [])
                .navigationSplitViewColumnWidth(min: WorkbenchSize.sidebarMinimum, ideal: WorkbenchSize.sidebarIdeal, max: WorkbenchSize.sidebarMaximum)
        } detail: {
            visitedDestinations
                .sheet(isPresented: inventoryReviewBinding, onDismiss: {
                    servingInventory.cancelReview()
                    Task { await servingInventory.refresh() }
                }) {
                    ServingInventoryReviewSheet(inventory: servingInventory, hosts: appHost.modelHosts)
                }
                .workbenchScrollEdge()
                .navigationTitle(selectedRoute.label)
                .navigationSubtitle(subtitle)
                .toolbar {
#if compiler(>=6.2)
                    if #available(macOS 26.0, *) {
                        // The status badge already supplies its own capsule.
                        // Avoid nesting it inside the system toolbar glass.
                        contextToolbar.sharedBackgroundVisibility(.hidden)
                    } else {
                        contextToolbar
                    }
#else
                    contextToolbar
#endif
                }
        }
        .frame(minWidth: WorkbenchSize.windowMinimumWidth, minHeight: WorkbenchSize.windowMinimumHeight)
        .environment(\.workbenchViewport, viewport)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
        .background { routeShortcutButtons }
        .onChange(of: selectedRouteID) { _, _ in
            visitedRoutes.insert(selectedRoute)
            acknowledgeOutcomeOnItsPage()
        }
        .onChange(of: Self.outcomeKey(modelWorkflow.workflow)) { _, _ in
            acknowledgeOutcomeOnItsPage()
        }
        .onAppear {
            visitedRoutes.insert(selectedRoute)
            acknowledgeOutcomeOnItsPage()
        }
        .sheet(isPresented: $setup.isPresented) {
            SetupAssistantView(appHost: appHost, coordinator: setup)
                .interactiveDismissDisabled(false)
        }
    }

    /// ⌘1…⌘9 open the first nine sidebar pages in order; ⌘0 opens Settings.
    static let shortcutRoutes: [AppRoute] =
        Array(AppRoute.grouped.flatMap(\.routes).filter { $0 != .settings }.prefix(9)) + [.settings]
    private static let shortcutKeys: [KeyEquivalent] = [
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
    ]

    private var routeShortcutButtons: some View {
        ForEach(Array(Self.shortcutRoutes.enumerated()), id: \.element) { index, route in
            Button(route.label) { selectedRouteID = route.rawValue }
                .keyboardShortcut(Self.shortcutKeys[index], modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    /// Keeps a destination mounted after its first visit, preserving local
    /// view state without eagerly constructing every feature view.
    static func mountedRoutes(for visitedRoutes: Set<AppRoute>) -> [AppRoute] {
        let destinations = Set(visitedRoutes.map(\.navigationDestination))
        return AppRoute.allCases.filter { destinations.contains($0) }
    }

    @ViewBuilder
    private var visitedDestinations: some View {
        // Retained pages must not impose their intrinsic minimum on the split view.
        GeometryReader { geometry in
            ZStack {
                ForEach(Self.mountedRoutes(for: visitedRoutes), id: \.self) { route in
                    let isActive = route == selectedRoute
                    routeDestination(route)
                        .environment(\.isRouteActive, isActive)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .accessibilityHidden(!isActive)
                        .zIndex(isActive ? 1 : 0)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func routeDestination(_ route: AppRoute) -> some View {
        switch route {
        case .overview:
            HomeView(appHost: appHost, onRouteSelection: navigate)
        case .library, .lmStudio:
            LibraryWorkspace(appHost: appHost,
                lmStudioRequested: selectedRouteID == AppRoute.lmStudio.rawValue, onRouteSelection: navigate)
        case .use:
            UseWorkspaceView(appHost: appHost, onRouteSelection: navigate)
        case .prepare:
            ConvertView(appHost: appHost, onRouteSelection: navigate)
        case .compare:
            ComparisonWorkspace(appHost: appHost, onRouteSelection: navigate)
        case .run:
            ServeView(appHost: appHost, onRouteSelection: navigate)
        case .monitor:
            ServingMonitorView(appHost: appHost, onRouteSelection: navigate)
        case .sources:
            ModelSourcesView(appHost: appHost, onRouteSelection: navigate)
        case .activity:
            JobsView(appHost: appHost, onRouteSelection: navigate)
        case .reclaim:
            DuplicatesView(appHost: appHost, onRouteSelection: navigate)
        case .clientSetup:
            WireView(appHost: appHost, onRouteSelection: navigate)
        case .health:
            DoctorView(appHost: appHost, onRouteSelection: navigate)
        case .discover, .adopt:
            DiscoveryWorkspace(appHost: appHost,
                recommendationRequested: selectedRouteID == AppRoute.adopt.rawValue, onRouteSelection: navigate)
        case .studies:
            StudiesView(lab: appHost.lab, installer: appHost.runtimeInstaller, agentPath: appHost.config.mlxAgentPath)
        case .training:
            TrainingView(appHost: appHost, onRouteSelection: navigate)
        case .settings:
            SettingsView(appHost: appHost, onRouteSelection: navigate)
        case .terminal:
            TerminalWorkspaceView(appHost: appHost, onRouteSelection: navigate)
        }
    }

    private func navigate(to route: AppRoute) {
        selectedRouteID = route.rawValue
    }

    private var inventoryReviewBinding: Binding<Bool> {
        Binding(get: { servingInventory.actionReview?.surface == .window }, set: { if !$0 { servingInventory.cancelReview() } })
    }

    private var sidebarBadges: [AppRoute: String] {
        var badges: [AppRoute: String] = [:]
        if let reclaimBadge = appHost.reclaim.badgeText {
            badges[AppRoute.BadgeDestination.reclaim.route] = reclaimBadge
        }
        let alertCount = appHost.watch.activeAlerts.count
        if alertCount > 0 {
            badges[AppRoute.BadgeDestination.alerts.route] = "\(alertCount)"
        }
        return badges
    }

    // MARK: - Window chrome

    /// The selected model is context for Prepare and Run only; elsewhere
    /// the title stands alone.
    private var subtitle: String {
        if selectedRoute == .run, let job = trainedAdapters.selectedJob { return job.repo + " · trained adapter" }
        return Self.subtitle(route: selectedRoute, workflow: modelWorkflow.workflow, selectedModelPath: appHost.selectedModelPath)
    }

    /// Prepare names the workflow's source, which can differ from the Library
    /// selection; Run names the model it shows.
    static func subtitle(route: AppRoute, workflow: ConversionWorkflow, selectedModelPath: String?) -> String {
        guard route == .prepare || route == .run else { return "" }
        if route == .prepare { return PrepareWorkflowPresentation(workflow: workflow).displayName }
        if route == .run {
            guard let path = RunPresentation.shownModelPath(workflow: workflow, selectedModelPath: selectedModelPath) else { return "" }
            return HFRepoID.forPath(path) ?? URL(fileURLWithPath: path).lastPathComponent
        }
        guard let path = selectedModelPath, !path.isEmpty else { return "No model selected" }
        return HFRepoID.forPath(path) ?? URL(fileURLWithPath: path).lastPathComponent
    }

    static let acknowledgedOutcomeStorageKey = "acknowledgedWorkflowOutcome"

    /// One key per workflow and state, so a new failure is unacknowledged even for the same workflow.
    static func outcomeKey(_ workflow: ConversionWorkflow) -> String {
        "\(workflow.id.uuidString)-\(workflow.state.rawValue)"
    }

    /// In-flight conversions and unacknowledged failures ride in the toolbar off Prepare and Activity;
    /// successes stay on Overview, Prepare and Activity.
    static func showsWorkflowBadge(route: AppRoute, state: ConversionWorkflowState, acknowledged: Bool) -> Bool {
        guard route != .prepare, route != .activity else { return false }
        return state.isInFlight || (!acknowledged && (state == .failed || state == .verificationFailed))
    }

    private func acknowledgeOutcomeOnItsPage() {
        guard selectedRoute == .prepare || selectedRoute == .activity else { return }
        acknowledgedOutcome = Self.outcomeKey(modelWorkflow.workflow)
    }

    /// Serving and Activity stay accessible from every workspace.
    @ToolbarContentBuilder
    private var contextToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            SystemResourceHeader(resources: appHost.resources, endpoint: endpoint, hosts: appHost.modelHosts,
                                 servingInventory: appHost.servingInventory,
                                 servers: modelWorkflow.servers,
                                 libraryModels: appHost.librarySnapshot?.models ?? [],
                                 historyLoaded: comparison.hasLoadedHistory,
                                 onManageServing: { rowID in
                appHost.handoffs.send(ServingFocusRequest(rowID: rowID), as: .openServing)
                navigate(to: .run)
            },
                                 onRefreshServers: { await appHost.modelWorkflow.refreshServers() },
                                 onOpenHost: { host in
                appHost.handoffs.send(HostedModelsRequest(host: host), as: .openHostedModels)
                navigate(to: .library)
            }, occupancy: appHost.occupancy, onUnload: { server in
                await appHost.unloadServing(server)
            })
        }
        ToolbarItem(id: "workbench.activity", placement: .primaryAction) {
            let workflow = modelWorkflow.workflow
            let unacknowledged = (workflow.state == .failed || workflow.state == .verificationFailed)
                && Self.showsWorkflowBadge(route: selectedRoute, state: workflow.state,
                                           acknowledged: acknowledgedOutcome == Self.outcomeKey(workflow))
            ActivityToolbarButton(status: ActivityToolbarStatus(
                workflow: workflow, history: modelWorkflow.history,
                statusUnavailable: appHost.conversionStatusError != nil,
                unacknowledgedFailure: unacknowledged, verifying: verification.activeModelPath != nil,
                comparing: comparison.activeRunID != nil, reading: modelWorkflow.isLoadingHistory,
                saving: modelWorkflow.isSavingHistory), selected: selectedRoute == .activity,
                compact: viewport.width < 920) {
                navigate(to: .activity)
            }
        }
    }
}

struct ActivityToolbarStatus: Equatable {
    enum Kind: Equatable { case idle, working, queued, attention }

    let kind: Kind
    let detail: String?

    init(workflow: ConversionWorkflow, history: [ConversionWorkflow], statusUnavailable: Bool = false,
         unacknowledgedFailure: Bool = false, verifying: Bool = false, comparing: Bool = false,
         reading: Bool = false, saving: Bool = false) {
        let earlier = history.lazy.filter { $0.id != workflow.id }
        let converting = workflow.state == .running || earlier.contains { $0.state == .running }
        let queued = earlier.reduce(workflow.state == .queued ? 1 : 0) { $0 + ($1.state == .queued ? 1 : 0) }
        if statusUnavailable && (converting || queued > 0) {
            self.init(.attention, "Status unavailable")
        } else if unacknowledgedFailure {
            self.init(.attention, workflow.state == .verificationFailed ? "Verification failed" : "Conversion failed")
        } else if converting {
            self.init(.working, queued > 0 ? "Converting · \(queued) queued" : "Converting")
        } else if verifying || workflow.state == .verifying {
            self.init(.working, "Verifying")
        } else if comparing {
            self.init(.working, "Comparing")
        } else if queued > 0 {
            self.init(.queued, "\(queued) queued")
        } else if reading || saving {
            self.init(.working, reading ? "Reading history" : "Saving history")
        } else {
            self.init(.idle, nil)
        }
    }

    private init(_ kind: Kind, _ detail: String?) {
        self.kind = kind
        self.detail = detail
    }

    var symbol: String {
        switch kind {
        case .idle, .working: "waveform"
        case .queued: "clock"
        case .attention: "exclamationmark"
        }
    }
}

struct ActivityToolbarButton: View {
    let status: ActivityToolbarStatus
    let selected: Bool
    var compact = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        switch status.kind {
        case .idle: selected ? WorkbenchColor.accent : WorkbenchColor.muted
        case .working: WorkbenchColor.accent
        case .queued, .attention: WorkbenchColor.warning
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: WorkbenchSpacing.xs) {
                glyph
                if !compact {
                    Text("Activity").font(WorkbenchTypography.metadata.weight(.semibold))
                    if let detail = status.detail {
                        Divider().frame(height: 12)
                        Text(detail).font(WorkbenchTypography.metadata).foregroundStyle(tint)
                    }
                }
            }
            .fixedSize()
            .padding(.horizontal, WorkbenchSpacing.xs)
            .padding(.vertical, WorkbenchSpacing.xxxs)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(WorkbenchColor.hairline, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Activity")
        .accessibilityValue(status.detail ?? "Idle")
        .accessibilityHint("Opens Activity")
        .accessibilityIdentifier("activity-toolbar-button")
        .help(status.detail.map { "Activity · " + $0 } ?? "Open Activity")
    }

    private var glyph: some View {
        Image(systemName: status.symbol)
            .font(WorkbenchTypography.metadata.weight(.semibold))
            .symbolRenderingMode(.hierarchical)
            .symbolEffect(.variableColor.iterative, options: .repeating,
                          isActive: status.kind == .working && !reduceMotion)
            .foregroundStyle(tint)
            .frame(width: 20, height: 20)
            .background(tint.opacity(WorkbenchTint.fill), in: Circle())
            .accessibilityHidden(true)
    }
}
