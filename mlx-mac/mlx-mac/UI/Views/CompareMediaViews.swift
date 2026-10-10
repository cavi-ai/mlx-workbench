import AVFoundation
import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ComparisonViewLogic
//
// Pure helpers behind the Compare tab's modes, kept out of the views so they
// can be tested.

enum ComparisonViewLogic {
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
        guard run.variants.contains(modelPath), let result = run.results.first(where: { $0.modelPath == modelPath }),
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
    /// Ready models whose task type the mode accepts.
    static func candidates(from models: [LibraryModel], mode: ComparisonMode) -> [LibraryModel] {
        models.filter { $0.readiness == .ready && mode.accepts($0.item.task?.type) }
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

    /// Prompt tokens over first-token time is a lower bound, so it always reads as an estimate.
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
                        let result = run.results.first { $0.modelPath == lane.path }
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
        let result = run.results.first { $0.modelPath == lane.path }
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
                Text(name(lane.path))
                    .font(WorkbenchTypography.emphasis)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(lane.path)
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
            .accessibilityLabel(ComparePresentation.laneAccessibilityLabel(lane, name: name(lane.path), metric: metric))
            laneActions(lane)
            if mode == .musicGeneration && run.state == .completed {
                listeningReview(lane.path)
            } else if mode != .musicGeneration {
                TaskQualityRating(run: run, modelPath: lane.path, modelName: name(lane.path), store: store, onReview: onReview)
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
        .background(WorkbenchColor.canvas)
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
                OutputExcerpt(text: sample.fullOutput ?? sample.outputExcerpt)
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

@MainActor
protocol AudioClipPlayback: AnyObject {
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: AudioClipPlayback {}

@MainActor
final class AudioClipPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var activeURL: URL?
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var failure: String?
    @Published private(set) var failureURL: URL?
    private var player: AudioClipPlayback?
    private var timer: Timer?
    private let makePlayer: (URL) throws -> AudioClipPlayback

    init(makePlayer: @escaping (URL) throws -> AudioClipPlayback = { try AVAudioPlayer(contentsOf: $0) }) {
        self.makePlayer = makePlayer
        super.init()
    }

    func toggle(_ url: URL) {
        if activeURL == url, let player {
            if isPlaying { pause() }
            else {
                if position >= duration { player.currentTime = 0; position = 0 }
                play()
            }
            return
        }
        select(url)
    }

    /// A/B compares elapsed seconds, without implying musical phrase alignment.
    func select(_ url: URL, preservingPosition: Bool = false, autoplay: Bool = true) {
        let elapsed = preservingPosition ? (player?.currentTime ?? position) : 0
        stop()
        do {
            let next = try makePlayer(url)
            guard next.duration.isFinite, next.duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
            if let native = next as? AVAudioPlayer { native.delegate = self }
            player = next
            activeURL = url
            duration = next.duration
            seek(to: elapsed)
            if autoplay, position < duration { play() }
        } catch {
            failure = AppHost.render(error)
            failureURL = url
        }
    }

    private func play() {
        guard let player else { return }
        isPlaying = player.play()
        if !isPlaying { failure = "Audio playback could not start."; failureURL = activeURL; return }
        failure = nil
        failureURL = nil
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.position = min(max(player.currentTime, 0), self.duration)
            }
        }
    }

    func pause() {
        player?.pause()
        position = min(max(player?.currentTime ?? position, 0), duration)
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite, let player else { return }
        position = min(max(seconds, 0), duration)
        player.currentTime = position
        if position >= duration { pause() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
        activeURL = nil
        position = 0
        duration = 0
        failure = nil
        failureURL = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.timer?.invalidate()
            self.timer = nil
            self.position = self.duration
            self.isPlaying = false
            if !flag { self.failure = "Audio playback ended unexpectedly." }
        }
    }
}

struct AudioClipButton: View {
    let url: URL
    let label: String
    @ObservedObject var player: AudioClipPlayer

    private var selected: Bool { player.activeURL == url }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Button { player.toggle(url) } label: {
                Label(selected && player.isPlaying ? "Pause" : label, systemImage: selected && player.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if selected || player.failureURL == url, let failure = player.failure {
                Text(failure).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
            }
        }
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
        .background(WorkbenchColor.canvas)
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

// MARK: - Media prompt sets

struct ComparisonPromptCancelButton: View {
    let requiresConfirmation: Bool
    let onDismiss: () -> Void
    @State private var confirmingDiscard = false

    var body: some View {
        Group {
            if confirmingDiscard && requiresConfirmation {
                HStack(spacing: WorkbenchSpacing.sm) {
                    Button("Keep editing") { confirmingDiscard = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Discard changes", role: .destructive, action: onDismiss)
                        .help("Close without keeping these draft changes.")
                }
                .controlSize(.small)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Unsaved prompt changes")
            } else {
                Button("Cancel") {
                    if requiresConfirmation { confirmingDiscard = true }
                    else { onDismiss() }
                }.keyboardShortcut(.cancelAction)
            }
        }
        .onChange(of: requiresConfirmation) { _, required in
            if !required { confirmingDiscard = false }
        }
    }
}

struct ComparisonPromptSetEditor: View {
    @State var draft: ComparisonPromptSetDraft
    let onSave: (ComparisonPromptSetDraft) async -> String?
    @State private var checkpoint: ComparisonPromptDraftCheckpoint<ComparisonPromptSetDraft.Prompt>
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(draft: ComparisonPromptSetDraft, onSave: @escaping (ComparisonPromptSetDraft) async -> String?) {
        _draft = State(initialValue: draft)
        _checkpoint = State(initialValue: ComparisonPromptDraftCheckpoint(name: draft.name, prompts: draft.prompts))
        self.onSave = onSave
    }

    private var hasUnsavedChanges: Bool {
        draft.original != nil ? draft.hasChanges : checkpoint.hasChanges(name: draft.name, prompts: draft.prompts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Label("\(draft.original == nil ? "New" : "Edit") \(draft.mode.title.lowercased()) prompt set",
                  systemImage: "slider.horizontal.3").font(WorkbenchTypography.cardTitle)
            if draft.original == nil {
                ComparisonPromptSetNameField(name: $draft.name)
            } else {
                Text(draft.name).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            ComparisonPromptFields(draft: $draft)
            if draft.mode.inputKind != nil {
                Text("Saving keeps input copies with this set. Unchanged saved files are reused.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
            Text(draft.mode == .videoGeneration
                ? "Blank settings use runtime defaults. Each model checks its size alignment and frame grouping when run. Saving does not generate output."
                : "Settings apply to each prompt. Saving does not run a comparison; past runs keep their recorded inputs and outputs.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            ErrorBanner(text: error)
            if saving {
                HStack(spacing: WorkbenchSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Saving prompt set and input copies…").font(WorkbenchTypography.metadata)
                }
            }
            HStack {
                Button { draft.addPrompt() } label: { Label("Add prompt", systemImage: "plus") }
                if draft.original != nil {
                    Button("Revert changes") { draft.revertChanges(); error = nil }
                        .buttonStyle(.borderless).disabled(!draft.hasChanges)
                        .help("Restore the set as it was when this editor opened.")
                }
                Spacer()
                ComparisonPromptCancelButton(requiresConfirmation: hasUnsavedChanges) { dismiss() }
                Button(draft.original == nil ? "Save prompt set" : "Save changes") {
                    let copy = draft
                    saving = true
                    Task { @MainActor in
                        error = await onSave(copy)
                        saving = false
                        if error == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent).tint(WorkbenchColor.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.validationError != nil || !draft.hasChanges)
                .help(draft.hasChanges ? "Save this prompt set." : "No changes to save.")
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: WorkbenchSize.Compare.promptEditorWidth)
        .disabled(saving)
        .interactiveDismissDisabled(saving || hasUnsavedChanges)
    }

    /// The open panel, filtered to the kind of file the mode takes.
    static func pick(_ kind: ComparisonMediaKind) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        switch kind {
        case .image: panel.allowedContentTypes = [.png, .jpeg, .webP]
        case .video: panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        case .audio: panel.allowedContentTypes = [.wav, .mp3]
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

enum ComparisonPromptScrollLogic {
    struct Anchor: Hashable { let promptID: String }
    struct Issue: Equatable {
        let promptID: String
        let number: Int
        let message: String
    }

    static func firstIssue<Prompt: Identifiable>(in prompts: [Prompt],
        error: (Prompt) -> String?) -> Issue? where Prompt.ID == String {
        guard prompts.count > 1 else { return nil }
        for (index, prompt) in prompts.enumerated() {
            if let message = error(prompt) {
                return Issue(promptID: prompt.id, number: index + 1, message: message)
            }
        }
        return nil
    }

    static func insertedID(before: [String], after: [String]) -> String? {
        let previous = Set(before)
        return after.first { !$0.isEmpty && !previous.contains($0) }
    }
}

struct ComparisonPromptList<Content: View>: View {
    let promptIDs: [String]
    let maximumHeight: CGFloat
    let issue: ComparisonPromptScrollLogic.Issue?
    let content: Content

    init(promptIDs: [String], maximumHeight: CGFloat = WorkbenchSize.Compare.promptEditorHeight,
         issue: ComparisonPromptScrollLogic.Issue? = nil, @ViewBuilder content: () -> Content) {
        self.promptIDs = promptIDs; self.maximumHeight = maximumHeight
        self.issue = issue; self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                ScrollView { content }
                    .onChange(of: promptIDs) { before, after in
                        if let id = ComparisonPromptScrollLogic.insertedID(before: before, after: after) {
                            proxy.scrollTo(ComparisonPromptScrollLogic.Anchor(promptID: id), anchor: .top)
                        }
                    }
                if let issue {
                    Button {
                        proxy.scrollTo(ComparisonPromptScrollLogic.Anchor(promptID: issue.promptID), anchor: .top)
                    } label: {
                        Label("Fix prompt \(issue.number)", systemImage: "exclamationmark.circle")
                            .font(WorkbenchTypography.label)
                            .foregroundStyle(WorkbenchColor.warning)
                    }
                    .buttonStyle(.borderless)
                    .help(issue.message)
                    .accessibilityHint(issue.message)
                }
            }
        }.frame(maxHeight: maximumHeight)
    }
}

/// The same cards are used for new sets, saved-set edits and recorded-run reuse.
struct ComparisonPromptFields: View {
    @Binding var draft: ComparisonPromptSetDraft
    @StateObject private var audio = AudioClipPlayer()

    var body: some View {
        ComparisonPromptList(promptIDs: draft.prompts.map(\.id),
            issue: ComparisonPromptScrollLogic.firstIssue(in: draft.prompts) { $0.validationError(for: draft.mode) }) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                ForEach($draft.prompts) { $prompt in
                    ComparisonPromptCard(prompt: $prompt, mode: draft.mode,
                        number: (draft.prompts.firstIndex { $0.id == prompt.id } ?? 0) + 1,
                        canRemove: draft.prompts.count > 1,
                        canMoveUp: draft.prompts.first?.id != prompt.id,
                        canMoveDown: draft.prompts.last?.id != prompt.id,
                        audio: audio,
                        onDuplicate: { draft.duplicatePrompt(id: prompt.id) },
                        onMove: { draft.movePrompt(id: prompt.id, direction: $0) },
                        onRemove: { draft.removePrompt(id: prompt.id) })
                        .id(ComparisonPromptScrollLogic.Anchor(promptID: prompt.id))
                }
            }
        }
        .onDisappear { audio.stop() }
    }
}

struct ComparisonPromptSetNameField: View {
    @Binding var name: String
    var placeholder = "Set name"
    var accessibilityName = "Prompt set name"
    var showInitialError = false
    @State private var edited = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(accessibilityName)
            if let message = PromptSetNameValidation.error(for: name),
               showInitialError || edited || !name.isEmpty {
                ComparisonDraftValidationMessage(message: message)
            }
        }
        .onChange(of: name) { _, _ in edited = true }
    }
}

private struct ComparisonDraftValidationMessage: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ComparisonPromptActions: View {
    let number: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onDuplicate: () -> Void
    let onMove: (ComparisonPromptMoveDirection) -> Void

    var body: some View {
        Menu {
            Button(action: onDuplicate) { Label("Duplicate prompt", systemImage: "plus.square.on.square") }
            Divider()
            Button { onMove(.up) } label: { Label("Move up", systemImage: "arrow.up") }
                .disabled(!canMoveUp)
            Button { onMove(.down) } label: { Label("Move down", systemImage: "arrow.down") }
                .disabled(!canMoveDown)
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Actions for prompt \(number)")
            .help("Duplicate this prompt or change its order")
    }
}

private struct ComparisonPromptCard: View {
    @Binding var prompt: ComparisonPromptSetDraft.Prompt
    let mode: ComparisonMode
    let number: Int
    let canRemove: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let audio: AudioClipPlayer
    let onDuplicate: () -> Void
    let onMove: (ComparisonPromptSetDraft.MoveDirection) -> Void
    let onRemove: () -> Void

    private var textLabel: String {
        switch mode {
        case .vision, .videoUnderstanding: "Question"
        case .speechToText: "Reference transcript (optional)"
        case .textToSpeech: "Text to speak"
        default: "Prompt"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack {
                Text("PROMPT \(number)").font(WorkbenchTypography.metadata.weight(.semibold))
                    .foregroundStyle(WorkbenchColor.accent)
                Spacer()
                ComparisonPromptActions(number: number, canMoveUp: canMoveUp, canMoveDown: canMoveDown,
                    onDuplicate: onDuplicate, onMove: onMove)
                Button(action: onRemove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).disabled(!canRemove)
                    .accessibilityLabel("Remove prompt \(number)")
                    .help("Remove this prompt; at least one prompt is required.")
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                Text(textLabel).font(WorkbenchTypography.label)
                TextField(textLabel, text: $prompt.text, axis: .vertical)
                    .lineLimit(2...5).accessibilityLabel("Prompt \(number) \(textLabel.lowercased())")
            }
            if let kind = mode.inputKind {
                HStack(spacing: WorkbenchSpacing.sm) {
                    Button("Choose \(kind.rawValue) file…") {
                        if let path = ComparisonPromptSetEditor.pick(kind) { prompt.inputPath = path }
                    }
                    Text(prompt.inputDisplayName
                        ?? (prompt.builtinInput == nil ? "No file chosen" : "Built-in \(kind.rawValue) fixture"))
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                        .lineLimit(1).truncationMode(.middle).help(prompt.inputPath)
                }
                if prompt.usesSavedInput, !prompt.inputFileUnavailable {
                    Label("Saved input from this run", systemImage: "archivebox")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.accent)
                }
                if prompt.inputFileUnavailable, prompt.validationError(for: mode) == nil {
                    Label(prompt.usesSavedInput ? "Saved input unavailable · choose a replacement"
                        : "Input file unavailable · choose a replacement", systemImage: "exclamationmark.triangle")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
                }
                if let url = prompt.inputPreviewURL {
                    ComparisonPromptInputPreview(url: url, kind: kind, audio: audio)
                } else if prompt.inputPath.isEmpty, prompt.builtinInput != nil {
                    Text("Built-in input is created when the comparison runs.")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
            }
            if mode == .vision || mode == .videoUnderstanding {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text("Expected words · optional").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    TextField("Comma-separated; a|b accepts either", text: $prompt.keywords)
                        .accessibilityLabel("Prompt \(number) expected words")
                }
            }
            if mode == .chat || mode == .vision || mode == .videoUnderstanding {
                parameter("Token limit", placeholder: "Default: 256", value: $prompt.maxTokens)
                    .help("Requested maximum output tokens. Run also applies the current serving token cap.")
                if mode == .chat, let name = prompt.toolName {
                    Label("Saved tool: \(name)", systemImage: "wrench.and.screwdriver")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
            }
            if mode == .imageGeneration {
                HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                    parameter("Size · square px", placeholder: "Default: 512", value: $prompt.size)
                    parameter("Steps", placeholder: "Default: 20", value: $prompt.steps)
                    parameter("Seed", placeholder: "Default: 42", value: $prompt.seed)
                }
            }
            if mode == .videoGeneration {
                HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                    parameter("Width · px", placeholder: "Runtime default", value: $prompt.width)
                    parameter("Height · px", placeholder: "Runtime default", value: $prompt.height)
                    parameter("Frames", placeholder: "Runtime default", value: $prompt.frames)
                }
                HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                    parameter("Frame rate · fps", placeholder: "Model default", value: $prompt.fps)
                    parameter("Steps", placeholder: "Model default", value: $prompt.steps)
                    parameter("Seed", placeholder: "Default: 42", value: $prompt.seed)
                }
            }
            if let message = prompt.validationError(for: mode) {
                ComparisonDraftValidationMessage(message: message)
                    .accessibilityLabel("Prompt \(number): \(message)")
            }
        }
        .padding(WorkbenchSpacing.md)
        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
    }

    private func parameter(_ title: String, placeholder: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(title).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            TextField(placeholder, text: value).accessibilityLabel("Prompt \(number) \(title.lowercased())")
        }.frame(maxWidth: .infinity)
    }
}

/// Explicit previews share one audio player across the editor. Opening the editor
/// never generates built-in fixtures or starts playback.
struct ComparisonPromptInputPreview: View {
    let url: URL
    let kind: ComparisonMediaKind
    @ObservedObject var audio: AudioClipPlayer
    @State private var expanded: Bool
    @State private var image: PreviewImage?

    init(url: URL, kind: ComparisonMediaKind, audio: AudioClipPlayer, expanded: Bool = false) {
        self.url = url; self.kind = kind; self.audio = audio
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        DisclosureGroup("Preview input", isExpanded: $expanded) {
            if expanded {
                switch kind {
                case .image:
                    ThumbnailView(url: url, size: CGSize(width: 160, height: 160)) {
                        image = PreviewImage(url: url)
                    }
                    .accessibilityLabel("Preview input image; open a larger view")
                case .audio:
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                        AudioClipButton(url: url, label: "Play input", player: audio)
                        if audio.activeURL == url {
                            Slider(value: Binding(get: { audio.position }, set: { audio.seek(to: $0) }),
                                in: 0...max(audio.duration, 0.001))
                                .accessibilityLabel("Input audio position")
                            Text(String(format: "%.1f / %.1f seconds", audio.position, audio.duration))
                                .font(WorkbenchTypography.metadata.monospacedDigit()).foregroundStyle(WorkbenchColor.muted)
                        }
                    }.frame(maxWidth: 320, alignment: .leading)
                case .video:
                    ClipVideoView(url: url).frame(width: 280, height: 158)
                }
            }
        }
        .font(WorkbenchTypography.secondary)
        .sheet(item: $image) { item in ImagePreviewSheet(url: item.url) }
        .onChange(of: expanded) { _, open in
            if !open, audio.activeURL == url { audio.stop() }
        }
        .onChange(of: url) { old, _ in
            if audio.activeURL == old { audio.stop() }
            expanded = false; image = nil
        }
        .onDisappear { if audio.activeURL == url { audio.stop() } }
    }
}

struct ComparisonRunSetupSheet: View {
    @State var setup: ComparisonRunSetup
    @State private var checkpoint: ComparisonPromptDraftCheckpoint<ComparisonPromptSetDraft.Prompt>
    let availablePaths: Set<String>
    let name: (String) -> String
    let onApply: (ComparisonRunSetup, PromptSet) -> String?
    let onSave: (ComparisonPromptSetDraft) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var showingSaveName = false
    @State private var saveName = ""
    @State private var savedName: String?
    @State private var saving = false

    init(setup: ComparisonRunSetup, availablePaths: Set<String>, name: @escaping (String) -> String,
         onApply: @escaping (ComparisonRunSetup, PromptSet) -> String?,
         onSave: @escaping (ComparisonPromptSetDraft) async -> String?) {
        _setup = State(initialValue: setup)
        _checkpoint = State(initialValue: ComparisonPromptDraftCheckpoint(prompts: setup.draft.prompts))
        self.availablePaths = availablePaths; self.name = name; self.onApply = onApply; self.onSave = onSave
    }

    private var hasUnsavedChanges: Bool {
        checkpoint.hasChanges(prompts: setup.draft.prompts)
            || (showingSaveName && saveName != "\(setup.sourceName) copy")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack(spacing: WorkbenchSpacing.sm) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(WorkbenchTypography.title).foregroundStyle(WorkbenchColor.accent)
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text("Reuse \(setup.draft.mode.title.lowercased()) setup").font(WorkbenchTypography.cardTitle)
                    Text(setup.sourceName).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                ForEach(Array(setup.modelPaths.enumerated()), id: \.offset) { index, path in
                    HStack(spacing: WorkbenchSpacing.xs) {
                        LetterChip(letter: ComparePresentation.letter(index))
                        Text(name(path)).font(WorkbenchTypography.label).lineLimit(1).truncationMode(.middle)
                        if !availablePaths.contains(path) {
                            Label("Unavailable", systemImage: "exclamationmark.triangle")
                                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
                        }
                    }.help(path)
                }
                if setup.modelPaths.contains(where: { !availablePaths.contains($0) }) {
                    Text("Replace or remove unavailable models in Compare before running.")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
                }
            }
            ComparisonPromptFields(draft: $setup.draft)
            if setup.draft.mode.inputKind != nil {
                Text("Save as prompt set keeps its own input copies. Temporary setups use the ten-run cache; older runs use original files or built-in fixtures.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
            Text("Recorded prompts and models for a new run. Current serving limits and runtime defaults still apply. Original results and ratings stay intact.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            ErrorBanner(text: error)
            if showingSaveName {
                HStack(spacing: WorkbenchSpacing.sm) {
                    ComparisonPromptSetNameField(name: $saveName, placeholder: "Prompt set name",
                        accessibilityName: "Saved prompt set name")
                    Button("Save") {
                        let copy = setup.savedDraft(named: saveName)
                        let title = saveName
                        saving = true
                        Task { @MainActor in
                            error = await onSave(copy)
                            if error == nil {
                                checkpoint.retain(prompts: setup.draft.prompts)
                                savedName = title; showingSaveName = false
                            }
                            saving = false
                        }
                    }
                    .disabled(setup.savedDraft(named: saveName).validationError != nil)
                    Button { showingSaveName = false; error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Cancel saving the prompt set")
                        .accessibilityLabel("Cancel saving the prompt set")
                }
            }
            if let savedName {
                Label("Saved ‘\(savedName)’ in the prompt set picker.", systemImage: "checkmark.circle")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.success)
            }
            if saving {
                HStack(spacing: WorkbenchSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Saving prompt set and input copies…").font(WorkbenchTypography.metadata)
                }
            }
            HStack(spacing: WorkbenchSpacing.sm) {
                Button { setup.draft.addPrompt() } label: { Label("Add prompt", systemImage: "plus") }
                Button("Save as prompt set…") {
                    saveName = "\(setup.sourceName) copy"; showingSaveName = true; savedName = nil; error = nil
                }
                .buttonStyle(.borderless).foregroundStyle(WorkbenchColor.accent).disabled(showingSaveName)
                Spacer()
                ComparisonPromptCancelButton(requiresConfirmation: hasUnsavedChanges) { dismiss() }
                Button("Use setup") {
                    do {
                        error = onApply(setup, try setup.draft.promptSet())
                        if error == nil { dismiss() }
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).tint(WorkbenchColor.accent).keyboardShortcut(.defaultAction)
                .disabled(setup.draft.validationError != nil)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: WorkbenchSize.Compare.promptEditorWidth)
        .disabled(saving)
        .interactiveDismissDisabled(saving || hasUnsavedChanges)
    }
}

// MARK: - Saved music prompt sets

/// Shared fields for creation, saved-set editing and recorded-run reuse.
struct MusicPromptFields: View {
    @Binding var prompts: [MusicComparisonSetup.Prompt]

    var body: some View {
        ComparisonPromptList(promptIDs: prompts.map(\.id), maximumHeight: WorkbenchSize.Compare.musicPromptEditorHeight,
            issue: ComparisonPromptScrollLogic.firstIssue(in: prompts, error: { $0.validationError })) {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                ForEach($prompts) { $prompt in
                    let promptID = prompt.id
                    let number = (prompts.firstIndex { $0.id == promptID } ?? 0) + 1
                    VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                        HStack {
                            Text("PROMPT \(number)").font(WorkbenchTypography.metadata.weight(.semibold))
                                .foregroundStyle(WorkbenchColor.accent)
                            Spacer()
                            ComparisonPromptActions(number: number,
                                canMoveUp: prompts.first?.id != promptID, canMoveDown: prompts.last?.id != promptID,
                                onDuplicate: { prompts.duplicatePrompt(id: promptID) },
                                onMove: { prompts.movePrompt(id: promptID, direction: $0) })
                            Button { prompts.removePrompt(id: promptID) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .disabled(prompts.count <= 1)
                                .accessibilityLabel("Remove prompt \(number)")
                                .help("Remove this prompt; at least one prompt is required.")
                        }
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                            Text("Caption").font(WorkbenchTypography.label)
                            TextField("Describe the music", text: $prompt.caption, axis: .vertical)
                                .lineLimit(2...5).accessibilityLabel("Prompt \(number) caption")
                        }
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                            Text("Lyrics").font(WorkbenchTypography.label)
                            TextField("Default: [instrumental]", text: $prompt.lyrics, axis: .vertical)
                                .lineLimit(2...6).accessibilityLabel("Prompt \(number) lyrics")
                        }
                        HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                            parameter("Duration · seconds", defaultValue: "Default: 15", value: $prompt.duration)
                            parameter("Steps", defaultValue: "Default: 30", value: $prompt.steps)
                            parameter("Seed", defaultValue: "Default: 42", value: $prompt.seed)
                        }
                        if let message = prompt.validationError {
                            ComparisonDraftValidationMessage(message: message)
                                .accessibilityLabel("Prompt \(number): \(message)")
                        }
                    }
                    .padding(WorkbenchSpacing.md)
                    .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                    .id(ComparisonPromptScrollLogic.Anchor(promptID: promptID))
                }
            }
        }
    }

    private func parameter(_ title: String, defaultValue: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(title).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            TextField(defaultValue, text: value).accessibilityLabel(title)
        }.frame(maxWidth: .infinity)
    }
}

struct MusicPromptSetCreateSheet: View {
    @State var draft: MusicPromptSetDraft
    @State private var checkpoint: ComparisonPromptDraftCheckpoint<MusicComparisonSetup.Prompt>
    let onSave: (MusicPromptSetDraft) -> String?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(draft: MusicPromptSetDraft = MusicPromptSetDraft(), onSave: @escaping (MusicPromptSetDraft) -> String?) {
        _draft = State(initialValue: draft)
        _checkpoint = State(initialValue: ComparisonPromptDraftCheckpoint(name: draft.name, prompts: draft.prompts))
        self.onSave = onSave
    }

    private var hasUnsavedChanges: Bool { checkpoint.hasChanges(name: draft.name, prompts: draft.prompts) }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Label("New music prompt set", systemImage: "music.note.list")
                .font(WorkbenchTypography.cardTitle)
            ComparisonPromptSetNameField(name: $draft.name, accessibilityName: "Music prompt set name")
            MusicPromptFields(prompts: $draft.prompts)
            Text("Settings apply to each prompt. Duration is a maximum request. Blank settings use the current defaults. Saving does not generate audio.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            ErrorBanner(text: error ?? draft.prompts.identityValidationError)
            HStack {
                Button { draft.addPrompt() } label: { Label("Add prompt", systemImage: "plus") }
                Spacer()
                ComparisonPromptCancelButton(requiresConfirmation: hasUnsavedChanges) { dismiss() }
                Button("Save prompt set") {
                    error = onSave(draft)
                    if error == nil { dismiss() }
                }
                .buttonStyle(.borderedProminent).tint(WorkbenchColor.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.validationError != nil)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: WorkbenchSize.Compare.musicPromptEditorWidth)
        .interactiveDismissDisabled(hasUnsavedChanges)
    }
}

struct PromptSetActions: View {
    let name: String?
    let isEnabled: Bool
    var isCopyEnabled = false
    let onEdit: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void
    var onCopy: (() -> Void)? = nil

    var body: some View {
        Menu {
            if let onCopy {
                Button("Customize copy…", systemImage: "doc.on.doc", action: onCopy).disabled(!isCopyEnabled)
            }
            if isEnabled {
                if onCopy != nil { Divider() }
                Button("Edit…", systemImage: "slider.horizontal.3", action: onEdit)
                Button("Rename…", systemImage: "pencil", action: onRename)
                Button("Remove…", systemImage: "trash", role: .destructive, action: onRemove)
            }
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!isEnabled && !isCopyEnabled)
            .accessibilityLabel("Manage saved prompt set")
            .help(isEnabled ? "Manage \(name ?? "prompt set")"
                : isCopyEnabled ? "Customize a copy of \(name ?? "prompt set")"
                : "Select a prompt set after the current save or comparison finishes.")
    }
}

struct MusicPromptSetEditSheet: View {
    @State var edit: MusicPromptSetEdit
    let onSave: (MusicPromptSetEdit) -> String?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack(spacing: WorkbenchSpacing.sm) {
                Image(systemName: "slider.horizontal.3")
                    .font(WorkbenchTypography.title).foregroundStyle(WorkbenchColor.accent)
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text("Edit music prompt set").font(WorkbenchTypography.cardTitle)
                    Text(edit.original.name).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
            }
            MusicPromptFields(prompts: $edit.prompts)
            Text("Save changes to this set. Blank settings use the current defaults. Past runs keep their recorded inputs, audio and ratings.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            ErrorBanner(text: error ?? edit.prompts.identityValidationError)
            HStack {
                Button { edit.prompts.addPrompt() } label: { Label("Add prompt", systemImage: "plus") }
                Button("Revert changes") { edit.revertChanges(); error = nil }
                    .buttonStyle(.borderless).disabled(!edit.hasChanges)
                    .help("Restore the set as it was when this editor opened.")
                Spacer()
                ComparisonPromptCancelButton(requiresConfirmation: edit.hasChanges) { dismiss() }
                Button("Save changes") {
                    error = onSave(edit)
                    if error == nil { dismiss() }
                }
                .buttonStyle(.borderedProminent).tint(WorkbenchColor.accent)
                .keyboardShortcut(.defaultAction).disabled(edit.validationError != nil || !edit.hasChanges)
                .help(edit.hasChanges ? "Save changes to this prompt set." : "No changes to save.")
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: WorkbenchSize.Compare.musicPromptEditorWidth)
        .interactiveDismissDisabled(edit.hasChanges)
    }
}

struct PromptSetRenameSheet: View {
    let set: PromptSet
    let onRename: (String) -> String?
    @State private var draft: PromptSetRenameDraft
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(set: PromptSet, onRename: @escaping (String) -> String?) {
        self.set = set
        self.onRename = onRename
        _draft = State(initialValue: PromptSetRenameDraft(set: set))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Label("Rename \(set.effectiveMode.title.lowercased()) prompt set", systemImage: "pencil")
                .font(WorkbenchTypography.cardTitle)
            Text("Only this saved set's name changes. Past runs keep their recorded names and inputs.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            ComparisonPromptSetNameField(name: $draft.name, placeholder: "Prompt set name", showInitialError: true)
            ErrorBanner(text: error)
            HStack {
                Spacer()
                ComparisonPromptCancelButton(requiresConfirmation: draft.hasChanges) { dismiss() }
                Button("Rename") {
                    error = onRename(draft.normalizedName)
                    if error == nil { dismiss() }
                }
                .buttonStyle(.borderedProminent).tint(WorkbenchColor.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canRename)
            }
        }
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: WorkbenchSize.Compare.promptSetRenameWidth)
        .interactiveDismissDisabled(draft.hasChanges)
    }
}

typealias MusicPromptSetRenameSheet = PromptSetRenameSheet

// MARK: - Reuse recorded music inputs

struct MusicComparisonSetupSheet: View {
    @State var setup: MusicComparisonSetup
    @State private var checkpoint: ComparisonPromptDraftCheckpoint<MusicComparisonSetup.Prompt>
    let availablePaths: Set<String>
    let name: (String) -> String
    let onApply: (MusicComparisonSetup, PromptSet) -> Void
    let onSave: (PromptSet) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var applyError: String?
    @State private var showingSaveName = false
    @State private var saveName = ""
    @State private var savedName: String?

    init(setup: MusicComparisonSetup, availablePaths: Set<String>, name: @escaping (String) -> String,
         onApply: @escaping (MusicComparisonSetup, PromptSet) -> Void, onSave: @escaping (PromptSet) throws -> Void) {
        _setup = State(initialValue: setup)
        _checkpoint = State(initialValue: ComparisonPromptDraftCheckpoint(prompts: setup.prompts))
        self.availablePaths = availablePaths; self.name = name; self.onApply = onApply; self.onSave = onSave
    }

    private var hasUnsavedChanges: Bool {
        checkpoint.hasChanges(prompts: setup.prompts)
            || (showingSaveName && saveName != "\(setup.sourceName) copy")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack(spacing: WorkbenchSpacing.sm) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(WorkbenchTypography.title).foregroundStyle(WorkbenchColor.accent)
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                    Text("Reuse music setup").font(WorkbenchTypography.cardTitle)
                    Text(setup.sourceName).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                }
            }
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                ForEach(Array(setup.modelPaths.enumerated()), id: \.offset) { index, path in
                    HStack(spacing: WorkbenchSpacing.xs) {
                        LetterChip(letter: ComparePresentation.letter(index))
                        Text(name(path)).font(WorkbenchTypography.label).lineLimit(1).truncationMode(.middle)
                        if !availablePaths.contains(path) {
                            Label("Unavailable", systemImage: "exclamationmark.triangle")
                                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
                        }
                    }.help(path)
                }
                if setup.modelPaths.contains(where: { !availablePaths.contains($0) }) {
                    Text("Replace or remove unavailable models in Compare before running.")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.warning)
                }
            }
            MusicPromptFields(prompts: $setup.prompts)
            Text("Temporary inputs for a new run. Blank settings use the current defaults. Saved results and listening ratings stay with the original run.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            ErrorBanner(text: applyError ?? setup.prompts.identityValidationError)
            if showingSaveName {
                HStack(spacing: WorkbenchSpacing.sm) {
                    ComparisonPromptSetNameField(name: $saveName, placeholder: "Prompt set name",
                        accessibilityName: "Saved music prompt set name")
                    Button("Save") { savePromptSet() }
                        .disabled(MusicComparisonSetup.nameValidationError(saveName) != nil || setup.validationError != nil)
                    Button { showingSaveName = false; applyError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Cancel saving the prompt set")
                        .accessibilityLabel("Cancel saving the prompt set")
                }
            }
            if let savedName {
                Label("Saved ‘\(savedName)’ in the prompt set picker.", systemImage: "checkmark.circle")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.success)
            }
            HStack {
                Button { setup.prompts.addPrompt() } label: { Label("Add prompt", systemImage: "plus") }
                Button("Save as prompt set…") {
                    saveName = "\(setup.sourceName) copy"
                    showingSaveName = true
                    savedName = nil
                    applyError = nil
                }
                .buttonStyle(.borderless).foregroundStyle(WorkbenchColor.accent)
                .disabled(showingSaveName || setup.validationError != nil)
                Spacer()
                ComparisonPromptCancelButton(requiresConfirmation: hasUnsavedChanges) { dismiss() }
                Button("Use setup") {
                    do { onApply(setup, try setup.promptSet()); dismiss() }
                    catch { applyError = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).tint(WorkbenchColor.accent)
                .keyboardShortcut(.defaultAction).disabled(setup.validationError != nil)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: WorkbenchSize.Compare.musicPromptEditorWidth)
        .interactiveDismissDisabled(hasUnsavedChanges)
    }

    private func savePromptSet() {
        do {
            let set = try setup.promptSet(named: saveName)
            try onSave(set)
            checkpoint.retain(prompts: setup.prompts)
            savedName = set.name
            showingSaveName = false
            applyError = nil
        } catch { applyError = error.localizedDescription }
    }

}

// MARK: - Prompt set selection

enum ComparisonPromptSetPickerLogic {
    enum Section: String, CaseIterable { case temporary = "Temporary setup", saved = "Saved sets", builtin = "Built-in presets" }
    struct Group: Identifiable {
        let section: Section
        let sets: [PromptSet]
        var id: Section { section }
    }
    static func groups(_ sets: [PromptSet], temporaryID: String?, query: String) -> [Group] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = sets.filter { set in
            query.isEmpty || ([set.name] + set.prompts.map { "\($0.text) \($0.tool?.name ?? "")" })
                .joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
        return Section.allCases.compactMap { section in
            let entries = matches.filter { set in
                let source: Section = set.id == temporaryID ? .temporary : set.origin == .builtin ? .builtin : .saved
                return source == section
            }
            return entries.isEmpty ? nil : Group(section: section, sets: entries)
        }
    }
    static func promptCount(_ set: PromptSet) -> String {
        "\(set.prompts.count) \(set.prompts.count == 1 ? "prompt" : "prompts")"
    }
}

struct ComparisonPromptSetPicker: View {
    let sets: [PromptSet]
    @Binding var selection: String
    let temporaryID: String?
    @State private var expanded = false

    private var selected: PromptSet? { sets.first { $0.id == selection } ?? sets.first }

    var body: some View {
        Button { expanded = true } label: {
            HStack(spacing: WorkbenchSpacing.xs) {
                Text("Prompt set").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                Text(selected?.name ?? "No prompt sets").font(WorkbenchTypography.emphasis)
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
        }
        .buttonStyle(.plain).disabled(sets.isEmpty)
        .accessibilityLabel("Choose prompt set")
        .accessibilityValue(selected?.name ?? "No prompt sets")
        .help(selected?.name ?? "No prompt sets available for this comparison mode")
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            ComparisonPromptSetPanel(sets: sets, selection: selected?.id, temporaryID: temporaryID) { id in
                guard sets.contains(where: { $0.id == id }) else { return }
                selection = id
                expanded = false
            }
        }
        .onChange(of: sets.map(\.id)) { _, _ in expanded = false }
    }
}

struct ComparisonPromptSetPanel: View {
    let sets: [PromptSet]
    let selection: String?
    let temporaryID: String?
    let onSelect: (String) -> Void
    @State var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Prompt sets").font(WorkbenchTypography.cardTitle)
            HStack(spacing: WorkbenchSpacing.xs) {
                TextField("Search names, prompts or tools", text: $query)
                    .textFieldStyle(.roundedBorder).focused($searchFocused)
                    .accessibilityLabel("Search prompt sets")
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(WorkbenchColor.muted)
                        .accessibilityLabel("Clear prompt set search")
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    let groups = ComparisonPromptSetPickerLogic.groups(sets, temporaryID: temporaryID, query: query)
                    if groups.isEmpty {
                        Text(sets.isEmpty ? "No prompt sets for this mode" : "No matching prompt sets")
                            .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    }
                    ForEach(groups) { group in
                        Text(group.section.rawValue).font(WorkbenchTypography.metadata.weight(.semibold))
                            .foregroundStyle(WorkbenchColor.accent).padding(.top, WorkbenchSpacing.xs)
                        ForEach(group.sets) { set in
                            Button { onSelect(set.id) } label: {
                                HStack(spacing: WorkbenchSpacing.sm) {
                                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                                        Text(set.name).font(WorkbenchTypography.label).lineLimit(1).truncationMode(.middle)
                                        Text(ComparisonPromptSetPickerLogic.promptCount(set))
                                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                                    }
                                    Spacer()
                                    if selection == set.id { Image(systemName: "checkmark").foregroundStyle(WorkbenchColor.accent) }
                                }
                                .padding(WorkbenchSpacing.sm).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selection == set.id ? WorkbenchColor.accent.opacity(.fill) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help(set.name)
                            .accessibilityAddTraits(selection == set.id ? [.isSelected] : [])
                        }
                    }
                }
            }.frame(maxHeight: 400)
        }
        .padding(WorkbenchSpacing.md).frame(width: 400)
        .onAppear { searchFocused = true }
    }
}

// MARK: - Run history

enum ComparisonHistoryLogic {
    struct Group: Identifiable {
        let mode: ComparisonMode
        let runs: [ComparisonRun]
        var id: ComparisonMode { mode }
    }

    static func groups(_ runs: [ComparisonRun], query: String) -> [Group] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = runs.filter { query.isEmpty || "\($0.effectiveMode.title) \($0.promptSetName) \($0.variants.joined(separator: " "))".localizedCaseInsensitiveContains(query) }
        return ComparisonMode.allCases.compactMap { mode in
            let entries = matching.filter { $0.effectiveMode == mode }.sorted { $0.startedAt > $1.startedAt }
            return entries.isEmpty ? nil : Group(mode: mode, runs: entries)
        }
    }

    static func modelCount(_ run: ComparisonRun) -> String {
        "\(run.variants.count) \(run.variants.count == 1 ? "model" : "models")"
    }
}

struct ComparisonHistoryPicker: View {
    let runs: [ComparisonRun]
    @Binding var selection: UUID?
    @State private var expanded = false

    private var selected: ComparisonRun? { runs.first { $0.id == selection } }

    var body: some View {
        Button {
            expanded = true
        } label: {
            HStack(spacing: WorkbenchSpacing.sm) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(WorkbenchColor.muted)
                VStack(alignment: .leading, spacing: WorkbenchSpacing.xxxs) {
                    Text(selected?.promptSetName ?? "Run history").font(WorkbenchTypography.label).lineLimit(1)
                    if let selected {
                        Text("\(selected.effectiveMode.title) · \(selected.startedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted).lineLimit(1)
                    }
                }
                Image(systemName: "chevron.down").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose comparison run")
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            ComparisonHistoryPanel(runs: runs, selection: selection) { id in
                selection = id
                expanded = false
            }
        }
    }
}

struct ComparisonHistoryPanel: View {
    let runs: [ComparisonRun]
    let selection: UUID?
    let onSelect: (UUID) -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Run history").font(WorkbenchTypography.cardTitle)
            TextField("Search runs or models", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    let groups = ComparisonHistoryLogic.groups(runs, query: query)
                    if groups.isEmpty {
                        Text("No matching runs").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    }
                    ForEach(groups) { group in
                        Text(group.mode.title).font(WorkbenchTypography.metadata.weight(.semibold))
                            .foregroundStyle(WorkbenchColor.muted).padding(.top, WorkbenchSpacing.xs)
                        ForEach(group.runs) { run in
                            Button {
                                onSelect(run.id)
                            } label: {
                                HStack(spacing: WorkbenchSpacing.sm) {
                                    VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                                        Text(run.promptSetName).font(WorkbenchTypography.label).lineLimit(1)
                                        Text("\(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(ComparisonHistoryLogic.modelCount(run)) · \(run.state.rawValue.capitalized)")
                                            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                                    }
                                    Spacer()
                                    if selection == run.id {
                                        Image(systemName: "checkmark").foregroundStyle(WorkbenchColor.accent)
                                    }
                                }
                                .padding(WorkbenchSpacing.sm)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selection == run.id ? WorkbenchColor.accent.opacity(.fill) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selection == run.id ? [.isSelected] : [])
                        }
                    }
                }
            }
            .frame(maxHeight: 400)
        }
        .padding(WorkbenchSpacing.md)
        .frame(width: 400)
    }
}
