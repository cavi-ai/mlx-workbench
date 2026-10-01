import XCTest

@testable import mlx_workbench

final class LibraryTypeGroupingTests: XCTestCase {
    private func model(_ path: String, key: String, type: ModelTaskType?, useCases: [String] = []) -> LibraryModel {
        let task = type.map { ModelTask(type: $0, useCases: useCases, source: "registry", confidence: "confirmed") }
        let item = ModelItem(path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: 10, modifiedAt: nil, shard: nil, modelKey: key, architecture: nil, quantization: "q4", parameters: nil, structure: nil, signature: nil, companion: nil, readable: true, status: "ready", outputs: [path], tensorCount: nil, error: nil, task: task)
        return LibraryModel(item: item, normalizedFamilyKey: key)
    }

    private func groups(_ models: [LibraryModel]) -> [LibraryGroupViewModel] {
        Dictionary(grouping: models, by: \.normalizedFamilyKey).map { key, variants in
            LibraryGroupViewModel(sourceGroup: ModelGroup(variants: variants, normalizedModelKey: key), variants: variants)
        }
    }

    func testTypeRowsNestTypeUseCaseFamily() {
        let rows = LibraryTablePresentation.typeRows(groups: groups([
            model("/m/qwen-coder-4", key: "qwen", type: .textLLM, useCases: ["coding", "general_chat"]),
            model("/m/qwen-coder-8", key: "qwen", type: .textLLM, useCases: ["coding", "general_chat"]),
            model("/m/qwen-chat", key: "qwen", type: .textLLM, useCases: ["general_chat"]),
            model("/m/whisper", key: "whisper", type: .speechToText, useCases: ["transcription"]),
        ]), sortOrder: [])
        XCTAssertEqual(rows.map(\.id), ["type:text_llm", "type:speech_to_text"])
        let text = rows[0].children ?? []
        XCTAssertEqual(text.map(\.name), ["Coding", "General chat"])
        XCTAssertEqual(text[0].children?.first?.children?.count, 2)
        XCTAssertEqual(text[1].children?.map(\.id), ["/m/qwen-chat"])
    }

    func testTypeRowsFallBackWhenAgentSentNoTask() {
        let rows = LibraryTablePresentation.typeRows(groups: groups([model("/m/legacy", key: "legacy", type: nil)]), sortOrder: [])
        XCTAssertEqual(rows.map(\.id), ["type:other"])
        XCTAssertEqual(rows[0].children?.map(\.name), ["Unclassified"])
        XCTAssertEqual(rows[0].children?.first?.children?.map(\.id), ["/m/legacy"])
    }

    func testSelectionIgnoresBucketsAndFindsNestedFamilies() {
        XCTAssertNil(LibraryTablePresentation.modelPath(forSelection: "type:text_llm"))
        XCTAssertNil(LibraryTablePresentation.modelPath(forSelection: "usecase:text_llm:coding"))
        XCTAssertEqual(LibraryTablePresentation.modelPath(forSelection: "/m/x"), "/m/x")
        let rows = LibraryTablePresentation.typeRows(groups: groups([
            model("/m/a", key: "fam", type: .textLLM, useCases: ["coding", "general_chat"]),
            model("/m/b", key: "fam", type: .textLLM, useCases: ["coding", "general_chat"]),
        ]), sortOrder: [])
        let familyID = rows[0].children?[0].children?[0].id ?? ""
        XCTAssertTrue(familyID.hasPrefix(LibraryRow.familyIDPrefix))
        XCTAssertEqual(LibraryTablePresentation.row(withID: familyID, in: rows)?.children?.count, 2)
    }

    func testIdentityRowsShowTaskRowsOnlyWhenTheAgentClassifiedTheModel() {
        let typed = model("/m/whisper", key: "whisper", type: .speechToText, useCases: ["transcription", "diarization"])
        let rows = ModelDetailsPresentation.identityRows(for: typed, prepareDestination: nil)
        XCTAssertEqual(rows.first { $0.label == "Type" }?.value, "Speech-to-text")
        XCTAssertEqual(rows.first { $0.label == "Use cases" }?.value, "Transcription, Diarization")
        XCTAssertEqual(rows.first { $0.label == "Classified by" }?.value, "registry (confirmed)")

        let legacy = ModelDetailsPresentation.identityRows(for: model("/m/legacy", key: "legacy", type: nil), prepareDestination: nil)
        XCTAssertFalse(legacy.contains { $0.label == "Type" || $0.label == "Use cases" || $0.label == "Classified by" })
    }
}
