import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

// MARK: - Fixtures

private enum TF {
    static let home = "/Users/fixture"
    static let now = Date(timeIntervalSinceReferenceDate: 1_000_000_000)

    static func job(_ state: String, repo: String = "org/base-model", out: String = "/Users/fixture/adapters/run-1",
                    pid: Int = 42, log: String? = "/tmp/run.log", identity: Bool = true, receipt: String = "r1") throws -> TrainingJob {
        var object: [String: Any] = ["receipt": receipt, "repo": repo, "out": out, "pid": pid, "state": state]
        if let log { object["log_path"] = log }
        if identity { object["adapter_identity"] = ["sha256": "abc123", "files": ["adapters.safetensors"]] }
        return try JSONDecoder().decode(TrainingJob.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func evaluation(_ id: String, created: String?) throws -> LabValue {
        var object: [String: Any] = ["id": id]
        if let created { object["created_at"] = created }
        return try JSONDecoder().decode(LabValue.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static let formatter = ISO8601DateFormatter()
}

private struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }

// MARK: - Presentation

final class TrainingPresentationTests: XCTestCase {
    func testEveryAgentStateMapsToAStatus() throws {
        let running = TrainingJobRow(job: try TF.job("running"), home: TF.home).status
        XCTAssertEqual(running.label, "Running")
        XCTAssertTrue(running.isLive)
        let done = TrainingJobRow(job: try TF.job("done"), home: TF.home).status
        XCTAssertEqual(done.label, "Completed")
        XCTAssertFalse(done.isLive)
        XCTAssertEqual(done.tone, .success)
        XCTAssertNotEqual(done.tone, running.tone)
        let failed = TrainingJobRow(job: try TF.job("failed"), home: TF.home).status
        XCTAssertEqual(failed.label, "Failed")
        XCTAssertEqual(failed.tone, .failure)
        let stopped = TrainingJobRow(job: try TF.job("stopped"), home: TF.home).status
        XCTAssertEqual(stopped.label, "Stopped")
        XCTAssertEqual(stopped.tone, .neutral)
    }

    func testUnknownStateKeepsItsOwnWording() throws {
        let status = TrainingJobRow(job: try TF.job("waiting_for_gpu_slot"), home: TF.home).status
        XCTAssertEqual(status.label, "Waiting For Gpu Slot")
        XCTAssertEqual(status.tone, .neutral)
        let odd = TrainingJobRow(job: try TF.job("rebalancing"), home: TF.home).status
        XCTAssertEqual(odd.label, "Rebalancing")
        XCTAssertEqual(odd.tone, .neutral)
        XCTAssertFalse(odd.isLive)
    }

    func testEmptyStatesAreSelectedByContent() throws {
        let empty = TrainingPresentation.make(jobs: [], evaluations: [], home: TF.home, now: TF.now)
        XCTAssertTrue(empty.showsNoJobs)
        XCTAssertTrue(empty.showsNoEvaluations)
        XCTAssertEqual(TrainingPresentation.noJobsSentence, "No training jobs yet. Preview and confirm a fine-tune to start one.")
        let filled = TrainingPresentation.make(
            jobs: [try TF.job("done")], evaluations: [try TF.evaluation("abcdef0123456789", created: nil)], home: TF.home, now: TF.now
        )
        XCTAssertFalse(filled.showsNoJobs)
        XCTAssertFalse(filled.showsNoEvaluations)
    }

    func testALoadFailureReplacesTheEmptySentenceWithItsOwn() throws {
        let failed = TrainingPresentation.make(jobs: [], evaluations: [], jobsError: "usage: mlx-agent", historyError: "usage: mlx-agent", home: TF.home, now: TF.now)
        XCTAssertFalse(failed.showsNoJobs)
        XCTAssertFalse(failed.showsNoEvaluations)
        XCTAssertEqual(failed.jobsError, "usage: mlx-agent")
        XCTAssertEqual(TrainingPresentation.jobsFailureSentence, "Training jobs couldn't load.")
        XCTAssertEqual(TrainingPresentation.evaluationsFailureSentence, "Evaluations couldn't load.")
        let historyOnly = TrainingPresentation.make(jobs: [], evaluations: [], historyError: "boom", home: TF.home, now: TF.now)
        XCTAssertTrue(historyOnly.showsNoJobs)
        XCTAssertFalse(historyOnly.showsNoEvaluations)
    }

    func testBaseModelsAreTheSortedCachedRepoIDs() {
        func model(_ path: String) -> LibraryModel {
            let item = ModelItem(
                path: path, name: "m", bytes: 1, modifiedAt: nil, shard: nil, modelKey: "m", architecture: nil,
                quantization: nil, parameters: nil, structure: nil, signature: nil, companion: nil, readable: true,
                status: "ready", outputs: [], tensorCount: nil, error: nil, task: nil
            )
            return LibraryModel(item: item, readiness: .ready)
        }
        let snapshot = LibrarySnapshot(
            models: [
                model("/c/models--org--zeta/snapshots/a"), model("/c/models--org--alpha/snapshots/b"),
                model("/c/models--org--alpha/snapshots/c"), model("/models/local-mlx"),
            ],
            groups: [], hardware: HardwareProfile(chip: "Test", model: nil, memoryBytes: 0, macOSVersion: nil),
            generatedAt: TF.now
        )
        XCTAssertEqual(TrainingPresentation.baseModels(snapshot), ["org/alpha", "org/zeta"])
        XCTAssertEqual(TrainingPresentation.baseModels(nil), [])
    }

    func testTypingACachedIDKeepsTheFieldAndPickingItHidesTheField() {
        let cached = ["org/alpha", "org/zeta"]
        var choice = TrainingBaseModelChoice()
        XCTAssertTrue(choice.showsField(cached: cached))
        XCTAssertEqual(choice.selection(repo: "org/alpha", cached: cached), "")
        XCTAssertTrue(choice.showsField(cached: cached), "typing a cached id must not hide the focused field")
        XCTAssertEqual(choice.select("org/alpha"), "org/alpha")
        XCTAssertFalse(choice.showsField(cached: cached))
        XCTAssertEqual(choice.selection(repo: "org/alpha", cached: cached), "org/alpha")
        XCTAssertEqual(choice.select(""), "")
        XCTAssertTrue(choice.showsField(cached: cached))
        XCTAssertTrue(TrainingBaseModelChoice().showsField(cached: []))
    }

    func testRetainedEvidenceCarriesTheInspectedShortID() {
        let evidence = TrainingRetainedEvidence(evaluationID: "0123456789abcdef", reportText: "{}", sha256: "ff")
        XCTAssertEqual(evidence.shortID, "01234567")
    }

    func testJobRowValuesAndActionsFollowTheState() throws {
        let done = TrainingJobRow(job: try TF.job("done"), home: TF.home)
        XCTAssertEqual(done.outputPath, "~/adapters/run-1")
        XCTAssertEqual(done.repo, "org/base-model")
        XCTAssertTrue(done.canCompare)
        XCTAssertFalse(done.canCancel)
        XCTAssertEqual(done.logPath, "/tmp/run.log")

        let doneWithoutIdentity = TrainingJobRow(job: try TF.job("done", identity: false), home: TF.home)
        XCTAssertFalse(doneWithoutIdentity.canCompare)
        XCTAssertNil(doneWithoutIdentity.adapterIdentity)

        let running = TrainingJobRow(job: try TF.job("running", log: nil, identity: false), home: TF.home)
        XCTAssertTrue(running.canCancel)
        XCTAssertFalse(running.canCompare)
        XCTAssertNil(running.logPath)

        let failed = TrainingJobRow(job: try TF.job("failed"), home: TF.home)
        XCTAssertFalse(failed.canCancel)
        XCTAssertFalse(failed.canCompare)
    }

    func testPathAbbreviationOnlyTouchesTheHomePrefix() {
        XCTAssertEqual(TrainingPresentation.abbreviated("/Users/fixture/a/b", home: "/Users/fixture"), "~/a/b")
        XCTAssertEqual(TrainingPresentation.abbreviated("/Users/fixture", home: "/Users/fixture"), "~")
        XCTAssertEqual(TrainingPresentation.abbreviated("/Users/fixtures/a", home: "/Users/fixture"), "/Users/fixtures/a")
        XCTAssertEqual(TrainingPresentation.abbreviated("/Volumes/x/a", home: "/Users/fixture"), "/Volumes/x/a")
        XCTAssertEqual(TrainingPresentation.abbreviated("/Volumes/x/a", home: nil), "/Volumes/x/a")
    }

    func testEvaluationRowsShowAShortIDAndARelativeDate() throws {
        let created = Date(timeIntervalSinceReferenceDate: 1_000_000_000 - 7_200)
        let raw = TF.formatter.string(from: created)
        let rows = TrainingPresentation.make(
            jobs: [], evaluations: [try TF.evaluation("0123456789abcdef", created: raw)], home: TF.home, now: TF.now
        ).evaluations
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "0123456789abcdef")
        XCTAssertEqual(rows[0].shortID, "01234567")
        XCTAssertEqual(rows[0].dateText, WorkbenchRelativeTime.text(for: created, style: .full, now: TF.now))
        XCTAssertNotEqual(rows[0].dateText, raw)
    }

    func testEvaluationDatesFallBackToTheirOwnText() throws {
        XCTAssertEqual(TrainingPresentation.dateText("yesterday-ish", now: TF.now), "yesterday-ish")
        let row = try XCTUnwrap(TrainingEvaluationRow(value: TF.evaluation("short", created: nil), now: TF.now))
        XCTAssertEqual(row.shortID, "short")
        XCTAssertNil(row.dateText)
        let noID = try JSONDecoder().decode(LabValue.self, from: Data(#"{"created_at":"x"}"#.utf8))
        XCTAssertNil(TrainingEvaluationRow(value: noID, now: TF.now))
    }
}

// MARK: - Loader

@MainActor
final class TrainingLoaderTests: XCTestCase {
    func testJobsSurviveAHistoryFailure() async throws {
        let job = try TF.job("running")
        let loader = TrainingLoader(jobs: { [job] }, history: { throw Boom() }, render: { $0.localizedDescription })
        await loader.refresh()
        XCTAssertEqual(loader.jobs.map(\.id), ["r1"])
        XCTAssertNil(loader.jobsError)
        XCTAssertEqual(loader.historyError, "boom")
    }

    func testHistorySurvivesAJobsFailure() async throws {
        let evaluation = try TF.evaluation("e1", created: nil)
        let loader = TrainingLoader(jobs: { throw Boom() }, history: { [evaluation] }, render: { $0.localizedDescription })
        await loader.refresh()
        XCTAssertEqual(loader.evaluations, [evaluation])
        XCTAssertEqual(loader.jobsError, "boom")
        XCTAssertNil(loader.historyError)
    }

    func testAFailedRefreshKeepsWhatLoadedBeforeAndARetryClearsTheError() async throws {
        let job = try TF.job("done")
        var failing = false
        let loader = TrainingLoader(
            jobs: { if failing { throw Boom() }; return [job] }, history: { [] }, render: { $0.localizedDescription }
        )
        await loader.refresh()
        failing = true
        await loader.refresh()
        XCTAssertEqual(loader.jobs.count, 1)
        XCTAssertEqual(loader.jobsError, "boom")
        failing = false
        await loader.refresh()
        XCTAssertNil(loader.jobsError)
    }

    private func yieldUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
    }

    func testHistoryPublishesWhileJobsAreStillLoading() async throws {
        let evaluation = try TF.evaluation("e1", created: nil)
        var release: CheckedContinuation<[TrainingJob], Never>?
        let loader = TrainingLoader(
            jobs: { await withCheckedContinuation { release = $0 } }, history: { [evaluation] },
            render: { $0.localizedDescription }
        )
        let refresh = Task { await loader.refresh() }
        await yieldUntil { !loader.evaluations.isEmpty }
        XCTAssertEqual(loader.evaluations, [evaluation])
        XCTAssertTrue(loader.jobs.isEmpty)
        release?.resume(returning: [try TF.job("running")])
        await refresh.value
        XCTAssertEqual(loader.jobs.map(\.id), ["r1"])
    }

    func testAStaleRefreshNeverOverwritesANewerOne() async throws {
        let stale = try TF.job("running", receipt: "stale"), fresh = try TF.job("done", receipt: "fresh")
        var calls = 0
        var release: CheckedContinuation<[TrainingJob], Never>?
        let loader = TrainingLoader(
            jobs: {
                calls += 1
                if calls == 1 { return await withCheckedContinuation { release = $0 } }
                return [fresh]
            }, history: { [] }, render: { $0.localizedDescription }
        )
        let first = Task { await loader.refresh() }
        await yieldUntil { release != nil }
        await loader.refresh()
        XCTAssertEqual(loader.jobs.map(\.id), ["fresh"])
        release?.resume(returning: [stale])
        await first.value
        XCTAssertEqual(loader.jobs.map(\.id), ["fresh"])
    }
}

// MARK: - Source

final class TrainingSourceTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/UI/Views/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testNoInlineJSONDumps() throws {
        for name in ["TrainingView.swift", "TrainingViews.swift", "TrainingPresentation.swift"] {
            let text = try source(name)
            XCTAssertFalse(text.contains(".jsonText).font("), "\(name) draws raw JSON outside a disclosure")
            if name != "TrainingPresentation.swift" {
                XCTAssertFalse(text.contains("job.state)"), "\(name) shows the raw agent state")
            }
        }
    }

    func testRefreshRunsOnlyWhileTheRouteIsActive() throws {
        let text = try source("TrainingView.swift")
        XCTAssertTrue(text.contains(".task(id: isRouteActive)"))
        XCTAssertTrue(text.contains("guard isRouteActive else { return }"))
    }

    func testEveryBorderedButtonIsSmall() throws {
        let lines = try source("TrainingViews.swift").components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where line.contains(".buttonStyle(.bordered)") {
            let nearby = lines[index...].prefix(2).joined()
            XCTAssertTrue(nearby.contains(".controlSize(.small)"), "line \(index + 1) is not small")
        }
    }

    func testThereIsOneStatusBadge() throws {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("mlx-mac/UI")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: ui, includingPropertiesForKeys: nil))
        var declarations = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            declarations += text.components(separatedBy: "\n").filter {
                $0.range(of: #"^\s*(private |fileprivate )?struct \w*StatusBadge\b"#, options: .regularExpression) != nil
            }.count
        }
        XCTAssertEqual(declarations, 1)
    }

    func testUITestAnchorsStay() throws {
        let text = try source("TrainingView.swift")
        for anchor in ["LoRA fine-tune", "Base model repo id", "Dataset path", "Preview Training", "Confirm & Train"] {
            XCTAssertTrue(text.contains("\"\(anchor)\""), anchor)
        }
        XCTAssertTrue(text.contains(#"TextField("Iterations""#))
    }
}

// MARK: - Renders

@MainActor
final class TrainingRenderTests: XCTestCase {
    private func config() -> Config {
        Config(
            schemaVersion: Config.SCHEMA_VERSION, ggufRoots: ["/m"], mlxRoots: [], outputDir: "/out/mlx",
            mlxAgentPath: "/agent", quarantineDir: "/quarantine", qBits: 4, signatures: true, host: "127.0.0.1",
            port: 8765, verificationEnabled: true, watchEnabled: true, fitReserveGB: 4, reclaimStaleDays: 60,
            comparisonMaxTokens: 512
        )
    }

    private func host() -> AppHost {
        AppHost(
            config: config(), discoveredRoots: [], configPath: "/state/config.json", agentHealth: .notConfigured,
            runtimeReport: RuntimeReport(
                convert: ConvertStatus(ok: true, modules: [:], executables: [:], missingModules: [], missingExecutables: [], install: "make install", message: "Ready."),
                serve: ServeStatus(ok: true, executables: [:], missingExecutables: [], install: "make install", message: "Ready."),
                install: "make install", ok: true
            ), hardwareProfile: HardwareProfile(chip: "Apple M4 Max", model: nil, memoryBytes: 137_438_953_472, macOSVersion: nil),
            modelWorkflowAPI: ModelWorkflowAPI(
                convertPreview: { _, _, _ in [:] }, convertStart: { _, _, _, _ in [:] }, convertStatus: { [] },
                servePreview: { _, _, _ in [:] }, serveStart: { _, _, _, _ in [:] }, serveStatus: { [] }, serveStop: { _ in [:] }
            ),
            modelWorkflowPersistence: ModelWorkflowPersistence(load: { [] }, upsert: { _ in })
        )
    }

    private func attach<Content: View>(_ view: Content, name: String, viewport: CGFloat, dark: Bool, height: CGFloat = 1300) async throws {
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

    private func loader(jobs: [TrainingJob], evaluations: [LabValue], jobsError: String? = nil, historyError: String? = nil) -> TrainingLoader {
        func failure(_ text: String) -> NSError { NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        return TrainingLoader(
            jobs: { if let jobsError { throw failure(jobsError) }; return jobs },
            history: { if let historyError { throw failure(historyError) }; return evaluations },
            render: { $0.localizedDescription },
            seededJobs: jobs, seededEvaluations: evaluations
        )
    }

    func testEveryStateRendersDarkAndLightAtEveryWidth() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let jobs = [
            try TF.job("running", repo: "mlx-community/Llama-3.2-3B-Instruct-4bit", out: "/Users/fixture/adapters/a-very-long-output-directory/llama-3b-lora-run-0007", identity: false, receipt: "r1"),
            try TF.job("done", repo: "mlx-community/Qwen3-8B-4bit", out: "/Users/fixture/adapters/qwen", receipt: "r2"),
            try TF.job("failed", repo: "org/base-model", out: "/Users/fixture/adapters/failed", identity: false, receipt: "r3"),
            try TF.job("rebalancing", repo: "org/other", out: "/Users/fixture/adapters/other", log: nil, identity: false, receipt: "r4"),
        ]
        let evaluations = [
            try TF.evaluation("0123456789abcdef", created: TF.formatter.string(from: Date().addingTimeInterval(-7_200))),
            try TF.evaluation("fedcba9876543210", created: TF.formatter.string(from: Date().addingTimeInterval(-259_200))),
        ]
        struct Scenario {
            let name: String
            let loader: TrainingLoader
            var planned = false
            var retained: TrainingRetainedEvidence?
        }
        let report = #"{"adapter":"qwen","outputs":[{"prompt":"hello","base":"hi","tuned":"hello there"}],"recipe":{"iters":100}}"#
        let scenarios = [
            Scenario(name: "empty", loader: loader(jobs: [], evaluations: [])),
            Scenario(name: "jobs", loader: loader(jobs: jobs, evaluations: evaluations)),
            Scenario(name: "jobs-error", loader: loader(jobs: [], evaluations: evaluations, jobsError: "usage: mlx-agent train status [-h] --json\nmlx-agent: error: unrecognized arguments")),
            Scenario(name: "history-error", loader: loader(jobs: jobs, evaluations: [], historyError: "usage: mlx-agent lab [-h] operation\nmlx-agent: error: the following arguments are required")),
            Scenario(
                name: "inspected", loader: loader(jobs: jobs, evaluations: evaluations),
                retained: TrainingRetainedEvidence(evaluationID: "0123456789abcdef", reportText: report, sha256: "9f2c4e7a1b0d")
            ),
            Scenario(name: "plan", loader: loader(jobs: jobs, evaluations: evaluations), planned: true),
        ]
        for scenario in scenarios {
            await scenario.loader.refresh()
            if scenario.name == "jobs-error" { XCTAssertNotNil(scenario.loader.jobsError) }
            if scenario.name == "history-error" { XCTAssertNotNil(scenario.loader.historyError) }
            for dark in [true, false] {
                for width in [CGFloat(1220), 824, 514] {
                    let session = TrainingSession(preview: { _ in ["preview_hash": "h"] }, start: { _, _ in })
                    if scenario.planned {
                        session.draft = TrainingDraft(repo: "org/base-model", data: "/Users/fixture/data", iterations: "100", output: "")
                        await session.previewTraining()?.value
                    }
                    let view = TrainingView(appHost: host(), loader: scenario.loader, session: session, seedRetained: scenario.retained)
                    try await attach(view.environment(\.isRouteActive, false), name: "training-\(scenario.name)", viewport: width, dark: dark)
                }
            }
        }
    }
}
