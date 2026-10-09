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
    struct ListeningClip: Identifiable {
        let modelPath: String
        let promptID: String
        let url: URL
        var id: String { modelPath + "|" + promptID }
    }

    /// Completed music runs offer A/B listening and a per-lane listening rating.
    static func showsListening(_ run: ComparisonRun) -> Bool {
        run.effectiveMode == .musicGeneration && run.state == .completed
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

/// A failure as one tinted line (the error's first line, two lines at most); the full text opens in a popover.
/// Lane headers and result cells both render failures through this view.
struct FailureNotice: View {
    let error: String
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Label(ComparePresentation.firstLine(of: error), systemImage: "exclamationmark.triangle.fill")
                .font(WorkbenchTypography.secondary)
                .foregroundStyle(WorkbenchColor.failure)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Details") { showsDetails = true }
                .buttonStyle(.borderless)
                .font(WorkbenchTypography.secondary)
                .popover(isPresented: $showsDetails) {
                    ScrollView {
                        Text(error)
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
    let laneActions: (CompareLane) -> LaneActions

    @State private var preview: PreviewImage?
    @StateObject private var audio: AudioClipPlayer

    @MainActor
    init(run: ComparisonRun, store: ComparisonOutputStore, contentWidth: CGFloat, isRouteActive: Bool,
         name: @escaping (String) -> String, onReview: @escaping (String, Int?) -> Void,
         audio: AudioClipPlayer? = nil, @ViewBuilder laneActions: @escaping (CompareLane) -> LaneActions) {
        self.run = run
        self.store = store
        self.contentWidth = contentWidth
        self.isRouteActive = isRouteActive
        self.name = name
        self.onReview = onReview
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
                MusicListeningPanel(run: run, store: store, name: name, player: audio)
                    .id(run.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $preview) { item in ImagePreviewSheet(url: item.url) }
        .onDisappear { audio.stop() }
        .onChange(of: run.id) { _, _ in audio.stop() }
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
            if ComparisonViewLogic.showsListening(run) {
                listeningReview(lane.path)
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
            Text(entry.text)
                .font(WorkbenchTypography.secondary)
                .textSelection(.enabled)
            if let kind = mode.inputKind, let url = inputURL(entry) {
                switch kind {
                case .image:
                    ThumbnailView(url: url, size: CGSize(width: WorkbenchSize.Compare.inputThumbnail, height: WorkbenchSize.Compare.inputThumbnail)) {
                        preview = PreviewImage(url: url)
                    }
                case .audio: AudioClipButton(url: url, label: "Play input", player: audio)
                case .video: ClipVideoView(url: url).frame(width: width, height: width * 9 / 16)
                }
            }
            if let keywords = entry.expectedKeywords, !keywords.isEmpty {
                Text("expects: \(keywords.joined(separator: ", "))")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
        }
        .padding(.vertical, WorkbenchSize.Compare.cellInset)
        .frame(width: width, alignment: .leading)
    }

    private func inputURL(_ entry: PromptEntry) -> URL? {
        if let path = entry.inputPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard entry.builtinInput != nil, let kind = entry.inputKind else { return nil }
        let ext: String
        switch kind {
        case .image: ext = "png"
        case .video: ext = "mp4"
        case .audio: ext = "wav"
        }
        let url = store.inputsDirectory(run.id)
            .appendingPathComponent("\(ComparisonOutputStore.safeComponent(entry.id)).\(ext)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A card that fills its row's height, so the cards of one prompt line up top and bottom.
    private func resultCell(_ sample: ComparisonSample?, result: VariantResult?, lane: CompareLane, layout: ComparePresentation.GridLayout) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if let sample {
                if let error = sample.error {
                    FailureNotice(error: error)
                } else {
                    outputView(sample, side: layout.mediaSide)
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
    private func outputView(_ sample: ComparisonSample, side: CGFloat) -> some View {
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
                        preview = PreviewImage(url: url)
                    }
                case .audio: AudioClipButton(url: url, label: sample.audioSeconds.map { String(format: "Play · %.1f s", $0) } ?? "Play", player: audio)
                default: ClipVideoView(url: url).frame(width: side, height: side * 9 / 16)
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
struct MusicListeningPanel: View {
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
            .help("Switch at the same elapsed time; shorter clips clamp to their end. Generated musical phrases may differ.")
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

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
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

/// Builds a user prompt set for a media mode, with an input file picker per entry
/// for the modes that take one.
struct MediaPromptSetEditor: View {
    let mode: ComparisonMode
    let onSave: (PromptSet) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var entries: [Draft] = [Draft()]

    struct Draft: Identifiable {
        let id = UUID().uuidString
        var text = ""
        var inputPath: String?
        var keywords = ""
        var lyrics = "[instrumental]"
    }

    @State private var durationSeconds = 15.0

    private var textLabel: String {
        switch mode {
        case .vision, .videoUnderstanding: return "Question"
        case .speechToText: return "What the audio says"
        case .textToSpeech: return "Text to speak"
        default: return "Prompt"
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && entries.allSatisfy { draft in
                (mode == .speechToText || !draft.text.trimmingCharacters(in: .whitespaces).isEmpty)
                    && (mode != .musicGeneration || !draft.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    && (mode.inputKind == nil || draft.inputPath != nil)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("New \(mode.title.lowercased()) prompt set").font(WorkbenchTypography.emphasis)
            TextField("Set name", text: $name)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                    ForEach($entries) { $draft in
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                            TextField(textLabel, text: $draft.text)
                            if mode == .musicGeneration {
                                TextField("Lyrics with section tags, or [instrumental]", text: $draft.lyrics, axis: .vertical)
                                    .lineLimit(2...6)
                            }
                            if let kind = mode.inputKind {
                                HStack {
                                    Button("Choose \(kind.rawValue) file…") { draft.inputPath = Self.pick(kind) ?? draft.inputPath }
                                    Text(draft.inputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No file chosen")
                                        .font(WorkbenchTypography.secondary)
                                        .foregroundStyle(WorkbenchColor.muted)
                                }
                            }
                            if mode == .vision || mode == .videoUnderstanding {
                                TextField("Expected words, comma-separated (optional)", text: $draft.keywords)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
            if mode == .musicGeneration {
                Stepper("Requested duration: \(Int(durationSeconds)) s", value: $durationSeconds, in: 5...360, step: 5)
                Text("Duration is a maximum request. Listen to compare quality; generation speed measures performance only.")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            }
            HStack {
                Button { entries.append(Draft()) } label: { Label("Add prompt", systemImage: "plus") }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: 520)
    }

    private func save() {
        let media: MediaParameters? = {
            switch mode {
            case .imageGeneration: return MediaParameters(size: 512, steps: 20, seed: 42)
            case .videoGeneration: return ComparisonMediaFixtures.videoGenerationParameters
            default: return nil
            }
        }()
        let prompts = entries.map { draft -> PromptEntry in
            let words = draft.keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return PromptEntry(
                id: draft.id,
                text: draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
                maxTokens: 256,
                inputKind: mode.inputKind,
                inputPath: draft.inputPath,
                expectedKeywords: words.isEmpty ? nil : words,
                media: mode == .musicGeneration
                    ? MediaParameters(steps: 30, seed: 42, durationSeconds: durationSeconds, lyrics: draft.lyrics)
                    : media
            )
        }
        onSave(PromptSet(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces),
            useCase: nil,
            prompts: prompts,
            origin: .userCreated,
            mode: mode
        ))
        dismiss()
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

// MARK: - Reuse recorded music inputs

struct MusicComparisonSetupSheet: View {
    @State var setup: MusicComparisonSetup
    let availablePaths: Set<String>
    let name: (String) -> String
    let onApply: (MusicComparisonSetup, PromptSet) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var applyError: String?

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
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    ForEach(Array(setup.prompts.indices), id: \.self) { index in
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                            Text("PROMPT \(index + 1)").font(WorkbenchTypography.metadata.weight(.semibold))
                                .foregroundStyle(WorkbenchColor.accent)
                            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                                Text("Caption").font(WorkbenchTypography.label)
                                TextField("Describe the music", text: $setup.prompts[index].caption, axis: .vertical)
                                    .lineLimit(2...5).accessibilityLabel("Prompt \(index + 1) caption")
                            }
                            VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
                                Text("Lyrics").font(WorkbenchTypography.label)
                                TextField("Default: [instrumental]", text: $setup.prompts[index].lyrics, axis: .vertical)
                                    .lineLimit(2...6).accessibilityLabel("Prompt \(index + 1) lyrics")
                            }
                            HStack(alignment: .top, spacing: WorkbenchSpacing.md) {
                                parameter("Duration · seconds", defaultValue: "Default: 15", value: $setup.prompts[index].duration)
                                parameter("Steps", defaultValue: "Default: 30", value: $setup.prompts[index].steps)
                                parameter("Seed", defaultValue: "Default: 42", value: $setup.prompts[index].seed)
                            }
                        }
                        .padding(WorkbenchSpacing.md)
                        .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                    }
                }
            }.frame(maxHeight: 390)
            Text("Temporary inputs for a new run. Blank settings use the current defaults. Saved results and listening ratings stay with the original run.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            ErrorBanner(text: applyError ?? setup.validationError)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
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
        .frame(width: 620)
    }

    private func parameter(_ title: String, defaultValue: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Text(title).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            TextField(defaultValue, text: value).accessibilityLabel(title)
        }.frame(maxWidth: .infinity)
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
