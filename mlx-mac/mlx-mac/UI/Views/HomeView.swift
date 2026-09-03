import SwiftUI

enum HomeNextActionKind: Equatable { case configure, scan, activity, prepare(String), run(String), library }

struct HomeNextAction: Equatable {
    let kind: HomeNextActionKind
    let title: String
    let reason: String
    let route: String

    static func derive(workflow: ConversionWorkflow, snapshot: LibrarySnapshot?, rootsConfigured: Bool, isScanning: Bool, lastError: String?, agentReady: Bool, convertRuntimeReady: Bool, serveRuntimeReady: Bool, reclaimableBytes: Int64 = 0, diskFreeFraction: Double? = nil) -> HomeNextAction {
        if workflow.state == .queued || workflow.state == .running { return .init(kind: .activity, title: "Monitor conversion", reason: "A conversion is \(workflow.state.rawValue); Activity has the authoritative receipt and live status.", route: AppRoute.activity.rawValue) }
        if workflow.state == .verifying { return .init(kind: .activity, title: "Verify conversion output", reason: "The canary suite is checking the MLX output before it is marked verified.", route: AppRoute.activity.rawValue) }
        if workflow.state == .verificationFailed { return .init(kind: .activity, title: "Resolve verification failure", reason: workflow.errorMessage ?? "The converted output failed the canary suite; Activity has the failing evidence.", route: AppRoute.activity.rawValue) }
        if workflow.state == .failed { return .init(kind: .activity, title: "Resolve conversion failure", reason: workflow.errorMessage ?? workflow.message ?? "The current conversion needs attention in Activity.", route: AppRoute.activity.rawValue) }
        if let path = workflow.completedModelPath, !path.isEmpty {
            guard workflow.state == .completed || workflow.state == .verified, snapshot?.models.first(where: { $0.item.path == path || $0.outputPaths.contains(path) })?.readiness == .ready else { return .init(kind: .activity, title: "Reconcile completed output", reason: "The completed workflow no longer matches a ready model in the current Library snapshot.", route: AppRoute.activity.rawValue) }
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
    case pending, complete, attention, failed
    var label: String { switch self { case .pending: return "Pending"; case .complete: return "Complete"; case .attention: return "Attention"; case .failed: return "Failed" } }
    var color: Color { switch self { case .pending: return WorkbenchColor.thermalAmber; case .complete: return WorkbenchColor.verifiedGreen; case .attention: return WorkbenchColor.thermalAmber; case .failed: return WorkbenchColor.systemRed } }
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
            verificationState = .pending
            verificationDetail = "The canary suite is running."
        }
        let measured = completedRuns.contains { run in run.state == .completed && run.results.contains { result in result.modelPath == path && result.modelSignature == signature && result.error == nil && !result.samples.isEmpty } }
        let identity = HFRepoID.serveIdentity(for: path)
        let serverConfirms = servers.contains { $0.state?.lowercased() == "running" && HFRepoID.serveIdentity(for: $0.repo ?? "") == identity }
        let stateConfirms: Bool
        if case .running(let servedPath, _) = endpointState { stateConfirms = HFRepoID.serveIdentity(for: servedPath) == identity } else { stateConfirms = false }
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
    private let onRouteSelection: (String) -> Void

    init(appHost: AppHost, onRouteSelection: @escaping (String) -> Void = { _ in }) { self.appHost = appHost; _modelWorkflow = ObservedObject(wrappedValue: appHost.modelWorkflow); _watch = ObservedObject(wrappedValue: appHost.watch); self.onRouteSelection = onRouteSelection }
    private var ggufRoots: [String] { if let roots = appHost.scanResult?.roots?.gguf, !roots.isEmpty { return roots }; return appHost.config.ggufRoots.isEmpty ? appHost.discoveredRoots : appHost.config.ggufRoots }
    private var mlxRoots: [String] { appHost.scanResult?.roots?.mlx ?? appHost.config.mlxRoots }
    private var agentReady: Bool { if case .ready = appHost.agentHealth { return true }; return false }
    private var nextAction: HomeNextAction { HomeNextAction.derive(workflow: modelWorkflow.workflow, snapshot: appHost.librarySnapshot, rootsConfigured: !ggufRoots.isEmpty || !mlxRoots.isEmpty, isScanning: appHost.isScanning, lastError: appHost.lastError, agentReady: agentReady, convertRuntimeReady: appHost.runtimeReport.convert.ok, serveRuntimeReady: appHost.runtimeReport.serve.ok, reclaimableBytes: appHost.reclaim.totalReclaimableBytes, diskFreeFraction: DiskProbe.freeFraction()) }
    private var flightPath: ModelFlightPathPresentation {
        let model = ModelFlightPathPresentation.selectedModel(
            in: appHost.librarySnapshot,
            selectedModelPath: appHost.selectedModelPath
        )
        return .derive(model: model, verification: model.map { appHost.verification.status(for: $0.item.path, signature: $0.item.signature) } ?? .unverified, completedRuns: appHost.comparison.runs, endpointState: appHost.endpoint.state, servers: modelWorkflow.servers)
    }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) { Text("WORKBENCH / OVERVIEW").font(WorkbenchTypography.monoUtility).foregroundColor(WorkbenchColor.fluxTeal).tracking(0.8); nextActionSurface; workspaceContext; flightPathSurface; alertsSection; statusSurface; recommendationEvidence }.padding(WorkbenchSpacing.pageInset).frame(maxWidth: .infinity, alignment: .leading) }.background(WorkbenchColor.alloyCanvas).onAppear { appHost.analyzeReclaim() }
    }

    private var nextActionSurface: some View { WorkbenchSurface { VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) { HStack(alignment: .firstTextBaseline) { VStack(alignment: .leading, spacing: 4) { Text("NEXT SAFE ACTION").font(WorkbenchTypography.monoUtility).foregroundColor(WorkbenchColor.fluxTeal); Text(nextAction.title).font(WorkbenchTypography.section) }; Spacer(); StatusBadge(status: nextActionStatus) }; Text(nextAction.reason).font(WorkbenchTypography.body).foregroundColor(WorkbenchColor.graphiteMuted).fixedSize(horizontal: false, vertical: true); Button(nextAction.title) { perform(nextAction) }.buttonStyle(.borderedProminent).accessibilityLabel("Next safe action: " + nextAction.title) } } }
    private var nextActionStatus: WorkbenchStatus {
        switch nextAction.kind {
        case .configure, .scan:
            return .warning
        case .activity:
            switch modelWorkflow.workflow.state {
            case .queued: return .queued
            case .running: return .running
            case .verifying: return WorkbenchStatus(rawValue: ConversionWorkflowState.verifying.rawValue)
            case .verificationFailed, .failed: return .failure
            default: return .warning
            }
        case .prepare, .run:
            return .ready
        case .library:
            return .pending
        }
    }

    private var workspaceContext: some View { WorkbenchSurface { VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) { Text("MODEL WORKSPACE").font(WorkbenchTypography.monoUtility).foregroundColor(WorkbenchColor.fluxTeal); HStack(alignment: .top, spacing: WorkbenchSpacing.xl) { instrumentValue("LIBRARY", appHost.librarySnapshot.map { String($0.models.count) + " models" } ?? "No snapshot", appHost.librarySnapshot.map { "Scanned " + timestamp($0.generatedAt) } ?? "Awaiting authoritative scan"); instrumentValue("HARDWARE", appHost.librarySnapshot?.hardware.chip ?? appHost.hardwareProfile.chip ?? "Unknown chip", appHost.librarySnapshot?.hardware.memoryBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "Memory unknown"); instrumentValue("ROOTS", String(ggufRoots.count + mlxRoots.count) + " configured", ggufRoots.first ?? mlxRoots.first ?? "No root configured") } } } }
    private func instrumentValue(_ label: String, _ value: String, _ detail: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(label).font(WorkbenchTypography.monoUtility).foregroundColor(WorkbenchColor.graphiteMuted); Text(value).font(WorkbenchTypography.section).foregroundColor(WorkbenchColor.graphiteInk); Text(detail).font(WorkbenchTypography.monoUtility).foregroundColor(WorkbenchColor.graphiteMuted).lineLimit(2) }.frame(maxWidth: .infinity, alignment: .leading) }

    private var flightPathSurface: some View { WorkbenchSurface { VStack(alignment: .leading, spacing: WorkbenchSpacing.md) { HStack { VStack(alignment: .leading, spacing: 4) { Text("MODEL FLIGHT PATH").font(WorkbenchTypography.monoUtility).foregroundColor(WorkbenchColor.fluxTeal); Text(flightPath.modelPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Select a model from Library").font(WorkbenchTypography.section) }; Spacer(); if let path = flightPath.modelPath { Text(path).font(WorkbenchTypography.monoUtility).foregroundColor(WorkbenchColor.graphiteMuted).lineLimit(1).truncationMode(.middle) } }; HStack(alignment: .top, spacing: 0) { ForEach(Array(flightPath.stages.enumerated()), id: \.element.id) { index, item in flightStage(item, isLast: index == flightPath.stages.count - 1) } }.accessibilityElement(children: .contain).accessibilityLabel("Model flight path") } } }
    private func flightStage(_ item: ModelFlightStagePresentation, isLast: Bool) -> some View { HStack(alignment: .top, spacing: 6) { VStack(spacing: 6) { Image(systemName: item.stage.symbolName).font(.system(size: 14, weight: .semibold)).foregroundColor(item.state.color).frame(width: 28, height: 28).background(item.state.color.opacity(0.12)).clipShape(Circle()); Text(item.stage.title).font(WorkbenchTypography.monoUtility).foregroundColor(WorkbenchColor.graphiteInk).multilineTextAlignment(.center); Text(item.state.label).font(WorkbenchTypography.monoUtility).foregroundColor(item.state.color) }.frame(maxWidth: .infinity); if !isLast { Rectangle().fill(WorkbenchColor.hairline).frame(height: 1).padding(.top, 14) } }.accessibilityElement(children: .ignore).accessibilityLabel(item.stage.title + ": " + item.state.label + ". " + item.detail) }

    @ViewBuilder private var alertsSection: some View { let alerts = watch.activeAlerts; if !alerts.isEmpty { VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) { SectionTitle(text: "Watch alerts"); ForEach(alerts) { alert in WorkbenchSurface(padding: WorkbenchSpacing.sm) { VStack(alignment: .leading, spacing: 6) { HStack { Text(alert.title).font(WorkbenchTypography.section); Spacer(); StatusBadge(status: .warning) }; Text(alert.body).font(WorkbenchTypography.body).foregroundColor(WorkbenchColor.graphiteMuted); HStack(spacing: 10) { Button("Open") { watch.act(on: alert.id); onRouteSelection(alert.route) }.buttonStyle(.bordered).controlSize(.small); Button("Snooze 7 days") { watch.snooze(alert.id) }.controlSize(.small); Button("Mute") { watch.mute(alert.id) }.controlSize(.small).foregroundColor(WorkbenchColor.graphiteMuted) } } } } } } }
    private var statusSurface: some View { WorkbenchSurface { VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) { SectionTitle(text: "Operational status"); HStack(alignment: .top, spacing: WorkbenchSpacing.xl) { instrumentValue("WORKFLOW", modelWorkflow.workflow.state.rawValue, modelWorkflow.workflow.message ?? "No active conversion message"); instrumentValue("RUNTIME", appHost.runtimeReport.ok ? "Ready" : "Needs attention", appHost.runtimeReport.ok ? "Prepare and Run checks passed" : appHost.runtimeReport.install); instrumentValue("ENDPOINT", endpointStatusLabel, appHost.endpoint.state.summary) } } } }
    private var endpointStatusLabel: String { switch appHost.endpoint.state { case .running: return "Running"; case .disabled: return "Disabled"; case .starting, .waitingForServer: return "Pending"; case .modelMismatch, .degraded: return "Attention" } }
    @ViewBuilder private var recommendationEvidence: some View { if let snapshot = appHost.librarySnapshot { VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) { SectionTitle(text: "Recommendation evidence"); Text("Current Library snapshot: " + timestamp(snapshot.generatedAt)).font(WorkbenchTypography.monoUtility).foregroundColor(WorkbenchColor.graphiteMuted); ForEach(UseCase.allCases) { useCase in if let recommendation = appHost.recommendations(for: useCase).first, let model = appHost.model(for: recommendation) { WorkbenchSurface(padding: WorkbenchSpacing.sm) { HStack(alignment: .top) { Text(useCase.title).font(WorkbenchTypography.monoUtility).frame(width: 145, alignment: .leading); VStack(alignment: .leading, spacing: 3) { Text(model.displayName).font(WorkbenchTypography.section); Text(recommendation.reasons.first?.message ?? "Ranked from the current local snapshot.").font(WorkbenchTypography.body).foregroundColor(WorkbenchColor.graphiteMuted) }; Spacer(); StatusBadge(state: recommendation.confidence.title) } } } } } } }
    private func perform(_ action: HomeNextAction) { switch action.kind { case .run(let path): appHost.selectedModelPath = path; if let model = appHost.librarySnapshot?.models.first(where: { $0.item.path == path || $0.outputPaths.contains(path) }) { modelWorkflow.prepareServe(model: model, exactPath: path) }; case .prepare(let path): appHost.selectedModelPath = path; if let model = appHost.librarySnapshot?.models.first(where: { $0.item.path == path }) { modelWorkflow.inspect(source: model.item, snapshot: appHost.librarySnapshot) }; case .configure, .scan, .activity, .library: break }; onRouteSelection(action.route) }
    private func timestamp(_ date: Date) -> String { let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short; return formatter.string(from: date) }
}
