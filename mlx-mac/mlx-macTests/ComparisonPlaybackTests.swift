import AppKit
import AVFoundation
import AVKit
import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

extension ComparisonMediaTests {
    func silentClip(_ name: String, seconds: Double = 5) throws -> URL {
        let url = root.appendingPathComponent(name).appendingPathExtension("wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let frames = AVAudioFrameCount(seconds * 8000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(frames))
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    @MainActor
    func testReleasingAudioOwnerInvalidatesItsRunLoopTimer() throws {
        var timer: Timer?
        var owner: AudioClipPlayer? = AudioClipPlayer(scheduleTimer: { interval, tick in
            let scheduled = Timer.scheduledTimer(withTimeInterval: interval, repeats: true, block: tick)
            timer = scheduled
            return scheduled
        }, makePlayer: { _ in StubAudioPlayback() })
        weak var released = owner
        owner?.toggle(root.appendingPathComponent("clip.wav"))
        XCTAssertTrue(try XCTUnwrap(timer).isValid)
        owner = nil
        XCTAssertNil(released)
        XCTAssertFalse(try XCTUnwrap(timer).isValid, "The run loop must not retain an orphaned repeating timer")
    }

    @MainActor
    func testSelectingAnotherClipKeepsPlaybackActiveInsteadOfStopping() throws {
        let a = StubAudioPlayback(), b = StubAudioPlayback()
        let first = root.appendingPathComponent("a.wav"), second = root.appendingPathComponent("b.wav")
        let player = AudioClipPlayer { $0 == first ? a : b }
        defer { player.stop() }
        player.toggle(first)
        XCTAssertTrue(player.isPlaying)
        player.toggle(second)
        XCTAssertTrue(player.isPlaying, "selecting B must replace A rather than just stopping A")
        XCTAssertFalse(a.isPlaying, "A and B must never play together")
        XCTAssertTrue(b.isPlaying)
        XCTAssertEqual(player.activeURL, second)
    }

    func testSharedListeningIsAvailableOnlyForCompletedAudioOutputRuns() {
        for mode in ComparisonMode.allCases {
            var run = historyRun(mode, "Listening", at: 100)
            XCTAssertEqual(ComparisonViewLogic.showsListening(run), mode == .textToSpeech || mode == .musicGeneration,
                           "Only generated audio has a shared listening transport: \(mode)")
            run.state = .running
            XCTAssertFalse(ComparisonViewLogic.showsListening(run))
        }
    }

    @MainActor
    func testPauseResumeScrubSwitchAndStopKeepOneTransport() throws {
        let a = StubAudioPlayback(), b = StubAudioPlayback(duration: 3)
        let first = root.appendingPathComponent("a.wav"), second = root.appendingPathComponent("b.wav")
        let player = AudioClipPlayer { $0 == first ? a : b }
        defer { player.stop() }
        player.toggle(first)
        player.seek(to: 2)
        player.toggle(first)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.position, 2)
        player.select(second, preservingPosition: true, autoplay: false)
        XCTAssertEqual(b.currentTime, 2)
        XCTAssertFalse(player.isPlaying)
        player.toggle(second)
        XCTAssertTrue(player.isPlaying)
        player.seek(to: 99)
        XCTAssertEqual(player.position, 3)
        XCTAssertFalse(player.isPlaying)
        player.seek(to: .nan)
        XCTAssertEqual(player.position, 3)
        player.toggle(second)
        XCTAssertEqual(b.currentTime, 0, "playing an ended clip restarts it")
        player.stop()
        XCTAssertNil(player.activeURL)
        XCTAssertEqual(player.duration, 0)
        XCTAssertFalse(b.isPlaying)
    }

    @MainActor
    func testRealWAVDecodingSeeksAndClampsWhenSwitchingToShorterAudio() throws {
        var decoded: [AVAudioPlayer] = []
        let player = AudioClipPlayer { url in
            let native = try AVAudioPlayer(contentsOf: url)
            decoded.append(native)
            return native
        }
        defer { player.stop() }
        player.select(try silentClip("long", seconds: 5), autoplay: false)
        player.seek(to: 4)
        player.select(try silentClip("short", seconds: 2), preservingPosition: true, autoplay: false)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(player.duration, 2, accuracy: 0.01)
        XCTAssertEqual(player.position, 2, accuracy: 0.01)
        XCTAssertFalse(decoded[0].isPlaying)
        XCTAssertFalse(decoded[1].isPlaying)
    }

    @MainActor
    func testUnreadableClipStopsPreviousAudioAndExposesItsFailure() {
        let first = root.appendingPathComponent("good.wav"), bad = root.appendingPathComponent("bad.wav")
        let a = StubAudioPlayback()
        let player = AudioClipPlayer { url in
            if url == first { return a }
            throw CocoaError(.fileReadCorruptFile)
        }
        player.toggle(first)
        player.select(bad, preservingPosition: true)
        XCTAssertFalse(a.isPlaying)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.activeURL)
        XCTAssertEqual(player.failureURL, bad)
        XCTAssertNotNil(player.failure)
    }

    @MainActor
    func testSpeechListeningKeepsPositionAndStopsWhenLeavingCompare() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("speech-output"))
        var run = historyRun(.textToSpeech, "Spoken sentences", at: 100, models: ["/speech/a", "/speech/b"])
        run.promptEntries = [PromptEntry(id: "sentence", text: "The quick brown fox jumps over the lazy dog.")]
        let directory = try store.createRunDirectory(run.id)
        run.results = try ["a", "b"].enumerated().map { index, key in
            let artifact = "\(key).wav"
            try FileManager.default.copyItem(at: silentClip("speech-\(key)", seconds: index == 0 ? 5 : 3),
                                            to: directory.appendingPathComponent(artifact))
            return VariantResult(modelPath: "/speech/\(key)", modelSignature: nil, samples: [
                ComparisonSample(promptID: "sentence", outputExcerpt: "", tokensPerSecond: nil,
                    timeToFirstTokenSeconds: nil, error: nil, artifact: artifact, audioSeconds: index == 0 ? 5 : 3)],
                aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil, aggregateMetric: index == 0 ? 1.2 : 0.9)
        }
        run.qualityReviews = ["/speech/a": ComparisonQualityReview(score: 4, rubricID: ComparisonQualityReview.taskOutcomeRubric,
                                                                 reviewedAt: Date())]
        let clips = ComparisonViewLogic.audioClips(for: run, store: store, promptID: "sentence")
        XCTAssertEqual(clips.count, 2)
        let player = AudioClipPlayer()
        defer { player.stop() }
        let width: CGFloat = 900
        do {
            func content(active: Bool) -> some View {
                MediaRunResultsView(run: run, store: store, contentWidth: width - 40, isRouteActive: active,
                    name: { $0 == "/speech/a" ? "Speech model A · 8-bit" : "Speech model B · 4-bit" },
                    onReview: { _, _ in XCTFail("Listening must not write quality ratings") }, audio: player) { _ in EmptyView() }
                    .padding(20).frame(width: width, height: 600)
                    .background(WorkbenchColor.canvas).preferredColorScheme(.dark)
            }
            let host = NSHostingView(rootView: content(active: true))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertNil(player.activeURL, "Opening speech results must not start playback")
            player.select(clips[0].url, autoplay: false)
            player.seek(to: 4)
            player.select(clips[1].url, preservingPosition: true, autoplay: false)
            XCTAssertEqual(player.position, 3, accuracy: 0.01)
            XCTAssertFalse(player.isPlaying, "Switching while paused stays paused")
            player.toggle(clips[0].url)
            XCTAssertTrue(player.isPlaying)
            host.rootView = content(active: false)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertNil(player.activeURL, "Leaving the Compare route must release playback even when results remain mounted")
            XCTAssertFalse(player.isPlaying)
        }
        try FileManager.default.removeItem(at: clips[0].url)
        XCTAssertEqual(ComparisonViewLogic.audioClips(for: run, store: store).map(\.modelPath), ["/speech/b"])
        XCTAssertNil(ComparisonViewLogic.qualityReviewUnavailableReason(run, modelPath: "/speech/b", store: store))
        XCTAssertNotNil(ComparisonViewLogic.qualityReviewUnavailableReason(run, modelPath: "/speech/a", store: store))
        XCTAssertEqual(run.qualityReviews?["/speech/a"]?.rubricID, ComparisonQualityReview.taskOutcomeRubric)
    }

    func testLinkedImageViewportFitsPansClampsAndResetsAcrossAspectRatios() {
        let canvas = CGSize(width: 400, height: 400)
        let landscape = CGSize(width: 800, height: 400)
        let portrait = CGSize(width: 400, height: 800)
        var viewport = ImageInspectionViewport()
        XCTAssertEqual(viewport.fittedSize(image: landscape, canvas: canvas), CGSize(width: 400, height: 200))
        XCTAssertEqual(viewport.offset(image: landscape, canvas: canvas), .zero)
        viewport.setZoom(2)
        viewport.pan(by: CGSize(width: 80, height: 60), image: landscape, canvas: canvas)
        XCTAssertEqual(viewport.offset(image: landscape, canvas: canvas), CGSize(width: 80, height: 0))
        XCTAssertEqual(viewport.offset(image: portrait, canvas: canvas), .zero,
                       "The linked normalized position must clamp to each image's visible bounds")
        viewport.setZoom(4)
        viewport.pan(by: CGSize(width: 10_000, height: -10_000), image: landscape, canvas: canvas)
        XCTAssertEqual(viewport.offset(image: landscape, canvas: canvas), CGSize(width: 600, height: -200))
        XCTAssertEqual(viewport.offset(image: portrait, canvas: canvas), CGSize(width: 200, height: -400))
        viewport.setZoom(.infinity)
        XCTAssertEqual(viewport.zoom, 4)
        viewport.setZoom(100)
        XCTAssertEqual(viewport.zoom, 8)
        viewport.reset()
        XCTAssertEqual(viewport.zoom, 1)
        XCTAssertEqual(viewport.center, .zero)
        XCTAssertEqual(viewport.fittedSize(image: .zero, canvas: canvas), .zero)
        XCTAssertEqual(viewport.offset(image: landscape, canvas: .zero), .zero)
    }

    @MainActor
    func testImageInspectionPairsOnlyAvailableOutputsFromTheSelectedPrompt() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("image-inspection"))
        var run = historyRun(.imageGeneration, "Images", at: 100, models: ["/a", "/b"])
        let directory = try store.createRunDirectory(run.id)
        let fixture = try await ComparisonMediaFixtures.generateInput(
            for: PromptEntry(id: "fixture", text: "", builtinInput: "red-circle"), into: directory)
        try FileManager.default.copyItem(at: fixture, to: directory.appendingPathComponent("a.png"))
        run.results = ["/a", "/b"].map { path in
            VariantResult(modelPath: path, modelSignature: nil, samples: [
                ComparisonSample(promptID: "first", outputExcerpt: "", tokensPerSecond: nil, timeToFirstTokenSeconds: nil,
                                 error: nil, artifact: path == "/a" ? "a.png" : "pruned.png"),
                ComparisonSample(promptID: "second", outputExcerpt: "", tokensPerSecond: nil, timeToFirstTokenSeconds: nil,
                                 error: nil, artifact: "a.png")],
                aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil)
        }
        XCTAssertTrue(ComparisonViewLogic.showsImageInspection(run))
        XCTAssertEqual(ComparisonViewLogic.imageClips(for: run, store: store, promptID: "first").map(\.modelPath), ["/a"])
        XCTAssertEqual(ComparisonViewLogic.imageClips(for: run, store: store, promptID: "second").count, 2)
        XCTAssertTrue(ComparisonViewLogic.imageClips(for: run, store: store, promptID: "absent").isEmpty)
        run.state = .running
        XCTAssertFalse(ComparisonViewLogic.showsImageInspection(run))
        run.state = .completed; run.mode = .textToSpeech
        XCTAssertFalse(ComparisonViewLogic.showsImageInspection(run))
        XCTAssertTrue(ComparisonViewLogic.imageClips(for: run, store: store, promptID: "second").isEmpty)
    }

    @MainActor
    func testVideoComparisonTransportLoadsRealClipsPausedSeeksBothAndReleasesPlayers() async throws {
        let first = try await ComparisonMediaFixtures.generateInput(
            for: PromptEntry(id: "video-a", text: "", builtinInput: "red-square-right"), into: root)
        let second = root.appendingPathComponent("video-b.mp4")
        let export = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: first), presetName: AVAssetExportPresetPassthrough))
        export.outputURL = second; export.outputFileType = .mp4
        export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 1.5, preferredTimescale: 600))
        await withCheckedContinuation { continuation in
            export.exportAsynchronously { continuation.resume() }
        }
        XCTAssertEqual(export.status, .completed)
        let transport = VideoComparisonPlayer()
        await transport.load([first, second])
        XCTAssertNil(transport.failure)
        XCTAssertEqual(transport.players.count, 2)
        XCTAssertEqual(transport.duration, 3, accuracy: 0.2)
        XCTAssertFalse(transport.isPlaying)
        XCTAssertTrue(transport.players.allSatisfy { $0.rate == 0 && $0.isMuted })
        await transport.seek(to: 1.2)
        for player in transport.players { XCTAssertEqual(player.currentTime().seconds, 1.2, accuracy: 0.1) }
        transport.setAudio(first)
        XCTAssertFalse(transport.players[0].isMuted)
        XCTAssertTrue(transport.players[1].isMuted)
        await transport.toggle()
        XCTAssertTrue(transport.isPlaying)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertGreaterThan(transport.players[0].currentTime().seconds, 1.3, "The real decoder must advance during playback")
        XCTAssertEqual(transport.players[1].currentTime().seconds,
                       min(transport.players[0].currentTime().seconds, 1.5), accuracy: 0.15)
        XCTAssertTrue(transport.isPlaying, "The longer clip continues after the shorter clip ends")
        transport.pause()
        XCTAssertFalse(transport.isPlaying)
        XCTAssertTrue(transport.players.allSatisfy { $0.rate == 0 })
        await transport.seek(to: 2.5)
        XCTAssertEqual(transport.players[0].currentTime().seconds, 2.5, accuracy: 0.1)
        XCTAssertEqual(transport.players[1].currentTime().seconds, 1.5, accuracy: 0.2,
                       "The shorter clip must clamp independently")
        await transport.toggle()
        await transport.load([second])
        XCTAssertEqual(transport.position, transport.duration, accuracy: 0.2)
        XCTAssertFalse(transport.isPlaying, "Switching to an ended shorter clip must not restart it")
        await transport.seek(to: 99)
        XCTAssertEqual(transport.position, transport.duration, accuracy: 0.1)
        await transport.seek(to: .nan)
        XCTAssertEqual(transport.position, transport.duration, accuracy: 0.1)
        await transport.toggle()
        XCTAssertEqual(transport.position, 0, accuracy: 0.1, "Playing an ended comparison restarts both clips")
        transport.pause()
        let players = transport.players
        transport.stop()
        XCTAssertTrue(transport.players.isEmpty)
        XCTAssertEqual(transport.position, 0)
        XCTAssertTrue(players.allSatisfy { $0.rate == 0 && $0.currentItem == nil })
        await transport.load([root.appendingPathComponent("missing.mp4")])
        XCTAssertNotNil(transport.failure)
        XCTAssertFalse(transport.isLoading)
        XCTAssertTrue(transport.players.isEmpty)
        let loading = Task { await transport.load([first, second]) }
        for _ in 0..<20 {
            if transport.isLoading || !transport.players.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        transport.stop()
        await loading.value
        XCTAssertTrue(transport.players.isEmpty, "A late load must not revive a closed transport")
        XCTAssertFalse(transport.isLoading)
    }
}
