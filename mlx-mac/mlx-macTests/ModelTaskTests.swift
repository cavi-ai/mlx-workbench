import XCTest

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
        XCTAssertFalse(ModelTaskType.classification.isServable)
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

    /// Run and Compare serve chat models; the inspector and context menu offer them for nothing else.
    @MainActor
    func testRunAndCompareAreOfferedOnlyForServableModels() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = AppHost(
            catalogStore: CatalogStore(appSupportDirectory: { root }), catalogClient: CatalogClient(),
            config: Config.defaults(), now: { Date(timeIntervalSinceReferenceDate: 100) }
        )
        let cases: [(ModelTaskType, Bool)] = [(.textLLM, true), (.visionLanguage, true), (.speechToText, false), (.classification, false), (.imageGeneration, false)]
        for (type, servable) in cases {
            let task = ModelTask(type: type, useCases: [], source: "registry", confidence: "confirmed")
            let item = ModelItem(path: "/m/\(type.rawValue)", name: type.rawValue, bytes: 1, modifiedAt: nil, shard: nil, modelKey: nil, architecture: nil, quantization: nil, parameters: nil, structure: nil, signature: nil, companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil, task: task)
            XCTAssertEqual(ModelActions(appHost: host, model: LibraryModel(item: item), onRouteSelection: { _ in }).canServe, servable, type.rawValue)
        }
    }

    func testUseCaseTitles() {
        XCTAssertEqual(ModelTaskPresentation.useCaseTitle("realtime_transcription"), "Realtime transcription")
        XCTAssertEqual(ModelTaskPresentation.useCaseTitle("vision"), "Image understanding")
        XCTAssertEqual(ModelTaskPresentation.useCaseTitle("unclassified"), "Unclassified")
        XCTAssertEqual(ModelTaskPresentation.useCaseTitle("new_thing"), "New Thing")
    }
}
