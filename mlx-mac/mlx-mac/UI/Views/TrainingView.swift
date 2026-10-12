import AppKit
import SwiftUI

struct TrainingDraft: Equatable {
    var repo = ""
    var data = ""
    var iterations = "100"
    var output = ""

    var iterationsError: String? {
        guard let value = Int(iterations.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            return "Enter a positive whole number of iterations."
        }
        return nil
    }

    var request: TrainingRequest? {
        let repo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = data.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty, !data.isEmpty, iterationsError == nil,
              let iterations = Int(iterations.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return TrainingRequest(repo: repo, data: data, iterations: iterations, output: output.isEmpty ? nil : output)
    }
}

struct TrainingRequest: Equatable {
    let repo: String
    let data: String
    let iterations: Int
    let output: String?
}

struct TrainingPreview {
    let request: TrainingRequest
    let hash: String
    let payload: [String: Any]
}

@MainActor
final class TrainingSession: ObservableObject {
    enum Operation: Equatable { case previewing, submitting }
    @Published var draft = TrainingDraft() {
        didSet {
            guard draft != oldValue else { return }
            revision += 1
            preview = nil
            errorMessage = nil
            notice = nil
        }
    }
    @Published private(set) var preview: TrainingPreview?
    @Published private(set) var operation: Operation?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    private var revision = 0
    private let previewOperation: (TrainingRequest) async throws -> [String: Any]
    private let startOperation: (TrainingRequest, String) async throws -> Void

    init(preview: @escaping (TrainingRequest) async throws -> [String: Any],
         start: @escaping (TrainingRequest, String) async throws -> Void) {
        previewOperation = preview
        startOperation = start
    }

    var isBusy: Bool { operation != nil }
    var canPreview: Bool { !isBusy && draft.request != nil }
    var canConfirm: Bool { !isBusy && preview != nil && preview?.request == draft.request }

    @discardableResult
    func previewTraining() -> Task<Void, Never>? {
        guard canPreview, let request = draft.request else { return nil }
        let revision = revision
        operation = .previewing
        preview = nil
        errorMessage = nil
        notice = nil
        return Task {
            defer { operation = nil }
            do {
                let payload = try await previewOperation(request)
                guard self.revision == revision, draft.request == request else { return }
                let nested = payload["plan"] as? [String: Any]
                guard let hash = (payload["preview_hash"] as? String ?? nested?["preview_hash"] as? String),
                      !hash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    errorMessage = "Training preview did not include a confirmation hash. Preview again before training."
                    return
                }
                preview = TrainingPreview(request: request, hash: hash, payload: payload)
            } catch {
                guard self.revision == revision else { return }
                errorMessage = AppHost.render(error)
            }
        }
    }

    @discardableResult
    func confirmTraining() -> Task<Void, Never>? {
        guard canConfirm, let preview else { return nil }
        operation = .submitting
        errorMessage = nil
        notice = nil
        return Task {
            defer { operation = nil }
            do {
                try await startOperation(preview.request, preview.hash)
                self.preview = nil
                notice = "Training submitted. See Activity."
            } catch {
                errorMessage = AppHost.render(error)
            }
        }
    }
}

enum TrainingField: Hashable { case repo, data, iterations }

struct TrainingPreviewGuidance: Equatable {
    let message: String
    let field: TrainingField?

    static func resolve(draft: TrainingDraft, operation: TrainingSession.Operation?) -> Self? {
        if let operation {
            return Self(message: operation == .previewing ? "Preparing training preview…" : "Submitting training…", field: nil)
        }
        if draft.repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self(message: "Enter a base model repo id to preview training.", field: .repo)
        }
        if draft.data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self(message: "Choose a dataset directory to preview training.", field: .data)
        }
        if let error = draft.iterationsError { return Self(message: error, field: .iterations) }
        return nil
    }
}

/// Each read owns its loading/error state. Failed refreshes keep the last
/// successful rows, and synchronous locks prevent duplicate CLI requests.
struct TrainingCollectionState<Element> {
    enum Phase: Equatable { case loading, empty, populated, failed }
    var items: [Element] = []
    var hasLoaded = false
    var isLoading = false
    var error: String?

    var phase: Phase {
        if !items.isEmpty { return .populated }
        if isLoading || (!hasLoaded && error == nil) { return .loading }
        if error != nil { return .failed }
        return .empty
    }
}

struct TrainingEvaluationRecord: Identifiable {
    let id: String
    let value: LabValue

    init?(_ value: LabValue) {
        guard let id = value.object?["id"]?.text, !id.isEmpty else { return nil }
        self.id = id
        self.value = value
    }
}

@MainActor
final class TrainingCollections: ObservableObject {
    struct Inspection {
        let recordID: String
        let response: LabResponse
    }

    @Published private(set) var jobs = TrainingCollectionState<TrainingJob>()
    @Published private(set) var history = TrainingCollectionState<LabValue>()
    @Published private(set) var inspection: Inspection?
    @Published private(set) var inspectingID: String?
    @Published private(set) var inspectionError: String?
    private let readJobs: () async throws -> [TrainingJob]
    private let readHistory: () async throws -> [LabValue]
    private let readInspection: (String) async throws -> LabResponse

    init(jobs: @escaping () async throws -> [TrainingJob],
         history: @escaping () async throws -> [LabValue],
         inspect: @escaping (String) async throws -> LabResponse) {
        readJobs = jobs
        readHistory = history
        readInspection = inspect
    }

    @discardableResult
    func refreshJobs() -> Task<Void, Never>? {
        guard !jobs.isLoading else { return nil }
        jobs.isLoading = true
        jobs.error = nil
        return Task {
            defer { jobs.isLoading = false }
            do {
                jobs.items = try await readJobs()
                jobs.hasLoaded = true
            } catch { jobs.error = AppHost.render(error) }
        }
    }

    @discardableResult
    func refreshHistory() -> Task<Void, Never>? {
        guard !history.isLoading else { return nil }
        history.isLoading = true
        history.error = nil
        return Task {
            defer { history.isLoading = false }
            do {
                history.items = try await readHistory()
                history.hasLoaded = true
            } catch { history.error = AppHost.render(error) }
        }
    }

    func refresh() async {
        let jobsTask = refreshJobs()
        let historyTask = refreshHistory()
        await jobsTask?.value
        await historyTask?.value
    }

    @discardableResult
    func inspect(_ recordID: String) -> Task<Void, Never>? {
        guard inspectingID == nil else { return nil }
        inspectingID = recordID
        inspectionError = nil
        return Task {
            defer { inspectingID = nil }
            do {
                let response = try await readInspection(recordID)
                inspection = Inspection(recordID: recordID, response: response)
            } catch {
                inspectionError = "Could not inspect \(recordID): \(AppHost.render(error))"
            }
        }
    }
}

// MARK: - TrainingView
// LoRA preview/confirm training on a cached base model.

struct TrainingView: View {
    @ObservedObject var appHost: AppHost
    @StateObject private var session: TrainingSession
    @StateObject private var collections: TrainingCollections
    @State private var evaluationJob: TrainingJob?
    @State private var cancelError: String?
    @State private var cancelingPIDs: Set<Int> = []
    @FocusState private var focusedField: TrainingField?

    init(appHost: AppHost) {
        self.appHost = appHost
        _session = StateObject(wrappedValue: TrainingSession(
            preview: { request in
                try await appHost.api.loraPreview(repo: request.repo, data: request.data, iters: request.iterations, out: request.output)
            },
            start: { request, hash in
                _ = try await appHost.api.loraStart(repo: request.repo, data: request.data, previewHash: hash, iters: request.iterations, out: request.output)
            }
        ))
        _collections = StateObject(wrappedValue: TrainingCollections(
            jobs: { try await appHost.api.trainingStatus().jobs },
            history: { try await appHost.lab.request(LabRequest(operation: "training-history")).evaluations ?? [] },
            inspect: { try await appHost.lab.request(LabRequest(operation: "training-inspect", evaluationID: $0)) }
        ))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                    formSection(proxy)
                    if let preview = session.preview { planSection(preview) }
                    trainingJobs
                    evaluationHistory
                }
                .frame(maxWidth: WorkbenchSize.contentMaxWidth, alignment: .leading)
                .padding(WorkbenchSpacing.pageInset)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .sheet(item: $evaluationJob) { job in TrainingEvaluationSheet(lab: appHost.lab, job: job) }
        .task { await collections.refresh() }
    }

    private var guidance: TrainingPreviewGuidance? {
        TrainingPreviewGuidance.resolve(draft: session.draft, operation: session.operation)
    }

    private func formSection(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            SectionTitle(text: "LoRA fine-tune")
            requestSignature(repo: session.draft.repo, data: session.draft.data, output: session.draft.output)
            Divider()
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                if !cachedRepoIdentities.isEmpty {
                    Picker("Cached base model", selection: cachedRepoSelection) {
                        Text("Custom repo id…").tag("")
                        ForEach(cachedRepoIdentities, id: \.self) { identity in Text(identity).tag(identity) }
                    }
                }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    fieldLabel("Base model repo id")
                    TextField("Base model repo id", text: $session.draft.repo)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Base model repo id")
                        .focused($focusedField, equals: .repo)
                }.id(TrainingField.repo)
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    fieldLabel("Dataset path")
                    HStack(spacing: WorkbenchSpacing.xs) {
                        TextField("Dataset path", text: $session.draft.data)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Dataset path")
                            .focused($focusedField, equals: .data)
                        Button("Choose…") { chooseDataset() }.buttonStyle(.bordered)
                    }
                }.id(TrainingField.data)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.md) { trainingFields }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) { trainingFields }
                }
            }.disabled(session.isBusy)
            previewActions(proxy)
            if session.preview == nil { operationFeedback }
        }
        .formSection {}
    }

    /// This signature only renders entered or captured values; the training
    /// plan remains the authority for any unspecified output destination.
    private func requestSignature(repo: String, data: String, output: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: WorkbenchSpacing.md) {
                signatureInput(repo: repo, data: data)
                Image(systemName: "arrow.right").foregroundStyle(WorkbenchColor.muted).accessibilityHidden(true)
                signatureOutput(output)
            }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                signatureInput(repo: repo, data: data)
                Label("LoRA adapter", systemImage: "arrow.turn.down.right").font(WorkbenchTypography.title)
                if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(output.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(WorkbenchTypography.compactValue).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func signatureInput(repo: String, data: String) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                fieldLabel("Base model")
                Text(repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter a repo id" : repo.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(WorkbenchTypography.title).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Label("Dataset", systemImage: "plus").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
                Text(data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Choose a directory" : data.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(WorkbenchTypography.compactValue).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func signatureOutput(_ output: String) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text("LoRA adapter").font(WorkbenchTypography.title)
            if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(output.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(WorkbenchTypography.compactValue).textSelection(.enabled)
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
    }

    private var cachedRepoIdentities: [String] {
        let models = appHost.librarySnapshot?.models ?? []
        var identities: Set<String> = []
        for model in models {
            for path in [model.item.path] + model.outputPaths {
                if let repoID = HFRepoID.forPath(path) { identities.insert(repoID) }
            }
        }
        return identities.sorted()
    }

    private var cachedRepoSelection: Binding<String> {
        Binding(
            get: { cachedRepoIdentities.contains(session.draft.repo) ? session.draft.repo : "" },
            set: { session.draft.repo = $0 }
        )
    }

    @ViewBuilder
    private var trainingFields: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            fieldLabel("Iterations")
            TextField("Iterations", text: $session.draft.iterations)
                .textFieldStyle(.roundedBorder)
                .frame(width: WorkbenchSize.Settings.fieldNarrow)
                .accessibilityLabel("Iterations")
                .focused($focusedField, equals: .iterations)
            if let error = session.draft.iterationsError {
                Text(error).font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.id(TrainingField.iterations)
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            fieldLabel("Output (optional)")
            TextField("Output (optional)", text: $session.draft.output)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Output directory")
        }
    }

    private func previewActions(_ proxy: ScrollViewProxy) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: WorkbenchSpacing.sm) {
                previewGuidance(proxy)
                Spacer(minLength: 0)
                previewButton
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                previewGuidance(proxy)
                previewButton
            }
        }
    }

    @ViewBuilder
    private func previewGuidance(_ proxy: ScrollViewProxy) -> some View {
        if let guidance {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                HStack(spacing: WorkbenchSpacing.xs) {
                    if session.isBusy { ProgressView().controlSize(.small) }
                    Text(guidance.message).font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("training-guidance")
                }
                if let field = guidance.field {
                    Button("Fix field") { reveal(field, proxy: proxy) }
                        .accessibilityIdentifier("training-fix-field")
                        .help("Reveal and focus the field that needs attention.")
                }
            }
        }
    }

    private func reveal(_ field: TrainingField, proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(field, anchor: .center) }
        // Focus follows layout, only after an explicit recovery action.
        DispatchQueue.main.async { focusedField = field }
    }

    @ViewBuilder
    private var previewButton: some View {
        if session.preview == nil {
            previewControl.buttonStyle(.borderedProminent)
        } else {
            previewControl.buttonStyle(.bordered)
        }
    }

    private var previewControl: some View {
        Button(session.operation == .previewing ? "Previewing…" : "Preview Training") { session.previewTraining() }
            .disabled(!session.canPreview)
            .accessibilityIdentifier("training-preview")
            .help(guidance?.message ?? "Capture this training request for review.")
    }

    @ViewBuilder
    private var operationFeedback: some View {
        ErrorBanner(text: session.errorMessage)
        if let notice = session.notice {
            Label(notice, systemImage: "checkmark.circle")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.success)
        }
    }

    private func planSection(_ preview: TrainingPreview) -> some View {
        WorkbenchSurface(.tinted) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    SectionTitle(text: "Training plan")
                    Text("Captured from your preview. Editing the setup requires a new preview.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
                requestSignature(repo: preview.request.repo, data: preview.request.data, output: preview.request.output ?? "")
                planRow("Iterations", String(preview.request.iterations))
                if preview.request.output == nil {
                    Text("No output directory entered.").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
                operationFeedback
                Button(session.operation == .submitting ? "Submitting…" : "Confirm & Train") { confirmTraining() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.canConfirm)
                    .accessibilityIdentifier("training-confirm")
                    .help("Submit the captured training request shown above.")
                Divider()
                RawJSONDisclosure("Raw plan payload", value: preview.payload)
            }
        }
    }

    private func planRow(_ label: String, _ value: String) -> some View {
        LabeledContent {
            Text(value).font(WorkbenchTypography.body).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } label: { fieldLabel(label) }
    }

    private var trainingJobs: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                HStack {
                    Label("Training jobs", systemImage: "list.bullet.rectangle").font(WorkbenchTypography.cardTitle)
                    Spacer()
                    Button("Refresh") { collections.refreshJobs() }
                        .disabled(collections.jobs.isLoading).accessibilityIdentifier("training-refresh-jobs")
                }
                collectionFeedback(collections.jobs, name: "training-jobs", loading: "Loading training jobs…",
                    refreshing: "Refreshing training jobs…", empty: "No training jobs", symbol: "list.bullet.rectangle",
                    explanation: "Preview and confirm a training request to create a job.")
                ForEach(collections.jobs.items) { job in
                    Divider()
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        Text(job.repo + " · " + job.state).font(WorkbenchTypography.cardTitle)
                        Text(job.out).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let identity = job.adapterIdentity {
                            DisclosureGroup("Adapter content identity") {
                                Text(identity.jsonText).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                            }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: WorkbenchSpacing.sm) { jobActions(job) }
                            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { jobActions(job) }
                        }
                    }
                }
                if let cancelError {
                    Label(cancelError, systemImage: "exclamationmark.triangle")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
                        .textSelection(.enabled).accessibilityIdentifier("training-cancel-error")
                }
            }
        }
    }

    @ViewBuilder
    private func jobActions(_ job: TrainingJob) -> some View {
        if job.state == "done", job.adapterIdentity != nil {
            Button("Compare with base") { evaluationJob = job }
        }
        if let log = job.logPath {
            Button("Open log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
        }
        if job.state == "running" {
            Button(cancelingPIDs.contains(job.pid) ? "Canceling…" : "Cancel training") { cancelTraining(job) }
                .disabled(cancelingPIDs.contains(job.pid))
        }
    }

    private var evaluationHistory: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                HStack {
                    Label("Retained training evaluations", systemImage: "doc.text.magnifyingglass")
                        .font(WorkbenchTypography.cardTitle)
                    Spacer()
                    Button("Refresh") { collections.refreshHistory() }
                        .disabled(collections.history.isLoading).accessibilityIdentifier("training-refresh-history")
                }
                collectionFeedback(collections.history, name: "training-history", loading: "Loading training evaluations…",
                    refreshing: "Refreshing training evaluations…", empty: "No retained training evaluations",
                    symbol: "doc.text.magnifyingglass", explanation: "Compare a completed adapter with its base model to retain an evaluation.")
                ForEach(collections.history.items.compactMap(TrainingEvaluationRecord.init)) { record in
                    Divider()
                    Button(record.id) { collections.inspect(record.id) }
                        .disabled(collections.inspectingID != nil)
                    if let created = record.value.object?["created_at"]?.text {
                        Text(created).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    }
                }
                if let inspectingID = collections.inspectingID {
                    HStack(spacing: WorkbenchSpacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Inspecting \(inspectingID)…").font(WorkbenchTypography.secondary)
                            .accessibilityIdentifier("training-inspection-loading")
                    }
                }
                if let error = collections.inspectionError {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                        Text(error).font(WorkbenchTypography.secondary).textSelection(.enabled)
                            .accessibilityIdentifier("training-inspection-error")
                    }.foregroundStyle(WorkbenchColor.failure)
                }
                if let inspection = collections.inspection {
                    Divider()
                    Text("Retained evaluation: \(inspection.recordID)")
                        .font(WorkbenchTypography.emphasis).textSelection(.enabled)
                        .accessibilityIdentifier("training-retained-evaluation")
                    if let report = inspection.response.report {
                        DisclosureGroup("Evaluation outputs and frozen recipe") {
                            ScrollView {
                                Text(report.jsonText).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                            }.frame(maxHeight: WorkbenchSize.Prepare.logMaximumHeight)
                        }
                    }
                    if let hash = inspection.response.artifactSHA256 {
                        Text("SHA-256: " + hash).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func collectionFeedback<Element>(_ state: TrainingCollectionState<Element>, name: String,
        loading: String, refreshing: String, empty: String, symbol: String, explanation: String) -> some View {
        if state.isLoading || state.phase == .loading {
            HStack(spacing: WorkbenchSpacing.xs) {
                ProgressView().controlSize(.small)
                Text(state.hasLoaded ? refreshing : loading).font(WorkbenchTypography.secondary)
                    .accessibilityIdentifier(name + "-loading")
            }
        } else if state.phase == .empty {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                HStack(spacing: WorkbenchSpacing.xs) {
                    Image(systemName: symbol).accessibilityHidden(true)
                    Text(empty).font(WorkbenchTypography.emphasis)
                        .accessibilityIdentifier(name + "-empty")
                }
                Text(explanation).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
        }
        if let error = state.error {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                    Text(error).font(WorkbenchTypography.secondary)
                        .textSelection(.enabled).accessibilityIdentifier(name + "-error")
                }.foregroundStyle(WorkbenchColor.failure)
                Text(state.hasLoaded ? "Showing the last loaded results. Refresh to retry." : "Refresh to retry.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
        }
    }

    private func confirmTraining() {
        guard let task = session.confirmTraining() else { return }
        Task {
            await task.value
            if session.notice != nil { await collections.refresh() }
        }
    }

    private func cancelTraining(_ job: TrainingJob) {
        guard cancelingPIDs.insert(job.pid).inserted else { return }
        cancelError = nil
        Task {
            defer { cancelingPIDs.remove(job.pid) }
            do {
                _ = try await appHost.api.trainingStop(pid: job.pid)
                await collections.refreshJobs()?.value
            } catch { cancelError = "Could not cancel \(job.repo): \(AppHost.render(error))" }
        }
    }

    private func chooseDataset() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let trimmed = session.draft.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { panel.directoryURL = URL(fileURLWithPath: trimmed) }
        if panel.runModal() == .OK, let url = panel.url { session.draft.data = url.path }
    }
}

private struct TrainingEvaluationSheet: View {
    @ObservedObject var lab: LabCoordinator
    let job: TrainingJob
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var preview: LabValue?
    @State private var result: LabResponse?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Evaluate trained adapter").font(WorkbenchTypography.title)
            Text("Use the same prompt, seed, token limit, and sampling settings for the cached base model and this adapter.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            Text(job.repo).font(WorkbenchTypography.cardTitle)
            TextField("Evaluation prompt", text: $prompt, axis: .vertical).lineLimit(3...6)
                .onChange(of: prompt) { preview = nil; result = nil }
            if let error { Text(error).foregroundStyle(WorkbenchColor.failure) }
            if let preview {
                DisclosureGroup("Reviewed evaluation recipe") {
                    ScrollView { Text(preview.jsonText).font(WorkbenchTypography.compactValue).textSelection(.enabled) }.frame(maxHeight: 180)
                }
            }
            if let result, let report = result.report?.object {
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text("Base model").font(WorkbenchTypography.cardTitle)
                        Text(report["outputs"]?.object?["baseline"]?.text ?? "").textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading) {
                        Text("Trained adapter").font(WorkbenchTypography.cardTitle)
                        Text(report["outputs"]?.object?["adapter"]?.text ?? "").textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Retained evaluation SHA-256: " + (result.artifactSHA256 ?? "")).accessibilityIdentifier("training-evaluation-evidence").font(WorkbenchTypography.compactValue).textSelection(.enabled)
                Text("These outputs provide comparison evidence. No quality judgment has been recorded.").font(WorkbenchTypography.metadata)
            }
            HStack {
                Button("Close") { dismiss() }.disabled(busy)
                Spacer()
                Button("Preview") { perform("training-preview") }.disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                Button("Run comparison") { perform("training-evaluate") }
                    .disabled(preview?.object?["preview_hash"]?.text == nil || busy)
            }
        }.padding(WorkbenchSpacing.pageInset).frame(width: 740)
    }
    private func perform(_ operation: String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let response = try await lab.request(LabRequest(operation: operation, receipt: job.receipt,
                    prompt: prompt, maxTokens: 128, previewHash: preview?.object?["preview_hash"]?.text))
                if operation == "training-preview" { preview = response.plan }
                else { result = response }
                error = nil
            } catch { self.error = AppHost.render(error) }
        }
    }
}
