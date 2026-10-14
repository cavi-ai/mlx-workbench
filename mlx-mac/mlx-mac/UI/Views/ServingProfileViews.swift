import SwiftUI

struct ServingProfileSaveRequest: Identifiable {
    let id = UUID()
    let run: ComparisonRun
    let laneID: String
    let letter: String
    var verifySuggestion = false
}

struct SuggestedProfileVerificationSheet: View {
    @ObservedObject var profiles: ServingProfileCoordinator
    let request: ServingProfileSaveRequest
    let onOpenRun: (ServingProfile) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var profileID: UUID?
    @State private var working = false
    @State private var error: String?

    private var profile: ServingProfile? { profiles.profiles.first { $0.id == profileID } }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Verify suggested lane \(request.letter)").font(WorkbenchTypography.cardTitle)
            Text("Save a named profile and run the canary checks with this lane's recorded settings. The comparison and model/runtime fingerprints are checked again. Verification temporarily loads the model and stops its test server afterward.")
                .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted).fixedSize(horizontal: false, vertical: true)
            TextField("Profile name", text: $name).textFieldStyle(.roundedBorder).disabled(profileID != nil || working)
            if working { ProgressView("Verifying profile…") }
            if let profile {
                Text(profile.hasPassedVerification ? "Canaries passed. Open Run to review and confirm serving." : "Profile saved; verification has not passed. Retry uses this same profile.")
                    .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                if let proof = profile.verification {
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
                if let profile, profile.hasPassedVerification {
                    Button("Open Run") {
                        error = onOpenRun(profile)
                        if error == nil { dismiss() }
                    }.keyboardShortcut(.defaultAction)
                } else {
                    Button(profileID == nil ? "Save and verify" : "Retry verification") {
                        working = true; error = nil
                        Task {
                            if profileID == nil { profileID = profiles.createSuggestedProfile(run: request.run, name: name)?.id }
                            if let profileID { await profiles.verifySuggestion(run: request.run, profileID: profileID) }
                            error = profiles.lastError; working = false
                        }
                    }.keyboardShortcut(.defaultAction)
                        .disabled(working || profiles.activeID != nil || ServingProfile.nameValidationError(name) != nil)
                }
            }
        }.padding(WorkbenchSpacing.lg).frame(width: 520)
            .interactiveDismissDisabled(working)
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
    @State private var port = String(EndpointConfig.defaultPort)
    @State private var jit = true
    @State private var renameRequest: ServingProfile?
    @State private var removalRequest: ServingProfile?

    private var choices: [ServingProfile] { profiles.profiles.filter { $0.modelPath == modelPath } }
    private var selected: ServingProfile? { profiles.profiles.first { $0.id == workflow.servingProfile?.id } }

    var body: some View {
        if !choices.isEmpty || workflow.servingProfile != nil {
            VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
                Picker("Serving profile", selection: Binding<UUID?>(
                    get: { workflow.servingProfile?.id },
                    set: { id in workflow.selectServingProfile(id.flatMap { id in choices.first { $0.id == id } }) })) {
                    Text("Runtime defaults").tag(Optional<UUID>.none)
                    ForEach(choices) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }.disabled(workflow.isServeSubmissionInFlight || profiles.activeID != nil)
                if let profile = selected {
                    Text("Draft-and-verify \(profile.options.speculation ? "on" : "off") · expert memory \(profile.options.expertMemoryGB.map { "\($0.formatted()) GB" } ?? "automatic") · \(profile.options.contextTokens) context tokens")
                        .font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                    Text(profile.hasPassedVerification ? "Canaries passed. Settings and fingerprints are checked again before serving." : "Profile verification is required before serving.")
                        .font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
                    HStack {
                        Button(profiles.activeID == profile.id ? "Verifying…" : "Verify profile") {
                            Task {
                                await profiles.verify(id: profile.id)
                                if workflow.servingProfile?.id == profile.id {
                                    workflow.selectServingProfile(profiles.profiles.first { $0.id == profile.id })
                                }
                            }
                        }
                        Menu("Manage profile") {
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
                ErrorBanner(text: profiles.lastError)
                ErrorBanner(text: endpoint.lastError)
            }.padding(.vertical, WorkbenchSpacing.sm)
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
