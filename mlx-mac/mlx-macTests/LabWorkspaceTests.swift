import XCTest
import AppKit
import SwiftUI
@testable import mlx_workbench

final class LabWorkspaceTests: XCTestCase {
    @MainActor
    func testTrainingHistorySwitchPreservesJobsAndRejectsOldSuccessAndFailure() async throws {
        for fails in [false, true] {
            let fixture = WorkspaceRefreshFixture(), harness = try WorkspaceRefreshHarness(fixture)
            defer { fixture.releaseAll(); harness.cleanup() }
            let job = try JSONDecoder().decode(TrainingJob.self, from: Data(#"{"receipt":"r1","repo":"org/base","out":"/fixture/adapter","pid":42,"state":"done"}"#.utf8))
            let loader = TrainingLoader(jobs: { [job] }, history: { [] }, seededJobs: [job])
            XCTAssertTrue(harness.bindTraining(loader))
            await loader.refreshHistory()?.value
            XCTAssertEqual(loader.evaluations.first?.object?["id"]?.text, "eval_first_1")
            await loader.inspect("shared-evaluation")?.value
            XCTAssertNotNil(loader.inspection)
            XCTAssertFalse(harness.bindTraining(loader), "Refreshing the same workspace retains evidence")
            XCTAssertNotNil(loader.inspection)
            if fails { fixture.fail("first:training-history") }
            let oldGate = fixture.hold("first:training-history")
            let old = loader.refreshHistory()
            await expectWorkspaceCall(fixture, "first:training-history", count: 2)
            await harness.lab.useStore(harness.second)
            XCTAssertTrue(harness.bindTraining(loader))
            XCTAssertTrue(loader.evaluations.isEmpty)
            XCTAssertNil(loader.inspection)
            XCTAssertNil(loader.historyError)
            XCTAssertFalse(loader.hasLoadedHistory)
            XCTAssertEqual(loader.jobs.map(\.receipt), ["r1"])
            XCTAssertTrue(loader.hasLoadedJobs)
            let newGate = fixture.hold("second:training-history")
            let current = loader.refreshHistory()
            await expectWorkspaceCall(fixture, "second:training-history")
            oldGate.signal(); await old?.value
            XCTAssertTrue(loader.isLoadingHistory)
            XCTAssertTrue(loader.evaluations.isEmpty)
            XCTAssertNil(loader.historyError)
            newGate.signal(); await current?.value
            XCTAssertEqual(loader.evaluations.first?.object?["id"]?.text, "eval_second_1")
            XCTAssertFalse(loader.isLoadingHistory)
        }
    }

    @MainActor
    func testTrainingInspectionWithSameIDCannotCrossWorkspaceSwitch() async throws {
        for fails in [false, true] {
            let fixture = WorkspaceRefreshFixture(), harness = try WorkspaceRefreshHarness(fixture)
            defer { fixture.releaseAll(); harness.cleanup() }
            let loader = TrainingLoader(jobs: { [] }, history: { [] })
            harness.bindTraining(loader)
            if fails { fixture.fail("first:training-inspect") }
            let oldGate = fixture.hold("first:training-inspect")
            let old = loader.inspect("shared-evaluation")
            await expectWorkspaceCall(fixture, "first:training-inspect")
            await harness.lab.useStore(harness.second)
            harness.bindTraining(loader)
            XCTAssertNil(loader.inspectingID)
            let newGate = fixture.hold("second:training-inspect")
            let current = loader.inspect("shared-evaluation")
            await expectWorkspaceCall(fixture, "second:training-inspect")
            oldGate.signal(); await old?.value
            XCTAssertEqual(loader.inspectingID, "shared-evaluation")
            XCTAssertNil(loader.inspection)
            XCTAssertNil(loader.inspectionError)
            newGate.signal(); await current?.value
            XCTAssertEqual(loader.inspection?.response.report?.object?["prompt"]?.text, "second_1")
            XCTAssertEqual(loader.inspection?.workspace, harness.lab.workspaceContext)
            XCTAssertNil(loader.inspectingID)
            await harness.lab.useStore(harness.first)
            harness.bindTraining(loader)
            XCTAssertNil(loader.inspection, "Returning to a path cannot restore an old visit's evidence")
        }
    }

    @MainActor
    func testTrainingReviewKeepsDraftAndOutputsWhenWorkspaceChanged() async throws {
        let fixture = WorkspaceRefreshFixture(), harness = try WorkspaceRefreshHarness(fixture)
        defer { fixture.releaseAll(); harness.cleanup() }
        let workspace = harness.lab.workspaceContext
        let retained = try await harness.lab.request(LabRequest(operation: "training-inspect", evaluationID: "shared-evaluation"), in: workspace)
        let session = TrainingEvaluationSession(receipt: "", retained: retained) { try await harness.lab.request($0, in: workspace) }
        let sample = try XCTUnwrap(session.samples.first)
        var draft = session.draft(sample.id)
        draft.preference = "adapter"; draft.notes = "Keep this review"
        session.updateReview(sample.id, draft)
        XCTAssertTrue(session.canSaveReview)
        await harness.lab.useStore(harness.second)
        await session.saveReview()?.value
        XCTAssertEqual(fixture.count("first:training-review"), 0)
        XCTAssertEqual(fixture.count("second:training-review"), 0)
        XCTAssertEqual(session.result?.artifactSHA256, retained.artifactSHA256)
        XCTAssertEqual(session.draft(sample.id), draft)
        XCTAssertTrue(session.hasUnsavedReviews)
        XCTAssertNotNil(session.reviewError)
        XCTAssertNil(session.reviewNotice)
    }

    @MainActor
    func testScopedDialogRequestsRejectChangedWorkspacesBeforeDispatch() async throws {
        let fixture = WorkspaceRefreshFixture(), harness = try WorkspaceRefreshHarness(fixture)
        defer { fixture.releaseAll(); harness.cleanup() }
        let workspace = harness.lab.workspaceContext
        await harness.lab.refresh()
        XCTAssertTrue(harness.lab.isCurrent(workspace), "Refreshing must not invalidate an open dialog")
        _ = try await harness.lab.request(LabRequest(operation: "preview"), in: workspace)
        XCTAssertEqual(fixture.count("first:preview"), 1)
        await harness.lab.useStore(harness.second)
        for operation in ["recipe-catalog", "recipe-prepare", "create", "review-start", "review-media", "review-submit", "reveal", "study-submit", "study-create", "study-run", "training-preview", "training-evaluate", "training-review"] {
            do {
                _ = try await harness.lab.request(LabRequest(operation: operation), in: workspace)
                XCTFail("A stale dialog must not send " + operation)
            } catch { XCTAssertTrue(error is LabWorkspaceChangedError, "\(error)") }
            XCTAssertEqual(fixture.count("first:" + operation), 0)
            XCTAssertEqual(fixture.count("second:" + operation), 0)
        }
        await harness.lab.useStore(harness.first)
        XCTAssertFalse(harness.lab.isCurrent(workspace), "Returning to the same path requires a fresh dialog")
    }

    @MainActor
    func testScopedDialogsRejectLateRepliesAndFailuresWithoutRerouting() async throws {
        for operation in ["create", "review-submit", "training-evaluate", "training-review"] {
            for fails in [false, true] {
                let fixture = WorkspaceRefreshFixture(), harness = try WorkspaceRefreshHarness(fixture)
                defer { fixture.releaseAll(); harness.cleanup() }
                let workspace = harness.lab.workspaceContext
                if fails { fixture.fail("first:" + operation) }
                let gate = fixture.hold("first:" + operation)
                let pending = Task { try await harness.lab.request(LabRequest(operation: operation), in: workspace) }
                await expectWorkspaceCall(fixture, "first:" + operation)
                await harness.lab.useStore(harness.second)
                gate.signal()
                do { _ = try await pending.value; XCTFail("A late dialog reply must not be accepted") }
                catch { XCTAssertTrue(error is LabWorkspaceChangedError, "\(error)") }
                XCTAssertEqual(fixture.count("first:" + operation), 1)
                XCTAssertEqual(fixture.count("second:" + operation), 0)
                XCTAssertNil(harness.lab.error)
            }
        }
    }

    @MainActor
    func testReviewStartCannotContinueWithMediaFromAnotherWorkspace() async throws {
        let fixture = WorkspaceRefreshFixture(), harness = try WorkspaceRefreshHarness(fixture)
        defer { fixture.releaseAll(); harness.cleanup() }
        let workspace = harness.lab.workspaceContext
        let gate = fixture.hold("first:review-start")
        let pending = Task {
            _ = try await harness.lab.request(LabRequest(operation: "review-start"), in: workspace)
            return try await harness.lab.request(LabRequest(operation: "review-media"), in: workspace)
        }
        await expectWorkspaceCall(fixture, "first:review-start")
        await harness.lab.useStore(harness.second)
        gate.signal()
        do { _ = try await pending.value; XCTFail("The old review chain must stop") }
        catch { XCTAssertTrue(error is LabWorkspaceChangedError) }
        XCTAssertEqual(fixture.count("first:review-media"), 0)
        XCTAssertEqual(fixture.count("second:review-media"), 0)
    }

    @MainActor
    func testAuthorSheetKeepsItsOpenedWorkspaceWhenSwiftUIRebuildsIt() async throws {
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
        }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
        }
        func refreshButton(_ view: NSView) -> NSButton? {
            guard let scroll = scrollViews(view).max(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }) else { return nil }
            // Revision picker, Capture recipe and Refresh availability, in content order.
            let controls = buttons(scroll)
            return controls.count == 3 ? controls.last : nil
        }
        let fixture = WorkspaceRefreshFixture(), harness = try WorkspaceRefreshHarness(fixture)
        defer { fixture.releaseAll(); harness.cleanup() }
        let host = NSHostingView(rootView: LabAuthorSheet(lab: harness.lab).buttonStyle(.borderless))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        await expectWorkspaceCall(fixture, "first:recipe-catalog")
        for _ in 0..<100 where refreshButton(host)?.isEnabled != true { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(try XCTUnwrap(refreshButton(host), "Native buttons: \(buttons(host).map { String(describing: type(of: $0)) + ":" + $0.title })").isEnabled)
        await harness.lab.useStore(harness.second)
        host.rootView = LabAuthorSheet(lab: harness.lab).buttonStyle(.borderless)
        for _ in 0..<100 where refreshButton(host)?.isEnabled != false { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(try XCTUnwrap(refreshButton(host)).isEnabled)
        XCTAssertEqual(fixture.count("second:recipe-catalog"), 0)
        await harness.lab.useStore(harness.first)
        host.rootView = LabAuthorSheet(lab: harness.lab).buttonStyle(.borderless)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(try XCTUnwrap(refreshButton(host)).isEnabled)
    }

    @MainActor
    func testWorkspaceSwitchStartsItsOwnRefreshAndIgnoresOldCompletions() async throws {
        for operation in ["snapshot", "study-list"] {
            let fixture = WorkspaceRefreshFixture()
            let harness = try WorkspaceRefreshHarness(fixture)
            defer { fixture.releaseAll(); harness.cleanup() }
            let oldGate = fixture.hold("first:" + operation)
            let newGate = fixture.hold("second:study-list")
            let old = Task { await harness.lab.refresh() }
            await expectWorkspaceCall(fixture, "first:" + operation)
            let change = Task { await harness.lab.useStore(harness.second) }
            await expectWorkspaceCall(fixture, "second:study-list")
            XCTAssertEqual(harness.lab.store, harness.second)
            XCTAssertNil(harness.lab.snapshot.history)
            oldGate.signal()
            await old.value
            XCTAssertTrue(harness.lab.isRefreshing, "The old completion must not clear the new refresh's busy state")
            XCTAssertNil(harness.lab.snapshot.history, "Records publish only after both reads succeed")
            newGate.signal()
            await change.value
            XCTAssertEqual(harness.lab.snapshot.history?.items.first?.id, "exp_second_1")
            XCTAssertEqual(harness.lab.studies.first?.id, "study_second_1")
            XCTAssertFalse(harness.lab.isRefreshing)
            XCTAssertNil(harness.lab.error)
            if operation == "snapshot" { XCTAssertEqual(fixture.count("first:study-list"), 0) }
        }
    }

    @MainActor
    func testOldRefreshFailuresCannotReplaceANewWorkspacesResult() async throws {
        for operation in ["snapshot", "study-list"] {
            let fixture = WorkspaceRefreshFixture()
            let harness = try WorkspaceRefreshHarness(fixture)
            defer { fixture.releaseAll(); harness.cleanup() }
            fixture.fail("first:" + operation)
            let gate = fixture.hold("first:" + operation)
            let old = Task { await harness.lab.refresh() }
            await expectWorkspaceCall(fixture, "first:" + operation)
            harness.lab.error = "Old workspace error"; harness.lab.notice = "Old workspace notice"
            await harness.lab.useStore(harness.second)
            gate.signal()
            await old.value
            XCTAssertEqual(harness.lab.snapshot.history?.items.first?.id, "exp_second_1")
            XCTAssertEqual(harness.lab.studies.first?.id, "study_second_1")
            XCTAssertNil(harness.lab.error)
            XCTAssertNil(harness.lab.notice)
        }
    }

    @MainActor
    func testFailedStudyListRetainsThePreviousMatchingRecords() async throws {
        let fixture = WorkspaceRefreshFixture()
        let harness = try WorkspaceRefreshHarness(fixture)
        defer { fixture.releaseAll(); harness.cleanup() }
        await harness.lab.refresh()
        fixture.setVersion(2)
        fixture.fail("first:study-list")
        await harness.lab.refresh()
        XCTAssertEqual(harness.lab.snapshot.history?.items.first?.id, "exp_first_1")
        XCTAssertEqual(harness.lab.studies.first?.id, "study_first_1")
        XCTAssertNotNil(harness.lab.error)
        XCTAssertFalse(harness.lab.isRefreshing)
    }

    @MainActor
    func testReturningToAWorkspaceDoesNotAcceptItsFirstVisitsLateResponse() async throws {
        let fixture = WorkspaceRefreshFixture()
        let harness = try WorkspaceRefreshHarness(fixture)
        defer { fixture.releaseAll(); harness.cleanup() }
        let gate = fixture.hold("first:snapshot")
        let old = Task { await harness.lab.refresh() }
        await expectWorkspaceCall(fixture, "first:snapshot")
        await harness.lab.useStore(harness.second)
        fixture.setVersion(2)
        await harness.lab.useStore(harness.first)
        gate.signal()
        await old.value
        XCTAssertEqual(harness.lab.snapshot.history?.items.first?.id, "exp_first_2")
        XCTAssertEqual(harness.lab.studies.first?.id, "study_first_2")
    }

    @MainActor
    func testOldJobAndRecoveryResultsCannotChangeTheNewWorkspacesStatus() async throws {
        for (operation, fails) in [("run", false), ("run", true), ("recover", false), ("recover", true), ("cancel", false), ("cancel", true)] {
            let fixture = WorkspaceRefreshFixture()
            let harness = try WorkspaceRefreshHarness(fixture)
            defer { fixture.releaseAll(); harness.cleanup() }
            await harness.lab.refresh()
            let job = try XCTUnwrap(harness.lab.snapshot.queue?.first)
            if fails { fixture.fail("first:" + operation) }
            let gate = fixture.hold("first:" + operation)
            let old = Task {
                switch operation {
                case "run": await harness.lab.run(job)
                case "cancel": await harness.lab.cancel(job)
                default: await harness.lab.recover()
                }
            }
            await expectWorkspaceCall(fixture, "first:" + operation)
            await harness.lab.useStore(harness.second)
            harness.lab.error = "Current workspace error"
            harness.lab.notice = "Current workspace notice"
            gate.signal()
            await old.value
            XCTAssertEqual(harness.lab.snapshot.history?.items.first?.id, "exp_second_1")
            XCTAssertEqual(harness.lab.error, "Current workspace error", operation)
            XCTAssertEqual(harness.lab.notice, "Current workspace notice", operation)
            XCTAssertEqual(fixture.count("second:snapshot"), 1)
        }
    }

    @MainActor
    func testCancelledRefreshKeepsRecordsWithoutPublishingAnError() async throws {
        let fixture = WorkspaceRefreshFixture()
        let harness = try WorkspaceRefreshHarness(fixture)
        defer { fixture.releaseAll(); harness.cleanup() }
        await harness.lab.refresh()
        fixture.setVersion(2)
        let gate = fixture.hold("first:snapshot")
        let refresh = Task { await harness.lab.refresh() }
        await expectWorkspaceCall(fixture, "first:snapshot", count: 2)
        refresh.cancel()
        gate.signal()
        await refresh.value
        XCTAssertEqual(harness.lab.snapshot.history?.items.first?.id, "exp_first_1")
        XCTAssertEqual(harness.lab.studies.first?.id, "study_first_1")
        XCTAssertNil(harness.lab.error)
        XCTAssertFalse(harness.lab.isRefreshing)
    }

    @MainActor
    private func expectWorkspaceCall(_ fixture: WorkspaceRefreshFixture, _ key: String, count: Int = 1) async {
        for _ in 0..<100 {
            if fixture.count(key) >= count { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Workspace request did not start: " + key)
    }

    func testRecipeDraftPreservesInputsAndExplainsInvalidRanges() throws {
        var draft = StudyRecipeDraft()
        draft.revision = String(repeating: "a", count: 40)
        draft.prompt = "A boat on a lake"
        XCTAssertNil(draft.validationError)
        XCTAssertEqual(draft.settings?.object?["num_frames"], .integer(17))
        draft.width = "257"
        XCTAssertTrue(try XCTUnwrap(draft.validationError).contains("16"))
        XCTAssertNil(draft.settings)
        draft.width = "256"; draft.frames = "18"
        XCTAssertTrue(try XCTUnwrap(draft.validationError).contains("16n+1"))
        draft.frames = "17"; draft.guidance = "nan"
        XCTAssertNotNil(draft.validationError)
    }

    @MainActor
    func testRecipeCaptureInvalidatesAfterEditsAndFailureRetainsDraft() async throws {
        var fail = false
        var calls: [String] = []
        let session = StudyRecipeSession { request in
            calls.append(request.operation)
            if request.operation == "recipe-catalog" {
                return LabResponse(recipes: [StudyRecipeOption(modelID: "Wan-AI/Wan2.1-T2V-1.3B-Diffusers",
                    displayName: "Wan", revisions: [String(repeating: "a", count: 40)], unavailableReason: nil)])
            }
            if fail { throw NSError(domain: "capture", code: 1) }
            var fields = try XCTUnwrap(request.settings?.object)
            fields["model_revision"] = fields.removeValue(forKey: "revision")
            fields["model_id"] = .string("Wan-AI/Wan2.1-T2V-1.3B-Diffusers")
            fields["adapter_id"] = .string("diffusers.wan2.1-t2v-1.3b.mps.v1")
            fields["model_checksum"] = .string("sha256:" + String(repeating: "b", count: 64))
            fields["source_checksums"] = .object(["model_index.json": .string(String(repeating: "c", count: 64))])
            fields["runtime_versions"] = .object(["python": .string("3.12")])
            return LabResponse(manifest: .object(fields))
        }
        await session.load()
        session.draft.prompt = "A boat"
        await session.capture()
        XCTAssertNotNil(session.manifest)
        session.draft.seed = "43"
        XCTAssertNil(session.manifest)
        fail = true
        await session.capture()
        XCTAssertNil(session.manifest)
        XCTAssertNotNil(session.error)
        XCTAssertEqual(session.draft.prompt, "A boat")
        XCTAssertEqual(session.draft.seed, "43")
        XCTAssertEqual(calls, ["recipe-catalog", "recipe-prepare", "recipe-prepare"])
    }

    @MainActor
    func testRecipeCaptureRejectsMismatchedResponseAndUnavailableCatalog() async {
        var unavailable = true
        let session = StudyRecipeSession { request in
            if request.operation == "recipe-catalog" {
                return LabResponse(recipes: [StudyRecipeOption(modelID: "Wan-AI/Wan2.1-T2V-1.3B-Diffusers",
                    displayName: "Wan", revisions: unavailable ? [] : [String(repeating: "a", count: 40)],
                    unavailableReason: unavailable ? "No cached model" : nil)])
            }
            return LabResponse(manifest: .object(["model_revision": .string("wrong")]))
        }
        await session.load()
        session.draft.prompt = "A boat"
        XCTAssertFalse(session.canCapture)
        unavailable = false
        await session.load()
        await session.capture()
        XCTAssertNil(session.manifest)
        XCTAssertNotNil(session.error)
    }
    @MainActor
    func testStudiesViewReadsAnIsolatedRealWorkspaceWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let agent = environment["MLX_LAB_TEST_AGENT"] else {
            throw XCTSkip("Set MLX_LAB_TEST_AGENT to exercise the study page with the shared engine.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("studies-view-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "studies-view-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "mlx-workbench.lab-store")
        let lab = LabCoordinator(api: WorkbenchAPI(cli: CLIProcess(), agentPath: agent), defaults: defaults)
        let installer = RuntimeInstaller()
        for width: CGFloat in [1190, 814] {
            let host = NSHostingView(rootView: StudiesView(lab: lab, installer: installer, agentPath: agent)
                .environment(\.isRouteActive, false).frame(width: width, height: 900)
                .background(WorkbenchColor.canvas).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            if width == 1190 {
                XCTAssertNil(lab.snapshot.history)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("experiments.sqlite3").path))
            }
            lab.error = "Refresh pending"
            host.rootView = StudiesView(lab: lab, installer: installer, agentPath: agent)
                .environment(\.isRouteActive, true).frame(width: width, height: 900)
                .background(WorkbenchColor.canvas).preferredColorScheme(.dark)
            for _ in 0..<200 where lab.snapshot.history == nil || lab.isRefreshing || lab.error != nil { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertNil(lab.error)
            XCTAssertEqual(lab.snapshot.history?.items.count, 0)
            XCTAssertEqual(lab.snapshot.queue?.count, 0)
            XCTAssertNil(lab.runningJobID)
            XCTAssertEqual(installer.state, .idle)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("experiments.sqlite3").path))
            host.layoutSubtreeIfNeeded()
            if let folder = environment["MLX_WORKBENCH_COMPARISON_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: folder)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("studies-\(Int(width)).png"))
            }
        }
    }

    func testRequestPreservesFrozenRecipeAndChangesOneVariable() throws {
        let baseline = try JSONDecoder().decode(LabValue.self, from: Data(#"{"prompt":"A kite","seed":42,"inference_steps":4,"model_revision":"frozen"}"#.utf8))
        let draft = LabDraft(baseline: baseline, variablePath: "inference_steps", alternateValue: .integer(8))
        let request = LabRequest(operation: "preview", draft: draft)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let emitted = try XCTUnwrap(object["draft"] as? [String: Any])
        XCTAssertEqual(emitted["variable_path"] as? String, "inference_steps")
        XCTAssertEqual((emitted["baseline"] as? [String: Any])?["model_revision"] as? String, "frozen")
        XCTAssertEqual(emitted["alternate_value"] as? Int, 8)
    }

    func testSealedSnapshotDecodesWithoutCanonicalMetadata() throws {
        let data = Data(#"{"history":{"items":[{"id":"exp_one","sealed":true,"states":["queued","queued"],"evidence_completeness":"pending"}]},"queue":[{"id":"job_one","experiment_id":"exp_one","state":"queued","error":null}]}"#.utf8)
        let response = try JSONDecoder().decode(LabResponse.self, from: data)
        XCTAssertEqual(response.history?.items.first?.id, "exp_one")
        XCTAssertTrue(try XCTUnwrap(response.history?.items.first?.sealed))
        XCTAssertEqual(response.queue?.first?.state, "queued")
    }

    func testLiveAgentWorkspaceSnapshot() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let agent = environment["MLX_LAB_TEST_AGENT"] else {
            throw XCTSkip("Set MLX_LAB_TEST_AGENT to exercise the shared engine.")
        }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: store) }
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: agent)
        let response = try await api.labWorkspace(request: LabRequest(operation: "snapshot"),
                                                  store: store, reviewer: "native-contract")
        XCTAssertEqual(response.history?.items.count, 0)
        XCTAssertEqual(response.queue?.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent("experiments.sqlite3").path))
    }
}

@MainActor
private final class WorkspaceRefreshHarness {
    let first: URL
    let second: URL
    let lab: LabCoordinator
    private let defaults: UserDefaults
    private let suite = "workspace-refresh-" + UUID().uuidString
    init(_ fixture: WorkspaceRefreshFixture) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        first = root.appendingPathComponent("first"); second = root.appendingPathComponent("second")
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(first.path, forKey: "mlx-workbench.lab-store")
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: "/fixture", command: { _, argv, _, _ in try fixture.run(argv) })
        lab = LabCoordinator(api: api, defaults: defaults)
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite) }
    @discardableResult
    func bindTraining(_ loader: TrainingLoader) -> Bool {
        let context = lab.workspaceContext
        return loader.bindWorkspace(context,
            history: { try await self.lab.request(LabRequest(operation: "training-history"), in: context).evaluations ?? [] },
            inspect: { try await self.lab.request(LabRequest(operation: "training-inspect", evaluationID: $0), in: context) })
    }
}

/// Controls callback order while exercising the production coordinator and API actor.
private final class WorkspaceRefreshFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: DispatchSemaphore] = [:]
    private var gates: [DispatchSemaphore] = []
    private var calls: [String] = []
    private var failures: Set<String> = []
    private var version = 1
    func hold(_ key: String) -> DispatchSemaphore {
        lock.withLock {
            let gate = DispatchSemaphore(value: 0)
            pending[key] = gate; gates.append(gate)
            return gate
        }
    }
    func fail(_ key: String) { lock.withLock { _ = failures.insert(key) } }
    func setVersion(_ value: Int) { lock.withLock { version = value } }
    func count(_ key: String) -> Int { lock.withLock { calls.filter { $0 == key }.count } }
    func releaseAll() { lock.withLock { gates }.forEach { $0.signal() } }
    func run(_ argv: [String]) throws -> [String: Any] {
        let database = argv[try XCTUnwrap(argv.firstIndex(of: "--database")) + 1]
        let file = argv[try XCTUnwrap(argv.firstIndex(of: "--request")) + 1]
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
        let operation = try XCTUnwrap(request["operation"] as? String)
        let workspace = URL(fileURLWithPath: database).deletingLastPathComponent().lastPathComponent
        let key = workspace + ":" + operation
        let (gate, fails, version) = lock.withLock {
            calls.append(key)
            return (pending.removeValue(forKey: key), failures.contains(key), self.version)
        }
        if let gate, gate.wait(timeout: .now() + 10) != .success { throw NSError(domain: "fixture-timeout", code: 1) }
        if fails { throw NSError(domain: "fixture-refresh-failure", code: 1) }
        let suffix = workspace + "_" + String(version)
        if operation == "snapshot" {
            return ["history": ["items": [["id": "exp_" + suffix, "sealed": true, "states": ["queued"], "evidence_completeness": "pending"]]],
                    "queue": [["id": "job_" + suffix, "experiment_id": "exp_" + suffix, "state": "queued"]]]
        }
        if operation == "study-list" { return ["studies": [["study_id": "study_" + suffix]]] }

        if operation == "training-history" { return ["evaluations": [["id": "eval_" + suffix]]] }
        if operation == "training-inspect" {
            return ["evaluation_id": request["evaluation_id"] ?? "shared-evaluation",
                    "artifact_sha256": String(repeating: "a", count: 64),
                    "report": ["schema_version": "text-training-evaluation/1", "prompt": suffix,
                               "max_tokens": 128, "preview_hash": "reviewed",
                               "outputs": ["baseline": "Base", "adapter": "Tuned"]]]
        }
        if operation == "recipe-catalog" {
            return ["recipes": [["model_id": "Wan-AI/Wan2.1-T2V-1.3B-Diffusers", "display_name": "Wan",
                                 "revisions": [String(repeating: "a", count: 40)]]]]
        }
        return ["status": "completed"]
    }
}
