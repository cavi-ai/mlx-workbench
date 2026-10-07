import SwiftUI

// MARK: - WireView
// Preview / apply runtime wiring for a model into a target config.

struct WireView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var wiring: WiringCoordinator
    @Environment(\.isRouteActive) private var isRouteActive
    private let onRouteSelection: (AppRoute) -> Void

    @State private var model = ""
    @State private var path = ""
    @State private var target = "mlx_lm"
    @State private var isPreviewing = false
    @State private var preview: [String: Any]?
    @State private var previewHash: String?
    @State private var result: String?
    @State private var errorMessage: String?

    @State private var selectedServerID: String?
    @State private var wiringResult: String?
    @State private var wiringResultHasIssues = false
    @State private var isRefreshingServer = false
    @State private var serverMessage: String?
    @State private var wiredServer: ServerInfo?
    @State private var wiredTransactionID: UUID?
    @State private var capture: WiredWorkflowCapture?
    @State private var importAfterCapture = false
    @State private var isPreparingCapture = false
    @State private var captureError: String?

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        self.onRouteSelection = onRouteSelection
        _wiring = ObservedObject(wrappedValue: appHost.wiring)
    }

    private var runningServers: [ServerInfo] {
        appHost.modelWorkflow.servers.filter { $0.state?.lowercased() == "running" }
    }

    private var selectedServer: ServerInfo? {
        runningServers.first { $0.id == selectedServerID }
    }
    private var selectedEndpoint: WireEndpoint? { selectedServer.flatMap { WireEndpoint(server: $0) } }
    private var wiredTransaction: WiringTransaction? {
        wiring.transactions.first { $0.id == wiredTransactionID && $0.rolledBackAt == nil && !$0.receipts.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                clientWiringSection
                formSection
                ErrorBanner(text: errorMessage)
                if let result {
                    Text(result).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.success)
                }
                if let preview {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionTitle(text: "Preview")
                            Spacer()
                            Button("Apply Wiring") {
                                apply()
                            }
                            .disabled(previewHash == nil)
                        }
                        RawJSONDisclosure("Raw wiring payload", value: preview)
                    }
                    .formSection {}
                }
                Spacer()
            }
            .padding(WorkbenchSpacing.pageInset)
        }
        .task(id: isRouteActive) {
            guard isRouteActive else { return }
            wiring.detect()
            await refreshServers()
        }
        .sheet(item: $capture, onDismiss: {
            if importAfterCapture { importAfterCapture = false; reviewReport() }
        }) { capture in
            WorkflowCaptureRequestView(models: [capture.model], initialModelPath: capture.model.path,
                environment: appHost.watch.currentFingerprintDescription, endpoint: capture.endpoint,
                initialHarness: capture.harness, onImport: { importAfterCapture = true; self.capture = nil })
        }
    }

    // MARK: - Cross-client wiring

    private var clientWiringSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Client wiring")
            Text("Point installed clients at a running local server. Each client's own config is written atomically with backup and rollback.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            if let serverMessage { Text(serverMessage).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted) }
            Button(isRefreshingServer ? "Refreshing servers…" : "Refresh servers") {
                Task { await refreshServers() }
            }.disabled(isRefreshingServer || wiring.isCheckingServer || wiring.isApplying)

            if runningServers.isEmpty {
                Text("No authoritative running server. Start one in Run first.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            } else {
                Picker("Endpoint", selection: $selectedServerID) {
                    Text("Choose a running server…").tag(String?.none)
                    ForEach(runningServers) { server in
                        Text("\(URL(fileURLWithPath: server.modelIdentity).lastPathComponent) :\(server.port.map(String.init) ?? "?")")
                            .tag(String?.some(server.id))
                    }
                }
                .frame(width: 340)
                .disabled(isRefreshingServer || wiring.isCheckingServer || wiring.isApplying)
            }
            if let selectedEndpoint {
                Text(selectedEndpoint.modelName).font(WorkbenchTypography.compactValue).foregroundStyle(WorkbenchColor.muted).textSelection(.enabled)
            }

            if wiring.installations.isEmpty {
                Text("No supported clients detected (opencode, Continue, Zed, Aider).")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            } else {
                ForEach(wiring.installations, id: \.clientID) { installation in
                    HStack {
                        Text(installation.displayName).font(WorkbenchTypography.secondary)
                        Spacer()
                        if installation.advisoryOnly {
                            Text(installation.advisoryNote ?? "Advisory only")
                                .font(WorkbenchTypography.secondary)
                                .foregroundStyle(WorkbenchColor.muted)
                        } else {
                            Text(installation.configPath ?? "")
                                .font(WorkbenchTypography.secondary)
                                .foregroundStyle(WorkbenchColor.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { wiringActions }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { wiringActions }
            }

            ErrorBanner(text: wiring.lastError)
            ErrorBanner(text: wiring.persistenceError)

            if !wiring.plans.isEmpty, let hash = wiring.previewHash {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: "Wiring preview")
                    ForEach(wiring.plans) { plan in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(plan.redactedDiff.enumerated()), id: \.offset) { _, line in
                                    Text(diffText(line))
                                        .font(WorkbenchTypography.value)
                                        .foregroundStyle(diffColor(line.kind))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            HStack {
                                Text(plan.displayName).font(WorkbenchTypography.emphasis)
                                if plan.rewritesFile {
                                    Text("reformats file").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                                }
                                Spacer()
                                Text(plan.summary).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                            }
                        }
                    }
                    Button("Confirm client wiring") {
                        if let server = selectedServer {
                            Task { @MainActor in
                                let transaction = await wiring.confirm(server: server, previewHash: hash, currentServers: {
                                    guard await appHost.modelWorkflow.refreshServingStatus() else {
                                        throw WorkflowEvidenceError.invalid("Could not establish current server status.")
                                    }
                                    return appHost.modelWorkflow.servers
                                })
                                if let transaction {
                                    wiredServer = server
                                    wiredTransactionID = transaction.id
                                    captureError = nil
                                    wiringResultHasIssues = !transaction.failures.isEmpty
                                    wiringResult = transaction.failures.isEmpty
                                        ? "Wired \(transaction.receipts.count) client(s) to \(transaction.modelName)."
                                        : "Wired with issues: \(transaction.failures.joined(separator: "; "))"
                                } else {
                                    wiringResult = nil
                                    wiringResultHasIssues = false
                                }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(wiring.isApplying || wiring.isCheckingServer || isRefreshingServer || selectedServer == nil)
                }
                .formSection {}
            }

            if let wiringResult {
                Text(wiringResult)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(wiringResultHasIssues ? WorkbenchColor.failure : WorkbenchColor.success)
            }
            if wiredTransaction != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.xs) { measurementActions }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { measurementActions }
                }
                ErrorBanner(text: captureError)
            }
        }
        .formSection {}
    }

    @ViewBuilder private var measurementActions: some View {
        Button(isPreparingCapture ? "Checking endpoint…" : "Measure this workflow…") {
            Task { await prepareCapture() }
        }.buttonStyle(.borderedProminent)
            .disabled(isPreparingCapture || isRefreshingServer || wiring.isApplying || wiring.isCheckingServer)
        Button("Review report in Compare…", action: reviewReport).buttonStyle(.bordered)
    }

    private func prepareCapture() async {
        guard !isPreparingCapture, let wiredServer, let transaction = wiredTransaction else { return }
        isPreparingCapture = true
        defer { isPreparingCapture = false }
        do {
            guard await appHost.modelWorkflow.refreshServingStatus() else {
                throw WorkflowEvidenceError.invalid("Server status unavailable. Refresh before measuring this workflow.")
            }
            guard isRouteActive, let currentTransaction = wiredTransaction, currentTransaction.id == transaction.id else { return }
            let models = (appHost.librarySnapshot?.models ?? []).filter { $0.readiness == .ready }
                .map { WorkflowCaptureModel(path: $0.item.path, name: $0.displayName, signature: $0.item.signature) }
            capture = try WiredWorkflowCapture.make(reviewedServer: wiredServer, currentServers: appHost.modelWorkflow.servers,
                transaction: currentTransaction, models: models)
            captureError = nil
        } catch { captureError = AppHost.render(error) }
    }

    private func reviewReport() {
        appHost.workflowReportImportRequested = true
        onRouteSelection(.compare)
    }

    @ViewBuilder
    private var wiringActions: some View {
        Button("Preview client wiring") {
            Task { @MainActor in
                let chosen = selectedServer
                await refreshServers()
                guard let chosen, let current = selectedServer, ClientWiringSelection.sameServer(chosen, current) else {
                    serverMessage = "Selected server stopped or changed. Choose a running server and preview again."
                    return
                }
                wiring.preview(server: current)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedEndpoint == nil || isRefreshingServer || wiring.isCheckingServer || wiring.isApplying || wiring.installations.allSatisfy(\.advisoryOnly))
        if wiring.rollbackAvailable {
            Button("Roll back last wiring") { wiring.rollback() }
                .buttonStyle(.bordered).disabled(wiring.isApplying || wiring.isCheckingServer || isRefreshingServer)
        }
    }

    private func refreshServers() async {
        guard !isRefreshingServer else { return }
        isRefreshingServer = true
        defer { isRefreshingServer = false }
        guard await appHost.modelWorkflow.refreshServingStatus() else {
            selectedServerID = nil; serverMessage = "Server status unavailable. Refresh before previewing client wiring."
            return
        }
        guard isRouteActive else { return }
        serverMessage = nil
        if let request = appHost.clientWiringRequest {
            let matching = ClientWiringSelection.matchingServers(request: request, servers: runningServers)
            selectedServerID = matching.count == 1 ? matching[0].id : nil
            if matching.isEmpty { serverMessage = "The chosen model is not running. Start it in Run, then refresh here." }
            else if matching.count > 1 { serverMessage = "The chosen model has multiple running endpoints. Choose the port to wire." }
            appHost.clientWiringRequest = nil
        } else if !runningServers.contains(where: { $0.id == selectedServerID }) { selectedServerID = nil }
    }

    private func diffText(_ line: DiffLine) -> String {
        switch line.kind {
        case .context: return "  \(line.text)"
        case .added: return "+ \(line.text)"
        case .removed: return "- \(line.text)"
        }
    }

    private func diffColor(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .context: return WorkbenchColor.ink
        case .added: return WorkbenchColor.success
        case .removed: return WorkbenchColor.failure
        }
    }

    @ViewBuilder
    private var manualWireControls: some View {
        Picker("Target", selection: $target) {
            Text("mlx_lm").tag("mlx_lm")
            Text("mlx-vlm").tag("mlx-vlm")
            Text("ollama").tag("ollama")
            Text("lmstudio").tag("lmstudio")
            Text("litellm").tag("litellm")
        }
        .frame(maxWidth: 180, alignment: .leading)
        Button("Preview Wire") { previewWire() }
            .buttonStyle(.borderedProminent)
            .disabled(model.isEmpty || path.isEmpty || isPreviewing)
    }


    private var formSection: some View {
        // Legacy single-file wiring. Cross-client wiring above is the
        // supported path; this stays available but collapsed.
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Model repo id", text: $model)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    TextField("Config file path", text: $path)
                        .textFieldStyle(.roundedBorder)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.xs) { manualWireControls }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { manualWireControls }
                }
            }
            .padding(.top, WorkbenchSpacing.xs)
        } label: {
            Text("Advanced: manual single-file wiring")
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.muted)
        }
        .formSection {}
    }

    private func previewWire() {
        errorMessage = nil
        result = nil
        isPreviewing = true
        let m = model, p = path, t = target
        Task {
            defer { isPreviewing = false }
            do {
                let wire = try await appHost.api.wirePreview(model: m, path: p, target: t)
                preview = wire.config ?? ["preview_hash": wire.preview_hash ?? ""]
                previewHash = wire.preview_hash
            } catch let error as BridgeError {
                preview = nil
                previewHash = nil
                errorMessage = error.errorDescription
            } catch {
                preview = nil
                previewHash = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func apply() {
        guard let previewHash else { return }
        errorMessage = nil
        result = nil
        let m = model, p = path, t = target, h = previewHash
        Task {
            do {
                let wire = try await appHost.api.wireApply(model: m, path: p, previewHash: h, target: t)
                result = "Wiring applied."
                preview = wire.config
                self.previewHash = wire.preview_hash
            } catch let error as BridgeError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
