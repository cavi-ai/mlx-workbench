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

    func testUnknownStatesKeepTheirOwnWording() {
        XCTAssertEqual(LabPresentation.aggregateStatus(["awaiting_gpu"]).label, "Awaiting Gpu")
        XCTAssertEqual(LabPresentation.aggregateStatus(["queued", "completed"]).label, "Queued · Completed")
        XCTAssertEqual(LabPresentation.aggregateStatus(["queued", "queued"]), .queued)
    }

    func testJobBadgeMapsStatesAndKeepsUnknownOnes() throws {
        XCTAssertEqual(LabJobRow(job: try LF.job("job_a", state: "queued")).status, .queued)
        XCTAssertEqual(LabJobRow(job: try LF.job("job_a", state: "running")).status, .running)
        XCTAssertEqual(LabJobRow(job: try LF.job("job_a", state: "failed")).status, .failure)
        XCTAssertEqual(LabJobRow(job: try LF.job("job_a", state: "cancelled")).status.label, "Cancelled")
        XCTAssertEqual(LabJobRow(job: try LF.job("job_a", state: "warming_up")).status.label, "Warming Up")
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
        XCTAssertEqual(done.status?.label, "Mystery State")
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
    func testRawJSONNeverFeedsATextFont() throws {
        let source = try LF.source("LabView.swift")
        for line in source.components(separatedBy: "\n") where line.contains("jsonText") {
            XCTAssertFalse(line.contains(".font("), "raw JSON drawn outside a disclosure: \(line)")
        }
    }

    func testSheetsUseTheSectionTitleAndNoFixedWidth() throws {
        let source = try LF.source("LabView.swift")
        XCTAssertFalse(source.contains(".font(WorkbenchTypography.title)"))
        XCTAssertFalse(source.contains("frame(width: 740)"))
        XCTAssertFalse(source.contains("frame(width: 80)"))
        for title in ["New controlled experiment", "Blind video review", "Import a Video Lab workspace"] {
            XCTAssertTrue(source.contains("Text(\"\(title)\").font(WorkbenchTypography.section)"), title)
        }
    }

    func testViewBodiesBuildNoFileURLs() throws {
        let source = try LF.source("LabView.swift")
        let allowed = ["lab.useStore(URL(fileURLWithPath: path))", "left: URL(fileURLWithPath: left)", "right: URL(fileURLWithPath: right)"]
        for line in source.components(separatedBy: "\n") where line.contains("fileURLWithPath") {
            XCTAssertTrue(allowed.contains { line.contains($0) }, "file URL built outside an action handler: \(line)")
        }
    }

    func testTheUITestAnchorsSurvive() throws {
        let source = try LF.source("LabView.swift")
        for anchor in ["New experiment…", "Create experiment", "Play together", "Pause", "Previous frame",
                       "Next frame", "Submit immutable review", "Blind review…", "Controlled studies"] {
            XCTAssertTrue(source.contains("\"\(anchor)\""), anchor)
        }
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"Blind review…\")"))
    }
}

// MARK: - Renders

@MainActor
final class LabRenderTests: XCTestCase {
    private func attach<Content: View>(_ view: Content, name: String, viewport: CGFloat, dark: Bool, height: CGFloat = 1000) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: viewport, height: height).background(WorkbenchColor.canvas).preferredColorScheme(dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: viewport, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)
        hosting.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "\(name)-\(dark ? "dark" : "light")-\(Int(viewport))"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func coordinator() -> LabCoordinator {
        let suite = "lab-render-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        return LabCoordinator(api: WorkbenchAPI(cli: CLIProcess(), agentPath: "/nonexistent-agent"), defaults: defaults)
    }

    private struct Scenario {
        let name: String
        let experiments: [LabExperimentRow]
        let jobs: [LabJobRow]
        let studies: [LabStudyRow]
        let error: String?
    }

    private func scenarios() throws -> [Scenario] {
        let experiments = [
            LabExperimentRow(item: try LF.item("exp_0123456789abcdef", sealed: true, states: ["completed", "completed"])),
            LabExperimentRow(item: try LF.item("exp_1123456789abcdef", sealed: false, states: ["completed"])),
            LabExperimentRow(item: try LF.item("exp_2123456789abcdef", sealed: true, states: ["completed", "running"])),
            LabExperimentRow(item: try LF.item("exp_3123456789abcdef", sealed: true, states: ["completed", "failed"])),
            LabExperimentRow(item: try LF.item("exp_4123456789abcdef", sealed: true, states: ["awaiting_gpu"])),
        ]
        let jobs = [
            LabJobRow(job: try LF.job("job_0123456789abcdef", state: "queued")),
            LabJobRow(job: try LF.job("job_1123456789abcdef", state: "running")),
            LabJobRow(job: try LF.job("job_2123456789abcdef", state: "failed", error: "The runtime ran out of memory while rendering the second candidate.")),
            LabJobRow(job: try LF.job("job_3123456789abcdef", state: "warming_up")),
        ]
        let studies = [
            try XCTUnwrap(LabStudyRow(value: try LF.value(#"{"study_id":"study_0123456789","state":"running","next_action":"record_preference","review_id":"r1","progress":{"rounds_done":3,"budget_remaining":5,"stage":"search"}}"#))),
            try XCTUnwrap(LabStudyRow(value: try LF.value(#"{"study_id":"study_1123456789","state":"completed","next_action":"none","progress":{"rounds_done":9}}"#))),
        ]
        return [
            Scenario(name: "lab-empty", experiments: [], jobs: [], studies: [], error: nil),
            Scenario(name: "lab-populated", experiments: experiments, jobs: jobs, studies: studies, error: nil),
            Scenario(name: "lab-error", experiments: experiments.prefix(1).map { $0 }, jobs: [], studies: [],
                     error: "usage: mlx-agent lab [-h] operation\nmlx-agent: error: the following arguments are required"),
        ]
    }

    private func panel(_ scenario: Scenario) -> some View {
        let actions = LabHeaderActions(create: {}, importWorkspace: {}, recover: {}, refresh: {}, chooseWorkspace: {}, reveal: {}, copyPath: {})
        return ScrollView {
            WorkbenchCard("Controlled studies", systemImage: "square.split.2x1") {
                Text("Compare one change at a time, then review the clips without seeing candidate identities.")
                    .foregroundStyle(WorkbenchColor.muted)
                LabHeaderView(storePath: "~/Library/Application Support/mlx-agent/lab", isRefreshing: false, canChangeWorkspace: true, actions: actions)
                ErrorBanner(text: scenario.error)
                LabExperimentList(rows: scenario.experiments, isOpeningReview: false, review: { _ in })
                ForEach(scenario.studies) { row in
                    Divider()
                    LabStudyRowView(row: row, busy: false, generationBlocked: false, perform: { _ in }, review: { _, _ in })
                }
                ForEach(scenario.jobs) { row in
                    LabJobRowView(row: row, runDisabled: false, run: {}, cancel: {})
                }
            }
            .padding(WorkbenchSpacing.pageInset)
        }
    }

    func testPanelAndSheetsRenderDarkAndLightAtEveryWidth() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let lab = coordinator()
        let context = LabReviewContext(
            id: "session", prompt: "A paper kite over a quiet harbor",
            left: URL(fileURLWithPath: "/nonexistent/left.mp4"), right: URL(fileURLWithPath: "/nonexistent/right.mp4")
        )
        for dark in [true, false] {
            for width in [CGFloat(1220), 824] {
                for scenario in try scenarios() {
                    try await attach(panel(scenario), name: scenario.name, viewport: width, dark: dark)
                }
                try await attach(LabAuthorSheet(lab: lab), name: "lab-author-sheet", viewport: width, dark: dark, height: 520)
                try await attach(LabReviewSheet(lab: lab, context: context), name: "lab-review-sheet", viewport: width, dark: dark, height: 760)
                try await attach(LabAdoptSheet(lab: lab), name: "lab-adopt-sheet", viewport: width, dark: dark, height: 420)
            }
        }
    }
}
