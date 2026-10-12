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

// MARK: - TrainingView
// LoRA preview/confirm training on a cached base model.

struct TrainingView: View {
    @ObservedObject var appHost: AppHost
    @StateObject private var session: TrainingSession
    @StateObject private var loader: TrainingLoader
    @State private var evaluationJob: TrainingJob?
    @State private var retained: TrainingRetainedEvidence?
    @State private var retainedExpanded = false
    @State private var inspectingID: String?
    @State private var actionError: String?
    @State private var baseChoice = TrainingBaseModelChoice()
    @State private var baseModels: [String] = []
    @Environment(\.isRouteActive) private var isRouteActive

    /// `seedRetained` lets a render hold the page with an inspected evaluation open.
    init(
        appHost: AppHost, loader: TrainingLoader? = nil, session: TrainingSession? = nil,
        seedRetained: TrainingRetainedEvidence? = nil
    ) {
        self.appHost = appHost
        _retained = State(initialValue: seedRetained)
        _retainedExpanded = State(initialValue: seedRetained != nil)
        _loader = StateObject(wrappedValue: loader ?? TrainingLoader(
            jobs: { try await appHost.api.trainingStatus().jobs },
            history: { try await appHost.lab.request(LabRequest(operation: "training-history")).evaluations ?? [] }
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
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                formSection
                if let preview = session.preview {
                    planSection(preview)
                }
                ErrorBanner(text: session.errorMessage)
                if let notice = session.notice {
                    Text(notice).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.success)
                }
                ErrorBanner(text: actionError)
                trainingJobs
                evaluationHistory
            }
            .frame(maxWidth: WorkbenchSize.contentMaxWidth, alignment: .leading)
            .padding(WorkbenchSpacing.pageInset)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .sheet(item: $evaluationJob) { job in TrainingEvaluationSheet(lab: appHost.lab, job: job) }
        .onChange(of: appHost.librarySnapshot?.generatedAt, initial: true) {
            baseModels = TrainingPresentation.baseModels(appHost.librarySnapshot)
        }
        .task(id: isRouteActive) {
            guard isRouteActive else { return }
            await loader.refresh()
        }
    }

    private var presentation: TrainingPresentation {
        TrainingPresentation.make(
            jobs: loader.jobs, evaluations: loader.evaluations,
            jobsError: loader.jobsError, historyError: loader.historyError
        )
    }

    private var trainingJobs: some View {
        TrainingJobsCard(
            presentation: presentation, pulses: isRouteActive,
            refresh: { Task { await loader.refresh() } },
            actions: TrainingJobActions(
                compare: { row in evaluationJob = loader.jobs.first { $0.id == row.id } },
                openLog: { NSWorkspace.shared.open(URL(fileURLWithPath: $0)) },
                cancel: { row in
                    Task {
                        do {
                            _ = try await appHost.api.trainingStop(pid: row.pid)
                            actionError = nil
                            await loader.refresh()
                        } catch { actionError = AppHost.render(error) }
                    }
                }
            )
        )
    }

    private var evaluationHistory: some View {
        TrainingEvaluationsCard(
            presentation: presentation,
            retained: retained,
            inspectingID: inspectingID,
            retainedExpanded: $retainedExpanded,
            inspect: { identity in
                guard inspectingID == nil else { return }
                inspectingID = identity
                Task {
                    defer { inspectingID = nil }
                    do {
                        let response = try await appHost.lab.request(
                            LabRequest(operation: "training-inspect", evaluationID: identity))
                        actionError = nil
                        if let report = response.report {
                            retained = TrainingRetainedEvidence(
                                evaluationID: identity, reportText: report.jsonText, sha256: response.artifactSHA256 ?? "")
                            retainedExpanded = true
                        }
                    } catch { actionError = AppHost.render(error) }
                }
            }
        )
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                SectionTitle(text: "LoRA fine-tune")
                Text("Choose a base model and dataset, then preview the training request.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            if !baseModels.isEmpty {
                Picker("Base model", selection: cachedRepoSelection) {
                    Text("Custom repo id…").tag("")
                    ForEach(baseModels, id: \.self) { identity in
                        Text(identity).tag(identity)
                    }
                }
                .frame(maxWidth: WorkbenchSize.Training.baseModelMenuWidth, alignment: .leading)
            }
            if showsCustomRepoField {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text("Base model repo id").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
                    TextField("Base model repo id", text: $session.draft.repo)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Base model repo id")
                }
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Text("Dataset path").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
                HStack(spacing: WorkbenchSpacing.xs) {
                    TextField("Dataset path", text: $session.draft.data)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Dataset path")
                    Button("Choose…") { chooseDataset() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: WorkbenchSpacing.md) { trainingFields }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) { trainingFields }
            }
            previewActions
        }
        .formSection {}
        .disabled(session.isBusy)
    }

    private var cachedRepoSelection: Binding<String> {
        Binding(
            get: { baseChoice.selection(repo: session.draft.repo, cached: baseModels) },
            set: { session.draft.repo = baseChoice.select($0) }
        )
    }

    /// The field is the only way in when the Library has no repo ids; with
    /// some, it shows until a cached model is picked and stays while typing.
    private var showsCustomRepoField: Bool {
        baseChoice.showsField(cached: baseModels)
    }

    private func planSection(_ preview: TrainingPreview) -> some View {
        WorkbenchSurface(.tinted) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    SectionTitle(text: "Training plan")
                    Text("Captured from your preview. Editing the setup requires a new preview.")
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.muted)
                }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    planRow("Base model", preview.request.repo)
                    planRow("Dataset", preview.request.data, identifier: true)
                    planRow("Iterations", String(preview.request.iterations))
                    if let output = preview.request.output {
                        planRow("Output", output, identifier: true)
                    }
                }
                HStack {
                    Spacer(minLength: 0)
                    Button(session.operation == .submitting ? "Submitting…" : "Confirm & Train") { confirmTraining() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!session.canConfirm)
                        .help("Submit the captured training request shown above.")
                }
                Divider()
                RawJSONDisclosure("Raw plan payload", value: preview.payload)
            }
        }
    }

    private func planRow(_ label: String, _ value: String, identifier: Bool = false) -> some View {
        LabeledContent {
            Text(value)
                .font(identifier ? WorkbenchTypography.value : WorkbenchTypography.body)
                .foregroundStyle(WorkbenchColor.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(label)
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.muted)
        }
    }

    @ViewBuilder
    private var trainingFields: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text("Iterations").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
            TextField("Iterations", text: $session.draft.iterations)
                .textFieldStyle(.roundedBorder)
                .frame(width: WorkbenchSize.Training.iterationsWidth)
                .accessibilityLabel("Iterations")
            if let error = session.draft.iterationsError {
                Text(error)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text("Output (optional)").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
            TextField("Output (optional)", text: $session.draft.output)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Output directory")
        }
    }

    private var previewActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: WorkbenchSpacing.sm) {
                trainingProgress
                Spacer(minLength: 0)
                previewButton
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                trainingProgress
                HStack {
                    Spacer(minLength: 0)
                    previewButton
                }
            }
        }
    }

    @ViewBuilder
    private var trainingProgress: some View {
        if session.isBusy {
            ProgressView(session.operation == .previewing ? "Preparing training preview…" : "Submitting training…")
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var previewButton: some View {
        if session.preview == nil {
            Button(session.operation == .previewing ? "Previewing…" : "Preview Training") { session.previewTraining() }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canPreview)
        } else {
            Button("Preview Training") { session.previewTraining() }
                .buttonStyle(.bordered)
                .disabled(!session.canPreview)
        }
    }

    private func confirmTraining() {
        guard let task = session.confirmTraining() else { return }
        Task {
            await task.value
            await loader.refresh()
        }
    }

    private func chooseDataset() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let trimmed = session.draft.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: trimmed)
        }
        if panel.runModal() == .OK, let url = panel.url {
            session.draft.data = url.path
        }
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
