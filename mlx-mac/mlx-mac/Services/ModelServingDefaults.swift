import Foundation

// MARK: - Per-model serving defaults
//
// `model-defaults.json` holds one record per model. An endpoint slot with
// `overrides != nil` follows these values for every field outside its override
// set; a slot with `overrides == nil` keeps its own stored values.

/// One serving setting a slot can override. Inference cases mirror `LocalInferenceOptions`.
enum ServingSettingKey: String, Codable, CaseIterable, Hashable, Sendable {
    case loadOnRequest, memoryPolicy, splashPreset, servingProfile
    case m5Prefill, promptLookup, visionCache, thinkingOff, maximumTokens, systemPrompt, temperature, topP, sharedPrefixCacheMiB
}

struct ModelServingDefaults: Codable, Equatable, Sendable {
    var inference = LocalInferenceOptions()
    var memoryPolicy: EndpointMemoryPolicy? = nil
    var loadOnRequest: Bool? = nil
    var splashPresetName: String? = nil
    var servingProfileID: UUID? = nil
}

/// A named settings set for one model.
struct ServingSettingsProfile: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var settings: ModelServingDefaults
}

/// One model's saved defaults and named profiles. Files written before profiles existed decode with none.
struct ModelDefaultsRecord: Codable, Equatable, Sendable {
    var modelPath: String
    var defaults: ModelServingDefaults?
    var profiles: [ServingSettingsProfile] = []

    init(modelPath: String, defaults: ModelServingDefaults?, profiles: [ServingSettingsProfile] = []) {
        self.modelPath = modelPath
        self.defaults = defaults
        self.profiles = profiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelPath = try container.decode(String.self, forKey: .modelPath)
        defaults = try container.decodeIfPresent(ModelServingDefaults.self, forKey: .defaults)
        profiles = try container.decodeIfPresent([ServingSettingsProfile].self, forKey: .profiles) ?? []
    }
}

/// Durable `model-defaults.json`; records match models by `HFRepoID.Identity`. Reads and writes run on one serial queue.
final class ModelDefaultsStore: @unchecked Sendable {
    private let store: JSONStore<ModelDefaultsRecord>
    private let queue = DispatchQueue(label: "mlx-workbench.model-defaults")

    init(store: JSONStore<ModelDefaultsRecord> = JSONStore(fileURL: WorkbenchStatePaths.modelDefaults())) {
        self.store = store
    }

    func defaults(for modelPath: String) -> ModelServingDefaults? {
        queue.sync {
            let identity = HFRepoID.Identity(modelPath)
            return ((try? store.load()) ?? []).first { HFRepoID.Identity($0.modelPath).matches(identity) }?.defaults
        }
    }

    func profiles(for modelPath: String) -> [ServingSettingsProfile] {
        queue.sync {
            let identity = HFRepoID.Identity(modelPath)
            return ((try? store.load()) ?? []).first { HFRepoID.Identity($0.modelPath).matches(identity) }?.profiles ?? []
        }
    }

    /// Saves the model's defaults; nil removes them. The model's profiles are kept.
    func save(_ defaults: ModelServingDefaults?, for modelPath: String) throws {
        try update(modelPath) { $0.defaults = defaults }
    }

    /// Adds or replaces a profile by id. Names are non-empty and unique per model.
    func saveProfile(_ profile: ServingSettingsProfile, for modelPath: String) throws {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { throw WorkflowEvidenceError.invalid("Profile name must be 1 to 60 characters.") }
        try update(modelPath) { record in
            guard !record.profiles.contains(where: { $0.id != profile.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw WorkflowEvidenceError.invalid("A profile named \(name) already exists for this model.")
            }
            var stored = profile
            stored.name = name
            if let index = record.profiles.firstIndex(where: { $0.id == profile.id }) { record.profiles[index] = stored }
            else { record.profiles.append(stored) }
        }
    }

    func removeProfile(id: UUID, for modelPath: String) throws {
        try update(modelPath) { $0.profiles.removeAll { $0.id == id } }
    }

    private func update(_ modelPath: String, _ change: (inout ModelDefaultsRecord) throws -> Void) throws {
        try queue.sync {
            let identity = HFRepoID.Identity(modelPath)
            try store.mutate { records in
                var record = records.first { HFRepoID.Identity($0.modelPath).matches(identity) }
                    ?? ModelDefaultsRecord(modelPath: modelPath, defaults: nil)
                try change(&record)
                records.removeAll { HFRepoID.Identity($0.modelPath).matches(identity) }
                if record.defaults != nil || !record.profiles.isEmpty { records.append(record) }
            }
        }
    }
}

enum ServingSettings {
    enum Source: Equatable { case modelDefault, endpoint }

    /// Which side supplies a field: the endpoint when it overrides it or has no override set (legacy), else the model default.
    static func source(of key: ServingSettingKey, slot: EndpointSlot) -> Source {
        guard let overrides = slot.overrides else { return .endpoint }
        return overrides.contains(key) ? .endpoint : .modelDefault
    }

    /// Keys whose values differ between two option sets.
    static func changedKeys(from old: LocalInferenceOptions, to new: LocalInferenceOptions) -> Set<ServingSettingKey> {
        var keys = Set<ServingSettingKey>()
        if old.m5Prefill != new.m5Prefill { keys.insert(.m5Prefill) }
        if old.promptLookup != new.promptLookup { keys.insert(.promptLookup) }
        if old.visionCache != new.visionCache { keys.insert(.visionCache) }
        if old.thinkingOff != new.thinkingOff { keys.insert(.thinkingOff) }
        if old.maximumTokens != new.maximumTokens { keys.insert(.maximumTokens) }
        if old.systemPrompt != new.systemPrompt { keys.insert(.systemPrompt) }
        if old.temperature != new.temperature { keys.insert(.temperature) }
        if old.topP != new.topP { keys.insert(.topP) }
        if old.sharedPrefixCacheMiB != new.sharedPrefixCacheMiB { keys.insert(.sharedPrefixCacheMiB) }
        return keys
    }

    /// The settings a slot serves with. `overrides == nil` returns the slot unchanged; otherwise fields outside the
    /// override set take the model default, and the slot's own value stays where no default exists.
    static func effective(slot: EndpointSlot, defaults: ModelServingDefaults?, profile: ServingProfile? = nil) -> EndpointSlot {
        guard let overrides = slot.overrides, let defaults, !slot.isTrainedAdapter else { return slot }
        var result = slot
        var options = slot.inferenceOptions
        let base = defaults.inference
        func follows(_ key: ServingSettingKey) -> Bool { !overrides.contains(key) }
        if follows(.m5Prefill) { options.m5Prefill = base.m5Prefill }
        if follows(.promptLookup) { options.promptLookup = base.promptLookup }
        if follows(.visionCache) { options.visionCache = base.visionCache }
        if follows(.thinkingOff) { options.thinkingOff = base.thinkingOff }
        if follows(.maximumTokens) { options.maximumTokens = base.maximumTokens }
        if follows(.systemPrompt) { options.systemPrompt = base.systemPrompt }
        if follows(.temperature) { options.temperature = base.temperature }
        if follows(.topP) { options.topP = base.topP }
        if follows(.sharedPrefixCacheMiB) { options.sharedPrefixCacheMiB = base.sharedPrefixCacheMiB }
        result.acceleration = options.requested ? options : nil
        if follows(.loadOnRequest), let mode = defaults.loadOnRequest { result.loadOnRequest = mode }
        if follows(.memoryPolicy), let policy = defaults.memoryPolicy { result.memoryPolicy = policy }
        if follows(.splashPreset), let name = defaults.splashPresetName { result.splashPresetName = name }
        if follows(.servingProfile), let id = defaults.servingProfileID {
            let usable = profile.flatMap { $0.id == id && $0.hasPassedVerification && $0.modelPath == slot.modelPath ? $0 : nil }
            result.servingProfile = usable
        }
        return result
    }

    /// The slot carrying a profile's values. Fields that match what the model default would supply keep following it;
    /// a legacy slot (`overrides == nil`) keeps owning every field.
    /// `defaultsServingProfile` is what the model default's serving profile id resolves to.
    static func applying(_ settings: ModelServingDefaults, to slot: EndpointSlot, servingProfile: ServingProfile?,
                         modelDefaults: ModelServingDefaults?, defaultsServingProfile: ServingProfile?) -> EndpointSlot {
        var candidate = slot
        candidate.acceleration = settings.inference.requested ? settings.inference : nil
        if let mode = settings.loadOnRequest { candidate.loadOnRequest = mode }
        candidate.memoryPolicy = settings.memoryPolicy
        candidate.splashPresetName = settings.splashPresetName
        candidate.servingProfile = servingProfile
        guard slot.overrides != nil else { return candidate }
        var followed = candidate
        followed.overrides = []
        let base = effective(slot: followed, defaults: modelDefaults, profile: defaultsServingProfile)
        var keys = changedKeys(from: base.inferenceOptions, to: candidate.inferenceOptions)
        if base.loadOnRequest != candidate.loadOnRequest { keys.insert(.loadOnRequest) }
        if base.memoryPolicy != candidate.memoryPolicy { keys.insert(.memoryPolicy) }
        if base.splashPresetName != candidate.splashPresetName { keys.insert(.splashPreset) }
        if base.servingProfile?.id != candidate.servingProfile?.id { keys.insert(.servingProfile) }
        candidate.overrides = keys
        return candidate
    }

    /// The values "Save as model default" writes: the slot's effective settings.
    static func defaults(from slot: EndpointSlot) -> ModelServingDefaults {
        ModelServingDefaults(inference: slot.inferenceOptions, memoryPolicy: slot.memoryPolicy, loadOnRequest: slot.loadOnRequest,
                             splashPresetName: slot.splashPresetName, servingProfileID: slot.servingProfile?.id)
    }
}

/// Slots affected by changing a model's defaults; `restarting` are enabled and change their launch settings.
struct ModelDefaultsChangePreview: Equatable {
    let modelPath: String
    let defaults: ModelServingDefaults?
    let following: [EndpointSlot]
    let restarting: [EndpointSlot]
    /// Post-change launch plan hash per restarting slot.
    var plans: [UUID: String] = [:]
    /// Set when the change rewrites one endpoint from a profile instead of the model defaults.
    var appliedSlot: EndpointSlot? = nil
    var appliedProfile: ServingSettingsProfile? = nil
}
