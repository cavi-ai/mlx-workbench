import Foundation

struct MediaSettingsBinding: Codable, Equatable, Sendable {
    let path: String
    let configSHA256: String
    enum CodingKeys: String, CodingKey { case path; case configSHA256 = "config_sha256" }
    var isValid: Bool { path.hasPrefix("/") && configSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
}

struct MediaReuseCapability: Codable, Equatable, Sendable {
    struct Memory: Codable, Equatable, Sendable {
        let minimum: Int
        let maximum: Int
        let `default`: Int
    }
    let modes: [String]
    let `default`: String
    let approximate: Bool
    let cacheMemoryMiB: Memory
    let unavailableReason: String?
    enum CodingKeys: String, CodingKey {
        case modes, `default`, approximate
        case cacheMemoryMiB = "cache_memory_mib", unavailableReason = "unavailable_reason"
    }
    var supportsAdaptive: Bool {
        modes == ["off", "adaptive"] && `default` == "off" && approximate
            && cacheMemoryMiB.minimum >= 8 && cacheMemoryMiB.maximum <= 4096
            && cacheMemoryMiB.minimum <= cacheMemoryMiB.default && cacheMemoryMiB.default <= cacheMemoryMiB.maximum
    }
}

struct MediaReuseSettings: Equatable, Sendable {
    var adaptive = false
    var memoryMiB = "256"
    static let allowance = IntegerSetting(title: "Feature-cache allowance", range: 8...4096)
    var title: String { adaptive ? "Experimental reuse" : "Standard" }
    var parameters: [String: JSONValue] {
        get throws {
            guard adaptive else { return [:] }
            guard let value = try Self.allowance.value(memoryMiB) else {
                throw InferenceSettingError(message: "Enter a feature-cache allowance of 8–4,096 MiB.")
            }
            return ["denoiser_cache": .string("adaptive"), "cache_memory_mib": .number(Double(value))]
        }
    }
    init(adaptive: Bool = false, memoryMiB: String = "256") { self.adaptive = adaptive; self.memoryMiB = memoryMiB }
    init(parameters: [String: JSONValue]) throws {
        try Self.validate(parameters)
        adaptive = parameters["denoiser_cache"]?.stringValue == "adaptive"
        memoryMiB = parameters["cache_memory_mib"]?.integerValue.map(String.init) ?? "256"
    }
    static func validate(_ parameters: [String: JSONValue]) throws {
        if let mode = parameters["denoiser_cache"] {
            guard let value = mode.stringValue, ["off", "adaptive"].contains(value) else { throw TaskProtocolError.invalidRequest }
        }
        if let memory = parameters["cache_memory_mib"] {
            guard let value = memory.integerValue else { throw TaskProtocolError.invalidRequest }
            try allowance.check(value)
        }
    }
}

struct MediaReuseReview: Identifiable, Equatable, Sendable {
    let id = UUID()
    let request: TaskRequest
    let binding: MediaSettingsBinding
}

extension MediaParameters {
    var reuseParameters: [String: JSONValue] {
        get throws {
            var values: [String: JSONValue] = [:]
            if let denoiserCache { values["denoiser_cache"] = .string(denoiserCache) }
            if let cacheMemoryMiB { values["cache_memory_mib"] = .number(Double(cacheMemoryMiB)) }
            try MediaReuseSettings.validate(values)
            return values
        }
    }
}

/// Reported telemetry is separate from the requested mode and from measured elapsed time.
struct MediaReuseReport: Equatable {
    let fullSteps: Int
    let reusedSteps: Int
    let peakCacheBytes: Int
    let memoryLimitBytes: Int
    let fallbackReason: String?
    init?(raw: JSONValue?) {
        guard let fields = raw?.objectValue, fields["mode"]?.stringValue == "adaptive",
              let full = fields["full_steps"]?.integerValue, full >= 0,
              let reused = fields["reused_steps"]?.integerValue, reused >= 0,
              let peak = fields["peak_cache_bytes"]?.integerValue, peak >= 0,
              let limit = fields["memory_limit_bytes"]?.integerValue, limit >= 0 else { return nil }
        fullSteps = full; reusedSteps = reused; peakCacheBytes = peak; memoryLimitBytes = limit
        fallbackReason = fields["fallback_reason"]?.stringValue
    }
    var summary: String { "\(fullSteps) full · \(reusedSteps) reused steps" }
    var explanation: String {
        if fallbackReason == "memory_limit" { return "Full computation: the required feature cache exceeded the allowance." }
        if fallbackReason != nil { return "The engine reported a fallback." }
        return reusedSteps == 0 ? "No steps were reused." : "Reuse can change the output. Review its visual quality."
    }
}

extension TaskCapabilities {
    func reuseCapability(for kind: TaskKind, modelPath: String) -> MediaReuseCapability? {
        guard isSupported, let model, model.isValid, Quarantine.resolve(model.path) == Quarantine.resolve(modelPath) else { return nil }
        return tasks.first(where: { $0.kind == kind })?.denoiserCache
    }
    func validateReuse(_ request: TaskRequest) throws {
        guard request.parameters["denoiser_cache"]?.stringValue == "adaptive" else { return }
        guard let capability = reuseCapability(for: request.kind, modelPath: request.modelPath), capability.supportsAdaptive else {
            throw InferenceSettingError(message: "This model does not advertise adaptive reuse. Choose Standard or select a compatible engine and model.")
        }
        let memory = request.parameters["cache_memory_mib"]?.integerValue ?? capability.cacheMemoryMiB.default
        guard (capability.cacheMemoryMiB.minimum...capability.cacheMemoryMiB.maximum).contains(memory) else {
            throw InferenceSettingError(message: "The feature-cache allowance is outside this model’s supported range.")
        }
    }
}
