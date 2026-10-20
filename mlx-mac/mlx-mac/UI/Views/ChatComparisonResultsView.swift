import AppKit
import SwiftUI

/// A prompt-outcome matrix and one reading inspector share recorded identities.
struct ChatComparisonResultsView<Actions: View>: View {
    let run: ComparisonRun
    let store: ComparisonOutputStore
    let contentWidth: CGFloat
    let name: (String) -> String
    let onReview: (String, Int?) -> Void
    let reviewError: String?
    let onPromote: (VariantResult) -> Void
    let allowsPromotion: Bool
    @ViewBuilder let laneActions: (CompareLane) -> Actions
    @State private var promptID: String
    @State private var firstID: String?
    @State private var secondID: String?
    @State private var showChanges = false
    @State private var matrixExpanded = false
    @State private var secondVisible = false

    init(run: ComparisonRun, store: ComparisonOutputStore, contentWidth: CGFloat,
         name: @escaping (String) -> String, onReview: @escaping (String, Int?) -> Void,
         reviewError: String?, onPromote: @escaping (VariantResult) -> Void, allowsPromotion: Bool = true,
         @ViewBuilder laneActions: @escaping (CompareLane) -> Actions) {
        self.run = run; self.store = store; self.contentWidth = contentWidth; self.name = name
        self.onReview = onReview; self.reviewError = reviewError; self.onPromote = onPromote; self.laneActions = laneActions
        self.allowsPromotion = allowsPromotion
        _promptID = State(initialValue: ComparisonViewLogic.rows(for: run).first?.id ?? "")
        let readable = ChatComparisonPresentation.readingResults(in: run)
        let first = readable.first?.id ?? run.variantIdentities.first
        _firstID = State(initialValue: first)
        _secondID = State(initialValue: readable.first { $0.id != first }?.id ?? run.variantIdentities.first { $0 != first })
    }

    private var prompts: [PromptEntry] { ComparisonViewLogic.rows(for: run) }
    private var lanes: [CompareLane] { ComparePresentation.lanes(for: run) }
    private var wide: Bool { contentWidth >= WorkbenchSize.Compare.boardBreakpoint }
    private var selectedPrompt: PromptEntry? { prompts.first { $0.id == promptID } }

    var body: some View {
        Group {
            if wide {
                HStack(alignment: .top, spacing: WorkbenchSpacing.lg) {
                    matrix.frame(width: min(WorkbenchSize.Compare.boardMatrixMaximum, contentWidth * 0.42))
                    inspector
                }
            } else {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    DisclosureGroup("Models in this run · \(lanes.count)", isExpanded: $matrixExpanded) { matrix }
                    inspector
                }
            }
        }
        .accessibilityIdentifier("chat-results-workspace")
        .onChange(of: run.results.map(\.id)) { _, _ in
            let readable = ChatComparisonPresentation.readingResults(in: run)
            if firstID == nil { firstID = readable.first?.id }
            if secondID == nil { secondID = readable.first { $0.id != firstID }?.id }
        }
    }

    private var matrix: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack {
                Text("Models in this run").font(WorkbenchTypography.section)
                Spacer(minLength: 0)
                Text("\(prompts.count) prompts").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: WorkbenchSpacing.xs) {
                        Text("Model").frame(width: WorkbenchSize.Compare.boardModelColumn, alignment: .leading)
                        ForEach(Array(prompts.enumerated()), id: \.element.id) { index, prompt in
                            Button { promptID = prompt.id; matrixExpanded = false } label: {
                                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                                    Text("Prompt \(index + 1)").fontWeight(.semibold)
                                    Text(prompt.text).lineLimit(2)
                                }
                                .frame(width: WorkbenchSize.Compare.boardPromptColumn, alignment: .leading)
                                .padding(.vertical, WorkbenchSpacing.xs)
                            }
                            .buttonStyle(.plain).foregroundStyle(prompt.id == promptID ? WorkbenchColor.accent : WorkbenchColor.muted)
                            .help(prompt.text).accessibilityLabel("Read prompt \(index + 1)")
                            .accessibilityAddTraits(prompt.id == promptID ? .isSelected : [])
                        }
                        Text("Median\ndecode").frame(width: WorkbenchSize.Compare.boardMetricColumn, alignment: .trailing)
                    }
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    ForEach(lanes) { lane in matrixRow(lane) }
                }
            }
            Text("Finished generation is not a quality score.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
        }
        .padding(WorkbenchSpacing.md)
        .background(WorkbenchColor.surface, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
    }

    private func matrixRow(_ lane: CompareLane) -> some View {
        let result = run.results.first { $0.id == lane.resultKey }
        return HStack(spacing: WorkbenchSpacing.xs) {
            HStack(spacing: WorkbenchSpacing.xs) {
                LetterChip(letter: lane.letter)
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Button { inspect(lane, prompt: promptID) } label: {
                        Text(name(lane.path)).fontWeight(.semibold).lineLimit(2).multilineTextAlignment(.leading)
                    }.buttonStyle(.plain).help(lane.path)
                    if let profile = lane.profileName { Text(profile).lineLimit(1).foregroundStyle(WorkbenchColor.muted) }
                    ChatModelDetailsButton(lane: lane, result: result, run: run, name: name(lane.path)) { laneActions(lane) }
                }
            }
            .frame(width: WorkbenchSize.Compare.boardModelColumn, height: WorkbenchSize.Compare.boardRowHeight, alignment: .leading)
            ForEach(Array(prompts.enumerated()), id: \.element.id) { index, prompt in
                let outcome = ChatComparisonPresentation.outcome(result, prompt: prompt, in: run)
                Button { inspect(lane, prompt: prompt.id) } label: {
                    Label(outcome.label, systemImage: outcome.symbol)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: WorkbenchSize.Compare.boardPromptColumn, height: WorkbenchSize.Compare.boardRowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(outcome.color)
                .accessibilityLabel("Model \(lane.letter), prompt \(index + 1): \(outcome.label)")
                .accessibilityIdentifier("comparison-cell-\(lane.index)-\(index)")
                .help(result?.error ?? result?.samples.first { $0.promptID == prompt.id }?.error ?? prompt.text)
            }
            VStack(alignment: .trailing, spacing: WorkbenchSpacing.xxs) {
                Text(result.flatMap { run.metricValue(of: $0) }.map { String(format: "%.1f tok/s", $0) } ?? "—")
                    .fontWeight(.semibold).monospacedDigit()
                if result?.samples.contains(where: { $0.metricsEstimated == true }) == true {
                    Text("Estimated").foregroundStyle(WorkbenchColor.muted)
                }
                if let latency = result?.aggregateTTFTSeconds {
                    Text(String(format: "First %.2f s", latency)).foregroundStyle(WorkbenchColor.muted)
                        .help("Fastest recorded first token; may include reasoning.")
                }
            }.frame(width: WorkbenchSize.Compare.boardMetricColumn, alignment: .trailing)
        }
        .font(WorkbenchTypography.secondary)
        .background(firstID == lane.resultKey || secondID == lane.resultKey ? WorkbenchColor.accent.opacity(.wash) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.control))
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            if let prompt = selectedPrompt, let index = prompts.firstIndex(where: { $0.id == promptID }) {
                HStack {
                    Text("Prompt \(index + 1) of \(prompts.count)").font(WorkbenchTypography.inspectorTitle)
                    Spacer()
                    Button { promptID = prompts[index - 1].id } label: { Image(systemName: "chevron.left") }
                        .disabled(index == 0).accessibilityLabel("Previous prompt")
                    Button { promptID = prompts[index + 1].id } label: { Image(systemName: "chevron.right") }
                        .disabled(index == prompts.count - 1).accessibilityLabel("Next prompt")
                }
                if !wide {
                    Picker("Recorded prompt", selection: $promptID) {
                        ForEach(Array(prompts.enumerated()), id: \.element.id) { index, entry in
                            Text("\(index + 1). \(entry.text)").tag(entry.id)
                        }
                    }
                }
                Text(prompt.text).font(WorkbenchTypography.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(WorkbenchSpacing.sm)
                    .background(WorkbenchColor.surface, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                Picker("View", selection: $showChanges) {
                    Text("Read").tag(false)
                    Text("Differences").tag(true)
                }.pickerStyle(.segmented).frame(width: 210)
                if showChanges {
                    TextComparisonContent(run: run, promptID: promptID, leftPath: firstID, rightPath: secondID,
                        showChanges: true, store: store, name: name, onReview: onReview)
                } else if wide || secondID == nil {
                    output(firstID, prompt: prompt, first: true)
                    if secondID != nil { Divider(); output(secondID, prompt: prompt, first: false) }
                } else {
                    Picker("Visible output", selection: $secondVisible) {
                        Text("Read left").tag(false)
                        Text("Read right").tag(true)
                    }.pickerStyle(.segmented)
                    output(secondVisible ? secondID : firstID, prompt: prompt, first: !secondVisible)
                }
                Divider()
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    Label("Review model quality across this run", systemImage: "star").font(WorkbenchTypography.label)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: WorkbenchSpacing.md) { ratings }
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) { ratings }
                    }
                }
                if let reviewError { ErrorBanner(text: reviewError) }
                if allowsPromotion, run.state == .completed, !run.hasCustomServingConfiguration,
                   let winner = run.winner, [firstID, secondID].contains(winner.id),
                   let lane = lanes.first(where: { $0.resultKey == winner.id }) {
                    Divider()
                    Button("Use model \(lane.letter)…") { onPromote(winner) }
                        .buttonStyle(.workbenchPrimary)
                        .help("Review this model as the preferred model for the run use case.")
                }
            } else {
                Text("No recorded prompts are available.").font(WorkbenchTypography.body).foregroundStyle(WorkbenchColor.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(WorkbenchSpacing.md)
        .accessibilityIdentifier("comparison-reading-inspector")
    }

    private var ratings: some View {
        ForEach(lanes.filter { $0.resultKey == firstID || $0.resultKey == secondID }) { lane in
            HStack {
                LetterChip(letter: lane.letter)
                TaskQualityRating(run: run, modelPath: lane.resultKey, modelName: name(lane.path), store: store, onReview: onReview)
            }
        }
    }

    @ViewBuilder private func output(_ id: String?, prompt: PromptEntry, first: Bool) -> some View {
        if let lane = lanes.first(where: { $0.resultKey == id }) {
            ChatInspectorOutput(run: run, lane: lane, result: run.results.first { $0.id == id }, prompt: prompt,
                name: name, lanes: lanes, onSelect: { selected in
                    if first {
                        if selected.resultKey == secondID { secondID = firstID }
                        firstID = selected.resultKey
                    } else {
                        if selected.resultKey == firstID { firstID = secondID }
                        secondID = selected.resultKey
                    }
                })
        }
    }

    private func inspect(_ lane: CompareLane, prompt: String) {
        promptID = prompt
        if lane.resultKey != firstID && lane.resultKey != secondID { firstID = lane.resultKey }
        matrixExpanded = false
    }
}

private struct ChatInspectorOutput: View {
    let run: ComparisonRun
    let lane: CompareLane
    let result: VariantResult?
    let prompt: PromptEntry
    let name: (String) -> String
    let lanes: [CompareLane]
    let onSelect: (CompareLane) -> Void

    private var sample: ComparisonSample? { result?.samples.first { $0.promptID == prompt.id } }

    var body: some View {
        let outcome = ChatComparisonPresentation.outcome(result, prompt: prompt, in: run)
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                LetterChip(letter: lane.letter)
                Menu {
                    ForEach(lanes) { choice in
                        Button("\(choice.letter) · \(name(choice.path))") { onSelect(choice) }
                    }
                } label: { Text(name(lane.path)).font(WorkbenchTypography.emphasis) }
                .menuStyle(.borderlessButton).help(lane.path)
                Spacer(minLength: 0)
                if let result, let output = ComparisonDiff.output(result, promptID: prompt.id) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output.text, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy the original recorded output, including any inline reasoning.")
                    .accessibilityLabel("Copy model \(lane.letter) recorded output")
                }
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Label("\(outcome.label) · this prompt", systemImage: outcome.symbol)
                    .foregroundStyle(outcome.color)
                if let result {
                    Text("\(ChatComparisonPresentation.completion(result, in: run).label) · entire run")
                        .foregroundStyle(WorkbenchColor.muted)
                }
            }.font(WorkbenchTypography.secondary)
            if let result, let recorded = ComparisonDiff.output(result, promptID: prompt.id) {
                let display = ChatRecordedText(recorded.text)
                if recorded.isExcerpt {
                    Text("Saved excerpt · full text not recorded").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.warning)
                }
                if !display.answer.isEmpty {
                    RecordedAnswerView(text: display.answer, reading: true)
                        .padding(WorkbenchSpacing.sm)
                        .background(WorkbenchColor.surface, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                } else {
                    Text(outcome == .tokenLimit ? "The token limit was reached before an answer was recorded."
                         : sample?.finishReason == "tool_calls" ? "Tool calls were emitted without answer text." : "No answer text recorded.")
                        .font(WorkbenchTypography.body).foregroundStyle(WorkbenchColor.muted)
                }
            } else {
                Text(result?.error ?? sample?.error ?? (outcome == .waiting ? "Waiting for recorded output…" : "No output was recorded for this prompt."))
                    .font(WorkbenchTypography.body).foregroundStyle(outcome == .blocked ? WorkbenchColor.failure : WorkbenchColor.muted)
                    .textSelection(.enabled)
            }
            if let sample {
                DisclosureGroup("Reasoning and measurements") { evidence(sample) }
                    .font(WorkbenchTypography.secondary)
            }
        }
        .padding(.vertical, WorkbenchSpacing.xs)
    }

    private func evidence(_ sample: ComparisonSample) -> some View {
        let inline = ChatRecordedText(sample.fullOutput ?? sample.outputExcerpt)
        let reasoning = [sample.reasoningText, inline.reasoning].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if !reasoning.isEmpty {
                Text("Reasoning").font(WorkbenchTypography.label)
                Text(reasoning).textSelection(.enabled)
            }
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
            if run.results.first(where: { $0.id == lane.resultKey })?.servingEvidence?.runtime == "strata" || sample.draftTokens != nil {
                ComparisonDraftTokenEvidenceView(evidence: sample.draftTokens)
            }
            if run.results.first(where: { $0.id == lane.resultKey })?.servingEvidence?.runtime == "strata" || sample.promptProcessing != nil {
                ComparisonPromptProcessingEvidenceView(evidence: sample.promptProcessing)
            }
        }
        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, WorkbenchSpacing.xs)
    }
}

private extension ChatComparisonPresentation.PromptOutcome {
    var color: Color {
        switch self {
        case .finished: WorkbenchColor.success
        case .blocked: WorkbenchColor.failure
        case .tokenLimit, .incomplete: WorkbenchColor.warning
        case .unknown, .notRecorded, .waiting: WorkbenchColor.muted
        }
    }
    var symbol: String {
        switch self {
        case .finished: "checkmark.circle.fill"
        case .blocked: "exclamationmark.circle.fill"
        case .tokenLimit, .incomplete: "exclamationmark.circle"
        case .unknown: "questionmark.circle"
        case .notRecorded: "minus.circle"
        case .waiting: "clock"
        }
    }
}

private struct ChatModelDetailsButton<Actions: View>: View {
    let lane: CompareLane
    let result: VariantResult?
    let run: ComparisonRun
    let name: String
    @ViewBuilder let actions: () -> Actions
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless).foregroundStyle(WorkbenchColor.muted)
            .help("Measurements and actions for \(name)")
            .accessibilityLabel("Details for model \(lane.letter)")
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    Text(name).font(WorkbenchTypography.label).textSelection(.enabled)
                    Text(lane.path).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted).textSelection(.enabled)
                    if let result {
                        if let error = result.error { ErrorBanner(text: error) }
                        ForEach(ComparisonViewLogic.servingDetails(result), id: \.self) { Text($0) }
                        if let prefill = result.aggregatePrefillTokensPerSecond { Text(String(format: "Estimated prefill %.1f tok/s", prefill)) }
                        if let ttft = result.aggregateTTFTSeconds { Text(String(format: "Fastest first token %.2f s", ttft)) }
                        if let score = run.qualityReviews?[result.id]?.score { Text("Your quality rating: \(score)/5") }
                        actions()
                    } else { Text("No measurements recorded yet.") }
                }
                .font(WorkbenchTypography.secondary).padding(WorkbenchSpacing.md)
                .frame(width: WorkbenchSize.detailsPopoverWidth)
            }
    }
}

/// Fenced code keeps its whitespace and a monospaced face. Prose stays readable;
/// no remote content or runtime-generated HTML is evaluated.
struct RecordedAnswerView: View {
    let text: String
    var reading = false

    private var blocks: [(text: String, code: Bool)] {
        var blocks: [(String, Bool)] = [], lines: [String] = [], code = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !lines.isEmpty { blocks.append((lines.joined(separator: "\n"), code)); lines = [] }
                code.toggle()
            } else { lines.append(line) }
        }
        if !lines.isEmpty { blocks.append((lines.joined(separator: "\n"), code)) }
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                Text(block.text)
                    .font(block.code ? WorkbenchTypography.value : reading ? WorkbenchTypography.reading : WorkbenchTypography.body)
                    .lineSpacing(WorkbenchSpacing.xxs).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(block.code ? WorkbenchSpacing.sm : 0)
                    .background(block.code ? WorkbenchColor.surface : Color.clear,
                        in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
            }
        }
    }
}
