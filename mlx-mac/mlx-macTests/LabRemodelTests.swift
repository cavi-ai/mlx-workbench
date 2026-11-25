import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

// MARK: - Fixtures

private enum LF {
    static func item(_ id: String, sealed: Bool = true, states: [String]) throws -> LabHistoryItem {
        let object: [String: Any] = ["id": id, "sealed": sealed, "states": states, "evidence_completeness": "complete"]
        return try JSONDecoder().decode(LabHistoryItem.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func job(_ id: String, state: String, error: String? = nil) throws -> LabJob {
        var object: [String: Any] = ["id": id, "experiment_id": "exp_0123456789", "state": state]
        if let error { object["error"] = error }
        return try JSONDecoder().decode(LabJob.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func value(_ json: String) throws -> LabValue {
        try JSONDecoder().decode(LabValue.self, from: Data(json.utf8))
    }

    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/UI/Views/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - Presentation

final class LabPresentationTests: XCTestCase {
    func testAggregateStatusFollowsTheStates() {
        XCTAssertEqual(LabPresentation.aggregateStatus(["completed", "completed"]), .succeeded)
        XCTAssertEqual(LabPresentation.aggregateStatus(["completed", "failed"]), .failure)
        XCTAssertEqual(LabPresentation.aggregateStatus(["queued", "running"]), .running)
        XCTAssertTrue(LabPresentation.aggregateStatus(["running", "completed"]).isLive)
        XCTAssertEqual(LabPresentation.aggregateStatus([]), .unknown)
    }

    func testUnknownStatesAreShownVerbatim() throws {
        XCTAssertEqual(LabPresentation.aggregateStatus(["awaiting_gpu"]).label, "awaiting_gpu")
        XCTAssertEqual(LabPresentation.aggregateStatus(["awaiting_gpu", "completed"]).label, "awaiting_gpu · Completed")
        XCTAssertEqual(LabPresentation.aggregateStatus(["queued", "completed"]).label, "Queued · Completed")
        XCTAssertEqual(LabPresentation.aggregateStatus(["queued", "queued"]), .queued)
        XCTAssertEqual(LabJobRow(job: try LF.job("job_a", state: "warming_up")).status.label, "warming_up")
    }

    func testCompletedReadsTheSameOnEveryRow() throws {
        let aggregate = LabPresentation.aggregateStatus(["completed"])
        XCTAssertEqual(aggregate, LabJobRow(job: try LF.job("job_a", state: "completed")).status)
        let study = try XCTUnwrap(LabStudyRow(value: try LF.value(#"{"study_id":"s_a","state":"completed"}"#)))
        XCTAssertEqual(aggregate, study.status)
        XCTAssertEqual(aggregate, LabPresentation.status(for: "completed"))
    }

    func testAnExperimentWithoutJobsHasNoBadge() throws {
        let row = LabExperimentRow(item: try LF.item("exp_a", states: []))
        XCTAssertNil(row.status)
        XCTAssertEqual(row.evidenceTag, "No jobs yet")
        XCTAssertFalse(row.canReview)
    }

    func testRevealValuesAreScalarsOrPointAtTheManifests() throws {
        XCTAssertEqual(LabPresentation.revealValue(.string("euler")), "euler")
        XCTAssertEqual(LabPresentation.revealValue(.integer(8)), "8")
        XCTAssertEqual(LabPresentation.revealValue(try LF.value(#"{"a":1}"#)), "see Frozen manifests")
        XCTAssertEqual(LabPresentation.revealValue(nil), "")
    }

    func testJobBadgeMapsStatesAndKeepsUnknownOnes() throws {
        XCTAssertEqual(LabJobRow(job: try LF.job("job_a", state: "queued")).status, .queued)
        XCTAssertEqual(LabJobRow(job: try LF.job("job_a", state: "running")).status, .running)
        XCTAssertEqual(LabJobRow(job: try LF.job("job_a", state: "failed")).status, .failure)
        XCTAssertEqual(LabJobRow(job: try LF.job("job_a", state: "cancelled")).status.label, "Cancelled")
    }

    func testJobActionsFollowTheState() throws {
        let queued = LabJobRow(job: try LF.job("job_a", state: "queued"))
        XCTAssertTrue(queued.canRun)
        XCTAssertTrue(queued.canCancel)
        let running = LabJobRow(job: try LF.job("job_a", state: "running"))
        XCTAssertFalse(running.canRun)
        XCTAssertTrue(running.canCancel)
        for state in ["completed", "failed", "cancelled"] {
            let done = LabJobRow(job: try LF.job("job_a", state: state))
            XCTAssertFalse(done.canRun)
            XCTAssertFalse(done.canCancel)
        }
    }

    func testJobFailureIsAnInRowSentenceOnlyWhenPresent() throws {
        XCTAssertEqual(LabJobRow(job: try LF.job("job_a", state: "failed", error: "out of memory")).failure, "out of memory")
        XCTAssertNil(LabJobRow(job: try LF.job("job_a", state: "failed", error: "")).failure)
        XCTAssertNil(LabJobRow(job: try LF.job("job_a", state: "queued")).failure)
    }

    func testShortIDDropsTheKindPrefixAndCutsTheBody() {
        XCTAssertEqual(LabPresentation.shortID("exp_0123456789abcdef"), "01234567")
        XCTAssertEqual(LabPresentation.shortID("job_abc"), "abc")
        XCTAssertEqual(LabPresentation.shortID("0123456789"), "01234567")
        XCTAssertEqual(LabPresentation.shortID(""), "")
    }

    func testExperimentRowReadsAsATitleStatusAndEvidenceTag() throws {
        let sealed = LabExperimentRow(item: try LF.item("exp_0123456789", sealed: true, states: ["completed", "completed"]))
        XCTAssertEqual(sealed.title, "Experiment 01234567")
        XCTAssertEqual(sealed.evidenceTag, "Identity sealed")
        XCTAssertFalse(sealed.reviewed)
        let reviewed = LabExperimentRow(item: try LF.item("exp_0123456789", sealed: false, states: ["completed"]))
        XCTAssertEqual(reviewed.evidenceTag, "Reviewed")
        XCTAssertTrue(reviewed.reviewed)
    }

    func testReviewIsEnabledOnlyWhenEveryStateIsCompleted() throws {
        XCTAssertTrue(LabExperimentRow(item: try LF.item("exp_a", states: ["completed", "completed"])).canReview)
        XCTAssertFalse(LabExperimentRow(item: try LF.item("exp_a", states: ["completed", "running"])).canReview)
        XCTAssertFalse(LabExperimentRow(item: try LF.item("exp_a", states: ["completed", "failed"])).canReview)
        XCTAssertFalse(LabExperimentRow(item: try LF.item("exp_a", states: [])).canReview)
    }

    func testStorePathCollapsesTheHomeDirectory() {
        XCTAssertEqual(LabPresentation.storePath("/Users/fixture/lab", home: "/Users/fixture"), "~/lab")
        XCTAssertEqual(LabPresentation.storePath("/Volumes/x/lab", home: "/Users/fixture"), "/Volumes/x/lab")
    }

    func testProgressItemsComeFromScalarEntriesInOrder() throws {
        let progress = try LF.value(#"{"rounds_done":3,"budget_remaining":0.5,"stage":"search","detail":{"a":1},"flag":true}"#)
        XCTAssertEqual(LabPresentation.progressItems(progress), [
            LabProgressItem(label: "Budget remaining", value: "0.5"),
            LabProgressItem(label: "Rounds done", value: "3"),
            LabProgressItem(label: "Stage", value: "search"),
        ])
        XCTAssertEqual(LabPresentation.progressItems(try LF.value("12")), [LabProgressItem(label: "Progress", value: "12")])
        XCTAssertEqual(LabPresentation.progressItems(nil), [])
        XCTAssertEqual(LabPresentation.progressItems(try LF.value(#"{"a":1,"b":2,"c":3,"d":4,"e":5}"#)).count, LabPresentation.maxProgressItems)
    }

    func testStudyRowMapsNextActionsAndKeepsTheRawRecord() throws {
        let resume = try XCTUnwrap(LabStudyRow(value: try LF.value(#"{"study_id":"study_0123456789","state":"running","next_action":"resume","progress":{"rounds":2}}"#)))
        XCTAssertEqual(resume.action, .resume)
        XCTAssertEqual(resume.status, .running)
        XCTAssertEqual(resume.shortID, "01234567")
        XCTAssertEqual(resume.progress, [LabProgressItem(label: "Rounds", value: "2")])
        XCTAssertFalse(resume.retainsEvidence)
        let review = try XCTUnwrap(LabStudyRow(value: try LF.value(#"{"study_id":"s_a","next_action":"record_preference","review_id":"rev1","prompt":"A kite"}"#)))
        XCTAssertEqual(review.action, .review(session: "rev1"))
        XCTAssertEqual(review.prompt, "A kite")
        let generate = try XCTUnwrap(LabStudyRow(value: try LF.value(#"{"study_id":"s_a","next_action":"complete_generation"}"#)))
        XCTAssertEqual(generate.action, .generate)
        let done = try XCTUnwrap(LabStudyRow(value: try LF.value(#"{"study_id":"s_a","state":"mystery_state"}"#)))
        XCTAssertEqual(done.action, .none)
        XCTAssertTrue(done.retainsEvidence)
        XCTAssertEqual(done.status?.label, "mystery_state")
        XCTAssertTrue(done.rawText.contains("study_id"))
        XCTAssertNil(LabStudyRow(value: try LF.value(#"{"state":"running"}"#)))
    }

    func testReviewActionNeedsASession() throws {
        let row = try XCTUnwrap(LabStudyRow(value: try LF.value(#"{"study_id":"s_a","next_action":"record_preference"}"#)))
        XCTAssertEqual(row.action, .none)
    }
}

// MARK: - Source guards

final class LabSourceGuardTests: XCTestCase {
    func testStudyRowsAreBuiltOnRefreshNotInTheBody() throws {
        let source = try LF.source("LabView.swift")
        let panel = try XCTUnwrap(source.range(of: "private struct AdaptiveStudiesPanel"))
        let tail = String(source[panel.upperBound...])
        let body = try XCTUnwrap(tail.range(of: "private func refresh"))
        let render = String(tail[..<body.lowerBound])
        XCTAssertFalse(render.contains("LabStudyRow("))
        XCTAssertFalse(render.contains("LabStudyRow.init"))
        let coordinator = try LF.source("../../Services/LabCoordinator.swift")
        XCTAssertTrue(coordinator.contains("LabStudyRow.init"))
    }

    func testViewBodiesBuildNoFileURLs() throws {
        let source = try LF.source("LabView.swift")
        let allowed = ["lab.useStore(URL(fileURLWithPath: path))", "left: URL(fileURLWithPath: left)", "right: URL(fileURLWithPath: right)"]
        for line in source.components(separatedBy: "\n") where line.contains("fileURLWithPath") {
            XCTAssertTrue(allowed.contains { line.contains($0) }, "file URL built outside an action handler: \(line)")
        }
    }

}
