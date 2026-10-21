import AVFoundation
import AVKit
import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ComparisonViewLogic
//
// Pure helpers behind the Compare tab's modes, kept out of the views so they
// can be tested.

enum ComparisonViewLogic {
    static func laneLabel(_ result: VariantResult, run: ComparisonRun, name: (String) -> String) -> String {
        guard result.laneID != nil, let index = run.variantIdentities.firstIndex(of: result.id) else {
            return name(result.modelPath)
        }
        return "\(ComparePresentation.letter(index)) · \(name(result.modelPath))"
    }
    struct OutputClip: Identifiable {
        let modelPath: String
        let url: URL
        var id: String { modelPath }
    }

    static func outputClips(for run: ComparisonRun, store: ComparisonOutputStore, promptID: String,
                            kind: ComparisonOutputKind) -> [OutputClip] {
        guard run.effectiveMode.outputKind == kind else { return [] }
        return run.results.compactMap { result in
            guard result.error == nil,
                  let sample = result.samples.first(where: { $0.promptID == promptID }), sample.error == nil,
                  let url = store.artifactURL(runID: run.id, artifact: sample.artifact ?? "") else { return nil }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue,
                  FileManager.default.isReadableFile(atPath: url.path) else { return nil }
            return OutputClip(modelPath: result.modelPath, url: url)
        }
    }
    enum InputEvidence: Equatable {
        case saved(URL), original(URL), unavailable(String)
        var url: URL? {
            switch self {
            case .saved(let url), .original(let url): return url
            case .unavailable: return nil
            }
        }
        var label: String {
            switch self {
            case .saved: return "Saved input"
            case .original: return "Original file · not saved with run"
            case .unavailable(let message): return message
            }
        }
    }

    static func inputEvidence(for run: ComparisonRun, entry: PromptEntry, store: ComparisonOutputStore) -> InputEvidence {
        if let artifacts = run.inputArtifacts {
            guard let artifact = artifacts[entry.id],
                  let url = store.readableInputArtifactURL(runID: run.id, artifact: artifact) else {
                return .unavailable("Saved input unavailable")
            }
            return .saved(url)
        }
        if let path = entry.inputPath, path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path)
            return ComparisonOutputStore.isReadableRegularFile(url) ? .original(url) : .unavailable("Original input unavailable")
        }
        guard entry.builtinInput != nil, let kind = run.effectiveMode.inputKind else {
            return .unavailable("Input not recorded")
        }
        let ext: String
        switch kind {
        case .image: ext = "png"
        case .video: ext = "mp4"
        case .audio: ext = "wav"
        }
        let artifact = "\(ComparisonOutputStore.safeComponent(entry.id)).\(ext)"
        guard let url = store.readableInputArtifactURL(runID: run.id, artifact: artifact) else {
            return .unavailable("Saved input unavailable")
        }
        return .saved(url)
    }

    struct ListeningClip: Identifiable {
        let modelPath: String
        let promptID: String
        let url: URL
        var id: String { modelPath + "|" + promptID }
    }

    /// Completed generated-audio runs share one A/B transport; review rubrics stay task-specific.
    static func showsListening(_ run: ComparisonRun) -> Bool {
        run.effectiveMode.outputKind == .audio && run.state == .completed
    }

    /// New human judgments require the whole recorded cohort to be inspectable.
    /// This does not erase reviews recorded while an output was still available.
    static func qualityReviewUnavailableReason(_ run: ComparisonRun, modelPath: String, store: ComparisonOutputStore) -> String? {
        guard run.state == .completed else { return "Wait for the comparison to finish before rating quality." }
        guard run.variantIdentities.contains(modelPath), let result = run.results.first(where: { $0.id == modelPath }),
              result.error == nil, ComparisonInsights.fullCohort(result, run: run),
              result.samples.allSatisfy({ $0.error == nil }) else {
            return "A complete, successful set of outputs is needed to rate this model."
        }
        if run.effectiveMode.outputKind != .text {
            for sample in result.samples {
                var isDirectory: ObjCBool = false
                guard let artifact = sample.artifact, let url = store.artifactURL(runID: run.id, artifact: artifact),
                      FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: url.path) else {
                    return "Outputs are unavailable. Saved ratings are retained; generate a new run to rate fresh outputs."
                }
            }
        }
        return nil
    }

    static func audioClips(for run: ComparisonRun, store: ComparisonOutputStore, promptID: String? = nil) -> [ListeningClip] {
        guard run.effectiveMode.outputKind == .audio else { return [] }
        return run.results.filter { $0.error == nil }.flatMap { result in
            result.samples.compactMap { sample in
                guard sample.error == nil, promptID == nil || sample.promptID == promptID,
                      let url = store.artifactURL(runID: run.id, artifact: sample.artifact ?? ""),
                      store.artifactExists(runID: run.id, artifact: sample.artifact) else { return nil }
                return ListeningClip(modelPath: result.modelPath, promptID: sample.promptID, url: url)
            }
        }
    }
    /// Ready models whose task and runtime support the mode.
    static func candidates(from models: [LibraryModel], mode: ComparisonMode) -> [LibraryModel] {
        models.filter { $0.readiness == .ready && mode.supports($0.item) }
    }

    static func promptSets(_ sets: [PromptSet], for mode: ComparisonMode) -> [PromptSet] {
        sets.filter { $0.effectiveMode == mode }
    }

    /// The prompts a run's grid shows: the snapshot the run kept, else a bare entry per sampled prompt id.
    static func rows(for run: ComparisonRun) -> [PromptEntry] {
        if let entries = run.promptEntries, !entries.isEmpty { return entries }
        var seen = Set<String>()
        let ids = run.results.flatMap { $0.samples.map(\.promptID) }.filter { seen.insert($0).inserted }
        return ids.map { PromptEntry(id: $0, text: $0) }
    }

    /// The numbers shown under a result cell: the mode's primary metric, then the rest as one line
    /// that wraps only between metrics (the spaces inside a metric do not break).
    static func metrics(_ sample: ComparisonSample, mode: ComparisonMode) -> (primary: String?, details: String) {
        let primary = mode.primaryMetric.value(of: sample).map(mode.primaryMetric.format)
        var parts: [String] = []
        switch mode {
        case .chat:
            if let ttft = sample.timeToFirstTokenSeconds { parts.append(firstToken(ttft)) }
            if let answer = sample.timeToFirstAnswerSeconds { parts.append(String(format: "answer begins %.2f s", answer)) }
            if let duration = sample.durationSeconds { parts.append(String(format: "total %.2f s", duration)) }
            if let tokens = sample.completionTokens { parts.append("\(tokens) generated tokens") }
            if sample.metricsEstimated == true { parts.append("token count estimated") }
            if let prefill = sample.prefillTokensPerSecond { parts.append(prefillText(prefill)) }
            parts.append(contentsOf: toolCallParts(calls: sample.toolCalls, names: sample.toolNames, usable: sample.toolCallsValid))
        case .vision, .videoUnderstanding:
            if let tokens = sample.generationTokens { parts.append("\(tokens) tokens") }
        case .speechToText:
            if let seconds = sample.seconds, let audio = sample.audioSeconds {
                parts.append(String(format: "%.1f s for %.1f s of audio", seconds, audio))
            }
        case .textToSpeech, .musicGeneration:
            if let audio = sample.audioSeconds { parts.append(String(format: "%.1f s of audio", audio)) }
        case .imageGeneration, .videoGeneration:
            break
        }
        if mode != .speechToText, let seconds = sample.seconds { parts.append(String(format: "%.1f s", seconds)) }
        if let load = sample.loadSeconds { parts.append(String(format: "load %.1f s", load)) }
        if let memory = sample.peakMemoryGB { parts.append(String(format: "%.1f GB peak", memory)) }
        let details = parts.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: " · ")
        return (primary, details)
    }

    static func firstToken(_ seconds: Double) -> String {
        String(format: "first token %.2f s", seconds)
    }

    /// Client TTFT includes work beyond prompt processing; cache evidence may be unavailable.
    static func prefillText(_ tokensPerSecond: Double) -> String {
        String(format: "in ~%.0f tok/s (est.)", tokensPerSecond)
    }

    static func wordErrorText(_ rate: Double) -> String {
        String(format: "%.0f%% word errors", rate * 100)
    }

    /// Tool-call facts for a sample or a whole result; nil `calls` means no tool was offered.
    static func toolCallParts(calls: Int?, names: [String]?, usable: Int?) -> [String] {
        guard let calls else { return [] }
        guard calls > 0 else { return ["No tool calls"] }
        let listed = (names ?? []).isEmpty ? "" : ": " + (names ?? []).joined(separator: ", ")
        var parts = ["\(calls) tool \(calls == 1 ? "call" : "calls")\(listed)"]
        if let usable { parts.append("\(usable) usable") }
        return parts
    }

    /// The lines under a chat lane's number; unmeasured values are left out, never shown as zero.
    static func chatLaneDetails(_ result: VariantResult) -> [String] {
        var lines: [String] = []
        if let prefill = result.aggregatePrefillTokensPerSecond { lines.append(prefillText(prefill)) }
        if let ttft = result.aggregateTTFTSeconds { lines.append(firstToken(ttft)) }
        let speeds = result.samples.compactMap(\.tokensPerSecond)
        if speeds.count >= 2, let low = speeds.min(), let high = speeds.max() {
            lines.append(String(format: "%.1f–%.1f tok/s across %d prompts", low, high, speeds.count))
        }
        if let calls = result.totalToolCalls {
            lines.append(calls == 0 ? "No tool calls"
                : "\(calls) tool \(calls == 1 ? "call" : "calls")" + (result.totalToolCallsValid.map { ", \($0) usable" } ?? ""))
        }
        return lines
    }

    static func servingDetails(_ result: VariantResult) -> [String] {
        var lines = [result.servingEvidence?.summary ?? "Runtime not recorded"]
        if let speculation = result.servingEvidence?.speculation {
            lines.append(speculation ? "Draft-and-verify on" : "Draft-and-verify off")
        }
        if result.servingEvidence?.runtime == "strata" {
            lines.append(result.servingEvidence?.expertMemoryGB.map { String(format: "Expert memory %.2f GB", $0) } ?? "Expert memory automatic")
            if let context = result.servingEvidence?.contextTokens { lines.append("Context capacity \(context) tokens") }
            if result.servingEvidence?.hasCustomOptions == true { lines.append("Custom settings · excluded from default recommendations") }
        }
        if result.servingEvidence?.weightsPreserved == true { lines.append("Original quantized weights") }
        if let seconds = result.startupSeconds { lines.append(String(format: "Server startup %.2f s", seconds)) }
        return lines
    }
}

// MARK: - Results grid

/// The letter identifying a variant, in slot tiles and lane headers alike.
struct LetterChip: View {
    let letter: String

    var body: some View {
        Text(letter)
            .font(WorkbenchTypography.label)
            .foregroundStyle(WorkbenchColor.accent)
            .frame(width: WorkbenchSize.Compare.chip, height: WorkbenchSize.Compare.chip)
            .background(WorkbenchColor.accent.opacity(.fill), in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
    }
}

struct CompareContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Model output clamped to a line limit; a longer answer offers its full selectable text in a popover.
private struct OutputExcerpt: View {
    let text: String
    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    @State private var showsFull = false

    private struct ShownHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private struct FullHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private var isTruncated: Bool { fullHeight > shownHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(text)
                .font(WorkbenchTypography.secondary)
                .lineLimit(WorkbenchSize.Compare.textCellLineLimit)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ShownHeightKey.self, value: proxy.size.height)
                })
                .background(
                    Text(text)
                        .font(WorkbenchTypography.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: FullHeightKey.self, value: proxy.size.height)
                        })
                )
                .onPreferenceChange(ShownHeightKey.self) { shownHeight = $0 }
                .onPreferenceChange(FullHeightKey.self) { fullHeight = $0 }
            if isTruncated {
                Button("Show full output") { showsFull = true }
                    .buttonStyle(.borderless)
                    .font(WorkbenchTypography.secondary)
                    .popover(isPresented: $showsFull) {
                        ScrollView {
                            Text(text)
                                .font(WorkbenchTypography.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(WorkbenchSize.Compare.cellInset)
                        }
                        .frame(width: WorkbenchSize.Compare.detailsPopoverWidth)
                        .frame(maxHeight: WorkbenchSize.Compare.detailsPopoverWidth)
                    }
            }
        }
    }
}

/// Lettered lanes lead the grid; below them one row per prompt, one column per lane,
/// so a letter means the same model down the whole page.
struct MediaRunResultsView<LaneActions: View>: View {
    let run: ComparisonRun
    let store: ComparisonOutputStore
    /// Measured by the owner above the run's identity boundary, so a run switch keeps the width.
    let contentWidth: CGFloat
    let isRouteActive: Bool
    let name: (String) -> String
    let onReview: (String, Int?) -> Void
    let reviewError: String?
    let laneActions: (CompareLane) -> LaneActions

    @State private var preview: PreviewImage?
    @State private var imageInspection: ImageInspectionSelection?
    @State private var videoInspection: ImageInspectionSelection?
    @StateObject private var audio: AudioClipPlayer

    @MainActor
    init(run: ComparisonRun, store: ComparisonOutputStore, contentWidth: CGFloat, isRouteActive: Bool,
         name: @escaping (String) -> String, onReview: @escaping (String, Int?) -> Void,
         audio: AudioClipPlayer? = nil, reviewError: String? = nil,
         @ViewBuilder laneActions: @escaping (CompareLane) -> LaneActions) {
        self.run = run
        self.store = store
        self.contentWidth = contentWidth
        self.isRouteActive = isRouteActive
        self.name = name
        self.onReview = onReview
        self.reviewError = reviewError
        self.laneActions = laneActions
        _audio = StateObject(wrappedValue: audio ?? AudioClipPlayer())
    }

    private var mode: ComparisonMode { run.effectiveMode }
    var body: some View {
        let lanes = ComparePresentation.lanes(for: run)
        let layout = ComparePresentation.gridLayout(contentWidth: contentWidth, laneCount: run.variants.count)
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            if layout.scrolls {
                ScrollView(.horizontal) { grid(lanes: lanes, layout: layout) }
            } else {
                grid(lanes: lanes, layout: layout)
            }
            if mode == .chat, run.state == .completed {
                ComparisonSpeculationSummaryView(run: run)
                ComparisonMemoryTradeoffView(run: run)
            }
            if ComparisonViewLogic.showsListening(run) {
                ComparisonListeningPanel(run: run, store: store, name: name, player: audio)
                    .id(run.id)
            }
            if ComparisonViewLogic.showsImageInspection(run) {
                Button {
                    if let prompt = ComparisonViewLogic.rows(for: run).first {
                        imageInspection = ImageInspectionSelection(promptID: prompt.id, modelPath: nil)
                    }
                } label: { Label("Inspect images", systemImage: "square.split.2x1") }
                .controlSize(.small)
            }
            if ComparisonViewLogic.showsVideoInspection(run) {
                Button {
                    if let prompt = ComparisonViewLogic.rows(for: run).first {
                        videoInspection = ImageInspectionSelection(promptID: prompt.id, modelPath: nil)
                    }
                } label: { Label("Inspect videos", systemImage: "film") }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $preview) { item in ImagePreviewSheet(url: item.url) }
        .sheet(item: $imageInspection) { selection in
            ImageComparisonSheet(run: run, store: store, selection: selection, name: name, onReview: onReview, reviewError: reviewError)
        }
        .sheet(item: $videoInspection) { selection in
            VideoComparisonSheet(run: run, store: store, selection: selection, name: name, onReview: onReview, reviewError: reviewError)
        }
        .onDisappear { audio.stop() }
        .onChange(of: run.id) { _, _ in audio.stop() }
        .onChange(of: isRouteActive) { _, active in
            if !active { audio.stop(); videoInspection = nil }
        }
    }

    private func listeningReview(_ path: String) -> some View {
        let review = run.qualityReviews?[path]
        let score = review?.rubricID == ComparisonQualityReview.musicListeningRubric ? review?.score ?? 0 : 0
        return Picker("Listening quality", selection: Binding(
            get: { score }, set: { onReview(path, $0 == 0 ? nil : $0) }
        )) {
            Text("Not reviewed").tag(0)
            ForEach(1...5, id: \.self) { value in Text(ComparisonQualityReview.musicScoreTitle(value)).tag(value) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("Listening quality for \(name(path))")
        .disabled(!ComparisonViewLogic.audioClips(for: run, store: store).contains { $0.modelPath == path })
        .help(ComparisonQualityReview.musicRubric)
    }

    private func grid(lanes: [CompareLane], layout: ComparePresentation.GridLayout) -> some View {
        let measuredCount = lanes.filter { $0.state == .measured }.count
        return Grid(alignment: .topLeading, horizontalSpacing: WorkbenchSize.Compare.columnSpacing, verticalSpacing: WorkbenchSpacing.sm) {
            GridRow(alignment: .top) {
                captionCell
                    .frame(width: layout.promptWidth, alignment: .leading)
                ForEach(lanes) { lane in
                    laneHeader(lane, measuredCount: measuredCount)
                        .frame(width: layout.laneWidth, alignment: .topLeading)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(ComparisonViewLogic.rows(for: run)) { entry in
                GridRow {
                    promptCell(entry, width: layout.promptWidth)
                    ForEach(lanes) { lane in
                        let result = run.results.first { $0.id == lane.resultKey }
                        resultCell(result?.samples.first { $0.promptID == entry.id }, result: result, lane: lane, layout: layout)
                    }
                }
            }
        }
    }

    private var captionCell: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text("Prompt")
                .font(WorkbenchTypography.label)
                .foregroundStyle(WorkbenchColor.ink)
            Text("\(mode.primaryMetric.title) · \(mode.primaryMetric.higherIsBetter ? "higher" : "lower") is faster")
                .font(WorkbenchTypography.metadata)
                .foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Lane header

    private func laneHeader(_ lane: CompareLane, measuredCount: Int) -> some View {
        let result = run.results.first { $0.id == lane.resultKey }
        let metric = mode.primaryMetric
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                HStack(spacing: WorkbenchSpacing.xs) {
                    LetterChip(letter: lane.letter)
                        .livePulse(lane.state == .measuring && isRouteActive)
                    Spacer(minLength: 0)
                    if lane.isLeader {
                        Label("Fastest", systemImage: "bolt.fill")
                            .font(WorkbenchTypography.label)
                            .foregroundStyle(WorkbenchColor.accent)
                            .lineLimit(1)
                            .fixedSize()
                            .transition(.opacity)
                    }
                }
                .workbenchAnimation(value: lane.isLeader)
                Text(lane.profileName ?? name(lane.path))
                    .font(WorkbenchTypography.emphasis)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(lane.path)
                if lane.profileName != nil {
                    Text(name(lane.path)).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
                if mode == .chat, let result {
                    ForEach(ComparisonViewLogic.servingDetails(result), id: \.self) { line in
                        Text(line)
                            .font(WorkbenchTypography.metadata)
                            .foregroundStyle(WorkbenchColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                laneValue(lane, metric: metric, measuredCount: measuredCount)
                if let result, lane.state == .measured, mode == .chat {
                    ForEach(ComparisonViewLogic.chatLaneDetails(result), id: \.self) { line in
                        Text(line)
                            .font(WorkbenchTypography.secondaryTabular)
                            .foregroundStyle(WorkbenchColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(([ComparePresentation.laneAccessibilityLabel(lane, name: lane.profileName.map { "\($0), \(name(lane.path))" } ?? name(lane.path), metric: metric)]
                + (mode == .chat ? result.map(ComparisonViewLogic.servingDetails) ?? [] : [])).joined(separator: ", "))
            laneActions(lane)
            if mode == .musicGeneration && run.state == .completed {
                listeningReview(lane.path)
            } else if mode != .musicGeneration {
                TaskQualityRating(run: run, modelPath: lane.resultKey, modelName: lane.profileName ?? name(lane.path), store: store, onReview: onReview)
            }
        }
    }

    @ViewBuilder
    private func laneValue(_ lane: CompareLane, metric: ComparisonMetric, measuredCount: Int) -> some View {
        if let value = lane.value, lane.state == .measured {
            let parts = ComparePresentation.splitValue(metric.format(value))
            HStack(alignment: .firstTextBaseline, spacing: WorkbenchSpacing.xxs) {
                Text(parts.number)
                    .font(WorkbenchTypography.display)
                    .foregroundStyle(WorkbenchColor.ink)
                    .lineLimit(1)
                    .fixedSize()
                Text(parts.unit)
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                    .lineLimit(1)
            }
            if let fraction = lane.fraction {
                bar(fraction: fraction, isLeader: lane.isLeader)
            } else if measuredCount == 1 {
                Text("Add a model to rank it")
                    .font(WorkbenchTypography.metadata)
                    .foregroundStyle(WorkbenchColor.muted)
            }
        } else if case .failed(let error) = lane.state {
            FailureNotice(error: error)
        } else if let status = ComparePresentation.laneStatus(lane.state) {
            Text(status)
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.muted)
                .lineLimit(1)
                .help(status)
        }
    }

    /// The lane's share of the fastest lane; the leader fills the track.
    private func bar(fraction: Double, isLeader: Bool) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: WorkbenchRadius.chip).fill(WorkbenchColor.well)
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: WorkbenchRadius.chip)
                    .fill(isLeader ? WorkbenchColor.accent : WorkbenchColor.accent.opacity(.stroke))
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: WorkbenchSize.barHeightCompact)
        .workbenchAnimation(value: Int((fraction * 100).rounded()))
        .accessibilityHidden(true)
    }

    private func promptCell(_ entry: PromptEntry, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if mode == .speechToText {
                Text("Reference transcript").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
            Text(entry.text)
                .font(WorkbenchTypography.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let kind = mode.inputKind {
                let evidence = ComparisonViewLogic.inputEvidence(for: run, entry: entry, store: store)
                Text(entry.inputDisplayName.map { "\(evidence.label) · \($0)" } ?? evidence.label)
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(evidence.url?.path ?? "Inputs are retained with the newest media runs. Older original files may have changed since the run.")
                if let url = evidence.url {
                    switch kind {
                    case .image:
                        ThumbnailView(url: url, size: CGSize(width: WorkbenchSize.Compare.inputThumbnail, height: WorkbenchSize.Compare.inputThumbnail)) {
                            preview = PreviewImage(url: url)
                        }
                    case .audio: AudioClipButton(url: url, label: "Play input", player: audio)
                    case .video: ClipVideoView(url: url).frame(width: width, height: width * 9 / 16)
                    }
                }
            }
            if let keywords = entry.expectedKeywords, !keywords.isEmpty {
                Text("Expected words: \(keywords.joined(separator: ", "))")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("All listed checks must match. A | separates alternatives; matching ignores case and checks for text presence, not task quality.")
            }
        }
        .padding(.vertical, WorkbenchSize.Compare.cellInset)
        .frame(width: width, alignment: .leading)
    }

    /// A card that fills its row's height, so the cards of one prompt line up top and bottom.
    private func resultCell(_ sample: ComparisonSample?, result: VariantResult?, lane: CompareLane, layout: ComparePresentation.GridLayout) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if let sample {
                if let error = sample.error {
                    FailureNotice(error: error)
                } else {
                    outputView(sample, modelPath: lane.path, side: layout.mediaSide)
                    metrics(sample)
                    if mode == .chat, result?.servingEvidence?.runtime == "strata" || sample.draftTokens != nil {
                        ComparisonDraftTokenEvidenceView(evidence: sample.draftTokens)
                    }
                    if mode == .chat, result?.servingEvidence?.runtime == "strata" || sample.promptProcessing != nil {
                        ComparisonPromptProcessingEvidenceView(evidence: sample.promptProcessing)
                    }
                }
            } else if ComparePresentation.showsNotRun(sample: sample, result: result) {
                Text("Not run").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            } else {
                Text(pendingText(lane.state)).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
        }
        .padding(WorkbenchSize.Compare.cellInset)
        .frame(width: layout.laneWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WorkbenchColor.canvas, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
    }

    private func pendingText(_ state: CompareLane.State) -> String {
        switch state {
        case .measuring: return "Measuring…"
        case .waiting: return "Waiting"
        case .notMeasured: return "Not measured"
        case .measured, .noMeasurement, .failed: return "No output"
        }
    }

    private func metrics(_ sample: ComparisonSample) -> some View {
        let metrics = ComparisonViewLogic.metrics(sample, mode: mode)
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            if let primary = metrics.primary {
                Text(primary).font(WorkbenchTypography.emphasis.monospacedDigit())
            }
            if !metrics.details.isEmpty {
                Text(metrics.details)
                    .font(WorkbenchTypography.secondary.monospacedDigit())
                    .foregroundStyle(WorkbenchColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func outputView(_ sample: ComparisonSample, modelPath: String, side: CGFloat) -> some View {
        switch mode.outputKind {
        case .text:
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                if let status = sample.completionDescription {
                    Text(status).font(WorkbenchTypography.metadata)
                        .foregroundStyle(sample.hasCompletedAnswer ? WorkbenchColor.muted : WorkbenchColor.warning)
                }
                let answer = sample.fullOutput ?? sample.outputExcerpt
                OutputExcerpt(text: answer.isEmpty && sample.reasoningText != nil ? "No answer text" : answer)
                if let reasoning = sample.reasoningText, !reasoning.isEmpty {
                    DisclosureGroup("Reasoning") { OutputExcerpt(text: reasoning) }
                }
                badge(sample)
            }
        case .image, .audio, .video:
            if let url = store.artifactURL(runID: run.id, artifact: sample.artifact ?? ""),
               FileManager.default.fileExists(atPath: url.path) {
                switch mode.outputKind {
                case .image:
                    ThumbnailView(url: url, size: CGSize(width: side, height: side)) {
                        if ComparisonViewLogic.showsImageInspection(run) {
                            imageInspection = ImageInspectionSelection(promptID: sample.promptID, modelPath: modelPath)
                        } else { preview = PreviewImage(url: url) }
                    }
                case .audio: AudioClipButton(url: url, label: sample.audioSeconds.map { String(format: "Play · %.1f s", $0) } ?? "Play", player: audio)
                default:
                    if ComparisonViewLogic.showsVideoInspection(run) {
                        Button {
                            videoInspection = ImageInspectionSelection(promptID: sample.promptID, modelPath: modelPath)
                        } label: {
                            VStack(spacing: WorkbenchSpacing.xs) {
                                ClipVideoView(url: url, controlsStyle: .none).allowsHitTesting(false)
                                    .frame(width: side, height: side * 9 / 16)
                                Label("Inspect video", systemImage: "film").font(WorkbenchTypography.metadata)
                            }
                        }.buttonStyle(.plain)
                    } else { ClipVideoView(url: url).frame(width: side, height: side * 9 / 16) }
                }
            } else {
                Label("output pruned", systemImage: "trash.slash")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
        }
    }

    @ViewBuilder
    private func badge(_ sample: ComparisonSample) -> some View {
        if let matched = sample.keywordsMatched {
            Label(matched ? "Keywords matched" : "Keywords missing",
                  systemImage: matched ? "checkmark.circle" : "xmark.circle")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(matched ? WorkbenchColor.success : WorkbenchColor.warning)
        } else if let rate = sample.wordErrorRate {
            Label(ComparisonViewLogic.wordErrorText(rate),
                  systemImage: rate <= SpeechCanary.maxWordErrorRate ? "checkmark.circle" : "xmark.circle")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(rate <= SpeechCanary.maxWordErrorRate ? WorkbenchColor.success : WorkbenchColor.warning)
        }
    }
}

struct ComparisonDraftTokenEvidenceView: View {
    let evidence: DraftTokenEvidence?

    static func description(_ evidence: DraftTokenEvidence?) -> String {
        guard let evidence, evidence.isValid else { return "Draft counts not reported" }
        guard let fraction = evidence.acceptanceFraction else { return "Server reported 0 draft tokens" }
        return "\(evidence.accepted) of \(evidence.offered) draft tokens accepted · \(String(format: "%.1f%%", fraction * 100))"
    }

    var body: some View {
        Text(Self.description(evidence)).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            .fixedSize(horizontal: false, vertical: true)
            .help("Server-reported draft counts for this request. Compare answer quality and measured latency separately.")
    }
}

struct ComparisonPromptProcessingEvidenceView: View {
    let evidence: PromptProcessingEvidence?

    static func description(_ evidence: PromptProcessingEvidence?) -> String {
        guard let evidence, evidence.isValid else { return "Prompt cache and server timing not reported" }
        let clock = String(format: "server prompt time %.3f s", evidence.processingSeconds)
        if evidence.processedTokens == 0 { return "No new prompt tokens · \(evidence.cachedTokens) cached · " + clock }
        let work = "\(evidence.processedTokens) new prompt tokens · \(evidence.cachedTokens) cached"
        if let rate = evidence.tokensPerSecond { return work + " · " + String(format: "server prefill %.1f tok/s · ", rate) + clock }
        return work + " · " + clock + " · rate unavailable"
    }

    var body: some View {
        Text(Self.description(evidence)).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            .fixedSize(horizontal: false, vertical: true)
            .help("Server-reported new and cached input tokens and prompt-processing time. Client first-token latency includes other work.")
    }
}

struct ComparisonSpeculationSummaryView: View {
    let run: ComparisonRun

    private func label(_ lane: ComparisonLaneConfiguration) -> String {
        let recorded = ComparePresentation.lanes(for: run).first { $0.resultKey == lane.id }
        return "Lane \(recorded?.letter ?? lane.id)" + (lane.servingProfileName.map { " · \($0)" } ?? "")
    }
    private func review(_ id: String) -> String {
        guard let review = run.qualityReviews?[id], review.rubricID == ComparisonQualityReview.taskOutcomeRubric,
              (1...5).contains(review.score) else { return "Not reviewed" }
        return ComparisonQualityReview.taskScoreTitle(review.score)
    }

    var body: some View {
        let pairs = SpeculationComparison.summaries(in: run)
        if !pairs.isEmpty {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                Text("Paired speculation observations").font(WorkbenchTypography.cardTitle)
                ForEach(pairs) { pair in
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                        Text("Expert memory \(pair.off.strataOptions?.expertMemoryGB.map { "\($0.formatted()) GB" } ?? "automatic") · \(pair.off.strataOptions?.contextTokens ?? 0) context tokens")
                            .font(WorkbenchTypography.label)
                        Text("Off: \(label(pair.off)) · On: \(label(pair.on))")
                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
                        if let reason = pair.unavailableReason {
                            Text("Paired summary unavailable: \(reason)").font(WorkbenchTypography.secondary).fixedSize(horizontal: false, vertical: true)
                        } else if let ratio = pair.medianDecodeRatio, let off = pair.offAnswerSeconds, let on = pair.onAnswerSeconds {
                            LabeledContent("Median client decode-rate ratio, on / off", value: String(format: "%.2f×", ratio))
                            LabeledContent("Median answer start, off / on", value: String(format: "%.2f s / %.2f s", off, on))
                            Text("\(pair.rows.count) paired \(pair.rows.count == 1 ? "prompt" : "prompts") · matching cache work and generation counts")
                                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                            DisclosureGroup("Per-prompt observations") {
                                ForEach(pair.rows) { row in
                                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                                        Text(run.promptEntries?.first { $0.id == row.id }?.text ?? row.id).font(WorkbenchTypography.secondary).lineLimit(2)
                                        Text(String(format: "Off %.1f tok/s · On %.1f tok/s · %.2f×", row.offRate, row.onRate, row.decodeRatio))
                                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                                    }
                                }
                            }
                        }
                        Text("Task ratings · Off: \(review(pair.off.id)) · On: \(review(pair.on.id))")
                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("A ratio above 1 means higher recorded client decode throughput with speculation on. These are sequential observations; system load can vary. Inspect answers and task ratings before choosing settings. This summary does not select or verify a profile.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ComparisonMemoryTradeoffView: View {
    let run: ComparisonRun
    @State private var headroomGoalGB = 8.0

    private var lanes: [CompareLane] { ComparePresentation.lanes(for: run) }
    private func result(_ lane: CompareLane) -> VariantResult? { run.results.first { $0.id == lane.resultKey } }
    private func memory(_ lane: CompareLane) -> SystemMemoryEvidence? {
        guard let evidence = result(lane)?.systemMemory, evidence.isValid else { return nil }
        return evidence
    }
    private var objective: StrataSettingsSearchObjective { run.settingsSearchGoal?.effectiveObjective ?? .firstAnswer }
    private func seconds(_ lane: CompareLane) -> Double? { result(lane).flatMap { objective.seconds(in: $0) } }
    private var measured: [CompareLane] { lanes.filter { memory($0) != nil && seconds($0) != nil } }
    private var maximumGB: Double { max(1, lanes.compactMap { memory($0).map { Double($0.totalBytes) / 1e9 } }.max() ?? 128) }
    private func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Memory and answer latency").font(WorkbenchTypography.cardTitle)
            if let goal = run.settingsSearchGoal {
                Text("Recorded search target: \(goal.contextTokens) context tokens · \(goal.headroomGB.formatted()) GB headroom")
                    .font(WorkbenchTypography.secondary)
                Text("Latency objective: \(objective.title)").font(WorkbenchTypography.secondary)
                Text(goal.warmEachPrompt == true
                    ? "Prompt warm-up: one-token request before each measured prompt; warm-up responses excluded."
                    : "Prompt warm-up: shared warm-up request only.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
                if let id = run.settingsSearchCandidateID, let lane = lanes.first(where: { $0.resultKey == id }) {
                    Text("Fastest observed qualifying \(objective.title.lowercased()): lane \(lane.letter). Save this lane as a serving profile and verify it before serving.")
                        .font(WorkbenchTypography.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No qualifying suggestion. \(run.settingsSearchAssessment.unavailableReason ?? "Review the recorded comparison evidence.")")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("System headroom is an estimate sampled during startup, warm-up and prompts. Other apps and file caching affect it; it is not model-only RAM use or a guaranteed peak.")
                .fixedSize(horizontal: false, vertical: true)
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            Text("Engine allocation: not reported.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            if !measured.isEmpty {
                Text("Explore minimum headroom: \(headroomGoalGB.formatted(.number.precision(.fractionLength(1)))) GB")
                    .font(WorkbenchTypography.secondary)
                Slider(value: $headroomGoalGB, in: 0...maximumGB, step: 0.5)
                    .accessibilityLabel("Observed headroom target in gigabytes")
                Chart(measured) { lane in
                    if let memory = memory(lane), let seconds = seconds(lane) {
                        PointMark(x: .value("Headroom", Double(memory.minimumAvailableBytes) / 1e9), y: .value("Answer latency", seconds))
                            .foregroundStyle(Double(memory.minimumAvailableBytes) / 1e9 >= headroomGoalGB ? WorkbenchColor.accent : WorkbenchColor.muted)
                            .annotation(position: .top) { Text(lane.letter).font(WorkbenchTypography.label) }
                    }
                }
                .chartXAxisLabel("Lowest sampled system headroom (GB)")
                .chartYAxisLabel(objective.axisLabel)
                .frame(height: 220)
                Text("Points require a finished answer and answer timing for every prompt. Completion does not establish answer quality; use the recorded answers and task ratings.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
            ForEach(lanes) { lane in
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                    Text("Lane \(lane.letter)").font(WorkbenchTypography.label)
                    if let evidence = memory(lane) {
                        Text("Headroom: \(gb(evidence.baselineAvailableBytes)) before start · \(gb(evidence.minimumAvailableBytes)) sampled minimum · \(gb(evidence.endingAvailableBytes)) before cleanup")
                        Text("\(evidence.sampleCount) readings · \(evidence.missedSamples) unavailable · 0.5 s sampling interval")
                        if seconds(lane) != nil {
                            Text(Double(evidence.minimumAvailableBytes) / 1e9 >= headroomGoalGB ? "Observed minimum meets the selected target." : "Observed minimum is below the selected target.")
                        }
                    } else { Text("System headroom not recorded.") }
                    if let seconds = seconds(lane) {
                        Text("\(objective.title): median \(String(format: "%.2f s", seconds))")
                    } else { Text("Answer latency unavailable for a complete prompt cohort.") }
                }.font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
        }.lineLimit(nil).padding(WorkbenchSpacing.md)
            .background(WorkbenchColor.canvas, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
    }
}

/// A compact explicit human judgment, independent of the speed and validation badges.
struct TaskQualityRating: View {
    let run: ComparisonRun
    let modelPath: String
    let modelName: String
    let store: ComparisonOutputStore
    let onReview: (String, Int?) -> Void

    private var score: Int? {
        guard let review = run.qualityReviews?[modelPath], review.rubricID == ComparisonQualityReview.taskOutcomeRubric,
              (1...5).contains(review.score) else { return nil }
        return review.score
    }

    var body: some View {
        let unavailable = ComparisonViewLogic.qualityReviewUnavailableReason(run, modelPath: modelPath, store: store)
        Menu {
            ForEach(1...5, id: \.self) { value in
                Button {
                    guard ComparisonViewLogic.qualityReviewUnavailableReason(run, modelPath: modelPath, store: store) == nil else { return }
                    onReview(modelPath, value)
                } label: {
                    if score == value { Label(ComparisonQualityReview.taskScoreTitle(value), systemImage: "checkmark") }
                    else { Text(ComparisonQualityReview.taskScoreTitle(value)) }
                }
                .disabled(unavailable != nil)
            }
            if score != nil {
                Divider()
                Button("Clear rating") { onReview(modelPath, nil) }
            }
            if let unavailable { Text(unavailable) }
        } label: {
            Label(score.map { "Quality · \($0)/5" } ?? "Rate quality", systemImage: score == nil ? "star" : "star.fill")
                .font(WorkbenchTypography.metadata)
                .foregroundStyle(score == nil ? WorkbenchColor.muted : WorkbenchColor.accent)
        }
        .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
        .disabled(run.state != .completed)
        .accessibilityLabel("Task quality for \(modelName)")
        .accessibilityValue(score.map { "\($0) out of 5" } ?? "Not reviewed")
        .help([ComparisonQualityReview.taskGuidance(for: run.effectiveMode), ComparisonQualityReview.rubric,
               "Judge all prompts in this run. Speed and automated checks do not establish task quality.", unavailable]
            .compactMap { $0 }.joined(separator: " "))
    }
}

struct PreviewImage: Identifiable {
    let url: URL
    var id: String { url.path }
}

// MARK: - Cells

/// An image file fitted into a fixed box; click opens the larger view. The box keeps its size while
/// the file loads, so the grid does not jump.
struct ThumbnailView: View {
    let url: URL
    let size: CGSize
    let onOpen: () -> Void
    @State private var image: NSImage?
    @State private var loaded = false

    var body: some View {
        ZStack {
            WorkbenchColor.surface
            if let image {
                Button(action: onOpen) {
                    Image(nsImage: image).resizable().scaledToFit()
                }
                .buttonStyle(.plain)
                .help("Open larger")
            } else if loaded {
                Text("Image unavailable").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
        .task(id: url) {
            loaded = false
            image = await MediaImageLoader.load(url)
            loaded = true
        }
    }
}

struct ImagePreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: WorkbenchSpacing.sm) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(minWidth: 480, minHeight: 480)
            } else if loaded {
                Text("Image unavailable").font(WorkbenchTypography.body)
            } else {
                ProgressView().frame(minWidth: 480, minHeight: 480)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(WorkbenchSpacing.pageInset)
        .frame(minWidth: 520, minHeight: 560)
        .task(id: url) {
            loaded = false
            image = await MediaImageLoader.load(url)
            loaded = true
        }
    }
}

/// Decodes a saved output image off the main actor; full-size PNGs from image models are large.
enum MediaImageLoader {
    static func load(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
    }
}

/// One transport for the run. Switching variants keeps elapsed seconds,
/// clamped to the shorter clip; separately generated phrases need not align.
struct ComparisonListeningPanel: View {
    let run: ComparisonRun
    let store: ComparisonOutputStore
    let name: (String) -> String
    @ObservedObject var player: AudioClipPlayer
    @State private var promptID: String
    @State private var leftPath: String?
    @State private var rightPath: String?

    init(run: ComparisonRun, store: ComparisonOutputStore, name: @escaping (String) -> String, player: AudioClipPlayer) {
        self.run = run; self.store = store; self.name = name; self.player = player
        let prompt = ComparisonViewLogic.rows(for: run).first?.id ?? ""
        let clips = ComparisonViewLogic.audioClips(for: run, store: store, promptID: prompt)
        _promptID = State(initialValue: prompt)
        _leftPath = State(initialValue: clips.first?.modelPath)
        _rightPath = State(initialValue: clips.dropFirst().first?.modelPath)
    }

    private var clips: [ComparisonViewLogic.ListeningClip] {
        ComparisonViewLogic.audioClips(for: run, store: store, promptID: promptID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack(spacing: WorkbenchSpacing.sm) {
                Label("A/B listening", systemImage: "headphones").font(WorkbenchTypography.emphasis)
                Spacer()
                if ComparisonViewLogic.rows(for: run).count > 1 {
                    Picker("Prompt", selection: $promptID) {
                        ForEach(ComparisonViewLogic.rows(for: run)) { entry in
                            Text(entry.text).lineLimit(1).tag(entry.id)
                        }
                    }.frame(maxWidth: 320).controlSize(.small)
                }
            }
            if clips.isEmpty {
                Text("Audio for this prompt is unavailable.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: WorkbenchSpacing.md) { choices }
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) { choices }
                }
                HStack(spacing: WorkbenchSpacing.sm) {
                    Button {
                        if let url = player.activeURL { player.toggle(url) }
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(player.activeURL == nil)
                    .accessibilityLabel(player.isPlaying ? "Pause listening" : "Resume listening")
                    Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }),
                           in: 0...max(player.duration, 0.001))
                        .disabled(player.activeURL == nil)
                        .accessibilityLabel("Listening position")
                    Text("\(clock(player.position)) / \(clock(player.duration))")
                        .font(WorkbenchTypography.secondary.monospacedDigit())
                        .foregroundStyle(WorkbenchColor.muted)
                    Button("Reset") { player.seek(to: 0) }
                        .controlSize(.small).disabled(player.activeURL == nil)
                }
                if let clip = clips.first(where: { $0.url == player.activeURL }) {
                    Text("\(player.isPlaying ? "Playing" : "Paused") · \(name(clip.modelPath))")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
            }
            if let failure = player.failure {
                Text(failure).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
            }
            if run.effectiveMode == .textToSpeech {
                Text("Switching preserves elapsed time. Different speaking rates mean words may not align.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
        }
        .padding(WorkbenchSpacing.sm)
        .background(WorkbenchColor.canvas, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
        .onChange(of: promptID) { _, _ in
            if !clips.contains(where: { $0.url == player.activeURL }) { player.stop() }
            if !clips.contains(where: { $0.modelPath == leftPath }) { leftPath = clips.first?.modelPath }
            if !clips.contains(where: { $0.modelPath == rightPath }) || leftPath == rightPath {
                rightPath = clips.first(where: { $0.modelPath != leftPath })?.modelPath
            }
        }
        .onChange(of: player.activeURL) { _, url in
            guard let clip = ComparisonViewLogic.audioClips(for: run, store: store).first(where: { $0.url == url }) else { return }
            promptID = clip.promptID
            if leftPath != clip.modelPath, rightPath != clip.modelPath { leftPath = clip.modelPath }
        }
    }

    @ViewBuilder private var choices: some View {
        choice("A", path: $leftPath, excluding: rightPath)
        choice("B", path: $rightPath, excluding: leftPath)
    }

    private func choice(_ title: String, path: Binding<String?>, excluding: String?) -> some View {
        let clip = clips.first { $0.modelPath == path.wrappedValue }
        let selected = clip != nil && clip?.url == player.activeURL
        return HStack(spacing: WorkbenchSpacing.xs) {
            Button {
                if let clip {
                    player.select(clip.url, preservingPosition: true,
                                  autoplay: player.activeURL == nil || player.isPlaying)
                }
            } label: {
                Label("Listen \(title)", systemImage: selected ? "checkmark" : "play.fill")
                    .foregroundStyle(selected ? WorkbenchColor.accent : WorkbenchColor.ink)
            }
            .buttonStyle(.bordered).controlSize(.small).disabled(clip == nil)
            .help(run.effectiveMode == .textToSpeech
                ? "Switch at the same elapsed time; shorter clips clamp to their end. Spoken words may not align."
                : "Switch at the same elapsed time; shorter clips clamp to their end. Generated musical phrases may differ.")
            Picker(title, selection: path) {
                Text("Choose model…").tag(String?.none)
                ForEach(clips.filter { $0.modelPath != excluding }) { candidate in
                    Text(name(candidate.modelPath)).tag(String?.some(candidate.modelPath))
                }
            }.labelsHidden().frame(minWidth: 120, maxWidth: 260).controlSize(.small)
        }
    }

    private func clock(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

/// A video file with transport controls; it never starts on its own.
/// AppKit's player view, not SwiftUI's `VideoPlayer`: referencing `AVPlayerView` links AVKit,
/// and without AVKit loaded the `VideoPlayer` overlay aborts while building its type metadata.
struct ClipVideoView: NSViewRepresentable {
    let url: URL
    var controlsStyle: AVPlayerViewControlsStyle = .inline

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = controlsStyle
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
    }
}
