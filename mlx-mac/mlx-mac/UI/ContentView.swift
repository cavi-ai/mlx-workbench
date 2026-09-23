import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var appHost: AppHost
    @ObservedObject private var endpoint: EndpointSupervisor
    @ObservedObject private var modelWorkflow: ModelWorkflowCoordinator
    @ObservedObject private var setup: SetupCoordinator
    /// Persisted across launches; legacy/unknown values resolve to Overview.
    @AppStorage(AppRoute.selectionStorageKey) private var selectedRouteID = AppRoute.overview.rawValue
    @State private var visitedRoutes: Set<AppRoute> = []

    init(appHost: AppHost) {
        _appHost = StateObject(wrappedValue: appHost)
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _modelWorkflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _setup = ObservedObject(wrappedValue: appHost.setup)
    }

    private var selectedRoute: AppRoute {
        AppRoute(rawID: selectedRouteID)
    }

    private var selectedRouteBinding: Binding<AppRoute> {
        Binding(
            get: { AppRoute(rawID: selectedRouteID) },
            set: { selectedRouteID = $0.rawValue }
        )
    }

    var body: some View {
        NavigationSplitView {
            AppSidebar(selectedRoute: selectedRouteBinding, badges: sidebarBadges)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            visitedDestinations
                .navigationTitle(selectedRoute.label)
                .navigationSubtitle(subtitle)
                .toolbar { contextToolbar }
        }
        .background { routeShortcutButtons }
        .onChange(of: selectedRouteID) { _, _ in
            visitedRoutes.insert(selectedRoute)
        }
        .onAppear {
            visitedRoutes.insert(selectedRoute)
            Task { await appHost.rescan() }
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
        AppRoute.allCases.filter { visitedRoutes.contains($0) }
    }

    @ViewBuilder
    private var visitedDestinations: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkbenchColor.canvas)
    }

    @ViewBuilder
    private func routeDestination(_ route: AppRoute) -> some View {
        switch route {
        case .overview:
            HomeView(appHost: appHost, onRouteSelection: navigate)
        case .library:
            LibraryView(appHost: appHost, onRouteSelection: navigate)
        case .prepare:
            ConvertView(appHost: appHost, onRouteSelection: navigate)
        case .compare:
            QuantView(appHost: appHost, onRouteSelection: navigate)
        case .run:
            ServeView(appHost: appHost, onRouteSelection: navigate)
        case .activity:
            JobsView(appHost: appHost, onRouteSelection: navigate)
        case .reclaim:
            DuplicatesView(appHost: appHost)
        case .clientSetup:
            WireView(appHost: appHost)
        case .health:
            DoctorView(appHost: appHost, onRouteSelection: navigate)
        case .discover:
            ScoutView(appHost: appHost)
        case .lmStudio:
            LMStudioView(appHost: appHost, onRouteSelection: navigate)
        case .training:
            TrainingView(appHost: appHost)
        case .adopt:
            AdoptView(appHost: appHost)
        case .settings:
            SettingsView(appHost: appHost)
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
        guard selectedRoute.group == .lifecycle else { return "" }
        guard let path = appHost.selectedModelPath, !path.isEmpty else { return "No model selected" }
        return HFRepoID.forPath(path) ?? URL(fileURLWithPath: path).lastPathComponent
    }

    /// Lifecycle and endpoint state ride in the toolbar only while they carry
    /// information: an idle workflow and an empty fleet show nothing.
    @ToolbarContentBuilder
    private var contextToolbar: some ToolbarContent {
        if modelWorkflow.workflow.state != .idle {
            ToolbarItem(placement: .automatic) {
                Button {
                    navigate(to: .activity)
                } label: {
                    StatusBadge(state: modelWorkflow.workflow.state.rawValue)
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
