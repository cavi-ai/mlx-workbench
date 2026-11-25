import Foundation

struct LocalInferenceOptions: Codable, Equatable, Sendable {
    var m5Prefill = false
    var promptLookup = false
    var visionCache = false
    var thinkingOff = false
    var maximumTokens: Int? = nil
    var systemPrompt = ""
    var temperature: Double? = nil
    var topP: Double? = nil
    var sharedPrefixCacheMiB: Int? = nil
    var hasRequestDefaults: Bool { !systemPrompt.isEmpty || temperature != nil || topP != nil }
    var textRequested: Bool { m5Prefill || promptLookup || thinkingOff }
    var accelerationRequested: Bool { m5Prefill || promptLookup || visionCache }
    var sharedPrefixCacheRequested: Bool { sharedPrefixCacheMiB != nil }
    var requested: Bool { textRequested || visionCache || maximumTokens != nil || hasRequestDefaults || sharedPrefixCacheRequested }
    var validationError: String? {
        if systemPrompt.utf8.count > 8192 || systemPrompt.contains("\0") { return "System prompt must fit in 8,192 UTF-8 bytes without null characters." }
        if let temperature, !temperature.isFinite || !(0...2).contains(temperature) { return "Temperature must be from 0 to 2." }
        if let topP, !topP.isFinite || !(0...1).contains(topP) { return "Top-p must be from 0 to 1." }
        if let maximumTokens, !(256...65536).contains(maximumTokens) { return "Default output length must be from 256 to 65536 tokens." }
        if visionCache && (textRequested || maximumTokens != nil) { return "Choose vision feature reuse separately from text-server settings." }
        if let mib = sharedPrefixCacheMiB {
            if !(16...2048).contains(mib) { return "Shared prefix cache must be from 16 to 2048 MiB." }
            if accelerationRequested { return "Shared prefix cache cannot be combined with M5 prefill, prompt lookup, or vision cache." }
            if !systemPrompt.isEmpty { return "Shared prefix cache cannot be combined with a default system prompt." }
        }
        return nil
    }

    init(m5Prefill: Bool = false, promptLookup: Bool = false, visionCache: Bool = false, thinkingOff: Bool = false, maximumTokens: Int? = nil, systemPrompt: String = "", temperature: Double? = nil, topP: Double? = nil, sharedPrefixCacheMiB: Int? = nil) {
        self.m5Prefill = m5Prefill; self.promptLookup = promptLookup; self.visionCache = visionCache
        self.thinkingOff = thinkingOff; self.maximumTokens = maximumTokens
        self.systemPrompt = systemPrompt; self.temperature = temperature; self.topP = topP
        self.sharedPrefixCacheMiB = sharedPrefixCacheMiB
    }

    enum CodingKeys: String, CodingKey { case m5Prefill, promptLookup, visionCache, thinkingOff, maximumTokens, systemPrompt, temperature, topP, sharedPrefixCacheMiB }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        m5Prefill = try values.decodeIfPresent(Bool.self, forKey: .m5Prefill) ?? false
        promptLookup = try values.decodeIfPresent(Bool.self, forKey: .promptLookup) ?? false
        visionCache = try values.decodeIfPresent(Bool.self, forKey: .visionCache) ?? false
        thinkingOff = try values.decodeIfPresent(Bool.self, forKey: .thinkingOff) ?? false
        maximumTokens = try values.decodeIfPresent(Int.self, forKey: .maximumTokens)
        systemPrompt = try values.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        temperature = try values.decodeIfPresent(Double.self, forKey: .temperature)
        topP = try values.decodeIfPresent(Double.self, forKey: .topP)
        sharedPrefixCacheMiB = try values.decodeIfPresent(Int.self, forKey: .sharedPrefixCacheMiB)
    }
}

struct EndpointInferencePreview {
    let slot: EndpointSlot
    let options: LocalInferenceOptions
    let hash: String
}

struct EndpointAuthenticationReview: Identifiable {
    let id = UUID()
    let slot: EndpointSlot
    let keySHA256: String?
    let token: String?
    let previewHash: String
}

// MARK: - Endpoint models
//
// Always-on Endpoint (premium spec 06): a stable loopback port that always
// serves the chosen model, so clients wired via Cross-client Wiring never
// hit a dead port. The supervisor reconciles desired state against
// authoritative serve status; receipts remain the authority.

struct EndpointConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var port: Int
    var modelPath: String
    /// Whether the login LaunchAgent (boot persistence) is installed.
    var installedAtLogin: Bool

    static let defaultPort = 8766

    static var disabled: EndpointConfig {
        EndpointConfig(enabled: false, port: defaultPort, modelPath: "", installedAtLogin: false)
    }
}

// MARK: - Fleet models (spec 09)

struct EndpointMemoryPolicy: Codable, Equatable, Sendable {
    var idleTimeoutSeconds: Int
    var keepLoaded: Bool
    var minimumHeadroomGB: Double?
    var modelMemoryBudgetGB: Double? = nil
    var unloadUnderPressure: Bool? = nil
    var contextTokens: Int? = nil
    var releaseAfterRequest: Bool? = nil
    var executionWaitSeconds: Int? = nil

    static let automatic = EndpointMemoryPolicy(idleTimeoutSeconds: 600, keepLoaded: false, minimumHeadroomGB: 2)
    static let legacy = EndpointMemoryPolicy(idleTimeoutSeconds: 0, keepLoaded: false, minimumHeadroomGB: nil)

    enum CodingKeys: String, CodingKey {
        case idleTimeoutSeconds = "idle_timeout_seconds"
        case keepLoaded = "keep_loaded"
        case minimumHeadroomGB = "minimum_headroom_gb"
        case modelMemoryBudgetGB = "model_memory_budget_gb"
        case unloadUnderPressure = "unload_under_pressure"
        case contextTokens = "context_tokens"
        case releaseAfterRequest = "release_after_request"
        case executionWaitSeconds = "execution_wait_seconds"
    }

    var isValid: Bool {
        !(keepLoaded && releaseAfterRequest == true) &&
        (0...86400).contains(idleTimeoutSeconds) &&
        (minimumHeadroomGB.map { $0.isFinite && (0...1024).contains($0) } ?? true) &&
        (modelMemoryBudgetGB.map { $0.isFinite && (1...1024).contains($0) } ?? true) &&
        (unloadUnderPressure != true || (minimumHeadroomGB != nil && !keepLoaded)) &&
        (contextTokens.map { (1024...1_048_576).contains($0) && minimumHeadroomGB != nil } ?? true) &&
        (executionWaitSeconds.map { (0...3600).contains($0) } ?? true)
    }

    var arguments: [String] {
        var result = ["--idle-timeout", String(idleTimeoutSeconds)]
        if keepLoaded { result.append("--keep-loaded") }
        if let releaseAfterRequest { result.append(releaseAfterRequest ? "--release-after-request" : "--no-release-after-request") }
        if let minimumHeadroomGB { result += ["--min-headroom-gb", String(minimumHeadroomGB)] }
        if let modelMemoryBudgetGB { result += ["--memory-budget-gb", String(modelMemoryBudgetGB)] }
        if unloadUnderPressure == true { result.append("--unload-under-pressure") }
        if let contextTokens { result += ["--context-tokens", String(contextTokens)] }
        if let executionWaitSeconds { result += ["--execution-wait", String(executionWaitSeconds)] }
        return result
    }
}

/// A saved engine profile, scoped to the active receipt directory.
/// Splash tuning a saved preset carries; nil leaves Splash's own default.
struct SplashTuning: Equatable {
    var verifyRows: String?
    var cachedStates: String?
    var kvFormat: String?
    var reasoningEffort: String?
    var thinkingBudget: Int?
    var persistentCache: Bool?
    var maxCacheDiskGB: Double?

    static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    init(verifyRows: String? = nil, cachedStates: String? = nil, kvFormat: String? = nil, reasoningEffort: String? = nil,
         thinkingBudget: Int? = nil, persistentCache: Bool? = nil, maxCacheDiskGB: Double? = nil) {
        self.verifyRows = verifyRows; self.cachedStates = cachedStates; self.kvFormat = kvFormat
        self.reasoningEffort = reasoningEffort; self.thinkingBudget = thinkingBudget
        self.persistentCache = persistentCache; self.maxCacheDiskGB = maxCacheDiskGB
    }

    init(settings: [String: Any]) {
        self.init(verifyRows: settings["splash_verify_rows"] as? String,
                  cachedStates: settings["splash_cached_states"] as? String,
                  kvFormat: settings["splash_kv_format"] as? String,
                  reasoningEffort: settings["splash_reasoning_effort"] as? String,
                  thinkingBudget: settings["splash_thinking_token_budget"] as? Int,
                  persistentCache: settings["splash_persistent_cache"] as? Bool,
                  maxCacheDiskGB: (settings["splash_max_cache_disk_gb"] as? NSNumber)?.doubleValue)
    }

    /// Engine profile settings for the values set.
    var settings: [String: Any] {
        let values: [String: Any?] = [
            "splash_verify_rows": verifyRows, "splash_cached_states": cachedStates, "splash_kv_format": kvFormat,
            "splash_reasoning_effort": reasoningEffort, "splash_thinking_token_budget": thinkingBudget,
            "splash_persistent_cache": persistentCache, "splash_max_cache_disk_gb": maxCacheDiskGB,
        ]
        return values.compactMapValues { $0 }
    }

    /// `serve profile save` options for the values set.
    var arguments: [String] {
        var argv: [String] = []
        if let verifyRows { argv += ["--splash-verify-rows", verifyRows] }
        if let cachedStates { argv += ["--splash-cached-states", cachedStates] }
        if let kvFormat { argv += ["--splash-kv-format", kvFormat] }
        if let reasoningEffort { argv += ["--splash-reasoning-effort", reasoningEffort] }
        if let thinkingBudget { argv += ["--splash-thinking-budget", String(thinkingBudget)] }
        if let persistentCache { argv.append(persistentCache ? "--splash-persistent-cache" : "--no-splash-persistent-cache") }
        if let maxCacheDiskGB { argv += ["--splash-max-cache-disk-gb", String(maxCacheDiskGB)] }
        return argv
    }

    /// A value Splash or the engine would refuse, named before saving.
    var problem: String? {
        if let thinkingBudget, !(0...1_010_000).contains(thinkingBudget) { return "The thinking budget is 0 to 1,010,000 tokens." }
        if let maxCacheDiskGB, !(0...4096).contains(maxCacheDiskGB) { return "The SSD cache quota is 0 to 4,096 GB." }
        if persistentCache == true && maxCacheDiskGB == 0 { return "The persistent cache needs an SSD cache quota above 0." }
        return nil
    }

    var summaryParts: [String] {
        var parts: [String] = []
        if let verifyRows { parts.append(verifyRows == "all" ? "Every draft row verified" : "Adaptive verification") }
        if let reasoningEffort { parts.append(reasoningEffort == "none" ? "Thinking off" : "Effort \(reasoningEffort)") }
        if let thinkingBudget { parts.append("Thinking ≤ \(thinkingBudget.formatted()) tokens") }
        if let kvFormat { parts.append("KV \(kvFormat)") }
        if let cachedStates { parts.append("States \(cachedStates)") }
        if persistentCache == true { parts.append("Persistent SSD cache") }
        if let maxCacheDiskGB { parts.append(maxCacheDiskGB == 0 ? "SSD cache off" : "SSD cache \(maxCacheDiskGB.formatted()) GB") }
        return parts
    }

    /// Starting points the preset editor offers; each fills the tuning, which stays editable.
    enum StartingPoint: String, CaseIterable, Identifiable {
        case balanced = "Balanced"
        case agentSessions = "Agent sessions"
        case repeatable = "Repeatable output"
        case quickAnswers = "Quick answers"

        var id: String { rawValue }

        var tuning: SplashTuning {
            switch self {
            case .balanced: return SplashTuning()
            case .agentSessions: return SplashTuning(reasoningEffort: "none", thinkingBudget: 0, persistentCache: true)
            case .repeatable: return SplashTuning(verifyRows: "all", cachedStates: "exact")
            case .quickAnswers: return SplashTuning(reasoningEffort: "none")
            }
        }

        var detail: String {
            switch self {
            case .balanced: return "Splash defaults: adaptive verification, int8 caches, and each request sets its own effort."
            case .agentSessions: return "Turns thinking off and keeps the SSD prompt cache across restarts."
            case .repeatable: return "Verifies every draft row and keeps cached states exact, so greedy and seeded outputs repeat."
            case .quickAnswers: return "Turns thinking off for every request."
            }
        }
    }
}

struct SplashPreset: Equatable, Identifiable {
    let name: String
    let memoryGB: Double?
    let contextTokens: Int?
    let headroomGB: Double
    let idleSeconds: Int
    let keepLoaded: Bool
    let releaseAfterRequest: Bool?
    let executionWaitSeconds: Int?
    let unloadUnderPressure: Bool
    let tuning: SplashTuning
    /// Complete engine settings bind the selection and review to the same source.
    let sourceSettings: Data
    var id: String { name }

    init?(name: String, settings: [String: Any]) {
        let wait = settings["execution_wait_seconds"] as? Int
        guard settings.keys.contains(where: { $0.hasPrefix("splash_") }),
              let headroom = (settings["min_headroom_gb"] as? NSNumber)?.doubleValue,
              let idle = settings["idle_timeout"] as? Int, let keep = settings["keep_loaded"] as? Bool,
              let pressure = settings["unload_under_pressure"] as? Bool,
              (wait.map { (0...3600).contains($0) } ?? true),
              let canonical = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]) else { return nil }
        self.name = name
        self.memoryGB = (settings["splash_max_memory_gb"] as? NSNumber)?.doubleValue
        self.contextTokens = settings["splash_max_context_tokens"] as? Int
        self.headroomGB = headroom; self.idleSeconds = idle; self.keepLoaded = keep; self.unloadUnderPressure = pressure
        self.releaseAfterRequest = settings["release_after_request"] as? Bool
        self.executionWaitSeconds = wait
        self.tuning = SplashTuning(settings: settings)
        self.sourceSettings = canonical
    }

    var summary: String {
        let memory = memoryGB.map { String(format: "%.1f GB memory", $0) } ?? "Default memory"
        let context = contextTokens.map { "\($0.formatted()) context" } ?? "Default context"
        let idle = keepLoaded ? "Keep loaded" : (releaseAfterRequest == true ? "Release after each request" : (idleSeconds == 0 ? "No idle unload" : "Idle \(idleSeconds) s"))
        let waitParts = executionWaitSeconds.flatMap { $0 > 0 ? ["Wait \($0) s"] : nil } ?? []
        return ([memory, context] + tuning.summaryParts + ["Reserve \(headroomGB.formatted()) GB", idle] + waitParts).joined(separator: " · ")
    }

}

struct SplashPresetReview: Identifiable {
    let id = UUID()
    let slot: EndpointSlot
    let preset: SplashPreset
    let server: ServerInfo
    let previewHash: String
}

/// The one role vocabulary for fleet endpoints. Each role has a canonical
/// loopback port and the model task types that may fill it.
enum ServingRole: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case embedding
    case general
    case vision
    case reasoning
    case coding
    case classification
    case image
    case mesh
    case voice
    case transcription
    case music
    case video

    var id: String { rawValue }

    init(_ useCase: UseCase) {
        switch useCase {
        case .coding: self = .coding
        case .generalChat: self = .general
        case .reasoning: self = .reasoning
        case .vision: self = .vision
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let token = String(raw.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        switch token {
        case "generalchat": self = .general
        case "research", "reasoningresearch": self = .reasoning
        default:
            guard let role = ServingRole(rawValue: token) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown serving role: \(raw)")
            }
            self = role
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var title: String {
        switch self {
        case .embedding: return ModelTaskType.embedding.title
        case .general: return "General"
        case .vision: return "Vision"
        case .reasoning: return "Reasoning"
        case .coding: return "Coding"
        case .classification: return ModelTaskType.classification.title
        case .image: return ModelTaskType.imageGeneration.title
        case .mesh: return "3D"
        case .voice: return ModelTaskType.textToSpeech.title
        case .transcription: return ModelTaskType.speechToText.title
        case .music: return ModelTaskType.musicGeneration.title
        case .video: return ModelTaskType.videoGeneration.title
        }
    }

    var symbolName: String {
        switch self {
        case .embedding: return ModelTaskType.embedding.symbolName
        case .general, .reasoning, .coding: return ModelTaskType.textLLM.symbolName
        case .vision: return ModelTaskType.visionLanguage.symbolName
        case .classification: return ModelTaskType.classification.symbolName
        case .image: return ModelTaskType.imageGeneration.symbolName
        case .mesh: return ModelTaskType.meshGeneration.symbolName
        case .voice: return ModelTaskType.textToSpeech.symbolName
        case .transcription: return ModelTaskType.speechToText.symbolName
        case .music: return ModelTaskType.musicGeneration.symbolName
        case .video: return ModelTaskType.videoGeneration.symbolName
        }
    }

    var defaultPort: Int {
        switch self {
        case .embedding: return 8091
        case .general: return 8092
        case .vision: return 8093
        case .reasoning: return 8094
        case .coding: return 8095
        case .classification: return 8096
        case .image: return 8097
        case .mesh: return 8098
        case .voice: return 8099
        case .transcription: return 8100
        case .music: return 8101
        case .video: return 8102
        }
    }

    var eligibleTaskTypes: [ModelTaskType] {
        switch self {
        case .embedding: return [.embedding]
        case .general, .reasoning, .coding: return [.textLLM, .visionLanguage]
        case .vision: return [.visionLanguage]
        case .classification: return [.classification]
        case .image: return [.imageGeneration]
        case .mesh: return [.meshGeneration]
        case .voice: return [.textToSpeech]
        case .transcription: return [.speechToText]
        case .music: return [.musicGeneration]
        case .video: return [.videoGeneration]
        }
    }

    var isChat: Bool {
        switch self {
        case .general, .vision, .reasoning, .coding: return true
        default: return false
        }
    }
}

/// One supervised endpoint: a model on its own stable loopback port.
/// `role == nil` is first-class — an unassigned stable port, exactly like
/// the original single endpoint.
struct EndpointSlot: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var enabled: Bool
    var port: Int
    var modelPath: String
    var role: ServingRole?
    /// Absent in legacy fleets: preserve their eager-serving behavior.
    var loadOnRequest: Bool?
    var memoryPolicy: EndpointMemoryPolicy?
    var servingProfile: ServingProfile? = nil
    /// Name of a receipt-scoped engine Splash profile.
    var splashPresetName: String? = nil
    var profilePreviewHash: String? = nil
    /// Existing fleet files use this storage key for local inference settings.
    var acceleration: LocalInferenceOptions? = nil
    var accelerationPreviewHash: String? = nil
    var apiKeySHA256: String? = nil
    /// Completed training receipt for an adapter endpoint. Nil for an ordinary model endpoint.
    var trainingReceipt: String? = nil
    var inferenceOptions: LocalInferenceOptions { acceleration ?? .init() }
    var isTrainedAdapter: Bool { trainingReceipt != nil }
    var usesJIT: Bool { loadOnRequest == true }

    init(id: UUID = UUID(), enabled: Bool, port: Int, modelPath: String, role: ServingRole? = nil, loadOnRequest: Bool? = nil, memoryPolicy: EndpointMemoryPolicy? = nil) {
        self.id = id
        self.enabled = enabled
        self.port = port
        self.modelPath = modelPath
        self.role = role
        self.loadOnRequest = loadOnRequest
        self.memoryPolicy = memoryPolicy
    }
}

/// The front door's loopback port and the shared key digest its routes verify.
struct FrontDoorSettings: Codable, Equatable, Sendable {
    var port: Int
    var apiKeySHA256: String
}

/// The two endpoint roles the fleet can designate as defaults. Distinct from
/// the legacy `UseCase` slot role, which is unchanged.
enum EndpointDefaultRole: String, CaseIterable, Identifiable {
    case coding
    case utility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coding: return "Coding"
        case .utility: return "Utility"
        }
    }
}

/// Saved per-role default endpoint choices, by slot UUID. Missing entries stay
/// unresolved; stale UUIDs are never silently substituted.
struct EndpointRoleDefaults: Codable, Equatable, Sendable {
    var coding: UUID? = nil
    var utility: UUID? = nil

    subscript(role: EndpointDefaultRole) -> UUID? {
        get { role == .coding ? coding : utility }
        set {
            switch role {
            case .coding: coding = newValue
            case .utility: utility = newValue
            }
        }
    }
}

struct EndpointFleetConfig: Codable, Equatable, Sendable {
    var slots: [EndpointSlot]
    /// Whether the login LaunchAgent (boot persistence) is installed.
    var installedAtLogin: Bool
    var frontDoor: FrontDoorSettings? = nil
    /// Absent in older fleets; synthesized decoding keeps them readable.
    var roleDefaults: EndpointRoleDefaults? = nil

    static let maxSlots = 16

    static var empty: EndpointFleetConfig {
        EndpointFleetConfig(slots: [], installedAtLogin: false)
    }

    func slot(for role: ServingRole) -> EndpointSlot? {
        slots.first { $0.role == role }
    }

    /// The assigned slot's port, else the role's canonical port.
    func port(for role: ServingRole) -> Int {
        slot(for: role)?.port ?? role.defaultPort
    }

    /// Assigns roles from the legacy `roleDefaults` slots that have none, when
    /// no slot already holds that role. `roleDefaults` is left untouched.
    func migratingRoleDefaults() -> EndpointFleetConfig {
        var result = self
        for (id, role) in [(roleDefaults?.coding, ServingRole.coding), (roleDefaults?.utility, ServingRole.general)] {
            guard let id, !result.slots.contains(where: { $0.role == role }),
                  let index = result.slots.firstIndex(where: { $0.id == id && $0.role == nil }) else { continue }
            result.slots[index].role = role
        }
        return result
    }

    /// The saved default slot for a role, only if it still exists, is enabled
    /// and uses JIT. Both roles may resolve to the same slot.
    func defaultSlot(for role: EndpointDefaultRole) -> EndpointSlot? {
        guard let id = roleDefaults?[role],
              let slot = slots.first(where: { $0.id == id }),
              slot.enabled, slot.usesJIT else { return nil }
        return slot
    }
}

/// Store-layer invariants for the fleet (spec 09): few slots, distinct
/// ports, one slot per role, sane ports.
enum EndpointFleetValidation: Error, Equatable {
    case tooManySlots(Int)
    case invalidPort(Int)
    case duplicatePort(Int)
    case duplicateRole(ServingRole)
    case invalidMemoryPolicy(UUID)
    case invalidInference(UUID, String)
    case incompatibleAcceleration(UUID)
    case invalidAuthentication(UUID)
    case invalidFrontDoorKey
    case invalidAdapterEndpoint(UUID)
}

extension EndpointFleetValidation: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .tooManySlots(let count):
            return "The fleet is capped at \(EndpointFleetConfig.maxSlots) endpoints (got \(count))."
        case .invalidPort(let port):
            return "Port \(port) is outside 1–65535."
        case .duplicatePort(let port):
            return "Port \(port) is already used by another endpoint."
        case .duplicateRole(let role):
            return "Role \(role.title) is already assigned to another endpoint."
        case .invalidMemoryPolicy:
            return "Memory policy requires an idle timeout of 0–86400 seconds and a finite reserve of 0–1024 GB."
        case .invalidInference(_, let reason):
            return reason
        case .incompatibleAcceleration:
            return "Strata profiles use their own decoding controls. Output length and request defaults can be set separately."
        case .invalidAuthentication:
            return "API key authentication requires Load on request and a valid credential reference."
        case .invalidFrontDoorKey:
            return "The front door needs a valid credential reference."
        case .invalidAdapterEndpoint:
            return "A trained adapter endpoint uses explicit MLX-LM serving and does not inherit the base model's quality verdict."
        }
    }
}

extension EndpointFleetConfig {
    /// Throws the first violated invariant; returns the config otherwise.
    @discardableResult
    func validated() throws -> EndpointFleetConfig {
        if slots.count > EndpointFleetConfig.maxSlots {
            throw EndpointFleetValidation.tooManySlots(slots.count)
        }
        var seenPorts = Set<Int>()
        var seenRoles = Set<ServingRole>()
        for slot in slots {
            if let digest = slot.apiKeySHA256,
               !slot.usesJIT || digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil {
                throw EndpointFleetValidation.invalidAuthentication(slot.id)
            }
            if slot.inferenceOptions.hasRequestDefaults && !slot.usesJIT {
                throw EndpointFleetValidation.invalidInference(slot.id, "Request defaults require Load on request.")
            }
            if let reason = slot.inferenceOptions.validationError {
                throw EndpointFleetValidation.invalidInference(slot.id, reason)
            }
            if slot.splashPresetName != nil && !ServeLaunch.splashPresetIsLegal(jit: slot.usesJIT, hasServingProfile: slot.servingProfile != nil, accelerationRequested: slot.inferenceOptions.accelerationRequested, sharedPrefixCacheRequested: slot.inferenceOptions.sharedPrefixCacheRequested) {
                throw EndpointFleetValidation.incompatibleAcceleration(slot.id)
            }
            if slot.servingProfile != nil && !ServeLaunch.profileAllows(accelerationRequested: slot.inferenceOptions.accelerationRequested, thinkingOff: slot.inferenceOptions.thinkingOff, sharedPrefixCacheRequested: slot.inferenceOptions.sharedPrefixCacheRequested) {
                throw EndpointFleetValidation.incompatibleAcceleration(slot.id)
            }
            if slot.inferenceOptions.sharedPrefixCacheRequested && !ServeLaunch.sharedPrefixCacheIsLegal(runtime: "mlx_lm", jit: slot.usesJIT, hasAPIKey: slot.apiKeySHA256 != nil, hasSplashPreset: slot.splashPresetName != nil, hasServingProfile: slot.servingProfile != nil, hasTrainingReceipt: slot.trainingReceipt != nil, options: slot.inferenceOptions) {
                throw EndpointFleetValidation.invalidInference(slot.id, "Shared prefix cache requires a keyed MLX-LM load-on-request endpoint with a 16–2048 MiB budget and no incompatible options.")
            }
            if let receipt = slot.trainingReceipt {
                let pinned = receipt.hasPrefix("/") && receipt != "/" && !receipt.contains("\0") && slot.modelPath.hasPrefix("/")
                let allowedOptions = slot.servingProfile == nil && slot.splashPresetName == nil
                    && !slot.inferenceOptions.requested && !slot.inferenceOptions.hasRequestDefaults
                    && (slot.memoryPolicy == nil || slot.usesJIT)
                if !pinned || !allowedOptions { throw EndpointFleetValidation.invalidAdapterEndpoint(slot.id) }
            }
            if let policy = slot.memoryPolicy, !policy.isValid { throw EndpointFleetValidation.invalidMemoryPolicy(slot.id) }
            guard (1...65535).contains(slot.port) else {
                throw EndpointFleetValidation.invalidPort(slot.port)
            }
            guard seenPorts.insert(slot.port).inserted else {
                throw EndpointFleetValidation.duplicatePort(slot.port)
            }
            if let role = slot.role {
                guard seenRoles.insert(role).inserted else {
                    throw EndpointFleetValidation.duplicateRole(role)
                }
            }
        }
        if let frontDoor {
            guard (1...65535).contains(frontDoor.port) else { throw EndpointFleetValidation.invalidPort(frontDoor.port) }
            guard !seenPorts.contains(frontDoor.port) else { throw EndpointFleetValidation.duplicatePort(frontDoor.port) }
            guard frontDoor.apiKeySHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw EndpointFleetValidation.invalidFrontDoorKey
            }
        }
        return self
    }
}


enum EndpointState: Equatable, Sendable {
    case disabled
    case starting
    case running(modelPath: String, port: Int)
    /// The configured port is serving a different model than configured.
    case modelMismatch(servedModel: String, port: Int)
    /// Desired on but the server is down; restart attempts exhausted.
    case degraded(reason: String)
    /// Desired on, server not yet confirmed running (start requested).
    case waitingForServer

    var summary: String {
        switch self {
        case .disabled: return "Disabled"
        case .starting: return "Starting…"
        case .running(let modelPath, let port):
            return "Running \(URL(fileURLWithPath: modelPath).lastPathComponent) on :\(port)"
        case .modelMismatch(let served, let port):
            return "Port \(port) is serving a different model (\(served))"
        case .degraded(let reason): return "Degraded: \(reason)"
        case .waitingForServer: return "Waiting for server…"
        }
    }
}
