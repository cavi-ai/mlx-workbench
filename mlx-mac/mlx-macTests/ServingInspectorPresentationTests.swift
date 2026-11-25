import XCTest
@testable import mlx_workbench

final class ServingInspectorPresentationTests: XCTestCase {
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
}
