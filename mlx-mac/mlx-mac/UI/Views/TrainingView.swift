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
            }
            .frame(maxWidth: WorkbenchSize.contentMaxWidth, alignment: .leading)
            .padding(WorkbenchSpacing.pageInset)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                SectionTitle(text: "LoRA fine-tune")
                Text("Choose a base model and dataset, then preview the training request.")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
            if !cachedRepoIdentities.isEmpty {
                Picker("Cached base model", selection: cachedRepoSelection) {
                    Text("Custom repo id…").tag("")
                    ForEach(cachedRepoIdentities, id: \.self) { identity in
                        Text(identity).tag(identity)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Text("Base model repo id").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
                TextField("Base model repo id", text: $session.draft.repo)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Base model repo id")
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

    /// Hugging Face repo ids for models already in the local cache, so the
    /// base model can be picked instead of typed.
    private var cachedRepoIdentities: [String] {
        let models = appHost.librarySnapshot?.models ?? []
        var identities: Set<String> = []
        for model in models {
            for path in [model.item.path] + model.outputPaths {
                if let repoID = HFRepoID.forPath(path) {
                    identities.insert(repoID)
                }
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
                    Button(session.operation == .submitting ? "Submitting…" : "Confirm & Train") { session.confirmTraining() }
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
                .frame(width: 120)
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
