import XCTest
@testable import mlx_workbench

final class ServingInspectorPresentationTests: XCTestCase {
    typealias Presentation = ServingInspectorPresentation

    func testChatRoleSectionOrder() {
        for role in [ServingRole.general, .vision, .reasoning, .coding] {
            XCTAssertEqual(Presentation.sections(for: role).map(\.title),
                           ["Status", "Load", "Inference", "Acceleration", "Access"], "\(role)")
        }
    }

    func testTypedRoleSectionOrder() {
        XCTAssertEqual(Presentation.sections(for: .classification).map(\.title), ["Status", "Load", "Access", "Tasks"])
        for role in ServingRole.allCases where !role.isChat {
            XCTAssertEqual(Presentation.sections(for: role).map(\.title), ["Status", "Load", "Access", "Tasks"], "\(role)")
        }
    }

    func testEveryInferenceFieldHasExactlyOneCaption() {
        let stored = Mirror(reflecting: LocalInferenceOptions()).children.compactMap(\.label)
        XCTAssertEqual(stored.count, 9)
        XCTAssertEqual(Presentation.Field.allCases.map(\.rawValue).sorted(), stored.sorted())
        let captions = Presentation.Field.allCases.map { Presentation.caption($0) }
        XCTAssertEqual(Set(captions).count, 9)
        XCTAssertTrue(captions.allSatisfy { !$0.isEmpty && !$0.contains("\n") })
    }

    func testCaptionRangesMatchTheValidationBounds() {
        let bounds = LocalInferenceBounds.self
        XCTAssertTrue(Presentation.caption(.maximumTokens).contains("\(bounds.maximumTokens.lowerBound) to \(bounds.maximumTokens.upperBound)"))
        XCTAssertTrue(Presentation.caption(.sharedPrefixCacheMiB).contains("\(bounds.sharedPrefixCacheMiB.lowerBound) to \(bounds.sharedPrefixCacheMiB.upperBound)"))
        XCTAssertTrue(Presentation.caption(.temperature).contains("0 to 2"))
        XCTAssertTrue(Presentation.caption(.topP).contains("0 to 1"))
        XCTAssertTrue(Presentation.caption(.systemPrompt).contains("8,192"))
        XCTAssertEqual(bounds.temperature, 0...2)
        XCTAssertEqual(bounds.topP, 0...1)
        XCTAssertEqual(bounds.maximumTokens, 256...65536)
        XCTAssertEqual(bounds.sharedPrefixCacheMiB, 16...2048)
        XCTAssertEqual(bounds.systemPromptBytes, 8192)
    }

    func testValidationAcceptsBoundsAndRejectsJustOutside() {
        let bounds = LocalInferenceBounds.self
        XCTAssertNil(LocalInferenceOptions(maximumTokens: bounds.maximumTokens.lowerBound).validationError)
        XCTAssertNil(LocalInferenceOptions(maximumTokens: bounds.maximumTokens.upperBound).validationError)
        XCTAssertNotNil(LocalInferenceOptions(maximumTokens: bounds.maximumTokens.lowerBound - 1).validationError)
        XCTAssertNotNil(LocalInferenceOptions(maximumTokens: bounds.maximumTokens.upperBound + 1).validationError)
        XCTAssertNil(LocalInferenceOptions(temperature: bounds.temperature.lowerBound).validationError)
        XCTAssertNil(LocalInferenceOptions(temperature: bounds.temperature.upperBound).validationError)
        XCTAssertNotNil(LocalInferenceOptions(temperature: bounds.temperature.upperBound + 0.01).validationError)
        XCTAssertNotNil(LocalInferenceOptions(temperature: bounds.temperature.lowerBound - 0.01).validationError)
        XCTAssertNil(LocalInferenceOptions(topP: bounds.topP.upperBound).validationError)
        XCTAssertNotNil(LocalInferenceOptions(topP: bounds.topP.upperBound + 0.01).validationError)
        XCTAssertNil(LocalInferenceOptions(sharedPrefixCacheMiB: bounds.sharedPrefixCacheMiB.lowerBound).validationError)
        XCTAssertNil(LocalInferenceOptions(sharedPrefixCacheMiB: bounds.sharedPrefixCacheMiB.upperBound).validationError)
        XCTAssertNotNil(LocalInferenceOptions(sharedPrefixCacheMiB: bounds.sharedPrefixCacheMiB.lowerBound - 1).validationError)
        XCTAssertNotNil(LocalInferenceOptions(sharedPrefixCacheMiB: bounds.sharedPrefixCacheMiB.upperBound + 1).validationError)
        XCTAssertNil(LocalInferenceOptions(systemPrompt: String(repeating: "a", count: bounds.systemPromptBytes)).validationError)
        XCTAssertNotNil(LocalInferenceOptions(systemPrompt: String(repeating: "a", count: bounds.systemPromptBytes + 1)).validationError)
    }

    func testValidationMessagesKeepTheirWording() {
        XCTAssertEqual(LocalInferenceOptions(systemPrompt: String(repeating: "a", count: 8193)).validationError,
                       "System prompt must fit in 8,192 UTF-8 bytes without null characters.")
        XCTAssertEqual(LocalInferenceOptions(temperature: 3).validationError, "Temperature must be from 0 to 2.")
        XCTAssertEqual(LocalInferenceOptions(topP: 2).validationError, "Top-p must be from 0 to 1.")
        XCTAssertEqual(LocalInferenceOptions(maximumTokens: 10).validationError, "Default output length must be from 256 to 65536 tokens.")
        XCTAssertEqual(LocalInferenceOptions(sharedPrefixCacheMiB: 4096).validationError, "Shared prefix cache must be from 16 to 2048 MiB.")
    }
}
