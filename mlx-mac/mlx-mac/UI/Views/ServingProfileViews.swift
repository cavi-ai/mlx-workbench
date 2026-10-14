import SwiftUI

enum ServingProfileSaveAction {
    case save
    case verifySuggestion
    case verifyMeasured(ServingProfile)
}

struct ServingProfileSaveRequest: Identifiable {
    let id = UUID()
    let run: ComparisonRun
    let laneID: String
    let letter: String
    var action: ServingProfileSaveAction = .save
}

struct ComparisonProfileVerificationSheet: View {
    @ObservedObject var profiles: ServingProfileCoordinator
    let request: ServingProfileSaveRequest
    let onOpenRun: (ServingProfile) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var profileID: UUID?
    @State private var working = false
    @State private var error: String?
    @State private var verifiedInSheet = false

    private var profile: ServingProfile? { profiles.profiles.first { $0.id == profileID } }
    private var existingProfile: ServingProfile? {
        if case .verifyMeasured(let profile) = request.action { return profile }
        return nil
    }
    private var hasPassed: Bool {
        verifiedInSheet && profile?.hasPassedVerification == true
            && profile?.sourceRunID == request.run.id && profile?.sourceLaneID == request.laneID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text(existingProfile == nil ? "Verify suggested lane \(request.letter)" : "Verify measured lane \(request.letter)").font(WorkbenchTypography.cardTitle)
            Text(existingProfile == nil
                 ? "Save a named profile and run the canary checks with this lane's recorded settings. The comparison and model/runtime fingerprints are checked again. Verification temporarily loads the model and stops its test server afterward."
                 : "Attach this comparison to the existing profile and run fresh canary checks. Starting clears its previous canary verdict. The comparison and model/runtime fingerprints are rechecked. Verification temporarily loads the model and stops its test server afterward.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            if let existingProfile {
                Text(profile?.name ?? existingProfile.name).font(WorkbenchTypography.label)
                Text("Draft-and-verify \(existingProfile.options.speculation ? "on" : "off") · expert memory \(existingProfile.options.expertMemoryGB.map { "\($0.formatted()) GB" } ?? "automatic") · \(existingProfile.options.contextTokens) context tokens")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            } else { TextField("Profile name", text: $name).textFieldStyle(.roundedBorder).disabled(profileID != nil || working) }
            if working { ProgressView("Verifying profile…") }
            if let profile {
                Text(hasPassed ? "Canaries passed. Open Run to review and confirm serving." : "Verification has not passed for this action. Retry uses this same profile.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                if let proof = profile.verification, existingProfile == nil || hasPassed || !proof.passed {
                    ForEach(proof.canaries, id: \.id) { canary in
                        Text("\(canary.title): \(canary.passed ? "passed" : canary.failureReason ?? "failed")")
                            .font(WorkbenchTypography.metadata).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ErrorBanner(text: error)
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Spacer()
                if let profile, hasPassed {
                    Button("Open Run") {
                        error = onOpenRun(profile)
                        if error == nil { dismiss() }
                    }.keyboardShortcut(.defaultAction)
                } else {
                    Button(profileID == nil ? (existingProfile == nil ? "Save and verify" : "Attach and verify") : "Retry verification", action: startVerification)
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || profiles.activeID != nil || (existingProfile == nil && ServingProfile.nameValidationError(name) != nil))
                }
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 520)
            .interactiveDismissDisabled(working)
    }

    private func startVerification() {
        working = true; error = nil; verifiedInSheet = false
        Task {
            if let existingProfile {
                let expected = profileID == nil ? existingProfile : profile
                profileID = existingProfile.id
                if let expected { await profiles.verifyMeasuredLane(run: request.run, laneID: request.laneID, original: expected) }
                else { error = "The profile is no longer available." }
            } else {
                if profileID == nil { profileID = profiles.createSuggestedProfile(run: request.run, name: name)?.id }
                if let profileID { await profiles.verifySuggestion(run: request.run, profileID: profileID) }
            }
            error = error ?? profiles.lastError
            verifiedInSheet = error == nil && profile?.hasPassedVerification == true
            working = false
        }
    }
}

struct SaveServingProfileSheet: View {
    @ObservedObject var profiles: ServingProfileCoordinator
    let request: ServingProfileSaveRequest
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Save lane \(request.letter) as a serving profile").font(WorkbenchTypography.cardTitle)
            Text("Saving keeps its recorded settings. Verify the profile in Run before using it.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            TextField("Profile name", text: $name).textFieldStyle(.roundedBorder)
            ErrorBanner(text: profiles.lastError)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save profile") {
                    if profiles.saveLane(run: request.run, laneID: request.laneID, name: name) != nil { dismiss() }
                }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 460)
    }
}

struct ServingProfileControls: View {
    @ObservedObject var profiles: ServingProfileCoordinator
    @ObservedObject var workflow: ModelWorkflowCoordinator
    @ObservedObject var endpoint: EndpointSupervisor
    let modelPath: String?
    var onCompare: ((ServingProfileComparisonSetup) -> String?)? = nil
    @State private var port = String(EndpointConfig.defaultPort)
    @State private var jit = true
    @State private var renameRequest: ServingProfile?
    @State private var removalRequest: ServingProfile?
    @State private var copyRequest: ServingProfile?
    @State private var comparisonRequest: ServingProfile?
    @State private var evidenceRequest: ServingProfileComparisonEvidence?
    @State private var evidenceError: String?
    @State private var chooserRequest: ServingProfileChooserRequest?

    private var choices: [ServingProfile] { profiles.profiles.filter { $0.modelPath == modelPath } }
    private var selected: ServingProfile? { profiles.profiles.first { $0.id == workflow.servingProfile?.id } }

    var body: some View {
        if !choices.isEmpty || workflow.servingProfile != nil {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                Picker("Serving profile", selection: Binding<UUID?>(
                    get: { workflow.servingProfile?.id },
                    set: { id in
                        evidenceError = nil
                        workflow.selectServingProfile(id.flatMap { id in choices.first { $0.id == id } })
                    })) {
                    Text("Runtime defaults").tag(Optional<UUID>.none)
                    ForEach(choices) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }.disabled(workflow.isServeSubmissionInFlight || profiles.activeID != nil)
                Button("Review profiles…") {
                    guard let modelPath else { return }
                    do {
                        chooserRequest = ServingProfileChooserRequest(modelPath: modelPath,
                            choices: try profiles.profileChoices(modelPath: modelPath))
                        evidenceError = nil
                    } catch { evidenceError = AppHost.render(error) }
                }.disabled(workflow.isServeSubmissionInFlight || profiles.activeID != nil || modelPath == nil)
                if let profile = selected {
                    Text("Draft-and-verify \(profile.options.speculation ? "on" : "off") · expert memory \(profile.options.expertMemoryGB.map { "\($0.formatted()) GB" } ?? "automatic") · \(profile.options.contextTokens) context tokens")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    Text(profile.hasPassedVerification ? "Canaries passed. Settings and fingerprints are checked again before serving." : "Profile verification is required before serving.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    HStack {
                        Button("Comparison evidence…") {
                            do { evidenceRequest = try profiles.comparisonEvidence(for: profile); evidenceError = nil }
                            catch { evidenceError = AppHost.render(error) }
                        }
                        Button(profiles.activeID == profile.id ? "Verifying…" : "Verify profile") {
                            Task {
                                await profiles.verify(id: profile.id)
                                if workflow.servingProfile?.id == profile.id {
                                    workflow.selectServingProfile(profiles.profiles.first { $0.id == profile.id })
                                }
                            }
                        }
                        Menu("Manage profile") {
                            Button("Compare profiles…") { comparisonRequest = profiles.profileForManagement(profile.id) }
                                .disabled(onCompare == nil || choices.filter(\.isValid).count < 2)
                            Button("Customize copy…") { copyRequest = profiles.profileForManagement(profile.id) }
                            Button("Rename…") { renameRequest = profiles.profileForManagement(profile.id) }
                            Button("Remove…", role: .destructive) { removalRequest = profiles.profileForManagement(profile.id) }
                        }.fixedSize()
                    }.disabled(profiles.activeID != nil || workflow.isServeSubmissionInFlight)
                    if let proof = profile.verification {
                        DisclosureGroup("Canary results") {
                            ForEach(proof.canaries, id: \.id) { canary in
                                Text("\(canary.title): \(canary.passed ? "passed" : canary.failureReason ?? "failed")")
                                    .font(WorkbenchTypography.metadata).textSelection(.enabled)
                            }
                        }
                    }
                    HStack {
                        TextField("Endpoint port", text: $port).frame(width: 110).textFieldStyle(.roundedBorder)
                        Toggle("Load on request", isOn: $jit)
                        Button("Use profile for endpoint") {
                            guard let number = Int(port) else { return }
                            Task { await endpoint.enableProfile(profile, port: number, loadOnRequest: jit) }
                        }.disabled(!profile.hasPassedVerification || profiles.activeID != nil || Int(port).map { !(1...65535).contains($0) } ?? true)
                    }
                    Text("The endpoint keeps this profile across relaunches. Its loopback port stays stable.")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
                ErrorBanner(text: evidenceError)
                ErrorBanner(text: profiles.lastError)
                ErrorBanner(text: endpoint.lastError)
            }.padding(.vertical, WorkbenchSpacing.sm)
                .sheet(item: $evidenceRequest) { evidence in ServingProfileComparisonSheet(evidence: evidence) }
                .sheet(item: $chooserRequest) { request in
                    ServingProfileChooserSheet(profiles: profiles, request: request, selectedID: workflow.servingProfile?.id) { profile in
                        guard !workflow.isServeSubmissionInFlight, profile.modelPath == workflow.workflow.completedModelPath else {
                            return "The Run model changed or serving is in progress. Reopen profile selection."
                        }
                        workflow.selectServingProfile(profile)
                        return nil
                    }
                }
                .sheet(item: $copyRequest) { profile in
                    ServingProfileCopySheet(profiles: profiles, profile: profile) { copy in workflow.selectServingProfile(copy) }
                }
                .sheet(item: $comparisonRequest) { profile in
                    ServingProfileComparisonSetupSheet(profiles: profiles, baseline: profile) { setup in
                        guard let onCompare else { return "Comparison setup is unavailable." }
                        return onCompare(setup)
                    }
                }
                .sheet(item: $renameRequest) { profile in
                    ServingProfileRenameSheet(profiles: profiles, profile: profile) { renamed in
                        if workflow.servingProfile?.id == renamed.id { workflow.selectServingProfile(renamed) }
                    }
                }
                .sheet(item: $removalRequest) { profile in
                    ServingProfileRemovalSheet(profiles: profiles, profile: profile) {
                        if workflow.servingProfile?.id == profile.id { workflow.selectServingProfile(nil) }
                    }
                }
        }
    }
}

struct ServingProfileChooserRequest: Identifiable {
    let id = UUID()
    let modelPath: String
    let choices: [ServingProfileChoice]
}

struct ServingProfileChooserSheet: View {
    @ObservedObject var profiles: ServingProfileCoordinator
    let request: ServingProfileChooserRequest
    let selectedID: UUID?
    let onSelect: (ServingProfile) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [ServingProfileChoice]
    @State private var error: String?

    init(profiles: ServingProfileCoordinator, request: ServingProfileChooserRequest, selectedID: UUID?,
         onSelect: @escaping (ServingProfile) -> String?) {
        self.profiles = profiles; self.request = request; self.selectedID = selectedID; self.onSelect = onSelect
        _choices = State(initialValue: request.choices)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Choose a serving profile").font(WorkbenchTypography.cardTitle)
            Text("Review saved settings and measurements for this model. Selecting a profile returns to Run; preview and confirmation are still required.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                    if choices.isEmpty { Text("No saved profiles for this model.").font(WorkbenchTypography.secondary) }
                    ForEach(choices) { choice in
                        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(choice.profile.name).font(WorkbenchTypography.label).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                if choice.id == selectedID { Text("Selected").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted) }
                            }
                            Text("Draft-and-verify \(choice.profile.options.speculation ? "on" : "off") · expert memory \(choice.profile.options.expertMemoryGB.map { "\($0.formatted()) GB" } ?? "automatic") · \(choice.profile.options.contextTokens) context tokens")
                                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
                            Text(choice.profile.hasPassedVerification ? "Canaries passed · serving rechecks fingerprints" : "Canary verification required")
                                .font(WorkbenchTypography.secondary)
                            if let evidence = choice.evidence {
                                Text("\(evidence.run.promptSetName) · recorded \((evidence.run.finishedAt ?? evidence.run.startedAt).formatted(date: .abbreviated, time: .shortened))")
                                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
                                LabeledContent("Median first answer", value: evidence.result.memoryTradeoffAnswerSeconds.map {
                                    "\($0.formatted(.number.precision(.fractionLength(2)))) s"
                                } ?? "Not recorded for every answer")
                                LabeledContent("Lowest system headroom", value: evidence.memory.map {
                                    "\((Double($0.minimumAvailableBytes) / 1e9).formatted(.number.precision(.fractionLength(1)))) GB"
                                } ?? "Not recorded")
                                LabeledContent("Task review", value: evidence.taskReview.map { ComparisonQualityReview.taskScoreTitle($0.score) } ?? "Not recorded")
                            } else {
                                Text("Comparison evidence unavailable: \(choice.evidenceUnavailableReason ?? "Not recorded")")
                                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            if !choice.profile.isValid {
                                Text("This saved profile has invalid settings.").font(WorkbenchTypography.secondary)
                            }
                            Button("Select profile") { select(choice) }
                                .disabled(!choice.profile.isValid || profiles.activeID != nil)
                                .accessibilityLabel("Select profile \(choice.profile.name)")
                            Divider()
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Measurements retain their recorded prompt sets and dates. System headroom includes other apps and file caching; it does not measure model-only RAM or predict available RAM now.")
                .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            ErrorBanner(text: error)
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Refresh profiles", action: refresh).disabled(profiles.activeID != nil)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 600, height: 640)
    }

    private func select(_ choice: ServingProfileChoice) {
        do {
            let profile = try profiles.selectChoice(choice, modelPath: request.modelPath)
            error = onSelect(profile)
            if error == nil { dismiss() }
        } catch { self.error = AppHost.render(error) }
    }

    private func refresh() {
        do { choices = try profiles.profileChoices(modelPath: request.modelPath); error = nil }
        catch { choices = []; self.error = AppHost.render(error) }
    }
}

struct ServingProfileComparisonSetupSheet: View {
    @ObservedObject var profiles: ServingProfileCoordinator
    let baseline: ServingProfile
    let onUse: (ServingProfileComparisonSetup) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var candidateID: UUID?
    @State private var error: String?

    private var choices: [ServingProfile] { profiles.profiles.filter { $0.id != baseline.id && $0.modelPath == baseline.modelPath && $0.isValid } }
    private var candidate: ServingProfile? { choices.first { $0.id == candidateID } }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Compare serving profiles").font(WorkbenchTypography.cardTitle)
            Text("Prepare two configurations of this local model in Compare. Choose one shared prompt set there, then explicitly run the comparison. Measurements do not change either profile's verification or your endpoint.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            Text("A · \(baseline.name)").font(WorkbenchTypography.label)
            settings(baseline)
            Picker("B · Comparison profile", selection: $candidateID) {
                Text("Choose a profile").tag(Optional<UUID>.none)
                ForEach(choices) { profile in Text(profile.name).tag(Optional(profile.id)) }
            }
            if let candidate { settings(candidate) }
            if candidate?.options == baseline.options {
                Text("Choose a profile with different settings.").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            }
            ErrorBanner(text: error)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use setup", action: useSetup).keyboardShortcut(.defaultAction)
                    .disabled(candidate == nil || candidate?.options == baseline.options || profiles.activeID != nil)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 520)
            .onChange(of: candidateID) { _, _ in error = nil }
    }

    private func settings(_ profile: ServingProfile) -> some View {
        Text("Draft-and-verify \(profile.options.speculation ? "on" : "off") · expert memory \(profile.options.expertMemoryGB.map { "\($0.formatted()) GB" } ?? "automatic") · \(profile.options.contextTokens) context tokens")
            .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
    }

    private func useSetup() {
        guard let candidate else { return }
        do {
            let setup = try profiles.prepareComparison(baseline: baseline, candidate: candidate)
            error = onUse(setup)
            if error == nil { dismiss() }
        } catch { self.error = AppHost.render(error) }
    }
}

struct ServingProfileCopySheet: View {
    @ObservedObject var profiles: ServingProfileCoordinator
    let onSaved: (ServingProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ServingProfileCopyDraft
    @State private var error: String?
    @State private var confirmingDiscard = false

    init(profiles: ServingProfileCoordinator, profile: ServingProfile, onSaved: @escaping (ServingProfile) -> Void) {
        self.profiles = profiles; self.onSaved = onSaved
        _draft = State(initialValue: ServingProfileCopyDraft(original: profile))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Customize profile copy").font(WorkbenchTypography.cardTitle)
            Text("Copy settings from “\(draft.original.name)”. The new profile uses the same local model and requires its own canary verification. Your original profile and endpoint settings stay intact.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            TextField("Profile name", text: $draft.name).textFieldStyle(.roundedBorder)
            StrataComparisonControls(options: $draft.options,
                helpText: "A smaller expert budget pages more weights from disk. Changed settings need new measurements; the copy does not inherit comparison evidence for different settings.")
            ErrorBanner(text: ServingProfile.nameValidationError(draft.name) ?? error)
            HStack {
                Button("Cancel") { if draft.hasChanges { confirmingDiscard = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save copy") {
                    if let copy = profiles.createCopy(draft) { onSaved(copy); dismiss() }
                    else { error = profiles.lastError }
                }.keyboardShortcut(.defaultAction).disabled(draft.validationError != nil || profiles.activeID != nil)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 520)
            .onChange(of: draft.name) { _, _ in error = nil }
            .onChange(of: draft.options) { _, _ in error = nil }
            .interactiveDismissDisabled(draft.hasChanges)
            .alert("Discard profile copy changes?", isPresented: $confirmingDiscard) {
                Button("Keep editing", role: .cancel) { }
                Button("Discard changes", role: .destructive) { dismiss() }
            }
    }
}

struct ServingProfileComparisonSheet: View {
    let evidence: ServingProfileComparisonEvidence
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Comparison evidence").font(WorkbenchTypography.cardTitle)
            Text(evidence.profile.name).font(WorkbenchTypography.label)
            Text("\(evidence.run.promptSetName) · recorded \((evidence.run.finishedAt ?? evidence.run.startedAt).formatted(date: .abbreviated, time: .shortened))")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            Text("\(evidence.result.samples.count) recorded \(evidence.result.samples.count == 1 ? "prompt" : "prompts") · draft-and-verify \(evidence.profile.options.speculation ? "on" : "off") · expert memory \(evidence.profile.options.expertMemoryGB.map { "\($0.formatted()) GB" } ?? "automatic") · \(evidence.profile.options.contextTokens) context tokens")
                .font(WorkbenchTypography.metadata).fixedSize(horizontal: false, vertical: true)
            if let seconds = evidence.result.memoryTradeoffAnswerSeconds {
                LabeledContent("Median time to first answer", value: "\(seconds.formatted(.number.precision(.fractionLength(2)))) s")
            } else { LabeledContent("Median time to first answer", value: "Not recorded for every finished answer") }
            if let memory = evidence.memory {
                LabeledContent("Lowest sampled system headroom", value: "\((Double(memory.minimumAvailableBytes) / 1e9).formatted(.number.precision(.fractionLength(1)))) GB")
                Text("\(memory.sampleCount) readings · \(memory.missedSamples) unavailable · \(memory.samplingIntervalSeconds.formatted()) s interval")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            } else { LabeledContent("System headroom", value: "Not recorded") }
            if let review = evidence.taskReview {
                LabeledContent("Task review", value: ComparisonQualityReview.taskScoreTitle(review.score))
                Text("Reviewed \(review.reviewedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
            } else { LabeledContent("Task review", value: "Not recorded") }
            Text("These are saved measurements and the current saved task review. System headroom includes other apps and file caching; it does not measure model-only RAM or guarantee future headroom.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            Text(evidence.profile.hasPassedVerification
                ? "Canaries passed separately. Serving still rechecks the model, runtime and settings."
                : "Canary verification is required before serving this profile.")
                .font(WorkbenchTypography.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(WorkbenchSpacing.lg).frame(width: 560)
    }
}

struct ServingProfileRenameSheet: View {
    @ObservedObject var profiles: ServingProfileCoordinator
    let profile: ServingProfile
    let onRenamed: (ServingProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    @State private var confirmingDiscard = false

    init(profiles: ServingProfileCoordinator, profile: ServingProfile, onRenamed: @escaping (ServingProfile) -> Void) {
        self.profiles = profiles; self.profile = profile; self.onRenamed = onRenamed
        _name = State(initialValue: profile.name)
    }

    private var validation: String? { ServingProfile.nameValidationError(name) }
    private var dirty: Bool { name != profile.name }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Rename serving profile").font(WorkbenchTypography.cardTitle)
            Text("Renaming preserves its settings and verification.").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            TextField("Profile name", text: $name).textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, _ in error = nil }
            ErrorBanner(text: validation ?? error)
            HStack {
                Button("Cancel") { if dirty { confirmingDiscard = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename") {
                    if let renamed = profiles.rename(profile, name: name) { onRenamed(renamed); dismiss() }
                    else { error = profiles.lastError }
                }.keyboardShortcut(.defaultAction)
                    .disabled(validation != nil || name.trimmingCharacters(in: .whitespacesAndNewlines) == profile.name || profiles.activeID != nil)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 460)
            .interactiveDismissDisabled(dirty)
            .alert("Discard profile name changes?", isPresented: $confirmingDiscard) {
                Button("Keep editing", role: .cancel) { }
                Button("Discard changes", role: .destructive) { dismiss() }
            }
    }
}

struct ServingProfileRemovalSheet: View {
    @ObservedObject var profiles: ServingProfileCoordinator
    let profile: ServingProfile
    let onRemoved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Remove “\(profile.name)”?").font(WorkbenchTypography.cardTitle)
            Text("This removes the saved profile and its verification. Model files, past comparisons and running servers are unchanged.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            Text("Configured endpoints must release this profile first, including disabled endpoints.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            ErrorBanner(text: error)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Remove profile", role: .destructive) {
                    if profiles.remove(profile) { onRemoved(); dismiss() }
                    else { error = profiles.lastError }
                }.disabled(profiles.activeID != nil)
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 460)
    }
}
