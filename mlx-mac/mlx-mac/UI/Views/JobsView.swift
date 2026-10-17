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
        let owners = Job.owners(of: jobs, among: records)
        return records.sorted { $0.updatedAt > $1.updatedAt }.map { record in
            let source = scanModels.first(where: { $0.path == record.sourcePath })
            return ActivityWorkflowCardPresentation(
                workflow: record,
                job: owners[record.id],
                snapshot: snapshot,
                sourceEvidence: source,
                agentReady: agentReady,
                convertRuntimeReady: convertRuntimeReady
            )
        }
    }
}

struct ActivityComparisonSection: View {
    @ObservedObject var comparison: ComparisonCoordinator
    let onOpen: () -> Void

    var body: some View {
        if comparison.activeRunID != nil || comparison.runStateUnavailableReason != nil {
            WorkbenchSurface {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    HStack {
                        Text("Comparison").font(WorkbenchTypography.cardTitle)
                        Spacer()
                        Button("Open Compare", action: onOpen)
                            .help("Open the comparison setup and recorded results.")
                            .accessibilityIdentifier("activity-open-comparison")
                    }
                    if let run = comparison.runs.first(where: { $0.id == comparison.activeRunID }) {
                        Text(run.promptSetName).font(WorkbenchTypography.emphasis)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(run.variants.isEmpty ? run.effectiveMode.title :
                            "\(run.effectiveMode.title) · \(run.variants.count) \(run.variants.count == 1 ? "lane" : "lanes")")
                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    }
                    if comparison.activeRunID != nil {
                        ComparisonProgressControls(message: comparison.progressMessage ?? "Measuring…",
                            isCancelling: comparison.isCancelling, cleanupPending: comparison.cleanupPending,
                            onCancel: comparison.cancel, onRetry: comparison.retryCleanup)
                    }
                    if let reason = comparison.runStateUnavailableReason {
                        Text(reason).font(WorkbenchTypography.secondary)
                            .foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    ErrorBanner(text: comparison.lastError)
                    ErrorBanner(text: comparison.persistenceError)
                }
            }
            .accessibilityIdentifier("activity-comparison")
        }
    }
}

struct JobsView: View {
    @ObservedObject var appHost: AppHost
    @ObservedObject private var modelWorkflow: ModelWorkflowCoordinator
    @ObservedObject private var verification: VerificationCoordinator
    @ObservedObject private var lab: LabCoordinator
    private let onRouteSelection: (AppRoute) -> Void

    @State private var isRefreshing = false
    @State private var statusError: String?
    @State private var selectedLog: LogSelection?
    @State private var webQueue = WebConvertQueue.Snapshot(items: [], path: "", problem: nil)
    @State private var isCompact = false
    @State private var trainingState = ActivityTrainingState()
    @State private var showsEmptyQueue = false
    @State private var queueBusy = false
    @State private var queueImport: QueueImport?
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
        _lab = ObservedObject(wrappedValue: appHost.lab)
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
        let studyJobs = lab.snapshot.queue ?? []
        let currentStudies = lab.error != nil ? studyJobs : studyJobs.filter { ActivityJobPriority.study($0, runningJobID: lab.runningJobID) }
        let earlierStudies = lab.error != nil ? [] : studyJobs.filter { !ActivityJobPriority.study($0, runningJobID: lab.runningJobID) }
        let currentTraining = trainingState.error != nil ? trainingState.jobs : trainingState.jobs.filter(ActivityJobPriority.training)
        let earlierTraining = trainingState.error != nil ? [] : trainingState.jobs.filter { !ActivityJobPriority.training($0) }
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                    ErrorBanner(text: statusError)
                    ErrorBanner(text: modelWorkflow.persistenceError)
                    ActivityComparisonSection(comparison: appHost.comparison) { onRouteSelection(.compare) }
                    if !page.inFlight.isEmpty { rowSection("In flight", rows: page.inFlight) }
                    ActivityStudySection(lab: lab, jobs: currentStudies, error: lab.error,
                        isWorking: lab.runningJobID != nil, onOpen: { onRouteSelection(.studies) })
                    ActivityTrainingSection(jobs: currentTraining, error: trainingState.error,
                        onOpen: { onRouteSelection(.training) }, onCancel: cancelTraining)
                    if !page.needsAttention.isEmpty { rowSection("Needs attention", rows: page.needsAttention) }
                    serversSection
                    queueSection
                    conversions(page)
                    ActivityStudySection(lab: lab, jobs: earlierStudies, error: nil, historical: true,
                        onOpen: { onRouteSelection(.studies) })
                    ActivityTrainingSection(jobs: earlierTraining, error: nil, historical: true,
                        onOpen: { onRouteSelection(.training) }, onCancel: cancelTraining)
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
        .sheet(item: $queueImport) { plan in
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                Text("Import queued conversions").font(WorkbenchTypography.title)
                Text("Stop the old web server before importing. The source remains untouched and an exact backup is retained.")
                Text(plan.source).textSelection(.enabled)
                Text("\(plan.count) queued records · SHA-256 \(plan.digest)").textSelection(.enabled)
                HStack {
                    Button("Cancel") { queueImport = nil }
                    Button("Import") {
                        queueImport = nil
                        queueAction(["operation": .string("adopt"), "source": .string(plan.source),
                                     "preview_hash": .string(plan.hash)])
                    }
                }
            }.padding(WorkbenchSpacing.pageInset).frame(width: 560)
        }
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
            if let error = modelWorkflow.serversError {
                ErrorBanner(text: error)
                if !modelWorkflow.servers.isEmpty {
                    Text("Showing last known server records.").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
            }
            if split.running.isEmpty && split.earlier.isEmpty {
                if modelWorkflow.serversError == nil {
                    designedState(symbol: "server.rack", text: "No server records yet; serving a model from Run adds one.")
                }
            } else {
                if split.running.isEmpty {
                    if modelWorkflow.serversError == nil { designedState(symbol: "server.rack", text: "No server is running.") }
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

    private struct QueueImport: Identifiable {
        let id = UUID()
        let source: String
        let hash: String
        let digest: String
        let count: Int
    }

    private var queueSection: some View {
        WorkbenchSurface {
            if webQueue.items.isEmpty && webQueue.problem == nil {
                DisclosureGroup("Conversion queue", isExpanded: $showsEmptyQueue) {
                    queueContents(showTitle: false).padding(.top, WorkbenchSpacing.sm)
                }
            } else { queueContents(showTitle: true) }
        }
    }

    private func queueContents(showTitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                if showTitle { Text("Conversion queue").font(WorkbenchTypography.cardTitle) }
                Spacer()
                Button("Import existing queue") { importQueue() }.disabled(queueBusy)
                Button("Run next") { queueAction(["operation": .string("run")]) }
                    .disabled(queueBusy || !webQueue.items.contains { $0.state == .queued || $0.state == .starting })
            }
            Text("Reviewed conversion plans are retained by mlx-agent. Run next starts one plan; refresh reconciles its receipt.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            if let problem = webQueue.problem { Text(problem).foregroundStyle(WorkbenchColor.failure) }
            ForEach(webQueue.items) { item in
                Divider()
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.label).font(WorkbenchTypography.cardTitle)
                        Text("\(item.state.rawValue) · q\(item.qBits) · \(item.path ?? item.repo ?? "")").font(WorkbenchTypography.metadata)
                        if let failure = item.failure { Text(failure.message + " " + failure.remediation).foregroundStyle(WorkbenchColor.failure) }
                    }
                    Spacer()
                    if item.state == .queued {
                        Button("↑") { queueAction(["operation": .string("move"), "id": .string(item.id), "direction": .string("up")]) }
                        Button("↓") { queueAction(["operation": .string("move"), "id": .string(item.id), "direction": .string("down")]) }
                    }
                    if item.state == .failed {
                        Button("Retry") { queueAction(["operation": .string("retry"), "id": .string(item.id)]) }
                    }
                    if item.state != .starting {
                        Button("Remove") { queueAction(["operation": .string("cancel"), "id": .string(item.id)]) }
                    }
                }.disabled(queueBusy)
            }
        }
    }

    private func queueAction(_ fields: [String: LabValue]) {
        guard !queueBusy else { return }
        queueBusy = true
        Task {
            defer { queueBusy = false }
            do {
                webQueue = try await appHost.api.conversionQueue(.object(fields)).snapshot()
                statusError = nil
            } catch { statusError = AppHost.render(error) }
        }
    }

    private func importQueue() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        queueBusy = true
        Task {
            defer { queueBusy = false }
            do {
                let result = try await appHost.api.conversionQueue(.object([
                    "operation": .string("adopt-preview"), "source": .string(source.path)]))
                guard let hash = result.previewHash, let digest = result.sourceDigest, let count = result.itemCount else {
                    throw WebConvertQueue.LoadError.invalidSchema("Queue import preview is incomplete.")
                }
                queueImport = QueueImport(source: source.path, hash: hash, digest: digest, count: count)
            } catch { statusError = AppHost.render(error) }
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await appHost.lab.refresh()
        do { trainingState.received(try await appHost.api.trainingStatus().jobs) }
        catch { trainingState.failed("Training status unavailable: \(AppHost.render(error))") }
        do { webQueue = try await appHost.api.conversionQueue(.object(["operation": .string("snapshot")])).snapshot() }
        catch { webQueue = .init(items: webQueue.items, path: webQueue.path, problem: AppHost.render(error)) }
        do {
            let jobs = try await appHost.api.convertStatus()
            statusError = nil
            await appHost.refreshWorkflowStatus(jobs: jobs)
        } catch {
            statusError = "Live conversion status unavailable: \(AppHost.render(error)). Showing last known activity."
            await appHost.refreshWorkflowStatus()
        }
        await modelWorkflow.refreshServers()
    }

    private func cancelTraining(_ job: TrainingJob) {
        Task {
            do { _ = try await appHost.api.trainingStop(pid: job.pid); await refresh() }
            catch { trainingState.failed("Training cancellation failed: \(AppHost.render(error))") }
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func perform(_ action: ActivityWorkflowAction) {
        switch action {
        case .openInLibrary(let path):
            appHost.libraryRevealRequest = LibraryRevealRequest(modelPath: path)
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
