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
        XCTAssertFalse(ModelTaskType.speechToText.hasCanary)
        XCTAssertFalse(ModelTaskType.textToSpeech.isServable)
    }

    func testCapabilitiesComeFromAgentTask() {
        let coder = ModelTask(type: .textLLM, useCases: ["coding", "general_chat"], source: "registry", confidence: "confirmed")
        XCTAssertEqual(ModelTaskPresentation.capabilities(for: coder), [.coding, .generalChat])
        let asr = ModelTask(type: .speechToText, useCases: ["transcription"], source: "registry", confidence: "confirmed")
        XCTAssertEqual(ModelTaskPresentation.capabilities(for: asr), [])
        let item = ModelItem(path: "/m/whisper", name: "whisper-coder", bytes: 1, modifiedAt: nil, shard: nil, modelKey: nil, architecture: nil, quantization: nil, parameters: nil, structure: nil, signature: nil, companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil, task: asr)
        XCTAssertEqual(LibraryModel(item: item).capabilities, [])
    }

    func testUseCaseTitles() {
        XCTAssertEqual(ModelTaskPresentation.useCaseTitle("realtime_transcription"), "Realtime transcription")
        XCTAssertEqual(ModelTaskPresentation.useCaseTitle("vision"), "Image understanding")
        XCTAssertEqual(ModelTaskPresentation.useCaseTitle("unclassified"), "Unclassified")
        XCTAssertEqual(ModelTaskPresentation.useCaseTitle("new_thing"), "New Thing")
    }
}
