import AVFoundation
import SwiftUI

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
