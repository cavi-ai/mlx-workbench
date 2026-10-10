import AppKit
import AVFoundation
import AVKit
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
private final class PromptPreviewFixture: ObservableObject {
    @Published var url: URL
    init(url: URL) { self.url = url }
}

private struct PromptPreviewFixtureView: View {
    @ObservedObject var fixture: PromptPreviewFixture
    let audio: AudioClipPlayer
    var body: some View {
        ComparisonPromptInputPreview(url: fixture.url, kind: .audio, audio: audio, expanded: true)
    }
}

@MainActor
private final class PromptCancelFixture: ObservableObject {
    @Published var requiresConfirmation: Bool
    var dismissals = 0
    init(requiresConfirmation: Bool) { self.requiresConfirmation = requiresConfirmation }
}

private struct PromptCancelFixtureView: View {
    @ObservedObject var fixture: PromptCancelFixture
    var body: some View {
        ComparisonPromptCancelButton(requiresConfirmation: fixture.requiresConfirmation) { fixture.dismissals += 1 }
            .buttonStyle(.borderless)
            .padding(WorkbenchSpacing.pageInset)
            .frame(width: 420, height: 90)
            .background(WorkbenchColor.canvas).preferredColorScheme(.dark)
    }
}

@MainActor
private final class PromptEditorScrollFixture: ObservableObject {
    @Published var draft: ComparisonPromptSetDraft
    @Published var music: [MusicComparisonSetup.Prompt]

    init() {
        var draft = ComparisonPromptSetDraft(mode: .imageGeneration)
        draft.name = "Scenes"
        for _ in 0..<3 { draft.addPrompt() }
        for index in draft.prompts.indices { draft.prompts[index].text = "Landscape \(index + 1)" }
        self.draft = draft
        music = (1...4).map { MusicComparisonSetup.Prompt(PromptEntry(id: "music-\($0)", text: "Solo piano \($0)")) }
    }
}

private struct PromptEditorScrollFixtureView: View {
    @ObservedObject var fixture: PromptEditorScrollFixture
    let music: Bool

    var body: some View {
        Group {
            if music { MusicPromptFields(prompts: $fixture.music) }
            else { ComparisonPromptFields(draft: $fixture.draft) }
        }
        .textFieldStyle(.roundedBorder)
        .padding(WorkbenchSpacing.pageInset)
        .frame(width: 620, height: 440)
        .background(WorkbenchColor.canvas).preferredColorScheme(.dark)
    }
}

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
private actor ChangingInputRunner: ComparisonMediaRunner {
    let original: URL
    private(set) var inputs: [URL] = []
    private(set) var contents: [String] = []
    init(original: URL) { self.original = original }
    func run(_ request: MediaRunRequest) async throws -> MediaRunOutput {
        let input = try XCTUnwrap(request.inputURL)
        inputs.append(input)
        contents.append(try String(contentsOf: input, encoding: .utf8))
        if inputs.count == 1 { try Data("changed source".utf8).write(to: original) }
        return MediaRunOutput(text: "description", generationTokensPerSecond: 10)
    }
}

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

    @MainActor
    func testEveryVariantUsesOneSavedInputEvenWhenOriginalChanges() async throws {
        let original = root.appendingPathComponent("original.png")
        try Data("original source".utf8).write(to: original)
        let runner = ChangingInputRunner(original: original)
        let store = ComparisonOutputStore(root: root.appendingPathComponent("saved-inputs"))
        let coordinator = makeCoordinator(runner: runner, store: store)
        let set = PromptSet(id: "s", name: "Source stability", useCase: nil, prompts: [
            PromptEntry(id: "p", text: "Describe this image", inputKind: .image, inputPath: original.path)
        ], origin: .userCreated, mode: .vision)
        coordinator.start(variants: [("/m/a", nil), ("/m/b", nil)], promptSet: set)
        await waitForRun(coordinator)
        let run = try XCTUnwrap(coordinator.runs.first)
        XCTAssertEqual(run.state, .completed)
        let contents = await runner.contents, inputs = await runner.inputs
        XCTAssertEqual(contents, ["original source", "original source"])
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(inputs.first, inputs.last)
        XCTAssertNotEqual(inputs.first, original)
        XCTAssertEqual(inputs.first?.deletingLastPathComponent(), store.inputsDirectory(run.id))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "changed source")
        let artifact = try XCTUnwrap(run.inputArtifacts?["p"])
        XCTAssertEqual(store.inputArtifactURL(runID: run.id, artifact: artifact), inputs.first)
        XCTAssertEqual(inputs.first?.pathExtension, "png")
        try FileManager.default.removeItem(at: original)
        let restored = try XCTUnwrap(JSONStore<ComparisonRun>(fileURL: root.appendingPathComponent("runs.json")).load().first)
        XCTAssertEqual(restored.inputArtifacts, run.inputArtifacts)
        let entry = try XCTUnwrap(restored.promptEntries?.first)
        XCTAssertEqual(ComparisonViewLogic.inputEvidence(for: restored, entry: entry, store: store), .saved(try XCTUnwrap(inputs.first)))
    }

    func testInputSnapshotsRefuseDirectoriesLinksAndUnsafeStorePaths() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("snapshots")), runID = UUID()
        try store.createRunDirectory(runID)
        let original = root.appendingPathComponent("original.wav")
        try Data("source".utf8).write(to: original)
        let link = root.appendingPathComponent("source-link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        for source in [link, try XCTUnwrap(root), root.appendingPathComponent("missing.wav")] {
            do { _ = try await store.snapshotInput(from: source, runID: runID); XCTFail("Unsafe input was saved") }
            catch { XCTAssertTrue(error is ComparisonOutputStore.InputError) }
        }
        try FileManager.default.removeItem(at: store.inputsDirectory(runID))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.inputsDirectory(runID), withDestinationURL: outside)
        do { _ = try await store.snapshotInput(from: original, runID: runID); XCTFail("Symlinked input folder was used") }
        catch { XCTAssertTrue(error is ComparisonOutputStore.InputError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "source")
        for name in ["../a.wav", "a/b.wav", ".hidden", "", "x..y.wav", "a\\b.wav"] {
            XCTAssertNil(store.inputArtifactURL(runID: runID, artifact: name))
        }
    }

    func testInputEvidenceDistinguishesSavedLegacyAndUnavailableInputsWithoutFallback() throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("evidence"))
        var run = historyRun(.vision, "Input evidence", at: 100)
        try store.createRunDirectory(run.id)
        let original = root.appendingPathComponent("source.png")
        try Data("new original".utf8).write(to: original)
        let entry = PromptEntry(id: "p", text: "Question", inputKind: .image, inputPath: original.path)
        XCTAssertEqual(ComparisonViewLogic.inputEvidence(for: run, entry: entry, store: store), .original(original))
        let saved = store.inputsDirectory(run.id).appendingPathComponent("saved.png")
        try Data("recorded input".utf8).write(to: saved)
        run.inputArtifacts = ["p": "saved.png"]
        XCTAssertEqual(ComparisonViewLogic.inputEvidence(for: run, entry: entry, store: store), .saved(saved))
        try FileManager.default.removeItem(at: saved)
        XCTAssertEqual(ComparisonViewLogic.inputEvidence(for: run, entry: entry, store: store), .unavailable("Saved input unavailable"))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "new original")
        run.inputArtifacts = ["p": "../source.png"]
        XCTAssertNil(ComparisonViewLogic.inputEvidence(for: run, entry: entry, store: store).url)
        run.inputArtifacts = nil
        try FileManager.default.removeItem(at: original)
        XCTAssertEqual(ComparisonViewLogic.inputEvidence(for: run, entry: entry, store: store), .unavailable("Original input unavailable"))
        let legacyJSON = try JSONEncoder().encode(run)
        XCTAssertNil(try JSONDecoder().decode(ComparisonRun.self, from: legacyJSON).inputArtifacts)
    }

    @MainActor
    func testGeneratedInputsKeepDistinctContentsWhenPromptFilenamesCollide() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("builtin-inputs"))
        let runner = StubMediaRunner()
        let probe = ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "h" }, start: { _, _, _ in }, stop: { _ in }),
            prober: IdleProber(), pickPort: { 9997 })
        let coordinator = ComparisonCoordinator(probe: probe,
            runStore: JSONStore<ComparisonRun>(fileURL: root.appendingPathComponent("builtin-runs.json")),
            promptSetStore: JSONStore<PromptSet>(fileURL: root.appendingPathComponent("builtin-sets.json")),
            mediaRunner: runner, outputStore: store)
        let set = PromptSet(id: "s", name: "Collision fixture", useCase: nil, prompts: [
            PromptEntry(id: "a b", text: "Red", inputKind: .image, builtinInput: "red-circle"),
            PromptEntry(id: "a/b", text: "Blue", inputKind: .image, builtinInput: "blue-squares")
        ], origin: .userCreated, mode: .vision)
        coordinator.start(variants: [("/m/a", nil), ("/m/b", nil)], promptSet: set)
        await waitForRun(coordinator)
        let run = try XCTUnwrap(coordinator.runs.first)
        let requests = await runner.requests
        XCTAssertEqual(requests.count, 4)
        guard requests.count == 4 else { return }
        let first = try XCTUnwrap(requests[0].inputURL), second = try XCTUnwrap(requests[1].inputURL)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(try Data(contentsOf: first), try Data(contentsOf: second))
        XCTAssertEqual(requests[2].inputURL, first)
        XCTAssertEqual(requests[3].inputURL, second)
        XCTAssertEqual(run.inputArtifacts?.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.inputsDirectory(run.id).path).count, 2)
    }

    @MainActor
    func testNativeGridShowsSavedUnavailableAndLegacyInputEvidence() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("grid-inputs"))
        var run = historyRun(.vision, "Vision fixture", at: 100, models: ["/model/a", "/model/b"])
        try store.createRunDirectory(run.id)
        let saved = try await ComparisonMediaFixtures.generateInput(
            for: PromptEntry(id: "p", text: "", builtinInput: "red-circle"), into: store.inputsDirectory(run.id))
        let image = try Data(contentsOf: saved)
        let original = root.appendingPathComponent("selected-image.png")
        let entry = PromptEntry(id: "p", text: "Describe the shape and its color.", inputKind: .image,
            inputPath: original.path, expectedKeywords: ["red", "circle|round"])
        run.promptEntries = [entry]
        run.inputArtifacts = ["p": saved.lastPathComponent]
        run.results = ["a", "b"].enumerated().map { index, key in
            VariantResult(modelPath: "/model/\(key)", modelSignature: "fixture", samples: [
                ComparisonSample(promptID: "p", outputExcerpt: index == 0 ? "A red circle on a white background." : "A red shape.",
                    tokensPerSecond: nil, timeToFirstTokenSeconds: nil, error: nil,
                    fullOutput: index == 0 ? "A red circle on a white background." : "A red shape.",
                    keywordsMatched: index == 0, generationTokensPerSecond: index == 0 ? 20 : 40)
            ], aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil,
                aggregateMetric: index == 0 ? 20 : 40)
        }
        for (label, width) in [("saved", 1000.0), ("unavailable", 760.0), ("legacy", 760.0)] {
            if label == "unavailable" {
                try FileManager.default.removeItem(at: saved)
                try image.write(to: original)
            } else if label == "legacy" { run.inputArtifacts = nil }
            let evidence = ComparisonViewLogic.inputEvidence(for: run, entry: entry, store: store)
            if label == "saved" { XCTAssertEqual(evidence, .saved(saved)) }
            else if label == "unavailable" { XCTAssertNil(evidence.url) }
            else { XCTAssertEqual(evidence, .original(original)) }
            let view = MediaRunResultsView(run: run, store: store, contentWidth: width - 48, isRouteActive: true,
                name: { $0 == "/model/a" ? "Model A · fixture" : "Model B · fixture" },
                onReview: { _, _ in XCTFail("Rendering must not write a rating") }, laneActions: { _ in EmptyView() })
                .padding(WorkbenchSpacing.pageInset).frame(width: width, height: 640, alignment: .topLeading)
                .background(WorkbenchColor.canvas).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 640),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Input evidence · \(label)"; attachment.lifetime = .keepAlways; add(attachment)
            if let directory = ProcessInfo.processInfo.environment["MLX_INPUT_EVIDENCE_PROOF_DIR"] {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("input-\(label).png"))
            }
            window.close()
        }
    }

    @MainActor
    func testTextInspectionModesAndNativeReadingDifferenceLayouts() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("text-output"))
        for mode in ComparisonMode.allCases {
            var run = historyRun(mode, mode.title, at: 100, models: ["/model/a", "/model/b"])
            run.results = ["a", "b"].map { key in
                VariantResult(modelPath: "/model/\(key)", modelSignature: nil, samples: [
                    ComparisonSample(promptID: "p", outputExcerpt: "excerpt", tokensPerSecond: nil,
                        timeToFirstTokenSeconds: nil, error: nil, fullOutput: "Full output \(key)")
                ], aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil)
            }
            XCTAssertEqual(ComparisonDiff.isAvailable(run), mode.outputKind == .text)
            run.state = .running
            XCTAssertFalse(ComparisonDiff.isAvailable(run))
            run.state = .completed; run.results.removeLast()
            XCTAssertFalse(ComparisonDiff.isAvailable(run))
        }

        for (mode, width, changes) in [(ComparisonMode.vision, 1000.0, false),
                                      (.speechToText, 760.0, false), (.videoUnderstanding, 1000.0, true), (.chat, 760.0, true)] {
            var run = historyRun(mode, mode.title, at: 100, models: ["/model/a", "/model/b"])
            run.promptEntries = [PromptEntry(id: "p", text: "Describe the bird and its surroundings.")]
            run.results = ["a", "b"].enumerated().map { index, key in
                let output = index == 0 ? "A red bird rests on a snowy branch.\nIt faces left.\nA pine forest fills the background."
                    : "A brown bird rests on a snowy branch.\nIt faces left.\nA distant forest fills the background."
                return VariantResult(modelPath: "/model/\(key)", modelSignature: "recorded", samples: [
                    ComparisonSample(promptID: "p", outputExcerpt: output, tokensPerSecond: 25,
                        timeToFirstTokenSeconds: 0.4, error: nil, fullOutput: mode == .chat ? nil : output)
                ], aggregateTokensPerSecond: 25, aggregateTTFTSeconds: 0.4, error: nil)
            }
            run.qualityReviews = ["/model/a": ComparisonQualityReview(score: 5, rubricID: "task-outcome-v1", reviewedAt: Date())]
            let view = VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                Text("\(mode.title) · Compare text A/B").font(WorkbenchTypography.cardTitle)
                if !changes {
                    TextComparisonEditor(run: run, store: store,
                        name: { $0 == "/model/a" ? "Qwen · 8-bit" : "Qwen · 4-bit" },
                        onReview: { _, _ in XCTFail("Reading must not write a rating") })
                } else {
                    TextComparisonContent(run: run, promptID: "p", leftPath: "/model/a", rightPath: "/model/b",
                    showChanges: changes, store: store, name: { $0 == "/model/a" ? "Qwen · 8-bit" : "Qwen · 4-bit" },
                    onReview: { _, _ in XCTFail("Reading outputs must not write quality ratings") })
                }
            }
            .padding(WorkbenchSpacing.pageInset).frame(width: width, height: 600, alignment: .topLeading)
            .background(WorkbenchColor.canvas).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Text A/B · \(mode.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
            if let directory = ProcessInfo.processInfo.environment["MLX_TEXT_COMPARISON_PROOF_DIR"] {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("text-\(mode.rawValue).png"))
            }
            window.close()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    }

    @MainActor
    func testTextEditorShowsSavedInputAndReferenceTranscriptContext() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("text-context"))
        var run = historyRun(.speechToText, "Transcript context fixture", at: 100, models: ["/model/a", "/model/b"])
        try store.createRunDirectory(run.id)
        let entry = PromptEntry(id: "p", text: "We build local models on this Mac.", inputKind: .audio, builtinInput: "speech")
        let audio = try await ComparisonMediaFixtures.generateInput(for: entry, into: store.inputsDirectory(run.id))
        run.promptEntries = [entry]
        run.inputArtifacts = [entry.id: audio.lastPathComponent]
        run.results = ["a", "b"].enumerated().map { index, key in
            VariantResult(modelPath: "/model/\(key)", modelSignature: "fixture", samples: [
                ComparisonSample(promptID: "p", outputExcerpt: index == 0 ? entry.text : "We build models on this Mac.",
                    tokensPerSecond: nil, timeToFirstTokenSeconds: nil, error: nil,
                    fullOutput: index == 0 ? entry.text : "We build models on this Mac.")
            ], aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil)
        }
        for (label, width) in [("saved", 1000.0), ("unavailable", 760.0)] {
            if label == "unavailable" { try FileManager.default.removeItem(at: audio) }
            let evidence = ComparisonViewLogic.inputEvidence(for: run, entry: entry, store: store)
            if label == "saved" { XCTAssertEqual(evidence.url, audio) }
            else { XCTAssertNil(evidence.url) }
            let view = TextComparisonEditor(run: run, store: store,
                name: { $0 == "/model/a" ? "Model A · fixture" : "Model B · fixture" },
                onReview: { _, _ in XCTFail("Rendering must not write a review") })
                .padding(WorkbenchSpacing.pageInset).frame(width: width, height: 600, alignment: .topLeading)
                .background(WorkbenchColor.canvas).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Text input context · \(label)"; attachment.lifetime = .keepAlways; add(attachment)
            if let directory = ProcessInfo.processInfo.environment["MLX_INPUT_EVIDENCE_PROOF_DIR"] {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("text-input-\(label).png"))
            }
            window.close()
        }
    }

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
            try await Task.sleep(for: .milliseconds(400))
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

    func testReuseSavedInputsAfterOriginalChangesOrDisappears() throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("saved-reuse"))
        for mode in [ComparisonMode.vision, .videoUnderstanding, .speechToText] {
            var run = historyRun(mode, "Saved inputs", at: 100)
            let original = root.appendingPathComponent("original-\(mode.rawValue).png")
            try Data("changed original".utf8).write(to: original)
            try store.createRunDirectory(run.id)
            let saved = store.inputsDirectory(run.id).appendingPathComponent("saved.png")
            try Data("recorded input".utf8).write(to: saved)
            run.promptEntries = [PromptEntry(id: "p", text: "Recorded text", inputKind: mode.inputKind,
                inputPath: original.path, expectedKeywords: ["recorded"])]
            run.inputArtifacts = ["p": "saved.png"]
            let history = run
            for removeOriginal in [false, true] {
                if removeOriginal { try FileManager.default.removeItem(at: original) }
                let setup = try ComparisonRunSetup(run: run, outputStore: store)
                XCTAssertTrue(setup.draft.prompts[0].usesSavedInput)
                XCTAssertFalse(setup.draft.prompts[0].inputFileUnavailable)
                XCTAssertEqual(setup.draft.prompts[0].inputPreviewURL, saved)
                let set = try setup.draft.promptSet()
                XCTAssertEqual(set.prompts[0].inputPath, saved.path)
                XCTAssertEqual(try Data(contentsOf: saved), Data("recorded input".utf8))
                XCTAssertEqual(try setup.savedDraft(named: "Copy").promptSet().prompts, set.prompts)
                XCTAssertEqual(run, history)
            }
        }
    }

    func testReuseMissingSavedInputsNeverFallsBackAndAcceptsExplicitReplacement() throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("missing-reuse"))
        var run = historyRun(.vision, "Saved inputs", at: 100)
        let original = root.appendingPathComponent("available-original.png")
        try Data("current file".utf8).write(to: original)
        run.promptEntries = [PromptEntry(id: "p", text: "Describe", inputKind: .image,
            inputPath: original.path, builtinInput: "red-circle")]
        try store.createRunDirectory(run.id)
        let link = store.inputsDirectory(run.id).appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        for artifacts in [[String: String](), ["p": "missing.png"], ["p": "../available-original.png"], ["p": "link.png"]] {
            run.inputArtifacts = artifacts
            var setup = try ComparisonRunSetup(run: run, outputStore: store)
            XCTAssertTrue(setup.draft.prompts[0].usesSavedInput)
            XCTAssertTrue(setup.draft.prompts[0].inputFileUnavailable)
            XCTAssertNil(setup.draft.prompts[0].inputPreviewURL)
            XCTAssertNil(setup.draft.prompts[0].builtinInput)
            XCTAssertThrowsError(try setup.draft.promptSet())
            XCTAssertThrowsError(try setup.savedDraft(named: "Copy").promptSet())
            setup.draft.prompts[0].inputPath = original.path
            XCTAssertFalse(setup.draft.prompts[0].usesSavedInput)
            XCTAssertEqual(try setup.draft.promptSet().prompts[0].inputPath, original.path)
            XCTAssertNil(try setup.draft.promptSet().prompts[0].builtinInput)
            setup.draft.prompts[0].inputPath = link.path
            XCTAssertThrowsError(try setup.draft.promptSet(), "A replacement symbolic link cannot be snapshotted")
        }
    }

    @MainActor
    func testReuseOldestRetainedInputCopiesBeforePruningAndPreservesSpeechLanguage() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("retained-reuse"))
        var run = historyRun(.speechToText, "Recorded speech", at: 100)
        let entry = ComparisonMediaFixtures.speechToTextSet.prompts[0]
        run.promptEntries = [entry]
        try store.createRunDirectory(run.id)
        let saved = store.inputsDirectory(run.id).appendingPathComponent("saved.wav")
        let contents = Data("saved speech fixture".utf8)
        try contents.write(to: saved)
        run.inputArtifacts = [entry.id: "saved.wav"]
        var history = [run]
        for index in 1..<ComparisonOutputStore.retainedRuns {
            let newer = historyRun(.speechToText, "Newer \(index)", at: 100 + Double(index))
            try store.createRunDirectory(newer.id)
            history.append(newer)
        }
        try JSONStore<ComparisonRun>(fileURL: root.appendingPathComponent("runs.json")).replaceAll(history)
        let runner = StubMediaRunner()
        let coordinator = makeCoordinator(runner: runner, store: store)
        let setup = try ComparisonRunSetup(run: run, outputStore: store)
        let set = try setup.draft.promptSet()
        XCTAssertEqual(set.prompts[0].inputPath, saved.path)
        coordinator.start(variants: [("/speech/a", "current")], promptSet: set)
        await waitForRun(coordinator)
        let requests = await runner.requests
        let request = try XCTUnwrap(requests.first)
        let input = try XCTUnwrap(request.inputURL)
        XCTAssertNotEqual(input, saved)
        XCTAssertEqual(try Data(contentsOf: input), contents)
        XCTAssertEqual(request.language, SpeechCanary.language)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.runDirectory(run.id).path))
        XCTAssertEqual(coordinator.runs.first { $0.id == run.id }, run)
        let next = try XCTUnwrap(coordinator.runs.first)
        XCTAssertEqual(next.state, .completed)
        XCTAssertNotNil(next.inputArtifacts?[entry.id])
        let directories = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
        XCTAssertEqual(directories.count, ComparisonOutputStore.retainedRuns)
    }

    @MainActor
    func testReuseSheetLabelsSavedAndPrunedInputs() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("reuse-proof"))
        var run = historyRun(.vision, "Bird descriptions · fixture", at: 100, models: ["/vision/a"])
        try store.createRunDirectory(run.id)
        let saved = store.inputsDirectory(run.id).appendingPathComponent("bird.png")
        try Data("input fixture".utf8).write(to: saved)
        run.promptEntries = [PromptEntry(id: "p", text: "Describe the bird and its surroundings", inputKind: .image,
            inputPath: root.appendingPathComponent("gone.png").path, expectedKeywords: ["bird", "snow"])]
        run.inputArtifacts = ["p": "bird.png"]
        for label in ["saved", "pruned"] {
            if label == "pruned" { try FileManager.default.removeItem(at: saved) }
            let sheet = ComparisonRunSetupSheet(setup: try ComparisonRunSetup(run: run, outputStore: store),
                availablePaths: ["/vision/a"], name: { _ in "Vision model · fixture" },
                onApply: { _, _ in XCTFail("Rendering must not apply or run"); return nil },
                onSave: { _ in XCTFail("Rendering must not save"); return nil })
            let host = NSHostingView(rootView: sheet.background(WorkbenchColor.canvas).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Reuse \(label) input"; attachment.lifetime = .keepAlways; add(attachment)
            if let directory = ProcessInfo.processInfo.environment["MLX_REUSE_SETUP_PROOF_DIR"] {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("reuse-input-\(label).png"))
            }
            window.close()
        }
    }

    @MainActor
    func testSavedReusedPromptSetOwnsInputsAfterRunCachePruningAndRestart() async throws {
        let outputs = ComparisonOutputStore(root: root.appendingPathComponent("cache"))
        var history = historyRun(.speechToText, "Saved speech", at: 100)
        try outputs.createRunDirectory(history.id)
        let source = outputs.inputsDirectory(history.id).appendingPathComponent("speech.wav")
        let bytes = Data("recorded speech".utf8)
        try bytes.write(to: source)
        var entry = ComparisonMediaFixtures.speechToTextSet.prompts[0]
        entry.inputPath = root.appendingPathComponent("original-gone.wav").path
        history.promptEntries = [entry]; history.inputArtifacts = [entry.id: source.lastPathComponent]
        let runs = JSONStore<ComparisonRun>(fileURL: root.appendingPathComponent("runs.json"))
        try runs.replaceAll([history])
        let historyBytes = try Data(contentsOf: runs.url)
        let runner = StubMediaRunner()
        let coordinator = makeCoordinator(runner: runner, store: outputs)
        let setup = try ComparisonRunSetup(run: history, outputStore: outputs)
        let result = await coordinator.createPromptSetWithInputCopies(setup.savedDraft(named: "Durable speech"))
        let saved = try XCTUnwrap(result)
        let owned = URL(fileURLWithPath: try XCTUnwrap(saved.prompts[0].inputPath))
        XCTAssertNotNil(saved.inputStorageID)
        XCTAssertNotEqual(owned, source)
        XCTAssertEqual(try Data(contentsOf: owned), bytes)
        XCTAssertEqual(try Data(contentsOf: runs.url), historyBytes)
        XCTAssertFalse(coordinator.savingPromptSet)
        XCTAssertNil(coordinator.activeRunID)
        let requestsBefore = await runner.requests
        XCTAssertTrue(requestsBefore.isEmpty)
        outputs.prune(keeping: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: owned), bytes)
        let restarted = makeCoordinator(runner: runner, store: outputs)
        let restored = try XCTUnwrap(restarted.promptSets.first { $0.id == saved.id })
        XCTAssertEqual(restored, saved)
        restarted.start(variants: [("/speech/model", "current")], promptSet: restored)
        await waitForRun(restarted)
        let requests = await runner.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(request.inputURL)), bytes)
        XCTAssertEqual(request.language, SpeechCanary.language)
        XCTAssertEqual(restarted.runs.first?.state, .completed)
        XCTAssertEqual(restarted.runs.first { $0.id == history.id }, history)
    }

    @MainActor
    func testOwnedInputSaveRollsBackPartialCopiesAndFailedJSONThenRetries() async throws {
        let source = root.appendingPathComponent("original.png")
        try Data("original image".utf8).write(to: source)
        var draft = ComparisonPromptSetDraft(mode: .vision)
        draft.name = "Saved images"; draft.prompts[0].text = "Describe"; draft.prompts[0].inputPath = source.path
        draft.addPrompt(); draft.prompts[1].text = "Describe again"; draft.prompts[1].inputPath = source.path
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let sets = root.appendingPathComponent("sets.json")
        let corrupt = Data("broken-json".utf8)
        try corrupt.write(to: sets)
        let failed = await coordinator.createPromptSetWithInputCopies(draft)
        XCTAssertNil(failed)
        XCTAssertFalse(coordinator.promptSets.contains { $0.id == draft.id })
        XCTAssertEqual(try Data(contentsOf: sets), corrupt)
        let ownedRoot = root.appendingPathComponent("prompt-set-inputs")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: ownedRoot.path).isEmpty)
        XCTAssertFalse(coordinator.savingPromptSet)
        try JSONStore<PromptSet>(fileURL: sets).replaceAll([])
        let retried = await coordinator.createPromptSetWithInputCopies(draft)
        let saved = try XCTUnwrap(retried)
        XCTAssertEqual(Set(saved.prompts.compactMap(\.inputPath)).count, 2)
        for entry in saved.prompts {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(entry.inputPath))), try Data(contentsOf: source))
        }
        let setBytes = try Data(contentsOf: sets)
        let idsBefore = try FileManager.default.contentsOfDirectory(atPath: ownedRoot.path)
        var bad = draft
        bad.name = "Unavailable"; bad.prompts[1].inputPath = root.appendingPathComponent("gone.png").path
        // The normal draft validates paths before copying; exercise a source disappearing
        // during the copy transaction through the storage boundary as well.
        let badSet = PromptSet(id: UUID().uuidString, name: "Partial", prompts: [
            PromptEntry(id: "a", text: "First", inputKind: .image, inputPath: source.path),
            PromptEntry(id: "b", text: "Second", inputKind: .image, inputPath: bad.prompts[1].inputPath)
        ], origin: .userCreated, mode: .vision)
        do { _ = try await ComparisonPromptInputStore(root: ownedRoot).copyingInputs(in: badSet); XCTFail("Missing second input must fail") }
        catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ownedRoot.path), idsBefore)
        XCTAssertEqual(try Data(contentsOf: sets), setBytes)
        XCTAssertEqual(try Data(contentsOf: source), Data("original image".utf8))
    }

    @MainActor
    func testRemovingOwnedPromptInputsPreservesBorrowedReferencesAndOtherFolders() async throws {
        let source = root.appendingPathComponent("source.png")
        try Data("original".utf8).write(to: source)
        var draft = ComparisonPromptSetDraft(mode: .vision)
        draft.name = "Owner"; draft.prompts[0].text = "Describe"; draft.prompts[0].inputPath = source.path
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let result = await coordinator.createPromptSetWithInputCopies(draft)
        let owner = try XCTUnwrap(result)
        let path = try XCTUnwrap(owner.prompts.first?.inputPath)
        let borrowed = PromptSet(id: UUID().uuidString, name: "Borrowed", prompts: owner.prompts, origin: .userCreated, mode: .vision)
        XCTAssertTrue(coordinator.savePromptSet(borrowed))
        let inputStore = ComparisonPromptInputStore(root: root.appendingPathComponent("prompt-set-inputs"))
        let unrelated = inputStore.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try Data("unrelated staged work".utf8).write(to: unrelated.appendingPathComponent("keep.txt"))
        let sets = root.appendingPathComponent("sets.json")
        let oldBytes = try Data(contentsOf: sets)
        try Data("corrupt".utf8).write(to: sets)
        XCTAssertFalse(coordinator.removePromptSet(id: owner.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        try oldBytes.write(to: sets)
        XCTAssertTrue(coordinator.removePromptSet(id: owner.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Another durable set still references this copy")
        XCTAssertTrue(coordinator.removePromptSet(id: borrowed.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.appendingPathComponent("keep.txt").path))
    }

    func testOwnedInputStoreRejectsSymlinksAndLegacySetsDecodeWithoutOwnership() async throws {
        let original = root.appendingPathComponent("original.png")
        try Data("original".utf8).write(to: original)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let ownedRoot = root.appendingPathComponent("owned")
        try FileManager.default.createSymbolicLink(at: ownedRoot, withDestinationURL: outside)
        let set = PromptSet(id: UUID().uuidString, name: "Legacy", prompts: [
            PromptEntry(id: "p", text: "Describe", inputKind: .image, inputPath: original.path)
        ], origin: .userCreated, mode: .vision)
        do { _ = try await ComparisonPromptInputStore(root: ownedRoot).copyingInputs(in: set); XCTFail("Linked store must fail") }
        catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.removeItem(at: ownedRoot)
        let link = root.appendingPathComponent("linked-input.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        var linked = set; linked.prompts[0].inputPath = link.path
        do { _ = try await ComparisonPromptInputStore(root: ownedRoot).copyingInputs(in: linked); XCTFail("Linked input must fail") }
        catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: ownedRoot.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(set)) as? [String: Any])
        json.removeValue(forKey: "inputStorageID")
        let legacy = try JSONDecoder().decode(PromptSet.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy, set)
        XCTAssertNil(legacy.inputStorageID)
    }

    @MainActor
    func testNewMediaPromptSetsKeepTheirOwnInputsWhenOriginalsDisappear() async throws {
        let runner = StubMediaRunner(), coordinator = makeCoordinator(runner: runner)
        for mode in [ComparisonMode.vision, .videoUnderstanding, .speechToText] {
            let original = root.appendingPathComponent("original-\(mode.rawValue).input")
            let bytes = Data("original \(mode.rawValue)".utf8)
            try bytes.write(to: original)
            var draft = ComparisonPromptSetDraft(mode: mode)
            draft.name = "New \(mode.title)"; draft.prompts[0].text = "Recorded reference"
            draft.prompts[0].inputPath = original.path
            let result = await coordinator.createPromptSetWithInputCopies(draft)
            let set = try XCTUnwrap(result)
            let path = try XCTUnwrap(set.prompts.first?.inputPath)
            XCTAssertNotEqual(path, original.path)
            try FileManager.default.removeItem(at: original)
            let restarted = makeCoordinator(runner: runner)
            let edit = try XCTUnwrap(restarted.preparePromptSetEdit(id: set.id))
            XCTAssertFalse(edit.prompts[0].inputFileUnavailable)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
            restarted.start(variants: [("/model", nil)], promptSet: try edit.promptSet())
            await waitForRun(restarted)
            XCTAssertEqual(restarted.runs.first?.state, .completed)
            let requests = await runner.requests
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(requests.last?.inputURL)), bytes)
        }
    }

    @MainActor
    func testOwnedPromptEditsReuseUnchangedFilesAndCopyOnlyReplacements() async throws {
        let first = root.appendingPathComponent("first.png"), second = root.appendingPathComponent("second.png")
        try Data("first".utf8).write(to: first); try Data("second".utf8).write(to: second)
        var draft = ComparisonPromptSetDraft(mode: .vision)
        draft.name = "Images"; draft.prompts[0].text = "First"; draft.prompts[0].inputPath = first.path
        draft.addPrompt(); draft.prompts[1].text = "Second"; draft.prompts[1].inputPath = second.path
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let result = await coordinator.createPromptSetWithInputCopies(draft)
        let original = try XCTUnwrap(result)
        let store = ComparisonOutputStore(root: root.appendingPathComponent("prompt-set-inputs"))
        let originalID = try XCTUnwrap(original.inputStorageID)
        let before = try FileManager.default.contentsOfDirectory(atPath: store.inputsDirectory(originalID).path)
        var edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: original.id))
        edit.prompts[0].text = "Changed question"; edit.prompts[0].maxTokens = "512"
        let textSaved = await coordinator.savePromptSetEditsWithInputCopies(edit)
        XCTAssertTrue(textSaved)
        let textOnly = try XCTUnwrap(coordinator.promptSets.first { $0.id == original.id })
        XCTAssertEqual(textOnly.inputStorageID, originalID)
        XCTAssertEqual(textOnly.prompts.map(\.inputPath), original.prompts.map(\.inputPath))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.inputsDirectory(originalID).path), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path), [originalID.uuidString])
        let replacement = root.appendingPathComponent("replacement.png")
        try Data("replacement".utf8).write(to: replacement)
        edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: original.id))
        edit.prompts[0].inputPath = replacement.path
        let replaced = await coordinator.savePromptSetEditsWithInputCopies(edit)
        XCTAssertTrue(replaced)
        let updated = try XCTUnwrap(coordinator.promptSets.first { $0.id == original.id })
        let newID = try XCTUnwrap(updated.inputStorageID)
        XCTAssertNotEqual(newID, originalID)
        XCTAssertEqual(updated.prompts[1].inputPath, original.prompts[1].inputPath)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.inputsDirectory(newID).path).count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(updated.prompts[0].inputPath))), Data("replacement".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.runDirectory(originalID).path), "The second prompt still owns its old input")
        edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: original.id))
        edit.removePrompt(id: edit.prompts[1].id)
        let removedPrompt = await coordinator.savePromptSetEditsWithInputCopies(edit)
        XCTAssertTrue(removedPrompt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.runDirectory(originalID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.runDirectory(newID).path))
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
        XCTAssertEqual(try Data(contentsOf: replacement), Data("replacement".utf8))
    }

    @MainActor
    func testOwnedPromptEditConflictAndCorruptStoreRollbackOnlyNewFiles() async throws {
        let source = root.appendingPathComponent("source.png"), replacement = root.appendingPathComponent("replacement.png")
        try Data("source".utf8).write(to: source); try Data("replacement".utf8).write(to: replacement)
        var draft = ComparisonPromptSetDraft(mode: .vision)
        draft.name = "Images"; draft.prompts[0].text = "Describe"; draft.prompts[0].inputPath = source.path
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let result = await coordinator.createPromptSetWithInputCopies(draft)
        let saved = try XCTUnwrap(result)
        let store = JSONStore<PromptSet>(fileURL: root.appendingPathComponent("sets.json"))
        let ownedRoot = root.appendingPathComponent("prompt-set-inputs")
        let folders = try FileManager.default.contentsOfDirectory(atPath: ownedRoot.path)
        var edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: saved.id))
        edit.prompts[0].inputPath = replacement.path
        var concurrent = saved; concurrent.prompts[0].text = "Another editor changed this"
        try store.replaceAll([concurrent])
        let conflicted = await coordinator.savePromptSetEditsWithInputCopies(edit)
        XCTAssertFalse(conflicted)
        XCTAssertTrue(coordinator.promptSetManagementError?.contains("reopen") == true)
        XCTAssertEqual(try store.load(), [concurrent])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ownedRoot.path), folders)
        edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: saved.id))
        edit.prompts[0].inputPath = replacement.path
        let corrupt = Data("broken-json".utf8)
        try corrupt.write(to: store.url)
        let failed = await coordinator.savePromptSetEditsWithInputCopies(edit)
        XCTAssertFalse(failed)
        XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ownedRoot.path), folders)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(saved.prompts.first?.inputPath))), Data("source".utf8))
        try store.replaceAll([concurrent])
        let retried = await coordinator.savePromptSetEditsWithInputCopies(edit)
        XCTAssertTrue(retried)
        XCTAssertFalse(coordinator.savingPromptSet)
        XCTAssertNil(coordinator.promptSetManagementError)
    }

    @MainActor
    func testOwnedInputEditReclaimsUsingCurrentLegacyRunReferences() async throws {
        let source = root.appendingPathComponent("source.png"), replacement = root.appendingPathComponent("replacement.png")
        try Data("source".utf8).write(to: source); try Data("replacement".utf8).write(to: replacement)
        var draft = ComparisonPromptSetDraft(mode: .vision)
        draft.name = "Images"; draft.prompts[0].text = "Describe"; draft.prompts[0].inputPath = source.path
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let result = await coordinator.createPromptSetWithInputCopies(draft)
        let saved = try XCTUnwrap(result)
        var legacy = historyRun(.vision, "Legacy reference", at: 100)
        legacy.promptEntries = saved.prompts
        let runs = JSONStore<ComparisonRun>(fileURL: root.appendingPathComponent("runs.json"))
        // Simulate a durable reference added after this coordinator loaded runs.
        try runs.replaceAll([legacy])
        let historyBytes = try Data(contentsOf: runs.url)
        var edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: saved.id))
        edit.prompts[0].inputPath = replacement.path
        let updated = await coordinator.savePromptSetEditsWithInputCopies(edit)
        XCTAssertTrue(updated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(saved.prompts.first?.inputPath)))
        XCTAssertEqual(try Data(contentsOf: runs.url), historyBytes)
        // A failed authoritative run-store read must also prevent reclamation.
        let current = try XCTUnwrap(coordinator.promptSets.first { $0.id == saved.id })
        try Data("broken-runs".utf8).write(to: runs.url)
        XCTAssertTrue(coordinator.removePromptSet(id: saved.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(current.prompts.first?.inputPath)))
    }

    @MainActor
    func testInputNamesSurviveOwnedCopiesEditsAndRecordedSetupReuse() async throws {
        let source = root.appendingPathComponent("Bird in snow.png")
        try Data("source image".utf8).write(to: source)
        var draft = ComparisonPromptSetDraft(mode: .vision)
        draft.name = "Readable inputs"; draft.prompts[0].text = "Describe"; draft.prompts[0].inputPath = source.path
        let runner = StubMediaRunner(), coordinator = makeCoordinator(runner: runner)
        let result = await coordinator.createPromptSetWithInputCopies(draft)
        let set = try XCTUnwrap(result)
        XCTAssertEqual(set.prompts[0].inputName, source.lastPathComponent)
        XCTAssertEqual(set.prompts[0].inputDisplayName, "Bird in snow.png")
        let ownedPath = try XCTUnwrap(set.prompts[0].inputPath)
        XCTAssertNotEqual(URL(fileURLWithPath: ownedPath).lastPathComponent, "Bird in snow.png")
        try FileManager.default.removeItem(at: source)
        let restored = try XCTUnwrap(JSONStore<PromptSet>(fileURL: root.appendingPathComponent("sets.json")).load().first)
        XCTAssertEqual(restored.prompts[0].inputDisplayName, "Bird in snow.png")
        var edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: set.id))
        XCTAssertEqual(edit.prompts[0].inputDisplayName, "Bird in snow.png")
        edit.prompts[0].text = "Describe the surroundings"
        let edited = await coordinator.savePromptSetEditsWithInputCopies(edit)
        XCTAssertTrue(edited)
        let textOnly = try XCTUnwrap(coordinator.promptSets.first { $0.id == set.id })
        XCTAssertEqual(textOnly.prompts[0].inputName, "Bird in snow.png")
        coordinator.start(variants: [("/vision/model", nil)], promptSet: textOnly)
        await waitForRun(coordinator)
        let run = try XCTUnwrap(coordinator.runs.first)
        let reuse = try ComparisonRunSetup(run: run, outputStore: coordinator.outputStore)
        XCTAssertEqual(reuse.draft.prompts[0].inputDisplayName, "Bird in snow.png")
        let reused = await coordinator.createPromptSetWithInputCopies(reuse.savedDraft(named: "Another copy"))
        XCTAssertEqual(reused?.prompts[0].inputName, "Bird in snow.png")
        XCTAssertNotEqual(reused?.prompts[0].inputPath, set.prompts[0].inputPath)
        let replacement = root.appendingPathComponent("New bird.jpg")
        try Data("replacement image".utf8).write(to: replacement)
        edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: set.id))
        edit.prompts[0].inputPath = replacement.path
        XCTAssertEqual(edit.prompts[0].inputDisplayName, "New bird.jpg")
        XCTAssertNil(try edit.promptSet().prompts[0].inputName, "Changing files must clear the previous display name")
        let replaced = await coordinator.savePromptSetEditsWithInputCopies(edit)
        XCTAssertTrue(replaced)
        XCTAssertEqual(coordinator.promptSets.first { $0.id == set.id }?.prompts[0].inputName, "New bird.jpg")
    }

    func testInputNamesAreDisplayOnlyAndLegacyNamesAreNotInvented() throws {
        var entry = PromptEntry(id: "p", text: "Describe", inputKind: .image,
            inputPath: root.appendingPathComponent("actual.png").path)
        let originalPath = entry.inputPath
        XCTAssertEqual(entry.inputDisplayName, "actual.png")
        for invalid in ["", ".", "..", "../other.png", "/private/other.png", "folder\\other.png", "name\n.png", "name\u{7f}.png", String(repeating: "a", count: 256)] {
            entry.inputName = invalid
            XCTAssertEqual(entry.inputDisplayName, "actual.png")
            XCTAssertEqual(entry.inputPath, originalPath)
        }
        entry.inputName = "Readable source.png"
        XCTAssertEqual(entry.inputDisplayName, "Readable source.png")
        XCTAssertEqual(entry.inputPath, originalPath)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json.removeValue(forKey: "inputName")
        let legacy = try JSONDecoder().decode(PromptEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.inputName)
        XCTAssertEqual(legacy.inputDisplayName, "actual.png")
        var run = historyRun(.vision, "Legacy input", at: 100)
        run.promptEntries = [legacy]; run.inputArtifacts = ["p": "missing.png"]
        let setup = try ComparisonRunSetup(run: run, outputStore: ComparisonOutputStore(root: root))
        XCTAssertEqual(setup.draft.prompts[0].inputDisplayName, "actual.png")
        XCTAssertTrue(setup.draft.prompts[0].inputFileUnavailable)
        XCTAssertNil(setup.draft.prompts[0].inputPreviewURL)
        XCTAssertThrowsError(try setup.draft.promptSet(), "A name must never resolve an unavailable file")
        entry.inputPath = nil; entry.inputName = nil
        XCTAssertNil(entry.inputDisplayName)
    }

    @MainActor
    func testReuseSheetShowsRecordedFilenameForSavedAndMissingCopies() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("name-proof"))
        var run = historyRun(.vision, "Named inputs · fixture", at: 100, models: ["/vision/a"])
        try store.createRunDirectory(run.id)
        let imageEntry = PromptEntry(id: "fixture", text: "Describe", inputKind: .image, builtinInput: "red-circle")
        let generated = try await ComparisonMediaFixtures.generateInput(for: imageEntry, into: root)
        let artifact = try await store.snapshotInput(from: generated, runID: run.id)
        run.promptEntries = [PromptEntry(id: "p", text: "Describe this bird and its surroundings", inputKind: .image,
            inputPath: root.appendingPathComponent("unknown-storage-name.png").path,
            inputName: "Bird photographs — winter reference.png")]
        run.inputArtifacts = ["p": artifact]
        for status in ["saved", "missing"] {
            if status == "missing" { try FileManager.default.removeItem(at: XCTUnwrap(store.inputArtifactURL(runID: run.id, artifact: artifact))) }
            let setup = try ComparisonRunSetup(run: run, outputStore: store)
            XCTAssertEqual(setup.draft.prompts[0].inputDisplayName, "Bird photographs — winter reference.png")
            let sheet = ComparisonRunSetupSheet(setup: setup, availablePaths: ["/vision/a"], name: { _ in "Vision model · fixture" },
                onApply: { _, _ in XCTFail("Rendering must not run"); return nil },
                onSave: { _ in XCTFail("Rendering must not save"); return nil })
            let host = NSHostingView(rootView: sheet.background(WorkbenchColor.canvas).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Input filename · \(status)"; attachment.lifetime = .keepAlways; add(attachment)
            if let directory = ProcessInfo.processInfo.environment["MLX_INPUT_NAME_PROOF_DIR"] {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("input-name-\(status).png"))
            }
            window.close()
        }
    }

    func testReuseOtherModesPreservesRecordedPromptsAndCreatesIndependentCopies() throws {
        let tool = BuiltinPromptSets.toolCalling.prompts[0].tool
        let input = root.appendingPathComponent("reference.png")
        try Data("reference".utf8).write(to: input)
        for mode in ComparisonMode.allCases where mode != .musicGeneration {
            var run = historyRun(mode, "Recorded", at: 100, models: ["/first", "/missing"])
            let entry = PromptEntry(id: "recorded", text: "Red bird", maxTokens: 77,
                tool: mode == .chat ? tool : nil, inputKind: mode.inputKind,
                inputPath: mode.inputKind == nil ? nil : input.path,
                expectedKeywords: ["red", "bird"],
                media: MediaParameters(size: 512, steps: 9, seed: 17, frames: 33, fps: 12))
            run.promptEntries = [entry]
            let original = run
            var setup = try ComparisonRunSetup(run: run)
            let temporary = try setup.draft.promptSet()
            XCTAssertNotEqual(temporary.id, run.promptSetID)
            XCTAssertEqual(temporary.effectiveMode, mode)
            XCTAssertEqual(temporary.prompts, [entry])
            XCTAssertEqual(setup.modelPaths, ["/first", "/missing"])
            setup.draft.prompts[0].text = "Blue bird"
            let saved = try setup.savedDraft(named: "Copy").promptSet()
            XCTAssertNotEqual(saved.id, temporary.id)
            XCTAssertEqual(saved.name, "Copy")
            XCTAssertEqual(saved.prompts[0].text, "Blue bird")
            XCTAssertEqual(saved.prompts[0].id, "recorded")
            XCTAssertEqual(saved.prompts[0].tool, entry.tool)
            XCTAssertEqual(run, original)
        }
        let chat = ComparisonRun(id: UUID(), promptSetID: "tools", promptSetName: "Tools", useCase: .coding,
            variants: ["/model"], results: [], startedAt: Date(), finishedAt: nil, state: .completed,
            promptEntries: [PromptEntry(id: "p", text: "Call a tool", tool: tool)])
        XCTAssertEqual(try ComparisonRunSetup(run: chat).draft.promptSet().useCase, .coding)
    }

    func testReuseOtherModesRejectsMissingSnapshotsAndInvalidSelections() throws {
        var run = historyRun(.imageGeneration, "Legacy", at: 100)
        XCTAssertThrowsError(try ComparisonRunSetup(run: run))
        run.promptEntries = []; XCTAssertThrowsError(try ComparisonRunSetup(run: run))
        run.promptEntries = [PromptEntry(id: "p", text: "A forest")]
        run.state = .running; XCTAssertThrowsError(try ComparisonRunSetup(run: run))
        run.state = .completed; run.mode = .musicGeneration
        XCTAssertThrowsError(try ComparisonRunSetup(run: run))
        run.mode = .imageGeneration
        run.promptEntries = [PromptEntry(id: "p", text: "A forest"), PromptEntry(id: "p", text: "Another forest")]
        XCTAssertThrowsError(try ComparisonRunSetup(run: run))
        for models in [[], [""], ["/model", "/model"], ["/a", "/b", "/c", "/d", "/e"]] {
            var invalid = historyRun(.chat, "Invalid selection", at: 100, models: models)
            invalid.promptEntries = [PromptEntry(id: "p", text: "Question")]
            XCTAssertThrowsError(try ComparisonRunSetup(run: invalid))
        }
    }

    func testReuseOtherModesFlagsMissingFilesAndAllowsReplacementOrBuiltinFixtures() throws {
        var run = historyRun(.vision, "Vision", at: 100)
        run.promptEntries = [PromptEntry(id: "p", text: "What is here?", inputKind: .image,
            inputPath: root.appendingPathComponent("gone.png").path)]
        var setup = try ComparisonRunSetup(run: run)
        XCTAssertTrue(setup.draft.prompts[0].inputFileUnavailable)
        XCTAssertThrowsError(try setup.draft.promptSet())
        let replacement = root.appendingPathComponent("new.png")
        try Data("reference".utf8).write(to: replacement)
        setup.draft.prompts[0].inputPath = replacement.path
        XCTAssertFalse(setup.draft.prompts[0].inputFileUnavailable)
        XCTAssertEqual(try setup.draft.promptSet().prompts[0].inputPath, replacement.path)
        run.promptEntries = [PromptEntry(id: "p", text: "What is here?", inputKind: .image, builtinInput: "red-circle")]
        let builtin = try ComparisonRunSetup(run: run)
        XCTAssertFalse(builtin.draft.prompts[0].inputFileUnavailable)
        XCTAssertEqual(try builtin.draft.promptSet().prompts[0].builtinInput, "red-circle")
    }

    @MainActor
    func testReusedVideoSetupSavesCopyAndStartsFreshRunWithoutChangingHistory() async throws {
        let runner = StubMediaRunner(), coordinator = makeCoordinator(runner: runner)
        var originalDraft = ComparisonPromptSetDraft(mode: .videoGeneration)
        originalDraft.name = "Video"; originalDraft.prompts[0].text = "A forest"
        originalDraft.prompts[0].steps = "9"; originalDraft.prompts[0].seed = "17"
        let originalSet = try XCTUnwrap(coordinator.createPromptSet(originalDraft))
        coordinator.start(variants: [("/video/a", "old-signature")], promptSet: originalSet)
        await waitForRun(coordinator)
        let runID = try XCTUnwrap(coordinator.runs.first?.id)
        coordinator.reviewQuality(runID: runID, modelPath: "/video/a", score: 4)
        let originalRun = try XCTUnwrap(coordinator.runs.first)
        let historyBefore = try Data(contentsOf: root.appendingPathComponent("runs.json"))
        var setup = try ComparisonRunSetup(run: originalRun)
        setup.draft.prompts[0].steps = "12"
        let saved = try XCTUnwrap(coordinator.createPromptSet(setup.savedDraft(named: "Video copy")))
        XCTAssertNotEqual(saved.id, originalSet.id)
        XCTAssertEqual(coordinator.promptSets.first { $0.id == originalSet.id }, originalSet)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("runs.json")), historyBefore)
        XCTAssertNil(coordinator.activeRunID)
        let requestsBeforeRun = await runner.requests
        XCTAssertEqual(requestsBeforeRun.count, 1)
        let temporary = try setup.draft.promptSet()
        coordinator.start(variants: [(setup.modelPaths[0], "new-signature")], promptSet: temporary)
        await waitForRun(coordinator)
        let next = try XCTUnwrap(coordinator.runs.first { $0.id != runID })
        XCTAssertEqual(next.state, .completed)
        XCTAssertEqual(next.promptEntries?.first?.media?.steps, 12)
        XCTAssertEqual(next.promptEntries?.first?.media?.seed, 17)
        XCTAssertEqual(next.results.first?.modelSignature, "new-signature")
        XCTAssertTrue(next.qualityReviews?.isEmpty ?? true)
        XCTAssertEqual(coordinator.runs.first { $0.id == runID }, originalRun)
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
    func testReuseOtherModeSheetRendersMissingInputsWithoutSavingOrRunning() async throws {
        var run = historyRun(.vision, "Bird descriptions", at: 100, models: ["/vision/a", "/vision/missing"])
        run.promptEntries = [PromptEntry(id: "recorded", text: "Describe the bird and its surroundings", maxTokens: 512,
            inputKind: .image, inputPath: root.appendingPathComponent("missing-bird.png").path,
            expectedKeywords: ["bird", "snow"])]
        let sheet = ComparisonRunSetupSheet(setup: try ComparisonRunSetup(run: run), availablePaths: ["/vision/a"],
            name: { $0 == "/vision/a" ? "Vision model · 8-bit" : "Vision model · 4-bit" },
            onApply: { _, _ in XCTFail("Rendering must not apply or run"); return nil },
            onSave: { _ in XCTFail("Rendering must not save"); return nil })
        let host = NSHostingView(rootView: sheet.background(WorkbenchColor.canvas).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "Reuse vision setup · missing model and file"; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["MLX_REUSE_SETUP_PROOF_DIR"] {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("reuse-vision.png"))
        }
        window.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sets.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runs.json").path))
    }

    @MainActor
    func testReusedSetupSaveFailureRetainsDraftAndCanRetryAsIndependentCopy() throws {
        var run = historyRun(.imageGeneration, "Images", at: 100)
        run.promptEntries = [PromptEntry(id: "p", text: "A red bird", media: MediaParameters(size: 768, steps: 9, seed: 17))]
        var setup = try ComparisonRunSetup(run: run)
        setup.draft.prompts[0].seed = "42"
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let storeURL = root.appendingPathComponent("sets.json")
        let corrupt = Data("broken-json".utf8); try corrupt.write(to: storeURL)
        XCTAssertNil(coordinator.createPromptSet(setup.savedDraft(named: "Copy")))
        XCTAssertEqual(try Data(contentsOf: storeURL), corrupt)
        XCTAssertEqual(try setup.draft.promptSet().prompts[0].media?.seed, 42)
        XCTAssertTrue(coordinator.promptSets.allSatisfy { $0.origin == .builtin })
        try FileManager.default.removeItem(at: storeURL)
        let saved = try XCTUnwrap(coordinator.createPromptSet(setup.savedDraft(named: "Copy")))
        XCTAssertNotEqual(saved.id, setup.draft.id)
        XCTAssertNil(coordinator.promptSetManagementError)
        XCTAssertEqual(saved.prompts[0].media, MediaParameters(size: 768, steps: 9, seed: 42))
        XCTAssertTrue(coordinator.runs.isEmpty)
        XCTAssertNil(coordinator.activeRunID)
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

    func testPromptDuplicationPreservesEditedFieldsAndHiddenMetadataInEveryOtherMode() throws {
        for mode in ComparisonMode.allCases where mode != .musicGeneration {
            let entry = PromptEntry(id: "original", text: "Reference", maxTokens: 77,
                tool: BuiltinPromptSets.toolCalling.prompts[0].tool, inputKind: mode.inputKind,
                builtinInput: mode.inputKind == nil ? nil : "fixture", expectedKeywords: ["red"],
                media: MediaParameters(size: 512, steps: 9, seed: 17, frames: 33, fps: 12))
            let set = PromptSet(id: "set", name: "Suite", useCase: .coding, prompts: [entry], origin: .userCreated, mode: mode)
            var draft = try ComparisonPromptSetDraft(set: set)
            draft.prompts[0].text = "Edited reference"
            draft.duplicatePrompt(id: entry.id)
            guard draft.prompts.count == 2 else { XCTFail("Duplicate must insert a second prompt"); continue }
            let copiedID = try XCTUnwrap(draft.prompts.last?.id)
            XCTAssertNotEqual(copiedID, entry.id)
            let saved = try draft.promptSet()
            var expected = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved.prompts[0])) as? [String: Any])
            let copied = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved.prompts[1])) as? [String: Any])
            expected["id"] = copiedID
            XCTAssertEqual(NSDictionary(dictionary: copied), NSDictionary(dictionary: expected))
            XCTAssertEqual(saved.useCase, set.useCase)
            draft.prompts[1].text = "Independent edit"
            XCTAssertEqual(draft.prompts[0].text, "Edited reference")
            draft.prompts[1].steps = "unfinished"
            draft.duplicatePrompt(id: copiedID)
            XCTAssertEqual(draft.prompts[2].steps, "unfinished", "Duplicate the draft, not only its last valid snapshot")
            XCTAssertEqual(Set(draft.prompts.map(\.id)).count, 3)
            XCTAssertEqual(set.prompts, [entry])
        }
    }

    @MainActor
    func testPromptOrderAndDuplicatesPersistAndReachRunnerWithoutChangingHistory() async throws {
        let runner = StubMediaRunner(), coordinator = makeCoordinator(runner: runner)
        var draft = ComparisonPromptSetDraft(mode: .imageGeneration)
        draft.name = "Ordered suite"; draft.prompts[0].text = "First scene"
        draft.prompts[0].seed = "7"
        draft.addPrompt(); draft.prompts[1].text = "Second scene"; draft.prompts[1].seed = "99"
        let first = draft.prompts[0].id, second = draft.prompts[1].id
        draft.movePrompt(id: first, direction: .up)
        draft.movePrompt(id: second, direction: .down)
        draft.movePrompt(id: "missing", direction: .up)
        draft.duplicatePrompt(id: "missing")
        XCTAssertEqual(draft.prompts.map(\.id), [first, second])
        draft.duplicatePrompt(id: first)
        let duplicate = draft.prompts[1].id
        draft.movePrompt(id: second, direction: .up)
        draft.movePrompt(id: second, direction: .up)
        XCTAssertEqual(draft.prompts.map(\.id), [second, first, duplicate])
        let created = await coordinator.createPromptSetWithInputCopies(draft)
        let set = try XCTUnwrap(created)
        XCTAssertEqual(makeCoordinator(runner: runner).promptSets.first { $0.id == set.id }, set)
        coordinator.start(variants: [("/image/a", nil)], promptSet: set)
        await waitForRun(coordinator)
        let requests = await runner.requests
        XCTAssertEqual(requests.map(\.entry.id), [second, first, duplicate])
        XCTAssertEqual(requests.map(\.entry.media?.seed), [99, 7, 7])
        let historyURL = root.appendingPathComponent("runs.json")
        let history = try Data(contentsOf: historyURL)
        var edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: set.id))
        edit.movePrompt(id: duplicate, direction: .up)
        edit.removePrompt(id: first)
        let saved = await coordinator.savePromptSetEditsWithInputCopies(edit)
        XCTAssertTrue(saved)
        XCTAssertEqual(coordinator.promptSets.first { $0.id == set.id }?.prompts.map(\.id), [second, duplicate])
        XCTAssertEqual(try Data(contentsOf: historyURL), history)
        XCTAssertEqual(coordinator.runs.first?.promptEntries, set.prompts)
    }

    @MainActor
    func testOtherModePromptSettingsPersistPerPromptAndReachTheRunner() async throws {
        let runner = StubMediaRunner(), coordinator = makeCoordinator(runner: runner)
        var draft = ComparisonPromptSetDraft(mode: .videoGeneration)
        draft.name = "Video contrasts"; draft.prompts[0].text = "Snow falling in a forest"
        draft.prompts[0].width = "640"; draft.prompts[0].height = "352"
        draft.prompts[0].frames = "33"; draft.prompts[0].fps = "12"
        draft.prompts[0].steps = "8"; draft.prompts[0].seed = "7"
        draft.addPrompt(); draft.prompts[1].text = "Clouds moving over mountains"
        draft.prompts[1].steps = "12"; draft.prompts[1].seed = "99"
        let set = try XCTUnwrap(coordinator.createPromptSet(draft))
        XCTAssertEqual(set.prompts[0].media, MediaParameters(width: 640, height: 352, steps: 8, seed: 7, frames: 33, fps: 12))
        XCTAssertEqual(set.prompts[1].media, MediaParameters(width: 416, height: 240, steps: 12, seed: 99, frames: 17))
        let loaded = makeCoordinator(runner: runner)
        XCTAssertEqual(loaded.promptSets.first { $0.id == set.id }, set)
        let requestsBefore = await runner.requests
        XCTAssertTrue(requestsBefore.isEmpty)
        coordinator.start(variants: [("/video/a", nil)], promptSet: set)
        await waitForRun(coordinator)
        let requests = await runner.requests
        XCTAssertEqual(requests.map(\.entry.media), [set.prompts[0].media, set.prompts[1].media])
        let run = try XCTUnwrap(coordinator.runs.first)
        let historyBytes = try Data(contentsOf: root.appendingPathComponent("runs.json"))
        var edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: set.id))
        edit.prompts[0].steps = "20"; edit.addPrompt(); edit.prompts[2].text = "A calm lake"
        edit.removePrompt(id: set.prompts[1].id)
        XCTAssertTrue(coordinator.savePromptSetEdits(edit))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("runs.json")), historyBytes)
        XCTAssertEqual(run.promptEntries, set.prompts)
        XCTAssertTrue(coordinator.renamePromptSet(id: set.id, name: "Renamed video"))
        XCTAssertTrue(coordinator.removePromptSet(id: set.id))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("runs.json")), historyBytes)
        XCTAssertEqual(coordinator.runs.first?.promptEntries, set.prompts)
    }

    @MainActor
    func testOtherModeEditingRejectsStaleAndCorruptStoresAndRecoversOnReopen() throws {
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        var draft = ComparisonPromptSetDraft(mode: .imageGeneration)
        draft.name = "Images"; draft.prompts[0].text = "A lighthouse"
        let set = try XCTUnwrap(coordinator.createPromptSet(draft))
        var edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: set.id)); edit.prompts[0].seed = "77"
        let store = JSONStore<PromptSet>(fileURL: root.appendingPathComponent("sets.json"))
        var changed = set; changed.prompts[0].text = "A mountain"
        try store.replaceAll([changed])
        XCTAssertFalse(coordinator.savePromptSetEdits(edit))
        XCTAssertEqual(try store.load(), [changed])
        var fresh = try XCTUnwrap(coordinator.preparePromptSetEdit(id: set.id)); fresh.prompts[0].seed = "99"
        XCTAssertTrue(coordinator.savePromptSetEdits(fresh))
        XCTAssertEqual(try store.load()[0].prompts[0].text, "A mountain")
        XCTAssertEqual(try store.load()[0].prompts[0].media?.seed, 99)
        let before = coordinator.promptSets, corrupt = Data("broken-json".utf8)
        try corrupt.write(to: store.url)
        XCTAssertFalse(coordinator.renamePromptSet(id: set.id, name: "Unsafe"))
        XCTAssertFalse(coordinator.removePromptSet(id: set.id))
        XCTAssertNil(coordinator.createPromptSet(draft))
        XCTAssertEqual(coordinator.promptSets, before)
        XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
    }

    @MainActor
    func testOtherModeDraftsValidateInputsAndProtectBuiltinsAndUneditedFields() throws {
        let input = root.appendingPathComponent("input.png"); try Data("input".utf8).write(to: input)
        let tool = BuiltinPromptSets.toolCalling.prompts[0].tool
        let original = PromptSet(id: "chat-edit", name: "Tools", useCase: .coding,
            prompts: [PromptEntry(id: "p", text: "Call the tool", maxTokens: 77, tool: tool)], origin: .userCreated)
        var chat = try ComparisonPromptSetDraft(set: original)
        chat.prompts[0].text = "Use the saved tool"; chat.prompts[0].maxTokens = "512"
        let edited = try chat.promptSet()
        XCTAssertEqual(edited.id, original.id); XCTAssertEqual(edited.mode, nil)
        XCTAssertEqual(edited.useCase, .coding); XCTAssertEqual(edited.prompts[0].tool, tool)
        XCTAssertEqual(edited.prompts[0].maxTokens, 512)
        XCTAssertThrowsError(try ComparisonPromptSetDraft(set: BuiltinPromptSets.coding))
        for mode in [ComparisonMode.vision, .videoUnderstanding, .speechToText] {
            var draft = ComparisonPromptSetDraft(mode: mode); draft.name = "Inputs"
            draft.prompts[0].text = "Describe the input"
            XCTAssertThrowsError(try draft.promptSet())
            draft.prompts[0].inputPath = input.path
            XCTAssertEqual(try draft.promptSet().prompts[0].inputKind, mode.inputKind)
            draft.prompts[0].inputPath = root.path
            XCTAssertThrowsError(try draft.promptSet())
        }
        var image = ComparisonPromptSetDraft(mode: .imageGeneration); image.name = "Images"; image.prompts[0].text = "Piano"
        let invalidImageFields: [(WritableKeyPath<ComparisonPromptSetDraft.Prompt, String>, String)] = [
            (\.size, "513"), (\.steps, "101"), (\.seed, "-1")]
        for (field, value) in invalidImageFields {
            var invalid = image; invalid.prompts[0][keyPath: field] = value
            XCTAssertThrowsError(try invalid.promptSet())
        }
        image.prompts[0].size = "768"; image.prompts[0].steps = "9"; image.prompts[0].seed = "100"
        XCTAssertEqual(try image.promptSet().prompts[0].media, MediaParameters(size: 768, steps: 9, seed: 100))
        let firstID = image.prompts[0].id
        image.removePrompt(id: firstID)
        XCTAssertEqual(image.prompts.count, 1)
        image.prompts = []; XCTAssertThrowsError(try image.promptSet())
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        XCTAssertFalse(coordinator.canManagePromptSet(id: BuiltinPromptSets.coding.id))
        XCTAssertFalse(coordinator.renamePromptSet(id: BuiltinPromptSets.coding.id, name: "Unsafe"))
        XCTAssertFalse(coordinator.removePromptSet(id: BuiltinPromptSets.coding.id))
    }

    func testInlineDraftValidationTracksEachPromptAndClearsAfterCorrection() throws {
        var draft = ComparisonPromptSetDraft(mode: .imageGeneration)
        XCTAssertNotNil(draft.nameValidationError)
        draft.name = "Images"
        draft.prompts[0].text = "A forest"
        XCTAssertNil(draft.validationError)
        draft.duplicatePrompt(id: draft.prompts[0].id)
        draft.prompts[1].steps = "101"
        XCTAssertNil(draft.prompts[0].validationError(for: draft.mode))
        XCTAssertEqual(draft.prompts[1].validationError(for: draft.mode), "Steps must be a whole number from 1 to 100.")
        XCTAssertEqual(draft.validationError, "Prompt 2: Steps must be a whole number from 1 to 100.")
        draft.prompts[1].steps = "10"
        draft.prompts[1].size = "513"
        XCTAssertEqual(draft.prompts[1].validationError(for: draft.mode), "Image size must be a multiple of 16 pixels.")
        draft.prompts[1].size = "512"
        XCTAssertNil(draft.validationError)
        XCTAssertEqual(try draft.promptSet().prompts.count, 2)
        draft.name = "bad\nname"
        XCTAssertNotNil(draft.nameValidationError)
        XCTAssertEqual(draft.validationError, draft.nameValidationError)
        draft.name = "Images"
        draft.prompts[1] = draft.prompts[0]
        XCTAssertNotNil(draft.validationError)
        XCTAssertThrowsError(try draft.promptSet())
    }

    func testInlineValidationChecksValuesWithoutReadingInputFilesAndSaveRechecksAvailability() throws {
        for mode in [ComparisonMode.chat, .vision, .videoUnderstanding, .speechToText, .textToSpeech, .imageGeneration, .videoGeneration] {
            var draft = ComparisonPromptSetDraft(mode: mode)
            draft.name = "Suite"
            draft.prompts[0].text = "Prompt"
            if mode.inputKind != nil {
                XCTAssertNotNil(draft.validationError)
                draft.prompts[0].inputPath = root.appendingPathComponent("absent.wav").path
                XCTAssertNil(draft.validationError, "Inline validation must not read the filesystem")
                XCTAssertThrowsError(try draft.promptSet(), "Save must still refuse missing inputs")
                draft.prompts[0].inputPath = "relative.wav"
                XCTAssertNotNil(draft.validationError)
                draft.prompts[0].inputPath = "/bad\npath.wav"
                XCTAssertNotNil(draft.validationError)
            } else {
                XCTAssertNil(draft.validationError)
                XCTAssertNoThrow(try draft.promptSet())
            }
        }
        var video = ComparisonPromptSetDraft(mode: .videoGeneration)
        video.name = "Video"; video.prompts[0].text = "Waves"
        video.prompts[0].fps = "61"
        XCTAssertNotNil(video.validationError)
        video.prompts[0].fps = ""
        XCTAssertNil(video.validationError, "Blank settings remain valid runtime defaults")
        video.prompts = []
        XCTAssertNotNil(video.validationError)
    }

    @MainActor
    func testInlineValidationEditorsRenderIssuesAndCorrectedValuesWithoutSaving() async throws {
        for invalid in [true, false] {
            var draft = ComparisonPromptSetDraft(mode: .imageGeneration)
            draft.name = "Landscape studies"; draft.prompts[0].text = "A mountain lake at sunrise"
            draft.prompts[0].size = invalid ? "513" : "512"
            let content = ComparisonPromptSetEditor(draft: draft) { _ in
                XCTFail("Rendering validation must never save or generate"); return nil
            }.background(WorkbenchColor.canvas).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let title = invalid ? "invalid" : "corrected"
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Inline prompt validation · \(title)"; attachment.lifetime = .keepAlways; add(attachment)
            if let path = ProcessInfo.processInfo.environment["MLX_INLINE_VALIDATION_PROOF_DIR"] {
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("\(title).png"))
            }
            window.close()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sets.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runs.json").path))
    }

    func testMusicInlineValidationIdentifiesThePromptAcrossCreateEditAndReuse() throws {
        var draft = MusicPromptSetDraft(); draft.name = "Instrumentals"
        draft.prompts[0].caption = "Solo piano"
        draft.addPrompt(); draft.prompts[1].caption = "Acoustic guitar"
        let saved = try draft.promptSet()
        draft.prompts[1].steps = "31"
        let message = "Steps must be a whole number from 1 to 30."
        XCTAssertNil(draft.prompts[0].validationError)
        XCTAssertEqual(draft.prompts[1].validationError, message)
        XCTAssertEqual(draft.validationError, "Prompt 2: \(message)")
        var edit = try MusicPromptSetEdit(set: saved)
        edit.prompts = draft.prompts
        XCTAssertEqual(edit.validationError, draft.validationError)
        var run = historyRun(.musicGeneration, saved.name, at: 100)
        run.promptEntries = saved.prompts
        var setup = try MusicComparisonSetup(run: run)
        setup.prompts = draft.prompts
        XCTAssertEqual(setup.validationError, draft.validationError)
        setup.prompts.movePrompt(id: setup.prompts[1].id, direction: .up)
        XCTAssertEqual(setup.validationError, "Prompt 1: \(message)")
        draft.prompts[1].steps = "30"
        XCTAssertNil(draft.validationError)
        XCTAssertEqual(try draft.promptSet(), saved, "Correcting a value preserves identities and metadata")
        for field in ["", "nan", "0", "361"] {
            draft.prompts[1].duration = field
            if field.isEmpty { XCTAssertNil(draft.validationError) }
            else { XCTAssertNotNil(draft.prompts[1].validationError) }
        }
    }

    func testMusicInlineValidationKeepsNamesAndDefaultsConsistentWithSave() throws {
        var draft = MusicPromptSetDraft()
        XCTAssertNotNil(draft.nameValidationError)
        XCTAssertEqual(draft.validationError, draft.nameValidationError)
        draft.name = "Solo"
        XCTAssertNotNil(draft.prompts[0].validationError)
        draft.prompts[0].caption = "Piano"
        for name in ["", " \n ", "bad\nname", "bad\u{0}"] {
            draft.name = name
            XCTAssertNotNil(draft.nameValidationError)
            XCTAssertThrowsError(try draft.promptSet())
        }
        draft.name = " Solo "
        draft.prompts[0].lyrics = ""; draft.prompts[0].duration = ""
        draft.prompts[0].steps = ""; draft.prompts[0].seed = ""
        XCTAssertNil(draft.validationError)
        XCTAssertEqual(try draft.promptSet().name, "Solo")
        XCTAssertEqual(try draft.promptSet().prompts[0].media, MediaParameters())
        draft.prompts[0].seed = "-1"
        XCTAssertNotNil(draft.validationError)
        draft.prompts[0].seed = ""
        draft.prompts.append(draft.prompts[0])
        XCTAssertNotNil(draft.validationError)
        XCTAssertThrowsError(try draft.promptSet())
        draft.prompts = []
        XCTAssertNotNil(draft.validationError)
    }

    @MainActor
    func testMusicInlineValidationRendersCreateEditAndReuseWithoutSavingOrGenerating() async throws {
        for invalid in [true, false] {
            var draft = MusicPromptSetDraft(); draft.name = "Instrumental studies"
            draft.prompts[0].caption = "Warm solo piano, a gentle melody, no vocals"
            draft.prompts[0].duration = invalid ? "361" : "15"
            let set = PromptSet(id: "fixture", name: draft.name, useCase: nil,
                prompts: [PromptEntry(id: "p", text: draft.prompts[0].caption)], origin: .userCreated, mode: .musicGeneration)
            var edit = try MusicPromptSetEdit(set: set); edit.prompts = draft.prompts
            var run = historyRun(.musicGeneration, draft.name, at: 100, models: ["/music/model"])
            run.promptEntries = set.prompts
            var setup = try MusicComparisonSetup(run: run); setup.prompts = draft.prompts
            let fixtures: [(String, AnyView)] = [
                ("create", AnyView(MusicPromptSetCreateSheet(draft: draft) { _ in
                    XCTFail("Validation must not save or generate"); return nil
                })),
                ("edit", AnyView(MusicPromptSetEditSheet(edit: edit) { _ in
                    XCTFail("Validation must not save edits or generate"); return nil
                })),
                ("reuse", AnyView(MusicComparisonSetupSheet(setup: setup, availablePaths: ["/music/model"],
                    name: { _ in "Music model" }, onApply: { _, _ in XCTFail("Validation must not apply or generate") },
                    onSave: { _ in XCTFail("Validation must not save") })))
            ]
            for (kind, content) in fixtures {
                let host = NSHostingView(rootView: content.background(WorkbenchColor.canvas).preferredColorScheme(.dark))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let title = "\(kind)-\(invalid ? "invalid" : "corrected")"
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "Music inline validation · \(title)"; attachment.lifetime = .keepAlways; add(attachment)
                if let path = ProcessInfo.processInfo.environment["MLX_MUSIC_INLINE_PROOF_DIR"] {
                    try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("\(title).png"))
                }
                window.close()
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sets.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runs.json").path))
    }

    func testPromptScrollTargetsOnlyNewIdentities() {
        XCTAssertEqual(ComparisonPromptScrollLogic.insertedID(before: ["a", "b"], after: ["a", "b", "c"]), "c")
        XCTAssertEqual(ComparisonPromptScrollLogic.insertedID(before: ["a", "b"], after: ["a", "copy", "b"]), "copy")
        XCTAssertNil(ComparisonPromptScrollLogic.insertedID(before: ["a", "b"], after: ["b", "a"]))
        XCTAssertNil(ComparisonPromptScrollLogic.insertedID(before: ["a", "b"], after: ["b"]))
        XCTAssertNil(ComparisonPromptScrollLogic.insertedID(before: ["a", "b"], after: ["a", "b"]))
        XCTAssertNil(ComparisonPromptScrollLogic.insertedID(before: ["a"], after: []))
    }

    func testPromptIssueNavigationTracksCurrentOrderAndRawValidation() throws {
        for mode in ComparisonMode.allCases where mode != .musicGeneration {
            var original = mode == .chat ? BuiltinPromptSets.toolCalling : promptSet(for: mode)
            original.origin = .userCreated
            var draft = try ComparisonPromptSetDraft(set: original)
            draft.duplicatePrompt(id: draft.prompts[0].id)
            XCTAssertNil(ComparisonPromptScrollLogic.firstIssue(in: draft.prompts) { $0.validationError(for: mode) })
            let id = draft.prompts[1].id
            draft.prompts[1].text = "\u{0001}"
            let before = draft.prompts
            let issue = try XCTUnwrap(ComparisonPromptScrollLogic.firstIssue(in: draft.prompts) { $0.validationError(for: mode) })
            XCTAssertEqual(issue.promptID, id)
            XCTAssertEqual(issue.number, 2)
            XCTAssertEqual(issue.message, draft.prompts[1].validationError(for: mode))
            XCTAssertEqual(draft.prompts, before, "Navigation must not mutate draft values")
            draft.movePrompt(id: id, direction: .up)
            XCTAssertEqual(ComparisonPromptScrollLogic.firstIssue(in: draft.prompts) { $0.validationError(for: mode) }?.number, 1)
            draft.prompts[0].text = "Corrected"
            XCTAssertNil(ComparisonPromptScrollLogic.firstIssue(in: draft.prompts) { $0.validationError(for: mode) })
            draft.prompts[0].text = "\u{0001}"
            draft.removePrompt(id: id)
            XCTAssertNil(ComparisonPromptScrollLogic.firstIssue(in: draft.prompts) { $0.validationError(for: mode) }, "Single-card editors need no jump action")
        }
        var prompts = (1...3).map { MusicComparisonSetup.Prompt(PromptEntry(id: "music-\($0)", text: "Piano")) }
        prompts[1].duration = "invalid"
        prompts[2].steps = "invalid"
        XCTAssertEqual(ComparisonPromptScrollLogic.firstIssue(in: prompts, error: { $0.validationError })?.promptID, "music-2")
        prompts.movePrompt(id: "music-3", direction: .up)
        XCTAssertEqual(ComparisonPromptScrollLogic.firstIssue(in: prompts, error: { $0.validationError })?.promptID, "music-3")
        prompts.removePrompt(id: "music-3")
        XCTAssertEqual(ComparisonPromptScrollLogic.firstIssue(in: prompts, error: { $0.validationError })?.number, 2)
        prompts[1].duration = "15"
        XCTAssertNil(ComparisonPromptScrollLogic.firstIssue(in: prompts, error: { $0.validationError }))
        prompts[0].steps = "bad"
        prompts.removePrompt(id: "music-2")
        XCTAssertNil(ComparisonPromptScrollLogic.firstIssue(in: prompts, error: { $0.validationError }))
    }

    @MainActor
    func testPromptEditorsJumpToHiddenInvalidCardOnlyOnRequest() async throws {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        func navigationButtons(in view: NSView) -> [NSButton] {
            // Card controls are inside the scroll view; the compact issue action
            // is the shared field view's only button outside that scroll area.
            if view is NSScrollView { return [] }
            if let button = view as? NSButton { return [button] }
            return view.subviews.flatMap { navigationButtons(in: $0) }
        }
        for music in [false, true] {
            let fixture = PromptEditorScrollFixture()
            let host = NSHostingView(rootView: PromptEditorScrollFixtureView(fixture: fixture, music: music))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            let scroll = try XCTUnwrap(scrollViews(in: host).max {
                ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
            })
            let initial = scroll.documentVisibleRect.minY
            if music { fixture.music[3].duration = "invalid" }
            else { fixture.draft.prompts[3].steps = "invalid" }
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(scroll.documentVisibleRect.minY, initial, accuracy: 2, "Validation must not request an automatic jump")
            let buttons = navigationButtons(in: host)
            XCTAssertEqual(buttons.count, 1)
            let button = try XCTUnwrap(buttons.first)
            let draftBefore = fixture.draft.prompts
            let musicBefore = fixture.music
            button.performClick(nil)
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(scroll.documentVisibleRect.minY - initial, 100, "The invalid card must be revealed")
            XCTAssertEqual(fixture.draft.prompts, draftBefore)
            XCTAssertEqual(fixture.music, musicBefore)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let title = music ? "music" : "image"
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Revealed invalid prompt · \(title)"; attachment.lifetime = .keepAlways; add(attachment)
            if let path = ProcessInfo.processInfo.environment["MLX_PROMPT_ISSUE_PROOF_DIR"] {
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("\(title).png"))
            }
            let revealed = scroll.documentVisibleRect.minY
            if music { fixture.music[3].duration = "15" }
            else { fixture.draft.prompts[3].steps = "20" }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertTrue(navigationButtons(in: host).isEmpty, "Correcting the error removes the action")
            // Removing the footer may clamp the viewport, but must retain the corrected card.
            XCTAssertGreaterThan(scroll.documentVisibleRect.minY - initial, 100)
            XCTAssertLessThan(abs(scroll.documentVisibleRect.minY - revealed), 100)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sets.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runs.json").path))
    }

    @MainActor
    func testPromptEditorsRevealAddedAndDuplicatedCardsWithoutSaving() async throws {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        for music in [false, true] {
            let fixture = PromptEditorScrollFixture()
            let host = NSHostingView(rootView: PromptEditorScrollFixtureView(fixture: fixture, music: music))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(scrollViews(in: host).max {
                ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
            })
            let initial = scroll.documentVisibleRect.minY
            let initialDocumentHeight = try XCTUnwrap(scroll.documentView).bounds.height
            if music { fixture.music.addPrompt() } else { fixture.draft.addPrompt() }
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let added = scroll.documentVisibleRect.minY
            XCTAssertGreaterThan(abs(added - initial), 100, "Adding must reveal the new card")
            if music { fixture.music.duplicatePrompt(id: fixture.music[0].id) }
            else { fixture.draft.duplicatePrompt(id: fixture.draft.prompts[0].id) }
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let duplicated = scroll.documentVisibleRect.minY
            XCTAssertGreaterThan(abs(duplicated - added), 100, "Duplicating must reveal the new adjacent card")
            // The four initial fixture cards have identical heights. Prompt 2
            // must start at the top, including its heading and action controls.
            XCTAssertEqual(duplicated - initial, (initialDocumentHeight + WorkbenchSpacing.md) / 4,
                accuracy: 2, "The new card's heading must not be clipped")
            if music { fixture.music[1].caption = "Solo cello 1" }
            else { fixture.draft.prompts[1].text = "Seascape 1" }
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(scroll.documentVisibleRect.minY, duplicated, accuracy: 2, "Typing must retain the scroll position")
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let title = music ? "music" : "image"
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Revealed duplicate · \(title)"; attachment.lifetime = .keepAlways; add(attachment)
            if let path = ProcessInfo.processInfo.environment["MLX_PROMPT_SCROLL_PROOF_DIR"] {
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("\(title).png"))
            }
            window.close()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sets.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runs.json").path))
    }

    func testSavedPromptDraftDetectsRawEditsAndRevertsTheOpenedSnapshot() throws {
        for mode in ComparisonMode.allCases where mode != .musicGeneration {
            var original = mode == .chat ? BuiltinPromptSets.toolCalling : promptSet(for: mode)
            original.origin = .userCreated
            original.inputStorageID = UUID()
            var draft = try ComparisonPromptSetDraft(set: original)
            XCTAssertFalse(draft.hasChanges)
            draft.prompts[0].text += " edited"
            XCTAssertTrue(draft.hasChanges)
            draft.prompts[0].steps = "invalid raw value"
            XCTAssertTrue(draft.hasChanges, "Invalid raw input is still an unsaved edit")
            draft.duplicatePrompt(id: draft.prompts[0].id)
            draft.movePrompt(id: draft.prompts.last!.id, direction: .up)
            draft.removePrompt(id: draft.prompts[0].id)
            draft.revertChanges()
            XCTAssertFalse(draft.hasChanges)
            XCTAssertEqual(try draft.promptSet(), original, "Revert must preserve original identities, metadata and input references")
            let oldText = draft.prompts[0].text
            draft.prompts[0].text = "Temporary"
            draft.prompts[0].text = oldText
            XCTAssertFalse(draft.hasChanges, "Manually restoring a field must clear dirty state")
        }
        var copy = try ComparisonPromptSetDraft(copying: BuiltinPromptSets.toolCalling)
        let before = try copy.promptSet()
        XCTAssertTrue(copy.hasChanges, "Independent new copies must still be saveable")
        copy.revertChanges()
        XCTAssertEqual(try copy.promptSet(), before, "A new copy has no saved original to revert")
    }

    func testNewAndCopiedDraftCheckpointsDetectRawEditsWithoutChangingSaveSemantics() throws {
        for mode in ComparisonMode.allCases where mode != .musicGeneration {
            let source = mode == .chat ? BuiltinPromptSets.toolCalling : promptSet(for: mode)
            for copied in [false, true] {
                var draft = copied ? try ComparisonPromptSetDraft(copying: source) : ComparisonPromptSetDraft(mode: mode)
                let checkpoint = ComparisonPromptDraftCheckpoint(name: draft.name, prompts: draft.prompts)
                XCTAssertFalse(checkpoint.hasChanges(name: draft.name, prompts: draft.prompts), "Opening alone must not require confirmation")
                XCTAssertTrue(draft.hasChanges, "Independent creation must keep its Save semantics")
                let name = draft.name
                draft.name += "A new name"
                XCTAssertTrue(checkpoint.hasChanges(name: draft.name, prompts: draft.prompts))
                draft.name = name
                draft.prompts[0].text += "\u{0001}"
                XCTAssertTrue(checkpoint.hasChanges(name: draft.name, prompts: draft.prompts), "Invalid raw values are still edits")
                draft.prompts[0].text.removeLast()
                XCTAssertFalse(checkpoint.hasChanges(name: draft.name, prompts: draft.prompts))
                let originalID = draft.prompts[0].id
                draft.duplicatePrompt(id: originalID)
                XCTAssertTrue(checkpoint.hasChanges(name: draft.name, prompts: draft.prompts))
                draft.removePrompt(id: draft.prompts[1].id)
                XCTAssertFalse(checkpoint.hasChanges(name: draft.name, prompts: draft.prompts))
            }
        }
        for copied in [false, true] {
            var draft = copied ? try MusicPromptSetDraft(copying: promptSet(for: .musicGeneration)) : MusicPromptSetDraft()
            let checkpoint = ComparisonPromptDraftCheckpoint(name: draft.name, prompts: draft.prompts)
            XCTAssertFalse(checkpoint.hasChanges(name: draft.name, prompts: draft.prompts))
            draft.prompts[0].duration = "invalid"
            XCTAssertTrue(checkpoint.hasChanges(name: draft.name, prompts: draft.prompts))
            draft.name += "Named copy"
            XCTAssertTrue(checkpoint.hasChanges(name: draft.name, prompts: draft.prompts))
        }
    }

    func testReuseCheckpointRetainsSuccessfulCopiesAndRearmsForFurtherEdits() throws {
        var prompts = (1...2).map { MusicComparisonSetup.Prompt(PromptEntry(id: "p-\($0)", text: "Solo piano \($0)")) }
        var checkpoint = ComparisonPromptDraftCheckpoint(prompts: prompts)
        XCTAssertFalse(checkpoint.hasChanges(prompts: prompts))
        prompts.movePrompt(id: "p-2", direction: .up)
        XCTAssertTrue(checkpoint.hasChanges(prompts: prompts), "Recorded order is part of the draft")
        // A failed save does not advance the checkpoint.
        XCTAssertTrue(checkpoint.hasChanges(prompts: prompts))
        checkpoint.retain(prompts: prompts)
        XCTAssertFalse(checkpoint.hasChanges(prompts: prompts), "A successfully saved copy retains these inputs")
        prompts[0].lyrics = "Edited lyrics"
        XCTAssertTrue(checkpoint.hasChanges(prompts: prompts), "Further edits must require confirmation again")
        var draft = try ComparisonPromptSetDraft(copying: BuiltinPromptSets.toolCalling)
        var textCheckpoint = ComparisonPromptDraftCheckpoint(prompts: draft.prompts)
        draft.prompts[0].maxTokens = "invalid"
        XCTAssertTrue(textCheckpoint.hasChanges(prompts: draft.prompts))
        draft.prompts[0].maxTokens = "128"
        textCheckpoint.retain(prompts: draft.prompts)
        XCTAssertFalse(textCheckpoint.hasChanges(prompts: draft.prompts))
        draft.prompts[0].maxTokens = "256"
        XCTAssertTrue(textCheckpoint.hasChanges(prompts: draft.prompts))
    }

    func testSavedMusicDraftDetectsInvalidRawEditsAndRestoresMetadataAndOrder() throws {
        var original = promptSet(for: .musicGeneration); original.origin = .userCreated
        original.useCase = .coding
        var edit = try MusicPromptSetEdit(set: original)
        XCTAssertFalse(edit.hasChanges)
        edit.prompts[0].duration = "invalid"
        XCTAssertTrue(edit.hasChanges)
        XCTAssertNotNil(edit.validationError)
        edit.prompts.duplicatePrompt(id: edit.prompts[0].id)
        edit.prompts.movePrompt(id: edit.prompts.last!.id, direction: .up)
        edit.prompts.addPrompt()
        edit.revertChanges()
        XCTAssertFalse(edit.hasChanges)
        XCTAssertNil(edit.validationError)
        XCTAssertEqual(try edit.updatedPromptSet(), original)
        edit.prompts[0].caption = "Changed caption"
        XCTAssertTrue(edit.hasChanges)
        edit.prompts[0].caption = original.prompts[0].text
        XCTAssertFalse(edit.hasChanges)
    }

    @MainActor
    func testPromptCancelKeepsDraftUntilExplicitDiscardAndClosesUnchangedImmediately() async throws {
        func buttons(in view: NSView) -> [NSButton] {
            if let button = view as? NSButton { return [button] }
            return view.subviews.flatMap { buttons(in: $0) }
        }
        for dirty in [false, true] {
            let fixture = PromptCancelFixture(requiresConfirmation: dirty)
            let host = NSHostingView(rootView: PromptCancelFixtureView(fixture: fixture))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 90),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(150))
            try XCTUnwrap(buttons(in: host).first).performClick(nil)
            try await Task.sleep(for: .milliseconds(150))
            if !dirty {
                XCTAssertEqual(fixture.dismissals, 1, "Unchanged drafts close immediately")
                continue
            }
            XCTAssertEqual(fixture.dismissals, 0, "Cancel must not silently discard draft changes")
            let choices = buttons(in: host)
            XCTAssertEqual(choices.count, 2, "Offer Keep editing and Discard changes")
            guard choices.count == 2 else { continue }
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Keep editing or discard · native control fixture"
            attachment.lifetime = .keepAlways; add(attachment)
            if let path = ProcessInfo.processInfo.environment["MLX_PROMPT_REVERT_PROOF_DIR"] {
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("discard-choices.png"))
            }
            choices[0].performClick(nil)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(fixture.dismissals, 0, "Keep editing must retain the draft")
            XCTAssertEqual(buttons(in: host).count, 1)
            try XCTUnwrap(buttons(in: host).first).performClick(nil)
            try await Task.sleep(for: .milliseconds(150))
            try XCTUnwrap(buttons(in: host).last).performClick(nil)
            XCTAssertEqual(fixture.dismissals, 1, "Only explicit Discard closes an edited draft")
        }
    }

    @MainActor
    func testPromptCancelReturnsToImmediateCloseAfterDraftRevert() async throws {
        func buttons(in view: NSView) -> [NSButton] {
            if let button = view as? NSButton { return [button] }
            return view.subviews.flatMap { buttons(in: $0) }
        }
        let fixture = PromptCancelFixture(requiresConfirmation: true)
        let host = NSHostingView(rootView: PromptCancelFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 90),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        try XCTUnwrap(buttons(in: host).first).performClick(nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.dismissals, 0)
        fixture.requiresConfirmation = false
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(buttons(in: host).count, 1)
        try XCTUnwrap(buttons(in: host).first).performClick(nil)
        XCTAssertEqual(fixture.dismissals, 1)
    }

    @MainActor
    func testSavedPromptEditorsRenderUnchangedAndEditedActionsWithoutWriting() async throws {
        for music in [false, true] {
            let original = PromptSet(id: "saved-fixture", name: music ? "Piano studies" : "Landscape studies", useCase: nil,
                prompts: [PromptEntry(id: "p", text: music ? "Warm solo piano, a gentle melody, no vocals" : "A mountain lake at sunrise",
                    media: music ? MediaParameters(steps: 30, seed: 42, durationSeconds: 15, lyrics: "[instrumental]")
                        : MediaParameters(size: 512, steps: 20, seed: 42))], origin: .userCreated,
                mode: music ? .musicGeneration : .imageGeneration)
            for changed in [false, true] {
                let content: AnyView
                if music {
                    var edit = try MusicPromptSetEdit(set: original)
                    if changed { edit.prompts[0].steps = "10" }
                    content = AnyView(MusicPromptSetEditSheet(edit: edit) { _ in
                        XCTFail("Rendering draft actions must not save or generate"); return nil
                    })
                } else {
                    var draft = try ComparisonPromptSetDraft(set: original)
                    if changed { draft.prompts[0].steps = "10" }
                    content = AnyView(ComparisonPromptSetEditor(draft: draft) { _ in
                        XCTFail("Rendering draft actions must not save or generate"); return nil
                    })
                }
                let host = NSHostingView(rootView: content.background(WorkbenchColor.canvas).preferredColorScheme(.dark))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let title = "\(music ? "music" : "image")-\(changed ? "edited" : "unchanged")"
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "Saved draft actions · \(title)"; attachment.lifetime = .keepAlways; add(attachment)
                if let path = ProcessInfo.processInfo.environment["MLX_PROMPT_REVERT_PROOF_DIR"] {
                    try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("\(title).png"))
                }
                window.close()
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sets.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runs.json").path))
    }

    func testLegacyVideoDefaultsRemainExactUntilSettingsAreChanged() throws {
        let set = PromptSet(id: "legacy-video", name: "Legacy", useCase: nil,
            prompts: [PromptEntry(id: "p", text: "A forest")], origin: .userCreated, mode: .videoGeneration)
        var draft = try ComparisonPromptSetDraft(set: set)
        XCTAssertEqual(try draft.promptSet(), set)
        XCTAssertEqual(draft.prompts[0].width, "416")
        draft.prompts[0].steps = "9"
        XCTAssertEqual(try draft.promptSet().prompts[0].media,
            MediaParameters(width: 416, height: 240, steps: 9, seed: 42, frames: 17))
        var square = set; square.prompts[0].media = MediaParameters(size: 512, steps: 10)
        var squareEdit = try ComparisonPromptSetDraft(set: square)
        XCTAssertEqual(try squareEdit.promptSet(), square)
        squareEdit.prompts[0].width = ""
        XCTAssertEqual(try squareEdit.promptSet().prompts[0].media, MediaParameters(height: 512, steps: 10))
    }

    @MainActor
    func testOtherModeManagementRefusesActiveRunsAndSaveFailureCanRetry() async throws {
        let runner = StubMediaRunner(gated: true), coordinator = makeCoordinator(runner: runner)
        var draft = ComparisonPromptSetDraft(mode: .imageGeneration); draft.name = "Images"; draft.prompts[0].text = "Piano"
        let store = JSONStore<PromptSet>(fileURL: root.appendingPathComponent("sets.json"))
        let corrupt = Data("invalid".utf8); try corrupt.write(to: store.url)
        XCTAssertNil(coordinator.createPromptSet(draft))
        XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
        try FileManager.default.removeItem(at: store.url)
        let set = try XCTUnwrap(coordinator.createPromptSet(draft))
        XCTAssertNil(coordinator.promptSetManagementError)
        var edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: set.id)); edit.prompts[0].seed = "99"
        coordinator.start(variants: [("/image/a", nil)], promptSet: set)
        XCTAssertNil(coordinator.preparePromptSetEdit(id: set.id))
        XCTAssertFalse(coordinator.savePromptSetEdits(edit))
        XCTAssertFalse(coordinator.renamePromptSet(id: set.id, name: "Changed"))
        XCTAssertFalse(coordinator.removePromptSet(id: set.id))
        XCTAssertEqual(try store.load(), [set])
        await runner.release(1); await waitForRun(coordinator)
        XCTAssertTrue(coordinator.savePromptSetEdits(edit))
        XCTAssertNil(coordinator.promptSetManagementError)
        XCTAssertEqual(try store.load()[0].prompts[0].media?.seed, 99)
    }

    func testMusicDuplicationPreservesDraftAndAllRecordedMetadataWithNewIdentity() throws {
        let entry = PromptEntry(id: "original", text: "Piano", maxTokens: 77,
            tool: BuiltinPromptSets.toolCalling.prompts[0].tool, inputKind: .audio,
            inputPath: "/recorded/input.wav", builtinInput: "fixture", expectedKeywords: ["piano"],
            media: MediaParameters(size: 512, steps: 12, seed: 7, durationSeconds: 12.5, lyrics: "[instrumental]"),
            inputName: "Piano reference.wav")
        var prompts = [MusicComparisonSetup.Prompt(entry)]
        prompts[0].caption = "Rhodes and bass"; prompts[0].lyrics = "[verse]\nA new day"
        prompts[0].duration = "20"; prompts[0].steps = "8"; prompts[0].seed = "99"
        prompts.duplicatePrompt(id: entry.id)
        guard prompts.count == 2 else { XCTFail("Duplicate must insert a second music prompt"); return }
        XCTAssertNotEqual(prompts[1].id, entry.id)
        var expected = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(prompts[0].entry())) as? [String: Any])
        let copied = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(prompts[1].entry())) as? [String: Any])
        expected["id"] = prompts[1].id
        XCTAssertEqual(NSDictionary(dictionary: copied), NSDictionary(dictionary: expected))
        prompts[1].caption = "Strings"
        XCTAssertEqual(prompts[0].caption, "Rhodes and bass")
        prompts[1].duration = "unfinished"
        prompts.duplicatePrompt(id: prompts[1].id)
        XCTAssertEqual(prompts.last?.duration, "unfinished")
        XCTAssertThrowsError(try prompts.last?.entry(), "Duplicating must not bypass validation")
        XCTAssertEqual(entry.text, "Piano")
    }

    @MainActor
    func testMusicArrangementPersistsAcrossCreateEditReuseAndRunnerWithHistoryIntact() async throws {
        let runner = StubMediaRunner(), coordinator = makeCoordinator(runner: runner)
        var draft = MusicPromptSetDraft(); draft.name = "Music suite"
        draft.prompts[0].caption = "Piano"; draft.prompts[0].seed = "7"
        draft.addPrompt(); draft.prompts[1].caption = "Strings"; draft.prompts[1].seed = "99"
        let first = draft.prompts[0].id, second = draft.prompts[1].id
        draft.prompts.movePrompt(id: first, direction: .up)
        draft.prompts.movePrompt(id: second, direction: .down)
        draft.prompts.movePrompt(id: "missing", direction: .up)
        draft.prompts.duplicatePrompt(id: "missing")
        XCTAssertEqual(draft.prompts.map(\.id), [first, second])
        let original = try XCTUnwrap(coordinator.createMusicPromptSet(draft))
        coordinator.start(variants: [("/music/a", nil)], promptSet: original)
        await waitForRun(coordinator)
        let runID = try XCTUnwrap(coordinator.runs.first?.id)
        coordinator.reviewQuality(runID: runID, modelPath: "/music/a", score: 4)
        let historical = try XCTUnwrap(coordinator.runs.first)
        let historyURL = root.appendingPathComponent("runs.json"), history = try Data(contentsOf: historyURL)
        var edit = try XCTUnwrap(coordinator.prepareMusicPromptSetEdit(id: original.id))
        edit.prompts.duplicatePrompt(id: first)
        guard edit.prompts.count == 3 else { XCTFail("Music edit must allow duplication"); return }
        let duplicate = edit.prompts[1].id
        edit.prompts.movePrompt(id: second, direction: .up)
        edit.prompts.movePrompt(id: second, direction: .up)
        XCTAssertTrue(coordinator.saveMusicPromptSetEdits(edit))
        let saved = try XCTUnwrap(makeCoordinator(runner: runner).promptSets.first { $0.id == original.id })
        XCTAssertEqual(saved.prompts.map(\.id), [second, first, duplicate])
        XCTAssertEqual(try Data(contentsOf: historyURL), history)
        let beforeRun = await runner.requests
        XCTAssertEqual(beforeRun.count, 2, "Arranging and saving must not generate audio")
        coordinator.start(variants: [("/music/a", nil)], promptSet: saved)
        await waitForRun(coordinator)
        let requests = await runner.requests
        XCTAssertEqual(requests.suffix(3).map(\.entry.id), [second, first, duplicate])
        XCTAssertEqual(requests.suffix(3).map(\.entry.media?.seed), [99, 7, 7])
        XCTAssertEqual(coordinator.runs.first { $0.id == runID }, historical)
        var setup = try MusicComparisonSetup(run: historical)
        setup.prompts.duplicatePrompt(id: second)
        let reuseDuplicate = try XCTUnwrap(setup.prompts.last?.id)
        setup.prompts.movePrompt(id: reuseDuplicate, direction: .up)
        let reused = try setup.promptSet(named: "Rearranged reuse")
        XCTAssertEqual(reused.prompts.map(\.id), [first, reuseDuplicate, second])
        XCTAssertNotEqual(reused.id, original.id)
        XCTAssertEqual(coordinator.runs.first { $0.id == runID }, historical)
        var invalid = edit
        invalid.prompts = [edit.prompts[0], edit.prompts[0]]
        XCTAssertThrowsError(try invalid.updatedPromptSet())
        invalid.prompts = []
        XCTAssertThrowsError(try invalid.updatedPromptSet())
    }

    @MainActor
    func testMusicEditAndReuseAddRemovePreservesDefaultsHistoryAndIndependentInputs() async throws {
        let runner = StubMediaRunner(), coordinator = makeCoordinator(runner: runner)
        let original = PromptSet(id: "music-edit", name: "Instrumentals", useCase: .coding,
            prompts: [PromptEntry(id: "one", text: "Piano", media: MediaParameters(steps: 12, seed: 7, durationSeconds: 12.5, lyrics: "[instrumental]")),
                PromptEntry(id: "two", text: "Strings")], origin: .userCreated, mode: .musicGeneration)
        XCTAssertTrue(coordinator.savePromptSet(original))
        coordinator.start(variants: [("/music/a", nil)], promptSet: original)
        await waitForRun(coordinator)
        let runID = try XCTUnwrap(coordinator.runs.first?.id)
        coordinator.reviewQuality(runID: runID, modelPath: "/music/a", score: 4)
        let historical = try XCTUnwrap(coordinator.runs.first)
        let historyURL = root.appendingPathComponent("runs.json"), historyBytes = try Data(contentsOf: historyURL)
        let artifact = try XCTUnwrap(coordinator.outputStore?.artifactURL(runID: runID,
            artifact: try XCTUnwrap(historical.results.first?.samples.first?.artifact)))
        let audioBytes = try Data(contentsOf: artifact)
        var edit = try XCTUnwrap(coordinator.prepareMusicPromptSetEdit(id: original.id))
        edit.prompts.addPrompt()
        guard edit.prompts.count == 3 else { XCTFail("Saved music editor must add a prompt"); return }
        let newID = edit.prompts[2].id
        XCTAssertFalse(original.prompts.map(\.id).contains(newID))
        XCTAssertEqual(edit.prompts[2].caption, "")
        XCTAssertEqual(edit.prompts[2].lyrics, "[instrumental]")
        XCTAssertEqual(edit.prompts[2].duration, "15.0")
        XCTAssertEqual(edit.prompts[2].steps, "30")
        XCTAssertEqual(edit.prompts[2].seed, "42")
        XCTAssertNotNil(edit.validationError, "A blank new caption must keep saving disabled")
        edit.prompts[2].caption = "Rhodes and drums"
        edit.prompts.removePrompt(id: "two")
        XCTAssertTrue(coordinator.saveMusicPromptSetEdits(edit))
        let saved = try XCTUnwrap(makeCoordinator(runner: runner).promptSets.first { $0.id == original.id })
        XCTAssertEqual(saved.prompts.map(\.id), ["one", newID])
        XCTAssertEqual(saved.prompts[0], original.prompts[0])
        XCTAssertEqual(saved.prompts[1].media, MediaParameters(steps: 30, seed: 42, durationSeconds: 15, lyrics: "[instrumental]"))
        XCTAssertEqual(saved.useCase, original.useCase)
        XCTAssertEqual(try Data(contentsOf: historyURL), historyBytes)
        XCTAssertEqual(try Data(contentsOf: artifact), audioBytes)
        let savedBytes = try Data(contentsOf: root.appendingPathComponent("sets.json"))
        var setup = try MusicComparisonSetup(run: historical)
        setup.prompts.removePrompt(id: "two")
        setup.prompts.addPrompt()
        guard setup.prompts.count == 2 else { XCTFail("Reuse must support replacing a prompt"); return }
        setup.prompts[1].caption = "Acoustic guitar"
        let reused = try setup.promptSet(named: "New suite")
        XCTAssertEqual(reused.prompts[0], original.prompts[0])
        XCTAssertEqual(reused.prompts[1].media, saved.prompts[1].media)
        XCTAssertNotEqual(reused.prompts[1].id, newID)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("sets.json")), savedBytes)
        XCTAssertEqual(coordinator.runs.first { $0.id == runID }, historical)
        let requests = await runner.requests
        XCTAssertEqual(requests.count, 2, "Draft changes and saving must not generate audio")
        setup.prompts.removePrompt(id: setup.prompts[1].id)
        setup.prompts.removePrompt(id: "one")
        setup.prompts.removePrompt(id: "missing")
        XCTAssertEqual(setup.prompts.map(\.id), ["one"])
        XCTAssertNil(setup.validationError)
    }

    func testReusedMusicSetupRejectsInvalidPromptIdentitiesAfterDraftChanges() throws {
        var run = historyRun(.musicGeneration, "Music", at: 100, models: ["/music/a"])
        run.promptEntries = [PromptEntry(id: "one", text: "Piano")]
        var setup = try MusicComparisonSetup(run: run)
        setup.prompts.append(setup.prompts[0])
        XCTAssertNotNil(setup.validationError)
        XCTAssertThrowsError(try setup.promptSet())
        setup.prompts = [MusicComparisonSetup.Prompt(PromptEntry(id: "", text: "Strings"))]
        XCTAssertNotNil(setup.validationError)
        XCTAssertThrowsError(try setup.promptSet())
    }

    @MainActor
    func testCustomizingBuiltinPromptSetsPreservesSettingsAndCreatesIndependentSetsInEveryMode() async throws {
        let runner = StubMediaRunner(), coordinator = makeCoordinator(runner: runner)
        for mode in ComparisonMode.allCases {
            var source: PromptSet
            if mode == .chat { source = BuiltinPromptSets.toolCalling }
            else { source = try XCTUnwrap(ComparisonMediaFixtures.all.first { $0.effectiveMode == mode }) }
            if mode == .musicGeneration { source.useCase = .coding }
            XCTAssertEqual(source.origin, .builtin)
            let saved: PromptSet
            if mode == .musicGeneration {
                let draft = try MusicPromptSetDraft(copying: source)
                saved = try XCTUnwrap(coordinator.createMusicPromptSet(draft))
            } else {
                let draft = try ComparisonPromptSetDraft(copying: source)
                XCTAssertNil(draft.original)
                let created = await coordinator.createPromptSetWithInputCopies(draft)
                saved = try XCTUnwrap(created)
            }
            XCTAssertNotEqual(saved.id, source.id)
            XCTAssertEqual(saved.name, "\(source.name) copy")
            XCTAssertEqual(saved.prompts, source.prompts)
            XCTAssertEqual(saved.useCase, source.useCase)
            XCTAssertEqual(saved.effectiveMode, mode)
            XCTAssertEqual(saved.origin, .userCreated)
            XCTAssertTrue(coordinator.canManagePromptSet(id: saved.id))
            XCTAssertFalse(coordinator.canManagePromptSet(id: source.id))
            XCTAssertEqual(makeCoordinator(runner: runner).promptSets.first { $0.id == saved.id }, saved)
        }
        XCTAssertTrue(coordinator.runs.isEmpty)
        let requests = await runner.requests
        XCTAssertTrue(requests.isEmpty, "Copying or saving presets must not generate")
        let malformed = PromptSet(id: "invalid", name: "Invalid", useCase: nil,
            prompts: [PromptEntry(id: "p", text: "One"), PromptEntry(id: "p", text: "Two")], origin: .userCreated)
        XCTAssertThrowsError(try ComparisonPromptSetDraft(copying: malformed))
        var music = malformed; music.mode = .musicGeneration
        XCTAssertThrowsError(try MusicPromptSetDraft(copying: music))
        music.prompts = []
        XCTAssertThrowsError(try MusicPromptSetDraft(copying: music))
        XCTAssertThrowsError(try ComparisonPromptSetDraft(copying: promptSet(for: .musicGeneration)))
        XCTAssertThrowsError(try MusicPromptSetDraft(copying: BuiltinPromptSets.coding))
    }

    @MainActor
    func testCopiedSavedPromptSetOwnsInputsAndSurvivesRemovingItsSource() async throws {
        let runner = StubMediaRunner(), coordinator = makeCoordinator(runner: runner)
        let input = root.appendingPathComponent("Bird reference.png")
        try Data("reference input".utf8).write(to: input)
        var draft = ComparisonPromptSetDraft(mode: .vision)
        draft.name = "Bird suite"; draft.prompts[0].text = "Describe this bird"
        draft.prompts[0].inputPath = input.path
        let created = await coordinator.createPromptSetWithInputCopies(draft)
        let source = try XCTUnwrap(created)
        let setsURL = root.appendingPathComponent("sets.json"), before = try Data(contentsOf: setsURL)
        var copy = try ComparisonPromptSetDraft(copying: source)
        XCTAssertEqual(try Data(contentsOf: setsURL), before, "Opening a copy must not write")
        copy.prompts[0].text = "What color is the bird?"
        let savedCopy = await coordinator.createPromptSetWithInputCopies(copy)
        let saved = try XCTUnwrap(savedCopy)
        XCTAssertEqual(saved.prompts.count, 1)
        XCTAssertEqual(saved.prompts.first?.inputDisplayName, "Bird reference.png")
        XCTAssertNotEqual(saved.inputStorageID, source.inputStorageID)
        let copiedPath = try XCTUnwrap(saved.prompts.first?.inputPath)
        XCTAssertNotEqual(copiedPath, source.prompts[0].inputPath)
        XCTAssertEqual(coordinator.promptSets.first { $0.id == source.id }, source)
        XCTAssertTrue(coordinator.removePromptSet(id: source.id))
        try FileManager.default.removeItem(at: input)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copiedPath)), Data("reference input".utf8))
        XCTAssertEqual(makeCoordinator(runner: runner).promptSets.first { $0.id == saved.id }, saved)
        let requests = await runner.requests
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testBuiltinCopyEditorsRenderRecordedSettingsWithoutSaving() async throws {
        for mode in [ComparisonMode.chat, .musicGeneration] {
            let content: AnyView
            if mode == .chat {
                content = AnyView(ComparisonPromptSetEditor(draft: try ComparisonPromptSetDraft(copying: BuiltinPromptSets.toolCalling)) { _ in
                    XCTFail("Opening a preset copy must not save or run"); return nil
                })
            } else {
                content = AnyView(MusicPromptSetCreateSheet(draft: try MusicPromptSetDraft(copying: promptSet(for: mode))) { _ in
                    XCTFail("Opening a music preset copy must not save or generate"); return nil
                })
            }
            let host = NSHostingView(rootView: content.background(WorkbenchColor.canvas).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Customize \(mode.title) preset"; attachment.lifetime = .keepAlways; add(attachment)
            if let path = ProcessInfo.processInfo.environment["MLX_PROMPT_COPY_PROOF_DIR"] {
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("\(mode.rawValue).png"))
            }
            window.close()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sets.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runs.json").path))
    }

    func testPromptSetPickerGroupsByProvenanceAndSearchesNamesPromptsAndTools() throws {
        let builtin = BuiltinPromptSets.toolCalling
        let saved = PromptSet(id: "saved", name: "My workflow", useCase: builtin.useCase,
            prompts: builtin.prompts, origin: .userCreated)
        let temporary = PromptSet(id: "temporary", name: "Reused suite", useCase: nil,
            prompts: [PromptEntry(id: "p", text: "Review a billing ticket")], origin: .userCreated)
        let inputs = [builtin, saved, temporary]
        let groups = ComparisonPromptSetPickerLogic.groups(inputs, temporaryID: temporary.id, query: " \n ")
        XCTAssertEqual(groups.map(\.section), [.temporary, .saved, .builtin])
        XCTAssertEqual(groups.map { $0.sets.map(\.name) }, [[temporary.name], [saved.name], [builtin.name]])
        XCTAssertEqual(ComparisonPromptSetPickerLogic.groups(inputs, temporaryID: temporary.id, query: "my WORKFLOW").flatMap(\.sets), [saved])
        XCTAssertEqual(ComparisonPromptSetPickerLogic.groups(inputs, temporaryID: temporary.id, query: "billing").flatMap(\.sets), [temporary])
        XCTAssertEqual(ComparisonPromptSetPickerLogic.groups([builtin], temporaryID: nil, query: "get_current_weather").flatMap(\.sets), [builtin])
        XCTAssertTrue(ComparisonPromptSetPickerLogic.groups(inputs, temporaryID: nil, query: "no match").isEmpty)
        XCTAssertTrue(ComparisonPromptSetPickerLogic.groups([], temporaryID: nil, query: "").isEmpty)
        XCTAssertEqual(ComparisonPromptSetPickerLogic.promptCount(temporary), "1 prompt")
        XCTAssertEqual(ComparisonPromptSetPickerLogic.promptCount(builtin), "\(builtin.prompts.count) prompts")
    }

    func testPromptSetPickerKeepsDuplicateNamesDistinctAndPreservesSourceOrder() {
        let first = PromptSet(id: "first", name: "Same name", useCase: nil,
            prompts: [PromptEntry(id: "p", text: "First")], origin: .userCreated)
        let second = PromptSet(id: "second", name: "Same name", useCase: nil,
            prompts: [PromptEntry(id: "p", text: "Second")], origin: .userCreated)
        let groups = ComparisonPromptSetPickerLogic.groups([second, first], temporaryID: nil, query: "Same")
        XCTAssertEqual(groups.flatMap(\.sets).map(\.id), ["second", "first"])
        XCTAssertEqual(groups.map(\.section), [.saved])
        XCTAssertEqual(ComparisonPromptSetPickerLogic.groups([first], temporaryID: "missing", query: "").map(\.section), [.saved])
        XCTAssertEqual(first.prompts[0].text, "First")
    }

    @MainActor
    func testPromptSetPickerRendersGroupsAndSearchStatesWithoutSelectingOrWriting() async throws {
        let saved = PromptSet(id: "saved", name: "Coding workflow · my prompts", useCase: .coding,
            prompts: BuiltinPromptSets.coding.prompts, origin: .userCreated)
        let temporary = PromptSet(id: "temporary", name: "Reused tool-calling setup", useCase: nil,
            prompts: BuiltinPromptSets.toolCalling.prompts, origin: .userCreated)
        let sets = [temporary, saved] + BuiltinPromptSets.all
        for query in ["", "my prompts", "nothing matches"] {
            let content = ComparisonPromptSetPanel(sets: sets, selection: saved.id, temporaryID: temporary.id,
                onSelect: { _ in XCTFail("Rendering or searching must not select a set or run") }, query: query)
            let host = NSHostingView(rootView: content.background(WorkbenchColor.canvas).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 470),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let label = query.isEmpty ? "groups" : query == "my prompts" ? "filtered" : "empty"
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Prompt set picker · \(label)"; attachment.lifetime = .keepAlways; add(attachment)
            if let path = ProcessInfo.processInfo.environment["MLX_PROMPT_PICKER_PROOF_DIR"] {
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("\(label).png"))
            }
            window.close()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sets.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runs.json").path))
    }

    @MainActor
    func testNewMusicPromptSetPersistsIndependentSettingsWithoutGenerating() async throws {
        let runner = StubMediaRunner(), coordinator = makeCoordinator(runner: runner)
        var draft = MusicPromptSetDraft()
        draft.name = "  Instrumental contrasts  "
        draft.prompts[0].caption = "Rhodes, bass and drums"
        draft.prompts[0].duration = "12.5"; draft.prompts[0].steps = "8"; draft.prompts[0].seed = "7"
        draft.addPrompt()
        draft.prompts[1].caption = "Acoustic guitar and strings"
        draft.prompts[1].lyrics = "[verse]\nA new day"
        draft.prompts[1].duration = "20"; draft.prompts[1].steps = "12"; draft.prompts[1].seed = "99"
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sets.json").path))
        let saved = try draft.promptSet()
        XCTAssertEqual(saved.name, "Instrumental contrasts")
        XCTAssertEqual(saved.origin, .userCreated); XCTAssertEqual(saved.effectiveMode, .musicGeneration)
        XCTAssertEqual(saved.prompts[0].text, "Rhodes, bass and drums")
        XCTAssertEqual(saved.prompts[0].media, MediaParameters(steps: 8, seed: 7, durationSeconds: 12.5, lyrics: "[instrumental]"))
        XCTAssertEqual(saved.prompts[1].media, MediaParameters(steps: 12, seed: 99, durationSeconds: 20, lyrics: "[verse]\nA new day"))
        XCTAssertNotEqual(saved.prompts[0].id, saved.prompts[1].id)
        XCTAssertEqual(coordinator.createMusicPromptSet(draft), saved)
        let loaded = makeCoordinator(runner: runner)
        XCTAssertEqual(loaded.promptSets.first { $0.id == saved.id }, saved)
        XCTAssertTrue(coordinator.runs.isEmpty); XCTAssertNil(coordinator.activeRunID)
        let requests = await runner.requests
        XCTAssertTrue(requests.isEmpty, "Creating a saved set must not generate audio")
    }

    func testNewMusicPromptSetRemovalKeepsSurvivingSettingsAndOnePromptMinimum() throws {
        var draft = MusicPromptSetDraft(); draft.name = "Piano"
        draft.prompts[0].caption = "Solo piano"
        let firstID = draft.prompts[0].id
        draft.addPrompt(); let secondID = draft.prompts[1].id
        draft.prompts[1].caption = "Strings"; draft.prompts[1].seed = "123"
        draft.removePrompt(id: firstID)
        XCTAssertEqual(try draft.promptSet().prompts.map(\.id), [secondID])
        XCTAssertEqual(try draft.promptSet().prompts[0].media?.seed, 123)
        draft.removePrompt(id: secondID)
        XCTAssertEqual(draft.prompts.count, 1)
        draft.prompts = []
        XCTAssertThrowsError(try draft.promptSet())
    }

    func testNewMusicPromptSetUsesSharedValidationAndOptionalDefaults() throws {
        var draft = MusicPromptSetDraft(); draft.name = "Piano"; draft.prompts[0].caption = "Solo piano"
        for name in ["", " \n ", "Name\u{0}"] {
            var invalid = draft; invalid.name = name
            XCTAssertThrowsError(try invalid.promptSet())
        }
        let invalidFields: [(WritableKeyPath<MusicComparisonSetup.Prompt, String>, String)] = [
                               (\.duration, "nan"), (\.duration, "361"),
                               (\.steps, "31"), (\.steps, "0"), (\.seed, "-1"), (\.seed, "4294967296"),
                               (\.caption, " \n "), (\.lyrics, " \n ")]
        for (field, value) in invalidFields {
            var invalid = draft; invalid.prompts[0][keyPath: field] = value
            XCTAssertThrowsError(try invalid.promptSet())
        }
        draft.prompts[0].duration = ""; draft.prompts[0].steps = ""; draft.prompts[0].seed = ""; draft.prompts[0].lyrics = ""
        let saved = try draft.promptSet()
        XCTAssertEqual(saved.prompts[0].media, MediaParameters())
    }

    @MainActor
    func testNewMusicPromptSetFailedSaveCanRetryWithoutLosingDraft() throws {
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let url = root.appendingPathComponent("sets.json"), corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)
        var draft = MusicPromptSetDraft(); draft.name = "Piano"; draft.prompts[0].caption = "Solo piano"
        draft.prompts[0].seed = "77"
        let saved = try draft.promptSet(), before = coordinator.promptSets
        XCTAssertNil(coordinator.createMusicPromptSet(draft))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertEqual(coordinator.promptSets, before)
        try FileManager.default.removeItem(at: url)
        XCTAssertNotNil(coordinator.promptSetManagementError)
        XCTAssertEqual(coordinator.createMusicPromptSet(draft), saved)
        XCTAssertNil(coordinator.promptSetManagementError)
        XCTAssertEqual(try JSONStore<PromptSet>(fileURL: url).load(), [saved])
        XCTAssertNil(coordinator.createMusicPromptSet(draft), "A repeated save cannot overwrite an existing set")
        XCTAssertEqual(try JSONStore<PromptSet>(fileURL: url).load(), [saved])
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
    func testNewMusicPromptSetSheetRendersIndependentSettingsWithoutSaving() async throws {
        var draft = MusicPromptSetDraft(); draft.name = "Instrumental contrasts"
        draft.prompts[0].caption = "Jazz-funk with Rhodes, bass and drums"
        draft.prompts[0].duration = "12.5"; draft.prompts[0].steps = "8"; draft.prompts[0].seed = "7"
        draft.addPrompt(); draft.prompts[1].caption = "Acoustic guitar and strings"
        draft.prompts[1].duration = "20"; draft.prompts[1].steps = "12"; draft.prompts[1].seed = "99"
        let content = MusicPromptSetCreateSheet(draft: draft) { _ in
            XCTFail("Rendering must not save a set"); return nil
        }.background(WorkbenchColor.canvas).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 580),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "New music prompt set"; attachment.lifetime = .keepAlways; add(attachment)
        if let path = ProcessInfo.processInfo.environment["MLX_MUSIC_CREATE_PROOF_PATH"] {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor
    func testPromptInputPreviewsRenderRealMediaWithoutAutoplay() async throws {
        let entries: [(ComparisonMediaKind, PromptEntry)] = [
            (.image, PromptEntry(id: "image", text: "Describe the red circle", inputKind: .image, builtinInput: "red-circle")),
            (.audio, PromptEntry(id: "audio", text: "The red bird landed on the branch.", inputKind: .audio, builtinInput: "speech")),
            (.video, PromptEntry(id: "video", text: "Describe the motion", inputKind: .video, builtinInput: "red-square-right"))
        ]
        func players(in view: NSView) -> [AVPlayerView] {
            (view as? AVPlayerView).map { [$0] } ?? view.subviews.flatMap { players(in: $0) }
        }
        var audioLoads = 0
        let audio = AudioClipPlayer { _ in audioLoads += 1; return StubAudioPlayback() }
        for (kind, entry) in entries {
            let url = try await ComparisonMediaFixtures.generateInput(for: entry, into: root)
            for expanded in [false, true] {
                let content = ComparisonPromptInputPreview(url: url, kind: kind, audio: audio, expanded: expanded)
                    .padding(WorkbenchSpacing.md).background(WorkbenchColor.canvas).preferredColorScheme(.dark)
                let host = NSHostingView(rootView: AnyView(content))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 240),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(250))
                host.layoutSubtreeIfNeeded()
                let videoViews = players(in: host)
                XCTAssertEqual(videoViews.count, kind == .video && expanded ? 1 : 0)
                XCTAssertTrue(videoViews.allSatisfy { $0.player?.rate == 0 }, "Preview must never autoplay")
                XCTAssertEqual(audioLoads, 0)
                XCTAssertNil(audio.activeURL)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "Input \(kind.rawValue) preview · \(expanded ? "expanded" : "collapsed")"
                attachment.lifetime = .keepAlways; add(attachment)
                if let directory = ProcessInfo.processInfo.environment["MLX_PROMPT_INPUT_PROOF_DIR"] {
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(kind.rawValue)-\(expanded).png"))
                }
                host.rootView = AnyView(EmptyView())
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertTrue(videoViews.allSatisfy { $0.player?.rate == 0 })
                window.close()
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sets.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runs.json").path))
    }

    @MainActor
    func testPromptInputPreviewStopsAudioOnReplacementAndRemoval() async throws {
        let fixture = PromptPreviewFixture(url: root.appendingPathComponent("first.wav"))
        let playback = StubAudioPlayback()
        var audioLoads = 0
        let audio = AudioClipPlayer { _ in audioLoads += 1; return playback }
        let host = NSHostingView(rootView: AnyView(PromptPreviewFixtureView(fixture: fixture, audio: audio)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(audioLoads, 0)
        audio.toggle(fixture.url)
        XCTAssertTrue(playback.isPlaying)
        fixture.url = root.appendingPathComponent("replacement.wav")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(playback.isPlaying)
        XCTAssertNil(audio.activeURL)
        audio.toggle(fixture.url)
        XCTAssertTrue(playback.isPlaying)
        host.rootView = AnyView(EmptyView())
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(playback.isPlaying)
        XCTAssertNil(audio.activeURL)
        window.close()
    }

    @MainActor
    func testOtherModePromptEditorsRenderWithoutWritingOrRunning() async throws {
        for mode in ComparisonMode.allCases where mode != .musicGeneration {
            var draft = ComparisonPromptSetDraft(mode: mode)
            draft.name = "\(mode.title) comparison"
            draft.prompts[0].text = mode == .speechToText ? "The red bird landed on the branch." : "Describe a red bird in a snowy forest."
            if let kind = mode.inputKind {
                draft.prompts[0].inputPath = root.appendingPathComponent("reference.\(kind == .image ? "png" : kind == .video ? "mp4" : "wav")").path
            }
            if mode == .vision || mode == .videoUnderstanding { draft.prompts[0].keywords = "red, bird" }
            let content = ComparisonPromptSetEditor(draft: draft) { _ in
                XCTFail("Rendering must not save or run a comparison"); return nil
            }.background(WorkbenchColor.canvas).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 580),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "\(mode.title) prompt editor"; attachment.lifetime = .keepAlways; add(attachment)
            if let directory = ProcessInfo.processInfo.environment["MLX_PROMPT_PARITY_PROOF_DIR"] {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(mode.rawValue).png"))
            }
            window.close()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sets.json").path))
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
    func testRenameSheetShowsValidationWhileEditingWithoutSaving() async throws {
        func fields(in view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField, field.isEditable { return [field] }
            return view.subviews.flatMap { fields(in: $0) }
        }
        for mode in [ComparisonMode.chat, .musicGeneration] {
            let set = PromptSet(id: "saved", name: "Studies", useCase: nil,
                prompts: [PromptEntry(id: "p", text: "A prompt")], origin: .userCreated, mode: mode)
            let content = PromptSetRenameSheet(set: set) { _ in
                XCTFail("Editing must not save a rename"); return nil
            }.background(WorkbenchColor.canvas).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let initialHeight = host.fittingSize.height
            let field = try XCTUnwrap(fields(in: host).first)
            for (name, state) in [("", "invalid"), ("New valid name", "valid")] {
                field.stringValue = name
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded()
                if state == "invalid" {
                    XCTAssertGreaterThan(host.fittingSize.height, initialHeight, "Invalid names reveal inline validation")
                } else {
                    XCTAssertEqual(host.fittingSize.height, initialHeight, accuracy: 1, "Valid names clear the warning")
                }
                window.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "Rename \(mode.rawValue) \(state)"; attachment.lifetime = .keepAlways; add(attachment)
                if let directory = ProcessInfo.processInfo.environment["MLX_RENAME_PROOF_DIR"] {
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(mode.rawValue)-\(state).png"))
                }
            }
        }
    }

    @MainActor
    func testNewSetNameFeedbackAppearsAfterClearingEditedNameInEveryMode() async throws {
        func fields(in view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField, field.isEditable { return [field] }
            return view.subviews.flatMap { fields(in: $0) }
        }
        for mode in ComparisonMode.allCases {
            let editor: AnyView
            if mode == .musicGeneration {
                editor = AnyView(MusicPromptSetCreateSheet { _ in
                    XCTFail("Editing a name must not save or generate"); return nil
                })
            } else {
                editor = AnyView(ComparisonPromptSetEditor(draft: ComparisonPromptSetDraft(mode: mode)) { _ in
                    XCTFail("Editing a name must not save or run a comparison"); return nil
                })
            }
            let host = NSHostingView(rootView: editor.background(WorkbenchColor.canvas).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let initialHeight = host.fittingSize.height
            let field = try XCTUnwrap(fields(in: host).first)
            XCTAssertEqual(field.stringValue, "")
            for (name, state) in [("Studies", "valid"), ("", "cleared"), ("Études 🎹", "corrected")] {
                field.stringValue = name
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                if state == "cleared" {
                    XCTAssertGreaterThan(host.fittingSize.height, initialHeight, "\(mode): edited blank names need feedback")
                } else {
                    XCTAssertEqual(host.fittingSize.height, initialHeight, accuracy: 1, "\(mode): valid names clear feedback")
                }
                if state == "cleared", let directory = ProcessInfo.processInfo.environment["MLX_NAME_FIELD_PROOF_DIR"] {
                    window.setContentSize(host.fittingSize); host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(mode.rawValue)-cleared.png"))
                }
            }
        }
    }

    func testRenameDraftValidationAndDiscardTrackingApplyToEveryMode() {
        for mode in ComparisonMode.allCases {
            let original = PromptSet(id: "saved", name: "Studies", useCase: .coding,
                prompts: [PromptEntry(id: "p", text: "A prompt")], origin: .userCreated, mode: mode)
            var draft = PromptSetRenameDraft(set: original)
            XCTAssertFalse(draft.hasChanges)
            XCTAssertFalse(draft.canRename, "Opening must not submit an unchanged name")
            draft.name = "  Studies  "
            XCTAssertTrue(draft.hasChanges, "Cancellation still tracks raw edits")
            XCTAssertFalse(draft.canRename, "Whitespace alone must not cause a redundant write")
            for invalid in ["", " \n ", "A\u{0000}B", "A\nB"] {
                draft.name = invalid
                XCTAssertTrue(draft.hasChanges)
                XCTAssertNotNil(draft.validationError)
                XCTAssertFalse(draft.canRename)
            }
            draft.name = "  Études 🎹  "
            XCTAssertTrue(draft.hasChanges)
            XCTAssertNil(draft.validationError)
            XCTAssertTrue(draft.canRename)
            XCTAssertEqual(draft.normalizedName, "Études 🎹")
            XCTAssertEqual(draft.original, original, "Draft editing must preserve identity, prompts and metadata")
            draft.name = "Studies"
            XCTAssertFalse(draft.hasChanges)
            XCTAssertFalse(draft.canRename)
        }
    }

    @MainActor
    func testTaskQualityRatingsRenderWithOutputsWithoutSaving() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("rating-proof"))
        for mode in [ComparisonMode.chat, .imageGeneration] {
            var run = historyRun(mode, "Bird comparison", at: 100, models: ["/model/a", "/model/b"])
            run.promptEntries = [PromptEntry(id: "p", text: "A red bird resting on a snowy branch")]
            if mode == .imageGeneration {
                let directory = try store.createRunDirectory(run.id)
                let image = try await ComparisonMediaFixtures.generateInput(
                    for: PromptEntry(id: "fixture", text: "", builtinInput: "red-circle"), into: directory)
                try FileManager.default.copyItem(at: image, to: directory.appendingPathComponent("a.png"))
                try FileManager.default.copyItem(at: image, to: directory.appendingPathComponent("b.png"))
            }
            run.results = ["a", "b"].enumerated().map { index, key in
                VariantResult(modelPath: "/model/\(key)", modelSignature: "measured", samples: [
                    ComparisonSample(promptID: "p", outputExcerpt: index == 0 ? "A red bird on a snowy branch." : "A bird on a branch.",
                        tokensPerSecond: index == 0 ? 20 : 40, timeToFirstTokenSeconds: 0.3, error: nil,
                        artifact: "\(key).png", secondsPerStep: index == 0 ? 1.8 : 0.9)],
                    aggregateTokensPerSecond: index == 0 ? 20 : 40, aggregateTTFTSeconds: 0.3,
                    error: nil, aggregateMetric: index == 0 ? 1.8 : 0.9)
            }
            run.qualityReviews = ["/model/a": ComparisonQualityReview(score: 5, rubricID: "task-outcome-v1", reviewedAt: Date())]
            let view = MediaRunResultsView(run: run, store: store, contentWidth: 940, isRouteActive: true,
                name: { $0 == "/model/a" ? "Model A · 8-bit" : "Model B · 4-bit" },
                onReview: { _, _ in XCTFail("Rendering must not write a quality rating") }, laneActions: { _ in EmptyView() })
                .padding(WorkbenchSpacing.pageInset).frame(width: 988, height: 620)
                .background(WorkbenchColor.canvas).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 988, height: 620),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "\(mode.title) · task quality ratings"; attachment.lifetime = .keepAlways; add(attachment)
            if let directory = ProcessInfo.processInfo.environment["MLX_QUALITY_RATINGS_PROOF_DIR"] {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("ratings-\(mode.rawValue).png"))
            }
            window.close()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runs.json").path))
    }

    func testTaskQualityReviewRequiresCompleteInspectableOutputs() throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("quality-outputs"))
        var run = historyRun(.vision, "Vision", at: 100)
        run.promptEntries = [PromptEntry(id: "p", text: "Describe it")]
        let sample = ComparisonSample(promptID: "p", outputExcerpt: "A red bird", tokensPerSecond: nil,
            timeToFirstTokenSeconds: nil, error: nil)
        run.results = [VariantResult(modelPath: "/model", modelSignature: nil, samples: [sample],
            aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil)]
        XCTAssertNil(ComparisonViewLogic.qualityReviewUnavailableReason(run, modelPath: "/model", store: store))
        XCTAssertNotNil(ComparisonViewLogic.qualityReviewUnavailableReason(run, modelPath: "/absent", store: store))
        run.state = .running
        XCTAssertNotNil(ComparisonViewLogic.qualityReviewUnavailableReason(run, modelPath: "/model", store: store))
        run.state = .completed; run.promptEntries?.append(PromptEntry(id: "missing", text: "Another question"))
        XCTAssertNotNil(ComparisonViewLogic.qualityReviewUnavailableReason(run, modelPath: "/model", store: store))
        run.promptEntries = [PromptEntry(id: "p", text: "Describe it")]
        let failed = ComparisonSample(promptID: "p", outputExcerpt: "", tokensPerSecond: nil,
            timeToFirstTokenSeconds: nil, error: "Generation failed")
        run.results = [VariantResult(modelPath: "/model", modelSignature: nil, samples: [failed],
            aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil)]
        XCTAssertNotNil(ComparisonViewLogic.qualityReviewUnavailableReason(run, modelPath: "/model", store: store))
        let fileSample = ComparisonSample(promptID: "p", outputExcerpt: "", tokensPerSecond: nil,
            timeToFirstTokenSeconds: nil, error: nil, artifact: "output.png")
        run.results = [VariantResult(modelPath: "/model", modelSignature: nil, samples: [fileSample],
            aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil)]
        for mode in [ComparisonMode.imageGeneration, .videoGeneration, .textToSpeech] {
            run.mode = mode
            XCTAssertNotNil(ComparisonViewLogic.qualityReviewUnavailableReason(run, modelPath: "/model", store: store))
        }
        let output = try store.createRunDirectory(run.id).appendingPathComponent("output.png")
        try Data("output".utf8).write(to: output)
        XCTAssertNil(ComparisonViewLogic.qualityReviewUnavailableReason(run, modelPath: "/model", store: store))
        try FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        XCTAssertNotNil(ComparisonViewLogic.qualityReviewUnavailableReason(run, modelPath: "/model", store: store))
    }

    @MainActor
    func testTaskQualityRatingsPersistClearAndDoNotChangeMeasuredOutputs() throws {
        for mode in ComparisonMode.allCases where mode != .musicGeneration {
            let runsURL = root.appendingPathComponent("quality-\(mode.rawValue).json")
            var run = historyRun(mode, "Quality", at: 100)
            run.promptEntries = [PromptEntry(id: "p", text: "Task")]
            run.results = [VariantResult(modelPath: "/model", modelSignature: "measured", samples: [
                ComparisonSample(promptID: "p", outputExcerpt: "Saved answer", tokensPerSecond: 20,
                    timeToFirstTokenSeconds: 0.3, error: nil, artifact: "output.png")],
                aggregateTokensPerSecond: 20, aggregateTTFTSeconds: 0.3, error: nil)]
            try JSONStore<ComparisonRun>(fileURL: runsURL).replaceAll([run])
            let coordinator = makeCoordinator(runner: StubMediaRunner(), runsURL: runsURL)
            coordinator.reviewQuality(runID: run.id, modelPath: "/model", score: 4)
            let reloaded = makeCoordinator(runner: StubMediaRunner(), runsURL: runsURL)
            let saved = try XCTUnwrap(reloaded.runs.first)
            XCTAssertEqual(saved.qualityReviews?["/model"]?.score, 4)
            XCTAssertEqual(saved.qualityReviews?["/model"]?.rubricID, "task-outcome-v1")
            XCTAssertEqual(saved.results, run.results)
            XCTAssertEqual(saved.promptEntries, run.promptEntries)
            reloaded.reviewQuality(runID: run.id, modelPath: "/model", score: nil)
            XCTAssertNil(try JSONStore<ComparisonRun>(fileURL: runsURL).load().first?.qualityReviews?["/model"])
            XCTAssertNil(reloaded.activeRunID)
        }
    }

    @MainActor
    func testTaskQualityRatingWriteFailureRetainsPublishedReview() throws {
        var run = historyRun(.vision, "Quality", at: 100)
        run.promptEntries = [PromptEntry(id: "p", text: "Task")]
        run.results = [VariantResult(modelPath: "/model", modelSignature: nil, samples: [],
            aggregateTokensPerSecond: nil, aggregateTTFTSeconds: nil, error: nil)]
        run.qualityReviews = ["/model": ComparisonQualityReview(score: 4, rubricID: "task-outcome-v1", reviewedAt: Date())]
        let url = root.appendingPathComponent("runs.json")
        try JSONStore<ComparisonRun>(fileURL: url).replaceAll([run])
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let corrupt = Data("broken-json".utf8); try corrupt.write(to: url)
        coordinator.reviewQuality(runID: run.id, modelPath: "/model", score: 1)
        XCTAssertEqual(coordinator.runs.first, run)
        XCTAssertNotNil(coordinator.persistenceError)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        try JSONStore<ComparisonRun>(fileURL: url).replaceAll([run])
        coordinator.reviewQuality(runID: run.id, modelPath: "/model", score: 3)
        XCTAssertEqual(coordinator.runs.first?.qualityReviews?["/model"]?.score, 3)
        XCTAssertNil(coordinator.persistenceError)
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
