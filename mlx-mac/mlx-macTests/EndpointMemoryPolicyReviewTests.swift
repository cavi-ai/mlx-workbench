import Foundation
import XCTest

@testable import mlx_workbench

final class EndpointMemoryPolicyReviewTests: XCTestCase {
    private func slot(jit: Bool = true) -> EndpointSlot {
        EndpointSlot(enabled: true, port: 8766, modelPath: "/models/model", loadOnRequest: jit, memoryPolicy: .automatic)
    }

    private func strataSlot(expertMemoryGB: Double? = nil) -> EndpointSlot {
        var result = slot()
        result.servingProfile = ServingProfile(id: UUID(), name: "Prepared model", modelPath: result.modelPath,
            options: StrataComparisonOptions(expertMemoryGB: expertMemoryGB, contextTokens: 32768))
        return result
    }

    private func review(slot: EndpointSlot, draft: EndpointMemoryPolicyDraft, hash: String = "reviewed") throws -> EndpointMemoryPolicyReview {
        EndpointMemoryPolicyReview(slot: slot, draft: draft, policy: try draft.policy(for: slot),
            previewHash: hash, allocation: nil, estimatedResidentBytes: nil)
    }

    func testExtendedAdmissionPolicyRoundTripsWithoutChangingEndpointOptions() throws {
        var target = slot()
        target.acceleration = LocalAccelerationOptions(visionCache: true)
        let original = target
        let policy = EndpointMemoryPolicy(idleTimeoutSeconds: 300, keepLoaded: false, minimumHeadroomGB: 4,
            unloadUnderPressure: true, contextTokens: 16384)
        let draft = EndpointMemoryPolicyDraft(policy: policy)
        XCTAssertEqual(try draft.policy(for: target), policy)
        XCTAssertEqual(target, original)
    }

    func testDisablingReserveClearsPressureAndContextDependencies() throws {
        var draft = EndpointMemoryPolicyDraft(policy: EndpointMemoryPolicy(idleTimeoutSeconds: 600, keepLoaded: false,
            minimumHeadroomGB: 4, unloadUnderPressure: true, contextTokens: 8192))
        draft.setReserve(false)
        let policy = try draft.policy(for: slot())
        XCTAssertNil(policy.minimumHeadroomGB)
        XCTAssertNil(policy.unloadUnderPressure)
        XCTAssertNil(policy.contextTokens)
        XCTAssertFalse(draft.pressureEnabled)
        XCTAssertFalse(draft.contextEnabled)
    }

    func testEnablingPressureAddsReserveAndDisablesKeepLoaded() throws {
        var draft = EndpointMemoryPolicyDraft(policy: EndpointMemoryPolicy(idleTimeoutSeconds: 600, keepLoaded: true, minimumHeadroomGB: nil))
        draft.setPressure(true)
        let policy = try draft.policy(for: slot())
        XCTAssertFalse(policy.keepLoaded)
        XCTAssertEqual(policy.minimumHeadroomGB, 2)
        XCTAssertEqual(policy.unloadUnderPressure, true)
    }

    func testEnablingKeepLoadedRemovesPressureWithoutChangingReserveOrContext() throws {
        var draft = EndpointMemoryPolicyDraft(policy: EndpointMemoryPolicy(idleTimeoutSeconds: 300, keepLoaded: false,
            minimumHeadroomGB: 4, unloadUnderPressure: true, contextTokens: 8192))
        draft.setKeepLoaded(true)
        let policy = try draft.policy(for: slot())
        XCTAssertTrue(policy.keepLoaded)
        XCTAssertNil(policy.unloadUnderPressure)
        XCTAssertEqual(policy.minimumHeadroomGB, 4)
        XCTAssertEqual(policy.contextTokens, 8192)
        XCTAssertEqual(policy.idleTimeoutSeconds, 300)
    }

    func testEnablingAdmissionContextAlsoEnablesReserve() throws {
        var draft = EndpointMemoryPolicyDraft(policy: .legacy)
        draft.contextTokens = " 16384 "
        draft.setContext(true)
        let policy = try draft.policy(for: slot())
        XCTAssertEqual(policy.minimumHeadroomGB, 2)
        XCTAssertEqual(policy.contextTokens, 16384)
    }

    func testStrataTotalBudgetRequiresExplicitAmountAndAddsReserve() throws {
        let target = strataSlot()
        var draft = EndpointMemoryPolicyDraft(policy: .legacy)
        draft.setBudget(true)
        XCTAssertThrowsError(try draft.policy(for: target), "A new budget must not silently choose an allowance")
        draft.budgetGB = " 24.5 "
        let policy = try draft.policy(for: target)
        XCTAssertEqual(policy.modelMemoryBudgetGB, 24.5)
        XCTAssertEqual(policy.minimumHeadroomGB, 2)
        XCTAssertNil(policy.contextTokens)
    }

    func testTotalBudgetIsRefusedForAutomaticRuntimeAndFixedExpertProfiles() {
        var draft = EndpointMemoryPolicyDraft(policy: .automatic)
        draft.setBudget(true)
        draft.budgetGB = "32"
        XCTAssertFalse(EndpointMemoryReviewRules.supportsTotalBudget(slot()))
        XCTAssertFalse(EndpointMemoryReviewRules.supportsTotalBudget(strataSlot(expertMemoryGB: 8)))
        XCTAssertThrowsError(try draft.policy(for: slot()))
        XCTAssertThrowsError(try draft.policy(for: strataSlot(expertMemoryGB: 8)))
        XCTAssertTrue(EndpointMemoryReviewRules.supportsTotalBudget(strataSlot()))
    }

    func testStrataContextStaysOwnedByTheProfile() {
        let target = strataSlot()
        let original = target
        var draft = EndpointMemoryPolicyDraft(policy: .automatic)
        draft.setContext(true)
        draft.contextTokens = "65536"
        XCTAssertThrowsError(try draft.policy(for: target))
        XCTAssertEqual(target, original)
        XCTAssertEqual(target.servingProfile?.options.contextTokens, 32768)
    }

    func testInvalidOrNonfiniteNumericTextCannotReachPreview() {
        for value in ["", "words", "nan", "inf", "-1", "1025"] {
            var draft = EndpointMemoryPolicyDraft(policy: .automatic)
            draft.reserveGB = value
            XCTAssertThrowsError(try draft.policy(for: slot()), "reserve: \(value)")
        }
        for value in ["", "words", "nan", "inf", "0", "1025"] {
            var draft = EndpointMemoryPolicyDraft(policy: .automatic)
            draft.setBudget(true); draft.budgetGB = value
            XCTAssertThrowsError(try draft.policy(for: strataSlot()), "budget: \(value)")
        }
        for value in ["", "words", "8192.5", "1023", "1048577"] {
            var draft = EndpointMemoryPolicyDraft(policy: .automatic)
            draft.setContext(true); draft.contextTokens = value
            XCTAssertThrowsError(try draft.policy(for: slot()), "context: \(value)")
        }
    }

    func testSupportedNumericBoundariesAreAcceptedAndIdleRangeIsEnforced() throws {
        for reserve in ["0", "1024"] {
            var draft = EndpointMemoryPolicyDraft(policy: .automatic)
            draft.reserveGB = reserve
            XCTAssertTrue(try draft.policy(for: slot()).isValid)
        }
        for context in ["1024", "1048576"] {
            var draft = EndpointMemoryPolicyDraft(policy: .automatic)
            draft.setContext(true); draft.contextTokens = context
            XCTAssertTrue(try draft.policy(for: slot()).isValid)
        }
        for budget in ["1", "1024"] {
            var draft = EndpointMemoryPolicyDraft(policy: .automatic)
            draft.setBudget(true); draft.budgetGB = budget
            XCTAssertTrue(try draft.policy(for: strataSlot()).isValid)
        }
        for idle in [-1, 86401] {
            var draft = EndpointMemoryPolicyDraft(policy: .automatic)
            draft.idleTimeoutSeconds = idle
            XCTAssertThrowsError(try draft.policy(for: slot()))
        }
    }

    func testEagerEndpointCannotCreateAMemoryPolicy() {
        let draft = EndpointMemoryPolicyDraft(policy: .automatic)
        XCTAssertThrowsError(try draft.policy(for: slot(jit: false)))
    }

    func testTotalBudgetCannotSilentlyRestoreADisabledReserve() {
        var draft = EndpointMemoryPolicyDraft(policy: .automatic)
        draft.setBudget(true); draft.budgetGB = "24"
        draft.setReserve(false)
        XCTAssertThrowsError(try draft.policy(for: strataSlot()))
    }

    func testConfirmationAcceptsTheSameDraftSlotAndFreshHash() throws {
        let target = slot()
        let draft = EndpointMemoryPolicyDraft(policy: .automatic)
        let reviewed = try review(slot: target, draft: draft)
        XCTAssertTrue(EndpointMemoryReviewRules.canConfirm(reviewed, draft: draft, slots: [target], freshHash: "reviewed"))
    }

    func testConfirmationRejectsChangedDraftSlotHashAndPolicy() throws {
        let target = slot()
        let draft = EndpointMemoryPolicyDraft(policy: .automatic)
        let reviewed = try review(slot: target, draft: draft)
        var editedDraft = draft
        editedDraft.reserveGB = "4"
        XCTAssertFalse(EndpointMemoryReviewRules.canConfirm(reviewed, draft: editedDraft, slots: [target], freshHash: "reviewed"))
        for hash in ["", "changed"] {
            XCTAssertFalse(EndpointMemoryReviewRules.canConfirm(reviewed, draft: draft, slots: [target], freshHash: hash))
        }
        XCTAssertFalse(EndpointMemoryReviewRules.canConfirm(reviewed, draft: draft, slots: [], freshHash: "reviewed"))
        var changed = target
        changed.acceleration = LocalAccelerationOptions(visionCache: true)
        XCTAssertFalse(EndpointMemoryReviewRules.canConfirm(reviewed, draft: draft, slots: [changed], freshHash: "reviewed"))
        changed = target; changed.memoryPolicy = .legacy
        XCTAssertFalse(EndpointMemoryReviewRules.canConfirm(reviewed, draft: draft, slots: [changed], freshHash: "reviewed"))
        let mismatched = EndpointMemoryPolicyReview(slot: target, draft: draft, policy: .legacy,
            previewHash: "reviewed", allocation: nil, estimatedResidentBytes: nil)
        XCTAssertFalse(EndpointMemoryReviewRules.canConfirm(mismatched, draft: draft, slots: [target], freshHash: "reviewed"))
    }
}
