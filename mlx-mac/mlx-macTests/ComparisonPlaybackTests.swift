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
    func testListeningResultsRenderWithRealTransportAndUnavailableArtifactsAreExcluded() async throws {
        let id = UUID(), store = ComparisonOutputStore(root: root.appendingPathComponent("listening-output"))
        let directory = try store.createRunDirectory(id)
        let sources = [try silentClip("source-a", seconds: 5), try silentClip("source-b", seconds: 3)]
        let audioRoot = ProcessInfo.processInfo.environment["MLX_LISTENING_AUDIO_ROOT"].map { URL(fileURLWithPath: $0) }
        let audioNames = ["fixed-original-8bit-instrumental.wav", "fixed-converted-4bit-instrumental.wav"]
        var results: [VariantResult] = []
        for index in 0..<2 {
            let artifact = "\(index)-instrumental.wav", target = directory.appendingPathComponent(artifact)
            let source = audioRoot?.appendingPathComponent(audioNames[index]) ?? sources[index]
            try FileManager.default.copyItem(at: source, to: target)
            let sample = ComparisonSample(promptID: "instrumental", outputExcerpt: "", tokensPerSecond: nil,
                timeToFirstTokenSeconds: nil, error: nil, artifact: artifact, audioSeconds: try AVAudioPlayer(contentsOf: target).duration)
            results.append(VariantResult(modelPath: "/model/\(index)", modelSignature: nil, samples: [sample],
                aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil, aggregateMetric: index == 0 ? 1.2 : 0.9))
        }
        let run = ComparisonRun(id: id, promptSetID: "listening", promptSetName: "Instrumental comparison",
            useCase: nil, variants: results.map(\.modelPath), results: results, startedAt: Date(), finishedAt: Date(),
            state: .completed, mode: .musicGeneration,
            promptEntries: [PromptEntry(id: "instrumental", text: "Instrumental jazz-funk · Rhodes, bass and drums")])
        let clips = ComparisonViewLogic.audioClips(for: run, store: store, promptID: "instrumental")
        XCTAssertEqual(clips.count, 2)
        let player = AudioClipPlayer()
        defer { player.stop() }
        player.select(clips[0].url, autoplay: false)
        player.seek(to: 1)
        player.select(clips[1].url, preservingPosition: true, autoplay: false)
        XCTAssertEqual(player.position, 1, accuracy: 0.05)
        for width: CGFloat in [900, 600] {
            let content = MediaRunResultsView(run: run, store: store, contentWidth: width - 40, isRouteActive: true,
                name: { $0 == "/model/0" ? "Music model · 8-bit" : "Music model · 4-bit" },
                onReview: { _, _ in }, audio: player) { _ in EmptyView() }
                .padding(20).frame(width: width, height: 600)
                .background(WorkbenchColor.canvas).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Music listening \(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
            if let path = ProcessInfo.processInfo.environment["MLX_LISTENING_PROOF_DIR"] {
                let output = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent("listening-\(Int(width)).png"))
            }
            window.close()
        }
        try FileManager.default.removeItem(at: clips[0].url)
        XCTAssertEqual(ComparisonViewLogic.audioClips(for: run, store: store).map(\.modelPath), ["/model/1"])
        XCTAssertTrue(ComparisonViewLogic.audioClips(for: run, store: store, promptID: "missing").isEmpty)
    }

    @MainActor
    func testSpeechListeningRendersWithTaskRatingsAndStopsWhenLeavingCompare() async throws {
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
        for width: CGFloat in [900, 600] {
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
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Speech listening \(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
            if let path = ProcessInfo.processInfo.environment["MLX_SPEECH_LISTENING_PROOF_DIR"] {
                let output = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent("speech-listening-\(Int(width)).png"))
            }
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
    func testImageComparisonViewerRendersAndNativeZoomControlsDoNotWriteRatings() async throws {
        let probe = Process(), output = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        probe.arguments = ["-n", "hw.model"]; probe.standardOutput = output
        try probe.run(); probe.waitUntilExit()
        let model = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        try XCTSkipUnless(probe.terminationStatus == 0 && model.hasPrefix("VirtualMac"),
            "Keyboard presentation tests require an isolated VM; no test window was opened.")
        let store = ComparisonOutputStore(root: root.appendingPathComponent("image-viewer-proof"))
        var run = historyRun(.imageGeneration, "Shapes", at: 100, models: ["/image/a", "/image/b"])
        run.promptEntries = [PromptEntry(id: "shapes", text: "Simple geometric shapes on a white background")]
        let directory = try store.createRunDirectory(run.id)
        for (index, builtin) in ["red-circle", "blue-squares"].enumerated() {
            let output = try await ComparisonMediaFixtures.generateInput(
                for: PromptEntry(id: "image-\(index)", text: "", builtinInput: builtin), into: directory)
            run.results.append(VariantResult(modelPath: index == 0 ? "/image/a" : "/image/b", modelSignature: nil,
                samples: [ComparisonSample(promptID: "shapes", outputExcerpt: "", tokensPerSecond: nil,
                    timeToFirstTokenSeconds: nil, error: nil, artifact: output.lastPathComponent)],
                aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil))
        }
        run.qualityReviews = ["/image/b": ComparisonQualityReview(score: 4, rubricID: ComparisonQualityReview.taskOutcomeRubric, reviewedAt: Date())]
        for size in [CGSize(width: 1000, height: 720), CGSize(width: 760, height: 620)] {
            let content = ImageComparisonSheet(run: run, store: store,
                selection: ImageInspectionSelection(promptID: "shapes", modelPath: "/image/b"),
                name: { $0 == "/image/a" ? "Shape model A · 8-bit" : "Shape model B · 4-bit" },
                onReview: { _, _ in XCTFail("Inspection and zoom must not write ratings") })
                .frame(width: size.width, height: size.height).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            let focus = XCTAttachment(string: "Before keyboard preflight: active=\(NSApp.isActive), key=\(window.isKeyWindow), policy=\(NSApp.activationPolicy().rawValue), canBecomeKey=\(window.canBecomeKey), finishedLaunching=\(NSRunningApplication.current.isFinishedLaunching), running=\(NSApp.isRunning), bundle=\(NSRunningApplication.current.bundleIdentifier ?? "none")")
            focus.name = "Image inspection keyboard preflight"; focus.lifetime = .keepAlways; add(focus)
            if !NSApp.isActive {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                let activated = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                                                            configuration: configuration)
                XCTAssertEqual(activated.processIdentifier, ProcessInfo.processInfo.processIdentifier,
                               "Keyboard proof must activate this exact test host")
                window.makeKeyAndOrderFront(nil)
            }
            try await Task.sleep(for: .milliseconds(400))
            guard NSApp.isActive, window.isKeyWindow else {
                XCTFail("Keyboard delivery unavailable: active=\(NSApp.isActive), key=\(window.isKeyWindow), policy=\(NSApp.activationPolicy().rawValue)")
                return
            }
            host.layoutSubtreeIfNeeded()
            let initialBitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: initialBitmap)
            if let path = ProcessInfo.processInfo.environment["MLX_IMAGE_INSPECTION_PROOF_DIR"] {
                let output = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try XCTUnwrap(initialBitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("image-inspection-\(Int(size.width)).png"))
            }
            func panePixels() throws -> [Data] {
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let image = try XCTUnwrap(bitmap.cgImage)
                let scale = CGFloat(image.width) / size.width
                return try [CGFloat(34), size.width / 2 + 18].map { x in
                    let rect = CGRect(x: x * scale, y: 180 * scale,
                                      width: (size.width / 2 - 60) * scale, height: 360 * scale)
                    let pane = try XCTUnwrap(image.cropping(to: rect))
                    return try XCTUnwrap(NSBitmapImageRep(cgImage: pane).representation(using: .png, properties: [:]))
                }
            }
            func click(_ point: NSPoint) throws {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                }
            }
            if size.width == 1000 {
                // Native pointer events hit the fixed-viewport toolbar, then compare image-only regions.
                let fitted = try panePixels()
                try click(NSPoint(x: 443, y: 34))
                try await Task.sleep(for: .milliseconds(200))
                let zoomed = try panePixels()
                XCTAssertNotEqual(fitted[0], zoomed[0], "Zoom must change A's rendered image")
                XCTAssertNotEqual(fitted[1], zoomed[1], "The same zoom action must change B's rendered image")
                try click(NSPoint(x: 250, y: 330))
                try await Task.sleep(for: .milliseconds(100))
                let arrow = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{F703}",
                    charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
                window.sendEvent(arrow)
                try await Task.sleep(for: .milliseconds(200))
                let panned = try panePixels()
                XCTAssertNotEqual(zoomed[0], panned[0], "Arrow keys in A must pan A")
                XCTAssertNotEqual(zoomed[1], panned[1], "Arrow keys in A must also pan B")
                try click(NSPoint(x: 556, y: 34))
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertEqual(try panePixels(), fitted, "Reset must return both panes to fit")
            }
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Image comparison \(Int(size.width))"; attachment.lifetime = .keepAlways; add(attachment)
            if let path = ProcessInfo.processInfo.environment["MLX_IMAGE_INSPECTION_PROOF_DIR"] {
                let output = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent("image-inspection-\(Int(size.width)).png"))
            }
        }
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

    @MainActor
    func testVideoViewerHostsSharedPlayersAndReleasesThemOnDismissal() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("video-viewer-proof"))
        var run = historyRun(.videoGeneration, "Moving shapes", at: 100, models: ["/video/a", "/video/b"])
        run.promptEntries = [PromptEntry(id: "motion", text: "A red square moving steadily across a white background")]
        let directory = try store.createRunDirectory(run.id)
        let source = try await ComparisonMediaFixtures.generateInput(
            for: PromptEntry(id: "source", text: "", builtinInput: "red-square-right"), into: root)
        for key in ["a", "b"] {
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent("\(key).mp4"))
            run.results.append(VariantResult(modelPath: "/video/\(key)", modelSignature: nil,
                samples: [ComparisonSample(promptID: "motion", outputExcerpt: "", tokensPerSecond: nil,
                    timeToFirstTokenSeconds: nil, error: nil, artifact: "\(key).mp4")],
                aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil))
        }
        run.qualityReviews = ["/video/a": ComparisonQualityReview(score: 4, rubricID: ComparisonQualityReview.taskOutcomeRubric, reviewedAt: Date())]
        XCTAssertTrue(ComparisonViewLogic.showsVideoInspection(run))
        XCTAssertEqual(ComparisonViewLogic.videoClips(for: run, store: store, promptID: "motion").count, 2)
        XCTAssertTrue(ComparisonViewLogic.videoClips(for: run, store: store, promptID: "absent").isEmpty)
        let transport = VideoComparisonPlayer()
        for size in [CGSize(width: 1000, height: 680), CGSize(width: 760, height: 600)] {
            let content = VideoComparisonSheet(run: run, store: store,
                selection: ImageInspectionSelection(promptID: "motion", modelPath: "/video/a"),
                name: { $0 == "/video/a" ? "Video model A · 8-bit" : "Video model B · 4-bit" },
                onReview: { _, _ in XCTFail("Playback must not write ratings") }, transport: transport)
                .frame(width: size.width, height: size.height).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: AnyView(content))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            for _ in 0..<40 {
                if transport.players.count == 2, !transport.isLoading { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(transport.players.count, 2)
            XCTAssertNil(transport.failure)
            XCTAssertFalse(transport.isPlaying, "Opening the viewer must not autoplay")
            await transport.seek(to: 1.2)
            let playerClass = try XCTUnwrap(NSClassFromString("AVPlayerView"))
            func embeddedPlayers(_ view: NSView) -> [AVPlayer] {
                view.subviews.flatMap { child in
                    if child.isKind(of: playerClass), let player = child.value(forKey: "player") as? AVPlayer { return [player] }
                    return embeddedPlayers(child)
                }
            }
            host.layoutSubtreeIfNeeded()
            let embedded = embeddedPlayers(host)
            XCTAssertEqual(embedded.count, 2)
            XCTAssertTrue(embedded.allSatisfy { player in transport.players.contains { $0 === player } })
            for player in embedded { XCTAssertEqual(player.currentTime().seconds, 1.2, accuracy: 0.1) }
            try await Task.sleep(for: .milliseconds(200))
            func playerViews(_ view: NSView) -> [NSView] {
                view.subviews.flatMap { child in child.isKind(of: playerClass) ? [child] : playerViews(child) }
            }
            XCTAssertTrue(playerViews(host).allSatisfy { ($0.value(forKey: "readyForDisplay") as? Bool) == true },
                          "Both native video panes must have a frame ready for display")
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Video comparison \(Int(size.width))"; attachment.lifetime = .keepAlways; add(attachment)
            if let path = ProcessInfo.processInfo.environment["MLX_VIDEO_COMPARISON_PROOF_DIR"] {
                let output = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent("video-comparison-\(Int(size.width)).png"))
            }
            await transport.toggle()
            XCTAssertTrue(transport.isPlaying)
            host.rootView = AnyView(EmptyView())
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(transport.players.isEmpty, "Dismissing the viewer must release its transport")
            XCTAssertTrue(embedded.allSatisfy { $0.rate == 0 && $0.currentItem == nil })
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("b.mp4"))
        XCTAssertEqual(ComparisonViewLogic.videoClips(for: run, store: store, promptID: "motion").map(\.modelPath), ["/video/a"])
        run.state = .running; XCTAssertFalse(ComparisonViewLogic.showsVideoInspection(run))
        run.state = .completed; run.mode = .videoUnderstanding
        XCTAssertFalse(ComparisonViewLogic.showsVideoInspection(run))
        XCTAssertTrue(ComparisonViewLogic.videoClips(for: run, store: store, promptID: "motion").isEmpty)
    }
}
