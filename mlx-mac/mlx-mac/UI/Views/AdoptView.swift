import SwiftUI

struct AdoptView: View {
    @ObservedObject var appHost: AppHost
    @Environment(\.isRouteActive) private var isRouteActive
    @Environment(\.openWindow) private var openWindow

    private let resources: SystemResourceMonitor
    private let onRouteSelection: (AppRoute) -> Void

    struct WorkflowContext {
        let requestedRole: String
        let statePath: String
        var response: AdoptResult?
    }

    enum Operation {
        case start, refresh

        var label: String {
            switch self {
            case .start: return "Starting adoption…"
            case .refresh: return "Refreshing status…"
            }
        }
    }

    @State private var role = AdoptRole.initial
    @State private var fast = false
    @State private var offline = false
    @State private var operation: Operation?
    @State private var workflow: WorkflowContext?
    @State private var errorMessage: String?
    @State private var isLastKnownState = false

    /// `resources` and the seed let a render hold the page at a fixed budget and result.
    init(
        appHost: AppHost,
        resources: SystemResourceMonitor? = nil,
        onRouteSelection: @escaping (AppRoute) -> Void = { _ in },
        seedWorkflow: WorkflowContext? = nil,
        seedOperation: Operation? = nil,
        seedError: String? = nil,
        seedLastKnown: Bool = false
    ) {
        self.appHost = appHost
        self.resources = resources ?? appHost.resources
        self.onRouteSelection = onRouteSelection
        _workflow = State(initialValue: seedWorkflow)
        _operation = State(initialValue: seedOperation)
        _errorMessage = State(initialValue: seedError)
        _isLastKnownState = State(initialValue: seedLastKnown)
    }

    private var isBusy: Bool { operation != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
            controls
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                    AdoptRecommendationView(
                        resources: resources,
                        intake: appHost.intake,
                        requestedRole: workflow?.requestedRole,
                        response: workflow?.response,
                        isLastKnown: isLastKnownState,
                        library: appHost.librarySnapshot,
                        reserveGB: appHost.config.fitReserveGB,
                        hardware: appHost.hardwareProfile,
                        onRun: run,
                        onAdd: addFromHuggingFace
                    )
                    ErrorBanner(text: errorMessage)
                    if let workflow {
                        workflowDetails(workflow)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, WorkbenchSpacing.pageInset)
            }
        }
        .frame(maxWidth: WorkbenchSize.contentMaxWidth)
        .padding(WorkbenchSpacing.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Adopt a role")
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.muted)
            ReclaimFlowLayout(spacing: WorkbenchSpacing.sm, lineSpacing: WorkbenchSpacing.xs) {
                Picker("Role", selection: $role) {
                    ForEach(AdoptRole.choices, id: \.self) { choice in
                        Text(AdoptRole.title(choice)).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(isBusy)
                .accessibilityIdentifier("adopt-role")
                Toggle("Fast", isOn: $fast)
                    .help("Heuristic-only discovery enrichment")
                    .disabled(isBusy)
                Toggle("Offline", isOn: $offline)
                    .help("Cached discovery; no metadata network requests")
                    .disabled(isBusy)
                Button("Start") { startAdopt() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(isRouteActive ? .defaultAction : nil)
                    .disabled(!isRouteActive || isBusy || !AdoptRole.choices.contains(role))
                    .help("Start adoption in a new state file for the selected role.")
                    .accessibilityIdentifier("adopt-start")
                Button("Refresh") { refreshStatus() }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || workflow == nil)
                    .help(workflow == nil ? "Start adoption before refreshing its status." : "Refresh the captured workflow's state file.")
                    .accessibilityIdentifier("adopt-refresh")
            }
            HStack {
                if let operation {
                    ProgressView(operation.label)
                        .controlSize(.small)
                        .accessibilityIdentifier("adopt-progress")
                }
            }
            .frame(minHeight: WorkbenchSpacing.lg, alignment: .leading)
        }
    }

    private func workflowDetails(_ workflow: WorkflowContext) -> some View {
        DisclosureGroup("Workflow details") {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                detail("State path", value: workflow.statePath, identifier: "adopt-state-path")
                if let response = workflow.response {
                    if let value = response.workflowID { detail("Workflow ID", value: value) }
                    if let value = response.manager { detail("Manager", value: value) }
                }
            }
            .padding(.top, WorkbenchSpacing.sm)
        }
        .font(WorkbenchTypography.secondary)
    }

    private func detail(_ label: String, value: String, identifier: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(label)
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.muted)
            Text(value)
                .font(label == "State path" || label == "Workflow ID" ? WorkbenchTypography.value : WorkbenchTypography.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier ?? "adopt-detail-\(label)")
        }
    }

    private func run(_ model: LibraryModel) {
        appHost.selectedModelPath = model.item.path
        appHost.modelWorkflow.prepareServe(model: model, exactPath: model.item.path)
        onRouteSelection(.run)
    }

    private func addFromHuggingFace(_ repo: String) {
        DiscoverIntakeAction.perform(repo: repo, intake: appHost.intake) { openWindow(id: IntakeWindow.id) }
    }

    private func startAdopt() {
        guard isRouteActive, !isBusy, AdoptRole.choices.contains(role) else { return }
        let statePath = URL(fileURLWithPath: appHost.configPath)
            .deletingLastPathComponent()
            .appendingPathComponent("adoptions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json").path
        let requestedRole = role, requestedFast = fast, requestedOffline = offline
        workflow = WorkflowContext(requestedRole: requestedRole, statePath: statePath)
        errorMessage = nil
        isLastKnownState = false
        operation = .start
        Task {
            defer { operation = nil }
            do {
                workflow?.response = try await appHost.api.adoptStart(
                    role: requestedRole, state: statePath, fast: requestedFast, offline: requestedOffline
                )
            } catch {
                errorMessage = "Adoption failed. \(error.localizedDescription) Start again to try a new workflow, or refresh this state file."
            }
        }
    }

    private func refreshStatus() {
        guard !isBusy, let workflow else { return }
        let statePath = workflow.statePath
        errorMessage = nil
        isLastKnownState = workflow.response != nil
        operation = .refresh
        Task {
            defer { operation = nil }
            do {
                self.workflow?.response = try await appHost.api.adoptStatus(state: statePath)
                isLastKnownState = false
            } catch {
                isLastKnownState = self.workflow?.response != nil
                errorMessage = "Status refresh failed. \(error.localizedDescription) Refresh to try again."
            }
        }
    }
}

// MARK: - Recommendation

/// The requested role, the reported repository and what to do with it. Observes the
/// intake coordinator for the Add action; the memory monitor is observed only by the fit view.
struct AdoptRecommendationView: View {
    let resources: SystemResourceMonitor
    @ObservedObject var intake: IntakeCoordinator
    let requestedRole: String?
    let response: AdoptResult?
    let isLastKnown: Bool
    let library: LibrarySnapshot?
    let reserveGB: Double
    let hardware: HardwareProfile
    let onRun: (LibraryModel) -> Void
    let onAdd: (String) -> Void

    private var state: AdoptRecommendationState {
        AdoptRecommendationState.make(response: response, library: library, intakeIsBusy: intake.isBusy)
    }

    var body: some View {
        let state = state
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                if isLastKnown {
                    Label("Last known state", systemImage: "clock.arrow.circlepath")
                        .font(WorkbenchTypography.emphasis)
                        .foregroundStyle(WorkbenchColor.muted)
                        .accessibilityIdentifier("adopt-last-known")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: WorkbenchSpacing.lg) {
                        roleBlock.fixedSize(horizontal: true, vertical: false)
                        Image(systemName: "arrow.right")
                            .font(WorkbenchTypography.section)
                            .foregroundStyle(WorkbenchColor.accent)
                            .accessibilityHidden(true)
                        modelBlock(state)
                            .frame(minWidth: WorkbenchSize.instrumentMinimum, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                        roleBlock
                        modelBlock(state)
                    }
                }
                if case .recommended(let repo, let step) = state {
                    nextStep(step, repo: repo)
                }
                outcome
                if let message = response?.message, !message.isEmpty {
                    Text(message)
                        .font(WorkbenchTypography.body)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var roleBlock: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text("Requested role")
                .font(WorkbenchTypography.metadata)
                .foregroundStyle(WorkbenchColor.muted)
            Text(requestedRole.map(AdoptRole.title) ?? "No role requested")
                .font(WorkbenchTypography.section)
                .accessibilityIdentifier("adopt-requested-role")
        }
    }

    private func modelBlock(_ state: AdoptRecommendationState) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text("Recommendation")
                .font(WorkbenchTypography.metadata)
                .foregroundStyle(WorkbenchColor.muted)
            Group {
                switch state {
                case .idle:
                    Text(AdoptRecommendationState.idleSentence)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                case .noRecommendation:
                    Text(AdoptRecommendationState.noRecommendationSentence)
                        .font(WorkbenchTypography.body)
                case .recommended(let repo, _):
                    Text(repo)
                        .font(WorkbenchTypography.section)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier("adopt-model")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, WorkbenchSpacing.md)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(WorkbenchColor.accent)
                .frame(width: WorkbenchSize.markerWidth)
        }
    }

    @ViewBuilder
    private func nextStep(_ step: AdoptNextStep, repo: String) -> some View {
        switch step {
        case .inLibrary(let model, let canRun):
            ReclaimFlowLayout(spacing: WorkbenchSpacing.lg, lineSpacing: WorkbenchSpacing.sm) {
                Label("In Library", systemImage: "checkmark.circle.fill")
                    .font(WorkbenchTypography.emphasis)
                    .symbolRenderingMode(.hierarchical)
                AdoptFitView(resources: resources, model: model, reserveGB: reserveGB, hardware: hardware)
                if canRun {
                    Button("Run…") { onRun(model) }
                        .buttonStyle(.bordered)
                        .help("Prepare this model on the Run tab")
                }
            }
        case .addFromHuggingFace(let enabled, let help):
            Button(DiscoverIntakeAction.title) { onAdd(repo) }
                .buttonStyle(.bordered)
                .disabled(!enabled)
                .help(help)
        }
    }

    @ViewBuilder
    private var outcome: some View {
        let items = AdoptOutcome.items(response)
        if !items.isEmpty {
            ReclaimFlowLayout(spacing: WorkbenchSpacing.lg, lineSpacing: WorkbenchSpacing.xs) {
                ForEach(items, id: \.label) { item in
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                        Text(item.figure)
                            .font(WorkbenchTypography.tabular)
                            .foregroundStyle(WorkbenchColor.ink)
                            .textSelection(.enabled)
                        Text(item.label)
                            .font(WorkbenchTypography.metadata)
                            .foregroundStyle(WorkbenchColor.muted)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityIdentifier("adopt-outcome")
        }
    }
}

// MARK: - Fit

/// The in-Library model's fit now. The only Adopt view that observes the memory monitor.
struct AdoptFitView: View {
    @ObservedObject var resources: SystemResourceMonitor
    let model: LibraryModel
    let reserveGB: Double
    let hardware: HardwareProfile

    var body: some View {
        let fit = LibraryFitPresentation.make(
            model: model, memory: resources.memory, hasProbed: resources.hasProbed,
            contextTokens: resources.contextTokens, reserveGB: reserveGB, hardware: hardware
        )
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(fit.word)
                .font(WorkbenchTypography.emphasis)
                .foregroundStyle(fit.tone == .fits ? WorkbenchColor.ink : (fit.tone == .neutral ? WorkbenchColor.muted : fit.tone.color))
                .redacted(reason: fit.state == .redacted ? .placeholder : [])
            if fit.state == .estimated || fit.state == .redacted {
                DiscoverFitBar(fill: fit.fill, tone: fit.tone)
                    .frame(width: WorkbenchSize.Discover.barWidth)
            }
        }
        .help(fit.help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(fit.accessibilityLabel)
    }
}
