import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var appHost: AppHost
    @ObservedObject private var endpoint: EndpointSupervisor
    @ObservedObject private var modelWorkflow: ModelWorkflowCoordinator
    @State private var selectedRoute: AppRoute = .overview
    @State private var visitedRoutes: Set<AppRoute> = [.overview]

    init(appHost: AppHost) {
        _appHost = StateObject(wrappedValue: appHost)
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _modelWorkflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
    }

    var body: some View {
        NavigationSplitView {
            AppSidebar(selectedRoute: $selectedRoute, badges: sidebarBadges)
                .navigationSplitViewColumnWidth(min: 176, ideal: 208, max: 220)
        } detail: {
            VStack(spacing: 0) {
                WorkspaceHeader(
                    route: selectedRoute,
                    selectedModelPath: appHost.selectedModelPath,
                    endpoint: endpoint,
                    modelWorkflow: modelWorkflow
                )

                Divider()
                    .overlay(WorkbenchColor.hairline)

                visitedDestinations
            }
            .background(WorkbenchColor.alloyCanvas)
        }
        .tint(WorkbenchColor.fluxTeal)
        .accentColor(WorkbenchColor.fluxTeal)
        .onChange(of: selectedRoute) { _, route in
            visitedRoutes.insert(route)
        }
        .onAppear {
            Task { await appHost.rescan() }
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
                routeDestination(route)
                    .opacity(route == selectedRoute ? 1 : 0)
                    .allowsHitTesting(route == selectedRoute)
                    .accessibilityHidden(route != selectedRoute)
                    .zIndex(route == selectedRoute ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func routeDestination(_ route: AppRoute) -> AnyView {
        switch route {
        case .overview:
            return AnyView(HomeView(appHost: appHost, onRouteSelection: navigate))
        case .library:
            return AnyView(LibraryView(appHost: appHost, onRouteSelection: navigate))
        case .prepare:
            return AnyView(ConvertView(appHost: appHost, onRouteSelection: navigate))
        case .compare:
            return AnyView(QuantView(appHost: appHost))
        case .run:
            return AnyView(ServeView(appHost: appHost, onRouteSelection: navigate))
        case .activity:
            return AnyView(JobsView(appHost: appHost, onRouteSelection: navigate))
        case .reclaim:
            return AnyView(DuplicatesView(appHost: appHost))
        case .clientSetup:
            return AnyView(WireView(appHost: appHost))
        case .health:
            return AnyView(DoctorView(appHost: appHost))
        case .discover:
            return AnyView(ScoutView(appHost: appHost))
        case .lmStudio:
            return AnyView(LMStudioView(appHost: appHost, onRouteSelection: navigate))
        case .training:
            return AnyView(TrainingView(appHost: appHost))
        case .adopt:
            return AnyView(AdoptView(appHost: appHost))
        case .settings:
            return AnyView(SettingsView(appHost: appHost))
        }
    }

    private func navigate(rawID: String) {
        selectedRoute = AppRoute(rawID: rawID)
    }

    private var sidebarBadges: [AppRoute: String] {
        var badges: [AppRoute: String] = [:]
        if let reclaimBadge = appHost.reclaim.badgeText {
            badges[AppRoute.BadgeDestination.reclaim.route] = reclaimBadge
        }
        let alertCount = appHost.watch.activeAlerts.count
        if alertCount > 0 {
            badges[AppRoute.BadgeDestination.alerts.route] = "\(alertCount) alert\(alertCount == 1 ? "" : "s")"
        }
        return badges
    }
}

// MARK: - Workspace header

private struct WorkspaceHeader: View {
    let route: AppRoute
    let selectedModelPath: String?
    @ObservedObject var endpoint: EndpointSupervisor
    @ObservedObject var modelWorkflow: ModelWorkflowCoordinator

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: WorkbenchSpacing.lg) {
                routeIdentity
                    .frame(maxWidth: .infinity, alignment: .leading)

                headerValue(label: "Model", value: selectedModelName)
                endpointContext(showSummary: true)
                lifecycleContext
            }
            .frame(minWidth: 820)

            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                routeIdentity

                HStack(alignment: .center, spacing: WorkbenchSpacing.md) {
                    headerValue(label: "Model", value: selectedModelName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    endpointContext(showSummary: false)
                    lifecycleContext
                }
            }
        }
        .padding(.horizontal, WorkbenchSpacing.pageInset)
        .padding(.vertical, WorkbenchSpacing.sm)
        .frame(minHeight: 62)
        .background(WorkbenchColor.instrumentSurface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(route.label). \(route.pageDescription). Model: \(selectedModelName). Endpoint: \(endpoint.state.summary). Lifecycle: \(modelWorkflow.workflow.state.rawValue)")
    }

    private var routeIdentity: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(route.label)
                .font(WorkbenchTypography.section)
                .foregroundColor(WorkbenchColor.graphiteInk)
            Text(route.pageDescription)
                .font(WorkbenchTypography.body)
                .foregroundColor(WorkbenchColor.graphiteMuted)
                .lineLimit(1)
        }
    }

    private func endpointContext(showSummary: Bool) -> some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            Text("Endpoint")
                .font(WorkbenchTypography.navigation)
                .foregroundColor(WorkbenchColor.graphiteMuted)
            StatusBadge(status: endpointBadgeStatus)
            // The badge already says it when the summary is just the state
            // label (e.g. "Disabled"); only add genuinely richer context.
            if showSummary, endpoint.state.summary != endpointBadgeStatus.label {
                Text(endpoint.state.summary)
                    .font(WorkbenchTypography.monoUtility)
                    .foregroundColor(WorkbenchColor.graphiteInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .help(endpoint.state.summary)
    }

    private var lifecycleContext: some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            Text("Lifecycle")
                .font(WorkbenchTypography.navigation)
                .foregroundColor(WorkbenchColor.graphiteMuted)
            StatusBadge(state: modelWorkflow.workflow.state.rawValue)
        }
    }

    private func headerValue(label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: WorkbenchSpacing.xxs) {
            Text(label)
                .font(WorkbenchTypography.navigation)
                .foregroundColor(WorkbenchColor.graphiteMuted)
            Text(value)
                .font(WorkbenchTypography.monoUtility)
                .foregroundColor(WorkbenchColor.graphiteInk)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: 180, alignment: .trailing)
    }

    private var selectedModelName: String {
        guard let selectedModelPath, !selectedModelPath.isEmpty else { return "No model selected" }
        return URL(fileURLWithPath: selectedModelPath).lastPathComponent
    }

    private var endpointBadgeStatus: WorkbenchStatus {
        switch endpoint.state {
        case .disabled: return .disabled
        case .starting, .waitingForServer: return .pending
        case .running: return .running
        case .modelMismatch: return .warning
        case .degraded: return .failure
        }
    }
}
