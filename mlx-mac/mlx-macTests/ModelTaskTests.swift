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
        XCTAssertEqual(ModelTaskType.visionProjector.title, "Vision projector")
        XCTAssertEqual(ModelTaskType.visionProjector.kindTitle, "Projector")
        XCTAssertFalse(ModelTaskType.visionProjector.hasCanary)
        XCTAssertFalse(ModelTaskType.visionProjector.supportsEndpoint)
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

    func testTypedEndpointsDoNotAdvertiseChatControls() {
        let typed = ServerInfo(path: "/models/music", runtime: "tasks", port: 8085, pid: 42, state: "running", taskKinds: ["music_generation"])
        XCTAssertFalse(typed.supportsChatCompletions)
        XCTAssertFalse(EndpointTestCoordinator.supports(typed))
        XCTAssertNil(WireEndpoint(server: typed))
        XCTAssertTrue(ModelTaskType.musicGeneration.supportsEndpoint)
        XCTAssertFalse(ModelTaskType.musicGeneration.isServable)
    }

    func testCapabilitiesComeFromAgentTask() {
        let coder = ModelTask(type: .textLLM, useCases: ["coding", "general_chat"], source: "registry", confidence: "confirmed")
        XCTAssertEqual(ModelTaskPresentation.capabilities(for: coder), [.coding, .generalChat])
        let asr = ModelTask(type: .speechToText, useCases: ["transcription"], source: "registry", confidence: "confirmed")
        XCTAssertEqual(ModelTaskPresentation.capabilities(for: asr), [])
        let item = ModelItem(path: "/m/whisper", name: "whisper-coder", bytes: 1, modifiedAt: nil, shard: nil, modelKey: nil, architecture: nil, quantization: nil, parameters: nil, structure: nil, signature: nil, companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil, task: asr)
        XCTAssertEqual(LibraryModel(item: item).capabilities, [])
    }

    /// Endpoint availability is independent of chat canaries and comparisons.
    @MainActor
    func testRunIsOfferedForSupportedEndpointTypes() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = AppHost(
            catalogStore: CatalogStore(appSupportDirectory: { root }), catalogClient: CatalogClient(),
            config: Config.defaults(), now: { Date(timeIntervalSinceReferenceDate: 100) }
        )
        let cases: [(ModelTaskType, Bool)] = [(.textLLM, true), (.visionLanguage, true), (.speechToText, true), (.textToSpeech, true), (.classification, true), (.imageGeneration, true), (.musicGeneration, true), (.videoGeneration, true), (.meshGeneration, true), (.embedding, true), (.other, false), (.speculativeDraft, false)]
        for (type, servable) in cases {
            let task = ModelTask(type: type, useCases: [], source: "registry", confidence: "confirmed")
            let item = ModelItem(path: "/m/\(type.rawValue)", name: type.rawValue, bytes: 1, modifiedAt: nil, shard: nil, modelKey: nil, architecture: nil, quantization: nil, parameters: nil, structure: nil, signature: nil, companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil, task: task)
            XCTAssertEqual(ModelActions(appHost: host, model: LibraryModel(item: item), onRouteSelection: { _ in }).canServe, servable, type.rawValue)
        }
    }

    @MainActor
    func testUnconvertedWeightsOfferConvertAndSidecarsOfferNothing() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prepare-actions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = AppHost(catalogStore: CatalogStore(appSupportDirectory: { root }), config: Config.defaults())
        func actions(_ name: String, status: String, companion: Bool? = nil, draft: ModelDraft? = nil) -> ModelActions {
            let item = ModelItem(path: "/m/\(name)", name: name, bytes: 1, modifiedAt: nil, shard: nil, modelKey: nil, architecture: nil, quantization: nil, parameters: nil, structure: nil, signature: nil, companion: companion, readable: true, status: status, outputs: [], tensorCount: nil, error: nil, draft: draft)
            return ModelActions(appHost: host, model: LibraryModel(item: item), onRouteSelection: { _ in })
        }
        let gguf = actions("Qwen3.8-27B-Q6_K.gguf", status: "pending")
        XCTAssertTrue(gguf.canPrepare)
        XCTAssertEqual(gguf.prepareTitle, "Convert to MLX…")
        let dspark = actions("dspark-Q8_0.gguf", status: "pending", draft: ModelDraft(port: "deepseek_v4_dspark", target: "DeepSeek-V4", blockSize: 5))
        XCTAssertTrue(dspark.canPrepare)
        XCTAssertFalse(actions("mmproj-F32.gguf", status: "companion", companion: true).canPrepare)
        XCTAssertFalse(actions("Qwen3.8-27B-FastMTP.gguf", status: "pending", draft: ModelDraft(port: nil, target: "Qwen3.8-27B", blockSize: nil)).canPrepare)
        let unsupported = actions("checkpoint", status: "unsupported")
        XCTAssertTrue(unsupported.canPrepare)
        XCTAssertEqual(unsupported.prepareTitle, "Prepare to run")
        let convertedSource = actions("ready-source.gguf", status: "ready")
        XCTAssertTrue(convertedSource.canPrepare)
        XCTAssertEqual(convertedSource.prepareTitle, "Convert to MLX…")
        XCTAssertFalse(actions("ready-model", status: "ready").canPrepare)
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
            (.classification, .classification), (.embedding, nil), (.speculativeDraft, nil), (.other, nil)
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

    func testScoreOnSetHandoffSelectsThatSetInCompare() throws {
        let model = comparisonModel(.classification)
        let builtin = ComparisonMediaFixtures.supportRoutingSet
        let saved = PromptSet(id: "saved-routing", name: "Saved routing", useCase: nil, prompts: builtin.prompts,
                              origin: .userCreated, mode: .classification)
        let request = try XCTUnwrap(ComparisonModelRequest(model: model, promptSetID: saved.id))
        XCTAssertEqual(request.mode, .classification)
        XCTAssertEqual(request.promptSetID, saved.id)
        XCTAssertEqual(request.selectedPromptSetID(in: [builtin, saved], current: builtin.id), saved.id)
        let plain = try XCTUnwrap(ComparisonModelRequest(model: model))
        XCTAssertNil(plain.promptSetID)
        XCTAssertEqual(plain.selectedPromptSetID(in: [builtin, saved], current: saved.id), saved.id)
        let missing = try XCTUnwrap(ComparisonModelRequest(model: model, promptSetID: "deleted-set"))
        XCTAssertEqual(missing.selectedPromptSetID(in: [builtin, saved], current: "gone"), builtin.id)
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
