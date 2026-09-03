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
    var isActive: Bool { workflow.state == .queued || workflow.state == .running || workflow.state == .verifying }

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
            if model.readiness == .ready { available.append(.runModel(workflow)) }
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
    private let onRouteSelection: (String) -> Void

    @State private var lastKnownJobs: [Job] = []
    @State private var isRefreshing = false
    @State private var statusError: String?
    @State private var selectedLog: LogSelection?

    struct LogSelection: Identifiable {
        let id: String
        let path: String
    }

    init(appHost: AppHost, onRouteSelection: @escaping (String) -> Void = { _ in }) {
        self.appHost = appHost
        _modelWorkflow = ObservedObject(wrappedValue: appHost.modelWorkflow)
        self.onRouteSelection = onRouteSelection
    }

    private var cards: [ActivityWorkflowCardPresentation] {
        ActivityPresentation.cards(
            workflow: modelWorkflow.workflow,
            history: modelWorkflow.history,
            jobs: lastKnownJobs,
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
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Activity").font(WorkbenchTypography.display).foregroundColor(WorkbenchColor.graphiteInk)
                        Text("Persisted conversion history and authoritative live process state.")
                            .font(WorkbenchTypography.body).foregroundColor(WorkbenchColor.graphiteMuted)
                    }
                    Spacer()
                    Button("Refresh") { Task { await refresh() } }.disabled(isRefreshing)
                }
                ErrorBanner(text: statusError)
                ErrorBanner(text: modelWorkflow.persistenceError)
                serversSection
                SectionTitle(text: "Conversions")
                if cards.isEmpty {
                    Text("No conversion activity yet.").font(.callout).foregroundColor(.secondary)
                } else {
                    ForEach(cards) { conversionCard($0) }
                }
            }
            .padding(WorkbenchSpacing.pageInset)
        }
        .sheet(item: $selectedLog) { LogSheet(path: $0.path) }
        .task {
            await refresh()
            while !Task.isCancelled && cards.contains(where: \.isActive) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await refresh()
            }
        }
    }

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Servers")
            if modelWorkflow.servers.isEmpty {
                Text("No authoritative server records are available.")
                    .font(.callout).foregroundColor(.secondary)
            } else {
                ForEach(modelWorkflow.servers) { server in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            StatusPill(state: server.state ?? "unknown")
                            Text(server.repo ?? "Unknown model").font(.headline).lineLimit(1)
                            Spacer()
                            if let port = server.port { Text(":\(port)").font(.caption) }
                        }
                        detailLine("PID", server.pid.map(String.init) ?? "Not reported")
                        detailLine("Receipt", server.receipt ?? "Not reported")
                        detailLine("Started", server.startedAt ?? "Not reported")
                        detailLine("Log path", server.logPath ?? "Not reported")
                    }
                    .formSection {}
                }
            }
        }
    }

    private func conversionCard(_ card: ActivityWorkflowCardPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusPill(state: card.workflow.state.rawValue)
                Text(card.stateTitle).font(.headline)
                Spacer()
                Text("Updated \(timestamp(card.workflow.updatedAt))")
                    .font(.caption).foregroundColor(.secondary)
            }
            detailLine("Source", card.workflow.sourcePath.isEmpty ? "Not recorded" : card.workflow.sourcePath)
            detailLine("Destination", card.workflow.outputPath.isEmpty ? "Not recorded" : card.workflow.outputPath)
            detailLine("Receipt", card.workflow.jobReceipt ?? "Not reported")
            detailLine("Created", timestamp(card.workflow.createdAt))
            detailLine("Agent state", card.workflow.lastKnownAgentState ?? "Not reported")
            detailLine("Log path", card.logPath ?? "Not reported")
            if let failure = card.workflow.errorMessage {
                Text(failure).font(.callout).foregroundColor(WorkbenchColor.systemRed).textSelection(.enabled)
            } else if let message = card.workflow.message {
                Text(message).font(.callout).foregroundColor(.secondary)
            }
            if !card.actions.isEmpty {
                HStack {
                    ForEach(Array(card.actions.enumerated()), id: \.offset) { _, action in
                        Button(actionTitle(action)) { perform(action) }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .formSection {}
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let jobs = try await appHost.api.convertStatus()
            lastKnownJobs = jobs
            statusError = nil
            await appHost.refreshWorkflowStatus(jobs: jobs)
        } catch {
            statusError = "Live conversion status unavailable: \(AppHost.render(error)). Showing last known activity."
            await appHost.refreshWorkflowStatus()
        }
    }

    private func actionTitle(_ action: ActivityWorkflowAction) -> String {
        switch action {
        case .openInLibrary: return "Open in Library"
        case .runModel: return "Run model"
        case .retryPreview: return "Retry preview"
        case .keepAnyway: return "Keep anyway (unverified)"
        }
    }

    private func perform(_ action: ActivityWorkflowAction) {
        switch action {
        case .openInLibrary(let path):
            appHost.selectedModelPath = path
            onRouteSelection("models")
        case .runModel(let record):
            guard let path = record.completedModelPath else { return }
            guard let model = appHost.librarySnapshot?.models.first(where: { $0.item.path == path || $0.outputPaths.contains(path) }) else { return }
            guard record.state == .completed || record.state == .verified, model.readiness == .ready else { return }
            appHost.modelWorkflow.restore(record)
            appHost.modelWorkflow.prepareServe(model: model, exactPath: path)
            appHost.selectedModelPath = path
            onRouteSelection("serve")
        case .keepAnyway(let record):
            appHost.verification.keepAnyway(recordID: record.id)
        case .retryPreview(let record):
            appHost.modelWorkflow.restore(record)
            appHost.selectedModelPath = record.sourcePath
            onRouteSelection("convert")
        }
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundColor(WorkbenchColor.graphiteMuted).frame(width: 110, alignment: .leading)
            Text(value).font(WorkbenchTypography.monoUtility).foregroundColor(WorkbenchColor.graphiteInk).textSelection(.enabled)
            Spacer()
        }
        .font(WorkbenchTypography.monoUtility)
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct LogSheet: View {
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = "Loading..."
    @State private var truncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(path).font(.headline); Spacer(); Button("Close") { dismiss() } }
            if truncated { Text("(truncated to the tail)").font(.caption).foregroundColor(.secondary) }
            ScrollView {
                Text(text).font(.system(.caption, design: .monospaced))
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
