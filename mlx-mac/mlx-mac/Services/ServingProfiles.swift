import Foundation

struct ServingProfileCopyDraft {
    let original: ServingProfile
    var name: String
    var options: StrataComparisonOptions

    init(original: ServingProfile) {
        self.original = original
        name = String(original.name.prefix(75)) + " copy"
        options = original.options
    }
    var hasChanges: Bool { name != String(original.name.prefix(75)) + " copy" || options != original.options }
    var validationError: String? { ServingProfile.nameValidationError(name) ?? options.validationError }
}

/// A read-only view of the currently saved source comparison, not a fresh measurement.
struct ServingProfileComparisonEvidence: Identifiable {
    let profile: ServingProfile
    let run: ComparisonRun
    let result: VariantResult
    var id: UUID { profile.id }
    var memory: SystemMemoryEvidence? { result.systemMemory.flatMap { $0.isValid ? $0 : nil } }
    var taskReview: ComparisonQualityReview? {
        guard let review = run.qualityReviews?[result.id], review.rubricID == ComparisonQualityReview.taskOutcomeRubric,
              (1...5).contains(review.score) else { return nil }
        return review
    }

    init(profile: ServingProfile, run: ComparisonRun) throws {
        guard profile.isValid, profile.sourceRunID == run.id, let laneID = profile.sourceLaneID,
              run.state == .completed, run.effectiveMode == .chat, run.results.filter({ $0.id == laneID }).count == 1,
              let result = run.results.first(where: { $0.id == laneID }), result.error == nil, result.modelPath == profile.modelPath,
              let serving = result.servingEvidence, serving.runtime == "strata",
              serving.speculation == profile.options.speculation, serving.expertMemoryGB == profile.options.expertMemoryGB,
              serving.contextTokens == profile.options.contextTokens else {
            throw WorkflowEvidenceError.invalid("The source comparison no longer matches this profile's model, lane or settings.")
        }
        if let proof = profile.verification {
            guard serving.modelFingerprint == proof.modelFingerprint, serving.runtimeFingerprint == proof.runtimeFingerprint else {
                throw WorkflowEvidenceError.invalid("The source comparison fingerprints differ from this profile's verification. Review the comparison in Compare.")
            }
        }
        self.profile = profile; self.run = run; self.result = result
    }
}

struct ServingProfileVerification: Codable, Equatable, Sendable {
    let options: StrataComparisonOptions
    let modelFingerprint: String
    let runtimeFingerprint: String
    let suiteVersion: Int
    let canaries: [CanaryResult]
    let verifiedAt: Date
    var answerBudget: Int? = 1024

    var passed: Bool {
        suiteVersion == CanarySuite.version && answerBudget == 1024 && !modelFingerprint.isEmpty && !runtimeFingerprint.isEmpty
            && canaries.count == CanarySuite.cases.count && canaries.allSatisfy(\.passed)
            && Set(canaries.map(\.id)) == Set(CanarySuite.cases.map(\.id))
    }
}

struct ServingProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let modelPath: String
    var options: StrataComparisonOptions
    var verification: ServingProfileVerification? = nil
    var sourceRunID: UUID? = nil
    var sourceLaneID: String? = nil

    var isValid: Bool {
        Self.nameValidationError(name) == nil
            && modelPath.hasPrefix("/") && !modelPath.unicodeScalars.contains { $0.value < 32 }
            && options.validationError == nil
    }
    static func nameValidationError(_ name: String) -> String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Enter a profile name." }
        guard name.count <= 80 else { return "Use no more than 80 characters." }
        guard !name.unicodeScalars.contains(where: { $0.value < 32 }) else { return "Use a name without control characters." }
        return nil
    }
    var hasPassedVerification: Bool { isValid && verification?.passed == true && verification?.options == options }

    func validate(plan: [String: Any]) throws {
        guard hasPassedVerification, let proof = verification,
              let evidence = ProbeServingEvidence(plan: plan), evidence.runtime == "strata",
              evidence.modelFingerprint == proof.modelFingerprint, evidence.runtimeFingerprint == proof.runtimeFingerprint,
              evidence.speculation == options.speculation, evidence.expertMemoryGB == options.expertMemoryGB,
              evidence.contextTokens == options.contextTokens else {
            throw WorkflowEvidenceError.invalid("This serving profile needs verification for the current model, runtime and settings.")
        }
    }

    func preview(api: WorkbenchAPI, port: Int?, jit: Bool = false, policy: EndpointMemoryPolicy? = nil) async throws -> [String: Any] {
        guard hasPassedVerification else { throw WorkflowEvidenceError.invalid("Verify the serving profile before previewing it.") }
        let plan = try await api.servePreview(repo: modelPath, runtime: "strata", port: port,
                                              jit: jit, memoryPolicy: policy, strataOptions: options)
        try validate(plan: plan)
        return plan
    }

    func start(api: WorkbenchAPI, port: Int?, hash: String, jit: Bool = false, policy: EndpointMemoryPolicy? = nil) async throws -> [String: Any] {
        let plan = try await preview(api: api, port: port, jit: jit, policy: policy)
        guard plan.string("preview_hash") == hash else {
            throw WorkflowEvidenceError.invalid("The serving profile preview changed. Preview it again before confirming.")
        }
        return try await api.serveStart(repo: modelPath, runtime: "strata", port: port, previewHash: hash,
                                       jit: jit, memoryPolicy: policy, timeout: 960, strataOptions: options)
    }

    /// Receipt ownership is established by serve status; bind its exact confirmed plan as well.
    static func matchesReceipt(_ server: ServerInfo, previewHash: String?) -> Bool {
        guard let previewHash, !previewHash.isEmpty, let pid = server.pid, let port = server.port,
              !server.modelIdentity.isEmpty, let location = server.receipt,
              let attributes = try? FileManager.default.attributesOfItem(atPath: location),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 65536,
              let data = try? Data(contentsOf: URL(fileURLWithPath: location)),
              let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return receipt["preview_hash"] as? String == previewHash && receipt["pid"] as? Int == pid
            && receipt["port"] as? Int == port
            && (receipt["path"] ?? receipt["repo"]) as? String == server.modelIdentity
    }
}

extension ServeLifecycle {
    static func verifiedProfile(_ profile: ServingProfile, api: WorkbenchAPI) -> ServeLifecycle {
        var lifecycle = live(api: api, runtime: "strata", strataOptions: profile.options)
        lifecycle.reviewedPreview = { path, port in
            guard path == profile.modelPath else { throw WorkflowEvidenceError.invalid("Serving profile model changed.") }
            let plan = try await profile.preview(api: api, port: port)
            return ProbeServePreview(hash: plan.string("preview_hash") ?? "", evidence: ProbeServingEvidence(plan: plan))
        }
        lifecycle.preview = { path, port in
            guard path == profile.modelPath else { throw WorkflowEvidenceError.invalid("Serving profile model changed.") }
            return try await profile.preview(api: api, port: port).string("preview_hash") ?? ""
        }
        lifecycle.start = { path, port, hash in
            guard path == profile.modelPath else { throw WorkflowEvidenceError.invalid("Serving profile model changed.") }
            _ = try await profile.start(api: api, port: port, hash: hash)
        }
        lifecycle.jitPreview = { path, port, policy in
            guard path == profile.modelPath else { throw WorkflowEvidenceError.invalid("Serving profile model changed.") }
            return try await profile.preview(api: api, port: port, jit: true, policy: policy).string("preview_hash") ?? ""
        }
        lifecycle.jitStart = { path, port, hash, policy in
            guard path == profile.modelPath else { throw WorkflowEvidenceError.invalid("Serving profile model changed.") }
            _ = try await profile.start(api: api, port: port, hash: hash, jit: true, policy: policy)
        }
        return lifecycle
    }
}

@MainActor
final class ServingProfileCoordinator: ObservableObject {
    @Published private(set) var profiles: [ServingProfile] = []
    @Published private(set) var activeID: UUID?
    @Published private(set) var lastError: String?
    /// Without an authoritative endpoint reference check, removal is refused.
    var removalGuard: ((UUID) throws -> Void)?
    var suggestionSource: ((ComparisonRun) throws -> VariantResult)?
    var comparisonSource: ((UUID) throws -> ComparisonRun?)?
    private let store: JSONStore<ServingProfile>
    private let probe: @Sendable (StrataComparisonOptions) -> ServeProbe

    init(store: JSONStore<ServingProfile>, probe: @escaping @Sendable (StrataComparisonOptions) -> ServeProbe) {
        self.store = store; self.probe = probe
        do { profiles = try store.load() }
        catch { lastError = "Serving profiles could not be loaded: \(AppHost.render(error))" }
    }

    @discardableResult
    func saveLane(run: ComparisonRun, laneID: String, name: String) -> ServingProfile? {
        do {
            guard run.state == .completed, run.effectiveMode == .chat,
                  let result = run.results.first(where: { $0.id == laneID }), result.error == nil,
                  let evidence = result.servingEvidence, evidence.runtime == "strata",
                  let speculation = evidence.speculation, let context = evidence.contextTokens else {
                throw WorkflowEvidenceError.invalid("Select a successful Strata lane with recorded serving settings.")
            }
            let profile = ServingProfile(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), modelPath: result.modelPath,
                options: StrataComparisonOptions(speculation: speculation, expertMemoryGB: evidence.expertMemoryGB, contextTokens: context),
                sourceRunID: run.id, sourceLaneID: result.id)
            guard profile.isValid else { throw WorkflowEvidenceError.invalid("Enter a profile name of 1–80 characters and valid settings.") }
            try store.upsert(profile, id: \.id)
            profiles = try store.load()
            lastError = nil
            return profile
        } catch { lastError = AppHost.render(error); return nil }
    }

    func resolve(_ requested: ServingProfile) throws -> ServingProfile {
        guard activeID != requested.id else { throw WorkflowEvidenceError.invalid("Profile verification is in progress.") }
        guard let current = try store.load().first(where: { $0.id == requested.id }),
              current.modelPath == requested.modelPath, current.options == requested.options, current.hasPassedVerification else {
            throw WorkflowEvidenceError.invalid("The current serving profile requires verification.")
        }
        return current
    }

    func comparisonEvidence(for requested: ServingProfile) throws -> ServingProfileComparisonEvidence {
        guard let current = try store.load().first(where: { $0.id == requested.id }),
              current.modelPath == requested.modelPath, current.options == requested.options else {
            throw WorkflowEvidenceError.invalid("The serving profile changed or is no longer available. Select it again.")
        }
        guard let id = current.sourceRunID, current.sourceLaneID != nil else {
            throw WorkflowEvidenceError.invalid("This profile has no recorded source comparison.")
        }
        guard let comparisonSource, let run = try comparisonSource(id) else {
            throw WorkflowEvidenceError.invalid("The source comparison is unavailable. The profile and its canary verdict are unchanged.")
        }
        return try ServingProfileComparisonEvidence(profile: current, run: run)
    }

    @discardableResult
    func createCopy(_ draft: ServingProfileCopyDraft) -> ServingProfile? {
        do {
            guard activeID == nil else { throw WorkflowEvidenceError.invalid("Wait for profile verification to finish.") }
            if let error = draft.validationError { throw WorkflowEvidenceError.invalid(error) }
            guard draft.original.isValid else { throw WorkflowEvidenceError.invalid("The source profile is invalid.") }
            let sameSettings = draft.options == draft.original.options
            let copy = ServingProfile(id: UUID(), name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                modelPath: draft.original.modelPath, options: draft.options,
                sourceRunID: sameSettings ? draft.original.sourceRunID : nil,
                sourceLaneID: sameSettings ? draft.original.sourceLaneID : nil)
            guard try store.insert(copy, requiring: draft.original, id: \.id) else {
                throw WorkflowEvidenceError.invalid("The source profile changed or is no longer available. Reopen Customize copy.")
            }
            profiles = try store.load(); lastError = nil
            return copy
        } catch { lastError = AppHost.render(error); return nil }
    }

    func createSuggestedProfile(run: ComparisonRun, name: String) -> ServingProfile? {
        do {
            guard activeID == nil, let suggestionSource else { throw WorkflowEvidenceError.invalid("Suggestion verification is unavailable or already running.") }
            let result = try suggestionSource(run)
            return saveLane(run: run, laneID: result.id, name: name)
        } catch { lastError = AppHost.render(error); return nil }
    }

    func verifySuggestion(run: ComparisonRun, profileID: UUID) async {
        do {
            guard activeID == nil, let suggestionSource else { throw WorkflowEvidenceError.invalid("Suggestion verification is unavailable or already running.") }
            let result = try suggestionSource(run)
            guard let evidence = result.servingEvidence, let context = evidence.contextTokens, let speculation = evidence.speculation,
                  let profile = try store.load().first(where: { $0.id == profileID }), profile.sourceRunID == run.id,
                  profile.sourceLaneID == result.id, profile.modelPath == result.modelPath,
                  profile.options == StrataComparisonOptions(speculation: speculation, expertMemoryGB: evidence.expertMemoryGB, contextTokens: context) else {
                throw WorkflowEvidenceError.invalid("The saved profile no longer matches this suggestion.")
            }
            await verify(id: profileID, expectedEvidence: evidence, beforePublishing: { _ = try suggestionSource(run) })
        } catch { lastError = AppHost.render(error) }
    }

    @discardableResult
    func profileForManagement(_ id: UUID) -> ServingProfile? {
        do {
            guard activeID == nil else { throw WorkflowEvidenceError.invalid("Wait for profile verification to finish.") }
            let loaded = try store.load()
            profiles = loaded
            guard let current = loaded.first(where: { $0.id == id }) else {
                throw WorkflowEvidenceError.invalid("The serving profile is no longer available.")
            }
            lastError = nil
            return current
        } catch { lastError = AppHost.render(error); return nil }
    }

    @discardableResult
    func rename(_ original: ServingProfile, name: String) -> ServingProfile? {
        do {
            guard activeID == nil else { throw WorkflowEvidenceError.invalid("Wait for profile verification to finish.") }
            if let error = ServingProfile.nameValidationError(name) { throw WorkflowEvidenceError.invalid(error) }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != original.name else { throw WorkflowEvidenceError.invalid("Choose a different profile name.") }
            var renamed = original; renamed.name = trimmed
            let changed = try store.update(id: original.id, keyPath: \.id) { current in
                guard current == original else { throw WorkflowEvidenceError.invalid("The profile changed. Reopen Rename to use its current name.") }
                return renamed
            }
            guard changed else { throw WorkflowEvidenceError.invalid("The serving profile is no longer available.") }
            profiles = try store.load(); lastError = nil
            return renamed
        } catch { lastError = AppHost.render(error); return nil }
    }

    @discardableResult
    func remove(_ original: ServingProfile) -> Bool {
        do {
            guard activeID == nil else { throw WorkflowEvidenceError.invalid("Wait for profile verification to finish.") }
            guard let removalGuard else { throw WorkflowEvidenceError.invalid("Endpoint references could not be checked. The profile was kept.") }
            let changed = try store.update(id: original.id, keyPath: \.id) { current in
                guard current == original else { throw WorkflowEvidenceError.invalid("The profile changed. Review it again before removal.") }
                try removalGuard(original.id)
                return nil
            }
            guard changed else { throw WorkflowEvidenceError.invalid("The serving profile is no longer available.") }
            profiles = try store.load(); lastError = nil
            return true
        } catch { lastError = AppHost.render(error); return false }
    }

    /// Uses the existing canaries with an explicit 1,024-token answer budget for thinking models.
    func verify(id: UUID, expectedEvidence: ProbeServingEvidence? = nil, beforePublishing: (() throws -> Void)? = nil) async {
        guard activeID == nil, let saved = profiles.first(where: { $0.id == id }), saved.isValid else { return }
        var original = saved
        activeID = id; lastError = nil
        defer { activeID = nil }
        do {
            if original.verification != nil {
                var cleared = original; cleared.verification = nil
                let invalidated = try store.update(id: id, keyPath: \.id) { current in
                    guard current == saved else { throw WorkflowEvidenceError.invalid("The profile changed before verification.") }; return cleared
                }
                guard invalidated else { throw WorkflowEvidenceError.invalid("The profile is no longer available.") }
                original = cleared; profiles = try store.load()
            }
            let prompts = CanarySuite.cases.map { ProbePrompt(id: $0.id, prompt: $0.prompt, maxTokens: max(1024, $0.maxTokens)) }
            var selectedProbe = probe(original.options)
            selectedProbe.expectedServingEvidence = expectedEvidence
            let outcome = try await selectedProbe.run(modelPath: original.modelPath, prompts: prompts)
            guard let evidence = outcome.servingEvidence, evidence.runtime == "strata",
                  let model = evidence.modelFingerprint, let runtime = evidence.runtimeFingerprint,
                  evidence.speculation == original.options.speculation, evidence.expertMemoryGB == original.options.expertMemoryGB,
                  evidence.contextTokens == original.options.contextTokens else {
                throw WorkflowEvidenceError.invalid("The verification server did not record the selected settings and fingerprints.")
            }
            let canaries = CanarySuite.cases.map { kase -> CanaryResult in
                guard let sample = outcome.samples[kase.id] else {
                    return CanaryResult(id: kase.id, title: kase.title, passed: false, failureReason: "Canary response missing.",
                                        responseExcerpt: "", tokensPerSecond: nil, timeToFirstTokenSeconds: nil)
                }
                let evaluated = CanarySuite.evaluate(kase, sample: sample)
                guard sample.finishReason == "stop" else {
                    return CanaryResult(id: kase.id, title: kase.title, passed: false, failureReason: "The answer did not finish normally.",
                        responseExcerpt: evaluated.responseExcerpt, tokensPerSecond: evaluated.tokensPerSecond,
                        timeToFirstTokenSeconds: evaluated.timeToFirstTokenSeconds)
                }
                return evaluated
            }
            let proof = ServingProfileVerification(options: original.options, modelFingerprint: model, runtimeFingerprint: runtime,
                suiteVersion: CanarySuite.version, canaries: canaries, verifiedAt: Date())
            try beforePublishing?()
            var updated = original; updated.verification = proof
            let changed = try store.update(id: id, keyPath: \.id) { current in
                guard current == original else { throw WorkflowEvidenceError.invalid("The profile changed during verification. Verify its current settings.") }
                return updated
            }
            guard changed else { throw WorkflowEvidenceError.invalid("The serving profile is no longer available.") }
            profiles = try store.load()
            if !proof.passed { lastError = "Profile verification failed. Inspect the recorded canary failures before serving." }
        } catch {
            lastError = AppHost.render(error)
            // A failed re-verification never leaves a previous passing verdict in use.
            do {
                _ = try store.update(id: id, keyPath: \.id) { current in
                    guard current == original else { return current }
                    var invalidated = current; invalidated.verification = nil; return invalidated
                }
                profiles = try store.load()
            } catch { profiles = []; lastError = "Serving profile state could not be saved: \(AppHost.render(error))" }
        }
    }
}
