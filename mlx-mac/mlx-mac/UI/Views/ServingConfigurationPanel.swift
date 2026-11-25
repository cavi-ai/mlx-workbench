import SwiftUI

/// The effective serving configuration as sorted-key JSON. Never contains an API key or digest; protection is a boolean.
enum ServingConfiguration {
    struct Document: Codable, Equatable {
        var modelPath: String
        var port: Int?
        var role: String?
        var protected: Bool?
        var settings: ModelServingDefaults
    }

    private static func encode(_ document: Document) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(document), as: UTF8.self)
    }

    /// `effective` is a slot already resolved against its model defaults.
    static func json(effective slot: EndpointSlot) throws -> String {
        try encode(Document(modelPath: slot.modelPath, port: slot.port, role: slot.role?.rawValue,
                            protected: slot.apiKeySHA256 != nil, settings: ServingSettings.defaults(from: slot)))
    }

    static func json(profile: ServingSettingsProfile, modelPath: String) throws -> String {
        try encode(Document(modelPath: modelPath, port: nil, role: nil, protected: nil, settings: profile.settings))
    }

    /// Settings with where each value comes from on this endpoint.
    static func sources(of slot: EndpointSlot) -> [(setting: String, source: String)] {
        ServingSettingKey.allCases.map { (ServingInspectorPresentation.label($0), ServingInspectorPresentation.sourceLabel($0, slot: slot)) }
    }
}

/// Shows the selected endpoint's configuration (or one saved profile) and manages the model's settings profiles.
struct ServingConfigurationPanel: View {
    @ObservedObject var endpoint: EndpointSupervisor
    let slot: EndpointSlot

    private enum Choice: Hashable { case endpoint, modelDefault, profile(UUID) }
    private enum NameEdit { case save, rename }

    @State private var choice = Choice.endpoint
    @State private var profiles: [ServingSettingsProfile] = []
    @State private var nameEdit: NameEdit?
    @State private var nameDraft = ""
    @State private var removing: ServingSettingsProfile?
    @State private var preview: ModelDefaultsChangePreview?
    @State private var busy = false
    @State private var error: String?

    private var selectedProfile: ServingSettingsProfile? {
        if case .profile(let id) = choice { return profiles.first { $0.id == id } }
        return nil
    }

    private var text: String {
        let effective = endpoint.effectiveSlot(slot)
        do {
            switch choice {
            case .endpoint: return try ServingConfiguration.json(effective: effective)
            case .modelDefault:
                guard let defaults = endpoint.modelDefaults(for: slot.modelPath) else { return "No model default is saved." }
                return try ServingConfiguration.json(profile: ServingSettingsProfile(name: "", settings: defaults), modelPath: slot.modelPath)
            case .profile:
                guard let profile = selectedProfile else { return "" }
                return try ServingConfiguration.json(profile: profile, modelPath: slot.modelPath)
            }
        } catch { return AppHost.render(error) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Configuration").font(WorkbenchTypography.cardTitle)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                Picker("Show", selection: $choice) {
                    Text("This endpoint").tag(Choice.endpoint)
                    Text("Model default").tag(Choice.modelDefault)
                    ForEach(profiles) { Text($0.name).tag(Choice.profile($0.id)) }
                }
                .fixedSize()
                .accessibilityIdentifier("serving-configuration-picker")
                ScrollView {
                    Text(text).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(WorkbenchSpacing.sm)
                }
                .frame(minHeight: 160, maxHeight: 360)
                .background(WorkbenchColor.canvas, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
                .accessibilityIdentifier("serving-configuration-json")
                sourceGrid
                actions
                if let nameEdit { nameEditor(nameEdit) }
                if let preview {
                    ModelDefaultsConfirmation(endpoint: endpoint, preview: preview,
                                              confirmTitle: preview.appliedSlot == nil ? "Confirm model default" : "Confirm apply") { failure in
                        error = failure
                        self.preview = nil
                        reload()
                    }
                }
                if let error { InlineMessage(kind: .error, text: error) }
            }
            .padding(WorkbenchSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkbenchColor.well, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
        }
        .onAppear(perform: reload)
        .onChange(of: slot.id) { _, _ in choice = .endpoint; preview = nil; nameEdit = nil; error = nil; reload() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serving-configuration")
    }

    private var sourceGrid: some View {
        let rows: [(setting: String, source: String)] = choice == .endpoint
            ? ServingConfiguration.sources(of: slot) : []
        return Grid(alignment: .leading, horizontalSpacing: WorkbenchSpacing.md, verticalSpacing: WorkbenchSpacing.xxs) {
            ForEach(rows, id: \.setting) { row in
                GridRow {
                    Text(row.setting).font(WorkbenchTypography.metadata)
                    Text(row.source).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
            }
            if choice != .endpoint {
                GridRow {
                    Text("Source").font(WorkbenchTypography.metadata)
                    Text(choice == .modelDefault ? "Model default" : "Profile").font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted)
                }
            }
        }
    }

    private var actions: some View {
        let isProfile = selectedProfile != nil
        return HStack(spacing: WorkbenchSpacing.sm) {
            Button("Copy JSON") { ServedModelsSelection.copy(text) }
            Button("Save as profile…") { nameDraft = ""; nameEdit = .save }
            Button("Apply…") { review { try await endpoint.previewApplyingProfile(slotID: slot.id, profile: $0) } }
                .disabled(!isProfile)
            if let profile = selectedProfile {
                Button("Make model default…") {
                    review { _ in try await endpoint.previewModelDefaultsChange(modelPath: slot.modelPath, to: profile.settings) }
                }
            }
            Button("Rename…") { nameDraft = selectedProfile?.name ?? ""; nameEdit = .rename }.disabled(!isProfile)
            Button("Remove…") { removing = selectedProfile }.disabled(!isProfile)
        }
        .buttonStyle(.borderless).controlSize(.small).disabled(busy)
        .confirmationDialog("Remove profile \"\(removing?.name ?? "")\"?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { profile in
            Button("Remove profile", role: .destructive) {
                perform { try endpoint.removeSettingsProfile(id: profile.id, modelPath: slot.modelPath); choice = .endpoint }
            }
        } message: { _ in Text("The saved profile is deleted. Endpoints keep their current settings.") }
    }

    private func nameEditor(_ edit: NameEdit) -> some View {
        HStack {
            TextField("Profile name", text: $nameDraft).frame(maxWidth: 220).onSubmit { commitName(edit) }
            Button(edit == .save ? "Save" : "Rename") { commitName(edit) }
                .buttonStyle(.workbenchPrimary).disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { nameEdit = nil }
        }
    }

    private func commitName(_ edit: NameEdit) {
        perform {
            switch edit {
            case .save: choice = .profile(try endpoint.saveSettingsProfile(name: nameDraft, fromSlot: slot.id).id)
            case .rename:
                if let profile = selectedProfile { try endpoint.renameSettingsProfile(profile, to: nameDraft, modelPath: slot.modelPath) }
            }
            nameEdit = nil
        }
    }

    private func perform(_ work: () throws -> Void) {
        error = nil
        do { try work() } catch { self.error = AppHost.render(error) }
        reload()
    }

    /// Previews against the selected profile (a placeholder when none is selected).
    private func review(_ make: @escaping (ServingSettingsProfile) async throws -> ModelDefaultsChangePreview) {
        busy = true; error = nil
        let profile = selectedProfile ?? ServingSettingsProfile(name: "", settings: ModelServingDefaults())
        Task {
            do { preview = try await make(profile) } catch { self.error = AppHost.render(error) }
            busy = false
        }
    }

    private func reload() { profiles = endpoint.settingsProfiles(for: slot.modelPath) }
}
