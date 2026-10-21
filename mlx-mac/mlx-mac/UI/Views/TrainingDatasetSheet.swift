import AppKit
import SwiftUI

struct TrainingDatasetSheet: View {
    @State private var draft: TrainingDatasetDraft
    private let original: TrainingDatasetDraft
    let onSaved: (URL) -> Void
    @State private var split = TrainingDatasetDraft.Split.train
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingDiscard = false
    @Environment(\.dismiss) private var dismiss

    init(batchSize: Int, onSaved: @escaping (URL) -> Void) {
        let draft = TrainingDatasetDraft(batchSize: batchSize)
        _draft = State(initialValue: draft)
        original = draft
        self.onSaved = onSaved
    }

    private var examples: Binding<[TrainingDatasetDraft.Example]> {
        split == .train ? $draft.train : $draft.valid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Create chat dataset").font(WorkbenchTypography.title)
            Text("Write user requests and the replies you want the model to learn. Reserve separate examples for validation; Workbench writes the JSONL files.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Examples", selection: $split) {
                Text("Training (\(draft.train.count))").tag(TrainingDatasetDraft.Split.train)
                Text("Validation (\(draft.valid.count))").tag(TrainingDatasetDraft.Split.valid)
            }.pickerStyle(.segmented)
                .accessibilityIdentifier("dataset-split")
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    HStack {
                        Text("\(split.title) · minimum \(draft.batchSize) examples")
                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                        Spacer()
                        Button("Add example", systemImage: "plus") {
                            let example = TrainingDatasetDraft.Example()
                            examples.wrappedValue.append(example)
                            Task { @MainActor in
                                await Task.yield()
                                proxy.scrollTo(example.id, anchor: .bottom)
                            }
                        }.disabled(examples.wrappedValue.count >= TrainingDatasetDraft.exampleLimit)
                    }
                    ScrollView {
                        LazyVStack(spacing: WorkbenchSpacing.sm) {
                            ForEach(Array(examples.wrappedValue.enumerated()), id: \.element.id) { index, example in
                                if let position = examples.wrappedValue.firstIndex(where: { $0.id == example.id }) {
                                    TrainingDatasetExampleCard(example: examples[position], number: index + 1,
                                        split: split, guidance: draft.validationIssue.flatMap { issue in
                                            issue.split == split && issue.exampleID == example.id ? issue.message : nil
                                        }, canRemove: examples.wrappedValue.count > 1) {
                                            examples.wrappedValue.removeAll { $0.id == example.id }
                                        }.id(example.id)
                                }
                            }
                        }.padding(.vertical, WorkbenchSpacing.xxs)
                    }.frame(minHeight: WorkbenchSize.Training.datasetListMinHeight, maxHeight: .infinity)
                        .id(split)
                    if let issue = draft.validationIssue, let targetSplit = issue.split {
                        Button(issue.exampleID == nil ? "Review \(targetSplit.title.lowercased()) examples" : "Fix \(targetSplit.title.lowercased()) example") {
                            split = targetSplit
                            let target = issue.exampleID ?? examples.wrappedValue.first?.id
                            Task { @MainActor in
                                await Task.yield()
                                if let target { proxy.scrollTo(target, anchor: .center) }
                            }
                        }
                        .accessibilityIdentifier("dataset-fix-example")
                        .help(issue.message)
                        .accessibilityHint(issue.message)
                    }
                }
            }
            if let message = error ?? draft.validationMessage {
                Text(message).font(WorkbenchTypography.metadata)
                    .foregroundStyle(error == nil ? WorkbenchColor.muted : WorkbenchColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dataset-guidance")
            }
            HStack {
                Button("Cancel") {
                    if draft == original { dismiss() } else { confirmingDiscard = true }
                }.keyboardShortcut(.cancelAction)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save dataset…", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.validationMessage != nil)
                    .help("Create train.jsonl and valid.jsonl in a new folder, then select it in Training. No training job starts.")
            }
        }
        .padding(WorkbenchSpacing.lg)
        .frame(minWidth: WorkbenchSize.Training.datasetSheetMinWidth,
               idealWidth: WorkbenchSize.Training.datasetSheetWidth,
               minHeight: WorkbenchSize.Training.datasetSheetHeight,
               maxHeight: WorkbenchSize.Training.datasetSheetHeight)
        .disabled(saving)
        .interactiveDismissDisabled(saving || draft != original)
        .confirmationDialog("Discard this dataset draft?", isPresented: $confirmingDiscard) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .onChange(of: draft) { _, _ in error = nil }
    }

    private func save() {
        guard !saving, draft.validationMessage == nil else { return }
        let panel = NSSavePanel()
        panel.title = "Create dataset folder"
        panel.prompt = "Create folder"
        panel.nameFieldLabel = "Folder name:"
        panel.nameFieldStringValue = "Training dataset"
        panel.message = "Choose a new folder. Both JSONL files will be created together; existing datasets are never replaced."
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let captured = draft
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await Task.detached(priority: .utility) { try TrainingDatasetExporter.save(captured, to: destination) }.value
                onSaved(destination)
                dismiss()
            } catch { self.error = AppHost.render(error) }
        }
    }
}

private struct TrainingDatasetExampleCard: View {
    @Binding var example: TrainingDatasetDraft.Example
    let number: Int
    let split: TrainingDatasetDraft.Split
    let guidance: String?
    let canRemove: Bool
    let onRemove: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack {
                Text("Example \(number)").font(WorkbenchTypography.label)
                Spacer()
                Button("Remove", systemImage: "minus.circle") { confirmingRemoval = true }
                    .labelStyle(.iconOnly).disabled(!canRemove)
                    .help("Remove example \(number) from this draft")
            }
            TextField("User request", text: $example.prompt, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("dataset-\(split.rawValue)-\(number)-prompt")
                .accessibilityLabel("\(split.title) example \(number) user request")
            TextField("Desired assistant reply", text: $example.reply, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("dataset-\(split.rawValue)-\(number)-reply")
                .accessibilityLabel("\(split.title) example \(number) assistant reply")
            if let guidance {
                Text(guidance).font(WorkbenchTypography.metadata)
                    .foregroundStyle(WorkbenchColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dataset-example-guidance")
            }
        }
        .padding(WorkbenchSpacing.sm)
        .background(WorkbenchColor.surface, in: RoundedRectangle(cornerRadius: WorkbenchSpacing.xs))
        .confirmationDialog("Remove example \(number)?", isPresented: $confirmingRemoval) {
            Button("Remove example", role: .destructive, action: onRemove)
            Button("Keep example", role: .cancel) {}
        }
    }
}
