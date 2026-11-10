import Foundation

struct LocalInferenceOptions: Codable, Equatable, Sendable {
    var m5Prefill = false
    var promptLookup = false
    var visionCache = false
    var thinkingOff = false
    var maximumTokens: Int? = nil
    var textRequested: Bool { m5Prefill || promptLookup || thinkingOff }
    var accelerationRequested: Bool { m5Prefill || promptLookup || visionCache }
    var requested: Bool { textRequested || visionCache || maximumTokens != nil }
    var validationError: String? {
        if let maximumTokens, !(256...65536).contains(maximumTokens) { return "Default output length must be from 256 to 65536 tokens." }
        if visionCache && (textRequested || maximumTokens != nil) { return "Choose vision feature reuse separately from text-server settings." }
        return nil
    }

    init(m5Prefill: Bool = false, promptLookup: Bool = false, visionCache: Bool = false, thinkingOff: Bool = false, maximumTokens: Int? = nil) {
        self.m5Prefill = m5Prefill; self.promptLookup = promptLookup; self.visionCache = visionCache
        self.thinkingOff = thinkingOff; self.maximumTokens = maximumTokens
    }

    enum CodingKeys: String, CodingKey { case m5Prefill, promptLookup, visionCache, thinkingOff, maximumTokens }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        m5Prefill = try values.decodeIfPresent(Bool.self, forKey: .m5Prefill) ?? false
        promptLookup = try values.decodeIfPresent(Bool.self, forKey: .promptLookup) ?? false
        visionCache = try values.decodeIfPresent(Bool.self, forKey: .visionCache) ?? false
        thinkingOff = try values.decodeIfPresent(Bool.self, forKey: .thinkingOff) ?? false
        maximumTokens = try values.decodeIfPresent(Int.self, forKey: .maximumTokens)
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
    }

    var isValid: Bool {
        !(keepLoaded && releaseAfterRequest == true) &&
        (0...86400).contains(idleTimeoutSeconds) &&
        (minimumHeadroomGB.map { $0.isFinite && (0...1024).contains($0) } ?? true) &&
        (modelMemoryBudgetGB.map { $0.isFinite && (1...1024).contains($0) } ?? true) &&
        (unloadUnderPressure != true || (minimumHeadroomGB != nil && !keepLoaded)) &&
        (contextTokens.map { (1024...1_048_576).contains($0) && minimumHeadroomGB != nil } ?? true)
    }

    var arguments: [String] {
        var result = ["--idle-timeout", String(idleTimeoutSeconds)]
        if keepLoaded { result.append("--keep-loaded") }
        if let releaseAfterRequest { result.append(releaseAfterRequest ? "--release-after-request" : "--no-release-after-request") }
        if let minimumHeadroomGB { result += ["--min-headroom-gb", String(minimumHeadroomGB)] }
        if let modelMemoryBudgetGB { result += ["--memory-budget-gb", String(modelMemoryBudgetGB)] }
        if unloadUnderPressure == true { result.append("--unload-under-pressure") }
        if let contextTokens { result += ["--context-tokens", String(contextTokens)] }
        return result
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
    var role: UseCase?
    /// Absent in legacy fleets: preserve their eager-serving behavior.
    var loadOnRequest: Bool?
    var memoryPolicy: EndpointMemoryPolicy?
    var servingProfile: ServingProfile? = nil
    var profilePreviewHash: String? = nil
    /// Existing fleet files use this storage key for local inference settings.
    var acceleration: LocalInferenceOptions? = nil
    var accelerationPreviewHash: String? = nil
    var apiKeySHA256: String? = nil
    var inferenceOptions: LocalInferenceOptions { acceleration ?? .init() }
    var usesJIT: Bool { loadOnRequest == true }

    init(id: UUID = UUID(), enabled: Bool, port: Int, modelPath: String, role: UseCase? = nil, loadOnRequest: Bool? = nil, memoryPolicy: EndpointMemoryPolicy? = nil) {
        self.id = id
        self.enabled = enabled
        self.port = port
        self.modelPath = modelPath
        self.role = role
        self.loadOnRequest = loadOnRequest
        self.memoryPolicy = memoryPolicy
    }
}

struct EndpointFleetConfig: Codable, Equatable, Sendable {
    var slots: [EndpointSlot]
    /// Whether the login LaunchAgent (boot persistence) is installed.
    var installedAtLogin: Bool

    static let maxSlots = 4

    static var empty: EndpointFleetConfig {
        EndpointFleetConfig(slots: [], installedAtLogin: false)
    }
}

/// Store-layer invariants for the fleet (spec 09): few slots, distinct
/// ports, one slot per role, sane ports.
enum EndpointFleetValidation: Error, Equatable {
    case tooManySlots(Int)
    case invalidPort(Int)
    case duplicatePort(Int)
    case duplicateRole(UseCase)
    case invalidMemoryPolicy(UUID)
    case invalidInference(UUID, String)
    case incompatibleAcceleration(UUID)
    case invalidAuthentication(UUID)
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
            return "Strata profiles use their own decoding controls. Only the default output length can be set separately."
        case .invalidAuthentication:
            return "API key authentication requires Load on request and a valid credential reference."
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
        var seenRoles = Set<UseCase>()
        for slot in slots {
            if let digest = slot.apiKeySHA256,
               !slot.usesJIT || digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil {
                throw EndpointFleetValidation.invalidAuthentication(slot.id)
            }
            if let reason = slot.inferenceOptions.validationError {
                throw EndpointFleetValidation.invalidInference(slot.id, reason)
            }
            if slot.servingProfile != nil && (slot.inferenceOptions.accelerationRequested || slot.inferenceOptions.thinkingOff) {
                throw EndpointFleetValidation.incompatibleAcceleration(slot.id)
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
