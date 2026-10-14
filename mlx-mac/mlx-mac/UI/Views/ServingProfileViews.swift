import SwiftUI

struct ServingProfileSaveRequest: Identifiable {
    let id = UUID()
    let run: ComparisonRun
    let laneID: String
    let letter: String
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
                    Button(profiles.activeID == profile.id ? "Verifying…" : "Verify profile") {
                        Task {
                            await profiles.verify(id: profile.id)
                            if workflow.servingProfile?.id == profile.id {
                                workflow.selectServingProfile(profiles.profiles.first { $0.id == profile.id })
                            }
                        }
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
        }
    }
}
