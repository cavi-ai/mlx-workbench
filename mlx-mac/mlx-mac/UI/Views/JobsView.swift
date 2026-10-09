import AppKit
import SwiftUI

enum ActivityWorkflowAction: Equatable {
    case openInLibrary(String)
    case runModel(ConversionWorkflow)
    case retryPreview(ConversionWorkflow)
    case keepAnyway(ConversionWorkflow)
}

struct ActivityWorkflowCardPresentation: Identifiable, Equatable {
    let workflow: ConversionWorkflow
    let logPath: String?
    let actions: [ActivityWorkflowAction]

    var id: UUID { workflow.id }
    var stateTitle: String {
        switch workflow.state {
        case .idle: return "Idle"
        case .inspectingSource: return "Source inspected"
        case .existingModelFound: return "Existing model found"
        case .previewingConversion: return "Preparing preview"
        case .readyToConfirm: return "Ready to confirm"
        case .queued: return "Queued"
        case .running: return "Running"
        case .completed: return "Completed"
        case .verifying: return "Verifying"
        case .verified: return "Verified"
        case .verificationFailed: return "Verification failed"
        case .failed: return "Failed"
        }
    }
    var isActive: Bool { workflow.state.isInFlight }

    init(
        workflow: ConversionWorkflow,
        job: Job?,
        snapshot: LibrarySnapshot?,
        sourceEvidence: ModelItem? = nil,
        agentReady: Bool = false,
        convertRuntimeReady: Bool = false
    ) {
        self.workflow = workflow
        self.logPath = job?.logPath
        var available: [ActivityWorkflowAction] = []
        if let path = workflow.completedModelPath,
           workflow.state == .completed || workflow.state == .verified,
           let model = snapshot?.models.first(where: { $0.item.path == path || $0.outputPaths.contains(path) }) {
            available.append(.openInLibrary(path))
            if model.readiness == .ready, ModelTaskPresentation.isServable(model) { available.append(.runModel(workflow)) }
        }
        if workflow.state == .verificationFailed {
            available.append(.keepAnyway(workflow))
        }
        let hasUsableSourceEvidence = sourceEvidence?.path == workflow.sourcePath
            && sourceEvidence?.readable != false
            && sourceEvidence?.status.lowercased() != "quarantined"
        if workflow.state == .failed,
           !workflow.sourcePath.isEmpty,
           hasUsableSourceEvidence,
           agentReady,
           convertRuntimeReady {
            available.append(.retryPreview(workflow))
        }
        self.actions = available
    }
}

enum ActivityPresentation {
    static func cards(
        workflow: ConversionWorkflow,
        history: [ConversionWorkflow],
        jobs: [Job],
        snapshot: LibrarySnapshot?,
        scanModels: [ModelItem],
        agentReady: Bool,
        convertRuntimeReady: Bool
    ) -> [ActivityWorkflowCardPresentation] {
        var records = history
        if workflow.state != .idle {
            if let index = records.firstIndex(where: { $0.id == workflow.id }) {
                records[index] = workflow
            } else {
                records.append(workflow)
            }
        }
        return records.sorted { $0.updatedAt > $1.updatedAt }.map { record in
            let job = jobs.first { $0.receipt == record.jobReceipt && record.jobReceipt != nil }
            let source = scanModels.first(where: { $0.path == record.sourcePath })
            return ActivityWorkflowCardPresentation(
                workflow: record,
                job: job,
                snapshot: snapshot,
                sourceEvidence: source,
                agentReady: agentReady,
                convertRuntimeReady: convertRuntimeReady
            )
        }
    }
}

struct JobsView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var modelWorkflow: ModelWorkflowCoordinator
    @ObservedObject private var verification: VerificationCoordinator
    private let onRouteSelection: (AppRoute) -> Void

    @State private var isRefreshing = false
    @State private var statusError: String?
    @State private var selectedLog: LogSelection?
    @State private var webQueue = WebConvertQueue.Snapshot(items: [], path: "", problem: nil)
    @State private var isCompact = false
    @State private var verificationStatuses: [UUID: VerificationStatus] = [:]
    @State private var expandedRows: Set<UUID> = []
    @State private var expandedServers: Set<String> = []
    @State private var showsEarlierServers = false
    @Environment(\.isRouteActive) private var isRouteActive

    struct LogSelection: Identifiable {
        let id: String
        let path: String
    }

    init(appHost: AppHost, onRouteSelection: @escaping (AppRoute) -> Void = { _ in }) {
        self.appHost = appHost
        _modelWorkflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        _verification = ObservedObject(wrappedValue: appHost.verification)
        self.onRouteSelection = onRouteSelection
    }

    private var cards: [ActivityWorkflowCardPresentation] {
        ActivityPresentation.cards(
            workflow: modelWorkflow.workflow,
            history: modelWorkflow.history,
            jobs: modelWorkflow.jobs,
            snapshot: appHost.librarySnapshot,
            scanModels: appHost.scanResult?.models ?? [],
            agentReady: agentReady,
            convertRuntimeReady: appHost.runtimeReport.convert.ok
        )
    }

    private var agentReady: Bool {
        if case .ready = appHost.agentHealth { return true }
        return false
    }

    var body: some View {
        let page = ActivityTimeline.page(
            cards: cards, snapshot: appHost.librarySnapshot, verification: verificationStatuses, now: Date()
        )
        let inFlight = ActivityPoll.inFlightIDs(workflow: modelWorkflow.workflow, history: modelWorkflow.history)
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                    ErrorBanner(text: statusError)
                    ErrorBanner(text: modelWorkflow.persistenceError)
                    conversions(page)
                    serversSection
                    if !webQueue.items.isEmpty || webQueue.problem != nil {
                        ActivityWebQueueView(snapshot: webQueue, isCompact: isCompact)
                    }
                }
                .frame(maxWidth: WorkbenchSize.Run.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(WorkbenchSpacing.pageInset)
            }
            .defaultScrollAnchor(.top)
            .onChange(of: viewport.size.width, initial: true) { _, width in
                isCompact = ActivityLayout.isCompact(rowWidth: ActivityLayout(viewportWidth: width).rowWidth, wasCompact: isCompact)
            }
        }
        .sheet(item: $selectedLog) { LogSheet(path: $0.path) }
        .toolbar {
            if isRouteActive {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                    .help("Refresh conversion and server status")
                }
            }
        }
        .task { await refresh() }
        .task(id: inFlight) {
            guard !inFlight.isEmpty else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: ActivityPoll.interval)
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
        .onChange(of: verification.reports, initial: true) { refreshVerification() }
        .onChange(of: modelWorkflow.history) { refreshVerification() }
        .onChange(of: modelWorkflow.workflow) { refreshVerification() }
        .onChange(of: appHost.librarySnapshot?.generatedAt) { refreshVerification() }
    }

    // MARK: Conversions

    @ViewBuilder
    private func conversions(_ page: ActivityPage) -> some View {
        if page.isEmpty {
            designedState(symbol: "clock.arrow.circlepath", text: "No conversions yet; the ones you start in Prepare appear here.")
        } else {
            if !page.inFlight.isEmpty { rowSection("In flight", rows: page.inFlight) }
            ForEach(page.groups) { rowSection($0.title, rows: $0.rows) }
        }
    }

    private func rowSection(_ title: String, rows: [ActivityRowPresentation]) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            SectionTitle(text: title)
            WorkbenchSurface {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.vertical, WorkbenchSpacing.sm) }
                        ActivityRowView(
                            row: row,
                            isCompact: isCompact,
                            pulses: isRouteActive,
                            isExpanded: expansion(of: row.id),
                            perform: perform,
                            viewLog: { selectedLog = LogSelection(id: $0, path: $0) },
                            copySource: copyToPasteboard,
                            dismiss: { appHost.modelWorkflow.dismiss(recordID: row.id) }
                        )
                    }
                }
            }
        }
    }

    private func expansion(of id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedRows.contains(id) },
            set: { if $0 { expandedRows.insert(id) } else { expandedRows.remove(id) } }
        )
    }

    // MARK: Servers

    private var serversSection: some View {
        let split = ActivityServerRow.split(modelWorkflow.servers, models: appHost.librarySnapshot?.models ?? [], now: Date())
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            SectionTitle(text: "Servers")
            if split.running.isEmpty && split.earlier.isEmpty {
                designedState(symbol: "server.rack", text: "No server records yet; serving a model from Run adds one.")
            } else {
                if split.running.isEmpty {
                    designedState(symbol: "server.rack", text: "No server is running.")
                } else {
                    serverSurface(split.running, style: isCompact ? .twoLine : .wide)
                }
                if !split.earlier.isEmpty {
                    DisclosureGroup(isExpanded: $showsEarlierServers) {
                        serverSurface(split.earlier, style: isCompact ? .oneLine : .wide)
                            .padding(.top, WorkbenchSpacing.xs)
                    } label: {
                        Text("Earlier servers (\(split.earlier.count))")
                            .font(WorkbenchTypography.label)
                            .foregroundStyle(WorkbenchColor.muted)
                    }
                }
            }
        }
    }

    private func serverSurface(_ rows: [ActivityServerRow], style: ActivityServerRowView.Style) -> some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.vertical, WorkbenchSpacing.sm) }
                    ActivityServerRowView(
                        row: row,
                        style: style,
                        isExpanded: Binding(
                            get: { expandedServers.contains(row.id) },
                            set: { if $0 { expandedServers.insert(row.id) } else { expandedServers.remove(row.id) } }
                        ),
                        viewLog: { selectedLog = LogSelection(id: $0, path: $0) }
                    )
                }
            }
        }
    }

    private func designedState(symbol: String, text: String) -> some View {
        Label {
            Text(text)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
        } icon: {
            Image(systemName: symbol).foregroundStyle(WorkbenchColor.muted)
        }
    }

    // MARK: Status

    private func refreshVerification() {
        let snapshot = appHost.librarySnapshot
        var next: [UUID: VerificationStatus] = [:]
        for card in cards where card.workflow.state == .completed {
            guard let path = card.workflow.completedModelPath else { continue }
            let signature = PrepareWorkflowPresentation(workflow: card.workflow).outputModel(in: snapshot)?.item.signature
            next[card.id] = verification.status(for: path, signature: signature)
        }
        verificationStatuses = next
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        webQueue = WebConvertQueue.loadDefault()
        do {
            let jobs = try await appHost.api.convertStatus()
            statusError = nil
            await appHost.refreshWorkflowStatus(jobs: jobs)
        } catch {
            statusError = "Live conversion status unavailable: \(AppHost.render(error)). Showing last known activity."
            await appHost.refreshWorkflowStatus()
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func perform(_ action: ActivityWorkflowAction) {
        switch action {
        case .openInLibrary(let path):
            appHost.selectedModelPath = path
            onRouteSelection(.library)
        case .runModel(let record):
            guard let path = record.completedModelPath else { return }
            guard let model = appHost.librarySnapshot?.models.first(where: { $0.item.path == path || $0.outputPaths.contains(path) }) else { return }
            guard record.state == .completed || record.state == .verified, model.readiness == .ready else { return }
            appHost.modelWorkflow.restore(record)
            appHost.modelWorkflow.prepareServe(model: model, exactPath: path)
            appHost.selectedModelPath = path
            onRouteSelection(.run)
        case .keepAnyway(let record):
            appHost.verification.keepAnyway(recordID: record.id)
        case .retryPreview(let record):
            appHost.modelWorkflow.restore(record)
            appHost.selectedModelPath = record.sourcePath
            onRouteSelection(.prepare)
        }
    }
}

struct LogSheet: View {
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = "Loading..."
    @State private var truncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack { Text(path).font(WorkbenchTypography.emphasis); Spacer(); Button("Close") { dismiss() } }
            if truncated { Text("(truncated to the tail)").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted) }
            ScrollView {
                Text(text).font(WorkbenchTypography.value)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
        .padding().frame(width: 720, height: 480).onAppear { load() }
    }

    private func load() {
        Task {
            let maxBytes = 64 * 1024
            let url = URL(string: path).flatMap { $0.scheme == "file" ? $0 : nil } ?? URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { text = "Invalid log path."; return }
            guard let data = try? Data(contentsOf: url) else { text = "Log not readable yet."; return }
            truncated = data.count > maxBytes
            let chunk = truncated ? data.suffix(maxBytes) : data
            text = (truncated ? "...\n" : "") + String(decoding: chunk, as: UTF8.self)
        }
    }
}
