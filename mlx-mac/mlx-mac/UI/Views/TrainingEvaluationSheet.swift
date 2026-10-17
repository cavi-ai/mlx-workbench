import SwiftUI

struct TrainingEvaluationReviewContext: Identifiable {
    let id: String
    let response: LabResponse
}

struct TrainingEvaluationSheet: View {
    let baseTitle: String
    let promptSets: [PromptSet]
    let managePromptSets: (() -> Void)?
    @StateObject private var session: TrainingEvaluationSession
    @State private var confirmsDiscard = false
    @Environment(\.dismiss) private var dismiss

    init(lab: LabCoordinator, job: TrainingJob, session: TrainingEvaluationSession? = nil,
         promptSets: [PromptSet] = [], managePromptSets: (() -> Void)? = nil) {
        baseTitle = job.repo; self.promptSets = promptSets; self.managePromptSets = managePromptSets
        _session = StateObject(wrappedValue: session ?? TrainingEvaluationSession(receipt: job.receipt) {
            try await lab.request($0)
        })
    }

    init(lab: LabCoordinator, retained: LabResponse) {
        baseTitle = retained.report?.object?["base_repo"]?.text ?? "Recorded base model"
        promptSets = []; managePromptSets = nil
        _session = StateObject(wrappedValue: TrainingEvaluationSession(receipt: "", retained: retained) { try await lab.request($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text(session.isRetainedOnly ? "Review retained evaluation" : "Evaluate trained adapter").font(WorkbenchTypography.title)
            Text(baseTitle).font(WorkbenchTypography.cardTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    if !session.isRetainedOnly { setup }
                    if let error = session.errorMessage { Text(error).foregroundStyle(WorkbenchColor.failure) }
                    if let preview = session.preview {
                        TrainingRawDisclosure(title: "Reviewed evaluation recipe", text: preview.plan.jsonText,
                                              maxHeight: WorkbenchSize.Training.recipeMaxHeight)
                    }
                    if let sample = session.selectedSample {
                        results(sample)
                        review(sample)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Close") {
                    if session.hasUnsavedReviews { confirmsDiscard = true } else { dismiss() }
                }.disabled(session.isBusy).buttonStyle(.bordered).controlSize(.small).keyboardShortcut(.cancelAction)
                Spacer()
                if !session.isRetainedOnly {
                    Button(session.operation == .previewing ? "Previewing…" : "Preview") { session.previewEvaluation() }
                        .disabled(!session.canPreview).buttonStyle(.bordered).controlSize(.small)
                    Button(session.operation == .evaluating ? "Running comparison…" : "Run comparison") { session.evaluate() }
                        .disabled(!session.canEvaluate).buttonStyle(.workbenchPrimary).controlSize(.small)
                }
            }
        }
        .padding(WorkbenchSpacing.pageInset)
        .frame(minWidth: 600, idealWidth: 800, maxWidth: 900, minHeight: 440, idealHeight: 680, maxHeight: 800)
        .interactiveDismissDisabled(session.isBusy || session.hasUnsavedReviews)
        .confirmationDialog("Discard unsaved review changes?", isPresented: $confirmsDiscard) {
            Button("Discard changes", role: .destructive) { dismiss() }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Choose evaluation prompts kept separate from training data. Both variants use the same recorded prompts, token limits, seed and sampling settings.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            Menu {
                Button("Single prompt") { session.useSinglePrompt() }
                ForEach(promptSets.filter { $0.effectiveMode == .chat }) { set in
                    Button(set.name) { session.selectSuite(set) }
                        .disabled(TrainingEvaluationSuite.unavailableReason(set) != nil)
                        .help(TrainingEvaluationSuite.unavailableReason(set) ?? "Snapshot the prompt text and token limits.")
                }
            } label: { Text(session.suite?.name ?? "Single prompt") }
                .accessibilityIdentifier("training-evaluation-source").disabled(!session.canChangeSetup)
            if let suite = session.suite {
                Text("\(suite.prompts.count) prompts captured; later prompt-set edits do not change this evaluation.")
                    .font(WorkbenchTypography.metadata)
            } else {
                TextField("Evaluation prompt", text: $session.prompt, axis: .vertical).lineLimit(3...6)
                    .disabled(!session.canChangeSetup)
                HStack {
                    Text("Token limit").font(WorkbenchTypography.label)
                    TextField("Token limit", text: $session.maxTokens).frame(width: 90).disabled(!session.canChangeSetup)
                }
                if let reason = session.inputValidation { Text(reason).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted) }
            }
            Text("Text-only sets support up to 16 prompts and 512 tokens per prompt. Tools, media and expected-word scoring are excluded.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            if let managePromptSets {
                Button("Manage prompt sets in Compare") { dismiss(); managePromptSets() }
                    .disabled(!session.canChangeSetup).buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private func results(_ sample: TrainingEvaluationSample) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Evaluation retained").font(WorkbenchTypography.emphasis).accessibilityIdentifier("training-evaluation-retained")
            Picker("Prompt", selection: $session.selectedPromptID) {
                ForEach(Array(session.samples.enumerated()), id: \.element.id) { index, item in
                    Text("\(index + 1). \(item.prompt.prefix(60))").tag(item.id)
                }
            }.accessibilityIdentifier("training-evaluation-prompt-picker").disabled(session.isBusy)
            Text(sample.prompt).textSelection(.enabled)
            Text("Token limit: \(sample.maxTokens)").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                    output("Base model", sample.baseline); output("Trained adapter", sample.adapter)
                }
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    output("Base model", sample.baseline); output("Trained adapter", sample.adapter)
                }
            }
            Text("Retained evaluation SHA-256: " + (session.result?.artifactSHA256 ?? ""))
                .accessibilityIdentifier("training-evaluation-evidence").font(WorkbenchTypography.compactValue).textSelection(.enabled)
        }
    }

    private func output(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text(title).font(WorkbenchTypography.cardTitle)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(minWidth: 230, maxWidth: .infinity, alignment: .leading)
    }

    private func review(_ sample: TrainingEvaluationSample) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Divider()
            Text("\(session.reviews.count) of \(session.samples.count) prompts reviewed").font(WorkbenchTypography.emphasis)
            Text("Which output better meets this prompt? Reviews record your preference; they do not mark the adapter verified.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            Picker("Preference", selection: Binding(get: { session.draft(sample.id).preference }, set: { value in
                var draft = session.draft(sample.id); draft.preference = value; session.updateReview(sample.id, draft)
            })) {
                Text("Choose a preference").tag("")
                ForEach(TrainingEvaluationReview.preferences, id: \.self) { Text(TrainingEvaluationReview.title($0)).tag($0) }
            }.disabled(session.isBusy).accessibilityIdentifier("training-evaluation-preference")
            TextField("Review notes (optional)", text: Binding(get: { session.draft(sample.id).notes }, set: { value in
                var draft = session.draft(sample.id); draft.notes = value; session.updateReview(sample.id, draft)
            }), axis: .vertical).lineLimit(2...4).disabled(session.isBusy).accessibilityIdentifier("training-evaluation-review-notes")
            if let error = session.reviewError { Text(error).foregroundStyle(WorkbenchColor.failure) }
            if let notice = session.reviewNotice { Text(notice).accessibilityIdentifier("training-evaluation-review-saved") }
            Button(session.operation == .savingReview ? "Saving review…" : "Save review") { session.saveReview() }
                .disabled(!session.canSaveReview).buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("training-evaluation-save-review")
                .help(session.reviewValidation ?? "Record this preference for the retained prompt outputs.")
        }
    }
}
