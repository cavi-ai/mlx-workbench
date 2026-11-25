import XCTest
@testable import mlx_workbench

final class ServingRolesPresentationTests: XCTestCase {
    private func model(_ path: String, task: ModelTaskType) -> LibraryModel {
        LibraryModel(item: ModelItem(path: path, name: path, bytes: 1_000, modifiedAt: nil, shard: nil, modelKey: path,
            architecture: nil, quantization: "Q4", parameters: "1B", structure: nil, signature: "s",
            companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil,
            task: ModelTask(type: task, useCases: [], source: "test", confidence: "test")), readiness: .ready, capabilities: nil)
    }

    func testClassifierCandidatesExcludeTextModels() {
        let models = [model("/m/llm", task: .textLLM), model("/m/clf", task: .classification), model("/m/vlm", task: .visionLanguage)]
        let classifier = ServingRolesPresentation.candidates(for: .classification, models: models, slots: [])
        XCTAssertEqual(classifier.map(\.item.path), ["/m/clf"])
        let coding = ServingRolesPresentation.candidates(for: .coding, models: models, slots: [])
        XCTAssertEqual(Set(coding.map(\.item.path)), ["/m/llm", "/m/vlm"])
    }
}
