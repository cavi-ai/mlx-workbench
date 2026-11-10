import AppKit
import SwiftUI

enum ServedModelsWindow {
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
    /// Compact rows keep the reviewed actions inline, move copy actions into a menu and fold the details away.
    var compact = false
    let onPrepare: (ServingActionKind) -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xs) {
                Text(service.name).font(WorkbenchTypography.emphasis).textSelection(.enabled)
                    .lineLimit(compact ? 1 : nil).truncationMode(.middle)
                Spacer(minLength: WorkbenchSpacing.xs)
                if compact { copyMenu }
            }
            Text(service.providerName + " · " + service.statusText)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(service.stale || service.residency == .unknown ? WorkbenchColor.warning : WorkbenchColor.muted)
            if compact {
                DisclosureGroup("Details", isExpanded: $showsDetails) {
                    ServingServiceDetails(service: service, inventory: inventory).padding(.top, WorkbenchSpacing.xxs)
                }
                .font(WorkbenchTypography.secondary)
                .accessibilityLabel("Details for \(service.name)")
            } else {
                ServingServiceDetails(service: service, inventory: inventory)
            }
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serving-service-\(service.id)")
    }

    private var copyMenu: some View {
        Menu {
            copyActions
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: WorkbenchSize.Run.overflow)
        .accessibilityLabel("Actions for \(service.name)")
    }

    @ViewBuilder private var copyActions: some View {
        if let endpoint = service.baseURL {
            Button("Copy base URL") { ServedModelsSelection.copy(endpoint) }
        }
        if service.server != nil || service.hostedModel != nil {
            Button("Copy model ID") { ServedModelsSelection.copy(service.modelID) }
        }
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
        if !compact { copyActions }
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
