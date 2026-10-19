import AppKit
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
    let workspaceWidth: CGFloat?
    @State private var promptID: String
    @State private var leftPath: String?
    @State private var rightPath: String?
    @State private var showChanges = false

    init(run: ComparisonRun, store: ComparisonOutputStore, name: @escaping (String) -> String,
         onReview: @escaping (String, Int?) -> Void, reviewError: String? = nil, workspaceWidth: CGFloat? = nil) {
        self.workspaceWidth = workspaceWidth
        self.run = run; self.store = store; self.name = name; self.onReview = onReview; self.reviewError = reviewError
        _promptID = State(initialValue: ComparisonViewLogic.rows(for: run).first?.id ?? "")
        let readable = ChatComparisonPresentation.readingResults(in: run)
        let first = readable.first?.id
        _leftPath = State(initialValue: first)
        _rightPath = State(initialValue: readable.first(where: { $0.id != first })?.id)
    }

    var body: some View {
        Group {
            if let workspaceWidth, workspaceWidth >= 1050 {
                HStack(alignment: .top, spacing: WorkbenchSpacing.lg) {
                    promptNavigation.frame(width: 180)
                    reader
                }
            } else {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    if workspaceWidth != nil { promptNavigation }
                    reader
                }
            }
        }
        .onChange(of: run.results.map(\.id)) { _, _ in
            let available = ChatComparisonPresentation.readingResults(in: run)
            if leftPath == nil { leftPath = available.first?.id }
            if rightPath == nil { rightPath = available.first { $0.id != leftPath }?.id }
        }
    }

    private var promptNavigation: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text("Prompts").font(WorkbenchTypography.section)
            if let workspaceWidth, workspaceWidth >= 1050 {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { promptButtons }
            } else {
                ScrollView(.horizontal) { HStack(spacing: WorkbenchSpacing.xs) { promptButtons } }
            }
        }
    }

    private var promptButtons: some View {
        ForEach(Array(ComparisonViewLogic.rows(for: run).enumerated()), id: \.element.id) { index, entry in
            Button { promptID = entry.id } label: {
                Text("\(index + 1). \(entry.text)").lineLimit(2)
                    .frame(width: 160, alignment: .leading).padding(WorkbenchSpacing.xs)
                    .background(promptID == entry.id ? WorkbenchColor.accent.opacity(.fill) : WorkbenchColor.canvas,
                        in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
            }
            .buttonStyle(.plain).accessibilityLabel("Read prompt \(index + 1)")
            .accessibilityAddTraits(promptID == entry.id ? .isSelected : [])
        }
    }

    private var reader: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            if workspaceWidth == nil, ComparisonViewLogic.rows(for: run).count > 1 {
                Picker("Prompt", selection: $promptID) {
                    ForEach(ComparisonViewLogic.rows(for: run)) { entry in
                        Text(entry.text).lineLimit(1).tag(entry.id)
                    }
                }
            }
            if let entry = ComparisonViewLogic.rows(for: run).first(where: { $0.id == promptID }) {
                if run.effectiveMode == .speechToText {
                    Text("Reference transcript").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
                Text(entry.text).font(WorkbenchTypography.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if run.effectiveMode.inputKind != nil {
                    let evidence = ComparisonViewLogic.inputEvidence(for: run, entry: entry, store: store)
                    HStack(spacing: WorkbenchSpacing.sm) {
                        Text(entry.inputDisplayName.map { "\(evidence.label) · \($0)" } ?? evidence.label)
                            .font(WorkbenchTypography.metadata)
                            .foregroundStyle(evidence.url == nil ? WorkbenchColor.warning : WorkbenchColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if evidence.url != nil {
                            Button("Show input in Finder") {
                                // Recheck availability at the action boundary; never fall
                                // back to a changed original when a saved copy disappeared.
                                if let url = ComparisonViewLogic.inputEvidence(for: run, entry: entry, store: store).url {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                            .font(WorkbenchTypography.metadata).buttonStyle(.borderless)
                            .help(evidence.url?.path ?? "")
                        }
                    }
                }
                if let keywords = entry.expectedKeywords, !keywords.isEmpty {
                    Text("Expected words: \(keywords.joined(separator: ", "))")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("All listed checks must match. A | separates alternatives; matching ignores case and checks for text presence, not task quality.")
                }
            }
            if let workspaceWidth {
                if workspaceWidth >= 700 {
                    HStack {
                        modelPicker("A", path: $leftPath, excluding: rightPath).labelsHidden()
                        modelPicker("B", path: $rightPath, excluding: leftPath).labelsHidden()
                    }
                } else {
                    modelPicker("A", path: $leftPath, excluding: rightPath)
                    modelPicker("B", path: $rightPath, excluding: leftPath)
                }
                readingModePicker
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { controls }
                    VStack(alignment: .leading) { controls }
                }
            }
            TextComparisonContent(run: run, promptID: promptID, leftPath: leftPath, rightPath: rightPath,
                showChanges: showChanges, store: store, name: name, onReview: onReview,
                paired: workspaceWidth.map { ($0 >= 1050 ? $0 - 204 : $0) >= 700 } ?? true)
            if let reviewError { ErrorBanner(text: reviewError) }
        }
    }

    @ViewBuilder private var controls: some View {
        modelPicker("A", path: $leftPath, excluding: rightPath)
        modelPicker("B", path: $rightPath, excluding: leftPath)
        readingModePicker
    }

    private var readingModePicker: some View {
        Picker("View", selection: $showChanges) {
            Text("Read A/B").tag(false)
            Text("Differences").tag(true)
        }
        .pickerStyle(.segmented).frame(width: 210)
    }

    private func modelPicker(_ letter: String, path: Binding<String?>, excluding: String?) -> some View {
        Picker(letter == "A" ? "Left model" : "Right model", selection: path) {
            if !run.results.contains(where: { $0.id != excluding }) {
                Text("No model available").tag(String?.none)
            }
            ForEach(run.results.filter { $0.id != excluding }) { result in
                Text(ComparisonViewLogic.laneLabel(result, run: run, name: name)).tag(String?.some(result.id))
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
    var paired = true
    @State private var rightVisible = false

    private var left: VariantResult? { run.results.first { $0.id == leftPath } }
    private var right: VariantResult? { run.results.first { $0.id == rightPath } }

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
                        Text("− Left model · + Right model · unchanged lines have no sign")
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
                if paired {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.sm) {
                        pane("A", result: left)
                        pane("B", result: right)
                    }
                } else {
                    Picker("Visible output", selection: $rightVisible) {
                        Text("Read left").tag(false)
                        Text("Read right").tag(true)
                    }.pickerStyle(.segmented).accessibilityIdentifier("chat-reader-side")
                    pane(rightVisible ? "B" : "A", result: rightVisible ? right : left)
                }
            }
        }
    }

    private func pane(_ letter: String, result: VariantResult?) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            HStack {
                LetterChip(letter: result.flatMap { run.variantIdentities.firstIndex(of: $0.id) }
                    .map { ComparePresentation.letter($0) } ?? letter)
                Text(result.map { ComparisonViewLogic.laneLabel($0, run: run, name: name) } ?? "No model selected")
                    .font(WorkbenchTypography.label).lineLimit(1).help(result?.modelPath ?? "")
                Spacer(minLength: 0)
            }
            if let result {
                TaskQualityRating(run: run, modelPath: result.id, modelName: name(result.modelPath),
                    store: store, onReview: onReview)
                if let sample = result.samples.first(where: { $0.promptID == promptID }) {
                    let inline = ChatRecordedText(sample.fullOutput ?? sample.outputExcerpt)
                    let status = inline.hasInlineReasoning && inline.answer.isEmpty && sample.finishReason == "stop"
                        ? "Generation stopped · no answer text" : sample.completionDescription ?? "Finish reason not reported"
                    if !status.isEmpty {
                        Text(status).font(WorkbenchTypography.metadata)
                            .foregroundStyle(sample.hasCompletedAnswer && !inline.answer.isEmpty ? WorkbenchColor.muted : WorkbenchColor.warning)
                    }
                    if run.effectiveMode == .chat, result.servingEvidence?.runtime == "strata" || sample.draftTokens != nil {
                        ComparisonDraftTokenEvidenceView(evidence: sample.draftTokens)
                    }
                    if run.effectiveMode == .chat, result.servingEvidence?.runtime == "strata" || sample.promptProcessing != nil {
                        ComparisonPromptProcessingEvidenceView(evidence: sample.promptProcessing)
                    }
                    let reasoning = [sample.reasoningText, inline.reasoning].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                    DisclosureGroup("Measurement details") {
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                            if let speed = sample.tokensPerSecond {
                                Text(String(format: "Decode %.1f tok/s", speed) + (sample.metricsEstimated == true ? " (estimated)" : ""))
                            }
                            if let first = sample.timeToFirstTokenSeconds { Text(String(format: "First token %.2f s · may include reasoning", first)) }
                            if inline.hasInlineReasoning { Text("Answer-start timing unavailable for inline reasoning.") }
                            else if let answer = sample.timeToFirstAnswerSeconds { Text(String(format: "Answer begins %.2f s", answer)) }
                            if let duration = sample.durationSeconds { Text(String(format: "Total %.2f s", duration)) }
                            if let tokens = sample.completionTokens { Text("Generated tokens: \(tokens)") }
                            if let calls = sample.toolCalls {
                                Text("Tool calls: \(calls)")
                                Text(sample.toolCallsValid.map { "Valid arguments: \($0)/\(calls)" } ?? "Argument validation not recorded")
                            }
                        }.font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    }
                    if !reasoning.isEmpty {
                        DisclosureGroup("Reasoning") {
                            ScrollView {
                                Text(reasoning).font(WorkbenchTypography.secondary).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(height: 160)
                        }
                    }
                }
                if let output = ComparisonDiff.output(result, promptID: promptID) {
                    Text(output.isExcerpt ? "Saved excerpt · full text not recorded" : "Full recorded output")
                        .font(WorkbenchTypography.metadata)
                        .foregroundStyle(output.isExcerpt ? WorkbenchColor.warning : WorkbenchColor.muted)
                    let display = ChatRecordedText(output.text)
                    HStack {
                        Button("Copy recorded output") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(output.text, forType: .string)
                        }.buttonStyle(.borderless).font(WorkbenchTypography.metadata)
                        Spacer()
                    }
                    ScrollView {
                        RecordedAnswerView(text: display.answer.isEmpty ? "No answer text recorded." : display.answer)
                    }
                    .frame(height: 340).accessibilityLabel("Model \(letter) recorded output")
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
