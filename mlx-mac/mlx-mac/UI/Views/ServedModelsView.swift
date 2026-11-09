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
            model.readiness == .ready && ModelTaskPresentation.supportsEndpoint(model)
                && !slots.contains { $0.modelPath == model.item.path || model.outputPaths.contains($0.modelPath) }
                && (query.isEmpty || model.displayName.localizedCaseInsensitiveContains(query))
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func canConfirm(model: LibraryModel?, models: [LibraryModel]) -> Bool {
        guard let model, model.item.signature?.isEmpty == false else { return false }
        return models.contains { $0.item.path == model.item.path && $0.item.signature == model.item.signature && $0.readiness == .ready && ModelTaskPresentation.supportsEndpoint($0) }
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
    @ObservedObject private var inventory: ServingInventoryCoordinator
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppRoute.selectionStorageKey) private var selectedRouteID = AppRoute.overview.rawValue
    @State private var query = ""
    @State private var keepModelLoaded = false
    @State private var requireAPIKey = false
    @State private var authenticationReview: EndpointAuthenticationReview?
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
        _inventory = ObservedObject(wrappedValue: appHost.servingInventory)
    }

    private var models: [LibraryModel] { appHost.librarySnapshot?.models ?? [] }

    private func revealModel(_ path: String) {
        appHost.selectedModelPath = path
        appHost.handoffs.send(LibraryRevealRequest(modelPath: path), as: .revealModel)
        selectedRouteID = AppRoute.library.rawValue
        openWindow(id: ServedModelsWindow.mainID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Served models").font(WorkbenchTypography.title)
            Text("Local model servers and saved hosts. Workbench endpoints can load models on request; other services keep their own settings.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            ServingSystemHeadroom(resources: appHost.resources)
            Text("Process RAM is observed resident memory; provider readings and source estimates are separate. Shared pages and GPU allocations prevent adding these values together.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            ErrorBanner(text: error ?? inventory.actionError ?? endpoint.lastError ?? endpoint.persistenceError ?? workflow.serversError)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    ServingInventoryErrors(inventory: inventory)
                    Text("Workbench endpoints").font(WorkbenchTypography.cardTitle)
                    ForEach(endpoint.fleet.slots) { slot in configured(slot) }
                    if endpoint.fleet.slots.isEmpty { Text("No models selected for serving.").foregroundStyle(WorkbenchColor.muted) }
                    Divider()
                    Text("Other local services").font(WorkbenchTypography.cardTitle)
                    let discovered = ServingInventoryPresentation.additionalServices(inventory.snapshot, slots: endpoint.fleet.slots)
                    if discovered.isEmpty {
                        Text(inventory.isRefreshing ? "Reading local services…" : "No other local services reported.")
                            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    }
                    ForEach(discovered) { service in
                        WorkbenchSurface(.tinted, padding: WorkbenchSpacing.sm) {
                            ServingServiceRow(service: service, inventory: inventory) { action in
                                Task { await inventory.prepare(action, service: service) }
                            }
                            if let path = service.modelPath, let model = models.first(where: { $0.item.path == path || $0.outputPaths.contains(path) }) {
                                Button("Show in Library") { revealModel(model.item.path) }.buttonStyle(.borderless)
                            }
                        }
                    }
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
                Button("Refresh status") {
                    Task { await inventory.refresh(refreshHosts: true); await workflow.refreshServers() }
                }.disabled(inventory.isRefreshing)
                Spacer()
                Button("Serving settings…") { openRun() }
            }.buttonStyle(.bordered)
        }
        .padding(WorkbenchSpacing.lg)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 620)
        .sheet(item: $action) { pending in confirmation(pending) }
        .sheet(item: $authenticationReview) { review in authenticationConfirmation(review) }
        .sheet(isPresented: inventoryReviewBinding, onDismiss: {
            inventory.cancelReview()
            Task { await inventory.refresh() }
        }) {
            ServingInventoryReviewSheet(inventory: inventory, hosts: appHost.modelHosts)
        }
    }

    private var inventoryReviewBinding: Binding<Bool> {
        Binding(get: { inventory.actionReview != nil }, set: { if !$0 { inventory.cancelReview() } })
    }

    private func configured(_ slot: EndpointSlot) -> some View {
        let connection = ServedModelsSelection.connection(slot: slot, state: endpoint.slotStates[slot.id], servers: workflow.servers)
        return WorkbenchSurface(.tinted, padding: WorkbenchSpacing.sm) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Text(MenuBarPresentation.modelName(slot.modelPath, models: models)).font(WorkbenchTypography.emphasis)
                Text("MLX Workbench").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                Text(MenuBarPresentation.availability(slot, state: endpoint.slotStates[slot.id], residency: endpoint.slotResidencies[slot.id]))
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                Text(verbatim: "http://127.0.0.1:\(slot.port)/v1").font(WorkbenchTypography.value).textSelection(.enabled)
                if let connection {
                    Text("Model: \(connection.modelName)").font(WorkbenchTypography.secondary).textSelection(.enabled)
                }
                if let service = ServingInventoryPresentation.service(for: slot, in: inventory.snapshot) {
                    ServingServiceDetails(service: service, inventory: inventory)
                    if service.canUnload {
                        Button("Unload model…") { Task { await inventory.prepare(.unload, service: service) } }
                            .disabled(inventory.isChanging || !inventory.mayChange(service))
                    }
                } else {
                    Text(slot.modelPath).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                }
                if models.contains(where: { $0.item.path == slot.modelPath || $0.outputPaths.contains(slot.modelPath) }) {
                    Button("Show in Library") { revealModel(slot.modelPath) }.buttonStyle(.borderless)
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
        if let hash = slot.apiKeySHA256 {
            Text("API key required").font(WorkbenchTypography.metadata)
            Button("Copy API key") {
                do { ServedModelsSelection.copy(try EndpointCredentialStore.token(for: hash)) }
                catch { self.error = AppHost.render(error) }
            }
            if connection == nil, let server = workflow.servers.first(where: { $0.port == slot.port && $0.matchesUnadaptedModel(slot.modelPath) }) {
                Button("Copy model ID") { ServedModelsSelection.copy(server.modelIdentity) }
            }
            Button("Reset API key…") { prepareAuthentication(slot, required: true) }
                .disabled(slot.enabled).help("Stop this endpoint before resetting its key.")
        }
        Button(slot.apiKeySHA256 == nil ? "Require API key…" : "Disable authentication…") {
            prepareAuthentication(slot, required: slot.apiKeySHA256 == nil)
        }.disabled(slot.enabled).help("Stop this endpoint before changing authentication.")
        if workflow.servers.contains(where: { $0.port == slot.port && $0.runtime == "tasks" }) {
            Button("Copy jobs URL") { ServedModelsSelection.copy("http://127.0.0.1:\(slot.port)/v1/tasks") }
        }
        Button("Remove…") { prepare(slot: slot, remove: true) }
        .help("Remove this serving selection. Model files stay in Library.")
    }

    private func prepare(model: LibraryModel) {
        guard let port = ServedModelsSelection.nextPort(slots: endpoint.fleet.slots, servers: workflow.servers) else { return }
        keepModelLoaded = false
        requireAPIKey = false
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
            if !pending.remove && pending.slot == nil {
                Picker("Model residency", selection: $keepModelLoaded) {
                    Text("Release weights after each request").tag(false)
                    Text("Keep loaded between requests").tag(true)
                }.accessibilityIdentifier("serve-model-residency")
                Text("Weights load on the first request. Stop and Unload release them; model files stay in place.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                Toggle("Require API key", isOn: $requireAPIKey).accessibilityIdentifier("serve-model-authentication")
                Text("Only clients with this key can use inference. The endpoint stays on loopback; the key is saved in Keychain.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
            if pending.unverified { InlineMessage(kind: .warning, text: "This model has not passed verification. Confirm only if you intend to serve it unverified.") }
            if let warning = pending.memoryWarning { InlineMessage(kind: .warning, text: warning) }
            HStack {
                Button("Cancel") { action = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(pending.remove ? "Remove selection" : pending.unverified ? "Serve unverified" : "Confirm serving") {
                    let retained = keepModelLoaded
                    let authenticated = requireAPIKey
                    Task { await apply(pending, keepLoaded: retained, requireKey: authenticated) }
                }.buttonStyle(.workbenchPrimary).disabled(endpoint.isChanging)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 460)
    }

    private func apply(_ pending: Action, keepLoaded: Bool, requireKey: Bool) async {
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
            await endpoint.addSlot(modelPath: model.item.path, port: pending.port, allowUnverified: pending.unverified, loadOnRequest: true,
                memoryPolicy: EndpointMemoryPolicy(idleTimeoutSeconds: 0, keepLoaded: keepLoaded, minimumHeadroomGB: 2,
                    releaseAfterRequest: !keepLoaded), requireAPIKey: requireKey)
        }
    }

    private func prepareAuthentication(_ slot: EndpointSlot, required: Bool) {
        Task {
            do { authenticationReview = try await endpoint.previewAuthentication(slot: slot, required: required) }
            catch { self.error = AppHost.render(error) }
        }
    }

    private func authenticationConfirmation(_ review: EndpointAuthenticationReview) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text(review.keySHA256 == nil ? "Disable API key authentication?" : "Require a new API key?")
                .font(WorkbenchTypography.cardTitle)
            Text("Endpoint: 127.0.0.1:\(review.slot.port)").textSelection(.enabled)
            Text(review.keySHA256 == nil ? "Any local client will be able to use this endpoint after you start it."
                 : "Only clients holding the new key can use this endpoint. Copy the key after saving and configure it in each client. Previous keys stop working.")
            Text("The endpoint stays stopped. Model files stay in place.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            HStack {
                Button("Cancel") { authenticationReview = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save authentication") {
                    Task {
                        if await endpoint.confirmAuthentication(review) { authenticationReview = nil }
                        error = endpoint.lastError
                    }
                }.buttonStyle(.workbenchPrimary).disabled(endpoint.isChanging)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 460)
    }

    private func openRun() {
        selectedRouteID = AppRoute.run.rawValue
        openWindow(id: ServedModelsWindow.mainID)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Cached observations only; path matching never resolves files during rendering.
enum ServingInventoryPresentation {
    static func localServices(_ snapshot: ServingInventorySnapshot) -> [ServingServiceObservation] {
        snapshot.services.filter(\.isLocal)
    }

    static func service(for slot: EndpointSlot, in snapshot: ServingInventorySnapshot) -> ServingServiceObservation? {
        localServices(snapshot).first { service in
            service.isWorkbenchManaged && service.server?.port == slot.port && service.server?.matchesUnadaptedModel(slot.modelPath) == true
        }
    }

    static func additionalServices(_ snapshot: ServingInventorySnapshot, slots: [EndpointSlot]) -> [ServingServiceObservation] {
        let configured = Set(slots.compactMap { service(for: $0, in: snapshot)?.id })
        return localServices(snapshot).filter { !configured.contains($0.id) }
    }

    static func linkedServices(for model: LibraryModel, in snapshot: ServingInventorySnapshot) -> [ServingServiceObservation] {
        let paths = Set(([model.item.path] + model.sourcePaths + model.outputPaths).map(normalizedPath))
        return localServices(snapshot).filter { service in
            guard let path = service.modelPath else { return false }
            return paths.contains(normalizedPath(path))
        }
    }

    static func resourceSelection(for service: ServingServiceObservation) -> HostResourceSelection? {
        guard let host = service.host, let model = service.hostedModel else { return nil }
        switch host.provider.adapter.releaseScope {
        case .host: return HostResourceSelection()
        case .model: return HostResourceSelection(modelID: model.modelID)
        case .instance:
            guard let instances = model.loadedInstanceIDs, instances.count == 1 else { return nil }
            return HostResourceSelection(modelID: model.modelID, instanceID: instances[0])
        case nil: return nil
        }
    }

    static func unloadTitle(for service: ServingServiceObservation) -> String {
        switch service.host?.provider.adapter.releaseScope {
        case .host: "Free host memory…"
        case .instance: "Unload instance…"
        default: "Unload model…"
        }
    }

    static func summary(_ snapshot: ServingInventorySnapshot) -> String {
        let local = localServices(snapshot).filter { $0.server != nil || $0.hostedModel != nil }
        guard snapshot.capturedAt != nil else { return "Reading local serving models…" }
        guard !local.isEmpty else { return "No local serving models reported" }
        let unknown = snapshot.unknownCount > 0 ? " · \(snapshot.unknownCount) unknown" : ""
        return "\(snapshot.loadedCount) loaded · \(local.count) local models\(unknown)"
    }

    static func icon(_ snapshot: ServingInventorySnapshot, slots: [EndpointSlot], states: [UUID: EndpointState]) -> String {
        if !snapshot.sourceErrors.isEmpty || snapshot.unknownCount > 0 { return "exclamationmark.triangle" }
        if snapshot.loadedCount > 0 { return "bolt.fill" }
        return MenuBarPresentation.fleetIcon(slots: slots, states: states)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

struct ServingInventoryErrors: View {
    @ObservedObject var inventory: ServingInventoryCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if !inventory.supportsEngineDiscovery {
                Text("This engine reports Workbench endpoints only. Update the engine to discover other MLX Agent servers.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
            }
            ForEach(inventory.snapshot.sourceErrors.keys.sorted(), id: \.self) { source in
                Text(sourceTitle(source) + ": " + (inventory.snapshot.sourceErrors[source] ?? "Unavailable"))
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sourceTitle(_ source: String) -> String {
        if let service = inventory.snapshot.services.first(where: { $0.sourceID == source }) {
            return service.providerName + (service.host.map { " · " + $0.baseURL } ?? "")
        }
        if source == "engine" { return "MLX Agent discovery" }
        if source.hasPrefix("engine:") { return "MLX Agent receipts · " + String(source.dropFirst(7)) }
        return source.hasPrefix("host:") ? "Model host" : source
    }
}

struct ServingSystemHeadroom: View {
    @ObservedObject var resources: SystemResourceMonitor

    var body: some View {
        if let memory = resources.memory {
            Text(String(format: "System headroom: ~%.1f GB available", Double(memory.availableBytes) / 1e9))
                .font(WorkbenchTypography.label.monospacedDigit())
                .foregroundStyle(memory.availableBytes < FitAdvisor.reserveBytes ? WorkbenchColor.warning : WorkbenchColor.ink)
        } else {
            Text("System headroom unavailable").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
        }
    }
}

struct ServingServiceRow: View {
    let service: ServingServiceObservation
    @ObservedObject var inventory: ServingInventoryCoordinator
    let onPrepare: (ServingActionKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text(service.name).font(WorkbenchTypography.emphasis).textSelection(.enabled)
            Text(service.providerName + " · " + service.statusText)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(service.stale || service.residency == .unknown ? WorkbenchColor.warning : WorkbenchColor.muted)
            ServingServiceDetails(service: service, inventory: inventory)
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serving-service-\(service.id)")
    }

    @ViewBuilder private var actions: some View {
        if service.canUnload {
            Button(ServingInventoryPresentation.unloadTitle(for: service)) { onPrepare(.unload) }
                .disabled(inventory.isChanging || !inventory.mayChange(service))
        }
        if service.canStop {
            Button("Stop server…") { onPrepare(.stop) }
                .disabled(inventory.isChanging || !inventory.mayChange(service))
        }
        if let endpoint = service.baseURL {
            Button("Copy base URL") { ServedModelsSelection.copy(endpoint) }
        }
        if service.server != nil || service.hostedModel != nil {
            Button("Copy model ID") { ServedModelsSelection.copy(service.modelID) }
        }
    }
}

struct ServingServiceDetails: View {
    let service: ServingServiceObservation
    @ObservedObject var inventory: ServingInventoryCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
            Text("Model: " + (service.hostedModel == nil && service.server == nil ? "Not reported" : service.modelID)).font(WorkbenchTypography.compactValue)
            Text("Endpoint: " + (service.baseURL ?? "Not reported")).font(WorkbenchTypography.compactValue)
            Text("Model path: " + (service.modelPath ?? "Not reported")).font(WorkbenchTypography.compactValue)
            if let receipts = service.server?.receiptsDirectory {
                Text("Receipts: " + receipts).font(WorkbenchTypography.compactValue)
            }
            if let runtime = service.runtime { Text("Runtime: " + runtime) }
            if let active = service.server?.activeRequests { Text("Active requests: \(active)") }
            if let pid = service.modelProcessID {
                Text("Model process RAM: " + memory(for: pid) + " · PID \(pid)")
            } else {
                Text("Model process RAM: Unknown")
            }
            if let pid = service.server?.pid, pid != service.modelProcessID {
                Text("Server process RAM: " + memory(for: pid) + " · PID \(pid)")
            }
            if let pid = service.hostProcessID {
                Text("Shared host process RAM: " + memory(for: pid) + " · PID \(pid)")
            }
            if let date = inventory.processMemoryCapturedAt, service.modelProcessID != nil || service.server?.pid != nil {
                Text("Process RAM read " + date.formatted(date: .omitted, time: .standard))
            }
            if let bytes = service.reportedMemoryBytes {
                Text("Provider-reported model memory: " + byteCount(bytes))
            }
            if let allocation = service.server?.memoryAllocation {
                if let bytes = allocation.estimatedResidentBytes { Text("Source estimate: " + byteCount(bytes)) }
                if let bytes = allocation.budgetBytes { Text("Configured memory budget: " + byteCount(bytes)) }
                if let mode = allocation.mode { Text("Allocation mode: " + mode) }
            }
            Text("Last observed " + service.capturedAt.formatted(date: .abbreviated, time: .standard))
        }
        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    private func memory(for pid: Int) -> String {
        guard !service.stale, let bytes = inventory.processMemory[pid] else { return "Unknown" }
        return byteCount(Int64(clamping: bytes))
    }

    private func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
}

struct ServingInventoryReviewSheet: View {
    @ObservedObject var inventory: ServingInventoryCoordinator
    @ObservedObject var hosts: ModelHostsCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let review = inventory.actionReview {
            if let host = review.service.host, let selection = ServingInventoryPresentation.resourceSelection(for: review.service) {
                HostResourceSheet(coordinator: hosts, hostID: host.id, selection: selection)
            } else {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    Text(review.action.title + "?").font(WorkbenchTypography.title)
                    Text(review.service.name).font(WorkbenchTypography.emphasis)
                    Text(review.service.providerName + " · " + review.service.statusText)
                        .font(WorkbenchTypography.secondary)
                    ServingServiceDetails(service: review.service, inventory: inventory)
                    Text(review.action == .unload
                         ? "Release model weights and keep the endpoint reachable. Its next request loads the same local files."
                         : "Stop this server. Model files stay in place.")
                        .font(WorkbenchTypography.secondary).fixedSize(horizontal: false, vertical: true)
                    ErrorBanner(text: inventory.actionError)
                    HStack {
                        Button("Cancel") { inventory.cancelReview(); dismiss() }.keyboardShortcut(.cancelAction)
                            .disabled(inventory.isChanging)
                        Spacer()
                        if inventory.isChanging { ProgressView().controlSize(.small) }
                        Button(review.action.title, role: .destructive) { Task { await inventory.confirm() } }
                            .disabled(inventory.isChanging || !inventory.mayChange(review.service))
                            .accessibilityIdentifier("serving-action-confirm")
                    }
                }
                .padding(WorkbenchSpacing.lg).frame(width: 520)
                .interactiveDismissDisabled(inventory.isChanging)
            }
        }
    }
}
