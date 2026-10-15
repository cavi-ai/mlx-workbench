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

// MARK: - TrainingView
// LoRA preview/confirm training on a cached base model.

struct TrainingView: View {
    @ObservedObject var appHost: AppHost
    @StateObject private var session: TrainingSession
    @StateObject private var loader: TrainingLoader
    @State private var evaluationJob: TrainingJob?
    @State private var retainedExpanded = false
    private let seededRetained: TrainingRetainedEvidence?
    @State private var cancelError: String?
    @State private var cancelingPIDs: Set<Int> = []
    @State private var baseChoice = TrainingBaseModelChoice()
    @State private var baseModels: [String] = []
    @FocusState private var focusedField: TrainingField?
    @Environment(\.isRouteActive) private var isRouteActive

    /// `seedRetained` lets a render hold the page with an inspected evaluation open.
    init(
        appHost: AppHost, loader: TrainingLoader? = nil, session: TrainingSession? = nil,
        seedRetained: TrainingRetainedEvidence? = nil
    ) {
        self.appHost = appHost
        seededRetained = seedRetained
        _retainedExpanded = State(initialValue: seedRetained != nil)
        _loader = StateObject(wrappedValue: loader ?? TrainingLoader(
            jobs: { try await appHost.api.trainingStatus().jobs },
            history: { try await appHost.lab.request(LabRequest(operation: "training-history")).evaluations ?? [] },
            inspect: { try await appHost.lab.request(LabRequest(operation: "training-inspect", evaluationID: $0)) }
        ))
        _session = StateObject(wrappedValue: session ?? TrainingSession(
            preview: { request in
                try await appHost.api.loraPreview(repo: request.repo, data: request.data, iters: request.iterations, out: request.output)
            },
            start: { request, hash in
                _ = try await appHost.api.loraStart(repo: request.repo, data: request.data, previewHash: hash, iters: request.iterations, out: request.output)
            }
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
        .onChange(of: appHost.librarySnapshot?.generatedAt, initial: true) {
            baseModels = TrainingPresentation.baseModels(appHost.librarySnapshot)
        }
        .task(id: isRouteActive) {
            guard isRouteActive else { return }
            await loader.refreshIfIdle()
        }
    }

    private var guidance: TrainingPreviewGuidance? {
        TrainingPreviewGuidance.resolve(draft: session.draft, operation: session.operation)
    }

    private var showsCustomRepoField: Bool { baseChoice.showsField(cached: baseModels) }

    private func formSection(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            SectionTitle(text: "LoRA fine-tune")
            requestSignature(repo: session.draft.repo, data: session.draft.data, output: session.draft.output)
            Divider()
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                if !baseModels.isEmpty {
                    Picker("Base model", selection: cachedRepoSelection) {
                        Text("Custom repo id…").tag("")
                        ForEach(baseModels, id: \.self) { identity in Text(identity).tag(identity) }
                    }.frame(maxWidth: WorkbenchSize.Training.baseModelMenuWidth, alignment: .leading)
                }
                if showsCustomRepoField {
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                        fieldLabel("Base model repo id")
                        TextField("Base model repo id", text: $session.draft.repo)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Base model repo id")
                            .focused($focusedField, equals: .repo)
                    }.id(TrainingField.repo)
                }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    fieldLabel("Dataset path")
                    HStack(spacing: WorkbenchSpacing.xs) {
                        TextField("Dataset path", text: $session.draft.data)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Dataset path")
                            .focused($focusedField, equals: .data)
                        Button("Choose…") { chooseDataset() }.buttonStyle(.bordered).controlSize(.small)
                    }
                }.id(TrainingField.data)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.md) { trainingFields }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) { trainingFields }
                }
            }.disabled(session.isBusy)
            previewActions(proxy)
            if session.preview == nil { operationFeedback }
        }.formSection {}
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

    private var cachedRepoSelection: Binding<String> {
        Binding(
            get: { baseChoice.selection(repo: session.draft.repo, cached: baseModels) },
            set: { session.draft.repo = baseChoice.select($0) }
        )
    }

    @ViewBuilder
    private var trainingFields: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            fieldLabel("Iterations")
            TextField("Iterations", text: $session.draft.iterations)
                .textFieldStyle(.roundedBorder)
                .frame(width: WorkbenchSize.Training.iterationsWidth)
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
        if field == .repo { baseChoice = TrainingBaseModelChoice() }
        // Custom selection may first need to reveal the field in the layout.
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(field, anchor: .center) }
            DispatchQueue.main.async { focusedField = field }
        }
    }

    @ViewBuilder
    private var previewButton: some View {
        if session.preview == nil {
            previewControl.buttonStyle(.workbenchPrimary)
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
                    .buttonStyle(.workbenchPrimary)
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

    private var presentation: TrainingPresentation {
        TrainingPresentation.make(
            jobs: loader.jobs, evaluations: loader.evaluations,
            jobsError: loader.jobsError, historyError: loader.historyError,
            jobsLoading: loader.isLoadingJobs, historyLoading: loader.isLoadingHistory,
            jobsLoaded: loader.hasLoadedJobs, historyLoaded: loader.hasLoadedHistory
        )
    }

    private var trainingJobs: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            TrainingJobsCard(
                presentation: presentation, pulses: isRouteActive,
                refresh: { loader.refreshJobs() },
                actions: TrainingJobActions(
                    compare: { row in evaluationJob = loader.jobs.first { $0.id == row.id } },
                    openLog: { NSWorkspace.shared.open(URL(fileURLWithPath: $0)) },
                    cancel: { cancelTraining($0) }, cancelingPIDs: cancelingPIDs
                )
            )
            if let cancelError {
                ErrorBanner(text: cancelError).accessibilityIdentifier("training-cancel-error")
            }
        }
    }

    private var retained: TrainingRetainedEvidence? {
        guard let inspection = loader.inspection, let report = inspection.response.report else { return seededRetained }
        return TrainingRetainedEvidence(evaluationID: inspection.recordID, reportText: report.jsonText,
            sha256: inspection.response.artifactSHA256 ?? "")
    }

    private var evaluationHistory: some View {
        TrainingEvaluationsCard(
            presentation: presentation, retained: retained, inspectingID: loader.inspectingID,
            retainedExpanded: $retainedExpanded, inspect: { identity in
                guard let task = loader.inspect(identity) else { return }
                Task {
                    await task.value
                    if loader.inspectionError == nil, loader.inspection?.recordID == identity { retainedExpanded = true }
                }
            }, refresh: { loader.refreshHistory() }, inspectionError: loader.inspectionError
        )
    }

    private func confirmTraining() {
        guard let task = session.confirmTraining() else { return }
        Task {
            await task.value
            if session.notice != nil { await loader.refreshIfIdle() }
        }
    }

    private func cancelTraining(_ row: TrainingJobRow) {
        guard cancelingPIDs.insert(row.pid).inserted else { return }
        cancelError = nil
        Task {
            defer { cancelingPIDs.remove(row.pid) }
            do {
                _ = try await appHost.api.trainingStop(pid: row.pid)
                await loader.refreshJobs()?.value
            } catch { cancelError = "Could not cancel \(row.repo): \(AppHost.render(error))" }
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
                TrainingRawDisclosure(
                    title: "Reviewed evaluation recipe", text: preview.jsonText, maxHeight: WorkbenchSize.Training.recipeMaxHeight
                )
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
