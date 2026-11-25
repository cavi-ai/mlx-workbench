import SwiftUI

/// What the Workbench key wizard shows for the saved fleet: which step applies and which endpoints are unprotected.
struct WorkbenchKeySetup: Equatable {
    enum Step: Int, CaseIterable {
        case createKey, protectEndpoints, connectApps

        var title: String {
            switch self {
            case .createKey: "Create key"
            case .protectEndpoints: "Protect endpoints"
            case .connectApps: "Connect apps"
            }
        }
    }

    struct Endpoint: Equatable, Identifiable {
        let id: UUID
        let port: Int
        let title: String
        let hasOwnKey: Bool
    }

    let keyDigest: String?
    /// Endpoints not on the Workbench key, unprotected and own-key, in ascending port order.
    let unprotected: [Endpoint]
    private let candidates: [EndpointSlot]

    init(keyDigest: String?, slots: [EndpointSlot]) {
        self.keyDigest = keyDigest
        candidates = slots.filter { $0.apiKeySHA256 == nil || $0.apiKeySHA256 != keyDigest }
            .sorted { $0.port < $1.port }
        unprotected = candidates
            .map { Endpoint(id: $0.id, port: $0.port, title: URL(fileURLWithPath: $0.modelPath).lastPathComponent, hasOwnKey: $0.apiKeySHA256 != nil) }
    }

    init(fleet: EndpointFleetConfig) { self.init(keyDigest: fleet.frontDoor?.apiKeySHA256, slots: fleet.slots) }

    /// The first step that still has work: no key, then unprotected endpoints, then connecting apps.
    var step: Step { keyDigest == nil ? .createKey : unprotected.isEmpty ? .connectApps : .protectEndpoints }

    /// The saved key as `…` and the last four digest characters; the key itself is never shown.
    var keySummary: String? { keyDigest.map { "…" + $0.suffix(4) } }

    var envVarName: String { QuickConnectSnippets.apiKeyEnvVar }

    /// A shell line with a quoted placeholder where the key goes; it never contains a key.
    var exportTemplate: String { "export \(envVarName)=\"<paste copied key>\"" }

    /// The endpoints to protect: the selection (all when nil) limited to those still unprotected, by ascending port.
    func chosen(_ selected: Set<UUID>?) -> [EndpointSlot] {
        candidates.filter { selected?.contains($0.id) ?? true }
    }
}

/// Create the Workbench key, move endpoints onto it, then hand it to apps.
struct WorkbenchKeyWizard: View {
    let appHost: AppHost
    @ObservedObject var endpoint: EndpointSupervisor
    @Environment(\.dismiss) private var dismiss
    @State private var step: WorkbenchKeySetup.Step?
    @State private var selected: Set<UUID>?
    @State private var review: WorkbenchKeyProtectReview?
    @State private var message: String?
    @State private var showsSetup = false
    @State private var busy = false

    init(appHost: AppHost) {
        self.appHost = appHost
        endpoint = appHost.endpoint
    }

    private var setup: WorkbenchKeySetup { WorkbenchKeySetup(fleet: endpoint.fleet) }
    private var current: WorkbenchKeySetup.Step { step ?? setup.step }
    private var chosen: Set<UUID> { Set(setup.chosen(selected).map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Workbench key").font(WorkbenchTypography.title)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
            Text("Step \(current.rawValue + 1) of \(WorkbenchKeySetup.Step.allCases.count): \(current.title)").font(WorkbenchTypography.emphasis)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    switch current {
                    case .createKey: createKey
                    case .protectEndpoints: protect
                    case .connectApps: connect
                    }
                    if let message { InlineMessage(kind: .error, text: message) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Back") { move(-1) }.disabled(current == .createKey || busy)
                Spacer()
                Button("Next") { move(1) }.disabled(current == .connectApps || setup.keyDigest == nil || busy)
            }
        }
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: 560, height: 460)
        .sheet(isPresented: $showsSetup) { ClientSetupWizard(appHost: appHost, client: .opencode, prefersFrontDoor: true) }
        .onChange(of: setup) { _, latest in
            let ids = Set(latest.unprotected.map(\.id))
            selected = selected.map { $0.intersection(ids) }
            if let review, !review.endpoints.allSatisfy({ ids.contains($0.slot.id) }) { self.review = nil }
        }
    }

    private func move(_ delta: Int) {
        message = nil; review = nil
        let next = max(0, min(WorkbenchKeySetup.Step.allCases.count - 1, current.rawValue + delta))
        step = WorkbenchKeySetup.Step(rawValue: next)
    }

    private var createKey: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            if let summary = setup.keySummary {
                Text("A Workbench key exists (\(summary)). It is stored in Keychain and never shown in full.")
            } else {
                Text("One key protects every endpoint you choose and the Workbench API. It is stored in Keychain.")
                Button("Create Workbench key") {
                    do { try endpoint.ensureWorkbenchKey(); step = nil; message = nil }
                    catch { message = AppHost.render(error) }
                }.buttonStyle(.workbenchPrimary).disabled(endpoint.isChanging)
            }
        }
    }

    private var protect: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            if let review {
                Text("These endpoints move onto the Workbench key. Running ones stop and restart in this order:")
                ForEach(review.endpoints, id: \.slot.id) { entry in
                    Text("127.0.0.1:\(entry.slot.port)\(entry.restarts ? " (restarts)" : " (stopped)")").textSelection(.enabled)
                }
                Text("Endpoints protected by the key load on request. Their previous keys stop working.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                HStack {
                    Button("Cancel") { self.review = nil }
                    Spacer()
                    Button("Protect endpoints") { confirm(review) }.buttonStyle(.workbenchPrimary).disabled(busy || endpoint.isChanging)
                }
            } else {
                Text("Choose the endpoints the Workbench key protects.")
                ForEach(setup.unprotected) { entry in
                    Toggle(isOn: Binding(get: { chosen.contains(entry.id) }, set: { on in
                        var next = chosen
                        if on { next.insert(entry.id) } else { next.remove(entry.id) }
                        selected = next
                    })) {
                        Text("\(entry.title) · 127.0.0.1:\(entry.port)\(entry.hasOwnKey ? " · own key" : "")")
                    }.toggleStyle(.checkbox)
                }
                Button("Review restart…") { prepare() }.buttonStyle(.workbenchPrimary)
                    .disabled(chosen.isEmpty || busy || endpoint.isChanging)
            }
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Apps send the key in the \(setup.envVarName) environment variable.")
            if let digest = setup.keyDigest {
                Button("Copy key") {
                    do { ServedModelsSelection.copyCredential(try EndpointCredentialStore.token(for: digest)); message = nil }
                    catch { message = AppHost.render(error) }
                }
            }
            Text(setup.exportTemplate).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Button("Copy template") { ServedModelsSelection.copy(setup.exportTemplate) }
            Button("Set up an app…") { showsSetup = true }
        }
    }

    private func prepare() {
        let slots = setup.chosen(selected)
        busy = true
        Task {
            defer { busy = false }
            do { review = try await endpoint.previewProtectEndpoints(slots); message = nil }
            catch { message = AppHost.render(error) }
        }
    }

    private func confirm(_ review: WorkbenchKeyProtectReview) {
        busy = true
        Task {
            defer { busy = false }
            let done = await endpoint.confirmProtectEndpoints(review)
            message = endpoint.lastError
            if done { self.review = nil; selected = nil; step = nil }
        }
    }
}
