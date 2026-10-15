import SwiftUI

struct ManualWiringDraft: Equatable {
    var model = ""
    var path = ""
    var target = "mlx_lm"

    var request: ManualWiringRequest? {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !path.isEmpty, !target.isEmpty else { return nil }
        return ManualWiringRequest(model: model, path: path, target: target)
    }
}

struct ManualWiringRequest: Equatable {
    let model: String
    let path: String
    let target: String
}

struct ManualWiringPreview {
    let request: ManualWiringRequest
    let hash: String
    let payload: [String: Any]?
}

@MainActor
final class ManualWiringSession: ObservableObject {
    enum Operation: Equatable { case previewing, applying }

    @Published var draft = ManualWiringDraft() {
        didSet {
            guard draft != oldValue else { return }
            revision += 1
            if preview != nil || operation == .previewing {
                guidance = "Inputs changed. Preview again before confirming."
            }
            preview = nil
            errorMessage = nil
            notice = nil
        }
    }
    @Published private(set) var preview: ManualWiringPreview?
    @Published private(set) var operation: Operation?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var guidance: String?
    private var revision = 0
    private let previewOperation: (ManualWiringRequest) async throws -> WireResult
    private let applyOperation: (ManualWiringRequest, String) async throws -> WireResult

    init(preview: @escaping (ManualWiringRequest) async throws -> WireResult,
         apply: @escaping (ManualWiringRequest, String) async throws -> WireResult) {
        previewOperation = preview
        applyOperation = apply
    }

    var isBusy: Bool { operation != nil }
    var canPreview: Bool { !isBusy && draft.request != nil }
    var canConfirm: Bool {
        !isBusy && preview != nil && preview?.request == draft.request
            && preview?.hash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    @discardableResult
    func previewWiring() -> Task<Void, Never>? {
        guard canPreview, let request = draft.request else { return nil }
        let revision = revision
        operation = .previewing
        preview = nil
        errorMessage = nil
        notice = nil
        guidance = nil
        return Task {
            defer { operation = nil }
            do {
                let wire = try await previewOperation(request)
                guard self.revision == revision, draft.request == request else { return }
                guard let hash = wire.preview_hash,
                      !hash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    errorMessage = "Wiring preview did not include a confirmation hash. Preview again before confirming."
                    return
                }
                preview = ManualWiringPreview(request: request, hash: hash, payload: wire.config)
            } catch {
                guard self.revision == revision else { return }
                errorMessage = "Wiring preview failed: \(AppHost.render(error)) Preview again before confirming."
            }
        }
    }

    @discardableResult
    func confirmWiring() -> Task<Void, Never>? {
        guard canConfirm, let preview else { return nil }
        operation = .applying
        self.preview = nil
        errorMessage = nil
        notice = nil
        guidance = nil
        return Task {
            defer { operation = nil }
            do {
                let wire = try await applyOperation(preview.request, preview.hash)
                switch wire.applied {
                case true?: notice = "Wiring applied."
                case false?: errorMessage = "Wiring was not applied. Review the config file and preview again before confirming."
                case nil: errorMessage = "Wiring application was not confirmed. Check the config file, then preview again before confirming."
                }
            } catch {
                errorMessage = "Wiring failed: \(AppHost.render(error)) Check the config file, then preview again before confirming."
            }
        }
    }
}

// MARK: - WireView
// Preview / apply runtime wiring for a model into a target config.

struct WireView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var wiring: WiringCoordinator
    @Environment(\.isRouteActive) private var isRouteActive
    private let onRouteSelection: (AppRoute) -> Void

    @StateObject private var manual: ManualWiringSession

    @State private var selectedServerID: String?
    @State private var isRefreshingServer = false
    @State private var hasServerStatus = false
    @State private var serverMessage: String?
    @State private var wiredServer: ServerInfo?
    @State private var wiredTransactionID: UUID?
    @State private var capture: WiredWorkflowCapture?
    @State private var importAfterCapture = false
    @State private var isPreparingCapture = false
    @State private var captureError: String?
    @State private var layout = ClientsLayout()

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        self.onRouteSelection = onRouteSelection
        _wiring = ObservedObject(wrappedValue: appHost.wiring)
        _manual = StateObject(wrappedValue: ManualWiringSession(
            preview: { request in
                try await appHost.api.wirePreview(model: request.model, path: request.path, target: request.target)
            },
            apply: { request, hash in
                try await appHost.api.wireApply(model: request.model, path: request.path, previewHash: hash, target: request.target)
            }
        ))
    }

    private var runningServers: [ServerInfo] {
        appHost.modelWorkflow.servers.filter { $0.state?.lowercased() == "running" }
    }

    private var selectedServer: ServerInfo? {
        runningServers.first { $0.id == selectedServerID }
    }
    private var selectedEndpoint: WireEndpoint? { selectedServer.flatMap { WireEndpoint(server: $0) } }
    private var hasCurrentClientPreview: Bool { wiring.previewMatches(server: selectedServer) }
    private var resultTransaction: WiringTransaction? {
        wiring.transactions.first { $0.id == wiredTransactionID && $0.rolledBackAt == nil }
    }
    private var wiredTransaction: WiringTransaction? {
        resultTransaction.flatMap { $0.receipts.isEmpty ? nil : $0 }
    }

    private var presentation: ClientsPresentation {
        ClientsPresentation.make(
            installations: wiring.installations,
            readings: wiring.readings,
            servers: appHost.modelWorkflow.servers,
            selectedServerID: selectedServerID,
            pendingTargetID: hasCurrentClientPreview ? selectedServer?.id : nil,
            plannedClientIDs: Set(wiring.plans.map(\.clientID)),
            hasServerStatus: hasServerStatus
        )
    }

    private var showsPreview: Bool { !wiring.plans.isEmpty && wiring.previewHash != nil }

    private var prominence: ClientsProminence {
        ClientsProminence.make(
            showsPreview: showsPreview, hasCurrentPreview: hasCurrentClientPreview, showsMeasurement: wiredTransaction != nil
        )
    }

    private var notices: [ClientsNotice] {
        ClientsNotice.make(
            serverMessage: serverMessage, lastError: wiring.lastError, persistenceError: wiring.persistenceError,
            captureError: wiredTransaction != nil ? captureError : nil
        )
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                    clientWiringSection
                    formSection
                }
                .frame(maxWidth: WorkbenchSize.Clients.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(WorkbenchSpacing.pageInset)
            }
            .defaultScrollAnchor(.top)
            .onChange(of: viewport.size.width, initial: true) { _, width in
                layout = ClientsLayout(viewportWidth: width, previous: layout)
            }
        }
        .task(id: isRouteActive) {
            hasServerStatus = false
            guard isRouteActive else { return }
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
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            boardHeader
            ClientsBoardView(
                presentation: presentation, mode: layout.boardMode,
                isRefreshing: isRefreshingServer, isRouteActive: isRouteActive,
                onOpenRun: { onRouteSelection(.run) },
                picker: { endpointPicker }
            )
            actionRow
            noticeViews(.actions)
            if showsPreview, let hash = wiring.previewHash { previewSurface(hash: hash) }
            if let transaction = resultTransaction {
                ClientsOutcomeView(
                    result: transaction.resultSummary, hasIssues: !transaction.failures.isEmpty, prominence: prominence,
                    showsMeasurement: wiredTransaction != nil, isPreparing: isPreparingCapture,
                    isMeasureDisabled: isPreparingCapture || isRefreshingServer || wiring.isApplying || wiring.isCheckingServer,
                    onMeasure: { Task { await prepareCapture() } }, onReview: reviewReport
                ) { noticeViews(.measurement) }
            }
        }
    }

    // MARK: Header

    private var refreshButton: some View {
        Button(isRefreshingServer ? "Refreshing…" : "Refresh clients and servers") {
            Task { await refreshServers() }
        }
        .frame(minWidth: WorkbenchSize.Clients.refreshWidth, alignment: .trailing)
        .disabled(isRefreshingServer || wiring.isCheckingServer || wiring.isApplying)
    }

    @ViewBuilder
    private var endpointPicker: some View {
        if !runningServers.isEmpty {
            Picker("Endpoint", selection: $selectedServerID) {
                Text("Choose a running server…").tag(String?.none)
                ForEach(runningServers) { server in
                    Text("\(URL(fileURLWithPath: server.modelIdentity).lastPathComponent) :\(server.port.map(String.init) ?? "?")")
                        .tag(String?.some(server.id))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Endpoint")
            .accessibilityIdentifier("client-wiring-endpoint")
            .disabled(isRefreshingServer || wiring.isCheckingServer || wiring.isApplying)
        }
    }

    private var boardHeader: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack(spacing: WorkbenchSpacing.sm) {
                SectionTitle(text: "Client wiring")
                Spacer()
                refreshButton
            }
            Text("Point installed clients at a running local server. Each client's own config is written atomically with backup and rollback.")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
            noticeViews(.header)
        }
    }

    @ViewBuilder
    private func noticeViews(_ slot: ClientsNotice.Slot) -> some View {
        ForEach(notices.filter { $0.slot == slot }) { notice in
            if notice.isError {
                ErrorBanner(text: notice.text)
            } else {
                Text(notice.text).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if layout.wrapsActions {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { wiringActions }
        } else {
            HStack(spacing: WorkbenchSpacing.xs) { wiringActions }
        }
    }

    // MARK: Preview

    @ViewBuilder
    private func previewSurface(hash: String) -> some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                if layout.wrapsPreviewHeader {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        SectionTitle(text: "Wiring preview")
                        staleWarning
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.sm) {
                        SectionTitle(text: "Wiring preview")
                        staleWarning
                    }
                }
                if let reviewed = wiring.reviewedEndpoint {
                    Text(reviewed.modelName)
                        .font(WorkbenchTypography.emphasis)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("client-wiring-reviewed-model")
                    Text(reviewed.baseURL)
                        .font(WorkbenchTypography.value)
                        .foregroundStyle(WorkbenchColor.muted)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("client-wiring-reviewed-endpoint")
                }
                ForEach(wiring.plans) { plan in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                            ForEach(Array(plan.redactedDiff.enumerated()), id: \.offset) { _, line in
                                Text(diffText(line))
                                    .font(WorkbenchTypography.value)
                                    .foregroundStyle(diffColor(line.kind))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, WorkbenchSpacing.xxs)
                    } label: {
                        planLabel(plan)
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
                            } else {
                                clearWiringResult()
                            }
                        }
                    }
                }
                .clientsProminence(prominence.confirm)
                .disabled(wiring.isApplying || wiring.isCheckingServer || isRefreshingServer || !hasCurrentClientPreview)
                .help(hasCurrentClientPreview ? "Apply the reviewed changes to the listed client configs." : "Preview the selected endpoint before confirming.")
            }
        }
    }

    @ViewBuilder
    private var staleWarning: some View {
        if !hasCurrentClientPreview {
            Label("Endpoint changed. Preview client wiring again.", systemImage: "arrow.clockwise")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.warning)
        }
    }

    @ViewBuilder
    private func planLabel(_ plan: ClientEditPlan) -> some View {
        if layout.wrapsPreviewHeader {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                Text(plan.displayName).font(WorkbenchTypography.emphasis)
                Text(plan.summary).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                if plan.rewritesFile {
                    Text("reformats file").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                }
            }
        } else {
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
        clientPreviewButton.clientsProminence(prominence.preview)
        if wiring.rollbackAvailable {
            Button("Roll back last wiring") {
                wiring.rollback()
                clearWiringResult()
            }
                .buttonStyle(.bordered).disabled(wiring.isApplying || wiring.isCheckingServer || isRefreshingServer)
        }
    }

    private var clientPreviewButton: some View {
        Button(hasCurrentClientPreview ? "Refresh preview" : "Preview client wiring") {
            Task { @MainActor in
                clearWiringResult()
                let chosen = selectedServer
                await refreshServers()
                guard let chosen, let current = selectedServer, ClientWiringSelection.sameServer(chosen, current) else {
                    serverMessage = "Selected server stopped or changed. Choose a running server and preview again."
                    return
                }
                wiring.preview(server: current)
            }
        }
        .disabled(selectedEndpoint == nil || isRefreshingServer || wiring.isCheckingServer || wiring.isApplying || wiring.installations.allSatisfy(\.advisoryOnly))
        .help("Review proposed client config changes before applying them.")
    }

    private func clearWiringResult() {
        wiredTransactionID = nil
        wiredServer = nil
        captureError = nil
    }

    private func readConfigs() async {
        if isRouteActive { await wiring.refreshReadings() }
    }

    private func readServingStatus() async -> Bool {
        let ok = await appHost.modelWorkflow.refreshServingStatus()
        hasServerStatus = true
        return ok
    }

    private func refreshServers() async {
        guard !isRefreshingServer else { return }
        isRefreshingServer = true
        defer { isRefreshingServer = false }
        let status = await ClientsRefresh.run(readConfigs: readConfigs, readStatus: readServingStatus)
        guard status else {
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
        Picker("Target runtime", selection: $manual.draft.target) {
            Text("mlx_lm").tag("mlx_lm")
            Text("mlx-vlm").tag("mlx-vlm")
            Text("ollama").tag("ollama")
            Text("lmstudio").tag("lmstudio")
            Text("litellm").tag("litellm")
        }
        .frame(maxWidth: 180, alignment: .leading)
        .accessibilityLabel("Target runtime")
        .accessibilityIdentifier("manual-wire-target")
        .disabled(manual.operation == .applying)
        manualPreviewButton.clientsProminence(manual.preview == nil)
    }

    private var manualPreviewButton: some View {
        Button("Preview Wire") { manual.previewWiring() }
            .disabled(!manual.canPreview)
            .help("Review the model, config file and target runtime before writing this file.")
            .accessibilityIdentifier("manual-wire-preview")
    }

    private var formSection: some View {
        // Cross-client wiring above is the supported path; manual wiring stays collapsed.
        DisclosureGroup {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text("Model repo id").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
                    TextField("Model repo id", text: $manual.draft.model)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Model repo id")
                        .accessibilityIdentifier("manual-wire-model")
                        .disabled(manual.operation == .applying)
                }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text("Config file path").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
                    TextField("Config file path", text: $manual.draft.path)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Config file path")
                        .accessibilityIdentifier("manual-wire-path")
                        .disabled(manual.operation == .applying)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.xs) { manualWireControls }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { manualWireControls }
                }
                if let operation = manual.operation {
                    ProgressView(operation == .previewing ? "Previewing wiring…" : "Applying wiring…")
                        .font(WorkbenchTypography.secondary)
                        .accessibilityIdentifier("manual-wire-progress")
                }
                if let guidance = manual.guidance {
                    Label(guidance, systemImage: "arrow.clockwise")
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                }
                if let preview = manual.preview { manualReview(preview) }
                if let error = manual.errorMessage {
                    ErrorBanner(text: error).accessibilityIdentifier("manual-wire-result")
                }
                if let notice = manual.notice {
                    Label(notice, systemImage: "checkmark.circle")
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.success)
                        .accessibilityIdentifier("manual-wire-result")
                }
            }
            .padding(.top, WorkbenchSpacing.xs)
        } label: {
            Text("Advanced: manual single-file wiring")
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.muted)
        }
    }

    private func manualReview(_ preview: ManualWiringPreview) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            SectionTitle(text: "Manual wiring review")
            reviewedValue("Model repo id", value: preview.request.model, id: "manual-wire-reviewed-model")
            reviewedValue("Config file", value: preview.request.path, id: "manual-wire-reviewed-path")
            reviewedValue("Target runtime", value: preview.request.target, id: "manual-wire-reviewed-target")
            Button("Confirm manual wiring") { manual.confirmWiring() }
                .buttonStyle(.workbenchPrimary)
                .disabled(!manual.canConfirm)
                .help("Write the reviewed model and target runtime to the reviewed config file.")
                .accessibilityIdentifier("manual-wire-confirm")
            if let payload = preview.payload {
                RawJSONDisclosure("Raw wiring payload", value: payload)
            }
        }
        .formSection {}
    }

    private func reviewedValue(_ label: String, value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(label).font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
            Text(value)
                .font(WorkbenchTypography.value)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityLabel(label + ": " + value)
                .accessibilityIdentifier(id)
        }
    }
}
