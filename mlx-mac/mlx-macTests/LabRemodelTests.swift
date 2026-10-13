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
    func testRawJSONNeverFeedsATextFont() throws {
        let source = try LF.source("LabView.swift")
        let uses = source.components(separatedBy: "jsonText").count - 1
        XCTAssertEqual(uses, 1, "raw JSON belongs only in manifestText, behind a disclosure")
        XCTAssertTrue(source.contains("reveal.manifests?[$0]?.jsonText"))
    }

    func testEveryLabBadgeStopsPulsingWhenItsRouteIsHidden() throws {
        let source = try LF.source("LabView.swift")
        let badges = source.components(separatedBy: "StatusBadge(").dropFirst()
        XCTAssertEqual(badges.count, 3)
        for badge in badges {
            XCTAssertTrue(badge.prefix(while: { $0 != "\n" }).contains("pulses: isRouteActive"), String(badge.prefix(60)))
        }
    }

    func testStudyBlindReviewIsDistinctFromTheExperimentAnchor() throws {
        let source = try LF.source("LabView.swift")
        XCTAssertFalse(source.contains("Button(\"Blind review\")"))
        XCTAssertEqual(source.components(separatedBy: ".accessibilityIdentifier(\"Blind review…\")").count - 1, 1)
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"Study blind review…\")"))
    }

    func testStudyRowsAreBuiltOnRefreshNotInTheBody() throws {
        let source = try LF.source("LabView.swift")
        let panel = try XCTUnwrap(source.range(of: "private struct AdaptiveStudiesPanel"))
        let tail = String(source[panel.upperBound...])
        let body = try XCTUnwrap(tail.range(of: "private func refresh"))
        let render = String(tail[..<body.lowerBound])
        XCTAssertFalse(render.contains("LabStudyRow("))
        XCTAssertFalse(render.contains("LabStudyRow.init"))
        XCTAssertTrue(tail[body.lowerBound...].contains("LabStudyRow.init"))
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
                       "Next frame", "Submit immutable review", "Blind review…"] {
            XCTAssertTrue(source.contains("\"\(anchor)\""), anchor)
        }
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"Blind review…\")"))
        XCTAssertTrue(try LF.source("QuantView.swift").contains("Text(\"Controlled studies\").tag(true)"))
        var rest = Substring(source)
        while let open = rest.range(of: "Menu {") {
            let tail = rest[open.upperBound...]
            if rest[..<open.lowerBound].hasSuffix("context") { rest = tail; continue }
            let close = try XCTUnwrap(tail.range(of: "} label:"))
            let menu = tail[..<close.lowerBound]
            for anchor in ["New experiment…", "Blind review…", "Create experiment"] {
                XCTAssertFalse(menu.contains(anchor), "\(anchor) moved into a menu")
            }
            rest = tail[close.upperBound...]
        }
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

    /// Answers each lab operation from fixtures; the runner never starts a process.
    nonisolated static let fakeAgent: WorkbenchAPI.AgentCommand = { _, argv, _, _ in
        guard let index = argv.firstIndex(of: "--request"), index + 1 < argv.count,
              let data = FileManager.default.contents(atPath: argv[index + 1]),
              let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let operation = request["operation"] as? String
        else { return [:] }
        func item(_ id: String, _ sealed: Bool, _ states: [String]) -> [String: Any] {
            ["id": id, "sealed": sealed, "states": states, "evidence_completeness": "complete"]
        }
        switch operation {
        case "snapshot":
            return [
                "history": ["items": [
                    item("exp_0123456789abcdef", true, ["completed", "completed"]),
                    item("exp_2123456789abcdef", true, ["completed", "running"]),
                    item("exp_3123456789abcdef", true, ["completed", "failed"]),
                ]],
                "queue": [
                    ["id": "job_0123456789abcdef", "experiment_id": "exp_0123456789abcdef", "state": "queued"],
                    ["id": "job_2123456789abcdef", "experiment_id": "exp_2123456789abcdef", "state": "failed",
                     "error": "The runtime ran out of memory while rendering the second candidate."],
                ],
            ]
        case "study-list":
            return ["studies": [
                ["study_id": "study_0123456789", "state": "running", "next_action": "record_preference", "review_id": "r1",
                 "progress": ["rounds_done": 3, "budget_remaining": 5, "stage": "search"]],
                ["study_id": "study_1123456789", "state": "completed", "next_action": "none", "progress": ["rounds_done": 9]],
            ]]
        case "reveal":
            return [
                "review_id": "review_0123456789", "revision": 1,
                "canonical_by_display": ["left": "candidate_b", "right": "candidate_a"],
                "variable_path": "inference_steps", "baseline_value": 8, "alternate_value": 16,
                "manifests": [
                    "candidate_a": ["model": "ltx-video", "inference_steps": 8, "seed": 42],
                    "candidate_b": ["model": "ltx-video", "inference_steps": 16, "seed": 42],
                ],
            ]
        default:
            return [:]
        }
    }

    private func fakeCoordinator() -> LabCoordinator {
        let defaults = UserDefaults(suiteName: "lab-render-" + UUID().uuidString) ?? .standard
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: "/nonexistent-agent", receiptDirectory: NSTemporaryDirectory(), command: Self.fakeAgent)
        return LabCoordinator(api: api, defaults: defaults)
    }

    func testFakeAgentAnswersSnapshotStudiesAndReveal() async throws {
        let lab = fakeCoordinator()
        await lab.refresh()
        XCTAssertNil(lab.error)
        XCTAssertEqual(lab.snapshot.history?.items.count, 3)
        XCTAssertEqual(lab.snapshot.queue?.count, 2)
        let studies = try await lab.request(LabRequest(operation: "study-list")).studies
        XCTAssertEqual(studies?.count, 2)
        let reveal = try await lab.request(LabRequest(operation: "reveal", sessionID: "session"))
        XCTAssertEqual(reveal.manifests?.count, 2)
        XCTAssertEqual(reveal.variablePath, "inference_steps")
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
                let preview = try JSONDecoder().decode(LabResponse.self, from: Data(
                    #"{"preview_hash":"abc","source_database_digest":"sha256:3f2a9c0d11","artifact_count":42,"artifact_bytes":734003200}"#.utf8))
                try await attach(LabAdoptSheet(lab: lab, initialPreview: preview, initialDestination: "/Volumes/Studio/Imported Video Lab"),
                                 name: "lab-adopt-evidence", viewport: width, dark: dark, height: 520)
                try await attach(
                    ScrollView {
                        LabPanel(lab: fakeCoordinator(), installer: RuntimeInstaller(), agentPath: "/nonexistent-agent")
                            .padding(WorkbenchSpacing.pageInset)
                    },
                    name: "lab-panel", viewport: width, dark: dark, height: 1100)
                let reviewed = LabReviewContext(
                    id: "session", prompt: "A paper kite over a quiet harbor",
                    left: URL(fileURLWithPath: "/nonexistent/left.mp4"), right: URL(fileURLWithPath: "/nonexistent/right.mp4"), reviewed: true)
                try await attach(LabReviewSheet(lab: fakeCoordinator(), context: reviewed), name: "lab-review-frozen", viewport: width, dark: dark, height: 900)
            }
        }
    }
}
