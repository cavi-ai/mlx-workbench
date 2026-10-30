import AppKit
import SwiftUI

enum ServedModelsWindow {
    static let id = "served-models"
    static let mainID = "workbench"
}

enum ServedModelsSelection {
    static func candidates(models: [LibraryModel], slots: [EndpointSlot], query: String) -> [LibraryModel] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.filter { model in
            model.readiness == .ready && ModelTaskPresentation.isServable(model)
                && !slots.contains { $0.modelPath == model.item.path || model.outputPaths.contains($0.modelPath) }
                && (query.isEmpty || model.displayName.localizedCaseInsensitiveContains(query))
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func canConfirm(model: LibraryModel?, models: [LibraryModel]) -> Bool {
        guard let model, model.item.signature?.isEmpty == false else { return false }
        return models.contains { $0.item.path == model.item.path && $0.item.signature == model.item.signature && $0.readiness == .ready && ModelTaskPresentation.isServable($0) }
    }

    static func nextPort(slots: [EndpointSlot], servers: [ServerInfo]) -> Int? {
        let used = Set(slots.map(\.port) + servers.compactMap(\.port))
        return (EndpointConfig.defaultPort...65535).first { !used.contains($0) }
    }

    static func connection(slot: EndpointSlot, state: EndpointState?, servers: [ServerInfo]) -> WireEndpoint? {
        guard slot.enabled, case .running(let path, let port) = state,
              path == slot.modelPath, port == slot.port,
              let server = servers.first(where: { $0.port == slot.port && $0.matchesUnadaptedModel(slot.modelPath) }) else { return nil }
        return WireEndpoint(server: server)
    }

    static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

/// A focused selection surface over the same fleet Run and the menu bar use.
struct ServedModelsView: View {
    let appHost: AppHost
    @ObservedObject private var endpoint: EndpointSupervisor
    @ObservedObject private var workflow: ModelWorkflowCoordinator
    @ObservedObject private var comparison: ComparisonCoordinator
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppRoute.selectionStorageKey) private var selectedRouteID = AppRoute.overview.rawValue
    @State private var query = ""
    @State private var action: Action?
    @State private var error: String?

    private struct Action: Identifiable {
        let id = UUID()
        let model: LibraryModel?
        let slot: EndpointSlot?
        let port: Int
        let memoryWarning: String?
        let unverified: Bool
        let remove: Bool
    }

    init(appHost: AppHost) {
        self.appHost = appHost
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _workflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _comparison = ObservedObject(wrappedValue: appHost.comparison)
    }

    private var models: [LibraryModel] { appHost.librarySnapshot?.models ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Served models").font(WorkbenchTypography.title)
            Text("Use these OpenAI-compatible endpoints in other apps. Models load on request; idle models unload automatically.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            ErrorBanner(text: error ?? endpoint.lastError ?? endpoint.persistenceError ?? workflow.serversError)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    ForEach(endpoint.fleet.slots) { slot in configured(slot) }
                    if endpoint.fleet.slots.isEmpty { Text("No models selected for serving.").foregroundStyle(WorkbenchColor.muted) }
                    Divider()
                    HStack {
                        Text("Add a model").font(WorkbenchTypography.cardTitle)
                        Spacer()
                        Text("\(endpoint.fleet.slots.count) of \(EndpointFleetConfig.maxSlots)").font(WorkbenchTypography.secondaryTabular)
                    }
                    TextField("Search ready models", text: $query).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search models to serve")
                    let candidates = ServedModelsSelection.candidates(models: models, slots: endpoint.fleet.slots, query: query)
                    if candidates.isEmpty {
                        Text(models.isEmpty ? "Scan Library to find local models." : "No matching models available to add.")
                            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    }
                    ForEach(candidates, id: \.item.path) { model in
                        HStack(spacing: WorkbenchSpacing.sm) {
                            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                                Text(model.displayName).font(WorkbenchTypography.emphasis).textSelection(.enabled)
                                Text(ByteCountFormatter.string(fromByteCount: model.item.bytes, countStyle: .file))
                                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                            }
                            Spacer(minLength: WorkbenchSpacing.sm)
                            Button("Add…") { prepare(model: model) }
                                .disabled(endpoint.isChanging || endpoint.fleet.slots.count >= EndpointFleetConfig.maxSlots || !comparison.hasLoadedHistory || model.item.signature?.isEmpty != false)
                                .help("Scan Library for a ready model with a recorded identity before adding it.")
                                .accessibilityLabel("Add \(model.displayName) to served models")
                        }
                    }
                }
            }
            HStack {
                Button("Refresh status") { Task { await workflow.refreshServers() } }
                Spacer()
                Button("Serving settings…") { openRun() }
            }.buttonStyle(.bordered)
        }
        .padding(WorkbenchSpacing.lg)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 620)
        .sheet(item: $action) { pending in confirmation(pending) }
    }

    private func configured(_ slot: EndpointSlot) -> some View {
        let connection = ServedModelsSelection.connection(slot: slot, state: endpoint.slotStates[slot.id], servers: workflow.servers)
        return WorkbenchSurface(.tinted, padding: WorkbenchSpacing.sm) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Text(MenuBarPresentation.modelName(slot.modelPath, models: models)).font(WorkbenchTypography.emphasis)
                Text(MenuBarPresentation.availability(slot, state: endpoint.slotStates[slot.id], residency: endpoint.slotResidencies[slot.id]))
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                Text(verbatim: "http://127.0.0.1:\(slot.port)/v1").font(WorkbenchTypography.value).textSelection(.enabled)
                if let connection {
                    Text("Model: \(connection.modelName)").font(WorkbenchTypography.secondary).textSelection(.enabled)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { slotActions(slot, connection: connection) }
                    VStack(alignment: .leading) { slotActions(slot, connection: connection) }
                }.disabled(endpoint.isChanging || !comparison.hasLoadedHistory)
            }
        }
    }

    @ViewBuilder
    private func slotActions(_ slot: EndpointSlot, connection: WireEndpoint?) -> some View {
        Button(slot.enabled ? "Stop" : "Start…") {
            if slot.enabled { Task { guard canStop(slot) else { return }; await endpoint.setSlotEnabled(id: slot.id, false) } }
            else { prepare(slot: slot, remove: false) }
        }
        Button("Copy base URL") { ServedModelsSelection.copy("http://127.0.0.1:\(slot.port)/v1") }
        if let connection { Button("Copy model ID") { ServedModelsSelection.copy(connection.modelName) } }
        Button("Remove…") { prepare(slot: slot, remove: true) }
        .help("Remove this serving selection. Model files stay in Library.")
    }

    private func prepare(model: LibraryModel) {
        guard let port = ServedModelsSelection.nextPort(slots: endpoint.fleet.slots, servers: workflow.servers) else { return }
        action = Action(model: model, slot: nil, port: port, memoryWarning: memoryWarning(for: model.item.path),
                        unverified: !appHost.isModelVerified(model.item.path), remove: false)
    }

    private func prepare(slot: EndpointSlot, remove: Bool) {
        action = Action(model: models.first { $0.item.path == slot.modelPath || $0.outputPaths.contains(slot.modelPath) }, slot: slot, port: slot.port,
                        memoryWarning: remove ? nil : memoryWarning(for: slot.modelPath),
                        unverified: !remove && !appHost.isModelVerified(slot.modelPath), remove: remove)
    }

    private func memoryWarning(for path: String) -> String? {
        guard let verdict = appHost.runFleetVerdict(adding: path) else { return nil }
        if case .fits = verdict { return nil }
        return verdict.summary
    }

    private func canStop(_ slot: EndpointSlot) -> Bool {
        guard comparison.hasLoadedHistory, !appHost.occupancy.blocksStop(modelIdentity: slot.modelPath) else {
            error = "Finish the operation using this model before stopping or removing its endpoint."
            return false
        }
        return true
    }

    private func confirmation(_ pending: Action) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text(pending.remove ? "Remove serving selection?" : "Serve this model?").font(WorkbenchTypography.cardTitle)
            Text(pending.model?.displayName ?? pending.slot?.modelPath ?? "Model").textSelection(.enabled)
            Text(verbatim: pending.remove ? "Its endpoint will stop. Model files stay in Library." : "Other apps can connect to http://127.0.0.1:\(pending.port)/v1.")
            if pending.unverified { InlineMessage(kind: .warning, text: "This model has not passed verification. Confirm only if you intend to serve it unverified.") }
            if let warning = pending.memoryWarning { InlineMessage(kind: .warning, text: warning) }
            HStack {
                Button("Cancel") { action = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(pending.remove ? "Remove selection" : pending.unverified ? "Serve unverified" : "Confirm serving") {
                    Task { await apply(pending) }
                }.buttonStyle(.workbenchPrimary).disabled(endpoint.isChanging)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 460)
    }

    private func apply(_ pending: Action) async {
        action = nil; error = nil
        if let slot = pending.slot {
            guard endpoint.fleet.slots.contains(slot), canStop(slot) else { error = error ?? "Endpoint changed; review it again."; return }
            if pending.remove { await endpoint.removeSlot(id: slot.id) }
            else {
                guard ServedModelsSelection.canConfirm(model: pending.model, models: models) else {
                    error = "Model changed or is unavailable. Refresh Library and review serving again."; return
                }
                guard pending.memoryWarning == memoryWarning(for: slot.modelPath) else { error = "Memory conditions changed; review serving again."; return }
                if pending.unverified || appHost.isModelVerified(slot.modelPath) {
                    // Start retains the existing supervisor's verification and receipt checks.
                    await endpoint.setSlotEnabled(id: slot.id, true)
                } else { error = "Verification changed; review serving again." }
            }
        } else if let model = pending.model {
            guard ServedModelsSelection.canConfirm(model: model, models: models),
                  ServedModelsSelection.candidates(models: models, slots: endpoint.fleet.slots, query: "").contains(where: { $0.item.path == model.item.path }),
                  ServedModelsSelection.nextPort(slots: endpoint.fleet.slots, servers: workflow.servers) == pending.port,
                  pending.memoryWarning == memoryWarning(for: model.item.path) else {
                error = "Model, port or memory conditions changed; review serving again."; return
            }
            await endpoint.addSlot(modelPath: model.item.path, port: pending.port, allowUnverified: pending.unverified, loadOnRequest: true)
        }
    }

    private func openRun() {
        selectedRouteID = AppRoute.run.rawValue
        openWindow(id: ServedModelsWindow.mainID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
