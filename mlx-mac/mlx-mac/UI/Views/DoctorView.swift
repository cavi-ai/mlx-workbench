import AppKit
import SwiftUI

// MARK: - DoctorView
// Health: environment/runtime status plus the doctor findings inventory.
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
    private let onRouteSelection: (AppRoute) -> Void

    @State private var checkState: DoctorCheckState = .notRun

    private var isRunning: Bool { checkState.isRunning }
    private var findings: [DoctorFinding] { checkState.findings }
    private var pruneCount: Int { checkState.pruneCount }

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        self.onRouteSelection = onRouteSelection
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                environmentSection
                findingsSection
                Spacer()
            }
            .padding(WorkbenchSpacing.pageInset)
        }
    }

    // MARK: - Environment

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            SectionTitle(text: "Runtime readiness")
            runtimeRow("Prepare runtime", ok: appHost.runtimeReport.convert.ok,
                       message: appHost.runtimeReport.convert.message)
            runtimeRow("Run runtime", ok: appHost.runtimeReport.serve.ok,
                       message: appHost.runtimeReport.serve.message)
            Divider()
            agentRow
            if !appHost.runtimeReport.ok {
                Text(appHost.runtimeReport.install)
                    .font(WorkbenchTypography.value)
                    .foregroundStyle(WorkbenchColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.sm) { runtimeRecoveryActions }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { runtimeRecoveryActions }
                }
                RuntimeInstallView(installer: appHost.runtimeInstaller) {
                    appHost.refreshRuntimeReport()
                }
            }
            Button("Run setup assistant again") { appHost.setup.presentAgain() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .formSection {}
    }

    @ViewBuilder
    private var runtimeRecoveryActions: some View {
        Button("Copy command") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(appHost.runtimeReport.install, forType: .string)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        Button("Open Settings") { onRouteSelection(.settings) }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    @ViewBuilder
    private var agentRow: some View {
        switch appHost.agentHealth {
        case .notConfigured:
            healthRow("mlx-agent", ok: false, message: "Not configured. Set the checkout path in Settings.")
        case .notUsable(_, _, let reason):
            healthRow("mlx-agent", ok: false, message: reason)
        case .notFound(let path, _):
            healthRow("mlx-agent", ok: false, message: "Not found at \(path).")
        case .ready(let path, _):
            healthRow("mlx-agent", ok: true, message: path)
        }
    }

    private func runtimeRow(_ label: String, ok: Bool, message: String) -> some View {
        healthRow(label, ok: ok, message: message)
    }

    private func healthRow(_ label: String, ok: Bool, message: String) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
                Label(label, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(WorkbenchTypography.emphasis)
                    .symbolRenderingMode(.hierarchical)
                Spacer()
                Text(ok ? "Ready" : "Needs setup")
                    .font(WorkbenchTypography.label)
                    .foregroundStyle(ok ? WorkbenchColor.success : WorkbenchColor.failure)
            }
            Text(message)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Findings

    private var findingsSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack {
                SectionTitle(text: "Model inventory findings")
                Spacer()
                if checkState != .notRun, !isRunning {
                    Button("Clear") { checkState = .notRun }
                        .controlSize(.small)
                }
                Button(isRunning ? "Checking…" : "Run doctor") { runDoctor() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)
            }
            Text("Checks local model files for incomplete caches, unreadable files, and other inventory issues.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)

            HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
                if isRunning {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Checking inventory")
                } else {
                    Image(systemName: checkState.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(checkState.isFailed ? WorkbenchColor.failure : checkState.isClean ? WorkbenchColor.success : WorkbenchColor.muted)
                        .accessibilityHidden(true)
                }
                Text(checkState.message)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(checkState.isFailed ? WorkbenchColor.failure : checkState.isClean ? WorkbenchColor.success : WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if pruneCount > 0 {
                HStack(spacing: WorkbenchSpacing.sm) {
                    Text("The doctor found \(pruneCount) prunable cache item(s).")
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.warning)
                    Spacer()
                    Button("Open Reclaim") { onRouteSelection(.reclaim) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            ForEach(findings) { finding in
                HStack(alignment: .top) {
                    StatusPill(state: finding.kind ?? "issue")
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                        Text(finding.path).font(WorkbenchTypography.secondary)
                            .textSelection(.enabled)
                        if let message = finding.message {
                            Text(message).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        }
                    }
                    Spacer()
                    if let size = finding.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.muted)
                    }
                }
                .padding(.vertical, WorkbenchSpacing.xxxs)
            }
        }
        .formSection {}
    }

    private func runDoctor() {
        guard !isRunning else { return }
        checkState = .running
        Task {
            do {
                let result = try await appHost.api.doctor(wiredRoots: [], hfCache: nil)
                checkState = .completed(result)
            } catch let error as BridgeError {
                checkState = .failed(error.errorDescription ?? error.localizedDescription)
            } catch {
                checkState = .failed(error.localizedDescription)
            }
        }
    }
}
