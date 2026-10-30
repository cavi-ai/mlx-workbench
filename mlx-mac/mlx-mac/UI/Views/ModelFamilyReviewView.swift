import SwiftUI

/// Purpose, measured replacements and explicit comparison selection in one review.
struct ModelFamilyReviewView: View {
    let appHost: AppHost
    let onCompare: () -> Void
    let onReviewRemoval: (String) -> Void
    @ObservedObject private var purposes: ModelPurposeStore
    @ObservedObject private var comparison: ComparisonCoordinator
    @ObservedObject private var workflow: WorkflowEvidenceStore
    @ObservedObject private var reclaim: ReclaimCoordinator
    @ObservedObject private var endpoint: EndpointSupervisor
    @State private var selected: Set<String> = []
    @State private var editing: PurposeDraft?
    @State private var clearing: ModelPurpose?
    @State private var error: String?

    private struct PurposeDraft: Identifiable {
        let model: LibraryModel
        var id: String { model.item.path }
    }

    init(appHost: AppHost, onCompare: @escaping () -> Void, onReviewRemoval: @escaping (String) -> Void) {
        self.appHost = appHost; self.onCompare = onCompare; self.onReviewRemoval = onReviewRemoval
        _purposes = ObservedObject(wrappedValue: appHost.modelPurposes)
        _comparison = ObservedObject(wrappedValue: appHost.comparison)
        _workflow = ObservedObject(wrappedValue: appHost.workflowEvidence)
        _endpoint = ObservedObject(wrappedValue: appHost.endpoint)
        _reclaim = ObservedObject(wrappedValue: appHost.reclaim)
    }

    private var models: [LibraryModel] { appHost.librarySnapshot?.models ?? [] }
    private var replacements: [ReclaimOpportunity] {
        ComparisonInsights.superseded(models: models, runs: comparison.runs, workflow: workflow.records,
            environment: appHost.watch.currentFingerprintDescription, protected: appHost.occupancy.protectedPaths)
    }
    private var entrants: [LibraryModel] { models.filter { selected.contains($0.item.path) }.sorted { $0.item.path < $1.item.path } }

    var body: some View {
        let groups = ModelFamilyReview.groups(models: models, purposes: purposes.records)
        if !groups.isEmpty || !purposes.records.isEmpty || purposes.error != nil {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                SectionTitle(text: "Which variants should I keep?")
                Text("Related names suggest models to review, not identical weights. Keep abliterated or tuned models for a distinct purpose. Compare interchangeable candidates on prompts that exercise those purposes.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                ErrorBanner(text: purposes.error ?? error)
                let replacements = self.replacements
                ForEach(groups) { group in
                    DisclosureGroup("\(group.id) · \(group.models.count) variants") {
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                            ForEach(group.models, id: \.item.path) { model in
                                modelRow(model, replacements: replacements)
                            }
                        }.padding(.top, WorkbenchSpacing.sm)
                    }
                }
                ForEach(purposes.records.filter { record in !models.contains { $0.item.path == record.path } }, id: \.path) { record in
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        Text("Keep: \(record.note)").font(WorkbenchTypography.emphasis)
                        Text("Absent from the current Library scan. Its purpose remains saved.").font(WorkbenchTypography.secondary)
                        Text(record.path).font(WorkbenchTypography.value).textSelection(.enabled)
                        Button("Clear keep reason…") { clearing = record }
                            .disabled(reclaim.isApplying || purposes.isSaving || !purposes.hasLoadedHistory)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { showdownControls }
                    VStack(alignment: .leading) { showdownControls }
                }
                Text("Choose a relevant prompt set in Compare, run the showdown, then rate every model’s task quality. Finished, current results can supply replacement advice here. A speed winner alone does not prove redundancy.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            .confirmationDialog("Clear this keep reason?", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }), presenting: clearing) { record in
                Button("Clear keep reason", role: .destructive) {
                    Task { _ = await purposes.save(path: record.path, signature: record.signature, note: "") }
                }
                Button("Cancel", role: .cancel) {}
            } message: { record in Text(record.note + " — Clearing this reason removes its cleanup protection.") }
            .sheet(item: $editing) { draft in
                ModelPurposeEditor(model: draft.model, purposes: purposes, reclaim: reclaim,
                    currentModel: { models.first { $0.item.path == draft.id } },
                    onSave: { appHost.analyzeReclaim() })
            }
        }
    }

    private func modelRow(_ model: LibraryModel, replacements: [ReclaimOpportunity]) -> some View {
        let path = model.item.path
        let roles = appHost.recommendationPreferences.preferredModelIDs.compactMap { $0.value == path ? $0.key : nil }
        let served = endpoint.fleet.slots.contains { $0.modelPath == path }
        let reasons = ModelFamilyReview.reasons(for: model, purpose: purposes.purpose(for: path), preferredRoles: roles,
            served: served, replacements: replacements)
        let candidate = replacements.contains { $0.paths.contains(path) }
        return WorkbenchSurface(.tinted, padding: WorkbenchSpacing.sm) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Toggle(isOn: Binding(get: { selected.contains(path) }, set: { on in
                    if on { selected.insert(path) } else { selected.remove(path) }
                })) {
                    Text(model.displayName).font(WorkbenchTypography.emphasis)
                }.toggleStyle(.checkbox)
                    .disabled(model.readiness != .ready || (selected.count >= ComparePresentation.maxSlots && !selected.contains(path)))
                    .accessibilityLabel("Select \(model.displayName) for showdown")
                Text("\(model.item.quantization ?? "Quantization unknown") · \(ByteCountFormatter.string(fromByteCount: model.item.bytes, countStyle: .file))")
                    .font(WorkbenchTypography.secondaryTabular).foregroundStyle(WorkbenchColor.muted)
                ForEach(reasons, id: \.self) { Text($0).font(WorkbenchTypography.secondary).fixedSize(horizontal: false, vertical: true) }
                ViewThatFits(in: .horizontal) {
                    HStack { modelActions(model, candidate: candidate) }
                    VStack(alignment: .leading) { modelActions(model, candidate: candidate) }
                }
                DisclosureGroup("Path") { Text(path).font(WorkbenchTypography.value).textSelection(.enabled) }
                    .font(WorkbenchTypography.secondary)
            }
        }
    }

    @ViewBuilder
    private func modelActions(_ model: LibraryModel, candidate: Bool) -> some View {
        Button(purposes.purpose(for: model.item.path) == nil ? "Keep for a purpose…" : "Edit keep reason…") {
            editing = PurposeDraft(model: model)
        }.disabled(!purposes.hasLoadedHistory || purposes.isSaving || reclaim.isApplying)
        if candidate {
            Button("Review removal…") { onReviewRemoval(model.item.path) }
                .disabled(!purposes.hasLoadedHistory || purposes.isSaving || comparison.activeRunID != nil)
        }
    }

    @ViewBuilder
    private var showdownControls: some View {
        Button("Prepare showdown…") {
            guard entrants.count == selected.count, let request = FamilyComparisonRequest(models: entrants) else { error = "Choose two to four ready models with a shared comparison mode."; return }
            appHost.handoffs.send(request, as: .compareFamily)
            error = nil
            onCompare()
        }.buttonStyle(.workbenchPrimary)
            .disabled(entrants.count != selected.count || FamilyComparisonRequest(models: entrants) == nil)
            .help("Choose two to four ready models with recorded identities and a shared comparison mode.")
        Text("\(selected.count) selected · 2–\(ComparePresentation.maxSlots) per showdown")
            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
        if !selected.isEmpty { Button("Clear selection") { selected = [] } }
    }
}

private struct ModelPurposeEditor: View {
    let model: LibraryModel
    @ObservedObject var purposes: ModelPurposeStore
    @ObservedObject var reclaim: ReclaimCoordinator
    let currentModel: () -> LibraryModel?
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    @State private var error: String?

    init(model: LibraryModel, purposes: ModelPurposeStore, reclaim: ReclaimCoordinator, currentModel: @escaping () -> LibraryModel?, onSave: @escaping () -> Void) {
        self.model = model; self.purposes = purposes; self.reclaim = reclaim; self.currentModel = currentModel; self.onSave = onSave
        _note = State(initialValue: purposes.purpose(for: model.item.path)?.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Why keep this model?").font(WorkbenchTypography.cardTitle)
            Text(model.displayName).font(WorkbenchTypography.emphasis)
            Text("Record a distinct use, such as abliterated creative writing, a coding fine-tune or a lower-memory fallback. A saved purpose protects the model from cleanup. Clear the text to remove that protection.")
                .font(WorkbenchTypography.secondary)
            TextField("Purpose for keeping this model", text: $note, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder)
            Text("\(note.count)/500 characters").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            ErrorBanner(text: error ?? purposes.error)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save purpose") { Task {
                    guard let current = currentModel(), current.item.signature == model.item.signature else {
                        error = "Model changed. Reopen this review before saving."; return
                    }
                    if await purposes.save(path: model.item.path, signature: model.item.signature, note: note) { onSave(); dismiss() }
                } }.buttonStyle(.workbenchPrimary).disabled(purposes.isSaving || reclaim.isApplying || note.count > 500)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 480).interactiveDismissDisabled(purposes.isSaving)
    }
}
