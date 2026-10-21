import SwiftUI

// MARK: - SetupAssistantView
//
// First-launch guided setup. Each step renders state the app already probes
// (agent health, runtime report, discovered roots); the only mutations are
// the guided runtime install (RuntimeInstaller) and saving confirmed roots
// through AppHost.saveConfig. Never blocks: every step can be skipped, and
// dismissing without finishing returns the assistant next launch.

struct SetupAssistantView: View {
    let appHost: AppHost
    @ObservedObject var coordinator: SetupCoordinator
    @ObservedObject private var runtimeInstaller: RuntimeInstaller
    @StateObject private var runtimePreparation = BundledRuntimePreparation()

    init(appHost: AppHost, coordinator: SetupCoordinator) {
        self.appHost = appHost
        self.coordinator = coordinator
        _runtimeInstaller = ObservedObject(wrappedValue: appHost.runtimeInstaller)
    }

    private var readiness: SetupReadiness {
        let connected: Bool
        if case .ready = appHost.agentHealth { connected = true } else { connected = false }
        return SetupReadiness(agentReady: connected, convertReady: appHost.runtimeReport.convert.ok,
                              serveReady: appHost.runtimeReport.serve.ok)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
            header
            Divider().overlay(WorkbenchColor.hairline)
            ScrollView {
                stepContent.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(WorkbenchColor.hairline)
            footer
        }
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: WorkbenchSize.SetupAssistant.sheetWidth, height: WorkbenchSize.SetupAssistant.sheetHeight)
        .interactiveDismissDisabled(runtimePreparation.isPreparing)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            SetupStepTrack(step: coordinator.step)
            HStack(alignment: .firstTextBaseline) {
                Text(coordinator.step.title)
                    .font(WorkbenchTypography.section)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(coordinator.step.progressLabel)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch coordinator.step {
        case .agent: agentStep
        case .runtime: runtimeStep
        case .roots: rootsStep
        case .done: doneStep
        }
    }

    // MARK: - Steps

    private var agentStep: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("MLX Workbench uses the mlx-agent engine for model operations. Prepare the bundled engine or keep a configured checkout; runtime packages are installed in its separate Python environment.")
                .font(WorkbenchTypography.body)
                .foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            switch appHost.agentHealth {
            case .ready(let path, _):
                StatusBadge(status: .ready)
                Text(path).font(WorkbenchTypography.value)
                    .foregroundStyle(WorkbenchColor.muted)
                    .textSelection(.enabled)
            case .notConfigured:
                guidance("No agent path is configured.", detail: "Use the bundled engine below, or choose an existing checkout in Settings. Source builds also discover their vendored engine.")
            case .notFound(let path, _):
                guidance("The configured agent path does not exist.", detail: path, isLiteral: true)
            case .notUsable(_, _, let reason):
                guidance("The agent at the configured path is not usable.", detail: reason)
            }
            BundledRuntimeSetupView(appHost: appHost, session: runtimePreparation)
        }
    }

    private var runtimeStep: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Converting and serving models uses the selected engine's Python 3.12 environment. Check the prerequisites below, then confirm installation to download its runtime packages.")
                .font(WorkbenchTypography.body)
                .foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            if appHost.isCheckingRuntime {
                RuntimeCheckStatusView()
            } else if appHost.runtimeReport.ok {
                StatusBadge(status: .ready)
                Text("Convert and serve runtimes are ready.").font(WorkbenchTypography.body)
                if appHost.runtimeInstaller.state != .idle {
                    RuntimeInstallStatusView(installer: appHost.runtimeInstaller)
                }
            } else {
                guidance("The runtime is not installed yet.", detail: appHost.runtimeReport.install, isLiteral: true)
                RuntimeInstallView(installer: appHost.runtimeInstaller) {
                    appHost.refreshRuntimeReport(appHost.runtimeInstaller.runtimeReport)
                }
            }
        }
    }

    private var rootsStep: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("The library scans these folders for models. Discovered roots on this Mac:")
                .font(WorkbenchTypography.body)
                .foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            if appHost.discoveredRoots.isEmpty {
                guidance("No model folders were discovered.", detail: "You can add roots later in Settings.")
            } else {
                ForEach(appHost.discoveredRoots, id: \.self) { root in
                    Text(root).font(WorkbenchTypography.value)
                        .foregroundStyle(WorkbenchColor.ink)
                        .textSelection(.enabled)
                }
                if appHost.config.ggufRoots.isEmpty {
                    Button("Use these roots") {
                        var next = appHost.config
                        next.ggufRoots = appHost.discoveredRoots
                        _ = appHost.saveConfig(next)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Text("Roots are already configured; edit them in Settings.")
                        .font(WorkbenchTypography.body)
                        .foregroundStyle(WorkbenchColor.muted)
                }
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text(readiness.title).font(WorkbenchTypography.emphasis)
                .accessibilityIdentifier("setup-readiness-title")
            Text(readiness.summary)
                .font(WorkbenchTypography.body)
                .foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Label(readiness.needsEngine ? "Engine needs attention" : "Engine connected",
                      systemImage: readiness.needsEngine ? "exclamationmark.circle" : "checkmark.circle")
                    .font(WorkbenchTypography.body)
                if readiness.needsEngine {
                    Button("Review engine") { coordinator.revisit(.agent) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Label(readiness.runtimeMessage,
                      systemImage: readiness.needsRuntime ? "exclamationmark.circle" : "checkmark.circle")
                    .font(WorkbenchTypography.body)
                    .fixedSize(horizontal: false, vertical: true)
                if readiness.needsRuntime {
                    Button("Review runtime") { coordinator.revisit(.runtime) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if !coordinator.isLast {
                Button("Skip setup") { coordinator.dismiss() }
                    .foregroundStyle(WorkbenchColor.muted)
            }
            Spacer()
            if !coordinator.isFirst {
                Button("Back") { coordinator.retreat() }
            }
            if coordinator.isLast {
                Button(readiness.finishTitle) {
                    coordinator.finish()
                    if readiness.isReady { appHost.requestRescan() }
                }
                .buttonStyle(.workbenchPrimary)
            } else {
                Button("Continue") { coordinator.advance() }
                    .buttonStyle(.workbenchPrimary)
            }
        }
        .buttonStyle(.bordered)
        .disabled(runtimePreparation.isPreparing)
    }

    /// `isLiteral` details are paths or commands and stay monospaced; prose reads in the secondary face.
    private func guidance(_ title: String, detail: String, isLiteral: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(title).font(WorkbenchTypography.body)
                .foregroundStyle(WorkbenchColor.warning)
            Text(detail).font(isLiteral ? WorkbenchTypography.value : WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct BundledRuntimeSetupView: View {
    let appHost: AppHost
    @ObservedObject var session: BundledRuntimePreparation
    @State private var plan: BundledRuntime?
    @State private var loadError: String?
    @State private var confirming = false
    @State private var capturedEnginePath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if let plan {
                Button("Use bundled engine…") {
                    capturedEnginePath = appHost.config.mlxAgentPath
                    confirming = true
                }
                .buttonStyle(.workbenchPrimary)
                .disabled(session.isPreparing)
                .accessibilityIdentifier("setup-bundled-runtime")
                Text("Workbench \(plan.manifest.workbenchVersion) · engine \(plan.manifest.engineRevision.prefix(12))")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                if session.isPreparing {
                    ProgressView("Preparing engine…").controlSize(.small)
                }
                if let path = session.preparedPath {
                    Text("Bundled engine prepared. Continue to Python runtime for dependency setup.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("setup-bundled-runtime-prepared")
                    Text(path).font(WorkbenchTypography.metadata).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("setup-bundled-runtime-path")
                }
            }
            ErrorBanner(text: loadError ?? session.errorMessage)
        }
        .task {
            do { plan = try await Task.detached(priority: .utility) { try BundledRuntime.included() }.value }
            catch { loadError = AppHost.render(error) }
        }
        .confirmationDialog("Use the bundled engine?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Prepare engine") {
                guard let plan else { return }
                session.prepare(plan) { path in
                    guard appHost.config.mlxAgentPath == capturedEnginePath else {
                        throw BundledRuntime.Failure("The selected engine changed. Review setup again before switching engines.")
                    }
                    var next = appHost.config
                    next.mlxAgentPath = path
                    guard await appHost.saveSettingsConfig(next) else {
                        throw BundledRuntime.Failure(appHost.lastError ?? "The engine setting could not be saved.")
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let plan {
                Text("Copy the packaged engine and setup files to \(plan.destination.path), then select that engine for Workbench. Continue to Python runtime to install dependencies.")
            }
        }
    }
}

/// One segment per step: finished and current steps fill with the accent, later ones stay in the well.
private struct SetupStepTrack: View {
    let step: SetupCoordinator.Step

    var body: some View {
        HStack(spacing: WorkbenchSpacing.xxs) {
            ForEach(SetupCoordinator.Step.allCases) { segment in
                Capsule()
                    .fill(segment.rawValue <= step.rawValue ? WorkbenchColor.accent : WorkbenchColor.well)
                    .frame(height: WorkbenchSize.stageTrack * 2)
            }
        }
        .workbenchAnimation(value: step)
        .accessibilityHidden(true)
    }
}
