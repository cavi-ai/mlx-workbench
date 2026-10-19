import SwiftUI

/// Chat has a reading workspace; media keeps its artifact grid.
struct ChatComparisonResultsView<Actions: View>: View {
    let run: ComparisonRun
    let store: ComparisonOutputStore
    let contentWidth: CGFloat
    let name: (String) -> String
    let onReview: (String, Int?) -> Void
    let reviewError: String?
    @ViewBuilder let laneActions: (CompareLane) -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.lg) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                Text("Model results").font(WorkbenchTypography.section)
                    .help("Completion records whether generation finished. Read the answers to judge quality.")
                VStack(spacing: 0) {
                    ForEach(ComparePresentation.lanes(for: run)) { lane in
                        modelRow(lane)
                        if lane.index < run.variants.count - 1 { Divider() }
                    }
                }
                Text("Median decode includes incomplete outputs. Completion is not a quality score.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            TextComparisonEditor(run: run, store: store, name: name, onReview: onReview,
                reviewError: reviewError, workspaceWidth: contentWidth)
        }
        .accessibilityIdentifier("chat-results-workspace")
    }

    private func modelRow(_ lane: CompareLane) -> some View {
        let result = run.results.first { $0.id == lane.resultKey }
        let completion = result.map { ChatComparisonPresentation.completion($0, in: run) }
        return HStack(alignment: .center, spacing: WorkbenchSpacing.sm) {
            LetterChip(letter: lane.letter)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Text(name(lane.path)).font(WorkbenchTypography.label)
                    .lineLimit(1).help(lane.path)
                if let profile = lane.profileName {
                    Text(profile).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
                if contentWidth < 700 { completionLabel(completion, lane: lane, error: result?.error) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if contentWidth >= 700 {
                completionLabel(completion, lane: lane, error: result?.error).frame(width: 170, alignment: .leading)
            }
            VStack(alignment: .trailing, spacing: WorkbenchSpacing.xxs) {
                Text(result.flatMap { run.metricValue(of: $0) }.map { String(format: "%.1f tok/s", $0) } ?? "—")
                    .font(WorkbenchTypography.label).monospacedDigit()
                if result?.samples.contains(where: { $0.metricsEstimated == true }) == true {
                    Text("Estimated").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
                if contentWidth >= 700 {
                    Text(result?.aggregateTTFTSeconds.map { String(format: "Best first token %.2f s", $0) } ?? "Latency not recorded")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                        .help("Fastest recorded first-token latency; may include reasoning.")
                }
            }.fixedSize()
            ChatModelDetailsButton(lane: lane, result: result, run: run, name: name(lane.path)) {
                laneActions(lane)
            }
        }
        .padding(.vertical, WorkbenchSpacing.xs)
        .accessibilityElement(children: .contain)
    }

    private func completionLabel(_ completion: ChatComparisonPresentation.Completion?, lane: CompareLane, error: String?) -> some View {
        Text(completion?.label ?? (lane.state == .measuring ? "Measuring…" : "Not measured"))
            .font(WorkbenchTypography.metadata)
            .foregroundStyle(error != nil ? WorkbenchColor.failure : completion?.isComplete == true ? WorkbenchColor.muted : WorkbenchColor.warning)
            .fixedSize(horizontal: false, vertical: true)
            .help(error ?? "Finished generation does not establish answer quality.")
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
                    .font(block.code ? WorkbenchTypography.value : WorkbenchTypography.body)
                    .lineSpacing(WorkbenchSpacing.xxs).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(block.code ? WorkbenchSpacing.sm : 0)
                    .background(block.code ? WorkbenchColor.surface : Color.clear,
                        in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
            }
        }
    }
}
