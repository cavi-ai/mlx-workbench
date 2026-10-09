import AVFoundation
import AVKit
import SwiftUI

extension ComparisonViewLogic {
    static func showsVideoInspection(_ run: ComparisonRun) -> Bool {
        run.effectiveMode.outputKind == .video && run.state == .completed
    }

    static func videoClips(for run: ComparisonRun, store: ComparisonOutputStore, promptID: String) -> [OutputClip] {
        outputClips(for: run, store: store, promptID: promptID, kind: .video)
    }
}

/// Owns only the viewer's players. Async load/seek completions cannot restart a closed viewer.
@MainActor
final class VideoComparisonPlayer: ObservableObject {
    private var ownedPlayers: [AVPlayer] = []
    var players: [AVPlayer] { ownedPlayers }
    @Published private(set) var urls: [URL] = []
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var failure: String?
    @Published private(set) var audibleURL: URL?
    private var durations: [Double] = []
    private var generation = 0
    private var seekGeneration = 0
    private var observer: Any?
    private var clockPlayer: AVPlayer?

    func load(_ urls: [URL], preservingPosition: Bool = true) async {
        let elapsed = preservingPosition ? position : 0
        let resume = preservingPosition && isPlaying
        let audio = audibleURL
        stop()
        guard !urls.isEmpty, urls.count <= 2 else { return }
        let token = generation
        isLoading = true
        defer {
            if token == generation {
                if Task.isCancelled { stop() } else { isLoading = false }
            }
        }
        do {
            var loaded: [AVPlayer] = [], lengths: [Double] = []
            for url in urls {
                let asset = AVURLAsset(url: url)
                let length = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard length.isFinite, length > 0, !tracks.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                guard token == generation, !Task.isCancelled else { return }
                let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player.automaticallyWaitsToMinimizeStalling = false
                player.isMuted = true
                for _ in 0..<100 {
                    guard token == generation, !Task.isCancelled else { return }
                    if player.status != .unknown { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard player.status == .readyToPlay else {
                    throw player.error ?? CocoaError(.fileReadCorruptFile)
                }
                loaded.append(player); lengths.append(length)
            }
            guard token == generation, !Task.isCancelled else { return }
            ownedPlayers = loaded; self.urls = urls; durations = lengths
            duration = lengths.max() ?? 0
            setAudio(audio)
            await seek(to: elapsed)
            guard token == generation, !Task.isCancelled else { return }
            isLoading = false
            if failure == nil, let index = lengths.indices.max(by: { lengths[$0] < lengths[$1] }) {
                let clock = loaded[index]
                clockPlayer = clock
                observer = clock.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                }
                if resume, position < duration { await toggle() }
            }
        } catch {
            guard token == generation else { return }
            stop()
            failure = "Video unavailable: \(error.localizedDescription)"
        }
        if token == generation { isLoading = false }
    }

    func seek(to value: Double) async {
        guard value.isFinite, !players.isEmpty else { return }
        let target = min(max(value, 0), duration), resume = isPlaying
        pause()
        seekGeneration += 1
        let request = seekGeneration, token = generation
        let cohort = Array(zip(players, durations))
        for (player, length) in cohort {
            let reached = await player.seek(to: CMTime(seconds: min(target, length), preferredTimescale: 600),
                                            toleranceBefore: .zero, toleranceAfter: .zero)
            guard token == generation, request == seekGeneration, !Task.isCancelled else { return }
            guard reached else {
                failure = "Video position could not be loaded. Try selecting the clips again."
                return
            }
        }
        position = target
        if resume, target < duration { play() }
    }

    func toggle() async {
        if isPlaying { pause(); return }
        guard !players.isEmpty, !isLoading, failure == nil else { return }
        let token = generation
        if position >= duration { await seek(to: 0) }
        guard token == generation, !Task.isCancelled, failure == nil else { return }
        play()
    }

    private func play() {
        guard players.allSatisfy({ $0.status == .readyToPlay && $0.currentItem?.status == .readyToPlay }) else {
            pause()
            failure = "Video is not ready for playback. Try selecting the clips again."
            return
        }
        let host = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 0.1, preferredTimescale: 600))
        for (player, length) in zip(players, durations) where position < length {
            player.setRate(1, time: CMTime(seconds: position, preferredTimescale: 600), atHostTime: host)
        }
        isPlaying = position < duration
    }

    func pause() {
        if isPlaying, let clockPlayer {
            let time = clockPlayer.currentTime().seconds
            if time.isFinite { position = min(max(time, 0), duration) }
        }
        players.forEach { $0.pause() }
        isPlaying = false
    }

    func setAudio(_ url: URL?) {
        audibleURL = url.flatMap { urls.contains($0) ? $0 : nil }
        for (player, source) in zip(players, urls) { player.isMuted = source != audibleURL }
    }

    private func refresh() {
        guard isPlaying, let clockPlayer else { return }
        if let failed = players.first(where: { $0.status == .failed || $0.currentItem?.status == .failed }) {
            pause()
            failure = "Video playback failed: \(failed.error?.localizedDescription ?? failed.currentItem?.error?.localizedDescription ?? "clip unavailable")"
            return
        }
        let time = clockPlayer.currentTime().seconds
        guard time.isFinite else { return }
        position = min(max(time, 0), duration)
        if position >= duration - 0.02 { pause(); position = duration }
    }

    func stop() {
        generation += 1; seekGeneration += 1
        if let observer, let clockPlayer { clockPlayer.removeTimeObserver(observer) }
        observer = nil; clockPlayer = nil
        for player in players { player.pause(); player.currentItem?.cancelPendingSeeks(); player.replaceCurrentItem(with: nil) }
        ownedPlayers = []; urls = []; durations = []
        position = 0; duration = 0; isPlaying = false; isLoading = false
        failure = nil; audibleURL = nil
    }

    deinit {
        if let observer, let clockPlayer { clockPlayer.removeTimeObserver(observer) }
        ownedPlayers.forEach { $0.pause() }
    }
}

struct VideoComparisonSheet: View {
    private struct PlaybackSelection: Hashable {
        let promptID: String
        let urls: [URL]
    }
    let run: ComparisonRun
    let store: ComparisonOutputStore
    let name: (String) -> String
    let onReview: (String, Int?) -> Void
    let reviewError: String?
    @Environment(\.dismiss) private var dismiss
    @State private var promptID: String
    @State private var leftPath: String?
    @State private var rightPath: String?
    @StateObject private var transport: VideoComparisonPlayer

    init(run: ComparisonRun, store: ComparisonOutputStore, selection: ImageInspectionSelection,
         name: @escaping (String) -> String, onReview: @escaping (String, Int?) -> Void,
         reviewError: String? = nil, transport: VideoComparisonPlayer? = nil) {
        self.run = run; self.store = store; self.name = name; self.onReview = onReview; self.reviewError = reviewError
        let clips = ComparisonViewLogic.videoClips(for: run, store: store, promptID: selection.promptID)
        let left = clips.first(where: { $0.modelPath == selection.modelPath })?.modelPath ?? clips.first?.modelPath
        _promptID = State(initialValue: selection.promptID)
        _leftPath = State(initialValue: left)
        _rightPath = State(initialValue: clips.first(where: { $0.modelPath != left })?.modelPath)
        _transport = StateObject(wrappedValue: transport ?? VideoComparisonPlayer())
    }

    private var clips: [ComparisonViewLogic.OutputClip] {
        ComparisonViewLogic.videoClips(for: run, store: store, promptID: promptID)
    }
    private var selected: [ComparisonViewLogic.OutputClip] {
        [leftPath, rightPath].compactMap { path in clips.first { $0.modelPath == path } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            HStack {
                Label("Video comparison", systemImage: "film").font(WorkbenchTypography.cardTitle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if ComparisonViewLogic.rows(for: run).count > 1 {
                Picker("Prompt", selection: $promptID) {
                    ForEach(ComparisonViewLogic.rows(for: run)) { Text($0.text).lineLimit(1).tag($0.id) }
                }
            } else if let entry = ComparisonViewLogic.rows(for: run).first {
                Text(entry.text).font(WorkbenchTypography.secondary).lineLimit(2).textSelection(.enabled)
            }
            HStack(spacing: WorkbenchSpacing.md) {
                lane("A", path: $leftPath, excluding: rightPath)
                lane("B", path: $rightPath, excluding: leftPath)
            }
            if let failure = transport.failure {
                HStack(spacing: WorkbenchSpacing.sm) {
                    ErrorBanner(text: failure)
                    Button("Retry") { Task { await transport.load(selected.map(\.url), preservingPosition: false) } }
                        .controlSize(.small)
                }
            }
            if let reviewError { ErrorBanner(text: reviewError) }
            HStack(spacing: WorkbenchSpacing.sm) {
                Button { Task { await transport.toggle() } } label: {
                    Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                }.accessibilityLabel(transport.isPlaying ? "Pause videos" : "Play videos")
                Slider(value: Binding(get: { transport.position }, set: { value in Task { await transport.seek(to: value) } }),
                       in: 0...max(transport.duration, 0.001))
                    .accessibilityLabel("Shared video position")
                Text(String(format: "%.1f / %.1f s", transport.position, transport.duration))
                    .font(WorkbenchTypography.secondaryTabular)
                Button("Reset") { Task { await transport.seek(to: 0) } }
                Picker("Audio", selection: Binding(get: { transport.audibleURL }, set: { transport.setAudio($0) })) {
                    Text("Off").tag(URL?.none)
                    if let clip = clips.first(where: { $0.modelPath == leftPath }) { Text("A").tag(URL?.some(clip.url)) }
                    if let clip = clips.first(where: { $0.modelPath == rightPath }) { Text("B").tag(URL?.some(clip.url)) }
                }.frame(width: 120)
            }
            .controlSize(.small)
            .disabled(transport.isLoading || transport.players.isEmpty || transport.failure != nil)
            Text("Shared elapsed time; shorter clips hold their last frame. Generated motion may differ.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
        }
        .padding(WorkbenchSpacing.pageInset)
        .frame(minWidth: 760, idealWidth: 1000, minHeight: 600, idealHeight: 680)
        .background(WorkbenchColor.canvas)
        .task(id: PlaybackSelection(promptID: promptID, urls: selected.map(\.url))) {
            await transport.load(selected.map(\.url))
        }
        .onChange(of: promptID) { _, _ in
            transport.stop()
            if !clips.contains(where: { $0.modelPath == leftPath }) { leftPath = clips.first?.modelPath }
            if !clips.contains(where: { $0.modelPath == rightPath }) || leftPath == rightPath {
                rightPath = clips.first(where: { $0.modelPath != leftPath })?.modelPath
            }
        }
        .onDisappear { transport.stop() }
    }

    private func lane(_ title: String, path: Binding<String?>, excluding: String?) -> some View {
        let clip = clips.first(where: { $0.modelPath == path.wrappedValue })
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            HStack(spacing: WorkbenchSpacing.sm) {
                Text(title).font(WorkbenchTypography.emphasis).foregroundStyle(WorkbenchColor.accent)
                Picker("Model \(title)", selection: path) {
                    Text("Choose model…").tag(String?.none)
                    ForEach(clips.filter { $0.modelPath != excluding }) { Text(name($0.modelPath)).tag(String?.some($0.modelPath)) }
                }.labelsHidden().frame(maxWidth: .infinity)
            }
            if let clip {
                TaskQualityRating(run: run, modelPath: clip.modelPath, modelName: name(clip.modelPath), store: store, onReview: onReview)
                if let index = transport.urls.firstIndex(of: clip.url), transport.players.indices.contains(index) {
                    SharedVideoPane(player: transport.players[index]).accessibilityLabel("Video \(title) from \(name(clip.modelPath))")
                } else {
                    ZStack { WorkbenchColor.surface; if transport.isLoading { ProgressView() } }
                }
            } else {
                Text("No available output for this prompt.").font(WorkbenchTypography.secondary)
                    .foregroundStyle(WorkbenchColor.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WorkbenchColor.surface)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SharedVideoPane: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .none; view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
