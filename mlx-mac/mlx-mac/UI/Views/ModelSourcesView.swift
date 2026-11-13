import SwiftUI

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
            if let sourceID, service?.sourceID != sourceID { return false }
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
    private var selected: ServingRow? { rows.first { $0.id == selectedID } }
    private var sourceChoices: [(id: String, title: String)] {
        var titles: [String: String] = [:]
        for service in inventory.snapshot.services {
            titles[service.sourceID] = service.providerName + (service.host.map { " · " + $0.baseURL } ?? "")
        }
        return titles.map { (id: $0.key, title: $0.value) }.sorted { $0.title < $1.title }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack { introduction; Spacer(); connectionActions }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) { introduction; connectionActions }
            }
            Picker("Show", selection: $foldersSelected) {
                Text("Server models").tag(false)
                Text("Model folders").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 400)
            if foldersSelected { folders }
            else { serverModels }
        }
        .padding(WorkbenchSpacing.lg)
        .sheet(item: $editor) { host in
            ModelHostEditor(host: host, coordinator: hosts, onSaved: { _ in
                Task { await inventory.refresh(refreshHosts: true) }
            })
        }
        .onChange(of: rows.map(\.id), initial: true) { _, ids in
            if selectedID == nil || !ids.contains(selectedID ?? "") { selectedID = ids.first }
        }
        .onChange(of: sourceChoices.map(\.id)) { _, ids in
            if let sourceID, !ids.contains(sourceID) { self.sourceID = nil }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text("Models across your Mac").font(WorkbenchTypography.cardTitle)
            Text("Connect local providers and reuse the model files you already have.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
        }
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

    private var serverModels: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack { filters; Spacer(); refresh }
                VStack(alignment: .leading) { filters; refresh }
            }
            Table(rows, selection: $selectedID) {
                TableColumn("Model") { row in
                    Text(ServingWorkspacePresentation.name(row, models: appHost.librarySnapshot?.models ?? []))
                        .lineLimit(1).truncationMode(.middle)
                }.width(min: 150, ideal: 240)
                TableColumn("Provider") { row in
                    Text(ServingWorkspacePresentation.service(row)?.providerName ?? "MLX Workbench")
                }.width(min: 100, ideal: 145)
                TableColumn("State") { row in
                    ServingStatusLabel(row: row, states: endpoint.slotStates, text: ServingWorkspacePresentation.service(row)?.statusText)
                }.width(min: 110, ideal: 160)
                TableColumn("API address") { row in
                    Text(ServingWorkspacePresentation.baseURL(row) ?? "Not reported").lineLimit(1).truncationMode(.middle)
                }.width(min: 150, ideal: 240)
            }.alternatingRowBackgrounds(.disabled).accessibilityIdentifier("sources-model-table")
                .overlay {
                    if rows.isEmpty {
                        ContentUnavailableView("No models reported", systemImage: "server.rack",
                            description: Text("Refresh local providers, add a connection, or browse registered files in Library."))
                    }
                }
            if let selected { modelDetails(selected) }
            if !inventory.snapshot.sourceErrors.isEmpty {
                DisclosureGroup("\(inventory.snapshot.sourceErrors.count) connection issue\(inventory.snapshot.sourceErrors.count == 1 ? "" : "s")") {
                    ForEach(inventory.snapshot.sourceErrors.keys.sorted(), id: \.self) { key in
                        Text((sourceChoices.first { $0.id == key }?.title ?? "Local discovery") + ": " + (inventory.snapshot.sourceErrors[key] ?? ""))
                            .font(WorkbenchTypography.secondary).textSelection(.enabled)
                    }
                }.font(WorkbenchTypography.secondary)
            }
            Text("Inventories include loaded and available models. Provider entries can share the same weights; they are not counted as separate disk usage.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
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
    private func modelDetails(_ row: ServingRow) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text(ServingWorkspacePresentation.modelID(row)).font(WorkbenchTypography.compactValue).textSelection(.enabled)
            if let path = ServingWorkspacePresentation.service(row)?.modelPath ?? ServingWorkspacePresentation.server(row)?.path {
                Text("Model files: " + path).font(WorkbenchTypography.secondary).textSelection(.enabled)
            } else {
                Text("This provider has not reported a model folder. Registered caches are listed in Model folders.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            HStack {
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
        }.padding(WorkbenchSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
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
