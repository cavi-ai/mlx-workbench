import SwiftUI

struct AdoptView: View {
    @ObservedObject var appHost: AppHost
    @Environment(\.isRouteActive) private var isRouteActive

    private struct WorkflowContext {
        let requestedRole: String
        let statePath: String
        var response: AdoptResult?
    }

    private enum Operation {
        case start, refresh

        var label: String {
            switch self {
            case .start: return "Starting adoption…"
            case .refresh: return "Refreshing status…"
            }
        }
    }

    @State private var role = "general"
    @State private var fast = false
    @State private var offline = false
    @State private var operation: Operation?
    @State private var workflow: WorkflowContext?
    @State private var errorMessage: String?
    @State private var isLastKnownState = false

    private var isBusy: Bool { operation != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
            controls
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                    recommendation
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
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Adopt a role")
                .font(WorkbenchTypography.title)
            Text("Choose a role to discover a model recommendation for this Mac.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)

            Picker("Role", selection: $role) {
                ForEach(WorkbenchAPI.supportedAdoptionRoles, id: \.self) { role in
                    Text(roleTitle(role)).tag(role)
                }
            }
            .pickerStyle(.menu)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(isBusy)
            .accessibilityIdentifier("adopt-role")

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: WorkbenchSpacing.lg) {
                    fastOption.fixedSize(horizontal: true, vertical: false)
                    offlineOption.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    fastOption
                    offlineOption
                }
            }
            .disabled(isBusy)

            HStack(spacing: WorkbenchSpacing.sm) {
                Button("Start") { startAdopt() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(isRouteActive ? .defaultAction : nil)
                    .disabled(!isRouteActive || isBusy || !WorkbenchAPI.supportedAdoptionRoles.contains(role))
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

    private var fastOption: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Toggle("Fast", isOn: $fast)
            Text("Heuristic-only discovery enrichment")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
        }
    }

    private var offlineOption: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Toggle("Offline", isOn: $offline)
            Text("Cached discovery; no metadata network requests")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
        }
    }

    private var recommendation: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            if isLastKnownState {
                Label("Last known state", systemImage: "clock.arrow.circlepath")
                    .font(WorkbenchTypography.emphasis)
                    .foregroundStyle(WorkbenchColor.muted)
                    .accessibilityIdentifier("adopt-last-known")
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: WorkbenchSpacing.lg) {
                    requestedRole.fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "arrow.right")
                        .font(WorkbenchTypography.section)
                        .foregroundStyle(WorkbenchColor.accent)
                        .accessibilityHidden(true)
                    recommendedModel
                        .frame(minWidth: WorkbenchSize.instrumentMinimum, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    requestedRole
                    Image(systemName: "arrow.down")
                        .font(WorkbenchTypography.section)
                        .foregroundStyle(WorkbenchColor.accent)
                        .accessibilityHidden(true)
                    recommendedModel
                }
            }
            if let reportedOutcome {
                Text(reportedOutcome)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("adopt-outcome")
            }
            if let message = workflow?.response?.message, !message.isEmpty {
                Text(message)
                    .font(WorkbenchTypography.body)
                    .textSelection(.enabled)
            }
        }
        .padding(WorkbenchSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchColor.surface)
    }

    private var requestedRole: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Label("Requested role", systemImage: "cpu")
                .symbolRenderingMode(.hierarchical)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            Text(workflow.map { roleTitle($0.requestedRole) } ?? "No role requested")
                .font(WorkbenchTypography.section)
                .accessibilityIdentifier("adopt-requested-role")
        }
    }

    private var recommendedModel: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Label("Recommendation", systemImage: "cube")
                .symbolRenderingMode(.hierarchical)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            Text(recommendationText)
                .font(WorkbenchTypography.title)
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

    private var recommendationText: String {
        guard let response = workflow?.response else {
            return "Recommendation appears after adoption."
        }
        guard let model = response.model, !model.isEmpty else {
            return "No recommendation reported."
        }
        return model
    }

    private var reportedOutcome: String? {
        guard let response = workflow?.response else { return nil }
        let fields = [
            ("Status", response.status),
            ("Phase", response.phase),
            ("Evidence strength", response.evidenceStrength)
        ].compactMap { label, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return "\(label): \(value)"
        }
        return fields.isEmpty ? nil : fields.joined(separator: " · ")
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

    private func roleTitle(_ role: String) -> String {
        role == "tool-use" ? "Tool use" : role.capitalized
    }

    private func startAdopt() {
        guard isRouteActive, !isBusy, WorkbenchAPI.supportedAdoptionRoles.contains(role) else { return }
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
