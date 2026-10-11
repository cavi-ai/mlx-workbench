import AppKit
import SwiftUI

// MARK: - TrainingView
// LoRA preview/confirm training on a cached base model.

struct TrainingView: View {
    @ObservedObject var appHost: AppHost

    @State private var repo = ""
    @State private var data = ""
    @State private var itersText = "100"
    @State private var out = ""
    @State private var isPreviewing = false
    @State private var evaluationJob: TrainingJob?
    @State private var jobs: [TrainingJob] = []
    @State private var evaluations: [LabValue] = []
    @State private var retainedEvaluation: LabResponse?
    @State private var isStarting = false
    @State private var preview: [String: Any]?
    @State private var notice: String?
    @State private var errorMessage: String?

    private var previewHash: String? {
        if let h = preview?["preview_hash"] as? String { return h }
        if let plan = preview?["plan"] as? [String: Any], let h = plan["preview_hash"] as? String { return h }
        return nil
    }

    private var iters: Int? {
        Int(itersText.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
                formSection
                if preview != nil {
                    planSection
                }
                trainingJobs
                evaluationHistory
                ErrorBanner(text: errorMessage)
                if let notice {
                    Text(notice).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.success)
                }
                Spacer()
            }
            .padding(WorkbenchSpacing.pageInset)
        }
        .sheet(item: $evaluationJob) { job in TrainingEvaluationSheet(lab: appHost.lab, job: job) }
        .task { await refreshTraining() }
        .onChange(of: repo) { preview = nil }
        .onChange(of: data) { preview = nil }
        .onChange(of: itersText) { preview = nil }
        .onChange(of: out) { preview = nil }
    }

    private var trainingJobs: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                HStack {
                    Text("Training jobs").font(WorkbenchTypography.cardTitle)
                    Spacer()
                    Button("Refresh") { Task { await refreshTraining() } }
                }
                ForEach(jobs) { job in
                    Divider()
                    Text(job.repo + " · " + job.state).font(WorkbenchTypography.cardTitle)
                    Text(job.out).font(WorkbenchTypography.metadata).textSelection(.enabled)
                    if let identity = job.adapterIdentity {
                        Text("Adapter content identity").font(WorkbenchTypography.metadata)
                        Text(identity.jsonText).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                    }
                    HStack {
                        if job.state == "done", job.adapterIdentity != nil {
                            Button("Compare with base") { evaluationJob = job }
                        }
                        if let log = job.logPath {
                            Button("Open log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
                        }
                        if job.state == "running" {
                            Button("Cancel training") {
                                Task {
                                    do { _ = try await appHost.api.trainingStop(pid: job.pid); await refreshTraining() }
                                    catch { errorMessage = AppHost.render(error) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var evaluationHistory: some View {
        WorkbenchSurface {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                Text("Retained training evaluations").font(WorkbenchTypography.cardTitle)
                ForEach(Array(evaluations.enumerated()), id: \.offset) { _, evaluation in
                    if let record = evaluation.object, let identity = record["id"]?.text {
                        Button(identity) {
                            Task {
                                do {
                                    retainedEvaluation = try await appHost.lab.request(
                                        LabRequest(operation: "training-inspect", evaluationID: identity))
                                } catch { errorMessage = AppHost.render(error) }
                            }
                        }
                        Text(record["created_at"]?.text ?? "").font(WorkbenchTypography.metadata)
                    }
                }
                if let retainedEvaluation, let report = retainedEvaluation.report {
                    DisclosureGroup("Evaluation outputs and frozen recipe") {
                        ScrollView {
                            Text(report.jsonText).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                        }.frame(maxHeight: 240)
                    }
                    Text("SHA-256: " + (retainedEvaluation.artifactSHA256 ?? ""))
                        .font(WorkbenchTypography.compactValue).textSelection(.enabled)
                }
            }
        }
    }

    private func refreshTraining() async {
        do {
            jobs = try await appHost.api.trainingStatus().jobs
            evaluations = try await appHost.lab.request(LabRequest(operation: "training-history")).evaluations ?? []
        }
        catch { errorMessage = AppHost.render(error) }
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            SectionTitle(text: "LoRA fine-tune")
            if !cachedRepoIdentities.isEmpty {
                Picker("Cached base model", selection: cachedRepoSelection) {
                    Text("Custom repo id…").tag("")
                    ForEach(cachedRepoIdentities, id: \.self) { identity in
                        Text(identity).tag(identity)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
            HStack {
                TextField("Base model repo id", text: $repo)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: WorkbenchSpacing.xs) {
                TextField("Dataset path", text: $data)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseDataset() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WorkbenchSpacing.xs) { trainingControls }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { trainingControls }
            }
        }
        .formSection {}
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
            get: { cachedRepoIdentities.contains(repo) ? repo : "" },
            set: { if !$0.isEmpty { repo = $0 } }
        )
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack {
                SectionTitle(text: "Training plan")
                Spacer()
                Button("Confirm & Train") { confirmTraining() }
                    .buttonStyle(.borderedProminent)
                    .disabled(previewHash == nil || isStarting)
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                planRow("Base model", repo)
                planRow("Dataset", data)
                planRow("Iterations", itersText)
                if !out.isEmpty {
                    planRow("Output", out)
                }
            }
            if let preview {
                RawJSONDisclosure("Raw plan payload", value: preview)
            }
        }
        .formSection {}
    }

    private func planRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
            Text(label)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(WorkbenchTypography.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var trainingControls: some View {
        TextField("Iterations", text: $itersText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 120)
        TextField("Output (optional)", text: $out)
            .textFieldStyle(.roundedBorder)
            if previewHash == nil {
                Button("Preview Training") { previewTraining() }
                    .buttonStyle(.borderedProminent)
                    .disabled(repo.isEmpty || data.isEmpty || isPreviewing)
            } else {
                Button("Preview Training") { previewTraining() }
                    .buttonStyle(.bordered)
                    .disabled(repo.isEmpty || data.isEmpty || isPreviewing)
            }
    }

    private func chooseDataset() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: trimmed)
        }
        if panel.runModal() == .OK, let url = panel.url {
            data = url.path
        }
    }

    private func previewTraining() {        errorMessage = nil
        notice = nil
        isPreviewing = true
        let r = repo, d = data, i = iters, o = out.isEmpty ? nil : out
        Task {
            defer { isPreviewing = false }
            do {
                preview = try await appHost.api.loraPreview(repo: r, data: d, iters: i, out: o)
            } catch let error as BridgeError {
                preview = nil
                errorMessage = error.errorDescription
            } catch {
                preview = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func confirmTraining() {
        guard let hash = previewHash, !isStarting else { return }
        isStarting = true
        errorMessage = nil
        notice = nil
        let r = repo, d = data, i = iters, o = out.isEmpty ? nil : out
        Task {
            defer { isStarting = false }
            do {
                _ = try await appHost.api.loraStart(repo: r, data: d, previewHash: hash, iters: i, out: o)
                notice = "Training submitted."
                await refreshTraining()
                preview = nil
            } catch let error as BridgeError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
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
