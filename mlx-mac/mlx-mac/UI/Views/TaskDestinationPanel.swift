import SwiftUI

struct ServedTaskPresentation: Identifiable {
    let origin: ServedTaskOrigin
    let model: LibraryModel
    var id: String { origin.id }
}

/// The task forms and result viewers are shared by one-off and resident jobs.
struct TaskDestinationPanel: View {
    let appHost: AppHost
    let model: LibraryModel
    var initialOrigin: ServedTaskOrigin? = nil
    var onEngineSetup: (() -> Void)? = nil
    var onDestinationChange: ((ServedTaskOrigin?) async throws -> Void)? = nil
    @ObservedObject private var sessions: ServedTaskSessions
    @ObservedObject private var workflow: ModelWorkflowCoordinator
    @ObservedObject private var oneOff: InferenceTaskCoordinator
    @State private var selectedID = "local"
    @State private var switching = false
    @State private var error: String?
    @State private var reviewUncertainty = false

    init(appHost: AppHost, model: LibraryModel, initialOrigin: ServedTaskOrigin? = nil, onEngineSetup: (() -> Void)? = nil,
         onDestinationChange: ((ServedTaskOrigin?) async throws -> Void)? = nil) {
        self.appHost = appHost; self.model = model; self.initialOrigin = initialOrigin; self.onEngineSetup = onEngineSetup
        self.onDestinationChange = onDestinationChange
        _selectedID = State(initialValue: initialOrigin?.id ?? "local")
        _sessions = ObservedObject(wrappedValue: appHost.servedTasks)
        _workflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _oneOff = ObservedObject(wrappedValue: appHost.inferenceTasks)
    }

    private var choices: [ServedTaskOrigin] {
        let running = workflow.servers.compactMap { try? ServedTaskOrigin(server: $0) }
        var unique: [String: ServedTaskOrigin] = [:]
        for origin in sessions.origins + running + (initialOrigin.map { [$0] } ?? [])
            where Quarantine.resolve(origin.server.path!) == Quarantine.resolve(model.item.path) {
            unique[origin.id] = origin
        }
        return unique.values.sorted { ($0.server.port!, $0.server.startedAt!) < ($1.server.port!, $1.server.startedAt!) }
    }
    private var origin: ServedTaskOrigin? { choices.first { $0.id == selectedID } }
    private var coordinator: InferenceTaskCoordinator? {
        selectedID == "local" ? oneOff : origin.flatMap { sessions.coordinator(for: $0) }
    }
    private func label(_ origin: ServedTaskOrigin) -> String {
        let running = workflow.servers.contains { origin.matches($0) }
        return "Server · :\(origin.server.port!) · \(running ? "Running" : "Recorded session") · \(origin.server.startedAt!)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Picker("Run on", selection: Binding(get: { selectedID }, set: { id in Task { await choose(id) } })) {
                Text("One-off run").tag("local")
                ForEach(choices) { origin in Text(label(origin)).tag(origin.id) }
            }
            .accessibilityIdentifier("task-destination")
            .disabled(switching || coordinator?.busy == true)
            if let origin {
                Label("Uses this server’s model and memory policy.", systemImage: "server.rack")
                    .font(WorkbenchTypography.secondary)
                Text("PID \(origin.server.pid!) · \(origin.server.apiKeySHA256 == nil ? "Loopback" : "API key required")")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                Text("Jobs: \(origin.artifactRoot.path)")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).textSelection(.enabled)
                if coordinator?.startOutcomeUnknown == true {
                    Text("The last submission was not confirmed. Check recent jobs before allowing another submission.")
                        .font(WorkbenchTypography.secondary)
                    Button("Allow another submission…") { reviewUncertainty = true }
                        .accessibilityIdentifier("task-resolve-submission")
                }
            }
            if let message = error ?? sessions.error { Text(message).foregroundStyle(WorkbenchColor.failure) }
            if let coordinator {
                InferenceTaskPanel(coordinator: coordinator, model: model, onEngineSetup: onEngineSetup)
                    .id(selectedID).disabled(switching)
            } else if switching { ProgressView("Opening server jobs…") }
        }
        .task {
            await sessions.load()
            if let initialOrigin { await choose(initialOrigin.id) }
        }
        .onChange(of: model.item.path) { _, _ in
            if let old = sessions.origins.first(where: { $0.id == selectedID }).flatMap({ sessions.coordinator(for: $0) }) {
                old.stopPolling(owner: "model-inspector"); old.stopPlayback()
            }
            selectedID = "local"; error = nil
        }
        .alert("Allow another submission?", isPresented: $reviewUncertainty) {
            Button("Keep blocked", role: .cancel) {}
            Button("Allow another submission") {
                guard let origin else { return }
                Task {
                    do { try await sessions.allowAnotherSubmission(origin) }
                    catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text("The server may have accepted the previous job. Review Recent tasks and wait for any active job to finish. This only enables the Start button; it does not submit or cancel a job.")
        }
    }

    private func choose(_ id: String) async {
        guard !switching, coordinator?.busy != true, id != selectedID || coordinator == nil else { return }
        switching = true
        defer { switching = false }
        let previous = coordinator
        do {
            let next: InferenceTaskCoordinator
            if id == "local" { next = oneOff }
            else {
                guard let selected = choices.first(where: { $0.id == id }) else { throw ServedTaskError.changed }
                next = try await sessions.select(selected)
            }
            try await onDestinationChange?(choices.first(where: { $0.id == id }))
            previous?.stopPolling(owner: "model-inspector")
            previous?.stopPlayback()
            if let previous { next.copyDrafts(from: previous) }
            selectedID = id
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct ServedTaskSheet: View {
    let appHost: AppHost
    let presentation: ServedTaskPresentation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack {
                Text(presentation.model.item.name).font(WorkbenchTypography.pageTitle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                TaskDestinationPanel(appHost: appHost, model: presentation.model, initialOrigin: presentation.origin)
            }
        }
        .padding(WorkbenchSpacing.lg)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 560, idealHeight: 760)
    }
}
