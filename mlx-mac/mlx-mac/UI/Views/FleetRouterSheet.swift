import SwiftUI

// MARK: - FleetRouterSheet
//
// "Wire roles…" flow (spec 09 P4): review the role → endpoint plan, render
// the router config via `fleet render`, review the apply preview diff, then
// confirm with the exact preview hash. Roles without a running endpoint are
// listed as skipped, never pointed at a dead port. Every mutating step goes
// through the agent's preview/confirm transaction — backup, rollback, and
// receipt stay the agent's discipline.

struct FleetRouterSheet: View {
    @ObservedObject var appHost: AppHost

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .plan
    @State private var warnings: [String] = []

    private enum Step {
        case plan
        case working(String)
        case preview(diff: String, hash: String)
        case applied(summary: String)
        case failed(message: String)
    }

    private var plan: FleetRouter.Plan {
        FleetRouter.plan(
            slots: appHost.endpoint.fleet.slots,
            states: appHost.endpoint.slotStates
        )
    }

    private var apiAssignments: [(role: String, repo: String, port: Int)] {
        plan.assignments.map { (role: $0.fleetRole, repo: $0.repo, port: $0.port) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Wire roles to running endpoints")
                .font(.headline)
            Text("Renders one router config mapping each role onto its running endpoint's stable port, via mlx-agent fleet.")
                .font(.caption)
                .foregroundColor(.secondary)

            planSection

            switch step {
            case .plan:
                EmptyView()
            case .working(let label):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(label).font(.caption).foregroundColor(.secondary)
                }
            case .preview(let diff, _):
                previewSection(diff: diff)
            case .applied(let summary):
                Label(summary, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundColor(WorkbenchColor.verifiedGreen)
            case .failed(let message):
                ErrorBanner(text: message)
            }

            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.caption2)
                            .foregroundColor(WorkbenchColor.thermalAmber)
                    }
                }
            }

            footer
        }
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: 560)
    }

    @ViewBuilder
    private var planSection: some View {
        if plan.assignments.isEmpty {
            Text("No roles can be wired right now. Assign roles to endpoints, keep them running, and use models from the Hugging Face cache.")
                .font(.callout)
                .foregroundColor(.secondary)
        } else {
            ForEach(plan.assignments) { assignment in
                HStack {
                    Text(assignment.fleetRole)
                        .font(.callout)
                        .frame(width: 90, alignment: .leading)
                    Text(assignment.repo)
                        .font(WorkbenchTypography.monoUtility)
                        .lineLimit(1)
                    Spacer()
                    Text(":\(assignment.port)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        ForEach(plan.skipped) { skipped in
            HStack {
                Text(FleetRouter.fleetRoleName(for: skipped.role))
                    .font(.callout)
                    .frame(width: 90, alignment: .leading)
                Text("skipped — \(skipped.reason)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        detailRow("Target", plan.targetPath)
    }

    private func previewSection(diff: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.callout)
            ScrollView {
                Text(diff)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button(closeTitle) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            switch step {
            case .plan:
                Button("Render preview") { renderPreview() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.isEmpty)
            case .working:
                EmptyView()
            case .preview:
                Button("Confirm apply") { confirmApply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .applied:
                EmptyView()
            case .failed:
                Button("Back to plan") { step = .plan }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var closeTitle: String {
        if case .applied = step { return "Done" }
        return "Cancel"
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundColor(.secondary).frame(width: 90, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
            Spacer()
        }
    }

    private func renderPreview() {
        step = .working("Rendering router config…")
        warnings = []
        Task {
            do {
                // Render proves the plan produces a valid config before the
                // apply preview is even requested.
                _ = try await runFleet { api in
                    try api.fleetRender(path: plan.targetPath, assignments: apiAssignments)
                }
                let data = try await runFleet { api in
                    try api.fleetApplyPreview(path: plan.targetPath, assignments: apiAssignments)
                }
                let preview = (data["preview"] as? [String: Any]) ?? data
                guard let hash = preview["preview_hash"] as? String, !hash.isEmpty else {
                    step = .failed(message: "mlx-agent did not return a preview hash.")
                    return
                }
                warnings = (data["warnings"] as? [[String: Any]])?.compactMap { $0["message"] as? String } ?? []
                let diff = (preview["diff"] as? String) ?? "(no diff reported)"
                step = .preview(diff: diff, hash: hash)
            } catch {
                step = .failed(message: AppHost.render(error))
            }
        }
    }

    private func confirmApply() {
        guard case .preview(_, let hash) = step else { return }
        step = .working("Applying router config…")
        Task {
            do {
                let directory = URL(fileURLWithPath: plan.targetPath).deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try await runFleet { api in
                    try api.fleetApplyConfirm(
                        path: plan.targetPath,
                        assignments: apiAssignments,
                        previewHash: hash
                    )
                }
                warnings = (data["warnings"] as? [[String: Any]])?.compactMap { $0["message"] as? String } ?? []
                let receipt = data["receipt"] as? [String: Any]
                let status = receipt?["status"] as? String ?? "applied"
                guard status == "applied" else {
                    step = .failed(message: "Fleet did not apply; receipt status is \(status).")
                    return
                }
                step = .applied(summary: "Router config applied to \(plan.targetPath)")
            } catch {
                step = .failed(message: AppHost.render(error))
            }
        }
    }

    /// The agent call on a background thread; API stays MainActor-free.
    private func runFleet<T>(_ work: @escaping (WorkbenchAPI) throws -> T) async throws -> T {
        let api = appHost.api
        return try await Task.detached { try work(api) }.value
    }
}
