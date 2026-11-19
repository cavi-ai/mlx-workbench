import SwiftUI

/// Settings > Serving: one authenticated loopback address for every endpoint that uses the front door key.
struct FrontDoorEditor: View {
    static let defaultPort = 8099
    let appHost: AppHost
    @ObservedObject var coordinator: FrontDoorCoordinator
    @ObservedObject var endpoint: EndpointSupervisor
    @State private var portText = ""
    @State private var message: String?
    @State private var showsSetup = false

    var body: some View {
        let settings = endpoint.fleet.frontDoor
        let joined = endpoint.fleet.slots.filter { settings != nil && $0.apiKeySHA256 == settings?.apiKeySHA256 }.count
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack {
                TextField("Port", text: $portText).frame(width: 80)
                    .disabled(coordinator.isRunning || coordinator.busy)
                    .accessibilityIdentifier("front-door-port")
                if coordinator.isRunning {
                    Button("Stop") { Task { await coordinator.stop() } }.disabled(coordinator.busy)
                        .accessibilityIdentifier("front-door-stop")
                } else {
                    Button(settings == nil ? "Create key and start" : "Start") { Task { await start() } }
                        .disabled(coordinator.busy || endpoint.isChanging || port == nil)
                        .accessibilityIdentifier("front-door-start")
                }
                if coordinator.busy { ProgressView().controlSize(.small) }
            }
            if let listening = coordinator.listening {
                ServingConnectionField(title: "Base URL", value: listening.apiBase, identifier: "front-door-base-url", compact: true)
                Text(listening.models.isEmpty ? "No running endpoint uses the front door key." : listening.models.joined(separator: " · "))
                    .font(WorkbenchTypography.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("front-door-models")
                HStack {
                    Button("Copy key") {
                        do { ServedModelsSelection.copyCredential(try EndpointCredentialStore.token(for: listening.apiKeySHA256)) }
                        catch { message = AppHost.render(error) }
                    }
                    Button("Refresh") { Task { await coordinator.refresh() } }.disabled(coordinator.busy)
                    Button("Set up OpenCode…") { showsSetup = true }
                        .disabled(coordinator.endpoint == nil)
                        .accessibilityIdentifier("front-door-setup-opencode")
                }
            }
            if settings != nil {
                Text("\(joined) of \(endpoint.fleet.slots.count) endpoints use the front door key. Stop an endpoint and choose Use front door key in Serving to add it.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            if let error = message ?? coordinator.error { InlineMessage(kind: .error, text: error) }
        }
        .onAppear { if portText.isEmpty { portText = String(settings?.port ?? Self.defaultPort) } }
        .sheet(isPresented: $showsSetup) { ClientSetupWizard(appHost: appHost, client: .opencode, prefersFrontDoor: true) }
    }

    private var port: Int? { Int(portText).flatMap { (1...65535).contains($0) ? $0 : nil } }

    private func start() async {
        guard let port else { return }
        message = nil
        if endpoint.fleet.frontDoor?.port != port {
            guard await endpoint.configureFrontDoor(port: port) else { message = endpoint.lastError; return }
        }
        guard let settings = endpoint.fleet.frontDoor else { return }
        await coordinator.start(settings)
    }
}
