import SwiftUI

// MARK: - DoctorView
// Health: environment/runtime status plus the doctor findings inventory.
// Prune actions live in Reclaim, which owns the authoritative prune flow.

struct DoctorView: View {
    @ObservedObject var appHost: AppHost
    private let onRouteSelection: (String) -> Void

    @State private var isRunning = false
    @State private var findings: [DoctorFinding] = []
    @State private var pruneCount = 0
    @State private var errorMessage: String?

    init(appHost: AppHost, onRouteSelection: @escaping (String) -> Void = { _ in }) {
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
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Environment")
            agentRow
            runtimeRow("Prepare runtime", ok: appHost.runtimeReport.convert.ok,
                       message: appHost.runtimeReport.convert.message)
            runtimeRow("Run runtime", ok: appHost.runtimeReport.serve.ok,
                       message: appHost.runtimeReport.serve.message)
            if !appHost.runtimeReport.ok {
                HStack(spacing: WorkbenchSpacing.sm) {
                    Text(appHost.runtimeReport.install)
                        .font(.caption)
                        .foregroundColor(WorkbenchColor.thermalAmber)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Open Settings") { onRouteSelection(AppRoute.settings.rawValue) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .formSection {}
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
        HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(ok ? WorkbenchColor.verifiedGreen : WorkbenchColor.systemRed)
            Text(label)
                .font(WorkbenchTypography.body)
                .frame(width: 130, alignment: .leading)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
        }
    }

    // MARK: - Findings

    private var findingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "Model inventory findings")
                Spacer()
                if !findings.isEmpty {
                    Button("Clear") { findings = [] }
                        .controlSize(.small)
                }
                Button(isRunning ? "Checking…" : "Run doctor") { runDoctor() }
                    .buttonStyle(.borderedProminent)
                    .tint(WorkbenchColor.fluxTeal)
                    .disabled(isRunning)
            }
            Text("Checks local model files for incomplete caches, unreadable files, and other inventory issues.")
                .font(.caption)
                .foregroundColor(.secondary)

            if isRunning {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
            }

            ErrorBanner(text: errorMessage)

            if pruneCount > 0 {
                HStack(spacing: WorkbenchSpacing.sm) {
                    Text("The doctor found \(pruneCount) prunable cache item(s).")
                        .font(.caption)
                        .foregroundColor(WorkbenchColor.thermalAmber)
                    Spacer()
                    Button("Open Reclaim") { onRouteSelection(AppRoute.reclaim.rawValue) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if findings.isEmpty, !isRunning, errorMessage == nil {
                Text("No findings from the latest doctor run.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                ForEach(findings) { finding in
                    HStack(alignment: .top) {
                        StatusPill(state: finding.kind ?? "issue")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.path).font(.caption)
                                .textSelection(.enabled)
                            if let message = finding.message {
                                Text(message).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if let size = finding.size {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .formSection {}
    }

    private func runDoctor() {
        errorMessage = nil
        isRunning = true
        Task {
            defer { isRunning = false }
            do {
                let result = try await appHost.api.doctor(wiredRoots: [], hfCache: nil)
                findings = result.findings ?? []
                pruneCount = result.prune_count ?? 0
            } catch let error as BridgeError {
                findings = []
                errorMessage = error.errorDescription
            } catch {
                findings = []
                errorMessage = error.localizedDescription
            }
        }
    }
}
