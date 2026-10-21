import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var appHost: AppHost
    @ObservedObject private var endpoint: EndpointSupervisor
    @ObservedObject private var modelWorkflow: ModelWorkflowCoordinator
    @ObservedObject private var setup: SetupCoordinator
    @ObservedObject private var comparison: ComparisonCoordinator
    @ObservedObject private var verification: VerificationCoordinator
    @ObservedObject private var trainedAdapters: TrainedAdapterServingCoordinator
    /// Persisted across launches; legacy/unknown values resolve to Overview.
    @AppStorage(AppRoute.selectionStorageKey) private var selectedRouteID = AppRoute.overview.rawValue
    /// The workflow outcome last seen on Prepare or Activity; a failure stays in the toolbar until then.
    @AppStorage(Self.acknowledgedOutcomeStorageKey) private var acknowledgedOutcome = ""
    @State private var visitedRoutes: Set<AppRoute> = []
    @State private var viewport = CGSize(width: WorkbenchSize.windowDefaultWidth, height: WorkbenchSize.windowDefaultHeight)

    init(appHost: AppHost) {
        _appHost = StateObject(wrappedValue: appHost)
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _modelWorkflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _setup = ObservedObject(wrappedValue: appHost.setup)
        _comparison = ObservedObject(wrappedValue: appHost.comparison)
        _verification = ObservedObject(wrappedValue: appHost.verification)
        _trainedAdapters = ObservedObject(wrappedValue: appHost.trainedAdapters)
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
            AppSidebar(selectedRoute: selectedRouteBinding, badges: sidebarBadges)
                .navigationSplitViewColumnWidth(min: WorkbenchSize.sidebarMinimum, ideal: WorkbenchSize.sidebarIdeal, max: WorkbenchSize.sidebarMaximum)
        } detail: {
            visitedDestinations
                .workbenchCanvas()
                .workbenchScrollEdge()
                .navigationTitle(selectedRoute.label)
                .navigationSubtitle(subtitle)
                .toolbarBackground(WorkbenchColor.canvas, for: .windowToolbar)
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

    /// ⌘1…⌘9, ⌘0 jump between the main tabs (Lab items stay click-only).
    private static let shortcutRoutes: [AppRoute] = [
        .overview, .library, .prepare, .compare, .run,
        .activity, .reclaim, .clientSetup, .health, .settings,
    ]
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
                    VStack(spacing: 0) {
                        if route != .library && route != .compare { WorkbenchPageHeading(route: route) }
                        routeDestination(route)
                    }
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
        case .prepare:
            ConvertView(appHost: appHost, onRouteSelection: navigate)
        case .compare:
            ComparisonWorkspace(appHost: appHost, onRouteSelection: navigate)
        case .run:
            ServeView(appHost: appHost, onRouteSelection: navigate)
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
        }
    }

    private func navigate(to route: AppRoute) {
        selectedRouteID = route.rawValue
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

    /// The selected model is context for the lifecycle tabs only; elsewhere
    /// the title stands alone.
    private var subtitle: String {
        if selectedRoute == .run, let job = trainedAdapters.selectedJob { return job.repo + " · trained adapter" }
        return Self.subtitle(route: selectedRoute, workflow: modelWorkflow.workflow, selectedModelPath: appHost.selectedModelPath)
    }

    /// Prepare names the workflow's source, which can differ from the Library
    /// selection; the other lifecycle tabs name the selection.
    static func subtitle(route: AppRoute, workflow: ConversionWorkflow, selectedModelPath: String?) -> String {
        guard route.group == .lifecycle, route != .compare else { return "" }
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

    /// Lifecycle and endpoint state ride in the toolbar only while they carry
    /// information: an idle workflow and an empty fleet show nothing.
    @ToolbarContentBuilder
    private var contextToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            SystemResourceHeader(resources: appHost.resources, endpoint: endpoint, hosts: appHost.modelHosts,
                                 onOpenHost: { host in
                appHost.hostedLibraryHostRequest = host
                appHost.hostedLibraryRequested = true
                navigate(to: .library)
            }, occupancy: appHost.occupancy, onUnload: { server in
                await appHost.unloadServing(server)
            })
        }
        if Self.showsWorkflowBadge(route: selectedRoute, state: modelWorkflow.workflow.state,
                                   acknowledged: acknowledgedOutcome == Self.outcomeKey(modelWorkflow.workflow)) {
            ToolbarItem(placement: .automatic) {
                Button {
                    navigate(to: .activity)
                } label: {
                    StatusBadge(state: modelWorkflow.workflow.state.rawValue)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .help("Conversion \(modelWorkflow.workflow.state.rawValue). Open Activity.")
                .accessibilityLabel("Conversion status: \(modelWorkflow.workflow.state.rawValue)")
            }
        }
        if !endpoint.fleet.slots.isEmpty {
            ToolbarItem(placement: .automatic) {
                Button {
                    navigate(to: .run)
                } label: {
                    Label(endpoint.state.summary, systemImage: EndpointIcon.name(for: endpoint.state))
                        .font(WorkbenchTypography.label)
                        .foregroundStyle(endpointStatus.color)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Endpoint: \(endpoint.state.summary). Open Run.")
                .accessibilityLabel("Endpoint: \(endpoint.state.summary)")
            }
        }
    }

    private var endpointStatus: WorkbenchStatus {
        switch endpoint.state {
        case .disabled: return .disabled
        case .starting, .waitingForServer: return .pending
        case .running: return .running
        case .modelMismatch: return .warning
        case .degraded: return .failure
        }
    }
}
