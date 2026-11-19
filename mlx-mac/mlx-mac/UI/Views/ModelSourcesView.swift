import SwiftUI
import AppKit

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

private struct ModelSourceListRow: View {
    let source: ModelSourceRow
    let selected: Bool
    var body: some View {
        HStack(spacing: WorkbenchSpacing.md) {
            Image(systemName: "cube.transparent").foregroundStyle(WorkbenchColor.muted)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Text(source.model).lineLimit(1).truncationMode(.middle).accessibilityIdentifier("sources-model-cell")
                Text(source.provider).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            Spacer(minLength: WorkbenchSpacing.sm)
            Text(source.state).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted).lineLimit(1)
        }.foregroundStyle(WorkbenchColor.ink)
            .padding(.horizontal, WorkbenchSpacing.md)
            .padding(.vertical, WorkbenchSpacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    WorkbenchColor.canvas.overlay(WorkbenchColor.surface)
                        .overlay(alignment: .leading) { Rectangle().fill(WorkbenchColor.accent).frame(width: 3) }
                }
            }
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
    @State private var showingDetails = false
    @State private var pendingEditor: ModelHost?
    @State private var showingIssues = false
    @State private var sortField = "Model"

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
        return VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: WorkbenchSpacing.md) {
                    workspacePicker
                    Spacer(minLength: 0)
                    if !foldersSelected { connectionActions }
                }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    workspacePicker
                    if !foldersSelected { connectionActions }
                }
            }
            Divider()
            Spacer().frame(height: WorkbenchSpacing.md)
            if foldersSelected { folders }
            else { serverModels(catalog) }
        }
        .padding(WorkbenchSpacing.lg)
        .sheet(isPresented: $showingDetails, onDismiss: {
            if let host = pendingEditor { pendingEditor = nil; editor = host }
        }) {
            if let selected = catalog.first(where: { $0.id == selectedID }) {
                VStack(alignment: .trailing, spacing: 0) {
                    Button("Done") { showingDetails = false }.padding(WorkbenchSpacing.md)
                    detailPane(selected)
                }.frame(minWidth: 420, minHeight: 420)
            }
        }
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
        HStack(spacing: WorkbenchSpacing.lg) {
            sourceTab("Server models", selected: !foldersSelected) { foldersSelected = false }
            sourceTab("Model folders", selected: foldersSelected) { foldersSelected = true }
        }
    }
    private func sourceTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: WorkbenchSpacing.sm) {
                Text(title).font(WorkbenchTypography.emphasis)
                    .foregroundStyle(selected ? WorkbenchColor.ink : WorkbenchColor.muted)
                Rectangle().fill(selected ? Color.accentColor : .clear).frame(height: 2)
            }.fixedSize(horizontal: true, vertical: false)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var connectionActions: some View {
        HStack(spacing: WorkbenchSpacing.sm) {
            Menu {
                ForEach(hosts.knownHosts) { host in
                    Button(host.name + " · " + host.baseURL) { editor = host }
                }
                if hosts.knownHosts.isEmpty { Text("No provider connections") }
            } label: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Connections").accessibilityLabel("Connections")
                .disabled(hosts.knownHosts.isEmpty || hosts.resourceBusy)
            Button {
                editor = ModelHost(name: ModelHostProvider.ollama.title, provider: .ollama,
                                   baseURL: ModelHostProvider.ollama.defaultURL)
            } label: { Label("Add provider", systemImage: "plus") }
                .buttonStyle(.workbenchPrimary)
                .disabled(hosts.storageError != nil || hosts.resourceBusy)
                .accessibilityIdentifier("sources-add-provider")
        }
    }

    private func serverModels(_ catalog: [ModelSourceRow]) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.sm) { search; filters; refresh; issues }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    search
                    HStack(spacing: WorkbenchSpacing.sm) { filters; refresh; issues }
                }
            }
            GeometryReader { geometry in
                if geometry.size.width >= 720 {
                    HStack(spacing: 0) {
                        catalogList(catalog, narrow: false).frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider().padding(.horizontal, WorkbenchSpacing.md)
                        detailPane(catalog.first { $0.id == selectedID })
                            .frame(width: min(340, max(280, geometry.size.width * 0.34)), height: geometry.size.height)
                    }
                } else {
                    catalogList(catalog, narrow: true)
                }
            }
        }
    }
    private var search: some View {
        HStack(spacing: WorkbenchSpacing.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(WorkbenchColor.muted)
            TextField("Search models", text: $query).textFieldStyle(.plain)
                .accessibilityIdentifier("sources-model-filter")
        }.padding(WorkbenchSpacing.sm)
            .background(WorkbenchColor.surface, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
            .overlay(RoundedRectangle(cornerRadius: WorkbenchRadius.control).stroke(WorkbenchColor.hairline))
    }
    private var filters: some View {
        HStack(spacing: WorkbenchSpacing.xs) {
            Picker("Provider", selection: $sourceID) {
                Text("All providers").tag(String?.none)
                ForEach(sourceChoices, id: \.id) { source in Text(source.title).tag(Optional(source.id)) }
            }.labelsHidden().frame(maxWidth: 155).accessibilityIdentifier("sources-provider-picker")
            Menu {
                Button("Model") { sortField = "Model"; sortOrder = [KeyPathComparator(\ModelSourceRow.model)] }
                Button("Provider") { sortField = "Provider"; sortOrder = [KeyPathComparator(\ModelSourceRow.provider)] }
                Button("Status") { sortField = "Status"; sortOrder = [KeyPathComparator(\ModelSourceRow.state)] }
            } label: { Image(systemName: "arrow.up.arrow.down") }
                .help("Sort by \(sortField)").accessibilityLabel("Sort models")
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var refresh: some View {
        Button {
            Task { await workflow.refreshServers(); await inventory.refresh(refreshHosts: true) }
        } label: { Image(systemName: "arrow.clockwise") }
            .help(inventory.isRefreshing ? "Refreshing…" : "Refresh")
            .accessibilityLabel("Refresh").disabled(inventory.isRefreshing).accessibilityIdentifier("sources-refresh")
    }
    @ViewBuilder private var issues: some View {
        if !inventory.snapshot.sourceErrors.isEmpty {
            Button { showingIssues.toggle() } label: { Image(systemName: "exclamationmark.triangle") }
                .help("Connection issues").accessibilityLabel("Connection issues")
                .popover(isPresented: $showingIssues) {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                        Text("Connection issues").font(WorkbenchTypography.emphasis)
                        ForEach(inventory.snapshot.sourceErrors.keys.sorted(), id: \.self) { key in
                            Text((inventory.snapshot.services.first { $0.sourceID == key }.map { $0.providerName + ($0.host.map { " · " + $0.baseURL } ?? "") } ?? "Local discovery") + ": " + (inventory.snapshot.sourceErrors[key] ?? ""))
                                .font(WorkbenchTypography.secondary).textSelection(.enabled)
                        }
                    }.padding(WorkbenchSpacing.md).frame(minWidth: 280, maxWidth: 420)
                }
        }
    }
    private func catalogList(_ catalog: [ModelSourceRow], narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                Text("Models").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                Spacer()
                Text("\(catalog.count)").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                if narrow, selectedID != nil {
                    Button("Connection details") { showingDetails = true }
                        .accessibilityIdentifier("sources-show-details")
                }
            }
            List(catalog, selection: $selectedID) { source in
                ModelSourceListRow(source: source, selected: source.id == selectedID)
                    .listRowInsets(EdgeInsets()).tag(source.id)
            }.listStyle(.plain).accessibilityIdentifier("sources-model-list")
                .overlay {
                    if catalog.isEmpty {
                        ContentUnavailableView {
                            Label(query.isEmpty && sourceID == nil ? "No models reported" : "No matching models", systemImage: "server.rack")
                        } description: {
                            Text(query.isEmpty && sourceID == nil ? "Refresh or add a provider to browse its models." : "Try a different search or provider.")
                        } actions: {
                            if !query.isEmpty || sourceID != nil {
                                Button("Clear filters") { query = ""; sourceID = nil }
                            } else { refresh }
                        }
                    }
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
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    ForEach(selected.members) { row in modelDetails(row) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Select a model to inspect its connections.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(WorkbenchSpacing.sm)
    }
    private func modelDetails(_ row: ServingRow) -> some View {
        let host = ServingWorkspacePresentation.service(row)?.host
        let server = ServingWorkspacePresentation.server(row)
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                Text(ServingWorkspacePresentation.provider(row)).font(WorkbenchTypography.emphasis).lineLimit(1)
                Spacer(minLength: WorkbenchSpacing.sm)
                ServingStatusLabel(row: row, states: endpoint.slotStates, text: ServingWorkspacePresentation.service(row)?.statusText)
                if host != nil || server != nil {
                    Menu {
                        if let host {
                            Button("Connection settings…") {
                                if showingDetails { pendingEditor = host; showingDetails = false }
                                else { editor = host }
                            }.disabled(hosts.resourceBusy)
                            if hosts.hosts.contains(host) {
                                Button("Open provider inventory") {
                                    showingDetails = false
                                    appHost.handoffs.send(HostedModelsRequest(host: host), as: .openHostedModels)
                                    onRouteSelection(.library)
                                }
                            }
                        }
                        if server != nil {
                            Button("Open model settings") {
                                showingDetails = false
                                appHost.handoffs.send(ServingFocusRequest(rowID: row.id), as: .openServing)
                                onRouteSelection(.run)
                            }
                        }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("Connection actions").accessibilityLabel("Actions for " + ServingWorkspacePresentation.provider(row))
                }
            }
            if let address = ServingWorkspacePresentation.baseURL(row) {
                HStack {
                    Text(address).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).help("Copy API address").accessibilityLabel("Copy API address")
                }
            }
            if let path = ServingWorkspacePresentation.service(row)?.modelPath ?? server?.path {
                Text("Model files: " + path).font(WorkbenchTypography.secondary).textSelection(.enabled)
            }
            Divider()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var folders: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                HStack {
                    Spacer()
                    Button("Manage folders…") { onRouteSelection(.settings) }.buttonStyle(.workbenchPrimary)
                }
                let folders = ModelSourcesPresentation.folders(appHost.config)
                let managedPath = URL(fileURLWithPath: appHost.config.outputDir).standardizedFileURL.path
                if let managed = folders.first(where: { $0.path == managedPath }) {
                    folderSection("Managed", folders: [managed])
                }
                folderSection("Registered", folders: folders.filter { $0.path != managedPath })
                HStack(spacing: WorkbenchSpacing.md) {
                    Button("Browse local files") { onRouteSelection(.library) }
                    Button("Review duplicates") { onRouteSelection(.reclaim) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func folderSection(_ title: String, folders: [ModelSourceFolder]) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text(title).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            ForEach(folders) { folder in
                HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                    Image(systemName: "folder").foregroundStyle(WorkbenchColor.muted)
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        Text(folder.uses.joined(separator: " · ")).font(WorkbenchTypography.emphasis)
                        Text(folder.path).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                    }
                    Spacer()
                }.padding(.vertical, WorkbenchSpacing.sm)
                Divider()
            }
        }
    }
}
