import SwiftUI

// MARK: - SetupAssistantView
//
// First-launch guided setup. Each step renders state the app already probes
// (agent health, runtime report, discovered roots); the only mutations are
// the guided runtime install (RuntimeInstaller) and saving confirmed roots
// through AppHost.saveConfig. Never blocks: every step can be skipped, and
// dismissing without finishing returns the assistant next launch.

struct SetupAssistantView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject var coordinator: SetupCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
            header
            Divider().overlay(WorkbenchColor.hairline)
            stepContent
            Divider().overlay(WorkbenchColor.hairline)
            footer
        }
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: 560)
        .frame(minHeight: 380)
        .background(WorkbenchColor.alloyCanvas)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SETUP").font(WorkbenchTypography.monoUtility)
                    .foregroundColor(WorkbenchColor.fluxTeal)
                Text(coordinator.step.title).font(WorkbenchTypography.section)
            }
            Spacer()
            Text("Step \(coordinator.step.rawValue + 1) of \(SetupCoordinator.Step.allCases.count)")
                .font(WorkbenchTypography.monoUtility)
                .foregroundColor(WorkbenchColor.graphiteMuted)
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
            Text("mlx-workbench drives conversions and serving through the mlx-agent CLI. The vendored checkout that ships with the app is used by default.")
                .font(WorkbenchTypography.body)
                .foregroundColor(WorkbenchColor.graphiteMuted)
                .fixedSize(horizontal: false, vertical: true)
            switch appHost.agentHealth {
            case .ready(let path, _):
                StatusBadge(status: .ready)
                Text(path).font(WorkbenchTypography.monoUtility)
                    .foregroundColor(WorkbenchColor.graphiteMuted)
                    .textSelection(.enabled)
            case .notConfigured:
                guidance("No agent path is configured.", detail: "The vendored checkout is picked up automatically when the app runs from the repository. Otherwise set the path in Settings.")
            case .notFound(let path, _):
                guidance("The configured agent path does not exist.", detail: path)
            case .notUsable(_, _, let reason):
                guidance("The agent at the configured path is not usable.", detail: reason)
            }
        }
    }

    private var runtimeStep: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Converting and serving models needs the repo's Python runtime (Python 3.12, mlx-lm, and friends).")
                .font(WorkbenchTypography.body)
                .foregroundColor(WorkbenchColor.graphiteMuted)
                .fixedSize(horizontal: false, vertical: true)
            if appHost.runtimeReport.ok {
                StatusBadge(status: .ready)
                Text("Convert and serve runtimes are ready.").font(WorkbenchTypography.body)
            } else {
                guidance("The runtime is not installed yet.", detail: appHost.runtimeReport.install)
                RuntimeInstallView(installer: appHost.runtimeInstaller) {
                    appHost.refreshRuntimeReport()
                }
            }
        }
    }

    private var rootsStep: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("The library scans these folders for models. Discovered roots on this Mac:")
                .font(WorkbenchTypography.body)
                .foregroundColor(WorkbenchColor.graphiteMuted)
                .fixedSize(horizontal: false, vertical: true)
            if appHost.discoveredRoots.isEmpty {
                guidance("No model folders were discovered.", detail: "You can add roots later in Settings.")
            } else {
                ForEach(appHost.discoveredRoots, id: \.self) { root in
                    Text(root).font(WorkbenchTypography.monoUtility)
                        .foregroundColor(WorkbenchColor.graphiteInk)
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
                        .foregroundColor(WorkbenchColor.graphiteMuted)
                }
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Setup complete. Scan the library to build the model inventory, then Home will point at the next safe action.")
                .font(WorkbenchTypography.body)
                .foregroundColor(WorkbenchColor.graphiteMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if !coordinator.isLast {
                Button("Skip setup") { coordinator.dismiss() }
                    .foregroundColor(WorkbenchColor.graphiteMuted)
            }
            Spacer()
            if !coordinator.isFirst && !coordinator.isLast {
                Button("Back") { coordinator.retreat() }
            }
            if coordinator.isLast {
                Button("Scan my library") {
                    coordinator.finish()
                    appHost.requestRescan()
                }
                .buttonStyle(.borderedProminent)
                .tint(WorkbenchColor.fluxTeal)
            } else {
                Button("Continue") { coordinator.advance() }
                    .buttonStyle(.borderedProminent)
                    .tint(WorkbenchColor.fluxTeal)
            }
        }
        .buttonStyle(.bordered)
    }

    private func guidance(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(WorkbenchTypography.body)
                .foregroundColor(WorkbenchColor.thermalAmber)
            Text(detail).font(WorkbenchTypography.monoUtility)
                .foregroundColor(WorkbenchColor.graphiteMuted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
