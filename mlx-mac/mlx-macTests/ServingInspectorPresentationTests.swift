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

    func testResidencyChoiceWritesOneConsistentMemoryPolicy() {
        let base = EndpointMemoryPolicy(idleTimeoutSeconds: 300, keepLoaded: false, minimumHeadroomGB: 4,
                                        unloadUnderPressure: true, executionWaitSeconds: 30)

        let release = EndpointResidency.releaseAfterRequest.applied(to: base)
        XCTAssertEqual(release.releaseAfterRequest, true)
        XCTAssertFalse(release.keepLoaded)
        XCTAssertEqual(release.idleTimeoutSeconds, 0)
        XCTAssertEqual(release.minimumHeadroomGB, 4)
        XCTAssertEqual(release.executionWaitSeconds, 30)
        XCTAssertTrue(release.isValid)
        XCTAssertEqual(EndpointResidency(release), .releaseAfterRequest)

        let keep = EndpointResidency.keepLoaded.applied(to: release)
        XCTAssertTrue(keep.keepLoaded)
        XCTAssertEqual(keep.releaseAfterRequest, false)
        XCTAssertNil(keep.unloadUnderPressure)
        XCTAssertTrue(keep.isValid)
        XCTAssertEqual(EndpointResidency(keep), .keepLoaded)

        let idle = EndpointResidency(.unloadAfterIdle, from: release).applied(to: release)
        XCTAssertEqual(idle.idleTimeoutSeconds, EndpointResidency.defaultIdleSeconds)
        XCTAssertFalse(idle.keepLoaded)
        XCTAssertEqual(idle.releaseAfterRequest, false)
        XCTAssertTrue(idle.isValid)
        XCTAssertEqual(EndpointResidency(.unloadAfterIdle, from: base), .unloadAfterIdle(seconds: 300))
    }

    func testInferenceEditsCompareAgainstModelDefaultResolvedOptions() {
        var slot = EndpointSlot(enabled: false, port: 8100, modelPath: "/models/a", loadOnRequest: true)
        slot.overrides = []
        let effective = ServingSettings.effective(slot: slot, defaults: ModelServingDefaults(inference: LocalInferenceOptions(temperature: 0.7)))
        var options = effective.inferenceOptions

        XCTAssertFalse(ServingInspectorPresentation.hasUnsavedEdits(options, effective: effective))
        XCTAssertTrue(ServingInspectorPresentation.hasUnsavedEdits(options, effective: slot))
        options.temperature = 0.9
        XCTAssertTrue(ServingInspectorPresentation.hasUnsavedEdits(options, effective: effective))
        options.temperature = 0.7
        XCTAssertFalse(ServingInspectorPresentation.hasUnsavedEdits(options, effective: effective))
    }

    func testPresetListsOnlySettingsThatDifferFromModelDefault() {
        var slot = EndpointSlot(enabled: false, port: 8100, modelPath: "/models/a", loadOnRequest: true, memoryPolicy: .automatic)
        slot.overrides = [.temperature]
        slot.acceleration = LocalInferenceOptions(temperature: 0.2)
        let defaults = ModelServingDefaults(inference: LocalInferenceOptions(maximumTokens: 2048, temperature: 0.7),
                                            memoryPolicy: .automatic, loadOnRequest: true)
        var followed = slot
        followed.overrides = []

        let effective = ServingSettings.effective(slot: slot, defaults: defaults)
        let modelDefault = ServingSettings.effective(slot: followed, defaults: defaults)
        XCTAssertEqual(ServingInspectorPresentation.differences(effective, from: modelDefault), [.temperature])
        XCTAssertEqual(ServingInspectorPresentation.differences(modelDefault, from: modelDefault), [])
    }
}
