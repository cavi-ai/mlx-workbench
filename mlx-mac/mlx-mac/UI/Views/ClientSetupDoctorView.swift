import SwiftUI

/// Read-only checks, followed by the existing wiring review or host editor.
struct ClientSetupDoctorView: View {
    @ObservedObject var wiring: WiringCoordinator
    @ObservedObject var hosts: ModelHostsCoordinator
    @ObservedObject var workflow: ModelWorkflowCoordinator
    @Binding var selectedServerID: String?
    let refreshClientsAndServers: () async -> Bool
    let previewClient: (String) async -> Bool
    let onOpenRun: () -> Void
    let onOpenHealth: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var checkID = UUID()
    @State private var checking = false
    @State private var progress = "Setup has not been checked."
    @State private var checkedAt: Date?
    @State private var preparing = false
    @State private var editor: ModelHost?
    @State private var serverStatusAvailable = false

    private var servers: [ServerInfo] { serverStatusAvailable ? workflow.servers.filter { WireEndpoint(server: $0) != nil } : [] }
    private var busy: Bool { checking || preparing || wiring.isApplying || wiring.isCheckingServer }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack {
                Text("Client and host setup").font(WorkbenchTypography.title)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(preparing)
            }
            HStack(alignment: .top) {
                if checking || preparing { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text(progress).accessibilityIdentifier("setup-doctor-status")
                    if let checkedAt {
                        Text("Last checked \(checkedAt.formatted(date: .omitted, time: .standard))")
                            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    }
                }
                Spacer()
                Button("Check setup") { checkID = UUID() }.disabled(busy)
                    .accessibilityIdentifier("setup-doctor-check")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    clientSection
                    hostSection
                    Button("Engine or model runtime issue? Open Health") { dismiss(); onOpenHealth() }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("setup-doctor-scroll")
        }
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: 660, height: 620)
        .interactiveDismissDisabled(preparing)
        .task(id: checkID) { await check() }
        .sheet(item: $editor) { host in
            ModelHostEditor(host: host, coordinator: hosts)
        }
    }

    private var clientSection: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                SectionTitle(text: "Coding clients")
                Text("Choose a running endpoint, then review one client’s config. Creating a config does not install the client application.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                if servers.isEmpty {
                    Text("No running endpoint is available. Start a model in Run, then check setup again.")
                        .foregroundStyle(WorkbenchColor.warning)
                    Button("Open Run") { dismiss(); onOpenRun() }
                } else {
                    Picker("Endpoint", selection: $selectedServerID) {
                        Text("Choose a running server…").tag(String?.none)
                        ForEach(servers) { server in
                            Text("\(server.modelIdentity) :\(server.port.map(String.init) ?? "?")").tag(String?.some(server.id))
                        }
                    }.accessibilityIdentifier("setup-doctor-endpoint").disabled(busy)
                }
                if let error = wiring.lastError { ErrorBanner(text: error) }
                ForEach(wiring.setupClients, id: \.clientID) { client in
                    clientRow(client)
                }
            }
        }
    }

    private func clientRow(_ client: ClientInstallation) -> some View {
        let detected = wiring.installations.contains { $0.clientID == client.clientID }
        let status = wiring.readings[client.clientID] ?? (checkedAt != nil && !detected
            ? ClientConfigStatus(reading: .fileAbsent, isLinked: false) : nil)
        let diagnosis = ClientSetupDiagnosis.make(clientID: client.clientID, status: status, servers: servers,
                                                  serverStatusAvailable: serverStatusAvailable)
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Divider()
            HStack {
                Text(client.displayName).font(WorkbenchTypography.emphasis)
                Spacer()
                if let guide = Self.clientGuides[client.clientID] { Link("Install / setup guide", destination: guide) }
                Button("Review config…") {
                    preparing = true
                    progress = "Checking the selected endpoint before preview…"
                    Task { @MainActor in
                        let previewed = await previewClient(client.clientID)
                        preparing = false
                        if previewed { dismiss() }
                        else { progress = "Config preview could not be prepared. Check the endpoint and the message below." }
                    }
                }
                .disabled(busy || !diagnosis.canPreview || !servers.contains { $0.id == selectedServerID })
                .accessibilityIdentifier("setup-client-\(client.clientID)")
            }
            Text(diagnosis.message).font(WorkbenchTypography.secondary)
                .foregroundStyle(diagnosis.canPreview ? WorkbenchColor.muted : WorkbenchColor.warning)
                .fixedSize(horizontal: false, vertical: true)
            if let path = client.configPath {
                Text(path).font(WorkbenchTypography.value).foregroundStyle(WorkbenchColor.muted)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hostSection: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                SectionTitle(text: "Model hosts")
                Text("Install and start the host, then add its local connection. Checks read inventory without loading models or generating output.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                if let error = hosts.storageError { ErrorBanner(text: error) }
                ForEach(hosts.hosts) { host in
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                        HStack {
                            Text(host.name).font(WorkbenchTypography.emphasis)
                            Spacer()
                            Button("Edit / test…") { editor = host }.disabled(busy)
                        }
                        Text(host.baseURL).font(WorkbenchTypography.value).textSelection(.enabled)
                        if hosts.refreshing.contains(host.id) {
                            Text("Reading inventory…")
                        } else if let error = hosts.errors[host.id] {
                            Text(error).foregroundStyle(WorkbenchColor.warning)
                        } else if let inventory = hosts.inventories[host.id] {
                            Text("\(inventory.models.count) models reported · \(inventory.capturedAt.formatted(date: .abbreviated, time: .standard))")
                        } else { Text("Not checked. Use Check setup or Edit / test…") }
                    }.font(WorkbenchTypography.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                }
                ForEach(ModelHostProvider.allCases) { provider in
                    HStack {
                        Text(provider.title)
                        Spacer()
                        if let guide = Self.hostGuides[provider] { Link("Install / setup guide", destination: guide) }
                        Button("Add connection…") {
                            editor = ModelHost(name: provider.title, provider: provider, baseURL: provider.defaultURL)
                        }.disabled(busy || hosts.storageError != nil)
                            .accessibilityIdentifier("setup-host-\(provider.rawValue)")
                    }
                }
            }
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        progress = "Checking client configs and running endpoints…"
        serverStatusAvailable = await refreshClientsAndServers()
        guard !Task.isCancelled else { return }
        for host in hosts.hosts {
            progress = "Reading \(host.name) inventory…"
            _ = await hosts.refresh(host.id)
            guard !Task.isCancelled else { return }
        }
        checkedAt = Date()
        progress = serverStatusAvailable
            ? "Setup check finished. Review the config and host results below."
            : "Client configs checked. Server status is unavailable; refresh after resolving the error."
    }

    private static let clientGuides = [
        "opencode": URL(string: "https://opencode.ai/docs/")!,
        "continue": URL(string: "https://docs.continue.dev/ide-extensions/install")!,
        "zed": URL(string: "https://zed.dev/download")!,
        "aider": URL(string: "https://aider.chat/docs/install.html")!
    ]
    private static let hostGuides: [ModelHostProvider: URL] = [
        .ollama: URL(string: "https://ollama.com/download")!,
        .lmStudio: URL(string: "https://lmstudio.ai/download")!,
        .comfyUI: URL(string: "https://docs.comfy.org/installation/desktop/macos")!,
        .llamaCpp: URL(string: "https://github.com/ggml-org/llama.cpp/blob/master/docs/install.md")!
    ]
}
