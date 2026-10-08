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
            break
        case .vision, .videoUnderstanding:
            if let tokens = sample.generationTokens { parts.append("\(tokens) tokens") }
        case .speechToText:
            if let seconds = sample.seconds, let audio = sample.audioSeconds {
                parts.append(String(format: "%.1f s for %.1f s of audio", seconds, audio))
            }
        case .textToSpeech, .musicGeneration:
            if let audio = sample.audioSeconds { parts.append(String(format: "%.1f s of audio", audio)) }
        case .imageGeneration, .videoGeneration:
            if let spread = sample.pixelStd { parts.append(String(format: "pixel spread %.1f", spread)) }
        }
        if mode != .speechToText, let seconds = sample.seconds { parts.append(String(format: "%.1f s", seconds)) }
        if let load = sample.loadSeconds { parts.append(String(format: "load %.1f s", load)) }
        if let memory = sample.peakMemoryGB { parts.append(String(format: "%.1f GB peak", memory)) }
        let details = parts.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: " · ")
        return (primary, details)
    }
}

// MARK: - Results grid

/// One row per prompt, one column per variant; each cell shows what the variant produced.
struct MediaRunResultsView: View {
    private struct ChartPoint: Identifiable {
        let name: String
        let value: Double
        var id: String { name }
    }

    let run: ComparisonRun
    let store: ComparisonOutputStore
    let name: (String) -> String

    @State private var preview: PreviewImage?

    /// Headers, prompts and cards share these, so every column's text starts on the same line.
    private static let promptWidth: CGFloat = 220
    private static let columnWidth: CGFloat = 264
    private static let inset = WorkbenchSpacing.sm
    private static let contentWidth = columnWidth - 2 * inset

    private var mode: ComparisonMode { run.effectiveMode }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            chart
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: WorkbenchSpacing.sm, verticalSpacing: WorkbenchSpacing.sm) {
                    GridRow(alignment: .lastTextBaseline) {
                        Text("Prompt")
                            .font(WorkbenchTypography.label)
                            .foregroundStyle(WorkbenchColor.muted)
                            .frame(width: Self.promptWidth, alignment: .leading)
                        ForEach(run.results) { result in
                            Text(name(result.modelPath))
                                .font(WorkbenchTypography.emphasis)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(result.modelPath)
                                .padding(.horizontal, Self.inset)
                                .frame(width: Self.columnWidth, alignment: .leading)
                        }
                    }
                    Divider()
                    ForEach(ComparisonViewLogic.rows(for: run)) { entry in
                        GridRow {
                            promptCell(entry)
                            ForEach(run.results) { result in
                                resultCell(result.samples.first { $0.promptID == entry.id }, result: result)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $preview) { item in ImagePreviewSheet(url: item.url) }
    }

    @ViewBuilder
    private var chart: some View {
        let points = run.results.compactMap { result in
            result.aggregateMetric.map { ChartPoint(name: name(result.modelPath), value: $0) }
        }
        if !points.isEmpty {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                Text("\(mode.primaryMetric.title) · \(mode.primaryMetric.higherIsBetter ? "higher" : "lower") is faster")
                    .font(WorkbenchTypography.label)
                    .foregroundStyle(WorkbenchColor.muted)
                Chart {
                    ForEach(points) { point in
                        BarMark(x: .value(mode.primaryMetric.title, point.value), y: .value("Variant", point.name))
                            .cornerRadius(3)
                    }
                }
                .frame(height: CGFloat(max(points.count, 1)) * 44 + 40)
            }
        }
    }

    private func promptCell(_ entry: PromptEntry) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            Text(entry.text)
                .font(WorkbenchTypography.secondary)
                .textSelection(.enabled)
            if let kind = mode.inputKind, let url = inputURL(entry) {
                switch kind {
                case .image: ThumbnailView(url: url, size: CGSize(width: 96, height: 96)) { preview = PreviewImage(url: url) }
                case .audio: AudioClipButton(url: url, label: "Play input")
                case .video: ClipVideoView(url: url).frame(width: Self.promptWidth, height: Self.promptWidth * 9 / 16)
                }
            }
            if let keywords = entry.expectedKeywords, !keywords.isEmpty {
                Text("expects: \(keywords.joined(separator: ", "))")
                    .font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted)
            }
        }
        .padding(.vertical, Self.inset)
        .frame(width: Self.promptWidth, alignment: .leading)
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
    private func resultCell(_ sample: ComparisonSample?, result: VariantResult) -> some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
            if let sample {
                if let error = sample.error {
                    Text(error)
                        .font(WorkbenchTypography.secondary)
                        .foregroundStyle(WorkbenchColor.failure)
                        .textSelection(.enabled)
                } else {
                    outputView(sample)
                    metrics(sample)
                }
            } else if let error = result.error {
                Text(error).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
            } else {
                Text("Pending").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
        }
        .padding(Self.inset)
        .frame(width: Self.columnWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WorkbenchColor.canvas)
        .clipShape(RoundedRectangle(cornerRadius: WorkbenchRadius.control, style: .continuous))
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
    private func outputView(_ sample: ComparisonSample) -> some View {
        switch mode.outputKind {
        case .text:
            VStack(alignment: .leading, spacing: WorkbenchSpacing.xs) {
                // The text's own height, up to 140 points; a longer answer scrolls.
                ScrollView {
                    Text(sample.fullOutput ?? sample.outputExcerpt)
                        .font(WorkbenchTypography.value)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
                badge(sample)
            }
        case .image, .audio, .video:
            if let url = store.artifactURL(runID: run.id, artifact: sample.artifact ?? ""),
               FileManager.default.fileExists(atPath: url.path) {
                switch mode.outputKind {
                case .image:
                    ThumbnailView(url: url, size: CGSize(width: Self.contentWidth, height: Self.contentWidth)) {
                        preview = PreviewImage(url: url)
                    }
                case .audio: AudioClipButton(url: url, label: sample.audioSeconds.map { String(format: "Play · %.1f s", $0) } ?? "Play")
                default: ClipVideoView(url: url).frame(width: Self.contentWidth, height: Self.contentWidth * 9 / 16)
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
            Label(String(format: "WER %.0f%%", rate * 100),
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
final class AudioClipPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var failure: String?
    private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if isPlaying {
            player?.stop()
            isPlaying = false
            return
        }
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.delegate = self
            player = next
            failure = nil
            isPlaying = next.play()
        } catch {
            failure = AppHost.render(error)
        }
    }

    func stop() {
        player?.stop()
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
    }
}

struct AudioClipButton: View {
    let url: URL
    let label: String
    @StateObject private var player = AudioClipPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.xxs) {
            Button { player.toggle(url) } label: {
                Label(player.isPlaying ? "Stop" : label, systemImage: player.isPlaying ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let failure = player.failure {
                Text(failure).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.failure)
            }
        }
        .onDisappear { player.stop() }
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
                    .buttonStyle(.borderedProminent)
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
                        Text(group.mode.title.uppercased()).font(WorkbenchTypography.metadata.weight(.semibold))
                            .tracking(1).foregroundStyle(WorkbenchColor.muted).padding(.top, WorkbenchSpacing.xs)
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
