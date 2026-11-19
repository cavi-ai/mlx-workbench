import SwiftUI

/// A catalog entry retains each connection's original observation and actions.
struct ModelSourceRow: Identifiable {
    struct GroupKey: Hashable { let modelID: String; let digest: String }
    let members: [ServingRow]
    let model: String
    let provider: String
    let state: String
    var id: String { members.map(\.id).sorted().first ?? "" }
    var row: ServingRow { members[0] }
    static let defaultSortOrder = [KeyPathComparator(\ModelSourceRow.model)]

    static func rows(_ rows: [ServingRow], models: [LibraryModel], sortOrder: [KeyPathComparator<ModelSourceRow>]) -> [ModelSourceRow] {
        var groups: [[ServingRow]] = []
        var keys: [GroupKey: [Int]] = [:]
        for row in rows {
            let service = ServingWorkspacePresentation.service(row)
            if case .service = row, let service, service.host?.provider == .ollama,
               let digest = service.hostedModel?.digest, !digest.isEmpty,
               let address = service.baseURL, !address.isEmpty {
                let key = GroupKey(modelID: service.modelID, digest: digest)
                if let index = keys[key]?.first(where: { index in
                    !groups[index].contains { ServingWorkspacePresentation.baseURL($0) == address }
                }) {
                    groups[index].append(row)
                } else {
                    keys[key, default: []].append(groups.count)
                    groups.append([row])
                }
            } else { groups.append([row]) }
        }
        return groups.map { members in
            let first = members[0]
            let service = ServingWorkspacePresentation.service(first)
            return ModelSourceRow(members: members, model: ServingWorkspacePresentation.name(first, models: models),
                                  provider: service?.host?.provider == .ollama ? "Ollama" : (service?.providerName ?? "MLX Workbench"),
                                  state: members.count > 1 ? "\(members.count) connections" : (service?.statusText ?? ServingWorkspacePresentation.status(first)))
        }.sorted(using: sortOrder.isEmpty ? defaultSortOrder : sortOrder)
    }
}

struct ModelSourceFolder: Identifiable, Equatable {
    let path: String
    let uses: [String]
    var id: String { path }
}

enum ModelSourcesPresentation {
    static func folders(_ config: Config) -> [ModelSourceFolder] {
        var uses: [String: Set<String>] = [:]
        for (paths, purpose) in [(config.ggufRoots, "GGUF"), (config.mlxRoots, "MLX"), ([config.outputDir], "Managed downloads & conversions")] {
            for path in paths where !path.isEmpty {
                uses[URL(fileURLWithPath: path).standardizedFileURL.path, default: []].insert(purpose)
            }
        }
        return uses.map { ModelSourceFolder(path: $0.key, uses: $0.value.sorted()) }.sorted { $0.path < $1.path }
    }

    static func rows(slots: [EndpointSlot], servers: [ServerInfo], snapshot: ServingInventorySnapshot,
                     sourceID: String?, query: String) -> [ServingRow] {
        ServingRows.build(slots: slots, servers: servers, snapshot: snapshot).filter { row in
            let service = ServingWorkspacePresentation.service(row)
            guard service?.modelID != "__inventory__" else { return false }
            if let sourceID {
                if sourceID == "provider:ollama" { if service?.host?.provider != .ollama { return false } }
                else if service?.sourceID != sourceID { return false }
            }
            return query.isEmpty || [ServingWorkspacePresentation.modelID(row), service?.name ?? "", service?.providerName ?? "MLX Workbench"]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

/// Provider inventories and registered folders share the existing discovery and storage owners.
struct ModelSourcesView: View {
    let appHost: AppHost
    let onRouteSelection: (AppRoute) -> Void
    @ObservedObject private var hosts: ModelHostsCoordinator
    @ObservedObject private var inventory: ServingInventoryCoordinator
    @ObservedObject private var endpoint: EndpointSupervisor
    @ObservedObject private var workflow: ModelWorkflowCoordinator
    @State private var foldersSelected = false
    @State private var sourceID: String?
    @State private var selectedID: String?
    @State private var query = ""
    @State private var sortOrder = ModelSourceRow.defaultSortOrder
    @State private var editor: ModelHost?

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost; self.onRouteSelection = onRouteSelection
        _hosts = ObservedObject(wrappedValue: appHost.modelHosts)
        _inventory = ObservedObject(wrappedValue: appHost.servingInventory)
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _workflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
    }

    private var rows: [ServingRow] {
        ModelSourcesPresentation.rows(slots: endpoint.fleet.slots, servers: workflow.servers,
                                      snapshot: inventory.snapshot, sourceID: sourceID, query: query)
    }
    private var catalog: [ModelSourceRow] { ModelSourceRow.rows(rows, models: appHost.librarySnapshot?.models ?? [], sortOrder: sortOrder) }
    private var sourceChoices: [(id: String, title: String)] {
        var titles: [String: String] = [:]
        for service in inventory.snapshot.services {
            if service.host?.provider == .ollama { titles["provider:ollama"] = "Ollama" }
            else { titles[service.sourceID] = service.providerName + (service.host.map { " · " + $0.baseURL } ?? "") }
        }
        return titles.map { (id: $0.key, title: $0.value) }.sorted { $0.title < $1.title }
    }

    var body: some View {
        let catalog = catalog
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack { workspacePicker; Spacer(); connectionActions }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) { workspacePicker; connectionActions }
            }
            if foldersSelected { folders }
            else { serverModels(catalog) }
        }
        .padding(WorkbenchSpacing.lg)
        .sheet(item: $editor) { host in
            ModelHostEditor(host: host, coordinator: hosts, onSaved: { _ in
                Task { await inventory.refresh(refreshHosts: true) }
            })
        }
        .onChange(of: catalog.map(\.id), initial: true) { _, ids in
            if selectedID == nil || !ids.contains(selectedID ?? "") { selectedID = ids.first }
        }
        .onChange(of: sourceChoices.map(\.id)) { _, ids in
            if let sourceID, !ids.contains(sourceID) { self.sourceID = nil }
        }
    }

    private var workspacePicker: some View {
        Picker("Show", selection: $foldersSelected) {
            Text("Server models").tag(false)
            Text("Model folders").tag(true)
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 400)
    }
    private var connectionActions: some View {
        HStack {
            Menu("Connections") {
                ForEach(hosts.knownHosts) { host in
                    Button(host.name + " · " + host.baseURL) { editor = host }
                }
                if hosts.knownHosts.isEmpty { Text("No provider connections") }
            }.disabled(hosts.knownHosts.isEmpty || hosts.resourceBusy)
            Button {
                editor = ModelHost(name: ModelHostProvider.ollama.title, provider: .ollama,
                                   baseURL: ModelHostProvider.ollama.defaultURL)
            } label: { Label("Add provider…", systemImage: "plus") }
                .disabled(hosts.storageError != nil || hosts.resourceBusy)
                .accessibilityIdentifier("sources-add-provider")
        }
    }

    private func serverModels(_ catalog: [ModelSourceRow]) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack { filters; Spacer(); refresh }
                VStack(alignment: .leading) { filters; refresh }
            }
            GeometryReader { geometry in
                if geometry.size.width >= 720 {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                        catalogTable(catalog).frame(width: geometry.size.width - min(360, max(280, geometry.size.width * 0.34)) - WorkbenchSpacing.md)
                        detailPane(catalog.first { $0.id == selectedID }).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: WorkbenchSpacing.md) {
                        catalogTable(catalog).frame(maxHeight: .infinity)
                        detailPane(catalog.first { $0.id == selectedID }).frame(height: min(230, geometry.size.height * 0.38))
                    }
                }
            }
            if !inventory.snapshot.sourceErrors.isEmpty {
                DisclosureGroup("\(inventory.snapshot.sourceErrors.count) connection issue\(inventory.snapshot.sourceErrors.count == 1 ? "" : "s")") {
                    ForEach(inventory.snapshot.sourceErrors.keys.sorted(), id: \.self) { key in
                        Text((inventory.snapshot.services.first { $0.sourceID == key }.map { $0.providerName + ($0.host.map { " · " + $0.baseURL } ?? "") } ?? "Local discovery") + ": " + (inventory.snapshot.sourceErrors[key] ?? ""))
                            .font(WorkbenchTypography.secondary).textSelection(.enabled)
                    }
                }.font(WorkbenchTypography.secondary)
            }
        }
    }
    private var filters: some View {
        HStack {
            Picker("Provider", selection: $sourceID) {
                Text("All providers").tag(String?.none)
                ForEach(sourceChoices, id: \.id) { source in Text(source.title).tag(Optional(source.id)) }
            }.frame(maxWidth: 340).accessibilityIdentifier("sources-provider-picker")
            TextField("Filter models", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("sources-model-filter")
        }
    }
    private var refresh: some View {
        Button {
            Task { await workflow.refreshServers(); await inventory.refresh(refreshHosts: true) }
        } label: { Label(inventory.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise") }
            .disabled(inventory.isRefreshing).accessibilityIdentifier("sources-refresh")
    }
    private func catalogTable(_ catalog: [ModelSourceRow]) -> some View {
        Table(catalog, selection: $selectedID, sortOrder: $sortOrder) {
            TableColumn("Model", value: \.model) { source in
                Text(source.model).lineLimit(1).truncationMode(.middle).accessibilityIdentifier("sources-model-cell")
            }.width(min: 150, ideal: 260)
            TableColumn("Provider", value: \.provider) { source in Text(source.provider).lineLimit(1) }
                .width(min: 90, ideal: 120)
            TableColumn("Status", value: \.state) { source in
                if source.members.count > 1 { Text(source.state).foregroundStyle(WorkbenchColor.muted) }
                else { ServingStatusLabel(row: source.row, states: endpoint.slotStates, text: ServingWorkspacePresentation.service(source.row)?.statusText) }
            }.width(min: 120, ideal: 160)
        }.alternatingRowBackgrounds(.disabled).accessibilityIdentifier("sources-model-table")
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No models reported", systemImage: "server.rack",
                        description: Text("Refresh local providers, add a connection, or browse registered files in Library."))
                }
            }
    }
    private func detailPane(_ selected: ModelSourceRow?) -> some View {
        ScrollView {
            if let selected {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    Text(selected.model).font(WorkbenchTypography.cardTitle).textSelection(.enabled)
                    if ServingWorkspacePresentation.modelID(selected.row) != selected.model {
                        Text(ServingWorkspacePresentation.modelID(selected.row)).font(WorkbenchTypography.secondary).textSelection(.enabled)
                    }
                    Text(selected.members.count == 1 ? "Connection" : "\(selected.members.count) connections")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    ForEach(selected.members) { row in modelDetails(row) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Select a model to inspect its connections.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(WorkbenchSpacing.md)
            .background(WorkbenchColor.surface, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
    }
    private func modelDetails(_ row: ServingRow) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(ServingWorkspacePresentation.provider(row)).font(WorkbenchTypography.emphasis)
                    Spacer()
                    ServingStatusLabel(row: row, states: endpoint.slotStates, text: ServingWorkspacePresentation.service(row)?.statusText)
                }
                VStack(alignment: .leading) {
                    Text(ServingWorkspacePresentation.provider(row)).font(WorkbenchTypography.emphasis)
                    ServingStatusLabel(row: row, states: endpoint.slotStates, text: ServingWorkspacePresentation.service(row)?.statusText)
                }
            }
            if let address = ServingWorkspacePresentation.baseURL(row) {
                Text(address).font(WorkbenchTypography.compactValue).textSelection(.enabled)
            }
            if let path = ServingWorkspacePresentation.service(row)?.modelPath ?? ServingWorkspacePresentation.server(row)?.path {
                Text("Model files: " + path).font(WorkbenchTypography.secondary).textSelection(.enabled)
            }
            if ServingWorkspacePresentation.service(row)?.host != nil || ServingWorkspacePresentation.server(row) != nil {
                Menu("Actions") {
                    if let host = ServingWorkspacePresentation.service(row)?.host {
                        Button("Connection settings…") { editor = host }.disabled(hosts.resourceBusy)
                        if hosts.hosts.contains(host) {
                            Button("Open provider inventory") {
                                appHost.handoffs.send(HostedModelsRequest(host: host), as: .openHostedModels)
                                onRouteSelection(.library)
                            }
                        }
                    }
                    if ServingWorkspacePresentation.server(row) != nil {
                        Button("Open model settings") {
                            appHost.handoffs.send(ServingFocusRequest(rowID: row.id), as: .openServing)
                            onRouteSelection(.run)
                        }
                    }
                }
            }
            Divider()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var folders: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                Text("New downloads and conversions use the managed folder. Existing caches stay in place and are scanned only when registered.")
                    .font(WorkbenchTypography.secondary)
                ForEach(ModelSourcesPresentation.folders(appHost.config)) { folder in
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        Text(folder.uses.joined(separator: " · ")).font(WorkbenchTypography.emphasis)
                        Text(folder.path).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                    }.padding(WorkbenchSpacing.md).frame(maxWidth: .infinity, alignment: .leading)
                        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                }
                ViewThatFits(in: .horizontal) {
                    HStack { folderActions }
                    VStack(alignment: .leading) { folderActions }
                }
                Text("Model updates reuse matching source files and prepare a new MLX version when needed. Review the replacement before retiring the previous version.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
        }
    }
    @ViewBuilder private var folderActions: some View {
        Button("Browse local files") { onRouteSelection(.library) }
        Button("Review duplicates") { onRouteSelection(.reclaim) }
        Button("Manage model folders…") { onRouteSelection(.settings) }
    }
}
