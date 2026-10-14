import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

@MainActor
final class VerificationCoordinatorTests: XCTestCase {
    func testProfileComparisonStagesDistinctSettingsWithoutSavingOrServing() throws {
        let store = JSONStore<ServingProfile>(fileURL: temporaryURL("profiles.json"))
        let baseline = managementProfile()
        let candidate = ServingProfile(id: UUID(), name: "Tuned", modelPath: baseline.modelPath,
            options: StrataComparisonOptions(speculation: true, expertMemoryGB: 4, contextTokens: 8192))
        try store.replaceAll([baseline, candidate])
        let coordinator = managementCoordinator(store), bytes = try Data(contentsOf: store.url)
        let setup = try coordinator.prepareComparison(baseline: baseline, candidate: candidate)
        let lanes = setup.lanes(signature: "fresh")
        XCTAssertEqual(lanes.count, 2)
        XCTAssertEqual(Set(lanes.map(\.id)).count, 2)
        XCTAssertEqual(lanes.map(\.modelPath), [baseline.modelPath, baseline.modelPath])
        XCTAssertEqual(lanes.map(\.strataOptions), [baseline.options, candidate.options])
        XCTAssertEqual(lanes.map(\.servingProfileName), [baseline.name, candidate.name])
        XCTAssertEqual(lanes.map(\.servingProfileID), [baseline.id, candidate.id])
        XCTAssertEqual(lanes.map(\.modelSignature), ["fresh", "fresh"])
        XCTAssertEqual(try JSONDecoder().decode([ComparisonLaneConfiguration].self, from: JSONEncoder().encode(lanes)), lanes)
        let namedRun = ComparisonRun(id: UUID(), promptSetID: "p", promptSetName: "p", useCase: nil,
            variants: lanes.map(\.modelPath), results: [], startedAt: Date(), finishedAt: Date(), state: .completed, laneConfigurations: lanes)
        XCTAssertEqual(ComparePresentation.lanes(for: namedRun).map(\.profileName), [baseline.name, candidate.name])
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        XCTAssertThrowsError(try coordinator.prepareComparison(baseline: baseline, candidate: baseline))
        var identical = candidate; identical.options = baseline.options
        XCTAssertThrowsError(try ServingProfileComparisonSetup(baseline: baseline, candidate: identical))
        let other = ServingProfile(id: UUID(), name: "Other", modelPath: "/Models/other", options: candidate.options)
        XCTAssertThrowsError(try ServingProfileComparisonSetup(baseline: baseline, candidate: other))
        var renamed = candidate; renamed.name = "Changed"
        try store.upsert(renamed, id: \.id)
        XCTAssertThrowsError(try coordinator.prepareComparison(baseline: baseline, candidate: candidate))
        XCTAssertFalse(candidate.hasPassedVerification)
        XCTAssertEqual(try store.load().first { $0.id == baseline.id }, baseline)
    }

    func testProfileCopyPreservesOriginalAndRequiresFreshVerification() throws {
        let store = JSONStore<ServingProfile>(fileURL: temporaryURL("profiles.json"))
        var original = managementProfile(); original.sourceRunID = UUID(); original.sourceLaneID = "lane"
        try store.upsert(original, id: \.id)
        let coordinator = managementCoordinator(store)
        var draft = ServingProfileCopyDraft(original: original)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertNil(draft.validationError)
        let unchanged = try XCTUnwrap(coordinator.createCopy(draft))
        XCTAssertNotEqual(unchanged.id, original.id)
        XCTAssertEqual(unchanged.modelPath, original.modelPath)
        XCTAssertEqual(unchanged.options, original.options)
        XCTAssertEqual(unchanged.sourceRunID, original.sourceRunID)
        XCTAssertEqual(unchanged.sourceLaneID, original.sourceLaneID)
        XCTAssertNil(unchanged.verification)
        XCTAssertFalse(unchanged.hasPassedVerification)
        draft.name = "Tuned"; draft.options.speculation = true; draft.options.expertMemoryGB = 4; draft.options.contextTokens = 32768
        XCTAssertTrue(draft.hasChanges)
        let tuned = try XCTUnwrap(coordinator.createCopy(draft))
        XCTAssertEqual(tuned.options, draft.options)
        XCTAssertNil(tuned.sourceRunID); XCTAssertNil(tuned.sourceLaneID)
        XCTAssertNil(tuned.verification)
        XCTAssertEqual(try store.load().first { $0.id == original.id }, original)
        XCTAssertThrowsError(try coordinator.resolve(tuned))
        let bytes = try Data(contentsOf: store.url)
        draft.name = "\n"
        XCTAssertNotNil(draft.validationError); XCTAssertNil(coordinator.createCopy(draft))
        draft.name = "Invalid"; draft.options.expertMemoryGB = .nan
        XCTAssertNotNil(draft.validationError); XCTAssertNil(coordinator.createCopy(draft))
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        draft = ServingProfileCopyDraft(original: original)
        var renamed = original; renamed.name = "Changed"
        try store.upsert(renamed, id: \.id)
        XCTAssertNil(coordinator.createCopy(draft))
        XCTAssertEqual(try store.load().count, 3)
    }

    func testProfileCopySaveFailurePreservesStoreAndPublishedProfiles() throws {
        let store = JSONStore<ServingProfile>(fileURL: temporaryURL("profiles.json")) { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let original = managementProfile()
        try store.upsert(original, id: \.id)
        let coordinator = managementCoordinator(store), bytes = try Data(contentsOf: store.url)
        XCTAssertNil(coordinator.createCopy(ServingProfileCopyDraft(original: original)))
        XCTAssertNotNil(coordinator.lastError)
        XCTAssertEqual(coordinator.profiles, [original])
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
    }

    func testProfileEvidenceReadsDurableSourceAndRefusesMismatchesWithoutWriting() throws {
        let store = JSONStore<ServingProfile>(fileURL: temporaryURL("profiles.json"))
        let source = JSONStore<ComparisonRun>(fileURL: temporaryURL("comparisons.json"))
        var profile = managementProfile()
        profile.sourceRunID = UUID(); profile.sourceLaneID = "lane"
        let evidence = try XCTUnwrap(ProbeServingEvidence(plan: ["runtime": "strata", "preview_hash": "preview",
            "strata_model_fingerprint": "model", "strata_runtime_fingerprint": "runtime", "strata_speculation": false,
            "strata_expert_memory_gb": 2.0, "strata_context_tokens": 8192]))
        let memory = SystemMemoryEvidence(totalBytes: 64_000_000_000, baselineAvailableBytes: 30_000_000_000,
            minimumAvailableBytes: 25_000_000_000, endingAvailableBytes: 28_000_000_000, sampleCount: 10,
            missedSamples: 1, startedAt: Date(), endedAt: Date(), samplingIntervalSeconds: 0.5)
        let result = VariantResult(modelPath: profile.modelPath, modelSignature: "model",
            samples: [ComparisonSample(promptID: "p", outputExcerpt: "323", tokensPerSecond: 10, timeToFirstTokenSeconds: 1,
                error: nil, finishReason: "stop", timeToFirstAnswerSeconds: 2)], aggregateTokensPerSecond: 10,
            aggregateTTFTSeconds: 1, error: nil, servingEvidence: evidence, laneID: "lane", systemMemory: memory)
        let run = ComparisonRun(id: profile.sourceRunID!, promptSetID: "p", promptSetName: "Arithmetic", useCase: nil,
            variants: [profile.modelPath], results: [result], startedAt: Date(), finishedAt: Date(), state: .completed,
            qualityReviews: ["lane": ComparisonQualityReview(score: 5, rubricID: ComparisonQualityReview.taskOutcomeRubric, reviewedAt: Date())])
        try store.upsert(profile, id: \.id); try source.upsert(run, id: \.id)
        let originalProfiles = try Data(contentsOf: store.url), originalRuns = try Data(contentsOf: source.url)
        let comparison = ComparisonCoordinator(probe: ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "unused" },
            start: { _, _, _ in XCTFail("Evidence inspection must not load a model") }, stop: { _ in }), prober: OpenAIEndpointProber()),
            runStore: source, promptSetStore: JSONStore(fileURL: temporaryURL("prompts.json")))
        let coordinator = managementCoordinator(store)
        coordinator.comparisonSource = { try comparison.recordedRun(id: $0) }
        let read = try coordinator.comparisonEvidence(for: profile)
        XCTAssertEqual(read.result.memoryTradeoffAnswerSeconds, 2)
        XCTAssertEqual(read.memory?.minimumAvailableBytes, 25_000_000_000)
        XCTAssertEqual(read.taskReview?.score, 5)
        var incomplete = run
        incomplete.results[0] = VariantResult(modelPath: result.modelPath, modelSignature: result.modelSignature,
            samples: result.samples, aggregateTokensPerSecond: result.aggregateTokensPerSecond,
            aggregateTTFTSeconds: result.aggregateTTFTSeconds, error: nil, servingEvidence: evidence, laneID: "lane")
        incomplete.qualityReviews = nil
        let withoutOptionalMetrics = try ServingProfileComparisonEvidence(profile: profile, run: incomplete)
        XCTAssertNil(withoutOptionalMetrics.memory)
        XCTAssertNil(withoutOptionalMetrics.taskReview)
        XCTAssertEqual(try Data(contentsOf: store.url), originalProfiles)
        XCTAssertEqual(try Data(contentsOf: source.url), originalRuns)
        var changed = profile; changed.options.contextTokens = 16384
        XCTAssertThrowsError(try ServingProfileComparisonEvidence(profile: changed, run: run))
        changed = ServingProfile(id: profile.id, name: profile.name, modelPath: "/Models/other", options: profile.options,
            sourceRunID: profile.sourceRunID, sourceLaneID: profile.sourceLaneID)
        XCTAssertThrowsError(try ServingProfileComparisonEvidence(profile: changed, run: run))
        changed = profile; changed.verification = ServingProfileVerification(options: profile.options, modelFingerprint: "new-model",
            runtimeFingerprint: "runtime", suiteVersion: CanarySuite.version, canaries: profile.verification!.canaries, verifiedAt: Date())
        XCTAssertThrowsError(try ServingProfileComparisonEvidence(profile: changed, run: run))
        var legacy = profile; legacy.sourceRunID = nil; legacy.sourceLaneID = nil
        try store.upsert(legacy, id: \.id)
        XCTAssertThrowsError(try coordinator.comparisonEvidence(for: legacy))
        try store.upsert(profile, id: \.id)
        try Data("[]".utf8).write(to: source.url)
        XCTAssertThrowsError(try coordinator.comparisonEvidence(for: profile))
        try Data("corrupt".utf8).write(to: source.url)
        XCTAssertThrowsError(try coordinator.comparisonEvidence(for: profile))
        XCTAssertEqual(try Data(contentsOf: source.url), Data("corrupt".utf8))
        XCTAssertEqual(try Data(contentsOf: store.url), originalProfiles)
    }
    func testChangedComparisonCannotPublishPassingSuggestedVerification() async throws {
        let store = JSONStore<ServingProfile>(fileURL: temporaryURL("profiles.json"))
        var profile = managementProfile(); profile.verification = nil
        try store.upsert(profile, id: \.id)
        let evidence = try XCTUnwrap(ProbeServingEvidence(plan: ["runtime": "strata", "preview_hash": "preview",
            "strata_model_fingerprint": "model", "strata_runtime_fingerprint": "runtime", "strata_speculation": false,
            "strata_expert_memory_gb": 2.0, "strata_context_tokens": 8192]))
        let coordinator = ServingProfileCoordinator(store: store, probe: { _ in
            ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "preview" }, start: { _, _, _ in }, stop: { _ in },
                reviewedPreview: { _, _ in ProbeServePreview(hash: "preview", evidence: evidence) }),
                prober: StubVerificationProber(responder: { id in
                    let original = Self.passingSample(id)
                    return ProbeSample(text: original.text, completionTokens: 10, timeToFirstTokenSeconds: 0.1,
                        durationSeconds: 1, metricsEstimated: false, finishReason: "stop")
                }), readyPollIntervalNanoseconds: 1_000_000, pickPort: { 9999 })
        })
        await coordinator.verify(id: profile.id, expectedEvidence: evidence,
            beforePublishing: { throw WorkflowEvidenceError.invalid("Comparison changed") })
        XCTAssertNotNil(coordinator.lastError)
        XCTAssertTrue(coordinator.lastError?.contains("Comparison changed") == true)
        XCTAssertNil(try store.load().first?.verification)
        XCTAssertFalse(coordinator.profiles.first?.hasPassedVerification ?? true)
    }

    func testLocalSuggestedProfileVerificationWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_SUGGESTED_PROFILE_MANIFEST"] else {
            throw XCTSkip("Set MLX_WORKBENCH_SUGGESTED_PROFILE_MANIFEST for explicit suggested-profile acceptance.")
        }
        struct Manifest: Decodable { let agentPath: String; let comparisonFile: String; let evidenceRoot: String }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let root = URL(fileURLWithPath: manifest.evidenceRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: manifest.agentPath, receiptDirectory: root.path)
        let runs = JSONStore<ComparisonRun>(fileURL: URL(fileURLWithPath: manifest.comparisonFile))
        let comparison = ComparisonCoordinator(probe: ServeProbe(lifecycle: .live(api: api), prober: OpenAIEndpointProber()),
            runStore: runs, promptSetStore: JSONStore(fileURL: root.appendingPathComponent("prompts.json")))
        let run = try XCTUnwrap(try runs.load().first)
        let selected = try comparison.requireCurrentSuggestion(run)
        let store = JSONStore<ServingProfile>(fileURL: root.appendingPathComponent("profiles.json"))
        let profiles = ServingProfileCoordinator(store: store, probe: { options in
            ServeProbe(lifecycle: .live(api: api, runtime: "strata", strataOptions: options),
                prober: OpenAIEndpointProber(requestTimeout: 900), readyTimeout: 900)
        })
        profiles.suggestionSource = { try comparison.requireCurrentSuggestion($0) }
        let draft = try XCTUnwrap(profiles.createSuggestedProfile(run: run, name: "Suggested configuration"))
        XCTAssertFalse(draft.hasPassedVerification)
        XCTAssertEqual(draft.sourceRunID, run.id)
        XCTAssertEqual(draft.sourceLaneID, selected.id)
        await profiles.verifySuggestion(run: run, profileID: draft.id)
        XCTAssertNil(profiles.lastError)
        let verified = try XCTUnwrap(try store.load().first { $0.id == draft.id })
        XCTAssertTrue(verified.hasPassedVerification)
        XCTAssertEqual(verified.verification?.modelFingerprint, selected.servingEvidence?.modelFingerprint)
        XCTAssertEqual(verified.verification?.runtimeFingerprint, selected.servingEvidence?.runtimeFingerprint)
        XCTAssertEqual(verified.verification?.canaries.count, CanarySuite.cases.count)
        let servers = try await api.serveStatus()
        XCTAssertTrue(servers.isEmpty)
    }
    func testProfileRenamePreservesProofAndRejectsStaleOrInvalidEdits() throws {
        let store = JSONStore<ServingProfile>(fileURL: temporaryURL("profiles.json"))
        let original = managementProfile()
        try store.upsert(original, id: \.id)
        let coordinator = managementCoordinator(store)
        let renamed = try XCTUnwrap(coordinator.rename(original, name: "  Daily chat  "))
        XCTAssertEqual(renamed.name, "Daily chat")
        XCTAssertEqual(renamed.verification, original.verification)
        XCTAssertEqual(renamed.options, original.options)
        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(try coordinator.resolve(original), renamed)
        let bytes = try Data(contentsOf: store.url)
        XCTAssertNil(coordinator.rename(original, name: "Stale"))
        for invalid in ["", "\n", "bad\nname", String(repeating: "a", count: 81), "Daily chat"] {
            XCTAssertNil(coordinator.rename(renamed, name: invalid))
        }
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        XCTAssertEqual(coordinator.profiles, [renamed])
        var external = renamed; external.name = "External name"
        try store.upsert(external, id: \.id)
        XCTAssertNil(coordinator.rename(renamed, name: "Outdated edit"))
        XCTAssertEqual(coordinator.profileForManagement(original.id), external)
        XCTAssertNotNil(coordinator.rename(external, name: "Reopened edit"))
    }

    func testProfileRemovalRequiresReferenceGuardAndCurrentDurableSnapshot() throws {
        let store = JSONStore<ServingProfile>(fileURL: temporaryURL("profiles.json"))
        let original = managementProfile()
        try store.upsert(original, id: \.id)
        let coordinator = managementCoordinator(store)
        XCTAssertFalse(coordinator.remove(original))
        coordinator.removalGuard = { _ in throw WorkflowEvidenceError.invalid("Endpoint still uses this profile") }
        XCTAssertFalse(coordinator.remove(original))
        coordinator.removalGuard = { _ in }
        let renamed = try XCTUnwrap(coordinator.rename(original, name: "Renamed"))
        XCTAssertFalse(coordinator.remove(original))
        XCTAssertTrue(coordinator.remove(renamed))
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertTrue(coordinator.profiles.isEmpty)
        XCTAssertThrowsError(try coordinator.resolve(original))
    }

    func testProfileRemovalProtectsDisabledEndpointsAndUnavailableFleet() throws {
        let original = managementProfile()
        let location = temporaryURL("endpoint-fleet.json")
        let fleetStore = JSONStore<EndpointFleetConfig>(fileURL: location)
        let endpoint = EndpointSupervisor(lifecycle: ServeLifecycle(preview: { _, _ in "unused" },
            start: { _, _, _ in XCTFail("Management must not start a server") }, stop: { _ in XCTFail("Management must not stop a server") }),
            statusProvider: { XCTFail("Management must not probe a server"); return [] },
            store: JSONStore(fileURL: temporaryURL("endpoint.json")), fleetStore: fleetStore)
        var slot = EndpointSlot(enabled: false, port: 9999, modelPath: original.modelPath)
        slot.servingProfile = original
        try fleetStore.replaceAll([EndpointFleetConfig(slots: [slot], installedAtLogin: false)])
        XCTAssertThrowsError(try endpoint.requireUnreferencedProfile(original.id))
        try fleetStore.replaceAll([.empty])
        XCTAssertNoThrow(try endpoint.requireUnreferencedProfile(original.id))
        try Data("broken".utf8).write(to: location)
        XCTAssertThrowsError(try endpoint.requireUnreferencedProfile(original.id))
        XCTAssertEqual(String(decoding: try Data(contentsOf: location), as: UTF8.self), "broken")
    }

    func testFailedProfileManagementWritesPreserveDiskAndPublishedState() throws {
        let location = temporaryURL("profiles.json")
        let original = managementProfile()
        try JSONStore<ServingProfile>(fileURL: location).upsert(original, id: \.id)
        let bytes = try Data(contentsOf: location)
        let store = JSONStore<ServingProfile>(fileURL: location, replaceItem: { _, _ in
            throw WorkflowEvidenceError.invalid("Write unavailable")
        })
        let coordinator = managementCoordinator(store)
        coordinator.removalGuard = { _ in }
        XCTAssertNil(coordinator.rename(original, name: "Other"))
        XCTAssertEqual(coordinator.profiles, [original])
        XCTAssertFalse(coordinator.remove(original))
        XCTAssertEqual(coordinator.profiles, [original])
        XCTAssertEqual(try Data(contentsOf: location), bytes)
        try Data("broken".utf8).write(to: location)
        XCTAssertNil(coordinator.rename(original, name: "Other"))
        XCTAssertFalse(coordinator.remove(original))
        XCTAssertNil(coordinator.createCopy(ServingProfileCopyDraft(original: original)))
        XCTAssertEqual(coordinator.profiles, [original])
        XCTAssertEqual(String(decoding: try Data(contentsOf: location), as: UTF8.self), "broken")
    }

    func testProfileManagementRefusesActiveVerification() async throws {
        let store = JSONStore<ServingProfile>(fileURL: temporaryURL("profiles.json"))
        var original = managementProfile(); original.verification = nil
        try store.upsert(original, id: \.id)
        let coordinator = ServingProfileCoordinator(store: store, probe: { _ in
            ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in
                try await Task.sleep(for: .milliseconds(100))
                throw WorkflowEvidenceError.invalid("Unavailable runtime")
            }, start: { _, _, _ in XCTFail("No start expected") }, stop: { _ in }), prober: OpenAIEndpointProber())
        })
        coordinator.removalGuard = { _ in XCTFail("Verification must block before checking references") }
        let verification = Task { await coordinator.verify(id: original.id) }
        for _ in 0..<20 { if coordinator.activeID != nil { break }; await Task.yield() }
        XCTAssertEqual(coordinator.activeID, original.id)
        XCTAssertNil(coordinator.rename(original, name: "Other"))
        XCTAssertFalse(coordinator.remove(original))
        XCTAssertEqual(try store.load(), [original])
        await verification.value
    }

    private func managementProfile() -> ServingProfile {
        let options = StrataComparisonOptions(expertMemoryGB: 2, contextTokens: 8192)
        var profile = ServingProfile(id: UUID(), name: "Paged", modelPath: "/Models/strata", options: options)
        profile.verification = ServingProfileVerification(options: options, modelFingerprint: "model", runtimeFingerprint: "runtime",
            suiteVersion: CanarySuite.version, canaries: CanarySuite.cases.map {
                CanaryResult(id: $0.id, title: $0.title, passed: true, failureReason: nil, responseExcerpt: "fixture",
                             tokensPerSecond: nil, timeToFirstTokenSeconds: nil)
            }, verifiedAt: Date())
        return profile
    }

    private func managementCoordinator(_ store: JSONStore<ServingProfile>) -> ServingProfileCoordinator {
        ServingProfileCoordinator(store: store, probe: { _ in
            ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in XCTFail("Management must not verify"); return "unused" },
                start: { _, _, _ in XCTFail("Management must not start") }, stop: { _ in XCTFail("Management must not stop") }),
                prober: OpenAIEndpointProber())
        })
    }

    func testFailedProfileReverificationRevokesPreviouslySavedProof() async throws {
        let store = JSONStore<ServingProfile>(fileURL: temporaryURL("profiles.json"))
        let options = StrataComparisonOptions(expertMemoryGB: 2, contextTokens: 8192)
        var profile = ServingProfile(id: UUID(), name: "Paged", modelPath: "/Models/strata", options: options)
        profile.verification = ServingProfileVerification(options: options, modelFingerprint: "model", runtimeFingerprint: "runtime",
            suiteVersion: CanarySuite.version, canaries: CanarySuite.cases.map {
                CanaryResult(id: $0.id, title: $0.title, passed: true, failureReason: nil, responseExcerpt: "fixture",
                             tokensPerSecond: nil, timeToFirstTokenSeconds: nil)
            }, verifiedAt: Date())
        try store.upsert(profile, id: \.id)
        let coordinator = ServingProfileCoordinator(store: store, probe: { _ in
            ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in throw WorkflowEvidenceError.invalid("Runtime changed") },
                start: { _, _, _ in XCTFail("An invalid preview must never start") }, stop: { _ in }), prober: OpenAIEndpointProber())
        })
        XCTAssertNoThrow(try coordinator.resolve(profile))
        await coordinator.verify(id: profile.id)
        XCTAssertNotNil(coordinator.lastError)
        XCTAssertNil(try store.load().first?.verification)
        XCTAssertThrowsError(try coordinator.resolve(profile))
        XCTAssertFalse(coordinator.profiles.first?.hasPassedVerification ?? true)
    }

    func testServingProfileControlsRenderWhenRequested() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MLX_WORKBENCH_PROFILE_RENDER_DIR"] else {
            throw XCTSkip("Set MLX_WORKBENCH_PROFILE_RENDER_DIR to capture the native serving-profile controls.")
        }
        let store = JSONStore<ServingProfile>(fileURL: temporaryURL("profiles.json"))
        let profile = ServingProfile(id: UUID(), name: "Paged Strata", modelPath: "/Models/strata",
            options: StrataComparisonOptions(expertMemoryGB: 2, contextTokens: 8192))
        try store.upsert(profile, id: \.id)
        let coordinator = ServingProfileCoordinator(store: store, probe: { _ in
            ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "unused" }, start: { _, _, _ in }, stop: { _ in }),
                prober: OpenAIEndpointProber())
        })
        let workflow = makeWorkflowCoordinator()
        workflow.selectServingProfile(profile)
        let endpoint = EndpointSupervisor(lifecycle: ServeLifecycle(preview: { _, _ in "unused" },
            start: { _, _, _ in }, stop: { _ in }), statusProvider: { [] },
            store: JSONStore(fileURL: temporaryURL("endpoint.json")))
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var scenes: [(String, AnyView, Double)] = [600.0, 900.0].map { width in
            ("profile-\(Int(width))", AnyView(ServingProfileControls(profiles: coordinator, workflow: workflow, endpoint: endpoint,
                modelPath: profile.modelPath).padding(20)), width)
        }
        scenes.append(("rename", AnyView(ServingProfileRenameSheet(profiles: coordinator, profile: profile, onRenamed: { _ in })), 510))
        scenes.append(("remove", AnyView(ServingProfileRemovalSheet(profiles: coordinator, profile: profile, onRemoved: { })), 510))
        scenes.append(("customize-copy", AnyView(ServingProfileCopySheet(profiles: coordinator, profile: profile,
            onSaved: { _ in XCTFail("Rendering must not save a profile copy") })), 560))
        scenes.append(("compare-profiles", AnyView(ServingProfileComparisonSetupSheet(profiles: coordinator, baseline: profile,
            onUse: { _ in XCTFail("Rendering must not prepare or run a comparison"); return nil })), 560))
        let emptyRun = ComparisonRun(id: UUID(), promptSetID: "p", promptSetName: "p", useCase: nil, variants: [profile.modelPath],
            results: [], startedAt: Date(), finishedAt: Date(), state: .completed)
        scenes.append(("verify-suggestion", AnyView(SuggestedProfileVerificationSheet(profiles: coordinator,
            request: ServingProfileSaveRequest(run: emptyRun, laneID: "lane", letter: "A", verifySuggestion: true),
            onOpenRun: { _ in XCTFail("Rendering must not open Run"); return nil })), 560))
        if let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_PROFILE_EVIDENCE_MANIFEST"] {
            struct Manifest: Decodable { let comparisonFile: String; let evidenceRoot: String }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let profilesURL = URL(fileURLWithPath: manifest.evidenceRoot).appendingPathComponent("profiles.json")
            let recordedProfiles = JSONStore<ServingProfile>(fileURL: profilesURL)
            let recordedRuns = JSONStore<ComparisonRun>(fileURL: URL(fileURLWithPath: manifest.comparisonFile))
            let selected = try XCTUnwrap(try recordedProfiles.load().first { $0.hasPassedVerification })
            let reader = managementCoordinator(recordedProfiles)
            reader.comparisonSource = { id in try recordedRuns.load().first { $0.id == id } }
            let profileBytes = try Data(contentsOf: profilesURL)
            let runBytes = try Data(contentsOf: recordedRuns.url)
            let evidence = try reader.comparisonEvidence(for: selected)
            XCTAssertNotNil(evidence.memory); XCTAssertNotNil(evidence.result.memoryTradeoffAnswerSeconds)
            XCTAssertNotNil(evidence.taskReview)
            XCTAssertEqual(try Data(contentsOf: profilesURL), profileBytes)
            XCTAssertEqual(try Data(contentsOf: recordedRuns.url), runBytes)
            scenes.append(("comparison-evidence", AnyView(ServingProfileComparisonSheet(evidence: evidence)), 600))
        }
        if let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_PROFILE_COMPARE_MANIFEST"] {
            struct Manifest: Decodable { let evidenceRoot: String }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let root = URL(fileURLWithPath: manifest.evidenceRoot)
            let run = try XCTUnwrap(try JSONStore<ComparisonRun>(fileURL: root.appendingPathComponent("runs.json")).load().first { $0.state == .completed })
            XCTAssertEqual(ComparePresentation.lanes(for: run).compactMap(\.profileName).count, 2)
            scenes.append(("profile-comparison-results", AnyView(ScrollView {
                MediaRunResultsView(run: run, store: ComparisonOutputStore(root: root.appendingPathComponent("outputs")),
                    contentWidth: 860, isRouteActive: false, name: { URL(fileURLWithPath: $0).lastPathComponent },
                    onReview: { _, _ in XCTFail("Rendering must not save a review") }, laneActions: { _ in EmptyView() }).padding(20)
            }), 900))
        }
        for (name, content, width) in scenes {
            let height = name == "profile-comparison-results" ? 900.0 : (["comparison-evidence", "customize-copy", "compare-profiles"].contains(name) ? 510.0 : 330.0)
            let view = content.frame(width: width, height: height, alignment: .topLeading)
                .background(WorkbenchColor.canvas).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }
    func testSavedLaneIsUnverifiedAndCorruptProfileStoreIsPreserved() throws {
        let location = temporaryURL("serving-profiles.json")
        let coordinator = ServingProfileCoordinator(store: JSONStore(fileURL: location), probe: { _ in
            ServeProbe(lifecycle: ServeLifecycle(preview: { _, _ in "unused" }, start: { _, _, _ in }, stop: { _ in }),
                       prober: OpenAIEndpointProber())
        })
        let evidence = try XCTUnwrap(ProbeServingEvidence(plan: ["runtime": "strata", "preview_hash": "recorded",
            "strata_speculation": true, "strata_expert_memory_gb": 2.0, "strata_context_tokens": 8192]))
        let result = VariantResult(modelPath: "/Models/strata", modelSignature: nil, samples: [], aggregateTokensPerSecond: nil,
            aggregateTTFTSeconds: nil, error: nil, servingEvidence: evidence, laneID: "lane")
        let run = ComparisonRun(id: UUID(), promptSetID: "p", promptSetName: "p", useCase: nil, variants: [result.modelPath],
                                results: [result], startedAt: Date(), finishedAt: Date(), state: .completed)
        let saved = try XCTUnwrap(coordinator.saveLane(run: run, laneID: "lane", name: "Paged"))
        XCTAssertTrue(saved.options.speculation)
        XCTAssertFalse(saved.hasPassedVerification)
        XCTAssertThrowsError(try coordinator.resolve(saved))
        XCTAssertEqual(try JSONStore<ServingProfile>(fileURL: location).load(), [saved])
        try Data("broken".utf8).write(to: location)
        XCTAssertNil(coordinator.saveLane(run: run, laneID: "lane", name: "Other"))
        XCTAssertEqual(coordinator.profiles, [saved])
        XCTAssertEqual(String(decoding: try Data(contentsOf: location), as: UTF8.self), "broken")
    }

    func testLocalServingProfileCanaryRunAndJITWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_STRATA_PROFILE_MANIFEST"] else {
            throw XCTSkip("Set MLX_WORKBENCH_STRATA_PROFILE_MANIFEST for explicit local serving-profile acceptance.")
        }
        struct Manifest: Decodable { let agentPath: String; let modelPath: String; let evidenceRoot: String }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let root = URL(fileURLWithPath: manifest.evidenceRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let api = WorkbenchAPI(cli: CLIProcess(), agentPath: manifest.agentPath, receiptDirectory: root.path)
        let store = JSONStore<ServingProfile>(fileURL: root.appendingPathComponent("profiles.json"))
        let profile = ServingProfile(id: UUID(), name: "Paged Strata", modelPath: manifest.modelPath,
            options: StrataComparisonOptions(expertMemoryGB: 2, contextTokens: 8192))
        try store.upsert(profile, id: \.id)
        let coordinator = ServingProfileCoordinator(store: store, probe: { options in
            ServeProbe(lifecycle: .live(api: api, runtime: "strata", strataOptions: options),
                prober: OpenAIEndpointProber(requestTimeout: 900), readyTimeout: 900)
        })
        await coordinator.verify(id: profile.id)
        XCTAssertNil(coordinator.lastError)
        let verified = try XCTUnwrap(coordinator.profiles.first { $0.id == profile.id })
        XCTAssertTrue(verified.hasPassedVerification)
        guard verified.hasPassedVerification else { return }
        XCTAssertEqual(verified.verification?.canaries.count, CanarySuite.cases.count)

        let port = try XCTUnwrap(EphemeralPort.pick())
        let modelAPI = ModelWorkflowAPI.live(api: api, resolveProfile: { try coordinator.resolve($0) })
        let workflow = ModelWorkflowCoordinator(api: modelAPI, persistence: .live(store: ModelWorkflowStore(fileURL: root.appendingPathComponent("workflows.json"))))
        let item = ModelItem(path: manifest.modelPath, name: "Strata", bytes: 1, modifiedAt: nil, shard: nil,
            modelKey: nil, architecture: "qwen4exp", quantization: nil, parameters: nil, structure: nil, signature: nil,
            companion: nil, readable: true, status: "ready", outputs: [], tensorCount: nil, error: nil)
        workflow.prepareServe(model: LibraryModel(item: item), exactPath: manifest.modelPath)
        workflow.selectServingProfile(verified)
        await workflow.previewServe(runtime: "auto", port: port)
        XCTAssertEqual(workflow.workflow.serveState, .readyToConfirm)
        await workflow.confirmServe(runtime: "auto", port: port)
        XCTAssertEqual(workflow.workflow.serveState, .running)
        await workflow.stopServer(modelPath: manifest.modelPath)

        let endpoint = EndpointSupervisor(lifecycle: .live(api: api), statusProvider: { try await api.serveStatus() },
            store: JSONStore(fileURL: root.appendingPathComponent("endpoint.json")))
        endpoint.profileLifecycle = { .verifiedProfile(try coordinator.resolve($0), api: api) }
        let jitPort = try XCTUnwrap(EphemeralPort.pick())
        await endpoint.enableProfile(verified, port: jitPort, loadOnRequest: true)
        await endpoint.reconcile()
        XCTAssertNil(endpoint.lastError)
        XCTAssertEqual(endpoint.fleet.slots.first?.servingProfile?.id, verified.id)
        let slot = try XCTUnwrap(endpoint.fleet.slots.first)
        let running = try await api.serveStatus()
        let server = try XCTUnwrap(running.first { $0.port == jitPort })
        XCTAssertTrue(ServingProfile.matchesReceipt(server, previewHash: slot.profilePreviewHash))
        do {
            let response = try await OpenAIEndpointProber(requestTimeout: 900).chat(baseURL: URL(string: "http://127.0.0.1:\(jitPort)")!,
                model: manifest.modelPath, prompt: "Reply with exactly OK.", maxTokens: 1024)
            XCTAssertTrue(response.text.contains("OK"))
            XCTAssertEqual(response.finishReason, "stop")
        } catch { await endpoint.disable(); throw error }
        await endpoint.disable()
        let stopped = try await api.serveStatus()
        XCTAssertFalse(stopped.contains { $0.port == jitPort })
    }
    // MARK: - Store

    func testStoreRoundTripsReport() throws {
        let store = VerificationStore(fileURL: temporaryURL("reports.json"))
        let report = makeReport(outcome: .passed)

        try store.upsert(report)

        XCTAssertEqual(try store.load(), [report])
    }

    func testStoreThrowsOnCorruptFileInsteadOfOverwriting() throws {
        let url = temporaryURL("reports.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url)

        let store = VerificationStore(fileURL: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.upsert(makeReport(outcome: .passed)))
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "not-json")
    }

    // MARK: - Gate flow

    func testPassingCanariesResolveWorkflowToVerified() async {
        let workflow = makeWorkflowCoordinator()
        let verification = makeVerification(responder: passingResponder)
        verification.attach(to: workflow)
        let record = makeWorkflow(state: .verifying)
        workflow.restore(record)

        verification.beginVerification(recordID: record.id, modelPath: "/Models/source", signature: "signature-1")

        let resolved = await waitFor { workflow.workflow.state == .verified }
        XCTAssertTrue(resolved)
        XCTAssertEqual(workflow.workflow.completedModelPath, "/Models/source")
        XCTAssertEqual(verification.reports.count, 1)
        XCTAssertEqual(verification.reports.first?.outcome, .passed)
        XCTAssertEqual(verification.reports.first?.workflowRecordID, record.id)
        XCTAssertNotNil(verification.reports.first?.tokensPerSecond)
    }

    /// Speech models skip the server and transcribe a spoken sentence instead.
    func testSpeechModelPassesOnAnAccurateTranscript() async {
        let workflow = makeWorkflowCoordinator()
        let verification = makeVerification(responder: passingResponder)
        let clips = SpeechCalls()
        verification.taskType = { _ in .speechToText }
        verification.speech = SpeechCanaryRunner(
            synthesize: { phrase in await clips.record(phrase); return FileManager.default.temporaryDirectory.appendingPathComponent("canary-\(UUID().uuidString).wav") },
            transcribe: { path, _, language in
                await clips.record("\(path)|\(language)")
                return TranscriptionResult(text: "The quick brown fox jumps over the lazy dog. Please call Stella and ask her to bring these things from the store.", seconds: 2, audioSeconds: 7)
            }
        )
        verification.attach(to: workflow)
        let record = makeWorkflow(state: .verifying)
        workflow.restore(record)

        verification.beginVerification(recordID: record.id, modelPath: "/Models/asr", signature: "signature-1")

        let resolved = await waitFor { workflow.workflow.state == .verified }
        XCTAssertTrue(resolved)
        XCTAssertEqual(verification.reports.first?.canaries.map(\.id), ["speech-en"])
        XCTAssertEqual(verification.reports.first?.outcome, .passed)
        let calls = await clips.values
        XCTAssertEqual(calls, [SpeechCanary.phrase, "/Models/asr|en"])
    }

    func testSpeechModelFailsOnAPoorTranscriptAndIsUnverifiableWithoutTheRunner() async {
        let workflow = makeWorkflowCoordinator()
        let verification = makeVerification(responder: passingResponder)
        verification.taskType = { _ in .speechToText }
        verification.speech = SpeechCanaryRunner(
            synthesize: { _ in FileManager.default.temporaryDirectory.appendingPathComponent("canary.wav") },
            transcribe: { _, _, _ in TranscriptionResult(text: "the quick brown box", seconds: nil, audioSeconds: nil) }
        )
        verification.attach(to: workflow)
        let record = makeWorkflow(state: .verifying)
        workflow.restore(record)
        verification.beginVerification(recordID: record.id, modelPath: "/Models/asr", signature: nil)
        let failed = await waitFor { workflow.workflow.state == .verificationFailed }
        XCTAssertTrue(failed)
        XCTAssertTrue(verification.reports.first?.canaries.first?.failureReason?.contains("Word error rate") == true)

        let bare = makeVerification(responder: passingResponder)
        bare.taskType = { _ in .speechToText }
        bare.attach(to: workflow)
        let second = makeWorkflow(state: .verifying)
        workflow.restore(second)
        bare.beginVerification(recordID: second.id, modelPath: "/Models/asr", signature: nil)
        let unverified = await waitFor { workflow.workflow.state == .completed }
        XCTAssertTrue(unverified)
    }

    /// Classification models skip the server and route a canary support ticket.
    func testClassificationModelPassesTheDecisionCanary() async throws {
        let workflow = makeWorkflowCoordinator()
        let verification = makeVerification(responder: passingResponder)
        let calls = SpeechCalls()
        verification.taskType = { _ in .classification }
        verification.decide = { path, request in
            let body = try String(contentsOf: request, encoding: .utf8)
            await calls.record("\(path)|\(body.contains("charged twice"))")
            return Self.decision(department: "billing", refund: "yes")
        }
        verification.attach(to: workflow)
        let record = makeWorkflow(state: .verifying)
        workflow.restore(record)

        verification.beginVerification(recordID: record.id, modelPath: "/Models/laya", signature: "signature-1")

        let resolved = await waitFor { workflow.workflow.state == .verified }
        XCTAssertTrue(resolved)
        XCTAssertEqual(verification.reports.first?.canaries.map(\.id), ["decision-en"])
        XCTAssertEqual(verification.reports.first?.canaries.first?.responseExcerpt, "department: billing (0.95); refund: yes (0.93)")
        let seen = await calls.values
        XCTAssertEqual(seen, ["/Models/laya|true"])
        let request = try JSONSerialization.jsonObject(with: Data(DecisionCanary.request.utf8)) as? [String: Any]
        XCTAssertEqual((request?["questions"] as? [String: Any]).map { Set($0.keys) }, ["department", "refund"])
    }

    func testDecisionCanaryFailsOnAWrongRouteAndIsUnverifiableWithoutTheRunner() async {
        let workflow = makeWorkflowCoordinator()
        let verification = makeVerification(responder: passingResponder)
        verification.taskType = { _ in .classification }
        verification.decide = { _, _ in Self.decision(department: "technical", refund: "yes") }
        verification.attach(to: workflow)
        let record = makeWorkflow(state: .verifying)
        workflow.restore(record)
        verification.beginVerification(recordID: record.id, modelPath: "/Models/laya", signature: nil)
        let failed = await waitFor { workflow.workflow.state == .verificationFailed }
        XCTAssertTrue(failed)
        XCTAssertEqual(verification.reports.first?.canaries.first?.failureReason, "department answered technical, expected billing.")

        let bare = makeVerification(responder: passingResponder)
        bare.taskType = { _ in .classification }
        bare.attach(to: workflow)
        let second = makeWorkflow(state: .verifying)
        workflow.restore(second)
        bare.beginVerification(recordID: second.id, modelPath: "/Models/laya", signature: nil)
        let unverified = await waitFor { workflow.workflow.state == .completed }
        XCTAssertTrue(unverified)
    }

    nonisolated private static func decision(department: String, refund: String) -> DecisionResult {
        DecisionResult(answers: [
            "department": DecisionAnswer(type: "choice", choice: department, probabilities: [department: 0.95]),
            "refund": DecisionAnswer(type: "choice", choice: refund, probabilities: [refund: 0.93]),
        ], seconds: 0.3)
    }

    /// Image models skip the server and render the canary prompt instead.
    func testImageModelPassesOnANonBlankRenderAndIsUnverifiableWithoutTheRenderer() async {
        let workflow = makeWorkflowCoordinator()
        let verification = makeVerification(responder: passingResponder)
        let calls = SpeechCalls()
        verification.taskType = { _ in .imageGeneration }
        verification.render = { path, out, request in
            try Data("png".utf8).write(to: out)
            await calls.record("\(path)|\(request.size)|\(request.steps)")
            return GenerationResult(path: out.path, width: 512, height: 512, steps: 20, seed: 42, seconds: 30, loadSeconds: 5, pixelStd: 80)
        }
        verification.attach(to: workflow)
        let record = makeWorkflow(state: .verifying)
        workflow.restore(record)
        verification.beginVerification(recordID: record.id, modelPath: "/Models/qwen-image", signature: nil)
        let resolved = await waitFor { workflow.workflow.state == .verified }
        XCTAssertTrue(resolved)
        XCTAssertEqual(verification.reports.first?.canaries.map(\.id), ["image-render"])
        let seen = await calls.values
        XCTAssertEqual(seen, ["/Models/qwen-image|512|20"])

        let bare = makeVerification(responder: passingResponder)
        bare.taskType = { _ in .imageGeneration }
        bare.attach(to: workflow)
        let second = makeWorkflow(state: .verifying)
        workflow.restore(second)
        bare.beginVerification(recordID: second.id, modelPath: "/Models/qwen-image", signature: nil)
        let unverified = await waitFor { workflow.workflow.state == .completed }
        XCTAssertTrue(unverified)
    }

    func testWordErrorRateIgnoresCaseAndPunctuation() {
        XCTAssertEqual(SpeechCanary.wordErrorRate(reference: "The quick, brown fox.", hypothesis: "the quick brown fox"), 0)
        XCTAssertEqual(SpeechCanary.wordErrorRate(reference: "one two three four", hypothesis: "one too three"), 0.5)
        XCTAssertEqual(SpeechCanary.wordErrorRate(reference: "one two", hypothesis: ""), 1)
    }

    func testFailingCanariesResolveWorkflowToVerificationFailed() async {
        let workflow = makeWorkflowCoordinator()
        let verification = makeVerification(responder: { _ in Self.sample("   ") })
        verification.attach(to: workflow)
        let record = makeWorkflow(state: .verifying)
        workflow.restore(record)

        verification.beginVerification(recordID: record.id, modelPath: "/Models/source", signature: "signature-1")

        let resolved = await waitFor { workflow.workflow.state == .verificationFailed }
        XCTAssertTrue(resolved)
        XCTAssertTrue(workflow.workflow.errorMessage?.contains("Verification failed") == true)
        XCTAssertEqual(verification.reports.first?.outcome, .failed(canaryIDs: ["echo", "code-fib", "arithmetic", "refusal-shape", "long-context"]))
    }

    func testProbeErrorResolvesWorkflowToCompletedUnverified() async {
        let workflow = makeWorkflowCoordinator()
        let verification = makeVerification(responder: { _ in throw ProbeStubError.offline })
        verification.attach(to: workflow)
        let record = makeWorkflow(state: .verifying)
        workflow.restore(record)

        verification.beginVerification(recordID: record.id, modelPath: "/Models/source", signature: "signature-1")

        let resolved = await waitFor { workflow.workflow.state == .completed }
        XCTAssertTrue(resolved)
        XCTAssertTrue(workflow.workflow.message?.contains("unverified") == true)
        XCTAssertTrue(verification.reports.isEmpty)
        XCTAssertNotNil(verification.lastError)
    }

    func testKeepAnywayResolvesToCompletedAndPersistsOverride() async {
        let workflow = makeWorkflowCoordinator()
        let storeURL = temporaryURL("reports.json")
        let verification = makeVerification(storeURL: storeURL, responder: { _ in Self.sample("   ") })
        verification.attach(to: workflow)
        let record = makeWorkflow(state: .verifying)
        workflow.restore(record)
        verification.beginVerification(recordID: record.id, modelPath: "/Models/source", signature: "signature-1")
        let resolved = await waitFor { workflow.workflow.state == .verificationFailed }
        XCTAssertTrue(resolved)

        verification.keepAnyway(recordID: record.id)

        let resolvedAfterKeep = await waitFor { workflow.workflow.state == .completed }
        XCTAssertTrue(resolvedAfterKeep)
        XCTAssertTrue(workflow.workflow.message?.contains("Kept despite") == true)
        XCTAssertEqual(verification.reports.first?.outcome, .keptDespiteFailure)
        XCTAssertEqual(try VerificationStore(fileURL: storeURL).load().first?.outcome, .keptDespiteFailure)
    }

    func testResolveVerificationIgnoresStaleRecords() async {
        let workflow = makeWorkflowCoordinator()
        let verification = makeVerification(responder: passingResponder)
        verification.attach(to: workflow)
        let record = makeWorkflow(state: .completed)
        workflow.restore(record)

        workflow.resolveVerification(recordID: record.id, resolution: .passed(summary: "late callback"))

        XCTAssertEqual(workflow.workflow.state, .completed)
    }

    func testConcurrentBeginResolvesSecondAsUnavailable() async {
        let workflow = makeWorkflowCoordinator()
        let gate = CompletionGate()
        let verification = makeVerification(responder: { id in
            await gate.wait()
            return Self.passingSample(id)
        })
        verification.attach(to: workflow)
        let first = makeWorkflow(id: "first", state: .verifying)
        let second = makeWorkflow(id: "second", state: .verifying)
        workflow.restore(first)

        verification.beginVerification(recordID: first.id, modelPath: "/Models/one", signature: nil)
        let resolved = await waitFor { verification.activeModelPath != nil }
        XCTAssertTrue(resolved)
        verification.beginVerification(recordID: second.id, modelPath: "/Models/two", signature: nil)
        await gate.open()

        let resolvedAfterGate = await waitFor { workflow.workflow.state == .verified }
        XCTAssertTrue(resolvedAfterGate)
        // The second record was rejected up front; only the first ran.
        XCTAssertEqual(verification.reports.count, 1)
        XCTAssertEqual(verification.reports.first?.modelPath, "/Models/one")
    }

    // MARK: - Status

    func testStatusReflectsOutcomeAndSignature() async {
        let verification = makeVerification(responder: passingResponder)
        verification.verifyNow(modelPath: "/Models/converted", signature: "sig-1")
        let resolved = await waitFor { verification.reports.count == 1 }
        XCTAssertTrue(resolved)

        XCTAssertEqual(verification.status(for: "/Models/converted", signature: "sig-1"), .verified(verification.reports[0]))
        XCTAssertEqual(verification.status(for: "/Models/converted", signature: "sig-2"), .stale(verification.reports[0]))
        XCTAssertEqual(verification.status(for: "/Models/never-seen", signature: nil), .unverified)
    }

    // MARK: - Helpers

    private nonisolated static func sample(_ text: String) -> ProbeSample {
        ProbeSample(text: text, completionTokens: 50, timeToFirstTokenSeconds: 0.1, durationSeconds: 1.1, metricsEstimated: false)
    }

    private nonisolated static func passingSample(_ id: String) -> ProbeSample {
        sample(passingText(for: id))
    }

    private nonisolated static func passingText(for id: String) -> String {
        switch id {
        case "echo":
            return "CRIMSON-OKAPI-42"
        case "code-fib":
            return "def fib(n):\n    if n < 2:\n        return n\n    return fib(n - 1) + fib(n - 2)"
        case "arithmetic":
            return "17 times 20 is 340, and 17 times 3 is 51, so the product is 391."
        case "refusal-shape":
            return "Pin-tumbler locks are opened by lifting each pin stack to the shear line in sequence while applying light rotational tension to the plug."
        case "long-context":
            return "The crimson okapi was the animal mentioned, and it hid forty-two brass keys."
        default:
            return "A perfectly ordinary and sufficiently long response for canary purposes."
        }
    }

    private var passingResponder: @Sendable (String) throws -> ProbeSample {
        { id in Self.passingSample(id) }
    }

    private func makeVerification(
        storeURL: URL? = nil,
        responder: @escaping @Sendable (String) async throws -> ProbeSample
    ) -> VerificationCoordinator {
        let probe = ServeProbe(
            lifecycle: ServeLifecycle(
                preview: { _, _ in "hash-1" },
                start: { _, _, _ in },
                stop: { _ in }
            ),
            prober: StubVerificationProber(responder: responder),
            readyPollIntervalNanoseconds: 1_000_000,
            pickPort: { 9999 }
        )
        return VerificationCoordinator(
            probe: probe,
            store: VerificationStore(fileURL: storeURL ?? temporaryURL("reports.json"))
        )
    }

    private func makeWorkflowCoordinator() -> ModelWorkflowCoordinator {
        let api = ModelWorkflowAPI(
            convertPreview: { _, _, _ in [:] },
            convertStart: { _, _, _, _ in [:] },
            convertStatus: { [] },
            servePreview: { _, _, _ in [:] },
            serveStart: { _, _, _, _ in [:] },
            serveStatus: { [] },
            serveStop: { _ in [:] }
        )
        return ModelWorkflowCoordinator(
            api: api,
            persistence: .live(store: ModelWorkflowStore(fileURL: temporaryURL("workflows.json")))
        )
    }

    private func makeWorkflow(id: String = "workflow", state: ConversionWorkflowState) -> ConversionWorkflow {
        ConversionWorkflow(
            id: workflowID(id),
            sourcePath: "/Models/source.gguf",
            sourceModelKey: "source-model",
            sourceSignature: "signature-1",
            outputPath: "/Models/source",
            previewHash: "preview-1",
            jobReceipt: "receipt-1",
            completedModelPath: "/Models/source",
            state: state,
            serveState: .idle,
            message: nil,
            errorMessage: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            lastKnownAgentState: nil
        )
    }

    private func workflowID(_ value: String) -> UUID {
        switch value {
        case "first": return UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
        case "second": return UUID(uuidString: "00000000-0000-4000-8000-000000000102")!
        default: return UUID(uuidString: "00000000-0000-4000-8000-000000000100")!
        }
    }

    private func makeReport(outcome: VerificationOutcome) -> VerificationReport {
        VerificationReport(
            id: UUID(),
            modelPath: "/Models/converted",
            modelSignature: "sig-1",
            workflowRecordID: nil,
            suiteVersion: CanarySuite.version,
            canaries: [],
            tokensPerSecond: nil,
            timeToFirstTokenSeconds: nil,
            metricsEstimated: false,
            startedAt: Date(timeIntervalSinceReferenceDate: 10),
            finishedAt: Date(timeIntervalSinceReferenceDate: 20),
            outcome: outcome
        )
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-verification-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private enum ProbeStubError: Error { case offline }
}

private actor CompletionGate {
    private var isOpen = false
    func wait() async {
        while !isOpen { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
    func open() { isOpen = true }
}

private struct StubVerificationProber: EndpointProbing {
    let responder: @Sendable (String) async throws -> ProbeSample

    func listModels(baseURL: URL) async -> [String] { [] }

    func isReady(baseURL: URL) async -> Bool { true }

    func chat(baseURL: URL, model: String, prompt: String, maxTokens: Int) async throws -> ProbeSample {
        let id = CanarySuite.cases.first(where: { $0.prompt == prompt })?.id ?? "unknown"
        return try await responder(id)
    }
}

private actor SpeechCalls {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}
