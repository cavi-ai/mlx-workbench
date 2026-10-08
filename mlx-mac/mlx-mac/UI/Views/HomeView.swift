import AppKit
import SwiftUI

enum HomeNextActionKind: Equatable { case configure, scan, activity, prepare(String), run(String), library }

struct HomeNextAction: Equatable {
    let kind: HomeNextActionKind
    let title: String
    let reason: String
    let route: String

    /// The verb phrase for the one button; mirrors what `HomeView.perform` does.
    var buttonTitle: String {
        switch kind {
        case .configure: return "Open Settings"
        case .scan: return "Open Library"
        case .activity: return "Open Activity"
        case .prepare: return "Prepare"
        case .run: return "Run"
        case .library: return route == AppRoute.reclaim.rawValue ? "Open Reclaim" : "Open Library"
        }
    }

    static func derive(workflow: ConversionWorkflow, snapshot: LibrarySnapshot?, rootsConfigured: Bool, isScanning: Bool, lastError: String?, agentReady: Bool, convertRuntimeReady: Bool, serveRuntimeReady: Bool, reclaimableBytes: Int64 = 0, diskFreeFraction: Double? = nil) -> HomeNextAction {
        if workflow.state == .queued || workflow.state == .running { return .init(kind: .activity, title: "Monitor conversion", reason: "A conversion is \(workflow.state.rawValue); Activity has the authoritative receipt and live status.", route: AppRoute.activity.rawValue) }
        if workflow.state == .verifying { return .init(kind: .activity, title: "Verify conversion output", reason: "The canary suite is checking the MLX output before it is marked verified.", route: AppRoute.activity.rawValue) }
        if workflow.state == .verificationFailed { return .init(kind: .activity, title: "Resolve verification failure", reason: workflow.errorMessage ?? "The converted output failed the canary suite; Activity has the failing evidence.", route: AppRoute.activity.rawValue) }
        if workflow.state == .failed { return .init(kind: .activity, title: "Resolve conversion failure", reason: workflow.errorMessage ?? workflow.message ?? "The current conversion needs attention in Activity.", route: AppRoute.activity.rawValue) }
        if let path = workflow.completedModelPath, !path.isEmpty {
            let completed = snapshot?.models.first(where: { $0.item.path == path || $0.outputPaths.contains(path) })
            guard workflow.state == .completed || workflow.state == .verified, let completed, completed.readiness == .ready else { return .init(kind: .activity, title: "Reconcile completed output", reason: "The completed workflow no longer matches a ready model in the current Library snapshot.", route: AppRoute.activity.rawValue) }
            if !ModelTaskPresentation.isServable(completed) {
                let type = completed.item.task?.type ?? .other
                let reason = type == .imageGeneration
                    ? "Conversion completed; generate images from the model's Library inspector."
                    : "Conversion completed; \(type.title.lowercased()) models are used from the Library inspector, not served."
                return .init(kind: .library, title: "Open the completed model", reason: reason, route: AppRoute.library.rawValue)
            }
            guard agentReady && serveRuntimeReady else { return .init(kind: .configure, title: "Repair the Run runtime", reason: "The model is complete, but the agent or serving runtime is unavailable.", route: AppRoute.settings.rawValue) }
            return .init(kind: .run(path), title: "Run completed model", reason: "Conversion completed and the selected MLX output is ready for a serve preview.", route: AppRoute.run.rawValue)
        }
        guard rootsConfigured else { return .init(kind: .configure, title: "Configure model roots", reason: "No GGUF or MLX roots are configured, so the library has nowhere to scan.", route: AppRoute.settings.rawValue) }
        guard agentReady else { return .init(kind: .configure, title: "Configure mlx-agent", reason: "The local agent is unavailable; Settings contains the path needed for scan, prepare, and run.", route: AppRoute.settings.rawValue) }
        if let error = lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty { return .init(kind: .scan, title: "Resolve the library scan", reason: error, route: AppRoute.library.rawValue) }
        guard let snapshot else { return .init(kind: .scan, title: isScanning ? "View library scan" : "Scan the model library", reason: isScanning ? "The first authoritative library scan is in progress." : "No successful library snapshot exists yet.", route: AppRoute.library.rawValue) }
        if let source = snapshot.models.first(where: { $0.readiness == .needsConversion }) {
            guard convertRuntimeReady else { return .init(kind: .configure, title: "Repair the Prepare runtime", reason: "A GGUF source needs conversion, but the conversion runtime is unavailable.", route: AppRoute.settings.rawValue) }
            return .init(kind: .prepare(source.item.path), title: "Prepare a GGUF model", reason: "The latest Library snapshot contains a GGUF source that needs MLX conversion.", route: AppRoute.prepare.rawValue)
        }
        if reclaimableBytes >= ReclaimAdvisor.badgeThresholdBytes, let free = diskFreeFraction, free < 0.15 { let amount = ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file); return .init(kind: .library, title: "Reclaim " + amount + " of disk", reason: "Reclaim opportunities exceed the threshold and the disk is under 15% free. Reclaim ranks evidence; quarantine moves, never deletes.", route: AppRoute.reclaim.rawValue) }
        return .init(kind: .library, title: "Review the model library", reason: snapshot.models.isEmpty ? "The latest scan found no local models." : "The latest scan found models, but none are currently ready to run or prepare.", route: AppRoute.library.rawValue)
    }
}

enum ModelFlightStage: String, CaseIterable, Identifiable {
    case discovered, prepared, verified, measured, serving
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbolName: String { switch self { case .discovered: return "scope"; case .prepared: return "shippingbox"; case .verified: return "checkmark.shield"; case .measured: return "chart.bar"; case .serving: return "antenna.radiowaves.left.and.right" } }
}

enum ModelFlightStageState: Equatable {
    case pending, active, complete, attention, failed

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .active: return "In progress"
        case .complete: return "Complete"
        case .attention: return "Attention"
        case .failed: return "Failed"
        }
    }
}

struct ModelFlightStagePresentation: Equatable, Identifiable {
    let stage: ModelFlightStage
    let state: ModelFlightStageState
    let detail: String
    var id: ModelFlightStage { stage }
}

/// Pure Overview presentation state. Success is only derived from current
/// snapshot/readiness, exact verification evidence, completed measured results,
/// and endpoint state plus authoritative running server receipts.
struct ModelFlightPathPresentation: Equatable {
    let modelPath: String?
    let stages: [ModelFlightStagePresentation]

    static func selectedModel(in snapshot: LibrarySnapshot?, selectedModelPath: String?) -> LibraryModel? {
        guard let selectedModelPath, !selectedModelPath.isEmpty else { return nil }
        return snapshot?.models.first {
            $0.item.path == selectedModelPath || $0.outputPaths.contains(selectedModelPath)
        }
    }

    static func derive(model: LibraryModel?, verification: VerificationStatus, completedRuns: [ComparisonRun], endpointState: EndpointState, servers: [ServerInfo]) -> Self {
        guard let model else { return .init(modelPath: nil, stages: ModelFlightStage.allCases.map { .init(stage: $0, state: .pending, detail: "Awaiting a model in the current Library snapshot.") }) }
        let path = model.item.path
        let signature = model.item.signature
        let prepared = model.readiness == .ready
        let verificationState: ModelFlightStageState
        let verificationDetail: String
        switch verification {
        case .verified:
            verificationState = .complete
            verificationDetail = "Canary report matches this model signature."
        case .failed(let report):
            verificationState = .failed
            verificationDetail = report.outcome.summary
        case .keptAnyway:
            verificationState = .attention
            verificationDetail = "The model was kept despite failed verification."
        case .stale:
            verificationState = .attention
            verificationDetail = "Verification evidence is stale for this model or environment."
        case .unverified:
            verificationState = .pending
            verificationDetail = "No matching successful canary report yet."
        case .inProgress:
            verificationState = .active
            verificationDetail = "The canary suite is running."
        }
        let measured = completedRuns.contains { run in run.state == .completed && run.results.contains { result in result.modelPath == path && result.modelSignature == signature && result.error == nil && !result.samples.isEmpty } }
        let serverConfirms = servers.contains { $0.state?.lowercased() == "running" && HFRepoID.matches($0.modelIdentity, path) }
        let stateConfirms: Bool
        if case .running(let servedPath, _) = endpointState { stateConfirms = HFRepoID.matches(servedPath, path) } else { stateConfirms = false }
        let serving = serverConfirms && stateConfirms
        return .init(modelPath: path, stages: [
            .init(stage: .discovered, state: .complete, detail: "Present in the latest Library snapshot."),
            .init(stage: .prepared, state: prepared ? .complete : .pending, detail: prepared ? "Library readiness is Ready." : "Library readiness is \(model.readiness.title)."),
            .init(stage: .verified, state: verificationState, detail: verificationDetail),
            .init(stage: .measured, state: measured ? .complete : .pending, detail: measured ? "A completed comparison result matches path and signature." : "No completed comparison result matches path and signature."),
            .init(stage: .serving, state: serving ? .complete : .pending, detail: serving ? "Endpoint state and authoritative server agree on this identity." : "Endpoint state and server receipts do not both confirm this identity.")
        ])
    }
}

struct HomeView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var modelWorkflow: ModelWorkflowCoordinator
    @ObservedObject private var watch: WatchCoordinator
    private let onRouteSelection: (AppRoute) -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var contentWidth = WorkbenchSize.assumedContentWidth

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        _modelWorkflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _watch = ObservedObject(wrappedValue: appHost.watch)
        self.onRouteSelection = onRouteSelection
    }

    private var ggufRoots: [String] {
        if let roots = appHost.scanResult?.roots?.gguf, !roots.isEmpty { return roots }
        return appHost.config.ggufRoots.isEmpty ? appHost.discoveredRoots : appHost.config.ggufRoots
    }

    private var mlxRoots: [String] {
        appHost.scanResult?.roots?.mlx ?? appHost.config.mlxRoots
    }

    private var agentReady: Bool {
        if case .ready = appHost.agentHealth { return true }
        return false
    }

    private var nextAction: HomeNextAction {
        HomeNextAction.derive(
            workflow: modelWorkflow.workflow,
            snapshot: appHost.librarySnapshot,
            rootsConfigured: !ggufRoots.isEmpty || !mlxRoots.isEmpty,
            isScanning: appHost.isScanning,
            lastError: appHost.lastError,
            agentReady: agentReady,
            convertRuntimeReady: appHost.runtimeReport.convert.ok,
            serveRuntimeReady: appHost.runtimeReport.serve.ok,
            reclaimableBytes: appHost.reclaim.totalReclaimableBytes,
            diskFreeFraction: DiskProbe.freeFraction()
        )
    }

    private var selectedModel: LibraryModel? {
        ModelFlightPathPresentation.selectedModel(
            in: appHost.librarySnapshot,
            selectedModelPath: appHost.selectedModelPath
        )
    }

    private var flightPath: ModelFlightPathPresentation {
        let model = selectedModel
        let verification = model.map {
            appHost.verification.status(for: $0.item.path, signature: $0.item.signature)
        } ?? .unverified
        return .derive(
            model: model,
            verification: verification,
            completedRuns: appHost.comparison.runs,
            endpointState: appHost.endpoint.state,
            servers: modelWorkflow.servers
        )
    }

    private var layoutMode: OverviewLayoutMode {
        OverviewLayoutMode(contentWidth: contentWidth)
    }

    var body: some View {
        ScrollView {
            regions
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: OverviewContentWidthKey.self, value: proxy.size.width)
                    }
                }
                .frame(maxWidth: WorkbenchSize.contentMaxWidth)
                .padding(WorkbenchSpacing.pageInset)
                .frame(maxWidth: .infinity)
        }
        .onPreferenceChange(OverviewContentWidthKey.self) { contentWidth = $0 }
        .onAppear { appHost.analyzeReclaim() }
    }

    private var regions: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
            hero
            FlightPathPanel(
                model: selectedModel,
                flightPath: flightPath,
                showsStateText: OverviewLayoutMode.showsStageState(contentWidth: contentWidth),
                chooseModel: { onRouteSelection(.library) }
            )
            LibraryStrip(
                presentation: LibraryStripPresentation(
                    snapshot: appHost.librarySnapshot,
                    rootCount: ggufRoots.count + mlxRoots.count,
                    reclaimableBytes: appHost.reclaim.totalReclaimableBytes,
                    runs: appHost.comparison.runs
                ),
                showsCaptions: OverviewLayoutMode.showsTileCaptions(contentWidth: contentWidth),
                open: openStripDestination
            )
            if !appHost.runtimeReport.ok {
                runtimeWarning
            }
            lowerRow
        }
    }

    private var hero: some View {
        let action = nextAction
        let instrument = ModelBudgetInstrument(
            resources: appHost.resources,
            reserveGB: appHost.config.fitReserveGB,
            model: selectedModel,
            hardware: appHost.hardwareProfile
        )
        let nextStep = NextStepPanel(action: action) { perform(action) }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                instrument
                    .frame(minWidth: WorkbenchSize.instrumentMinimum, idealWidth: WorkbenchSize.instrumentMinimum, maxWidth: .infinity)
                nextStep
                    .frame(minWidth: WorkbenchSize.nextStepMinimum, idealWidth: WorkbenchSize.nextStepMinimum, maxWidth: WorkbenchSize.nextStepMaximum)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: WorkbenchSize.heroRowMinimum)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                instrument
                nextStep
            }
        }
    }

    private var runtimeWarning: some View {
        InlineMessage(
            kind: .warning,
            text: "The convert and serve runtime needs setup.",
            action: (title: "Open Health", perform: { onRouteSelection(.health) })
        )
    }

    @ViewBuilder
    private var lowerRow: some View {
        let alerts = watch.activeAlerts
        let rows = recommendationRows
        if layoutMode.usesTwoColumnLowerRow && !alerts.isEmpty && !rows.isEmpty {
            HStack(alignment: .top, spacing: WorkbenchSpacing.lg) {
                alertsPanel(alerts)
                RecommendationsPanel(rows: rows)
            }
        } else if !alerts.isEmpty || !rows.isEmpty {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                if !alerts.isEmpty { alertsPanel(alerts) }
                if !rows.isEmpty { RecommendationsPanel(rows: rows) }
            }
        }
    }

    private func alertsPanel(_ alerts: [WatchAlert]) -> some View {
        WatchAlertsPanel(
            alerts: alerts,
            onAction: { kind, alert in perform(kind, on: alert) },
            onSnooze: { watch.snooze($0.id) },
            onMute: { watch.mute($0.id) }
        )
    }

    private var recommendationRows: [OverviewRecommendationRow] {
        guard appHost.librarySnapshot != nil else { return [] }
        return UseCase.allCases.compactMap { useCase in
            guard let recommendation = appHost.recommendations(for: useCase).first,
                  let model = appHost.model(for: recommendation) else { return nil }
            return OverviewRecommendationRow(
                useCase: useCase.title,
                modelName: model.displayName,
                confidence: recommendation.confidence.title,
                reason: recommendation.reasons.first?.message ?? "Ranked from the current local snapshot."
            )
        }
    }

    private func openStripDestination(_ index: Int) {
        let routes: [AppRoute] = [.library, .reclaim, .compare]
        guard routes.indices.contains(index) else { return }
        onRouteSelection(routes[index])
    }

    private func perform(_ action: WatchAlertPresentation.ActionKind, on alert: WatchAlert) {
        switch action {
        case .addFromHuggingFace(let repo):
            appHost.intake.open(with: repo)
            openWindow(id: IntakeWindow.id)
            watch.dismiss(alert.id)
        case .openOnHuggingFace(let repo):
            if let url = URL(string: "https://huggingface.co/\(repo)") { NSWorkspace.shared.open(url) }
        case .reverify:
            watch.act(on: alert.id)
        }
    }

    private func perform(_ action: HomeNextAction) {
        switch action.kind {
        case .run(let path):
            appHost.selectedModelPath = path
            if let model = appHost.librarySnapshot?.models.first(where: { $0.item.path == path || $0.outputPaths.contains(path) }) {
                modelWorkflow.prepareServe(model: model, exactPath: path)
            }
        case .prepare(let path):
            appHost.selectedModelPath = path
            if let model = appHost.librarySnapshot?.models.first(where: { $0.item.path == path }) {
                modelWorkflow.inspect(source: model.item, snapshot: appHost.librarySnapshot)
            }
        case .configure, .scan, .activity, .library:
            break
        }
        onRouteSelection(AppRoute(rawID: action.route))
    }
}
