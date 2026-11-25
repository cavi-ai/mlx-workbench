import SwiftUI

enum ServingWorkspacePresentation {
    /// The count is how many sources missed the latest refresh. The sheet lists each one.
    static func sourceIssueTitle(_ count: Int) -> String {
        count == 1
            ? "1 source did not answer the latest refresh."
            : "\(count) sources did not answer the latest refresh."
    }
    enum Section: String, CaseIterable {
        case live = "Live endpoints", saved = "Saved configurations", available = "Available from other apps"
    }
    static func section(_ row: ServingRow) -> Section {
        if isRunning(row) { return .live }
        if case .endpoint = row { return .saved }
        return .available
    }
    static func rows(_ rows: [ServingRow], includeAvailable: Bool) -> [ServingRow] {
        rows.filter { row in
            guard case .service(let service) = row else { return true }
            guard !service.stale, service.modelID != "__inventory__" else { return false }
            if let server = service.server { return server.state == "running" }
            return includeAvailable || [.loaded, .loading, .unloading].contains(service.residency)
        }
    }
    static func name(_ row: ServingRow, models: [LibraryModel]) -> String {
        switch row {
        case .endpoint(let slot, _, _): return MenuBarPresentation.modelName(slot.modelPath, models: models)
        case .server(let server, _): return MenuBarPresentation.modelName(server.modelIdentity, models: models) + (server.adapterSummary.map { " · " + $0 } ?? "")
        case .service(let service):
            if let name = service.hostedModel?.name { return name }
            if let server = service.server {
                return MenuBarPresentation.modelName(server.path ?? server.modelIdentity, models: models) + (server.adapterSummary.map { " · " + $0 } ?? "")
            }
            return service.modelPath.map { MenuBarPresentation.modelName($0, models: models) } ?? service.modelID
        }
    }
    static func server(_ row: ServingRow) -> ServerInfo? {
        if let observation = service(row), !observation.stale, let server = observation.server { return server }
        switch row {
        case .endpoint(_, let server, _): return server
        case .server(let server, _): return server
        case .service(let service): return service.server
        }
    }
    static func service(_ row: ServingRow) -> ServingServiceObservation? {
        switch row {
        case .endpoint(_, _, let service), .server(_, let service): service
        case .service(let service): service
        }
    }
    static func status(_ row: ServingRow, states: [UUID: EndpointState] = [:]) -> String {
        if case .endpoint(let slot, let server, _) = row, server == nil { return MenuBarPresentation.availability(slot, state: states[slot.id], residency: nil) }
        if let server = server(row) {
            if (server.activeRequests ?? 0) > 0 { return "Busy" }
            switch server.modelState {
            case "loaded": return "Loaded"
            case "unloaded": return "Ready on request"
            case "loading": return "Loading"
            case "unloading": return "Unloading"
            case "failed": return "Needs attention"
            default: return server.state == "running" ? "Running · residency unknown" : "Stopped"
            }
        }
        return service(row)?.statusText ?? "Unavailable"
    }
    static func provider(_ row: ServingRow) -> String {
        if let service = service(row), !service.isWorkbenchManaged { return service.providerName }
        switch server(row)?.runtime {
        case "strata": return "Strata"
        case "splash": return "Splash"
        case "mlx_lm": return "MLX-LM"
        case "mlx-vlm": return "MLX-VLM"
        case "tasks": return "Task server"
        default: return "Workbench"
        }
    }
    static func baseURL(_ row: ServingRow) -> String? {
        if case .endpoint(let slot, _, _) = row { return "http://127.0.0.1:\(slot.port)/v1" }
        if let server = server(row), let port = server.port { return "http://127.0.0.1:\(port)/v1" }
        return service(row)?.baseURL
    }
    static func modelID(_ row: ServingRow) -> String {
        if let server = server(row) { return server.modelIdentity }
        if case .endpoint(let slot, _, _) = row { return slot.modelPath }
        return service(row)?.modelID ?? ""
    }
    /// Related endpoints require a concrete local model path and existing model identity evidence.
    static func siblingEndpoints(of row: ServingRow, in rows: [ServingRow]) -> [ServingRow] {
        let path: String
        if let current = server(row) {
            guard let value = current.path, current.adapterPath == nil, current.adapterIdentity == nil,
                  current.adapterStatus == nil, current.trainingBinding == nil else { return [] }
            path = value
        } else if case .endpoint(let slot, _, _) = row { path = slot.modelPath }
        else { return [] }
        guard path.hasPrefix("/") else { return [] }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return rows.filter { candidate in
            guard candidate.id != row.id, isRunning(candidate), let other = server(candidate),
                  let otherPath = other.path, otherPath.hasPrefix("/"), other.adapterPath == nil,
                  other.adapterIdentity == nil, other.adapterStatus == nil, other.trainingBinding == nil else { return false }
            return URL(fileURLWithPath: otherPath).standardizedFileURL.path == normalized
        }
    }
    static func isRunning(_ row: ServingRow) -> Bool {
        if service(row)?.stale == true { return false }
        if let server = server(row) { return server.state == "running" }
        return service(row).map { !$0.stale && [.loaded, .loading, .unloading].contains($0.residency) && $0.modelID != "__inventory__" } ?? false
    }

    /// Why a running row needs attention, in the engine's words; nil when it does not.
    static func attentionReason(_ row: ServingRow) -> String? {
        guard isRunning(row), let server = server(row), server.modelState == "failed" else { return nil }
        return server.lastError.flatMap { $0.isEmpty ? nil : $0 } ?? "The model failed to load. The server log has the details."
    }

    static let attentionNextStep = "The next request loads the model again. Stop the server to release it."

    /// Running rows that need attention first, the rest in their order.
    static func attentionFirst(_ rows: [ServingRow]) -> [ServingRow] {
        rows.filter { attentionReason($0) != nil } + rows.filter { attentionReason($0) == nil }
    }

    /// Running rows counted the way their status reads: attention, in memory, loading, or loaded on request.
    static func tally(_ rows: [ServingRow]) -> ServingTally {
        rows.filter(isRunning).reduce(into: ServingTally()) { tally, row in
            if attentionReason(row) != nil { tally.attention += 1; return }
            switch server(row)?.modelState ?? service(row)?.residency.rawValue {
            case "loaded": tally.loaded += 1
            case "unloaded": tally.onRequest += 1
            case "loading": tally.loading += 1
            case "unloading": tally.unloading += 1
            default: tally.unknown += 1
            }
        }
    }
}

struct ServingSiblingEndpoints: View {
    let row: ServingRow
    let rows: [ServingRow]
    let onSelect: (String) -> Void
    var body: some View {
        let siblings = ServingWorkspacePresentation.siblingEndpoints(of: row, in: rows)
        if !siblings.isEmpty {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Text("Same model at other endpoints").font(WorkbenchTypography.label)
                ForEach(siblings) { sibling in
                    Button("\(ServingWorkspacePresentation.baseURL(sibling) ?? "Address unavailable") · \(ServingWorkspacePresentation.status(sibling))") {
                        onSelect(sibling.id)
                    }.buttonStyle(.link).fixedSize(horizontal: false, vertical: true)
                }
                Text("Each endpoint can be managed separately.").foregroundStyle(WorkbenchColor.muted)
            }.font(WorkbenchTypography.secondary)
        }
    }
}

struct ServingTally: Equatable {
    var attention = 0
    var loaded = 0
    var loading = 0
    var unloading = 0
    var onRequest = 0
    var unknown = 0
}

/// A row's status; one that needs attention is a link that explains itself in place.
struct ServingStatusLabel: View {
    let row: ServingRow
    let states: [UUID: EndpointState]
    var text: String? = nil
    @State private var explaining = false

    var body: some View {
        let status = text ?? ServingWorkspacePresentation.status(row, states: states)
        if let reason = ServingWorkspacePresentation.attentionReason(row) {
            Button { explaining = true } label: {
                Label(status, systemImage: "exclamationmark.triangle.fill")
            }
            .buttonStyle(.link)
            .foregroundStyle(WorkbenchColor.failure)
            .help(reason)
            .accessibilityHint("Shows why this model needs attention")
            .popover(isPresented: $explaining, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    Text(status).font(WorkbenchTypography.emphasis)
                    Text(reason).textSelection(.enabled)
                    Text(ServingWorkspacePresentation.attentionNextStep).foregroundStyle(WorkbenchColor.muted)
                }
                .font(WorkbenchTypography.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading)
                .padding(WorkbenchSpacing.md)
            }
        } else {
            Text(status)
        }
    }
}

private struct ServingModelRow: View {
    let row: ServingRow
    let models: [LibraryModel]
    let states: [UUID: EndpointState]
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            HStack {
                Text(ServingWorkspacePresentation.name(row, models: models)).font(WorkbenchTypography.emphasis).lineLimit(2)
                Spacer(minLength: WorkbenchSpacing.xs)
                if let port = ServingWorkspacePresentation.server(row)?.port {
                    Text(verbatim: ":\(port)").font(WorkbenchTypography.compactValue).foregroundStyle(prominence == .increased ? WorkbenchColor.onSelection : WorkbenchColor.muted)
                } else if case .endpoint(let slot, _, _) = row {
                    Text(verbatim: ":\(slot.port)").font(WorkbenchTypography.compactValue).foregroundStyle(prominence == .increased ? WorkbenchColor.onSelection : WorkbenchColor.muted)
                }
            }
            HStack(spacing: WorkbenchSpacing.xs) {
                Circle().fill(dotColor).frame(width: 7, height: 7).accessibilityHidden(true)
                if case .endpoint(let slot, _, _) = row, let role = slot.role {
                    Text(role.title)
                    Text("·")
                }
                Text(ServingWorkspacePresentation.provider(row))
                Text("·")
                ServingStatusLabel(row: row, states: states)
            }.font(WorkbenchTypography.metadata).foregroundStyle(prominence == .increased ? WorkbenchColor.onSelection : WorkbenchColor.muted).lineLimit(1)
        }
        .foregroundStyle(prominence == .increased ? WorkbenchColor.onSelection : WorkbenchColor.ink)
        .help(ServingWorkspacePresentation.baseURL(row) ?? "")
    }

    private var dotColor: Color {
        if ServingWorkspacePresentation.attentionReason(row) != nil { return WorkbenchColor.failure }
        return ServingWorkspacePresentation.isRunning(row) ? WorkbenchColor.success : WorkbenchColor.muted.opacity(0.5)
    }
}

struct ServingModelList: View {
    let appHost: AppHost
    let roleRows: [ServingRolesPresentation.RoleRow]
    let endpointRows: [ServingRow]
    let otherRows: [ServingRow]
    let slots: [EndpointSlot]
    let models: [LibraryModel]
    let states: [UUID: EndpointState]
    let sourceIssueCount: Int
    @Binding var selectedID: String?
    @Binding var includesAvailable: Bool
    let choose: (ServingRole, LibraryModel) -> Void
    let change: (EndpointSlot, LibraryModel) -> Void
    let toggle: (EndpointSlot) -> Void
    let add: () -> Void
    let monitor: () -> Void
    let refresh: () -> Void
    let showSources: () -> Void
    @State private var query = ""
    @State private var showsKeyWizard = false
    @State private var othersExpanded = false
    @State private var rolesExpanded = false
    private func visible(_ rows: [ServingRow]) -> [ServingRow] {
        rows.filter { query.isEmpty || (ServingWorkspacePresentation.name($0, models: models) + " " + ServingWorkspacePresentation.provider($0)).localizedCaseInsensitiveContains(query) }
    }

    private func modelMenu(_ title: String, role: ServingRole, assigned: Bool, pick: @escaping (LibraryModel) -> Void) -> some View {
        let candidates = ServingRolesPresentation.candidates(for: role, models: models, slots: slots)
        return Menu(title) {
            ForEach(candidates, id: \.item.path) { model in
                Button(model.displayName) { pick(model) }
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(candidates.isEmpty)
        .help(candidates.isEmpty ? "No ready \(role.title) models in Library." : "")
        .accessibilityIdentifier("serving-role-\(role.rawValue)-\(assigned ? "change" : "choose")")
    }

    @ViewBuilder
    private func roleRow(_ entry: ServingRolesPresentation.RoleRow) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            HStack {
                Label(entry.title, systemImage: entry.role.symbolName).font(WorkbenchTypography.emphasis)
                Spacer(minLength: WorkbenchSpacing.xs)
                if entry.isAssigned {
                    Text(verbatim: entry.portText).font(WorkbenchTypography.compactValue).foregroundStyle(WorkbenchColor.muted)
                }
            }
            if let slot = entry.slot, let row = entry.row {
                Text(ServingWorkspacePresentation.name(row, models: models)).font(WorkbenchTypography.secondary).lineLimit(1)
                ServingStatusLabel(row: row, states: states).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted).lineLimit(1)
                HStack {
                    Button(slot.enabled ? "Stop" : "Start…") { toggle(slot) }.buttonStyle(.borderless)
                        .accessibilityIdentifier("serving-role-\(entry.role.rawValue)-toggle")
                    modelMenu("Change model…", role: entry.role, assigned: true) { change(slot, $0) }
                }
            } else {
                Text(entry.unassignedText).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                modelMenu("Choose model…", role: entry.role, assigned: false) { choose(entry.role, $0) }
            }
        }
        .padding(.vertical, WorkbenchSpacing.xs)
        .tag(entry.row?.id ?? entry.id)
        .accessibilityIdentifier("serving-\(entry.id)")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                Text("Endpoints").font(WorkbenchTypography.cardTitle)
                Spacer()
                Button { showsKeyWizard = true } label: { Image(systemName: "key") }.buttonStyle(.borderless)
                    .accessibilityLabel("Workbench key").help("Workbench key…").accessibilityIdentifier("serving-workbench-key")
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).accessibilityLabel("Refresh serving models")
            }.padding(.horizontal, WorkbenchSpacing.md).padding(.top, WorkbenchSpacing.md)
                .sheet(isPresented: $showsKeyWizard) { WorkbenchKeyWizard(appHost: appHost) }
            Button(action: add) {
                Label("Load model…", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.workbenchPrimary).controlSize(.large).padding(.horizontal, WorkbenchSpacing.md)
            .accessibilityIdentifier("serving-add-model")
            TextField("Filter", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, WorkbenchSpacing.md)
                .accessibilityIdentifier("serving-model-filter")
            List(selection: $selectedID) {
                Section {
                    if visible(endpointRows).isEmpty {
                        Text(endpointRows.isEmpty ? "No endpoints yet. Load a model to get an address." : "No endpoints match the filter.")
                            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(visible(endpointRows)) { row in
                        ServingModelRow(row: row, models: models, states: states)
                            .padding(.vertical, WorkbenchSpacing.xs).tag(row.id)
                            .accessibilityIdentifier("serving-model-\(row.id)")
                    }
                }
                Section {
                    DisclosureGroup(ServingRolesPresentation.rolesTitle(roleRows), isExpanded: $rolesExpanded) {
                        ForEach(roleRows) { roleRow($0) }
                    }.accessibilityIdentifier("serving-roles")
                }
                Section {
                    WorkbenchAPIRowView(appHost: appHost, coordinator: appHost.frontDoor, endpoint: appHost.endpoint)
                        .accessibilityIdentifier("serving-workbench-api")
                }
                Section {
                    DisclosureGroup(ServingRolesPresentation.othersTitle(count: otherRows.count), isExpanded: $othersExpanded) {
                        ForEach(visible(otherRows)) { row in
                            ServingModelRow(row: row, models: models, states: states)
                                .padding(.vertical, WorkbenchSpacing.xs).tag(row.id)
                                .accessibilityIdentifier("serving-model-\(row.id)")
                        }
                    }.accessibilityIdentifier("serving-other-servers")
                }
            }.listStyle(.sidebar).accessibilityIdentifier("serving-model-list")
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                Toggle("Include available models", isOn: $includesAvailable).toggleStyle(.checkbox)
                    .font(WorkbenchTypography.secondary).accessibilityIdentifier("serving-include-available")
                Button("Open live Monitor", action: monitor).buttonStyle(.borderless)
                if sourceIssueCount > 0 {
                    Button(ServingWorkspacePresentation.sourceIssueTitle(sourceIssueCount), action: showSources)
                        .buttonStyle(.borderless).foregroundStyle(WorkbenchColor.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("serving-source-issues")
                }
            }.padding(WorkbenchSpacing.md)
        }.frame(minWidth: WorkbenchSize.Serving.sidebar, idealWidth: WorkbenchSize.Serving.sidebar, maxWidth: WorkbenchSize.Serving.sidebar)
    }
}

struct ServingConnectionField: View {
    let title: String
    let value: String
    var identifier: String? = nil
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text(title).font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
            HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
                Text(value).font(WorkbenchTypography.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { ServedModelsSelection.copy(value) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).accessibilityLabel("Copy \(title.lowercased())")
                    .accessibilityIdentifier(identifier ?? "serving-copy-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
            }
        }.padding(compact ? 0 : WorkbenchSpacing.md)
            .background(compact ? Color.clear : WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
    }
}
