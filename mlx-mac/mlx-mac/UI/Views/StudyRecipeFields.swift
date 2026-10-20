import SwiftUI

struct StudyRecipeFields: View {
    @ObservedObject var session: StudyRecipeSession

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text(session.options.first?.displayName ?? "Wan 2.1 T2V 1.3B (MPS)").font(WorkbenchTypography.emphasis)
            Text("Capture a recipe from existing Diffusers weights. No model is downloaded or loaded; generation stays a separate action.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            if let option = session.options.first, !option.revisions.isEmpty {
                Picker("Cached revision", selection: $session.draft.revision) {
                    ForEach(option.revisions, id: \.self) { revision in Text(revision).tag(revision) }
                }
            }
            TextField("Shared prompt", text: $session.draft.prompt, axis: .vertical).lineLimit(3...6)
            TextField("Negative prompt (optional)", text: $session.draft.negativePrompt, axis: .vertical).lineLimit(1...3)
            if let reason = session.unavailableReason, !session.isBusy {
                Text(reason).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("study-recipe-guidance")
            }
            Grid(alignment: .leading, horizontalSpacing: WorkbenchSpacing.md, verticalSpacing: WorkbenchSpacing.sm) {
                GridRow {
                    numberField("Width", text: $session.draft.width)
                    numberField("Height", text: $session.draft.height)
                }
                GridRow {
                    numberField("Frames", text: $session.draft.frames)
                    numberField("FPS", text: $session.draft.fps)
                }
                GridRow {
                    numberField("Baseline inference steps", text: $session.draft.steps)
                    numberField("Baseline guidance", text: $session.draft.guidance)
                }
                GridRow { numberField("Baseline seed", text: $session.draft.seed) }
            }
            DisclosureGroup("Generation settings explained") {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    Text("Steps set the number of refinement passes. Guidance controls how strongly the prompt conditions generation. Seed selects the starting randomness; keep it fixed when comparing another setting.")
                    Text("Width and height set the clip size. Frames sets the number of images; FPS sets playback speed. Duration is frames divided by FPS.")
                }
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Capture recipe") { Task { await session.capture() } }.disabled(!session.canCapture)
                    .help(session.unavailableReason ?? "Record this baseline and its model and runtime identities without starting generation.")
                    .accessibilityHint(session.unavailableReason ?? "Record this baseline without starting generation.")
                Button("Refresh availability") { Task { await session.load() } }.disabled(session.isBusy)
                if session.isBusy { ProgressView().controlSize(.small) }
            }
            if let fields = session.manifest?.object, let digest = fields["model_checksum"]?.text {
                Label("Recipe captured", systemImage: "checkmark.circle").accessibilityIdentifier("study-recipe-captured")
                Text("Model and runtime identities are attached. Generation rechecks them before loading.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                Text(digest).font(WorkbenchTypography.metadata).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle).help(digest)
            }
            ErrorBanner(text: session.error)
        }.disabled(session.isBusy)
    }

    private func numberField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
            Text(label).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            TextField(label, text: text)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
