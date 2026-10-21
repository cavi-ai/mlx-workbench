import SwiftUI

struct HostedModelsView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var hosts: ModelHostsCoordinator
    let onRouteSelection: (AppRoute) -> Void
    private let suppliedHostSelection: Binding<UUID?>?
    @State private var selectedHostID: UUID?
    @State private var selectedModelID: String?
    @State private var editor: ModelHost?
    @State private var removing: ModelHost?
    @State private var actionError: String?
    @State private var query = ""
    @State private var selectedInstanceID: String?
    @State private var resourceRequest: HostResourceRequest?

    init(appHost: AppHost, selectedHostID: Binding<UUID?>? = nil, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost; self.onRouteSelection = onRouteSelection
        self.suppliedHostSelection = selectedHostID
        _selectedHostID = State(initialValue: selectedHostID == nil ? appHost.modelHosts.hosts.first?.id : nil)
        _hosts = ObservedObject(wrappedValue: appHost.modelHosts)
    }

    private var hostSelection: Binding<UUID?> { suppliedHostSelection ?? $selectedHostID }
    private var selectedHost: ModelHost? { hosts.hosts.first { $0.id == hostSelection.wrappedValue } }
    private var inventory: HostInventory? { selectedHost.flatMap { hosts.inventories[$0.id] } }
    private var selectedModel: HostedModel? { inventory?.models.first { $0.id == selectedModelID } }
    private var rows: [HostedModel] {
        (inventory?.models ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
            || $0.modelID.localizedCaseInsensitiveContains(query) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                ViewThatFits(in: .horizontal) {
                    HStack { hostControls; Spacer(); actions }
                    VStack(alignment: .leading) { hostControls; actions }
                }
                ErrorBanner(text: hosts.storageError ?? actionError)
                if let host = selectedHost {
                    Label(host.baseURL, systemImage: "network").font(WorkbenchTypography.compactValue).textSelection(.enabled)
                    resourceControls(host)
                    if hosts.resourceHostID == host.id, let message = hosts.resourceMessage {
                        Text(message).font(WorkbenchTypography.secondary).textSelection(.enabled)
                            .accessibilityIdentifier("host-resource-result")
                    }
                    if let error = hosts.errors[host.id] {
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                            ErrorBanner(text: error)
                            HStack {
                                Button("Retry refresh") { Task { await hosts.refresh(host.id) } }
                                    .disabled(hosts.refreshing.contains(host.id))
                                    .accessibilityIdentifier("retry-model-host-refresh")
                                    .help("Read this host's inventory again without loading models.")
                                Button("Edit connection…") { editor = host }
                                    .disabled(appHost.hostedComparison.activeRunID != nil || hosts.resourceBusy)
                                    .accessibilityIdentifier("repair-model-host-connection")
                                    .help("Review the server URL, provider and credential before saving changes.")
                            }.controlSize(.small)
                        }
                    }
                    if let inventory {
                        inventoryContent(inventory)
                    } else {
                        ContentUnavailableView {
                            Label(hosts.refreshing.contains(host.id) ? "Reading model inventory" : "Read this host's models", systemImage: "externaldrive.connected.to.line.below")
                        } description: {
                            Text("Refresh reads the host's inventory without loading or generating models.")
                        } actions: { refreshButton(host) }
                    }
                } else {
                    ContentUnavailableView {
                        Label(hosts.hosts.isEmpty ? "Connect a local model host" : "Choose a model host", systemImage: "externaldrive.connected.to.line.below")
                    } description: {
                        Text(hosts.hosts.isEmpty
                            ? "See models managed by Ollama, LM Studio, ComfyUI or an OpenAI-compatible server."
                            : "Choose a saved connection above, or add another model host.")
                    } actions: {
                        Button("Add host…") { addHost() }.buttonStyle(.workbenchPrimary)
                    }
                }
            }
            .padding(WorkbenchSpacing.pageInset)
        }
        .accessibilityIdentifier("hosted-models-workspace")
        .onChange(of: appHost.handoffs[.openHostedModels], initial: true) { _, _ in
            guard suppliedHostSelection == nil else { return }
            do {
                guard let host = try appHost.takeHostedModelsHost() else { return }
                hostSelection.wrappedValue = host.id; selectedModelID = nil; selectedInstanceID = nil
                query = ""; actionError = nil
            } catch { actionError = AppHost.render(error) }
        }
        .onChange(of: hostSelection.wrappedValue) { _, _ in selectedModelID = nil; selectedInstanceID = nil }
        .onChange(of: hosts.hosts) { _, saved in
            if let id = hostSelection.wrappedValue, !saved.contains(where: { $0.id == id }) { hostSelection.wrappedValue = nil }
        }
        .sheet(item: $editor) { host in
            ModelHostEditor(host: host, coordinator: hosts, onSaved: { hostSelection.wrappedValue = $0.id })
        }
        .sheet(item: $resourceRequest) { request in
            HostResourceSheet(coordinator: hosts, hostID: request.hostID, selection: request.selection)
        }
        .onChange(of: selectedModelID) { _, _ in selectedInstanceID = nil }
        .confirmationDialog("Remove \(removing?.name ?? "host")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove host", role: .destructive) {
                guard let host = removing else { return }
                do { try hosts.remove(host.id); selectedModelID = nil; actionError = nil }
                catch { actionError = AppHost.render(error) }
                removing = nil
            }
        } message: { Text("This removes the saved connection and credential. Models and host processes stay where they are.") }
    }

    private var hostControls: some View {
        HStack {
            Picker("Host", selection: hostSelection) {
                Text(hosts.hosts.isEmpty ? "No hosts" : "Select a host").tag(UUID?.none)
                ForEach(hosts.hosts) { Text(LibrarySource.host($0.id).title(in: hosts.hosts)).tag(Optional($0.id)) }
            }.frame(maxWidth: 320).accessibilityIdentifier("model-host-picker")
            if let host = selectedHost {
                Menu {
                    Button("Edit host…") { editor = host }
                    Button("Remove host…", role: .destructive) { removing = host }
                } label: { Label("Host options", systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(appHost.hostedComparison.activeRunID != nil || hosts.resourceBusy)
                .help("Edit or remove this connection when comparisons are idle.")
            }
        }
    }

    private var actions: some View {
        HStack {
            if let host = selectedHost { refreshButton(host) }
            Button("Add host…") { addHost() }.disabled(hosts.storageError != nil || hosts.resourceBusy)
        }
    }

    private func refreshButton(_ host: ModelHost) -> some View {
        Button { Task { await hosts.refresh(host.id) } } label: {
            Label(hosts.refreshing.contains(host.id) ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(hosts.refreshing.contains(host.id))
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .accessibilityIdentifier("refresh-model-host")
    }

    private func inventoryContent(_ inventory: HostInventory) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(inventory.models.count)").font(WorkbenchTypography.display)
                Text("models reported").foregroundStyle(WorkbenchColor.muted)
                Spacer()
                if hosts.refreshing.contains(inventory.host.id) { ProgressView().controlSize(.small) }
                Text(inventory.capturedAt, style: .time).font(WorkbenchTypography.secondary)
            }
            HStack {
                TextField("Filter models", text: $query).textFieldStyle(.roundedBorder)
                Button("Compare…") { compare(inventory) }
                    .buttonStyle(.workbenchPrimary)
                    .disabled(selectedModel == nil || appHost.hostedComparison.activeRunID != nil || hosts.errors[inventory.host.id] != nil)
                    .help("Select a model from a successfully refreshed inventory, then review the comparison setup.")
            }
            Table(rows, selection: $selectedModelID) {
                TableColumn("Model", value: \.name).width(min: 180)
                TableColumn("State") { model in Text(Self.state(model)) }.width(min: 80, ideal: 100)
                TableColumn("Parameters") { model in Text(model.parameters ?? "Unknown") }.width(min: 75, ideal: 90)
                TableColumn("Quantization") { model in Text(model.quantization ?? "Unknown") }.width(min: 80, ideal: 95)
                TableColumn("Size") { model in Text(Self.bytes(model.sizeBytes)) }.width(min: 80, ideal: 100)
            }
            .frame(minHeight: 300, idealHeight: 390)
            .accessibilityIdentifier("hosted-model-table")
            if rows.isEmpty { Label("No models match this inventory or filter.", systemImage: "line.3.horizontal.decrease.circle").foregroundStyle(WorkbenchColor.muted) }
            if let running = inventory.runningModels {
                DisclosureGroup("Reported running models (\(running.count))") {
                    HostedRunningModelsView(models: inventory.reportedLoadedModels)
                }.accessibilityIdentifier("host-running-models")
            }
            if let model = selectedModel {
                DisclosureGroup("Reported model details") {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        if inventory.host.provider == .ollama {
                            Button("Read model details") {
                                Task { await hosts.readModelDetails(inventory.host.id, modelID: model.modelID) }
                            }
                            .disabled(hosts.refreshing.contains(inventory.host.id) || hosts.resourceBusy
                                || hosts.errors[inventory.host.id] != nil || model.digest?.isEmpty != false)
                            .help(model.digest?.isEmpty != false
                                ? "A reported installed digest is required. Refresh the host first."
                                : "Refresh inventory and read this model's reported maximum context and capabilities.")
                            .accessibilityIdentifier("read-host-model-details")
                        }
                        HostedModelDetailsView(model: model)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, WorkbenchSpacing.xs)
                }
            }
            if let version = inventory.runtimeVersion { Text("Runtime version: \(version)").font(WorkbenchTypography.secondary) }
            if let device = inventory.deviceSummary { Text(device).font(WorkbenchTypography.secondary) }
            if inventory.host.provider == .comfyUI { HostDeviceMemoryDisclosure(snapshot: inventory.deviceMemory) }
            ForEach(inventory.warnings, id: \.self) { Label($0, systemImage: "info.circle").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted) }
            Text("Host-reported metadata · \(inventory.capturedAt.formatted(date: .abbreviated, time: .standard))")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
        }
    }

    @ViewBuilder
    private func resourceControls(_ host: ModelHost) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if let activity = inventory?.activity { HostActivityLabel(activity: activity) }
            switch host.provider {
            case .comfyUI:
                Button("Free host memory…") { resourceRequest = HostResourceRequest(hostID: host.id, selection: HostResourceSelection()) }
                    .disabled(hosts.resourceBusy || hosts.resourceUseBlocked())
                    .accessibilityIdentifier("host-resource-open")
                    .help("Review activity before requesting cleanup of all cached ComfyUI models.")
            case .ollama, .lmStudio:
                if let model = selectedModel, model.isLoaded == true {
                    let instances = model.loadedInstanceIDs ?? []
                    let instance = instances.count == 1 ? instances.first : selectedInstanceID.flatMap { instances.contains($0) ? $0 : nil }
                    HStack {
                        if host.provider == .lmStudio, instances.count > 1 {
                            Picker("Loaded instance", selection: $selectedInstanceID) {
                                Text("Choose instance").tag(String?.none)
                                ForEach(instances, id: \.self) { Text($0).tag(Optional($0)) }
                            }.frame(maxWidth: 300).accessibilityIdentifier("host-resource-instance")
                        }
                        Button(host.provider == .lmStudio ? "Unload instance…" : "Unload model…") {
                            resourceRequest = HostResourceRequest(hostID: host.id,
                                selection: HostResourceSelection(modelID: model.modelID, instanceID: host.provider == .lmStudio ? instance : nil))
                        }.disabled(hosts.resourceBusy || hosts.resourceUseBlocked() || (host.provider == .lmStudio && instance == nil))
                            .accessibilityIdentifier("host-resource-open")
                            .help("Check current activity and review the exact target before unloading.")
                    }
                    if host.provider == .lmStudio, instances.isEmpty {
                        Text("Unloading requires native loaded-instance identities from this host.").font(WorkbenchTypography.secondary)
                    }
                } else {
                    Text("Select a model reported as loaded to review unloading.").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
            case .llamaCpp, .openAICompatible:
                Text("Unloading is unavailable for this provider.").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
        }
    }

    static func state(_ model: HostedModel) -> String {
        switch model.isLoaded { case true: return "Loaded"; case false: return "Available"; case nil: return "Load unknown" }
    }
    static func bytes(_ count: Int64?) -> String { count.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown" }
    private func addHost() { editor = ModelHost(name: "Ollama", provider: .ollama, baseURL: ModelHostProvider.ollama.defaultURL) }
    private func compare(_ inventory: HostInventory) {
        guard let model = selectedModel else { return }
        let target = HostedComparisonTarget(host: inventory.host, model: model, capturedAt: inventory.capturedAt, runtimeVersion: inventory.runtimeVersion)
        do {
            try target.validate(mode: inventory.host.provider == .comfyUI ? .imageGeneration : .chat)
            if !appHost.hostedComparisonTargets.contains(where: { $0.id == target.id }) {
                guard appHost.hostedComparisonTargets.count < 4 else { throw HostedIntegrationError.invalid("Remove a comparison lane before adding another model.") }
                appHost.hostedComparisonTargets.append(target)
            }
            appHost.compareHostedModels = true; onRouteSelection(.compare)
        } catch { actionError = AppHost.render(error) }
    }
}

struct HostDeviceMemoryDisclosure: View {
    let snapshot: HostDeviceMemorySnapshot?

    var body: some View {
        DisclosureGroup("Reported device memory") {
            HostDeviceMemoryView(snapshot: snapshot)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, WorkbenchSpacing.xs)
        }
    }
}

/// Cached values only. Opening this content never reads a host or releases memory.
struct HostDeviceMemoryView: View {
    let snapshot: HostDeviceMemorySnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            if let snapshot {
                Text("Device memory read " + snapshot.capturedAt.formatted(date: .abbreviated, time: .standard))
                    .foregroundStyle(WorkbenchColor.muted)
                if snapshot.devices.isEmpty { Text("No devices reported").foregroundStyle(WorkbenchColor.muted) }
                if !snapshot.devices.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                            ForEach(Array(snapshot.devices.enumerated()), id: \.offset) { offset, device in
                                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                                    Text("\(offset + 1). " + (device.name ?? "Unnamed device")).font(WorkbenchTypography.label)
                                    Text((device.type ?? "Type unknown") + (device.index.map { " · index \($0)" } ?? ""))
                                        .foregroundStyle(WorkbenchColor.muted)
                                    Text("Reported free: " + bytes(device.freeBytes) + " · total: " + bytes(device.totalBytes))
                                    Text(device.reportsSystemMemory
                                        ? "Shared system memory reported by ComfyUI; overlaps system headroom."
                                        : "Host-reported device memory; allocations may be shared.")
                                        .foregroundStyle(WorkbenchColor.muted)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 220)
                }
                Text("Device readings are separate observations, never added together. They do not measure a model's allocation or memory released by cleanup.")
                    .foregroundStyle(WorkbenchColor.muted)
            } else {
                Text("Device memory unknown").foregroundStyle(WorkbenchColor.muted)
                Text("This snapshot contains no device-memory readings.").foregroundStyle(WorkbenchColor.muted)
            }
        }
        .font(WorkbenchTypography.secondary).textSelection(.enabled)
    }

    private func bytes(_ value: Int64?) -> String {
        guard let value else { return "Unknown" }
        return value == 0 ? "0 bytes" : ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
}

struct HostedModelDetailsView: View {
    let model: HostedModel

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text(model.modelID).font(WorkbenchTypography.compactValue).textSelection(.enabled)
            Text("Family: \(model.family ?? "Unknown") · Format: \(model.format ?? "Unknown")")
            Text("Loaded context: \(model.contextLength.map(String.init) ?? "Unknown") · Maximum context: \(model.maximumContextLength.map(String.init) ?? "Unknown")")
                .accessibilityIdentifier("host-model-context")
            Text("Reported model memory: \(HostedModelsView.bytes(model.memoryBytes))")
            Text("Capabilities: \(model.capabilities.map { $0.isEmpty ? "None reported" : $0.joined(separator: ", ") } ?? "Unknown")")
                .accessibilityIdentifier("host-model-capabilities")
            if let digest = model.digest { Text("Digest: \(digest)").font(WorkbenchTypography.compactValue).textSelection(.enabled) }
            if let date = model.detailsCapturedAt {
                Text("Model details read · \(date.formatted(date: .abbreviated, time: .standard))")
                    .foregroundStyle(WorkbenchColor.muted).accessibilityIdentifier("host-model-details-read-at")
            }
        }.font(WorkbenchTypography.secondary)
    }
}

/// Running weights are observations, not installed selections or memory-release authority.
struct HostedRunningModelsView: View {
    let models: [HostedModel]

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Ollama reports these weights in memory; installed tags can refer to different weights. Use Ollama to manage differing or unlisted weights.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            if models.isEmpty {
                Text("No running models were reported.").font(WorkbenchTypography.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                        ForEach(models) { model in
                            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                                Text(model.name).font(WorkbenchTypography.emphasis)
                                Text("Digest: \(model.digest ?? "Unknown")").font(WorkbenchTypography.compactValue)
                                Text("Host-reported memory: \(model.memoryBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "Unknown") · Loaded context: \(model.contextLength.map(String.init) ?? "Unknown")")
                                    .font(WorkbenchTypography.secondary)
                            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.vertical, WorkbenchSpacing.xs)
                }.frame(height: 180)
            }
        }.padding(.top, WorkbenchSpacing.xs)
    }
}

private struct HostResourceRequest: Identifiable {
    let id = UUID()
    let hostID: UUID
    let selection: HostResourceSelection
}

struct HostActivityLabel: View {
    let activity: HostActivity
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack {
                Label(activity.state.title, systemImage: activity.state == .idle ? "checkmark.circle" : "info.circle")
                if let running = activity.runningCount, let pending = activity.pendingCount { Text("\(running) running · \(pending) queued") }
                Text("Checked \(activity.checkedAt.formatted(date: .omitted, time: .standard))").foregroundStyle(WorkbenchColor.muted)
            }
            Text(activity.detail).foregroundStyle(WorkbenchColor.muted)
        }.font(WorkbenchTypography.secondary)
    }
}

struct HostResourceSheet: View {
    @ObservedObject var coordinator: ModelHostsCoordinator
    let hostID: UUID
    let selection: HostResourceSelection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text(coordinator.resourcePreview?.actionTitle ?? "Host memory").font(WorkbenchTypography.title)
            if coordinator.resourceBusy {
                ProgressView(coordinator.resourceApplying ? "Sending request and refreshing inventory…" : "Checking current target and activity…")
                    .controlSize(.small)
            }
            if let preview = coordinator.resourcePreview {
                Text(preview.host.name).font(WorkbenchTypography.section)
                Text(preview.host.baseURL).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                Text(preview.scope).fixedSize(horizontal: false, vertical: true)
                if let model = preview.model {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        Text("Model: \(model.modelID)").font(WorkbenchTypography.compactValue)
                        Text("Weights digest: \(model.digest ?? "Unknown")").font(WorkbenchTypography.compactValue)
                        Text("Loaded context: \(model.contextLength.map(String.init) ?? "Unknown") · Quantization: \(model.quantization ?? "Unknown")")
                            .font(WorkbenchTypography.secondary)
                    }.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                HostActivityLabel(activity: preview.activity)
                Label(preview.warning, systemImage: "exclamationmark.triangle")
                    .font(WorkbenchTypography.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Activity is checked again before the request. Model files and the host application stay in place.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            if let message = coordinator.resourceMessage {
                Text(message).font(WorkbenchTypography.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("host-resource-message")
            }
            HStack {
                Button(coordinator.resourcePreview == nil && !coordinator.resourceBusy ? "Close" : "Cancel") {
                    if coordinator.resourcePreview != nil || coordinator.resourceBusy { coordinator.cancelResourcePreview() }
                    dismiss()
                }.keyboardShortcut(.cancelAction).disabled(coordinator.resourceApplying)
                Spacer()
                if let preview = coordinator.resourcePreview {
                    Button(preview.actionTitle, role: .destructive) { Task { await coordinator.confirmResource() } }
                        .disabled(coordinator.resourceBusy || coordinator.resourceUseBlocked())
                        .accessibilityIdentifier("host-resource-confirm")
                } else if !coordinator.resourceBusy {
                    Button("Check again") { Task { await coordinator.prepareResource(hostID: hostID, selection: selection) } }
                }
            }
        }.padding(WorkbenchSpacing.pageInset).frame(width: 520)
            .task { await coordinator.prepareResource(hostID: hostID, selection: selection) }
            .interactiveDismissDisabled(coordinator.resourceBusy || coordinator.resourcePreview != nil)
            .onDisappear {
                if coordinator.resourcePreview != nil || coordinator.resourceBusy { coordinator.cancelResourcePreview() }
            }
    }
}

private struct ModelHostEditor: View {
    @State var host: ModelHost
    @ObservedObject var coordinator: ModelHostsCoordinator
    var onSaved: (ModelHost) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var replaceToken = false
    @State private var error: String?
    @StateObject private var connectionCheck = ModelHostConnectionCheck()

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Model host").font(WorkbenchTypography.title)
            Form {
                Picker("Provider", selection: $host.provider) { ForEach(ModelHostProvider.allCases) { Text($0.title).tag($0) } }
                    .onChange(of: host.provider) { previous, selected in
                        if host.baseURL == previous.defaultURL { host.baseURL = selected.defaultURL }
                        if host.name == previous.title { host.name = selected.title }
                    }
                TextField("Name", text: $host.name).accessibilityIdentifier("model-host-name")
                TextField("Server URL", text: $host.baseURL).accessibilityIdentifier("model-host-url")
                Toggle("Replace saved API token", isOn: $replaceToken)
                if replaceToken { SecureField("API token (optional)", text: $token) }
            }.formStyle(.grouped)
            Text("Local servers only. Tokens are stored in Keychain; leaving the replacement token blank removes it.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            if let message = host.validationMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                HStack {
                    Button("Test connection") {
                        let host = host, token = token, replaceToken = replaceToken
                        connectionCheck.check { try await coordinator.checkConnection(host, token: token, replaceToken: replaceToken) }
                    }
                    .disabled(host.validationMessage != nil || connectionCheck.isChecking)
                    .accessibilityIdentifier("test-model-host-connection")
                    if connectionCheck.isChecking {
                        ProgressView().controlSize(.small)
                        Button("Cancel check") { connectionCheck.invalidate() }
                    }
                }
                if let inventory = connectionCheck.inventory {
                    Label("Inventory read · \(inventory.models.count) models reported", systemImage: "checkmark.circle")
                        .foregroundStyle(WorkbenchColor.success)
                        .accessibilityIdentifier("model-host-connection-result")
                    Text("Checked \(inventory.capturedAt.formatted(date: .omitted, time: .standard)) · Generation is not tested.")
                        .foregroundStyle(WorkbenchColor.muted)
                }
                if let message = connectionCheck.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(WorkbenchColor.failure)
                        .accessibilityIdentifier("model-host-connection-error")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Optional: reads the model inventory without loading models or saving this connection or token.")
                    .foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            }.font(WorkbenchTypography.secondary)
            ErrorBanner(text: error)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save host") {
                    do { try coordinator.save(host, token: token, replaceToken: replaceToken); onSaved(host); dismiss() }
                    catch { self.error = AppHost.render(error) }
                }.keyboardShortcut(.defaultAction).buttonStyle(.workbenchPrimary)
                    .disabled(host.validationMessage != nil || connectionCheck.isChecking)
            }
        }.padding(WorkbenchSpacing.pageInset).frame(width: 500, height: 540)
            .onChange(of: host) { _, _ in connectionCheck.invalidate(); error = nil }
            .onChange(of: token) { _, _ in connectionCheck.invalidate(); error = nil }
            .onChange(of: replaceToken) { _, _ in connectionCheck.invalidate(); error = nil }
            .onDisappear { connectionCheck.invalidate() }
    }
}
