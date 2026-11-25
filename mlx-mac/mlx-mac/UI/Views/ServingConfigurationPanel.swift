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
}

/// The chosen preset's settings that differ from the model default, with their source; JSON opens on request.
/// Also manages the model's settings profiles.
struct ServingConfigurationPanel: View {
    @ObservedObject var endpoint: EndpointSupervisor
    let slot: EndpointSlot

    private enum Choice: Hashable { case endpoint, modelDefault, profile(UUID) }
    private enum NameEdit { case save, rename }
    private struct Row: Identifiable {
        let key: ServingSettingKey
        let value: String
        let source: String
        var id: ServingSettingKey { key }
    }

    @State private var choice = Choice.endpoint
    @State private var profiles: [ServingSettingsProfile] = []
    @State private var nameEdit: NameEdit?
    @State private var nameDraft = ""
    @State private var removing: ServingSettingsProfile?
    @State private var preview: ModelDefaultsChangePreview?
    @State private var showsJSON = false
    @State private var busy = false
    @State private var error: String?

    private var selectedProfile: ServingSettingsProfile? {
        if case .profile(let id) = choice { return profiles.first { $0.id == id } }
        return nil
    }

    private var savedDefaults: ModelServingDefaults? { endpoint.modelDefaults(for: slot.modelPath) }

    private var text: String {
        let effective = endpoint.effectiveSlot(slot)
        do {
            switch choice {
            case .endpoint: return try ServingConfiguration.json(effective: effective)
            case .modelDefault:
                guard let defaults = savedDefaults else { return "No model default is saved." }
                return try ServingConfiguration.json(profile: ServingSettingsProfile(name: "", settings: defaults), modelPath: slot.modelPath)
            case .profile:
                guard let profile = selectedProfile else { return "" }
                return try ServingConfiguration.json(profile: profile, modelPath: slot.modelPath)
            }
        } catch { return AppHost.render(error) }
    }

    /// Engine defaults: no inference values, memory policy, Splash preset or serving profile.
    private var engineDefault: EndpointSlot {
        var result = endpoint.effectiveSlot(slot)
        result.acceleration = nil; result.memoryPolicy = nil; result.splashPresetName = nil; result.servingProfile = nil
        return result
    }

    /// The endpoint following the model default for every setting; engine defaults when none is saved.
    private var modelDefault: EndpointSlot {
        guard savedDefaults != nil else { return engineDefault }
        var followed = slot
        followed.overrides = []
        return endpoint.effectiveSlot(followed)
    }

    /// The endpoint carrying a profile's values, as Apply would write them.
    private func carrying(_ settings: ModelServingDefaults) -> EndpointSlot {
        var result = endpoint.effectiveSlot(slot)
        result.acceleration = settings.inference.requested ? settings.inference : nil
        if let mode = settings.loadOnRequest { result.loadOnRequest = mode }
        result.memoryPolicy = settings.memoryPolicy
        result.splashPresetName = settings.splashPresetName
        if result.servingProfile?.id != settings.servingProfileID { result.servingProfile = nil }
        return result
    }

    /// Nil when the model default is chosen and none is saved.
    private var rows: [Row]? {
        func rows(_ candidate: EndpointSlot, base: EndpointSlot, source: (ServingSettingKey) -> String) -> [Row] {
            ServingInspectorPresentation.differences(candidate, from: base).map {
                Row(key: $0, value: ServingInspectorPresentation.value($0, slot: candidate), source: source($0))
            }
        }
        switch choice {
        case .endpoint:
            return rows(endpoint.effectiveSlot(slot), base: modelDefault) { ServingInspectorPresentation.sourceLabel($0, slot: slot) }
        case .modelDefault:
            guard savedDefaults != nil else { return nil }
            return rows(modelDefault, base: engineDefault) { _ in "Model default" }
        case .profile:
            guard let profile = selectedProfile else { return [] }
            return rows(carrying(profile.settings), base: modelDefault) { _ in "Profile" }
        }
    }

    private var emptyText: String {
        switch choice {
        case .endpoint: return savedDefaults == nil ? "Every setting uses the engine default." : "Every setting matches the model default."
        case .modelDefault: return "The model default sets no values."
        case .profile: return "This profile matches the model default."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.sm) {
            Text("Presets").font(WorkbenchTypography.cardTitle)
            VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
                HStack {
                    Picker("Preset", selection: $choice) {
                        Text("This endpoint").tag(Choice.endpoint)
                        Text("Model default").tag(Choice.modelDefault)
                        ForEach(profiles) { Text($0.name).tag(Choice.profile($0.id)) }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("serving-configuration-picker")
                    Spacer(minLength: WorkbenchSpacing.sm)
                    Button("Show JSON…") { showsJSON = true }
                        .buttonStyle(.borderless).controlSize(.small)
                        .help("Show the chosen preset as sorted-key JSON. It never contains an API key.")
                        .accessibilityIdentifier("serving-configuration-show-json")
                }
                settingRows
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
        .sheet(isPresented: $showsJSON) { jsonSheet }
        .onAppear(perform: reload)
        .onChange(of: slot.id) { _, _ in choice = .endpoint; preview = nil; nameEdit = nil; error = nil; reload() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("serving-configuration")
    }

    @ViewBuilder
    private var settingRows: some View {
        if let rows {
            if rows.isEmpty {
                Text(emptyText).font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: WorkbenchSpacing.md, verticalSpacing: WorkbenchSpacing.xs) {
                    ForEach(rows) { row in
                        GridRow {
                            Text(ServingInspectorPresentation.label(row.key)).font(WorkbenchTypography.label).lineLimit(1)
                            Text(row.value).font(WorkbenchTypography.secondary).lineLimit(1).truncationMode(.tail)
                                .textSelection(.enabled).help(row.value)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.source).font(WorkbenchTypography.metadata).foregroundStyle(WorkbenchColor.muted).lineLimit(1)
                                .padding(.horizontal, WorkbenchSpacing.xs).padding(.vertical, WorkbenchSpacing.xxxs)
                                .background(WorkbenchColor.surface, in: Capsule())
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("serving-configuration-settings")
            }
        } else {
            Text("No model default is saved.").font(WorkbenchTypography.secondary).foregroundStyle(WorkbenchColor.muted)
        }
    }

    private var jsonSheet: some View {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            Text("Settings JSON").font(WorkbenchTypography.cardTitle)
            ScrollView {
                Text(text).font(WorkbenchTypography.compactValue).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(WorkbenchSpacing.sm)
            }
            .frame(minHeight: 240, maxHeight: 480)
            .background(WorkbenchColor.canvas, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))
            .accessibilityIdentifier("serving-configuration-json")
            HStack {
                Button("Copy JSON") { ServedModelsSelection.copy(text) }
                    .accessibilityIdentifier("serving-configuration-copy-json")
                Spacer()
                Button("Done") { showsJSON = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(WorkbenchSpacing.lg)
        .frame(width: 520)
    }

    private var actions: some View {
        let isProfile = selectedProfile != nil
        return HStack(spacing: WorkbenchSpacing.sm) {
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
