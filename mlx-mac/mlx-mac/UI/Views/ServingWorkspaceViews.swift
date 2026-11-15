import SwiftUI

enum ServingWorkspaceTab: String, CaseIterable, Identifiable {
    case connection, inference, memory, clients
    var id: String { rawValue }
    var title: String {
        switch self {
        case .connection: "API & security"
        case .inference: "Inference"
        case .memory: "Memory"
        case .clients: "Connect apps"
        }
    }
}

enum ServingWorkspacePresentation {
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
        case .endpoint(let slot, _, _): MenuBarPresentation.modelName(slot.modelPath, models: models)
        case .server(let server, _): MenuBarPresentation.modelName(server.modelIdentity, models: models) + (server.adapterSummary.map { " · " + $0 } ?? "")
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
                Text(ServingWorkspacePresentation.provider(row))
                Text("·")
                ServingStatusLabel(row: row, states: states)
            }.font(WorkbenchTypography.metadata).foregroundStyle(prominence == .increased ? WorkbenchColor.onSelection : WorkbenchColor.muted).lineLimit(1)
            if let address = ServingWorkspacePresentation.baseURL(row) {
                Text(address).font(WorkbenchTypography.metadata).foregroundStyle(prominence == .increased ? WorkbenchColor.onSelection : WorkbenchColor.muted).lineLimit(1).truncationMode(.middle).help(address)
            }
        }.foregroundStyle(prominence == .increased ? WorkbenchColor.onSelection : WorkbenchColor.ink)
    }
}

struct ServingModelList: View {
    let rows: [ServingRow]
    let models: [LibraryModel]
    let states: [UUID: EndpointState]
    let sourceIssueCount: Int
    @Binding var selectedID: String?
    @Binding var includesAvailable: Bool
    let add: () -> Void
    let monitor: () -> Void
    let refresh: () -> Void
    let showSources: () -> Void
    @State private var query = ""
    private var visibleRows: [ServingRow] {
        rows.filter { query.isEmpty || (ServingWorkspacePresentation.name($0, models: models) + " " + ServingWorkspacePresentation.provider($0)).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                Text("Endpoints").font(WorkbenchTypography.cardTitle)
                Spacer()
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).accessibilityLabel("Refresh serving models")
                Button(action: add) { Image(systemName: "plus") }.buttonStyle(.borderless).accessibilityLabel("Serve a model").accessibilityIdentifier("serving-add-model")
            }.padding(.horizontal, WorkbenchSpacing.md).padding(.top, WorkbenchSpacing.md)
            TextField("Filter models", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, WorkbenchSpacing.md)
                .accessibilityIdentifier("serving-model-filter")
            List(selection: $selectedID) {
                ForEach(ServingWorkspacePresentation.Section.allCases, id: \.self) { section in
                    let entries = visibleRows.filter { ServingWorkspacePresentation.section($0) == section }
                    if !entries.isEmpty { Section(section.rawValue) {
                ForEach(entries) { row in
                    ServingModelRow(row: row, models: models, states: states)
                        .padding(.vertical, WorkbenchSpacing.xs).tag(row.id)
                        .accessibilityIdentifier("serving-model-\(row.id)")
                }
                    } }
                }
            }.listStyle(.sidebar).accessibilityIdentifier("serving-model-list")
            .overlay {
                if rows.isEmpty { ContentUnavailableView("No endpoints", systemImage: "server.rack", description: Text("Serve a model to get started.")) }
                else if visibleRows.isEmpty { ContentUnavailableView.search(text: query) }
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                Toggle("Include available models", isOn: $includesAvailable).toggleStyle(.checkbox)
                    .font(WorkbenchTypography.secondary).accessibilityIdentifier("serving-include-available")
                Button("Open live Monitor", action: monitor).buttonStyle(.borderless)
                if sourceIssueCount > 0 {
                    Button("Connection issues (\(sourceIssueCount))", action: showSources)
                        .buttonStyle(.borderless).foregroundStyle(WorkbenchColor.muted)
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
