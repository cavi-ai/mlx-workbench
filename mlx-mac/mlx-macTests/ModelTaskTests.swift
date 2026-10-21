import XCTest
import AppKit
import SwiftUI

@testable import mlx_workbench

final class ModelTaskTests: XCTestCase {
    func testUnknownTypeDecodesAsOther() throws {
        let data = Data(#"{"type":"quantum_llm","use_cases":[],"source":"name","confidence":"likely"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ModelTask.self, from: data).type, .other)
    }

    func testDictionaryInitAndPrimaryUseCase() {
        let task = ModelTask(dictionary: ["type": "speech_to_text", "use_cases": ["realtime_transcription", "transcription"], "source": "pipeline_tag", "confidence": "confirmed"])
        XCTAssertEqual(task?.type, .speechToText)
        XCTAssertEqual(task?.primaryUseCase, "realtime_transcription")
        XCTAssertNil(ModelTask(dictionary: nil))
        XCTAssertNil(ModelTask(dictionary: ["use_cases": []]))
    }

    func testCanaryAndServability() {
        XCTAssertTrue(ModelTaskType.textLLM.hasCanary)
        XCTAssertTrue(ModelTaskType.visionLanguage.isServable)
        XCTAssertTrue(ModelTaskType.speechToText.hasCanary)
        XCTAssertFalse(ModelTaskType.speechToText.isServable)
        XCTAssertFalse(ModelTaskType.textToSpeech.hasCanary)
        XCTAssertFalse(ModelTaskType.textToSpeech.isServable)
        XCTAssertTrue(ModelTaskType.classification.hasCanary)
        XCTAssertTrue(ModelTaskType.imageGeneration.hasCanary)
        XCTAssertFalse(ModelTaskType.imageGeneration.isServable)
        XCTAssertFalse(ModelTaskType.classification.isServable)
        XCTAssertFalse(ModelTaskType.speculativeDraft.hasCanary)
        XCTAssertFalse(ModelTaskType.speculativeDraft.isServable)
        XCTAssertEqual(ModelTaskType.speculativeDraft.title, "Speculative drafter")
        XCTAssertEqual(ModelTaskPresentation.useCaseTitle("speculative_decoding"), "Speculative decoding")
        XCTAssertEqual(ModelTaskPresentation.capabilities(for: ModelTask(type: .speculativeDraft, useCases: ["speculative_decoding"], source: "gguf_architecture", confidence: "confirmed")), [])
        XCTAssertEqual(ModelTaskType.classification.title, "Classification")
        let data = Data(#"{"type":"classification","use_cases":["moderation","routing","classification"],"source":"pipeline_tag","confidence":"confirmed"}"#.utf8)
        let task = try? JSONDecoder().decode(ModelTask.self, from: data)
        XCTAssertEqual(task?.type, .classification)
        XCTAssertEqual(task.map { ModelTaskPresentation.capabilities(for: $0) }, [])
        XCTAssertEqual(ModelTaskPresentation.useCaseTitle("moderation"), "Moderation")
    }

    func testCapabilitiesComeFromAgentTask() {
        let coder = ModelTask(type: .textLLM, useCases: ["coding", "general_chat"], source: "registry", confidence: "confirmed")
        XCTAssertEqual(ModelTaskPresentation.capabilities(for: coder), [.coding, .generalChat])
        let asr = ModelTask(type: .speechToText, useCases: ["transcription"], source: "registry", confidence: "confirmed")
        XCTAssertEqual(ModelTaskPresentation.capabilities(for: asr), [])
        let item = ModelItem(path: "/m/whisper", name: "whisper-coder", bytes: 1, modifiedAt: nil, shard: nil, modelKey: nil, architecture: nil, quantization: nil, parameters: nil, structure: nil, signature: nil, companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil, task: asr)
        XCTAssertEqual(LibraryModel(item: item).capabilities, [])
    }

    /// Run serves chat models; media comparisons use their own task runners.
    @MainActor
    func testRunIsOfferedOnlyForServableModels() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = AppHost(
            catalogStore: CatalogStore(appSupportDirectory: { root }), catalogClient: CatalogClient(),
            config: Config.defaults(), now: { Date(timeIntervalSinceReferenceDate: 100) }
        )
        let cases: [(ModelTaskType, Bool)] = [(.textLLM, true), (.visionLanguage, true), (.speechToText, false), (.classification, false), (.imageGeneration, false), (.speculativeDraft, false)]
        for (type, servable) in cases {
            let task = ModelTask(type: type, useCases: [], source: "registry", confidence: "confirmed")
            let item = ModelItem(path: "/m/\(type.rawValue)", name: type.rawValue, bytes: 1, modifiedAt: nil, shard: nil, modelKey: nil, architecture: nil, quantization: nil, parameters: nil, structure: nil, signature: nil, companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil, task: task)
            XCTAssertEqual(ModelActions(appHost: host, model: LibraryModel(item: item), onRouteSelection: { _ in }).canServe, servable, type.rawValue)
        }
    }

    @MainActor
    func testLibraryComparisonRequestsSelectTheTaskWithoutStartingWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compare-actions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = AppHost(catalogStore: CatalogStore(appSupportDirectory: { root }), config: Config.defaults())
        let workflow = host.modelWorkflow.workflow
        var routes: [AppRoute] = []
        let cases: [(ModelTaskType, ComparisonMode?)] = [
            (.textLLM, .chat), (.visionLanguage, .chat), (.speechToText, .speechToText),
            (.textToSpeech, .textToSpeech), (.musicGeneration, .musicGeneration),
            (.imageGeneration, .imageGeneration), (.videoGeneration, .videoGeneration),
            (.classification, nil), (.embedding, nil), (.speculativeDraft, nil), (.other, nil)
        ]
        for (type, mode) in cases {
            let model = comparisonModel(type)
            let actions = ModelActions(appHost: host, model: model, onRouteSelection: { routes.append($0) })
            _ = host.handoffs.take(.compareModel)
            let previousRoutes = routes.count
            XCTAssertEqual(actions.canCompare, mode != nil, type.rawValue)
            actions.compare()
            XCTAssertEqual(host.handoffs[.compareModel]?.mode, mode, type.rawValue)
            XCTAssertEqual(routes.count, previousRoutes + (mode == nil ? 0 : 1))
            if mode != nil {
                let request = try XCTUnwrap(host.handoffs[.compareModel])
                XCTAssertEqual(request.modelPath, model.item.path)
                XCTAssertEqual(routes.last, .compare)
                actions.compare()
                XCTAssertNotEqual(host.handoffs[.compareModel]?.id, request.id)
            }
        }
        XCTAssertNil(host.comparison.activeRunID)
        XCTAssertTrue(host.comparison.runs.isEmpty)
        XCTAssertTrue(host.comparison.promptSets.filter { $0.origin == .userCreated }.isEmpty)
        XCTAssertEqual(host.modelWorkflow.workflow, workflow)
    }

    func testComparisonRequestRejectsUnavailableOrChangedTask() throws {
        let model = comparisonModel(.speechToText)
        let request = try XCTUnwrap(ComparisonModelRequest(model: model))
        XCTAssertEqual(request.resolve(in: [model]), model)
        XCTAssertNil(request.resolve(in: []))
        let unavailable = LibraryModel(item: model.item, readiness: .needsRuntime)
        XCTAssertNil(ComparisonModelRequest(model: unavailable))
        XCTAssertNil(request.resolve(in: [unavailable]))
        let changed = comparisonModel(.textToSpeech, path: model.item.path)
        XCTAssertNil(request.resolve(in: [changed]))
    }

    @MainActor
    func testLibraryHandoffUpdatesAnAlreadyMountedComparison() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compare-handoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = AppHost(catalogStore: CatalogStore(appSupportDirectory: { root }), config: Config.defaults())
        let types: [ModelTaskType] = [.speechToText, .imageGeneration, .textToSpeech, .videoGeneration]
        let models = types.map { comparisonModel($0) }
        host.librarySnapshot = LibrarySnapshot(models: models, groups: [], hardware: host.hardwareProfile, generatedAt: Date())
        let view = NSHostingView(rootView: QuantView(appHost: host)
            .environment(\.isRouteActive, true).frame(width: 1190, height: 900)
            .background(WorkbenchColor.canvas).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1190, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        try await Task.sleep(for: .milliseconds(200))
        for model in models {
            ModelActions(appHost: host, model: model, onRouteSelection: { XCTAssertEqual($0, .compare) }).compare()
            for _ in 0..<40 where host.handoffs[.compareModel] != nil { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertNil(host.handoffs[.compareModel])
            try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded()
            let popups = descendants(view).compactMap { $0 as? NSPopUpButton }
            let mode = try XCTUnwrap(popups.first { $0.itemTitles.contains("Video understanding") })
            XCTAssertEqual(mode.title, ComparisonMode.preferred(for: model.item)?.title)
            XCTAssertTrue(popups.contains { $0.title.hasPrefix(model.displayName) }, "The Library model must occupy lane A.")
            XCTAssertTrue(popups.contains { $0.title == "Choose a model" }, "Lane B must await explicit selection.")
            XCTAssertNil(host.comparison.activeRunID)
            XCTAssertTrue(host.comparison.runs.isEmpty)
            if let folder = ProcessInfo.processInfo.environment["MLX_WORKBENCH_COMPARISON_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: folder)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("library-\(model.item.task!.type.rawValue).png"))
            }
        }
    }

    private func comparisonModel(_ type: ModelTaskType, path: String? = nil) -> LibraryModel {
        LibraryModel(item: ModelItem(path: path ?? "/m/\(type.rawValue)", name: type.rawValue, bytes: 1, modifiedAt: nil,
            shard: nil, modelKey: nil, architecture: nil, quantization: nil, parameters: nil, structure: nil,
            signature: nil, companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil,
            error: nil, task: ModelTask(type: type, useCases: [], source: "registry", confidence: "confirmed")), readiness: .ready)
    }

    func testUseCaseTitles() {
        XCTAssertEqual(ModelTaskPresentation.useCaseTitle("realtime_transcription"), "Realtime transcription")
        XCTAssertEqual(ModelTaskPresentation.useCaseTitle("vision"), "Image understanding")
        XCTAssertEqual(ModelTaskPresentation.useCaseTitle("unclassified"), "Unclassified")
        XCTAssertEqual(ModelTaskPresentation.useCaseTitle("new_thing"), "New Thing")
    }
}
