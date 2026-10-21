import SwiftUI

// MARK: - DoctorView
// Health: the readiness chain plus the doctor findings inventory.
// Prune actions live in Reclaim, which owns the authoritative prune flow.

enum DoctorCheckState: Equatable {
    case notRun
    case running
    case completed(DoctorResult)
    case failed(String)

    var isRunning: Bool { if case .running = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
    var findings: [DoctorFinding] {
        if case .completed(let result) = self { return result.findings ?? [] }
        return []
    }
    var pruneCount: Int {
        if case .completed(let result) = self { return result.prune_count ?? 0 }
        return 0
    }
    var isClean: Bool {
        if case .completed = self { return findings.isEmpty && pruneCount == 0 }
        return false
    }
    var symbol: String {
        switch self {
        case .notRun: return "stethoscope"
        case .running: return "magnifyingglass"
        case .completed: return isClean ? "checkmark.circle" : "exclamationmark.triangle"
        case .failed: return "exclamationmark.triangle"
        }
    }
    var message: String {
        switch self {
        case .notRun: return "Inventory has not been checked. Run doctor to check local model files."
        case .running: return "Checking local model files for inventory issues…"
        case .completed:
            return isClean ? "No inventory issues found in the latest doctor run."
                : "The latest doctor run found inventory issues. Review the findings below."
        case .failed(let message): return "Inventory check failed. \(message) Retry Run doctor after resolving the issue."
        }
    }
}

struct DoctorView: View {
    @ObservedObject var appHost: AppHost
    @Environment(\.isRouteActive) private var isRouteActive
    private let onRouteSelection: (AppRoute) -> Void

    @State private var checkState: DoctorCheckState = .notRun
    @State private var lastCheckedAt: Date?
    @State private var layout = HealthLayout()
    @StateObject private var backends: HealthBackendSession
    @StateObject private var recovery: ModelRuntimeRecoverySession
    @Environment(\.openWindow) private var openWindow

    private var isRunning: Bool { checkState.isRunning }

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        self.onRouteSelection = onRouteSelection
        _backends = StateObject(wrappedValue: HealthBackendSession(fetch: { try await appHost.api.backendList() }))
        _recovery = StateObject(wrappedValue: ModelRuntimeRecoverySession(
            fetch: { try await appHost.api.backendList() },
            preview: { try await appHost.api.backendInstallPreview(id: $0) },
            start: { _ = try await appHost.api.backendInstallStart(id: $0, previewHash: $1) }
        ))
    }

    var body: some View {
        let fingerprint = appHost.watch.currentFingerprint
        let chain = HealthPresentation.chain(
            agent: appHost.agentHealth,
            report: appHost.runtimeReport,
            fingerprint: fingerprint,
            installAvailable: appHost.runtimeInstaller.repoRoot != nil
        )
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                    if let request = appHost.handoffs[.recoverModelRuntime] {
                        ModelRuntimeRecoveryView(appHost: appHost, session: recovery, request: request,
                                                 onInstalled: { await backends.refresh(source: appHost.config.mlxAgentPath) },
                                                 onReturn: { onRouteSelection(.library) })
                    }
                    if appHost.isCheckingRuntime {
                        RuntimeCheckStatusView().padding(WorkbenchSpacing.md)
                    } else {
                        HealthHeroView(
                            chain: chain,
                            fingerprint: fingerprint,
                            forkMode: layout.forkMode,
                            isRouteActive: isRouteActive,
                            installCommand: appHost.runtimeReport.install,
                            installer: appHost.runtimeInstaller,
                            verification: appHost.verification,
                            onRuntimeInstalled: { appHost.refreshRuntimeReport(appHost.runtimeInstaller.runtimeReport) },
                            onOpenSettings: { onRouteSelection(.settings) },
                            onReviewOnOverview: { onRouteSelection(.overview) }
                        )
                    }
                    HealthRuntimeScopeView(
                        backends: backends,
                        intake: appHost.intake,
                        source: appHost.config.mlxAgentPath,
                        onRefresh: { Task { await backends.refresh(source: appHost.config.mlxAgentPath) } },
                        onAddModel: {
                            guard !appHost.intake.isBusy else { return }
                            appHost.intake.open(with: "")
                            openWindow(id: IntakeWindow.id)
                        },
                        onOpenRun: { onRouteSelection(.run) }
                    )
                    findingsSection
                    WorkbenchSurface {
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                            SectionTitle(text: "Client and host setup")
                            Text("Check coding-client configs and local host connections, add missing connections, and review config repairs.")
                                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                            Button("Open setup doctor…") {
                                appHost.handoffs.send(ClientSetupRequest(), as: .clientSetup)
                                onRouteSelection(.clientSetup)
                            }.accessibilityIdentifier("health-client-setup-doctor")
                        }
                    }
                }
                .frame(maxWidth: WorkbenchSize.Health.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(WorkbenchSpacing.pageInset)
            }
            .defaultScrollAnchor(.top)
            .onChange(of: viewport.size.width, initial: true) { _, width in
                layout = HealthLayout(viewportWidth: width, previous: layout)
            }
        }
        .toolbar {
            if isRouteActive {
                ToolbarItem(placement: .primaryAction) {
                    Button { appHost.setup.presentAgain() } label: {
                        Label("Setup Assistant…", systemImage: "wand.and.stars")
                    }
                    .help("Setup Assistant…")
                }
            }
        }
    }

    // MARK: - Findings

    private var findingsSection: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                findingsHeader
                stateBlock
                ForEach(
                    HealthDoctor.groups(
                        findings: checkState.findings,
                        prunableCount: checkState.pruneCount,
                        models: appHost.librarySnapshot?.models ?? []
                    )
                ) { group in
                    HealthFindingGroupView(
                        group: group,
                        isCompact: layout.compactFindings,
                        wrapsHeader: layout.wrapsHeader,
                        onOpenReclaim: { onRouteSelection(.reclaim) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var findingsHeader: some View {
        if layout.wrapsHeader {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                SectionTitle(text: "Model inventory findings")
                HStack(spacing: WorkbenchSpacing.sm) { findingsControls }
            }
        } else {
            HStack(spacing: WorkbenchSpacing.sm) {
                SectionTitle(text: "Model inventory findings")
                Spacer()
                findingsControls
            }
        }
    }

    @ViewBuilder
    private var findingsControls: some View {
        if checkState != .notRun, !isRunning {
            Button("Clear") {
                checkState = .notRun
                lastCheckedAt = nil
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        Button(isRunning ? "Checking…" : "Run doctor") { runDoctor() }
            .buttonStyle(.workbenchPrimary)
            .disabled(isRunning)
    }

    private var stateBlock: some View {
        let tone = HealthDoctor.tone(checkState).color
        return HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
            Image(systemName: checkState.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tone)
                .contentTransition(isRouteActive ? .symbolEffect(.replace) : .identity)
                .workbenchAnimation(value: checkState.symbol)
                .livePulse(isRouteActive && isRunning)
                .accessibilityLabel("Checking inventory")
                .accessibilityHidden(!isRunning)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Text(checkState.message)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(tone)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if case .completed(let result) = checkState {
                    if checkState.isClean {
                        ForEach(HealthDoctor.cleanLines(result.summary), id: \.self) { line in
                            Text(line)
                                .font(WorkbenchTypography.secondary)
                                .foregroundStyle(WorkbenchColor.muted)
                        }
                    }
                    if let checkedAt = lastCheckedAt {
                        TimelineView(.everyMinute) { context in
                            Text(HealthDoctor.checkedText(checkedAt, now: context.date))
                                .font(WorkbenchTypography.secondary)
                                .foregroundStyle(WorkbenchColor.muted)
                        }
                    }
                }
            }
        }
    }

    private func runDoctor() {
        guard !isRunning else { return }
        checkState = .running
        Task {
            do {
                let result = try await appHost.api.doctor(wiredRoots: [], hfCache: nil)
                lastCheckedAt = Date()
                checkState = .completed(result)
            } catch let error as BridgeError {
                checkState = .failed(error.errorDescription ?? error.localizedDescription)
            } catch {
                checkState = .failed(error.localizedDescription)
            }
        }
    }
}
