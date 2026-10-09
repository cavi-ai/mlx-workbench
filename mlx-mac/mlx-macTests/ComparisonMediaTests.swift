import AppKit
import AVFoundation
import Foundation
import ImageIO
import SwiftUI
import XCTest

@testable import mlx_workbench

private struct IdleProber: EndpointProbing {
    func listModels(baseURL: URL) async -> [String] { [] }
    func isReady(baseURL: URL) async -> Bool { true }
    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int) async throws -> ProbeSample {
        throw StubMediaError.chatNotExpected
    }
}

private enum StubMediaError: Error { case chatNotExpected, modelFailed }

@MainActor
private final class StubAudioPlayback: AudioClipPlayback {
    var currentTime: TimeInterval = 0
    let duration: TimeInterval
    private(set) var isPlaying = false
    init(duration: TimeInterval = 5) { self.duration = duration }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false; currentTime = 0 }
}

/// Stands in for the agent: records every request, writes the output file for file modes.
private actor StubMediaRunner: ComparisonMediaRunner {
    private(set) var requests: [MediaRunRequest] = []
    private var failingModels: Set<String>
    /// Nil: requests run at once. Otherwise each request waits for a permit from `release`.
    private var permits: Int?

    init(failingModels: Set<String> = [], gated: Bool = false) {
        self.failingModels = failingModels
        self.permits = gated ? 0 : nil
    }

    func release(_ count: Int) { permits = (permits ?? 0) + count }

    func run(_ request: MediaRunRequest) async throws -> MediaRunOutput {
        requests.append(request)
        if permits != nil {
            while permits == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
            permits! -= 1
        }
        if failingModels.contains(request.modelPath) { throw StubMediaError.modelFailed }
        if let out = request.outputURL { try Data("stub".utf8).write(to: out) }
        switch request.mode {
        case .chat:
            throw ComparisonMediaError.notAMediaMode
        case .vision, .videoUnderstanding:
            return MediaRunOutput(
                text: "A red circle moving to the right", seconds: 2, loadSeconds: 1,
                generationTokens: 8, generationTokensPerSecond: 40, peakMemoryGB: 3
            )
        case .speechToText:
            return MediaRunOutput(text: request.entry.text, seconds: 1, audioSeconds: 4)
        case .textToSpeech, .musicGeneration:
            return MediaRunOutput(seconds: 3, audioSeconds: 6, realTimeFactor: 0.5)
        case .imageGeneration:
            return MediaRunOutput(seconds: 40, steps: 20, pixelStd: 60)
        case .videoGeneration:
            return MediaRunOutput(seconds: 18, frames: 9, secondsPerFrame: 2, pixelStd: 50)
        }
    }
}

final class ComparisonMediaTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("compare-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Modes

    func testEachModeNamesTheTaskTypesItAcceptsAndItsMetric() {
        XCTAssertEqual(ComparisonMode.chat.acceptedTaskTypes, [.textLLM, .visionLanguage])
        XCTAssertEqual(ComparisonMode.vision.acceptedTaskTypes, [.visionLanguage])
        XCTAssertEqual(ComparisonMode.videoUnderstanding.acceptedTaskTypes, [.visionLanguage])
        XCTAssertEqual(ComparisonMode.speechToText.acceptedTaskTypes, [.speechToText])
        XCTAssertEqual(ComparisonMode.textToSpeech.acceptedTaskTypes, [.textToSpeech])
        XCTAssertEqual(ComparisonMode.imageGeneration.acceptedTaskTypes, [.imageGeneration])
        XCTAssertEqual(ComparisonMode.videoGeneration.acceptedTaskTypes, [.videoGeneration])
        XCTAssertEqual(ModelTaskType.videoGeneration.title, "Video generation")
        XCTAssertFalse(ModelTaskType.videoGeneration.isServable)
        XCTAssertFalse(ModelTaskType.videoGeneration.hasCanary)

        XCTAssertEqual(ComparisonMode.chat.primaryMetric, .tokensPerSecond)
        XCTAssertEqual(ComparisonMode.vision.primaryMetric, .generationTokensPerSecond)
        XCTAssertEqual(ComparisonMode.videoUnderstanding.primaryMetric, .generationTokensPerSecond)
        XCTAssertEqual(ComparisonMode.speechToText.primaryMetric, .realTimeFactor)
        XCTAssertEqual(ComparisonMode.textToSpeech.primaryMetric, .realTimeFactor)
        XCTAssertEqual(ComparisonMode.imageGeneration.primaryMetric, .secondsPerStep)
        XCTAssertEqual(ComparisonMode.videoGeneration.primaryMetric, .secondsPerFrame)
        XCTAssertEqual(ComparisonMode.vision.inputKind, .image)
        XCTAssertEqual(ComparisonMode.videoUnderstanding.inputKind, .video)
        XCTAssertEqual(ComparisonMode.speechToText.inputKind, .audio)
        XCTAssertNil(ComparisonMode.imageGeneration.inputKind)
        XCTAssertEqual(ComparisonMode.allCases.count, 8)
        XCTAssertEqual(ComparisonMode.musicGeneration.acceptedTaskTypes, [.musicGeneration])
        XCTAssertEqual(ComparisonMode.musicGeneration.outputKind, .audio)
        XCTAssertEqual(ComparisonMode.musicGeneration.primaryMetric, .realTimeFactor)
        XCTAssertFalse(ModelTaskType.musicGeneration.isServable)
        XCTAssertFalse(ModelTaskType.musicGeneration.hasCanary)
    }

    private func model(_ path: String, type: ModelTaskType?) -> LibraryModel {
        let task = type.map { ModelTask(type: $0, useCases: [], source: "test", confidence: "likely") }
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: 1000,
            modifiedAt: nil, shard: nil, modelKey: nil, architecture: nil, quantization: "Q4",
            parameters: nil, structure: nil, signature: nil, companion: nil, readable: true,
            status: "ready", outputs: [], tensorCount: nil, error: nil, task: task
        )
        return LibraryModel(item: item, readiness: .ready)
    }

    func testCandidatesFollowTheModesAcceptedTypes() {
        let models = [
            model("/llm", type: .textLLM), model("/vlm", type: .visionLanguage), model("/stt", type: .speechToText),
            model("/tts", type: .textToSpeech), model("/img", type: .imageGeneration), model("/vid", type: .videoGeneration),
            model("/unlabelled", type: nil), model("/emb", type: .embedding), model("/music", type: .musicGeneration),
        ]
        func paths(_ mode: ComparisonMode) -> [String] {
            ComparisonViewLogic.candidates(from: models, mode: mode).map(\.item.path)
        }
        XCTAssertEqual(paths(.chat), ["/llm", "/vlm", "/unlabelled"])
        XCTAssertEqual(paths(.chat), ComparePresentation.candidates(from: models).map(\.item.path))
        XCTAssertEqual(paths(.vision), ["/vlm"])
        XCTAssertEqual(paths(.videoUnderstanding), ["/vlm"])
        XCTAssertEqual(paths(.speechToText), ["/stt"])
        XCTAssertEqual(paths(.textToSpeech), ["/tts"])
        XCTAssertEqual(paths(.imageGeneration), ["/img"])
        XCTAssertEqual(paths(.videoGeneration), ["/vid"])
        XCTAssertEqual(paths(.musicGeneration), ["/music"])
    }

    func testPromptSetsAreFilteredByModeAndBuiltinMediaSetsAreWellFormed() {
        let all = BuiltinPromptSets.all + ComparisonMediaFixtures.all
        XCTAssertEqual(ComparisonViewLogic.promptSets(all, for: .chat).count, BuiltinPromptSets.all.count)
        for mode in ComparisonMode.allCases where mode != .chat {
            let sets = ComparisonViewLogic.promptSets(all, for: mode)
            XCTAssertEqual(sets.count, 1, "\(mode)")
            XCTAssertFalse(sets[0].prompts.isEmpty)
            for entry in sets[0].prompts {
                XCTAssertEqual(entry.inputKind, mode.inputKind, "\(entry.id)")
                if mode.inputKind != nil { XCTAssertNotNil(entry.builtinInput) }
            }
        }
        XCTAssertEqual(ComparisonMediaFixtures.imageGenerationSet.prompts.map(\.media), Array(repeating: MediaParameters(size: 512, steps: 20, seed: 42), count: 2))
        XCTAssertEqual(ComparisonMediaFixtures.videoGenerationSet.prompts.count, 1)
        XCTAssertEqual(
            ComparisonMediaFixtures.videoGenerationSet.prompts[0].media,
            MediaParameters(width: 416, height: 240, steps: 30, seed: 42, frames: 17)
        )
        XCTAssertEqual(ComparisonMediaFixtures.videoGenerationSet.prompts[0].text, "A red ball bouncing on a wooden floor")
        let words = ComparisonMediaFixtures.textToSpeechSet.prompts[1].text.split(separator: " ").count
        XCTAssertEqual(words, 25)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    }

    // MARK: Decoding

    func testLegacySampleAndRunFilesDecodeWithoutTheNewFields() throws {
        let sample = #"{"promptID":"p","outputExcerpt":"hi","tokensPerSecond":12.5,"timeToFirstTokenSeconds":0.2}"#
        let decoded = try JSONDecoder().decode(ComparisonSample.self, from: Data(sample.utf8))
        XCTAssertEqual(decoded.tokensPerSecond, 12.5)
        XCTAssertNil(decoded.fullOutput)
        XCTAssertNil(decoded.artifact)
        XCTAssertNil(decoded.wordErrorRate)

        let run = """
        {"id":"\(UUID().uuidString)","promptSetID":"builtin-coding","promptSetName":"Coding","variants":["/m"],
         "results":[{"modelPath":"/m","samples":[\(sample)],"aggregateTokensPerSecond":12.5}],
         "startedAt":780000000,"state":"completed"}
        """
        let legacy = try JSONDecoder().decode(ComparisonRun.self, from: Data(run.utf8))
        XCTAssertNil(legacy.mode)
        XCTAssertEqual(legacy.effectiveMode, .chat)
        XCTAssertNil(legacy.results[0].aggregateMetric)
        XCTAssertNil(legacy.promptEntries)

        let entry = #"{"id":"e","text":"t","maxTokens":64}"#
        let decodedEntry = try JSONDecoder().decode(PromptEntry.self, from: Data(entry.utf8))
        XCTAssertNil(decodedEntry.inputKind)
        XCTAssertNil(decodedEntry.expectedKeywords)
        let set = try JSONDecoder().decode(PromptSet.self, from: Data(#"{"id":"s","name":"n","prompts":[],"origin":"userCreated"}"#.utf8))
        XCTAssertEqual(set.effectiveMode, .chat)
    }

    func testNewSampleAndRunRoundTrip() throws {
        let sample = ComparisonSample(
            promptID: "p", outputExcerpt: "hi", tokensPerSecond: nil, timeToFirstTokenSeconds: nil, error: nil,
            fullOutput: "hi there", artifact: "0-p.txt", seconds: 2, loadSeconds: 1, audioSeconds: 4,
            realTimeFactor: 0.5, wordErrorRate: 0.1, keywordsMatched: true, generationTokens: 8,
            generationTokensPerSecond: 40, peakMemoryGB: 3, secondsPerStep: 2, secondsPerFrame: 1, pixelStd: 50
        )
        let run = ComparisonRun(
            id: UUID(), promptSetID: "s", promptSetName: "S", useCase: nil, variants: ["/m"],
            results: [VariantResult(modelPath: "/m", modelSignature: nil, samples: [sample], aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil, aggregateMetric: 0.5)],
            startedAt: Date(timeIntervalSinceReferenceDate: 5), finishedAt: nil, state: .completed,
            mode: .speechToText, promptEntries: [PromptEntry(id: "p", text: "hi", inputKind: .audio, inputPath: "/a.wav")]
        )
        let again = try JSONDecoder().decode(ComparisonRun.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(again, run)
        XCTAssertEqual(again.effectiveMode, .speechToText)
    }

    // MARK: Agent arguments and results

    func testMusicParametersRoundTripAndKeepQualityUnknown() throws {
        let parameters = MediaParameters(steps: 12, seed: 7, durationSeconds: 20, lyrics: "[verse]\nA new day")
        XCTAssertEqual(try JSONDecoder().decode(MediaParameters.self, from: JSONEncoder().encode(parameters)), parameters)
        let old = try JSONDecoder().decode(MediaParameters.self, from: Data("{\"steps\":20}".utf8))
        XCTAssertNil(old.lyrics)
        XCTAssertNil(old.durationSeconds)
        XCTAssertEqual(WorkbenchAPI.musicArguments(path: "/local/music", caption: "-piano", out: "/out.wav", parameters: parameters),
                       ["convert", "music", "--path", "/local/music", "--caption=-piano", "--lyrics=[verse]\nA new day", "--out", "/out.wav", "--duration", "20.0", "--steps", "12", "--seed", "7", "--timeout", "3600"])
        let sample = ComparisonMediaScoring.sample(mode: .musicGeneration, entry: PromptEntry(id: "p", text: "piano"),
                                                  output: MediaRunOutput(seconds: 10, audioSeconds: 20), artifact: "0-p.wav")
        XCTAssertEqual(sample.realTimeFactor, 0.5)
        XCTAssertNil(sample.wordErrorRate)
        XCTAssertNil(sample.keywordsMatched)
    }

    func testReuseMusicSetupUsesRecordedPromptsAndPreservesOptionalParameters() throws {
        let prompts = [PromptEntry(id: "one", text: "  jazz-funk instrumental\n", maxTokens: 77,
                                  media: MediaParameters(steps: 12, seed: 7, durationSeconds: 12.5, lyrics: "[instrumental]")),
                       PromptEntry(id: "two", text: "Acoustic guitar", media: nil)]
        var run = historyRun(.musicGeneration, "Saved music", at: 10, models: ["/a", "/b"])
        run.promptEntries = prompts
        let setup = try MusicComparisonSetup(run: run)
        let prepared = try setup.promptSet()
        XCTAssertEqual(prepared.prompts, prompts, "reuse must not substitute the current preset or invented defaults")
        XCTAssertEqual(prepared.effectiveMode, .musicGeneration)
        XCTAssertNotEqual(prepared.id, run.promptSetID)
        XCTAssertEqual(setup.modelPaths, ["/a", "/b"])
        XCTAssertEqual(setup.id, run.id)
        XCTAssertEqual(run.promptEntries, prompts)
    }

    func testReuseMusicSetupEditsEachPromptWithoutChangingItsPeers() throws {
        var run = historyRun(.musicGeneration, "Saved music", at: 10)
        run.promptEntries = [PromptEntry(id: "a", text: "Jazz", media: MediaParameters(steps: 12, seed: 7, durationSeconds: 20, lyrics: "[instrumental]")),
                             PromptEntry(id: "b", text: "Piano", media: MediaParameters(steps: 8, seed: 0, durationSeconds: 9, lyrics: "[verse]\nA new day"))]
        var setup = try MusicComparisonSetup(run: run)
        setup.prompts[0].caption = "Funk"
        setup.prompts[0].duration = "15.5"
        setup.prompts[0].steps = "6"
        setup.prompts[0].seed = "4294967295"
        let prepared = try setup.promptSet()
        XCTAssertEqual(prepared.prompts[0].text, "Funk")
        XCTAssertEqual(prepared.prompts[0].media, MediaParameters(steps: 6, seed: 4_294_967_295, durationSeconds: 15.5, lyrics: "[instrumental]"))
        XCTAssertEqual(prepared.prompts[1], run.promptEntries?[1])
        XCTAssertEqual(run.promptEntries?.first?.text, "Jazz")
    }

    func testReuseRefusesMissingSnapshotsAndInvalidMusicArguments() throws {
        var run = historyRun(.musicGeneration, "Legacy", at: 10)
        XCTAssertThrowsError(try MusicComparisonSetup(run: run))
        run.promptEntries = []
        XCTAssertThrowsError(try MusicComparisonSetup(run: run))
        run.promptEntries = [PromptEntry(id: "p", text: "Piano")]
        for value in ["NaN", "infinity", "0", "361", "garbage"] {
            var setup = try MusicComparisonSetup(run: run)
            setup.prompts[0].duration = value
            XCTAssertThrowsError(try setup.promptSet(), value)
        }
        for value in ["0", "31", "2.5"] {
            var setup = try MusicComparisonSetup(run: run)
            setup.prompts[0].steps = value
            XCTAssertThrowsError(try setup.promptSet(), value)
        }
        for value in ["-1", "4294967296", "garbage"] {
            var setup = try MusicComparisonSetup(run: run)
            setup.prompts[0].seed = value
            XCTAssertThrowsError(try setup.promptSet(), value)
        }
        run.mode = .chat
        XCTAssertThrowsError(try MusicComparisonSetup(run: run))
    }

    private func historyRun(_ mode: ComparisonMode, _ title: String, at time: TimeInterval, models: [String] = ["/model"]) -> ComparisonRun {
        ComparisonRun(id: UUID(), promptSetID: "set", promptSetName: title, useCase: nil, variants: models, results: [],
                      startedAt: Date(timeIntervalSince1970: time), finishedAt: nil, state: .completed, mode: mode)
    }

    func testHistoryGroupsModesSortsNewestAndSearchesModels() {
        let older = historyRun(.chat, "Tool calling", at: 10)
        let newer = historyRun(.chat, "Tool calling", at: 20)
        let music = historyRun(.musicGeneration, "Instrumental sketches", at: 30, models: ["/MiniMax-4bit", "/MiniMax-8bit"])
        let groups = ComparisonHistoryLogic.groups([older, music, newer], query: "")
        XCTAssertEqual(groups.map(\.mode), [.chat, .musicGeneration])
        XCTAssertEqual(groups.first?.runs.map(\.id), [newer.id, older.id])
        XCTAssertEqual(ComparisonHistoryLogic.groups([older, music], query: "  MINIMAX  ").first?.runs.map(\.id), [music.id])
        XCTAssertTrue(ComparisonHistoryLogic.groups([older], query: "music").isEmpty)
        XCTAssertEqual(ComparisonHistoryLogic.modelCount(older), "1 model")
        XCTAssertEqual(ComparisonHistoryLogic.modelCount(music), "2 models")
    }

    @MainActor
    func testHistoryPopoverRendersGroupedReadableRows() async throws {
        let modes: [ComparisonMode] = [.chat, .chat, .vision, .musicGeneration, .imageGeneration]
        let names = ["Tool calling", "Tool calling", "Vision basics", "Instrumental sketches", "Image prompts"]
        let runs = zip(modes, names).enumerated().map { index, pair in
            historyRun(pair.0, pair.1, at: 1_791_388_800 + Double(index * 180), models: index == 4 ? ["/one"] : ["/one", "/two"])
        }
        let picker = ComparisonHistoryPicker(runs: runs, selection: .constant(runs[3].id))
        let root = VStack(alignment: .leading, spacing: 20) {
            picker
            ComparisonHistoryPanel(runs: runs, selection: runs[3].id, onSelect: { _ in })
        }.padding(20).frame(width: 480, height: 600).background(WorkbenchColor.canvas).preferredColorScheme(.dark)
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "Grouped comparison history"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAgentArgumentsKeepTextAsOneTokenAndShrinkVideoFrames() {
        XCTAssertEqual(
            WorkbenchAPI.speakArguments(path: "/m", text: "-dash start", out: "/o.wav"),
            ["convert", "speak", "--path", "/m", "--text=-dash start", "--out", "/o.wav", "--timeout", "600"]
        )
        let image = WorkbenchAPI.describeArguments(path: "/m", prompt: "What?", image: "/i.png", video: nil, maxTokens: 96)
        XCTAssertTrue(image.contains("--prompt=What?"))
        XCTAssertEqual(image.firstIndex(of: "--image").map { image[$0 + 1] }, "/i.png")
        XCTAssertFalse(image.contains("--max-pixels"))
        let video = WorkbenchAPI.describeArguments(path: "/m", prompt: "What?", image: nil, video: "/v.mp4", maxTokens: 128)
        XCTAssertEqual(video.firstIndex(of: "--max-pixels").map { video[$0 + 1] }, "200704")
        XCTAssertEqual(video.firstIndex(of: "--video").map { video[$0 + 1] }, "/v.mp4")
        XCTAssertEqual(video.firstIndex(of: "--max-tokens").map { video[$0 + 1] }, "128")

        let render = WorkbenchAPI.videoArguments(
            path: "/m", prompt: "A red ball", out: "/o.mp4", parameters: ComparisonMediaFixtures.videoGenerationParameters
        )
        XCTAssertEqual(
            render,
            ["convert", "video", "--path", "/m", "--prompt=A red ball", "--out", "/o.mp4", "--timeout", "3600",
             "--width", "416", "--height", "240", "--frames", "17", "--steps", "30", "--seed", "42"]
        )
        XCTAssertFalse(render.contains("--fps"), "an unset fps leaves the model's default")
    }

    func testAgentResultsDecodeTheContractKeys() throws {
        let speak = #"{"schema":"speak/1","path":"/o.wav","sample_rate":24000,"audio_seconds":4.5,"seconds":2.25,"load_seconds":1.5,"real_time_factor":0.5,"peak_memory_gb":1.25}"#
        let spoken = try JSONDecoder().decode(SpeakResult.self, from: Data(speak.utf8))
        XCTAssertEqual(spoken.realTimeFactor, 0.5)
        XCTAssertEqual(spoken.audioSeconds, 4.5)
        let describe = #"{"schema":"describe/1","text":"A red square.","prompt_tokens":120,"generation_tokens":9,"prompt_tps":300.5,"generation_tps":41.5,"peak_memory_gb":3.5,"seconds":2,"load_seconds":1,"input":{"kind":"video","path":"/v.mp4"}}"#
        let described = try JSONDecoder().decode(DescribeResult.self, from: Data(describe.utf8))
        XCTAssertEqual(described.generationTps, 41.5)
        XCTAssertEqual(described.generationTokens, 9)
        let video = #"{"schema":"video/1","path":"/o.mp4","width":416,"height":240,"frames":20,"fps":16.0,"duration_seconds":1.25,"steps":30,"seed":42,"seconds":33,"load_seconds":6,"seconds_per_frame":1.65,"peak_memory_gb":9,"pixel_std":52.5}"#
        let rendered = try JSONDecoder().decode(VideoResult.self, from: Data(video.utf8))
        XCTAssertEqual(rendered.frames, 20)
        XCTAssertEqual(rendered.fps, 16)
        XCTAssertEqual(rendered.secondsPerFrame, 1.65)
    }

    func testVendoredResultFixturesDecodeThroughTheProductionPath() throws {
        let spoken = try WorkbenchAPI.decode(SpeakResult.self, from: try vendoredFixture("convert-speak"))
        XCTAssertEqual(spoken.path, "/tmp/mlx-agent/fox.wav")
        XCTAssertEqual(spoken.sampleRate, 32000)
        XCTAssertEqual(spoken.audioSeconds, 2.624)
        XCTAssertEqual(spoken.seconds, 1.848)
        XCTAssertEqual(spoken.loadSeconds, 2.238)
        XCTAssertEqual(spoken.realTimeFactor, 0.7041)
        XCTAssertEqual(spoken.peakMemoryGB, 0.24)

        let described = try WorkbenchAPI.decode(DescribeResult.self, from: try vendoredFixture("convert-describe"))
        XCTAssertEqual(described.text, "The image shows a red circle.")
        XCTAssertEqual(described.promptTokens, 55)
        XCTAssertEqual(described.generationTokens, 8)
        XCTAssertEqual(described.promptTps, 46.694)
        XCTAssertEqual(described.generationTps, 222.039)
        XCTAssertEqual(described.peakMemoryGB, 3.244)
        XCTAssertEqual(described.seconds, 1.253)
        XCTAssertEqual(described.loadSeconds, 0.485)

        let rendered = try WorkbenchAPI.decode(VideoResult.self, from: try vendoredFixture("convert-video"))
        XCTAssertEqual(rendered.path, "/tmp/mlx-agent/red-ball-416.mp4")
        XCTAssertEqual(rendered.width, 416)
        XCTAssertEqual(rendered.height, 240)
        XCTAssertEqual(rendered.frames, 20)
        XCTAssertEqual(rendered.fps, 16)
        XCTAssertEqual(rendered.durationSeconds, 1.25)
        XCTAssertEqual(rendered.steps, 30)
        XCTAssertEqual(rendered.seed, 42)
        XCTAssertEqual(rendered.seconds, 27.021)
        XCTAssertEqual(rendered.loadSeconds, 1.372)
        XCTAssertEqual(rendered.secondsPerFrame, 1.351)
        XCTAssertEqual(rendered.peakMemoryGB, 25.596)
        XCTAssertEqual(rendered.pixelStd, 54.353)
    }

    private func vendoredFixture(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // mlx-macTests
            .deletingLastPathComponent()   // mlx-mac
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("vendor/mlx-agent/tests/fixtures/\(name).json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: Output store

    func testRetentionPrunesOnlyUUIDNamedDirectoriesAndKeepsTheKeptSet() throws {
        let store = ComparisonOutputStore(root: root)
        let ids = (0..<12).map { _ in UUID() }
        for id in ids { try store.createRunDirectory(id) }
        let stranger = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        let strayFile = root.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: strayFile)

        let keep = Set(ids.prefix(ComparisonOutputStore.retainedRuns))
        let removed = store.prune(keeping: keep)

        XCTAssertEqual(Set(removed), Set(ids.suffix(2)))
        for id in ids.prefix(10) { XCTAssertTrue(FileManager.default.fileExists(atPath: store.runDirectory(id).path)) }
        for id in ids.suffix(2) { XCTAssertFalse(FileManager.default.fileExists(atPath: store.runDirectory(id).path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: strayFile.path), "a file named like a run is not a run directory")
    }

    func testPruneNeverFollowsASymbolicLink() throws {
        let store = ComparisonOutputStore(root: root)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("keep".utf8).write(to: outside.appendingPathComponent("precious.txt"))
        let link = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertTrue(store.prune(keeping: []).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("precious.txt").path))
    }

    func testArtifactNamesThatCouldEscapeTheRunDirectoryAreRefused() {
        let store = ComparisonOutputStore(root: root)
        let run = UUID()
        XCTAssertEqual(store.artifactURL(runID: run, artifact: "0-p.png")?.deletingLastPathComponent().lastPathComponent, run.uuidString)
        for bad in ["../x.png", "a/b.png", "..", "", ".hidden", "/etc/passwd", "a\\b", "x..y.png", "inputs/p.png"] {
            XCTAssertNil(store.artifactURL(runID: run, artifact: bad), bad)
        }
        XCTAssertFalse(store.artifactExists(runID: run, artifact: "../x.png"))
        XCTAssertEqual(ComparisonOutputStore.artifactName(variantIndex: 2, promptID: "../a b", kind: .image), "2-___a_b.png")
        XCTAssertTrue(ComparisonOutputStore.isContainedName(ComparisonOutputStore.artifactName(variantIndex: 0, promptID: "../../x", kind: .video)))
    }

    // MARK: Scoring

    func testKeywordsAreScoredContainsAllCaseInsensitive() {
        XCTAssertEqual(ComparisonMediaScoring.keywordsMatched(output: "A RED square moves to the Right.", expected: ["red", "right"]), true)
        XCTAssertEqual(ComparisonMediaScoring.keywordsMatched(output: "A red square moves left.", expected: ["red", "right"]), false)
        XCTAssertEqual(ComparisonMediaScoring.keywordsMatched(output: "There are 3 blue squares", expected: ["three|3", "blue"]), true)
        XCTAssertNil(ComparisonMediaScoring.keywordsMatched(output: "anything", expected: nil))
        XCTAssertNil(ComparisonMediaScoring.keywordsMatched(output: "anything", expected: []))
    }

    func testSpeechSamplesReuseTheSpeechCanaryWordErrorRate() {
        let entry = PromptEntry(id: "s", text: "The quick brown fox jumps over the lazy dog.", inputKind: .audio)
        let heard = "the quick brown fox jumped over the lazy dog"
        let sample = ComparisonMediaScoring.sample(
            mode: .speechToText, entry: entry,
            output: MediaRunOutput(text: heard, seconds: 2, audioSeconds: 8), artifact: "0-s.txt"
        )
        XCTAssertEqual(sample.wordErrorRate, SpeechCanary.wordErrorRate(reference: entry.text, hypothesis: heard))
        XCTAssertEqual(try XCTUnwrap(sample.wordErrorRate), 1.0 / 9.0, accuracy: 1e-9)
        XCTAssertEqual(sample.realTimeFactor, 0.25)
        XCTAssertEqual(sample.fullOutput, heard)
    }

    func testDerivedSpeedRatios() {
        let image = ComparisonMediaScoring.sample(
            mode: .imageGeneration,
            entry: PromptEntry(id: "i", text: "x", media: MediaParameters(size: 512, steps: 20, seed: 42)),
            output: MediaRunOutput(seconds: 40), artifact: "0-i.png"
        )
        XCTAssertEqual(image.secondsPerStep, 2)
        let video = ComparisonMediaScoring.sample(
            mode: .videoGeneration, entry: PromptEntry(id: "v", text: "x"),
            output: MediaRunOutput(seconds: 18, frames: 9), artifact: "0-v.mp4"
        )
        XCTAssertEqual(video.secondsPerFrame, 2)
        let speech = ComparisonMediaScoring.sample(
            mode: .textToSpeech, entry: PromptEntry(id: "t", text: "x"),
            output: MediaRunOutput(seconds: 3, audioSeconds: 6), artifact: "0-t.wav"
        )
        XCTAssertEqual(speech.realTimeFactor, 0.5)
        XCTAssertEqual(ComparisonViewLogic.metrics(image, mode: .imageGeneration).primary, "2.00 s/step")
        XCTAssertEqual(ComparisonViewLogic.metrics(speech, mode: .textToSpeech).primary, "RTF 0.50")
    }

    func testMetricDetailsWrapOnlyBetweenMetrics() {
        let image = ComparisonMediaScoring.sample(
            mode: .imageGeneration,
            entry: PromptEntry(id: "i", text: "x", media: MediaParameters(size: 512, steps: 20, seed: 42)),
            output: MediaRunOutput(seconds: 34.6, loadSeconds: 11.2, peakMemoryGB: 9.5, pixelStd: 54), artifact: "0-i.png"
        )
        let metrics = ComparisonViewLogic.metrics(image, mode: .imageGeneration)
        XCTAssertEqual(metrics.primary, "1.73 s/step")
        let nbsp = "\u{00A0}"
        XCTAssertEqual(metrics.details, ["34.6 s", "load 11.2 s", "9.5 GB peak"]
            .map { $0.replacingOccurrences(of: " ", with: nbsp) }.joined(separator: " · "))

        let speech = ComparisonMediaScoring.sample(
            mode: .speechToText, entry: PromptEntry(id: "s", text: "the quick brown fox"),
            output: MediaRunOutput(text: "the quick brown fox", seconds: 1, audioSeconds: 4), artifact: "0-s.txt"
        )
        let speechMetrics = ComparisonViewLogic.metrics(speech, mode: .speechToText)
        XCTAssertFalse(speechMetrics.details.contains("WER"), "the badge already shows the word error rate")
        XCTAssertEqual(speechMetrics.details, "1.0 s for 4.0 s of audio".replacingOccurrences(of: " ", with: nbsp))
    }

    // MARK: Coordinator

    private func silentClip(_ name: String, seconds: Double = 5) throws -> URL {
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

    func testReuseValidatesTextAndCanClearExplicitParametersToDefaults() throws {
        var run = historyRun(.musicGeneration, "Saved music", at: 100)
        run.promptEntries = [PromptEntry(id: "p", text: "Piano", media:
            MediaParameters(size: 512, steps: 12, seed: 7, durationSeconds: 12.5, lyrics: "[instrumental]"))]
        var setup = try MusicComparisonSetup(run: run)
        setup.prompts[0].duration = ""; setup.prompts[0].steps = ""
        setup.prompts[0].seed = ""; setup.prompts[0].lyrics = ""
        let cleared = try setup.promptSet().prompts[0]
        XCTAssertEqual(cleared.media, MediaParameters(size: 512), "Unedited media fields must survive")
        for caption in ["   ", "Piano\u{0}", String(repeating: "🎹", count: 2001)] {
            setup.prompts[0].caption = caption
            XCTAssertThrowsError(try setup.promptSet())
        }
        setup.prompts[0].caption = String(repeating: "🎹", count: 2000)
        XCTAssertNoThrow(try setup.promptSet())
        for lyrics in ["  ", "Song\u{1}", String(repeating: "a", count: 10001)] {
            setup.prompts[0].lyrics = lyrics
            XCTAssertThrowsError(try setup.promptSet())
        }
        run.promptEntries?[0].media?.lyrics = ""
        XCTAssertNotNil(try MusicComparisonSetup(run: run).validationError)
        run = historyRun(.musicGeneration, "Duplicate models", at: 100, models: ["/model", "/model"])
        run.promptEntries = [PromptEntry(id: "p", text: "Piano")]
        XCTAssertThrowsError(try MusicComparisonSetup(run: run))
    }

    @MainActor
    func testReusedMusicSetupStartsFreshRunWithoutMutatingSavedInputsOrReviews() async throws {
        let runner = StubMediaRunner(), runsURL = root.appendingPathComponent("reuse-runs.json")
        let coordinator = makeCoordinator(runner: runner, runsURL: runsURL)
        var set = promptSet(for: .musicGeneration)
        set.origin = .userCreated
        set.prompts = [PromptEntry(id: "recorded", text: "Instrumental jazz-funk",
            media: MediaParameters(steps: 12, seed: 7, durationSeconds: 12.5, lyrics: "[instrumental]"))]
        coordinator.savePromptSet(set)
        coordinator.start(variants: [("/music/a", nil)], promptSet: set)
        await waitForRun(coordinator)
        let originalID = try XCTUnwrap(coordinator.runs.first?.id)
        coordinator.reviewQuality(runID: originalID, modelPath: "/music/a", score: 4)
        let original = try XCTUnwrap(coordinator.runs.first)
        var setup = try MusicComparisonSetup(run: original)
        setup.prompts[0].duration = "20"
        let prepared = try setup.promptSet()
        let presetsBefore = try Data(contentsOf: root.appendingPathComponent("sets.json"))
        coordinator.start(variants: [("/music/a", nil)], promptSet: prepared)
        await waitForRun(coordinator)
        let newRun = try XCTUnwrap(coordinator.runs.first { $0.id != originalID })
        XCTAssertEqual(newRun.state, .completed)
        XCTAssertEqual(newRun.promptEntries, prepared.prompts)
        XCTAssertTrue(newRun.qualityReviews?.isEmpty ?? true)
        XCTAssertEqual(coordinator.runs.first { $0.id == originalID }, original)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("sets.json")), presetsBefore)
        let requests = await runner.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.entry, prepared.prompts.first)
        XCTAssertEqual(requests.last?.entry.media?.durationSeconds, 20)
        XCTAssertEqual(requests.last?.entry.media?.seed, 7)
        XCTAssertEqual(requests.last?.entry.media?.steps, 12)
        XCTAssertEqual(requests.last?.modelPath, "/music/a")
        XCTAssertEqual(try JSONStore<ComparisonRun>(fileURL: runsURL).load().count, 2)
    }

    @MainActor
    func testReuseMusicSheetRendersRecordedFieldsAndUnavailableModel() async throws {
        var run = historyRun(.musicGeneration, "Instrumental comparison", at: 100, models: ["/music/8bit", "/music/4bit"])
        run.promptEntries = [PromptEntry(id: "recorded", text: "Instrumental jazz-funk with Rhodes, bass and drums",
            media: MediaParameters(steps: 12, seed: 7, durationSeconds: 12.5, lyrics: "[instrumental]"))]
        let view = MusicComparisonSetupSheet(setup: try MusicComparisonSetup(run: run), availablePaths: ["/music/8bit"],
            name: { $0 == "/music/8bit" ? "Music model · 8-bit" : "Music model · 4-bit" },
            onApply: { _, _ in XCTFail("Rendering must not apply or generate") },
            onSave: { _ in XCTFail("Rendering must not save") })
            .background(WorkbenchColor.canvas).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 590),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "Reuse music setup"; attachment.lifetime = .keepAlways; add(attachment)
        if let path = ProcessInfo.processInfo.environment["MLX_REUSE_PROOF_PATH"] { try png.write(to: URL(fileURLWithPath: path)) }
    }

    @MainActor
    func testNamedMusicPromptSetPersistsEditedSnapshotWithoutOverwritingSourceOrGenerating() async throws {
        let runner = StubMediaRunner(), coordinator = makeCoordinator(runner: runner)
        let original = PromptSet(id: "original", name: "My instrumental", useCase: nil,
            prompts: [PromptEntry(id: "p", text: "Piano", maxTokens: 77,
                media: MediaParameters(steps: 12, seed: 7, durationSeconds: 12.5, lyrics: "[instrumental]"))],
            origin: .userCreated, mode: .musicGeneration)
        XCTAssertTrue(coordinator.savePromptSet(original))
        var run = historyRun(.musicGeneration, original.name, at: 100)
        run.promptEntries = original.prompts
        var setup = try MusicComparisonSetup(run: run)
        setup.prompts[0].caption = "Rhodes, bass and drums"
        setup.prompts[0].lyrics = "[verse]\nA new day"
        setup.prompts[0].duration = "20"; setup.prompts[0].steps = "8"; setup.prompts[0].seed = "99"
        let saved = try setup.promptSet(named: "  My instrumental  ")
        XCTAssertEqual(saved.name, original.name, "Same-name copies must still have independent identities")
        XCTAssertNotEqual(saved.id, original.id)
        XCTAssertNotEqual(try setup.promptSet(named: saved.name).id, saved.id)
        XCTAssertEqual(saved.prompts[0].maxTokens, 77)
        XCTAssertEqual(saved.prompts[0].media, MediaParameters(steps: 8, seed: 99, durationSeconds: 20, lyrics: "[verse]\nA new day"))
        XCTAssertTrue(coordinator.savePromptSet(saved))
        let loaded = try JSONStore<PromptSet>(fileURL: root.appendingPathComponent("sets.json")).load()
        XCTAssertEqual(loaded.first { $0.id == original.id }, original)
        XCTAssertEqual(loaded.first { $0.id == saved.id }, saved)
        let reloaded = makeCoordinator(runner: runner)
        XCTAssertEqual(reloaded.promptSets.first { $0.id == saved.id }, saved)
        XCTAssertNil(coordinator.activeRunID)
        XCTAssertTrue(coordinator.runs.isEmpty)
        let requests = await runner.requests
        XCTAssertTrue(requests.isEmpty, "Saving must not generate audio")
        XCTAssertEqual(run.promptEntries, original.prompts)
        for name in ["", " \n ", "Name\u{0}"] { XCTAssertThrowsError(try setup.promptSet(named: name)) }
        setup.prompts[0].steps = "31"
        XCTAssertThrowsError(try setup.promptSet(named: "Invalid settings"))
    }

    @MainActor
    func testMusicPromptSetSaveFailureLeavesStoreAndPublishedPresetsUntouched() throws {
        let url = root.appendingPathComponent("sets.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let before = coordinator.promptSets
        var run = historyRun(.musicGeneration, "Music", at: 100)
        run.promptEntries = [PromptEntry(id: "p", text: "Piano")]
        let saved = try MusicComparisonSetup(run: run).promptSet(named: "Piano copy")
        XCTAssertFalse(coordinator.savePromptSet(saved))
        XCTAssertEqual(coordinator.promptSets, before)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertNotNil(coordinator.persistenceError)
        XCTAssertNil(coordinator.activeRunID)
    }

    @MainActor
    func testMusicPromptSetRenameAndRemovalPreserveHistoryReviewsAndOutputs() async throws {
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let source = PromptSet(id: "music-source", name: "Instrumental", useCase: nil,
            prompts: promptSet(for: .musicGeneration).prompts, origin: .userCreated, mode: .musicGeneration)
        let other = PromptSet(id: "music-other", name: source.name, useCase: nil,
            prompts: source.prompts, origin: .userCreated, mode: .musicGeneration)
        XCTAssertTrue(coordinator.savePromptSet(source)); XCTAssertTrue(coordinator.savePromptSet(other))
        coordinator.start(variants: [("/music/a", nil)], promptSet: source)
        await waitForRun(coordinator)
        let run = try XCTUnwrap(coordinator.runs.first)
        coordinator.reviewQuality(runID: run.id, modelPath: "/music/a", score: 4)
        let history = try Data(contentsOf: root.appendingPathComponent("runs.json"))
        let artifact = try XCTUnwrap(coordinator.outputStore?.artifactURL(runID: run.id,
            artifact: try XCTUnwrap(run.results.first?.samples.first?.artifact)))
        let output = try Data(contentsOf: artifact)
        XCTAssertTrue(coordinator.renameMusicPromptSet(id: source.id, name: "  Jazz-funk  "))
        var renamed = source; renamed.name = "Jazz-funk"
        XCTAssertEqual(coordinator.promptSets.first { $0.id == source.id }, renamed)
        XCTAssertEqual(makeCoordinator(runner: StubMediaRunner()).promptSets.first { $0.id == source.id }, renamed)
        XCTAssertTrue(coordinator.removeMusicPromptSet(id: source.id))
        let reloaded = makeCoordinator(runner: StubMediaRunner())
        XCTAssertFalse(reloaded.promptSets.contains { $0.id == source.id })
        XCTAssertEqual(reloaded.promptSets.first { $0.id == other.id }, other)
        XCTAssertEqual(reloaded.runs.first?.qualityReviews?["/music/a"]?.score, 4)
        XCTAssertEqual(reloaded.runs.first?.promptSetName, source.name)
        XCTAssertEqual(reloaded.runs.first?.promptEntries, source.prompts)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("runs.json")), history)
        XCTAssertEqual(try Data(contentsOf: artifact), output)
    }

    @MainActor
    func testMusicPromptManagementRejectsBuiltinsOtherModesTemporaryAndActiveSets() async throws {
        let runner = StubMediaRunner(gated: true), coordinator = makeCoordinator(runner: runner)
        let music = PromptSet(id: "music-user", name: "Music", useCase: nil,
            prompts: [PromptEntry(id: "p", text: "Piano")], origin: .userCreated, mode: .musicGeneration)
        let chat = PromptSet(id: "chat-user", name: "Chat", useCase: nil,
            prompts: [PromptEntry(id: "p", text: "Hello")], origin: .userCreated)
        XCTAssertTrue(coordinator.savePromptSet(music)); XCTAssertTrue(coordinator.savePromptSet(chat))
        let before = try Data(contentsOf: root.appendingPathComponent("sets.json"))
        for id in [ComparisonMediaFixtures.musicGenerationSet.id, chat.id, "temporary"] {
            XCTAssertFalse(coordinator.canManageMusicPromptSet(id: id))
            XCTAssertFalse(coordinator.renameMusicPromptSet(id: id, name: "Changed"))
            XCTAssertFalse(coordinator.removeMusicPromptSet(id: id))
        }
        for name in ["", " \n ", "Music\u{0}"] { XCTAssertFalse(coordinator.renameMusicPromptSet(id: music.id, name: name)) }
        coordinator.start(variants: [("/music/a", nil)], promptSet: music)
        XCTAssertNotNil(coordinator.activeRunID)
        XCTAssertFalse(coordinator.renameMusicPromptSet(id: music.id, name: "While running"))
        XCTAssertFalse(coordinator.removeMusicPromptSet(id: music.id))
        await runner.release(1); await waitForRun(coordinator)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("sets.json")), before)
    }

    @MainActor
    func testMusicPromptManagementUsesDurableInputsAndDoesNotOverwriteCorruption() throws {
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let original = PromptSet(id: "music-user", name: "Music", useCase: nil,
            prompts: [PromptEntry(id: "p", text: "Piano")], origin: .userCreated, mode: .musicGeneration)
        XCTAssertTrue(coordinator.savePromptSet(original))
        let url = root.appendingPathComponent("sets.json"), store = JSONStore<PromptSet>(fileURL: url)
        var fresh = original; fresh.prompts[0].text = "Updated on disk"
        try store.upsert(fresh, id: \.id)
        XCTAssertTrue(coordinator.renameMusicPromptSet(id: original.id, name: "Renamed"))
        XCTAssertEqual(coordinator.promptSets.first { $0.id == original.id }?.prompts, fresh.prompts)
        let published = coordinator.promptSets, corrupt = Data("broken-json".utf8)
        try corrupt.write(to: url)
        XCTAssertFalse(coordinator.renameMusicPromptSet(id: original.id, name: "Must fail"))
        XCTAssertFalse(coordinator.removeMusicPromptSet(id: original.id))
        XCTAssertEqual(coordinator.promptSets, published)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertNotNil(coordinator.promptSetManagementError)
        XCTAssertNil(coordinator.persistenceError, "Management failures must not overwrite unrelated persistence state")
        fresh.mode = .chat
        try store.replaceAll([fresh])
        let changed = try Data(contentsOf: url)
        XCTAssertFalse(coordinator.removeMusicPromptSet(id: original.id))
        XCTAssertEqual(try Data(contentsOf: url), changed)
        try store.replaceAll([])
        XCTAssertFalse(coordinator.renameMusicPromptSet(id: original.id, name: "Missing"))
        XCTAssertEqual(try store.load(), [])
        try store.replaceAll([original])
        XCTAssertTrue(coordinator.renameMusicPromptSet(id: original.id, name: "Recovered name"))
        XCTAssertNil(coordinator.promptSetManagementError, "A successful retry must clear its stale action error")
    }

    @MainActor
    func testEditingSavedMusicSetPreservesIdentityHistoryReviewsAndOutputs() async throws {
        let runner = StubMediaRunner(), coordinator = makeCoordinator(runner: runner)
        let original = PromptSet(id: "music-edit", name: "Instrumentals", useCase: .coding,
            prompts: [PromptEntry(id: "one", text: "Piano", maxTokens: 77, expectedKeywords: ["piano"],
                media: MediaParameters(size: 512, steps: 12, seed: 7, durationSeconds: 12.5, lyrics: "[instrumental]")),
                PromptEntry(id: "two", text: "Acoustic guitar")], origin: .userCreated, mode: .musicGeneration)
        XCTAssertTrue(coordinator.savePromptSet(original))
        coordinator.start(variants: [("/music/a", nil)], promptSet: original)
        await waitForRun(coordinator)
        let run = try XCTUnwrap(coordinator.runs.first)
        coordinator.reviewQuality(runID: run.id, modelPath: "/music/a", score: 4)
        let history = try Data(contentsOf: root.appendingPathComponent("runs.json"))
        let setsURL = root.appendingPathComponent("sets.json"), before = try Data(contentsOf: setsURL)
        let artifact = try XCTUnwrap(coordinator.outputStore?.artifactURL(runID: run.id,
            artifact: try XCTUnwrap(run.results.first?.samples.first?.artifact)))
        let output = try Data(contentsOf: artifact)
        var edit = try XCTUnwrap(coordinator.prepareMusicPromptSetEdit(id: original.id))
        edit.prompts[0].caption = "Rhodes, bass and drums"
        edit.prompts[0].lyrics = "[verse]\nA new day"
        edit.prompts[0].duration = "20"; edit.prompts[0].steps = "8"; edit.prompts[0].seed = "99"
        XCTAssertEqual(try Data(contentsOf: setsURL), before, "Opening and editing the draft must not write")
        XCTAssertEqual(coordinator.promptSets.first { $0.id == original.id }, original)
        XCTAssertTrue(coordinator.saveMusicPromptSetEdits(edit))
        var expected = original
        expected.prompts[0].text = "Rhodes, bass and drums"
        expected.prompts[0].media = MediaParameters(size: 512, steps: 8, seed: 99, durationSeconds: 20, lyrics: "[verse]\nA new day")
        XCTAssertEqual(coordinator.promptSets.first { $0.id == original.id }, expected)
        let reloaded = makeCoordinator(runner: runner)
        XCTAssertEqual(reloaded.promptSets.first { $0.id == original.id }, expected)
        XCTAssertEqual(reloaded.runs.first?.promptEntries, original.prompts)
        XCTAssertEqual(reloaded.runs.first?.qualityReviews?["/music/a"]?.score, 4)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("runs.json")), history)
        XCTAssertEqual(try Data(contentsOf: artifact), output)
        let requests = await runner.requests
        XCTAssertEqual(requests.count, 2, "Saving must not generate additional audio")
    }

    @MainActor
    func testMusicEditSaveRejectsInvalidStaleMissingAndCorruptStoredSets() throws {
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let original = PromptSet(id: "music-edit", name: "Music", useCase: nil,
            prompts: [PromptEntry(id: "p", text: "Piano")], origin: .userCreated, mode: .musicGeneration)
        XCTAssertTrue(coordinator.savePromptSet(original))
        let url = root.appendingPathComponent("sets.json"), store = JSONStore<PromptSet>(fileURL: url)
        let before = try Data(contentsOf: url)
        var invalid = try MusicPromptSetEdit(set: original); invalid.prompts[0].duration = "0"
        XCTAssertFalse(coordinator.saveMusicPromptSetEdits(invalid))
        XCTAssertEqual(try Data(contentsOf: url), before)
        var edit = try MusicPromptSetEdit(set: original); edit.prompts[0].caption = "Jazz"
        var changed = original; changed.prompts[0].text = "Changed on disk"
        try store.replaceAll([changed])
        let freshBytes = try Data(contentsOf: url)
        XCTAssertFalse(coordinator.saveMusicPromptSetEdits(edit))
        XCTAssertEqual(try Data(contentsOf: url), freshBytes)
        try store.replaceAll([])
        XCTAssertFalse(coordinator.saveMusicPromptSetEdits(edit))
        XCTAssertEqual(try store.load(), [])
        let corrupt = Data("broken-json".utf8); try corrupt.write(to: url)
        XCTAssertFalse(coordinator.saveMusicPromptSetEdits(edit))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertNil(coordinator.prepareMusicPromptSetEdit(id: original.id))
        XCTAssertEqual(coordinator.promptSets.first { $0.id == original.id }, original)
        XCTAssertNotNil(coordinator.promptSetManagementError)
        try store.replaceAll([changed])
        var freshEdit = try XCTUnwrap(coordinator.prepareMusicPromptSetEdit(id: original.id))
        XCTAssertEqual(freshEdit.original, changed, "Reopening after a stale save must read the current durable snapshot")
        let reopenedBytes = try Data(contentsOf: url)
        freshEdit.prompts[0].seed = "99"
        XCTAssertEqual(try Data(contentsOf: url), reopenedBytes, "Opening the editor must not write")
        XCTAssertTrue(coordinator.saveMusicPromptSetEdits(freshEdit))
        XCTAssertEqual(coordinator.promptSets.first { $0.id == original.id }?.prompts[0].text, changed.prompts[0].text)
        XCTAssertNil(coordinator.promptSetManagementError)
    }

    @MainActor
    func testMusicEditProtectsBuiltinsOtherModesAndActiveComparisons() async throws {
        XCTAssertThrowsError(try MusicPromptSetEdit(set: ComparisonMediaFixtures.musicGenerationSet))
        let chat = PromptSet(id: "chat", name: "Chat", useCase: nil, prompts: [PromptEntry(id: "p", text: "Hello")], origin: .userCreated)
        XCTAssertThrowsError(try MusicPromptSetEdit(set: chat))
        var set = PromptSet(id: "music-edit", name: "Music", useCase: nil,
            prompts: [PromptEntry(id: "p", text: "Piano")], origin: .userCreated, mode: .musicGeneration)
        let runner = StubMediaRunner(gated: true), coordinator = makeCoordinator(runner: runner)
        XCTAssertTrue(coordinator.savePromptSet(set))
        let before = try Data(contentsOf: root.appendingPathComponent("sets.json"))
        var edit = try MusicPromptSetEdit(set: set); edit.prompts[0].caption = "Jazz"
        coordinator.start(variants: [("/music/a", nil)], promptSet: set)
        XCTAssertNil(coordinator.prepareMusicPromptSetEdit(id: set.id))
        XCTAssertFalse(coordinator.saveMusicPromptSetEdits(edit))
        await runner.release(1); await waitForRun(coordinator)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("sets.json")), before)
        set.prompts = []
        XCTAssertThrowsError(try MusicPromptSetEdit(set: set))
        set.prompts = [PromptEntry(id: "p", text: "Piano"), PromptEntry(id: "p", text: "Guitar")]
        XCTAssertThrowsError(try MusicPromptSetEdit(set: set))
        edit.prompts = []
        XCTAssertThrowsError(try edit.updatedPromptSet())
    }

    @MainActor
    func testSavedMusicEditSheetRendersRecordedSettingsWithoutSaving() async throws {
        let set = PromptSet(id: "music-edit", name: "Jazz-funk instrumentals", useCase: nil,
            prompts: [PromptEntry(id: "p", text: "Instrumental jazz-funk with Rhodes, bass and drums",
                media: MediaParameters(steps: 12, seed: 7, durationSeconds: 12.5, lyrics: "[instrumental]"))],
            origin: .userCreated, mode: .musicGeneration)
        let content = MusicPromptSetEditSheet(edit: try MusicPromptSetEdit(set: set)) { _ in
            XCTFail("Rendering must not save a set"); return nil
        }
        .background(WorkbenchColor.canvas).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 530),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "Edit saved music prompt set"; attachment.lifetime = .keepAlways; add(attachment)
        if let path = ProcessInfo.processInfo.environment["MLX_MUSIC_EDIT_PROOF_PATH"] { try png.write(to: URL(fileURLWithPath: path)) }
    }

    @MainActor
    func testMusicPromptSetRenameSheetRendersWithoutMutatingTheSet() async throws {
        let set = PromptSet(id: "music-user", name: "Jazz-funk instrumentals", useCase: nil,
            prompts: [PromptEntry(id: "p", text: "Piano")], origin: .userCreated, mode: .musicGeneration)
        let content = MusicPromptSetRenameSheet(set: set) { _ in
            XCTFail("Rendering must not rename a set"); return nil
        }
        .background(WorkbenchColor.canvas).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "Rename saved music prompt set"; attachment.lifetime = .keepAlways; add(attachment)
        if let path = ProcessInfo.processInfo.environment["MLX_MUSIC_MANAGE_PROOF_PATH"] { try png.write(to: URL(fileURLWithPath: path)) }
    }

    @MainActor
    func testMusicListeningReviewPersistsItsOwnRubricAndCanBeCleared() async throws {
        let url = root.appendingPathComponent("listening-runs.json")
        let coordinator = makeCoordinator(runner: StubMediaRunner(), runsURL: url)
        coordinator.start(variants: [("/music/a", nil)], promptSet: promptSet(for: .musicGeneration))
        await waitForRun(coordinator)
        let id = try XCTUnwrap(coordinator.runs.first?.id)
        coordinator.reviewQuality(runID: id, modelPath: "/music/a", score: 4)
        let reloaded = makeCoordinator(runner: StubMediaRunner(), runsURL: url)
        let review = try XCTUnwrap(reloaded.runs.first?.qualityReviews?["/music/a"])
        XCTAssertEqual(review.score, 4)
        XCTAssertEqual(review.rubricID, "music-listening-v1")
        XCTAssertNil(reloaded.runs.first?.winner, "listening scores must not promote a speed winner")
        reloaded.reviewQuality(runID: id, modelPath: "/music/a", score: nil)
        XCTAssertNil(try JSONStore<ComparisonRun>(fileURL: url).load().first?.qualityReviews?["/music/a"])
    }

    @MainActor
    private func makeCoordinator(
        runner: ComparisonMediaRunner,
        store: ComparisonOutputStore? = nil,
        runsURL: URL? = nil
    ) -> ComparisonCoordinator {
        let probe = ServeProbe(
            lifecycle: ServeLifecycle(preview: { _, _ in "h" }, start: { _, _, _ in }, stop: { _ in }),
            prober: IdleProber(),
            readyPollIntervalNanoseconds: 1_000_000,
            pickPort: { 9997 }
        )
        return ComparisonCoordinator(
            probe: probe,
            runStore: JSONStore<ComparisonRun>(fileURL: runsURL ?? root.appendingPathComponent("runs.json")),
            promptSetStore: JSONStore<PromptSet>(fileURL: root.appendingPathComponent("sets.json")),
            mediaRunner: runner,
            outputStore: store ?? ComparisonOutputStore(root: root.appendingPathComponent("outputs")),
            generateInput: { entry, directory in
                let url = directory.appendingPathComponent("\(entry.id).bin")
                try Data("in".utf8).write(to: url)
                return url
            }
        )
    }

    @MainActor
    private func waitForRun(_ coordinator: ComparisonCoordinator) async {
        for _ in 0..<2000 where coordinator.activeRunID != nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func promptSet(for mode: ComparisonMode) -> PromptSet {
        var set = (ComparisonMediaFixtures.all.first { $0.effectiveMode == mode })!
        // User-picked files so the stub run needs no generated inputs on disk.
        if mode.inputKind != nil {
            let input = root.appendingPathComponent("user-input.bin")
            try? Data("in".utf8).write(to: input)
            set.prompts = set.prompts.map { entry in
                var copy = entry
                copy.builtinInput = nil
                copy.inputPath = input.path
                return copy
            }
        }
        return set
    }

    @MainActor
    func testEveryMediaModeWritesAnArtifactAndMetricsPerVariantAndPrompt() async throws {
        for mode in ComparisonMode.allCases where mode != .chat {
            let store = ComparisonOutputStore(root: root.appendingPathComponent("outputs-\(mode.rawValue)"))
            let runner = StubMediaRunner()
            let coordinator = makeCoordinator(runner: runner, store: store, runsURL: root.appendingPathComponent("runs-\(mode.rawValue).json"))
            let set = promptSet(for: mode)

            coordinator.start(variants: [("/m/a", nil), ("/m/b", nil)], promptSet: set)
            XCTAssertNotNil(coordinator.activeRunID)
            await waitForRun(coordinator)

            let run = try XCTUnwrap(coordinator.runs.first, "\(mode)")
            XCTAssertEqual(run.state, .completed)
            XCTAssertEqual(run.effectiveMode, mode)
            XCTAssertEqual(run.results.map(\.modelPath), ["/m/a", "/m/b"])
            for (index, result) in run.results.enumerated() {
                XCTAssertNil(result.error, "\(mode)")
                XCTAssertEqual(result.samples.map(\.promptID), set.prompts.map(\.id))
                XCTAssertNotNil(result.aggregateMetric, "\(mode) aggregate")
                for (sample, entry) in zip(result.samples, set.prompts) {
                    XCTAssertEqual(sample.artifact, ComparisonOutputStore.artifactName(variantIndex: index, promptID: entry.id, kind: mode.outputKind))
                    XCTAssertTrue(store.artifactExists(runID: run.id, artifact: sample.artifact), "\(mode) \(sample.artifact ?? "")")
                    XCTAssertNotNil(mode.primaryMetric.value(of: sample), "\(mode) metric")
                }
            }
            let persisted = try JSONStore<ComparisonRun>(fileURL: root.appendingPathComponent("runs-\(mode.rawValue).json")).load()
            XCTAssertEqual(persisted.first?.results.count, 2)
            XCTAssertEqual(persisted.first?.mode, mode)
            let requests = await runner.requests
            XCTAssertEqual(requests.count, 2 * set.prompts.count)
            XCTAssertEqual(requests.map(\.modelPath), requests.map(\.modelPath).sorted(), "variants run one after the other")
            if mode.outputKind == .text {
                let text = try String(contentsOf: try XCTUnwrap(store.artifactURL(runID: run.id, artifact: run.results[0].samples[0].artifact ?? "")), encoding: .utf8)
                XCTAssertEqual(text, run.results[0].samples[0].fullOutput)
            } else {
                XCTAssertTrue(requests.allSatisfy { $0.outputURL != nil })
            }
        }
    }

    @MainActor
    func testVisionRunScoresKeywordsAndCarriesTheDescribeMetrics() async throws {
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        coordinator.start(variants: [("/m/vlm", nil)], promptSet: promptSet(for: .vision))
        await waitForRun(coordinator)
        let samples = try XCTUnwrap(coordinator.runs.first?.results.first?.samples)
        XCTAssertEqual(samples[0].keywordsMatched, true)
        XCTAssertEqual(samples[1].keywordsMatched, false)
        XCTAssertEqual(samples[0].generationTokens, 8)
        XCTAssertEqual(samples[0].generationTokensPerSecond, 40)
        XCTAssertEqual(samples[0].peakMemoryGB, 3)
        XCTAssertEqual(coordinator.runs.first?.results.first?.aggregateMetric, 40)
    }

    @MainActor
    func testBuiltinSpeechClipsAreTranscribedAsEnglishAndUserClipsAreNot() async throws {
        let builtinSet = ComparisonMediaFixtures.speechToTextSet
        let builtinRunner = StubMediaRunner()
        let builtin = makeCoordinator(runner: builtinRunner, runsURL: root.appendingPathComponent("runs-builtin.json"))
        builtin.start(variants: [("/m/whisper", nil)], promptSet: builtinSet)
        await waitForRun(builtin)
        XCTAssertEqual(builtin.runs.first?.state, .completed)
        let builtinRequests = await builtinRunner.requests
        XCTAssertEqual(builtinRequests.map(\.entry.id), builtinSet.prompts.map(\.id))
        XCTAssertEqual(builtinRequests.map(\.language), Array(repeating: SpeechCanary.language, count: builtinSet.prompts.count))

        let userSet = promptSet(for: .speechToText)
        let userRunner = StubMediaRunner()
        let user = makeCoordinator(runner: userRunner, runsURL: root.appendingPathComponent("runs-user.json"))
        user.start(variants: [("/m/whisper", nil)], promptSet: userSet)
        await waitForRun(user)
        XCTAssertEqual(user.runs.first?.state, .completed)
        let userRequests = await userRunner.requests
        XCTAssertEqual(userRequests.map(\.entry.id), userSet.prompts.map(\.id))
        XCTAssertEqual(userRequests.map(\.language), Array(repeating: nil, count: userSet.prompts.count))

        XCTAssertNil(ComparisonMediaFixtures.language(ofBuiltinInput: "red-circle"))
    }

    @MainActor
    func testRunIsPersistedAfterEachVariantAndOnlyOneRunAtATime() async throws {
        let runner = StubMediaRunner(gated: true)
        let runsURL = root.appendingPathComponent("runs.json")
        let coordinator = makeCoordinator(runner: runner, runsURL: runsURL)
        let set = promptSet(for: .textToSpeech)

        coordinator.start(variants: [("/m/a", nil), ("/m/b", nil)], promptSet: set)
        let firstRun = coordinator.activeRunID
        coordinator.start(variants: [("/m/c", nil)], promptSet: set)
        XCTAssertEqual(coordinator.lastError, "A comparison run is already in progress.")
        XCTAssertEqual(coordinator.activeRunID, firstRun)
        XCTAssertEqual(coordinator.runs.count, 1)

        // Release only the first variant's requests: its result must reach the disk while the second variant is still gated.
        await runner.release(set.prompts.count)
        var onDisk: [ComparisonRun] = []
        for _ in 0..<2000 {
            onDisk = (try? JSONStore<ComparisonRun>(fileURL: runsURL).load()) ?? []
            if (onDisk.first?.results.count ?? 0) >= 1 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(onDisk.first?.results.count, 1)
        XCTAssertEqual(onDisk.first?.results.first?.modelPath, "/m/a")
        XCTAssertEqual(onDisk.first?.state, .running)
        XCTAssertNotNil(coordinator.activeRunID, "the second variant is still running")

        await runner.release(set.prompts.count)
        await waitForRun(coordinator)
        XCTAssertEqual(try JSONStore<ComparisonRun>(fileURL: runsURL).load().first?.results.count, 2)
        XCTAssertEqual(coordinator.runs.first?.state, .completed)
    }

    @MainActor
    func testAnUnreadableRunStoreNeverPrunesTheSavedOutputs() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("outputs"))
        let saved = [UUID(), UUID(), UUID()]
        for id in saved {
            try store.createRunDirectory(id)
            try Data("x".utf8).write(to: store.runDirectory(id).appendingPathComponent("0-p.png"))
        }
        let runsURL = root.appendingPathComponent("runs.json")
        try Data("{ not json".utf8).write(to: runsURL)
        let coordinator = makeCoordinator(runner: StubMediaRunner(), store: store, runsURL: runsURL)
        XCTAssertNotNil(coordinator.persistenceError)
        XCTAssertTrue(coordinator.runs.isEmpty)

        coordinator.start(variants: [("/m", nil)], promptSet: promptSet(for: .imageGeneration))
        let runID = try XCTUnwrap(coordinator.activeRunID)
        await waitForRun(coordinator)

        for id in saved { XCTAssertTrue(FileManager.default.fileExists(atPath: store.runDirectory(id).path), "\(id)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.runDirectory(runID).path))
    }

    @MainActor
    func testAFailingVariantIsRecordedAndTheRunContinues() async throws {
        let coordinator = makeCoordinator(runner: StubMediaRunner(failingModels: ["/m/bad"]))
        coordinator.start(variants: [("/m/bad", nil), ("/m/good", nil)], promptSet: promptSet(for: .imageGeneration))
        await waitForRun(coordinator)
        let run = try XCTUnwrap(coordinator.runs.first)
        XCTAssertNotNil(run.results[0].error)
        XCTAssertTrue(run.results[0].samples.allSatisfy { $0.error != nil })
        XCTAssertNil(run.results[1].error)
        XCTAssertEqual(run.state, .completed)
    }

    @MainActor
    func testMediaRunsAreRefusedWithoutAnOutputStoreAndForTheWrongPromptSet() async throws {
        let probe = ServeProbe(
            lifecycle: ServeLifecycle(preview: { _, _ in "h" }, start: { _, _, _ in }, stop: { _ in }),
            prober: IdleProber(), readyPollIntervalNanoseconds: 1_000_000, pickPort: { 9997 }
        )
        let bare = ComparisonCoordinator(
            probe: probe,
            runStore: JSONStore<ComparisonRun>(fileURL: root.appendingPathComponent("r.json")),
            promptSetStore: JSONStore<PromptSet>(fileURL: root.appendingPathComponent("s.json"))
        )
        bare.start(variants: [("/m", nil)], promptSet: ComparisonMediaFixtures.imageGenerationSet)
        XCTAssertNil(bare.activeRunID)
        XCTAssertNotNil(bare.lastError)

        let coordinator = makeCoordinator(runner: StubMediaRunner())
        coordinator.start(variants: [("/m", nil)], promptSet: ComparisonMediaFixtures.imageGenerationSet, mode: .chat)
        XCTAssertNil(coordinator.activeRunID)
        XCTAssertTrue(coordinator.lastError?.contains("Image generation") ?? false)
    }

    @MainActor
    func testStartingAMediaRunPrunesOlderRunsOutputsButNotTheirMetrics() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("outputs"))
        let runsURL = root.appendingPathComponent("runs.json")
        let runStore = JSONStore<ComparisonRun>(fileURL: runsURL)
        var olderIDs: [UUID] = []
        for index in 0..<10 {
            let id = UUID()
            olderIDs.append(id)
            try store.createRunDirectory(id)
            try Data("x".utf8).write(to: store.runDirectory(id).appendingPathComponent("0-p.png"))
            try runStore.upsert(
                ComparisonRun(
                    id: id, promptSetID: "s", promptSetName: "S", useCase: nil, variants: [], results: [],
                    startedAt: Date(timeIntervalSinceReferenceDate: Double(100 + index)),
                    finishedAt: Date(timeIntervalSinceReferenceDate: Double(101 + index)), state: .completed,
                    mode: .imageGeneration
                ),
                id: \.id
            )
        }
        let coordinator = makeCoordinator(runner: StubMediaRunner(), store: store, runsURL: runsURL)
        coordinator.start(variants: [("/m", nil)], promptSet: promptSet(for: .imageGeneration))
        await waitForRun(coordinator)

        // The new run plus the nine newest older runs keep their files; the oldest run loses its folder.
        let oldest = try XCTUnwrap(coordinator.runs.last)
        XCTAssertEqual(oldest.id, olderIDs[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.runDirectory(oldest.id).path))
        for id in olderIDs.dropFirst() { XCTAssertTrue(FileManager.default.fileExists(atPath: store.runDirectory(id).path)) }
        XCTAssertEqual(coordinator.runs.count, 11, "run metrics are kept")
        XCTAssertFalse(store.artifactExists(runID: oldest.id, artifact: "0-p.png"))
    }

    // MARK: Built-in generators

    func testBuiltinImagesDecodeAsPNG() async throws {
        for (id, name) in [("vision-red-circle", "red-circle"), ("vision-blue-squares", "blue-squares"), ("vision-green-triangle", "green-triangle")] {
            let entry = PromptEntry(id: id, text: "q", inputKind: .image, builtinInput: name)
            let url = try await ComparisonMediaFixtures.generateInput(for: entry, into: root)
            XCTAssertEqual(url.pathExtension, "png")
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, ComparisonMediaFixtures.imageEdge)
            XCTAssertEqual(image.height, ComparisonMediaFixtures.imageEdge)
        }
    }

    func testBuiltinVideoLoadsAsAVAssetWithAThreeSecondVideoTrack() async throws {
        let entry = PromptEntry(id: "video-red-square", text: "q", inputKind: .video, builtinInput: "red-square-right")
        let url = try await ComparisonMediaFixtures.generateInput(for: entry, into: root)
        XCTAssertEqual(url.pathExtension, "mp4")
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width), ComparisonMediaFixtures.imageEdge)
        XCTAssertEqual(Int(size.height), ComparisonMediaFixtures.imageEdge)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.2)
    }

    func testBuiltinSpeechWritesAWAVNamedByThePrompt() async throws {
        let entry = PromptEntry(id: "stt-fox", text: "The quick brown fox.", inputKind: .audio, builtinInput: "speech")
        let url = try await ComparisonMediaFixtures.generateInput(for: entry, into: root)
        XCTAssertEqual(url.lastPathComponent, "stt-fox.wav")
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.length, 0)
        XCTAssertEqual(file.processingFormat.sampleRate, 16000)
    }

    func testUnknownBuiltinInputIsAnError() async {
        let entry = PromptEntry(id: "x", text: "q", inputKind: .image, builtinInput: "nope")
        do {
            _ = try await ComparisonMediaFixtures.generateInput(for: entry, into: root)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Unknown built-in input nope.")
        }
    }

    /// The clip view hosts AppKit's player with the file loaded and paused. The player view is looked
    /// up by name so this test does not link AVKit itself: the app has to.
    @MainActor
    func testClipVideoViewHostsAPausedPlayerForTheFile() throws {
        let url = root.appendingPathComponent("clip.mp4")
        let host = NSHostingView(rootView: ClipVideoView(url: url).frame(width: 320, height: 180))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: .borderless, backing: .buffered, defer: true
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let playerViewClass: AnyClass = try XCTUnwrap(NSClassFromString("AVPlayerView"), "AVKit is not loaded")
        let playerView = try XCTUnwrap(Self.firstDescendant(of: host) { $0.isKind(of: playerViewClass) })
        let player = try XCTUnwrap(playerView.value(forKey: "player") as? AVPlayer)
        XCTAssertEqual((player.currentItem?.asset as? AVURLAsset)?.url, url)
        XCTAssertEqual(player.rate, 0)
    }

    private static func firstDescendant(of view: NSView, where matches: (NSView) -> Bool) -> NSView? {
        for child in view.subviews {
            if matches(child) { return child }
            if let found = firstDescendant(of: child, where: matches) { return found }
        }
        return nil
    }
}
