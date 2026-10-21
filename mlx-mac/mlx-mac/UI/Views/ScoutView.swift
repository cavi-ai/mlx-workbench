import AppKit
import SwiftUI

enum DiscoveryMode: String, CaseIterable, Identifiable {
    case browse, recommend
    var id: Self { self }
    var title: String { self == .browse ? "Browse candidates" : "Recommend for a task" }
}

/// Both tasks retain their draft and results when switching modes or routes.
struct DiscoveryWorkspace: View {
    let appHost: AppHost
    let recommendationRequested: Bool
    let onRouteSelection: (AppRoute) -> Void
    @Environment(\.isRouteActive) private var isRouteActive
    @State private var mode: DiscoveryMode
    @State private var visitedModes: Set<DiscoveryMode>

    init(appHost: AppHost, initialMode: DiscoveryMode = .browse, recommendationRequested: Bool = false,
         onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        self.recommendationRequested = recommendationRequested
        self.onRouteSelection = onRouteSelection
        let initial = recommendationRequested ? DiscoveryMode.recommend : initialMode
        _mode = State(initialValue: initial)
        _visitedModes = State(initialValue: [initial])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Discovery task", selection: $mode) {
                ForEach(DiscoveryMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 440)
            .padding(.horizontal, WorkbenchSpacing.pageInset)
            .padding(.top, WorkbenchSpacing.pageInset)
            .accessibilityIdentifier("discovery-mode")
            ZStack {
                ForEach(DiscoveryMode.allCases.filter { visitedModes.contains($0) }) { destination in
                    let active = destination == mode
                    modeView(destination)
                        .environment(\.isRouteActive, isRouteActive && active)
                        .opacity(active ? 1 : 0)
                        .allowsHitTesting(active)
                        .accessibilityHidden(!active)
                        .zIndex(active ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: mode) { _, selected in visitedModes.insert(selected) }
        .onChange(of: recommendationRequested) { _, requested in
            if requested { mode = .recommend; visitedModes.insert(.recommend) }
        }
    }

    @ViewBuilder private func modeView(_ mode: DiscoveryMode) -> some View {
        switch mode {
        case .browse: ScoutView(appHost: appHost)
        case .recommend: AdoptView(appHost: appHost, onRouteSelection: onRouteSelection)
        }
    }
}

// MARK: - ScoutView
// Discover MLX models for this host, by role.

struct ScoutView: View {
    @ObservedObject var appHost: AppHost
    private let resources: SystemResourceMonitor

    @State private var role = ""
    @State private var limit = DiscoverLimit.initial
    @State private var fast = false
    @StateObject private var session: DiscoverySession
    @State private var showsCatalogDetails = false
    @State private var layout = DiscoverLayout()

    /// `resources` and `initialState` let a render hold the page at a fixed budget and result.
    init(appHost: AppHost, resources: SystemResourceMonitor? = nil, initialState: DiscoveryState = .notRun) {
        self.appHost = appHost
        self.resources = resources ?? appHost.resources
        _session = StateObject(wrappedValue: DiscoverySession(initialState: initialState) { request in
            let response = try await appHost.api.discover(role: request.role, limit: request.limit, fast: request.fast, new: false)
            return response.candidates ?? []
        })
    }

    private var isScouting: Bool { session.state.isRunning }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                    header
                    DiscoverFitField(
                        resources: resources,
                        intake: appHost.intake,
                        state: session.state,
                        resultToken: session.resultToken,
                        reserveGB: appHost.config.fitReserveGB,
                        hardware: appHost.hardwareProfile,
                        library: appHost.librarySnapshot,
                        layout: layout,
                        fast: session.request?.fast ?? false,
                        snapshot: session.result,
                        isStopping: session.isStopping,
                        onStop: { session.stop() },
                        onClear: { session.clear() }
                    )
                    catalogSection
                }
                .frame(maxWidth: WorkbenchSize.Discover.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(WorkbenchSpacing.pageInset)
            }
            .defaultScrollAnchor(.top)
            .onChange(of: viewport.size.width, initial: true) { _, width in
                layout = DiscoverLayout(viewportWidth: width, previous: layout)
            }
        }
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) { catalogHeader }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { catalogHeader }
            }
            Text(appHost.catalog.statusLabel)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            if let reason = appHost.catalogRefreshUnavailableReason, !appHost.isRefreshingCatalog {
                Text(reason + " You can still browse candidates above; this separate cache does not determine which models are installed.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("discover-catalog-guidance")
            }
            DisclosureGroup("Details and catalog entries", isExpanded: $showsCatalogDetails) {
                catalogDetails
                    .padding(.top, WorkbenchSpacing.xs)
            }
            .font(WorkbenchTypography.secondary)
        }
    }

    private var catalogDetails: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text("Metadata only. Local installation truth comes from the Library scan, not this catalog cache.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            HStack(alignment: .top, spacing: WorkbenchSpacing.lg) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    if let snapshot = appHost.catalog.snapshot {
                        statusRow(label: "Source", value: snapshot.sourceLabel)
                        statusRow(label: "Revision", value: snapshot.revision)
                        statusRow(label: "Last Refresh", value: Self.timestampFormatter.string(from: snapshot.fetchedAt))
                    }
                }
                Spacer()
            }
            if let message = appHost.catalog.detailMessage {
                Text(message)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            } else if case .missing = appHost.catalog {
                Text("Catalog metadata has not been fetched yet. Refresh Metadata to fetch it.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            if let snapshot = appHost.catalog.snapshot, !snapshot.records.isEmpty {
                catalogResults(snapshot)
            }
        }
    }

    @ViewBuilder
    private var catalogHeader: some View {
        Text("Catalog metadata").font(WorkbenchTypography.emphasis)
        Spacer()
        Button(appHost.isRefreshingCatalog ? "Refreshing…" : "Refresh Metadata") {
            Task { await appHost.refreshCatalog() }
        }
        .buttonStyle(.bordered)
        .disabled(appHost.catalogRefreshUnavailableReason != nil)
        .help(appHost.catalogRefreshUnavailableReason ?? "Fetch catalog metadata from the configured provider.")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Discovery")
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.muted)
            Text("Choose a role to find Hugging Face repositories. Browsing reads metadata without downloading or loading models. Add from Hugging Face… opens a separate review before downloading.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            switch layout.headerMode {
            case .oneLine:
                HStack(alignment: .center, spacing: WorkbenchSpacing.sm) {
                    roleControl
                    limitControl
                    fastControl
                    Spacer(minLength: WorkbenchSpacing.xs)
                    discoverButton
                }
            case .roleOwnLine:
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    roleControl
                    HStack(alignment: .center, spacing: WorkbenchSpacing.sm) {
                        limitControl
                        fastControl
                        Spacer(minLength: WorkbenchSpacing.xs)
                        discoverButton
                    }
                }
            case .stacked:
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    roleControl
                    limitControl
                    fastControl
                    discoverButton
                }
            }
            Text(fast
                 ? "Fast uses repository names instead of inspecting each model. Sizes and memory-fit estimates may be missing."
                 : "Repository inspection adds size estimates when available. Browsing never runs a model; memory fit remains an estimate.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("discover-inspection-guidance")
        }
    }

    private var roleControl: some View {
        Picker("Role", selection: $role) {
            ForEach(DiscoverRole.choices, id: \.self) { choice in
                Text(DiscoverRole.title(choice)).tag(choice)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("discover-role")
        .fixedSize()
        .disabled(isScouting)
        .help("The task you want the model to handle. Any searches every supported role; the candidate limit applies to each role separately.")
        .accessibilityHint("Choose a task, or Any to search every supported role.")
    }

    private var limitControl: some View {
        Stepper(value: $limit, in: DiscoverLimit.range) {
            Text("Per role: \(limit)")
                .font(WorkbenchTypography.secondaryTabular)
        }
        .fixedSize()
        .help("Candidates requested for each role; with Any the total can be several times this.")
        .disabled(isScouting)
    }

    private var fastControl: some View {
        Toggle("Fast", isOn: $fast)
            .help("Skips repository inspection: quicker, but sizes may be missing.")
            .disabled(isScouting)
    }

    private var discoverButton: some View {
        Button("Discover") { discover() }
            .buttonStyle(.workbenchPrimary)
            .disabled(isScouting)
    }

    private func catalogResults(_ snapshot: CatalogSnapshot) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack {
                SectionTitle(text: "Catalog Entries (\(snapshot.records.count))")
                Spacer()
                Text("Remote metadata only")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            List(snapshot.records, id: \.self) { record in
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text(record.repoIdentity)
                        .font(WorkbenchTypography.body)
                    HStack(spacing: WorkbenchSpacing.xs) {
                        if let roles = record.roles, !roles.isEmpty {
                            Text(roles.map(\.title).joined(separator: ", "))
                                .font(WorkbenchTypography.secondary)
                                .foregroundStyle(WorkbenchColor.muted)
                        }
                        if !record.formats.isEmpty {
                            Text(record.formats.joined(separator: ", "))
                                .font(WorkbenchTypography.secondary)
                                .foregroundStyle(WorkbenchColor.muted)
                        }
                        Text(Self.timestampFormatter.string(from: record.updatedAt))
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.muted)
                    }
                    Text(record.sourceURL.absoluteString)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                        .textSelection(.enabled)
                }
                .padding(.vertical, WorkbenchSpacing.xxxs)
            }
            .frame(height: 240)
        }
    }

    private func discover() {
        session.start(DiscoveryRequest(role: role, limit: limit, fast: fast))
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
            Text("\(label):")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            Text(value)
                .font(WorkbenchTypography.secondary)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
