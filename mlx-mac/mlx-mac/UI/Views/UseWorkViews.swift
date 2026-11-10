import AppKit
import SwiftUI

struct UseTurnView: View {
    let turn: UseTurn
    let modelName: String
    let isLast: Bool
    let canRetry: Bool
    let onRetry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Text("You").font(WorkbenchTypography.emphasis)
                Text(turn.prompt).font(WorkbenchTypography.body).textSelection(.enabled)
                ForEach(turn.images) { image in
                    Label(image.name, systemImage: "photo").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
            }
            .padding(WorkbenchSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                HStack {
                    Text(modelName).font(WorkbenchTypography.emphasis)
                    Spacer()
                    if turn.state == .sending { ProgressView().controlSize(.small) }
                }
                if !turn.reasoning.isEmpty {
                    DisclosureGroup("Reasoning") {
                        Text(turn.reasoning).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).textSelection(.enabled)
                    }
                }
                Group {
                    if turn.state == .sending { Text(turn.answer.isEmpty ? "Waiting for the model…" : turn.answer) }
                    else { Text(.init(turn.answer)) }
                }
                .font(WorkbenchTypography.reading).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("use-answer-\(turn.id)")
                HStack(spacing: WorkbenchSpacing.sm) {
                    Text(turn.state.title).foregroundStyle(turn.state.suppliesContext ? WorkbenchColor.muted : WorkbenchColor.warning)
                        .accessibilityIdentifier("use-turn-status-\(turn.id)")
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(turn.answer, forType: .string)
                    }.disabled(turn.answer.isEmpty)
                    if isLast && turn.state.canRetry {
                        Button("Try again") { onRetry() }.disabled(!canRetry).accessibilityIdentifier("use-retry")
                    }
                }.font(WorkbenchTypography.secondary)
                if let notice = turn.notice {
                    Text(notice).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning).textSelection(.enabled)
                }
            }
        }
    }
}

struct UseSettingsSheet: View {
    @ObservedObject var coordinator: UseWorkspaceCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var limit: String
    @State private var temperature: String
    @State private var instructions: String
    @State private var makeDefault = false
    @State private var saving = false
    @State private var error: String?
    init(settings: UseRequestDefaults, coordinator: UseWorkspaceCoordinator) {
        self.coordinator = coordinator
        _limit = State(initialValue: String(settings.maximumTokens))
        _temperature = State(initialValue: String(settings.temperature))
        _instructions = State(initialValue: settings.systemPrompt)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Request settings").font(WorkbenchTypography.title)
            Form {
                TextField("Response limit", text: $limit).accessibilityIdentifier("use-token-limit")
                TextField("Temperature", text: $temperature).accessibilityIdentifier("use-temperature")
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    Text("System instructions").font(WorkbenchTypography.label)
                    TextEditor(text: $instructions).font(WorkbenchTypography.body)
                        .frame(minHeight: WorkbenchSize.Use.composerMinimum)
                        .accessibilityIdentifier("use-system-prompt")
                }
                Toggle("Use these defaults for new conversations", isOn: $makeDefault)
            }
            Text("Server inference settings and memory policy are managed in Run.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            if let error { Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") {
                    guard let tokens = Int(limit), let value = Double(temperature) else { error = UseSessionError.settings.localizedDescription; return }
                    let settings = UseRequestDefaults(maximumTokens: tokens, temperature: value, systemPrompt: instructions)
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await coordinator.setSettings(settings, saveDefaults: makeDefault); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.workbenchPrimary).keyboardShortcut(.defaultAction).disabled(saving)
                    .accessibilityIdentifier("use-apply-settings")
            }
        }.padding(WorkbenchSpacing.lg)
            .frame(width: WorkbenchSize.Use.settingsWidth).frame(minHeight: WorkbenchSize.Use.settingsHeight)
    }
}

struct UseTaskHistory: View {
    @ObservedObject var coordinator: InferenceTaskCoordinator
    let modelPath: String
    @Environment(\.isRouteActive) private var isRouteActive
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            RecentTaskList(coordinator: coordinator, filterModelPath: modelPath)
            if let task = coordinator.selectedTask, task.state.isActive {
                Button("Cancel job") { Task { await coordinator.cancel(id: task.id) } }
            }
        }
        .task { if isRouteActive { await coordinator.refreshRecent() } }
        .task(id: "\(isRouteActive):\(coordinator.selectedTask?.id ?? ""):\(coordinator.selectedTask?.state.wireValue ?? "")") {
            guard isRouteActive, let task = coordinator.selectedTask, task.state.isActive else {
                coordinator.stopPolling(owner: "use-task-history"); return
            }
            coordinator.startPolling(id: task.id, owner: "use-task-history")
        }
        .onDisappear { coordinator.stopPolling(owner: "use-task-history"); coordinator.stopPlayback() }
        .onChange(of: isRouteActive) { _, active in
            if !active { coordinator.stopPolling(owner: "use-task-history"); coordinator.stopPlayback() }
        }
    }
}
