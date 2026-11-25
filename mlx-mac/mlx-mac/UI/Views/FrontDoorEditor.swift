import SwiftUI

/// Settings > Serving: the Workbench API port. Start, stop and copy live on the Serving row.
struct FrontDoorEditor: View {
    static let defaultPort = ServingRole.workbenchAPIDefaultPort
    @ObservedObject var coordinator: FrontDoorCoordinator
    @ObservedObject var endpoint: EndpointSupervisor
    @State private var portText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack {
                TextField("Port", text: $portText).frame(width: 80)
                    .disabled(coordinator.isRunning || coordinator.busy || endpoint.isChanging)
                    .onSubmit { Task { await save() } }
                    .accessibilityIdentifier("front-door-port")
                Button("Save") { Task { await save() } }
                    .disabled(coordinator.isRunning || coordinator.busy || endpoint.isChanging || port == nil || port == endpoint.fleet.frontDoor?.port)
            }
            if let error = endpoint.lastError { InlineMessage(kind: .error, text: error) }
        }
        .onAppear { if portText.isEmpty { portText = String(endpoint.fleet.frontDoor?.port ?? Self.defaultPort) } }
    }

    private var port: Int? { Int(portText).flatMap { (1...65535).contains($0) ? $0 : nil } }

    private func save() async {
        guard let port, endpoint.fleet.frontDoor?.port != port else { return }
        _ = await endpoint.configureFrontDoor(port: port)
    }
}

/// The first Serving row: the Workbench API address, state, routed model count and its controls.
struct WorkbenchAPIRowView: View {
    let appHost: AppHost
    @ObservedObject var coordinator: FrontDoorCoordinator
    @ObservedObject var endpoint: EndpointSupervisor
    @State private var message: String?
    @State private var showsSetup = false
    @State private var showsKeyWizard = false

    var body: some View {
        let settings = endpoint.fleet.frontDoor
        let row = ServingRolesPresentation.workbenchAPIRow(settings: settings, isRunning: coordinator.isRunning, slots: endpoint.fleet.slots)
        let collisions = FrontDoorCoordinator.detectCollisions(slots: endpoint.fleet.slots, frontDoorKeySHA256: settings?.apiKeySHA256)
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            HStack {
                Label(row.title, systemImage: "point.3.connected.trianglepath.dotted").font(WorkbenchTypography.emphasis)
                Spacer(minLength: WorkbenchSpacing.xs)
                if coordinator.busy { ProgressView().controlSize(.small) }
                Text(row.stateText).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
            Text(row.address).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .accessibilityIdentifier("front-door-base-url")
            HStack(spacing: WorkbenchSpacing.sm) {
                if row.isRunning {
                    Button(row.stopTitle) { Task { await coordinator.stop() } }.disabled(coordinator.busy)
                        .accessibilityIdentifier("front-door-stop")
                } else {
                    Button(row.startTitle) { Task { await start(settings) } }
                        .disabled(coordinator.busy || endpoint.isChanging)
                        .accessibilityIdentifier("front-door-start")
                        .help(row.isConfigured ? "Start the shared address." : "Create the Workbench key and start the shared address.")
                }
                Text(row.routedText).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    .fixedSize().accessibilityIdentifier("front-door-models")
                    .help("Endpoints that use the Workbench key are reachable through this address.")
                Spacer(minLength: 0)
                Menu {
                    Button(row.copyAddressTitle) { ServedModelsSelection.copy(row.address) }
                    Button(row.keyTitle) { showsKeyWizard = true }
                        .accessibilityIdentifier("front-door-workbench-key")
                    Button(row.setupTitle) { showsSetup = true }
                        .disabled(coordinator.endpoint == nil)
                        .accessibilityIdentifier("front-door-setup-opencode")
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Workbench API actions")
            }.controlSize(.small)
            ForEach(collisions) { collision in
                InlineMessage(kind: .warning, text: collision.warningMessage)
                    .accessibilityIdentifier("front-door-collision-\(collision.modelName)")
            }
            if let error = message ?? coordinator.error { InlineMessage(kind: .error, text: error) }
        }
        .padding(.vertical, WorkbenchSpacing.xs)
        .sheet(isPresented: $showsSetup) { ClientSetupWizard(appHost: appHost, client: .opencode, prefersFrontDoor: true) }
        .sheet(isPresented: $showsKeyWizard) { WorkbenchKeyWizard(appHost: appHost) }
    }

    private func start(_ settings: FrontDoorSettings?) async {
        message = nil
        if settings == nil {
            guard await endpoint.configureFrontDoor(port: FrontDoorEditor.defaultPort) else { message = endpoint.lastError; return }
        }
        guard let settings = endpoint.fleet.frontDoor else { return }
        await coordinator.start(settings)
    }
}
