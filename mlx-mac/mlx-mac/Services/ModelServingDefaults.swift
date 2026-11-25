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

struct ModelDefaultsRecord: Codable, Equatable, Sendable {
    var modelPath: String
    var defaults: ModelServingDefaults
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

    /// Saves the model's defaults; nil removes them.
    func save(_ defaults: ModelServingDefaults?, for modelPath: String) throws {
        try queue.sync {
            let identity = HFRepoID.Identity(modelPath)
            try store.mutate { records in
                records.removeAll { HFRepoID.Identity($0.modelPath).matches(identity) }
                if let defaults { records.append(ModelDefaultsRecord(modelPath: modelPath, defaults: defaults)) }
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
}
