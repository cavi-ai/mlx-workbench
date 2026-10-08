import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkflowCaptureRequestView: View {
    let models: [WorkflowCaptureModel]
    let initialModelPath: String?
    let environment: String?
    var endpoint: WorkflowCaptureEndpoint? = nil
    var initialHarness: WorkflowHarness = .openCode
    var onImport: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var harness: WorkflowHarness = .openCode
    @State private var selectedPath = ""
    @State private var note: String?
    @State private var error: String?

    private var selectedModel: WorkflowCaptureModel? { models.first { $0.path == selectedPath } }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Label("Capture a workflow", systemImage: "arrow.down.doc").font(WorkbenchTypography.title)
            Text("Copy the request, run your task, then review its measured report.").font(WorkbenchTypography.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let endpoint {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Label("Wired endpoint", systemImage: "network").font(WorkbenchTypography.emphasis)
                    Text(endpoint.baseURL).font(WorkbenchTypography.value).textSelection(.enabled)
                    Text("Clients: \(endpoint.clientIDs.joined(separator: ", ")) · verify the task uses this endpoint")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
            }
            Picker("Harness", selection: $harness) {
                ForEach(WorkflowHarness.allCases) { Text($0.title).tag($0) }
            }
            Picker("Local model", selection: $selectedPath) {
                Text("Choose a model").tag("")
                ForEach(models) { Text($0.name).tag($0.path) }
            }
            .disabled(endpoint != nil)
            if let selectedModel {
                Text(selectedModel.path).font(WorkbenchTypography.value).textSelection(.enabled)
            }
            Text("Includes model and environment identities. Establish missing fields from the run; preserve historical identities and dates.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            if models.isEmpty { Text("No ready local models available. Rescan Library first.").font(WorkbenchTypography.secondary) }
            if selectedModel?.signature == nil || !ComparisonInsights.knownEnvironment(environment) {
                Text("Some identity context is unavailable. Imported observations stay unconfirmed until Library and this Mac can match them.").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
            }
            if let note { Text(note).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.success) }
            ErrorBanner(text: error)
            if let onImport {
                Button("Review report in Compare…", action: onImport).buttonStyle(.bordered)
            }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save request…") { makeRequest(saveRequest) }.disabled(selectedModel == nil)
                Button("Copy request") { makeRequest { request in
                    let text = String(decoding: try WorkflowEvidenceStore.encode(request), as: UTF8.self)
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setString(text, forType: .string) else { throw WorkflowEvidenceError.invalid("could not copy capture request") }
                    note = "Request copied. Ask the agent to fill reportDraft and save that object as JSON."
                } }.buttonStyle(.borderedProminent).disabled(selectedModel == nil)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 520)
        .onAppear {
            selectedPath = models.contains(where: { $0.path == initialModelPath }) ? (initialModelPath ?? "") : (models.first?.path ?? "")
            harness = initialHarness
        }
    }

    private func makeRequest(_ consume: (WorkflowCaptureRequest) throws -> Void) {
        guard let selectedModel else { return }
        do {
            try consume(WorkflowCaptureRequest.make(harness: harness, model: selectedModel, environment: environment, endpoint: endpoint))
            error = nil
        } catch { self.error = AppHost.render(error) }
    }

    private func saveRequest(_ request: WorkflowCaptureRequest) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "workflow-capture-request.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try JSONStore<WorkflowEvidence>.refuseSymlink(url, fileManager: .default)
                try WorkflowEvidenceStore.encode(request).write(to: url, options: .atomic)
                note = "Saved \(url.lastPathComponent). Ask the agent to fill reportDraft and save that object as JSON."
                self.error = nil
            } catch { self.error = AppHost.render(error) }
        }
    }
}

struct WorkflowImportPreviewView: View {
    let preview: WorkflowImportPreview
    let models: [WorkflowCaptureModel]
    let environment: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Label("Review workflow report", systemImage: "doc.text.magnifyingglass").font(WorkbenchTypography.title)
            Text("\(preview.newRecords.count) new · \(preview.duplicateCount) already imported").font(WorkbenchTypography.value)
            Text("Historical or unmatched observations can be saved for reference. They cannot establish current model replacement advice. Import preserves all recorded identities, sources and timestamps.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            if preview.report.records.isEmpty { Text("No measurements in this report. Ask your agent to fill the capture request first.").font(WorkbenchTypography.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    ForEach(preview.report.records) { record in
                        WorkbenchSurface(padding: WorkbenchSpacing.sm) {
                            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                                HStack {
                                    Text("\(record.harness) · \(record.workloadID)").font(WorkbenchTypography.emphasis)
                                    Spacer()
                                    Text(preview.newRecords.contains(where: { $0.id == record.id }) ? "New" : "Already imported").font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
                                }
                                Text(models.first(where: { $0.path == record.modelPath })?.name ?? URL(fileURLWithPath: record.modelPath).lastPathComponent).font(WorkbenchTypography.emphasis)
                                let status = WorkflowImportIdentity.status(record, models: models, environment: environment)
                                Text(status.label).font(WorkbenchTypography.label).foregroundStyle(status == .matching ? WorkbenchColor.success : WorkbenchColor.warning)
                                Text("\(record.sampleCount) samples · \(String(format: "%.2f", record.totalSeconds)) s total · \(record.measuredAt.formatted())").font(WorkbenchTypography.secondary)
                                Text("Inference \(seconds(record.inferenceSeconds)) · tools \(seconds(record.toolSeconds)) · queue \(seconds(record.queueSeconds))").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                                if record.configurationFingerprint == nil { Text("Configuration identity missing · no replacement advice").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted) }
                                DisclosureGroup("Recorded source and identity") {
                                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                                        Text("Source: \(record.source)")
                                        Text("Model: \(record.modelPath)")
                                        Text("Signature: \(record.modelSignature)")
                                        Text("Environment: \(record.environmentFingerprint)")
                                    }.font(WorkbenchTypography.value).textSelection(.enabled)
                                }.font(WorkbenchTypography.secondary)
                            }
                        }
                    }
                }
            }.frame(maxHeight: 360)
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import \(preview.newRecords.count) records", action: onConfirm).buttonStyle(.borderedProminent).disabled(preview.newRecords.isEmpty)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 600)
    }

    private func seconds(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0) } ?? "unknown" }
}

struct AgentModelGuidanceView: View {
    let evidence: AgentEvidenceExport
    let onReview: (String, String) async throws -> ModelGuidanceReview
    let onApply: (ModelGuidanceReview, UseCase, Bool) async throws -> String
    let onWire: (String) -> Void
    let onSave: (AgentEvidenceExport) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note: String?
    @State private var error: String?
    @State private var review: ModelGuidanceReview?
    @State private var isPreparing = false
    @State private var appliedModelPath: String?

    var body: some View {
        if let review {
            ModelGuidanceReviewView(review: review, onApply: onApply, onBack: { self.review = nil }, onApplied: {
                note = $0; appliedModelPath = review.candidate.modelPath; error = nil; self.review = nil
            })
        } else {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Label("Model guidance for your agent", systemImage: "list.bullet.clipboard").font(WorkbenchTypography.title)
            Text("Task-specific choices from local evidence. Quality, speed and fit stay separate. Use model reviews a role preference and an optional endpoint switch.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            Text("\(evidence.contextTokens) tokens · headroom captured \(evidence.memoryCapturedAt?.formatted() ?? "unknown")")
                .font(WorkbenchTypography.value)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    if (evidence.taskGuidance ?? []).isEmpty {
                        Text("No measured task cohorts yet. Run a comparison or import workflow reports to establish choices.").font(WorkbenchTypography.secondary)
                    }
                    ForEach(evidence.taskGuidance ?? []) { task in
                        WorkbenchSurface(padding: WorkbenchSpacing.sm) {
                            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                                Text(task.title).font(WorkbenchTypography.emphasis)
                                Text("\(task.harness ?? task.mode ?? task.source) · \(task.measuredAt.formatted())")
                                    .font(WorkbenchTypography.label).foregroundStyle(WorkbenchColor.muted)
                                Text("Quality first among estimated fits: \(names(task.qualityFirstFitPaths))").font(WorkbenchTypography.emphasis)
                                Text("Best reviewed outcome: \(names(task.qualityLeaders))")
                                Text("Best measured \(metricTitle(task.performanceMetric)): \(names(task.performanceLeaders))")
                                if !task.latencyLeaders.isEmpty { Text("Lowest first-token latency: \(names(task.latencyLeaders))") }
                                ForEach(choices(task)) { candidate in
                                    HStack {
                                        Text(candidate.name).font(WorkbenchTypography.label).lineLimit(1)
                                        Spacer()
                                        Button("Use model…") { prepare(taskID: task.id, path: candidate.modelPath) }
                                            .disabled(isPreparing)
                                    }
                                }
                                ForEach(task.needsEvidence, id: \.self) { Text($0).foregroundStyle(WorkbenchColor.warning) }
                                DisclosureGroup("Models and evidence") {
                                    ForEach(task.candidates) { candidate in
                                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                                            Text(candidate.name).font(WorkbenchTypography.emphasis)
                                            Text(candidate.fitSummary)
                                            Text("Disk: \(candidate.diskBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown")")
                                            ForEach(candidate.exclusionReasons, id: \.self) { Text($0).foregroundStyle(WorkbenchColor.warning) }
                                            Text("Evidence: \(candidate.evidenceID)").font(WorkbenchTypography.value).textSelection(.enabled)
                                        }.padding(.vertical, WorkbenchSpacing.xxs)
                                    }
                                    if !task.unmeasuredModelPaths.isEmpty { Text("\(task.unmeasuredModelPaths.count) ready models have no observation in this cohort.").foregroundStyle(WorkbenchColor.muted) }
                                }
                            }.font(WorkbenchTypography.secondary)
                        }
                    }
                }
            }.frame(maxHeight: 420)
            Text("Fit is an estimate at captured headroom; recheck before serving. GPU, disk and network bottlenecks are unmeasured. Reclaim suggestions still require their own review.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            if let note { Text(note).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.success) }
            if let appliedModelPath {
                Button("Wire into clients…") { onWire(appliedModelPath) }
                    .font(WorkbenchTypography.label)
            }
            ErrorBanner(text: error)
            if isPreparing { ProgressView("Checking model, evidence and headroom…").font(WorkbenchTypography.secondary) }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save JSON…") { onSave(evidence) }
                Button("Copy for agent") {
                    do {
                        let text = String(decoding: try WorkflowEvidenceStore.encode(evidence), as: UTF8.self)
                        NSPasteboard.general.clearContents()
                        guard NSPasteboard.general.setString(text, forType: .string) else { throw WorkflowEvidenceError.invalid("could not copy guidance") }
                        note = "Copied task guidance and its source evidence."; error = nil
                    } catch { self.error = AppHost.render(error) }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 640).disabled(isPreparing)
            .interactiveDismissDisabled(isPreparing)
        }
    }

    private func choices(_ task: AgentTaskGuidance) -> [AgentTaskCandidate] {
        let leaders = Set(task.qualityFirstFitPaths + task.qualityLeaders + task.performanceLeaders + task.latencyLeaders)
        return task.candidates.filter { candidate in
            candidate.comparable && leaders.contains(candidate.modelPath) &&
                evidence.models.contains { $0.path == candidate.modelPath && !$0.tasks.isEmpty }
        }
    }

    private func prepare(taskID: String, path: String) {
        isPreparing = true; error = nil
        Task { @MainActor in
            defer { isPreparing = false }
            do { review = try await onReview(taskID, path) }
            catch { self.error = AppHost.render(error) }
        }
    }

    private func names(_ paths: [String]) -> String {
        paths.isEmpty ? "Needs evidence" : paths.map { path in evidence.models.first { $0.path == path }?.name ?? path }.joined(separator: ", ")
    }
    private func metricTitle(_ raw: String) -> String {
        raw == "totalSeconds" ? "workflow duration (same sample count)" : (ComparisonMetric(rawValue: raw)?.title ?? raw)
    }
}

struct ModelGuidanceReviewView: View {
    let review: ModelGuidanceReview
    let onApply: (ModelGuidanceReview, UseCase, Bool) async throws -> String
    let onBack: () -> Void
    let onApplied: (String) -> Void
    @State private var role: UseCase
    @State private var enableEndpoint = false
    @State private var isApplying = false
    @State private var error: String?

    init(review: ModelGuidanceReview, onApply: @escaping (ModelGuidanceReview, UseCase, Bool) async throws -> String,
         onBack: @escaping () -> Void, onApplied: @escaping (String) -> Void) {
        self.review = review; self.onApply = onApply; self.onBack = onBack; self.onApplied = onApplied
        let taskRole = review.evidence.taskGuidance?.first { $0.id == review.taskID }?.useCase
        _role = State(initialValue: taskRole.flatMap { review.roles.contains($0) ? $0 : nil } ?? review.roles.first ?? .generalChat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Label("Use \(review.candidate.name)", systemImage: "star.circle.fill").font(WorkbenchTypography.title)
            Text(review.candidate.modelPath).font(WorkbenchTypography.compactValue).foregroundStyle(WorkbenchColor.muted).textSelection(.enabled)
            Picker("Preferred role", selection: $role) {
                ForEach(review.roles) { Text($0.title).tag($0) }
            }
            Text("This saves a role preference across workflows. Client wiring and reclaim have separate reviews.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            WorkbenchSurface(.tinted, padding: WorkbenchSpacing.sm) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    Label(review.candidate.fitSummary, systemImage: "memorychip").font(WorkbenchTypography.emphasis)
                    Text("Estimate at \(review.evidence.contextTokens) tokens · \(review.evidence.reserveGB.formatted()) GB reserve")
                        .font(WorkbenchTypography.secondary)
                    Text("Headroom checked \(review.evidence.memoryCapturedAt?.formatted() ?? "unknown"). Context here is an estimate, not an endpoint setting.")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
            }
            Toggle("Also use on the always-on endpoint", isOn: $enableEndpoint)
                .font(WorkbenchTypography.emphasis).disabled(!review.verified || review.candidate.fitStatus != "fits")
            Text(review.endpoint.enabled
                ? "Replace \(URL(fileURLWithPath: review.endpoint.modelPath).lastPathComponent) on port \(review.endpoint.port)."
                : "Enable on loopback port \(review.endpoint.port).")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            if !review.verified || review.candidate.fitStatus != "fits" {
                Text(!review.verified ? "Endpoint requires a verified model. You can save the preference now." : "Endpoint requires an estimated fit at current headroom. You can save the preference now.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
            }
            ErrorBanner(text: error)
            HStack {
                Button("Back", action: onBack).keyboardShortcut(.cancelAction)
                Spacer()
                Button(isApplying ? "Checking and applying…" : "Use model") { apply() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 560).disabled(isApplying)
            .interactiveDismissDisabled(isApplying)
    }

    private func apply() {
        isApplying = true; error = nil
        Task { @MainActor in
            defer { isApplying = false }
            do { onApplied(try await onApply(review, role, enableEndpoint)) }
            catch { self.error = AppHost.render(error) }
        }
    }
}
