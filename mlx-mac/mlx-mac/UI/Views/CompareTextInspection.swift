import SwiftUI

/// One recorded prompt, two outputs. Collapsed below the charts by default.
struct TextComparisonPanel: View {
    let run: ComparisonRun
    let store: ComparisonOutputStore
    let name: (String) -> String
    let onReview: (String, Int?) -> Void
    let reviewError: String?
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            TextComparisonEditor(run: run, store: store, name: name, onReview: onReview, reviewError: reviewError)
                .id(run.id).padding(.top, WorkbenchSpacing.sm)
        } label: {
            Label("Compare text · A/B", systemImage: "text.alignleft")
                .font(WorkbenchTypography.label)
        }
    }
}

struct TextComparisonEditor: View {
    let run: ComparisonRun
    let store: ComparisonOutputStore
    let name: (String) -> String
    let onReview: (String, Int?) -> Void
    let reviewError: String?
    @State private var promptID: String
    @State private var leftPath: String?
    @State private var rightPath: String?
    @State private var showChanges = false

    init(run: ComparisonRun, store: ComparisonOutputStore, name: @escaping (String) -> String,
         onReview: @escaping (String, Int?) -> Void, reviewError: String? = nil) {
        self.run = run; self.store = store; self.name = name; self.onReview = onReview; self.reviewError = reviewError
        _promptID = State(initialValue: ComparisonViewLogic.rows(for: run).first?.id ?? "")
        let first = run.results.first?.modelPath
        _leftPath = State(initialValue: first)
        _rightPath = State(initialValue: run.results.first(where: { $0.modelPath != first })?.modelPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            if ComparisonViewLogic.rows(for: run).count > 1 {
                Picker("Prompt", selection: $promptID) {
                    ForEach(ComparisonViewLogic.rows(for: run)) { entry in
                        Text(entry.text).lineLimit(1).tag(entry.id)
                    }
                }
            }
            if let entry = ComparisonViewLogic.rows(for: run).first(where: { $0.id == promptID }) {
                Text(entry.text).font(WorkbenchTypography.secondary).textSelection(.enabled)
            }
            ViewThatFits(in: .horizontal) {
                HStack { controls }
                VStack(alignment: .leading) { controls }
            }
            TextComparisonContent(run: run, promptID: promptID, leftPath: leftPath, rightPath: rightPath,
                showChanges: showChanges, store: store, name: name, onReview: onReview)
            if let reviewError { ErrorBanner(text: reviewError) }
        }
    }

    @ViewBuilder private var controls: some View {
        modelPicker("A", path: $leftPath, excluding: rightPath)
        modelPicker("B", path: $rightPath, excluding: leftPath)
        Picker("View", selection: $showChanges) {
            Text("Read A/B").tag(false)
            Text("Differences").tag(true)
        }
        .pickerStyle(.segmented).frame(width: 210)
    }

    private func modelPicker(_ letter: String, path: Binding<String?>, excluding: String?) -> some View {
        Picker("Model \(letter)", selection: path) {
            ForEach(run.results.filter { $0.modelPath != excluding }) { result in
                Text(name(result.modelPath)).tag(String?.some(result.modelPath))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Renders reading and differences from the same recorded model/prompt identities.
struct TextComparisonContent: View {
    let run: ComparisonRun
    let promptID: String
    let leftPath: String?
    let rightPath: String?
    let showChanges: Bool
    let store: ComparisonOutputStore
    let name: (String) -> String
    let onReview: (String, Int?) -> Void

    private var left: VariantResult? { run.results.first { $0.modelPath == leftPath } }
    private var right: VariantResult? { run.results.first { $0.modelPath == rightPath } }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            if showChanges {
                if let left, let right,
                   let pair = ComparisonDiff.pairs(left, right).first(where: { $0.promptID == promptID }) {
                    if pair.leftIsExcerpt || pair.rightIsExcerpt {
                        Text("Excerpt comparison · full text was not recorded for every output.")
                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
                    }
                    if let lines = ComparisonDiff.differences(pair) {
                        Text("− Model A · + Model B · unchanged lines have no sign")
                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                    Text(lineText(line)).font(WorkbenchTypography.value)
                                        .foregroundStyle(lineColor(line.kind)).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(WorkbenchSpacing.sm)
                        }
                        .frame(height: 300)
                        .background(WorkbenchColor.canvas, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                        .accessibilityLabel("Text differences for the selected prompt")
                    } else {
                        Text("These outputs are too long for highlighted differences. Read the complete recorded text in A/B view.")
                            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    }
                } else {
                    Text("Two successful outputs for the same prompt are needed to show differences.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
            } else {
                HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
                    pane("A", result: left)
                    pane("B", result: right)
                }
            }
        }
    }

    private func pane(_ letter: String, result: VariantResult?) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack {
                LetterChip(letter: letter)
                Text(result.map { name($0.modelPath) } ?? "No model selected")
                    .font(WorkbenchTypography.label).lineLimit(1).help(result?.modelPath ?? "")
                Spacer(minLength: 0)
            }
            if let result {
                TaskQualityRating(run: run, modelPath: result.modelPath, modelName: name(result.modelPath),
                    store: store, onReview: onReview)
                if let output = ComparisonDiff.output(result, promptID: promptID) {
                    Text(output.isExcerpt ? "Saved excerpt · full text not recorded" : "Full recorded output")
                        .font(WorkbenchTypography.metadata)
                        .foregroundStyle(output.isExcerpt ? WorkbenchColor.warning : WorkbenchColor.muted)
                    ScrollView {
                        Text(output.text.isEmpty ? "Empty response" : output.text)
                            .font(WorkbenchTypography.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 280).accessibilityLabel("Model \(letter) recorded output")
                } else {
                    Text(result.error ?? result.samples.first(where: { $0.promptID == promptID })?.error
                        ?? "No recorded output for this prompt.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
                }
            }
        }
        .padding(WorkbenchSpacing.sm).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(WorkbenchColor.canvas, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
    }

    private func lineText(_ line: DiffLine) -> String {
        switch line.kind {
        case .context: return "  \(line.text)"
        case .removed: return "− \(line.text)"
        case .added: return "+ \(line.text)"
        }
    }

    private func lineColor(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .context: return WorkbenchColor.ink
        case .removed: return WorkbenchColor.failure
        case .added: return WorkbenchColor.success
        }
    }
}
