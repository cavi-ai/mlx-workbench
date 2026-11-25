import Foundation

/// Which runtime, Splash preset, and memory policy a launch may combine.
/// Start now, a saved endpoint, and a login item all ask this before they build arguments.
struct ServeLaunch: Equatable, Sendable {
    var runtime: String
    /// Splash preset name passed as `--profile`. Nil for a Strata profile or an ordinary runtime.
    var splashPresetName: String?
    var includesMemoryPolicy: Bool

    /// Saved endpoint and login item. `otherwise` is `"auto"` for a login item.
    static func saved(splashPresetName: String?, hasServingProfile: Bool, jit: Bool, accelerationRequested: Bool, thinkingOff: Bool, sharedPrefixCacheMiB: Int? = nil, hasAPIKey: Bool = false, systemPrompt: String = "", otherwise: String = "auto") throws -> ServeLaunch {
        let prefixRequested = sharedPrefixCacheMiB != nil
        if let name = splashPresetName {
            guard splashPresetIsLegal(jit: jit, hasServingProfile: hasServingProfile, accelerationRequested: accelerationRequested, sharedPrefixCacheRequested: prefixRequested) else {
                throw WorkflowEvidenceError.invalid("Splash preset is unavailable for this endpoint.")
            }
            return ServeLaunch(runtime: "splash", splashPresetName: name, includesMemoryPolicy: false)
        }
        if hasServingProfile {
            guard profileAllows(accelerationRequested: accelerationRequested, thinkingOff: thinkingOff, sharedPrefixCacheRequested: prefixRequested) else {
                throw WorkflowEvidenceError.invalid("Local acceleration and shared prefix cache cannot be combined with a serving profile.")
            }
            return ServeLaunch(runtime: "strata", splashPresetName: nil, includesMemoryPolicy: jit)
        }
        if let mib = sharedPrefixCacheMiB {
            let validRuntime = otherwise == "auto" || otherwise == "mlx_lm"
            guard validRuntime, jit, hasAPIKey, (16...2048).contains(mib), !accelerationRequested, systemPrompt.isEmpty else {
                throw WorkflowEvidenceError.invalid("Shared prefix cache requires a keyed MLX-LM load-on-request endpoint with a 16–2048 MiB budget and no incompatible options.")
            }
            return ServeLaunch(runtime: "mlx_lm", splashPresetName: nil, includesMemoryPolicy: true)
        }
        return ServeLaunch(runtime: otherwise, splashPresetName: nil, includesMemoryPolicy: jit)
    }

    /// Start now. A Splash runtime here is the picker value, not a named preset.
    static func startNow(runtime: String, hasServingProfile: Bool, options: LocalInferenceOptions, jit: Bool = false, hasAPIKey: Bool = false) throws {
        let conflictsWithProfile = hasServingProfile && (options.accelerationRequested || options.thinkingOff || options.sharedPrefixCacheRequested)
        let textOnVision = options.textRequested && (runtime == "mlx-vlm" || options.visionCache)
        let visionOnText = options.visionCache && runtime == "mlx_lm"
        guard !conflictsWithProfile, !textOnVision, !visionOnText else {
            throw WorkflowEvidenceError.invalid("Choose text acceleration for MLX-LM or vision feature reuse for MLX-VLM, without a Strata profile.")
        }
        guard splashLaunchIsLegal(runtime: runtime, options: options) else {
            throw WorkflowEvidenceError.invalid(splashLaunchMessage)
        }
        if options.sharedPrefixCacheRequested {
            guard sharedPrefixCacheIsLegal(runtime: runtime, jit: jit, hasAPIKey: hasAPIKey, hasSplashPreset: false, hasServingProfile: hasServingProfile, hasTrainingReceipt: false, options: options) else {
                throw WorkflowEvidenceError.invalid("Shared prefix cache requires a keyed MLX-LM load-on-request endpoint with a 16–2048 MiB budget and no incompatible options.")
            }
        }
    }

    static func splashPresetIsLegal(jit: Bool, hasServingProfile: Bool, accelerationRequested: Bool, sharedPrefixCacheRequested: Bool = false) -> Bool {
        jit && !hasServingProfile && !accelerationRequested && !sharedPrefixCacheRequested
    }

    /// A Splash draft model or chat template needs the Splash runtime; `auto` leaves the choice to the engine preview.
    static func splashLaunchIsLegal(runtime: String, options: LocalInferenceOptions?) -> Bool {
        !(options?.splashLaunchRequested ?? false) || ["splash", "auto"].contains(runtime)
    }

    static let splashLaunchMessage = "A Splash draft model or chat template needs the Splash runtime. Choose a Splash preset or clear the Splash files."

    static func profileAllows(accelerationRequested: Bool, thinkingOff: Bool, sharedPrefixCacheRequested: Bool = false) -> Bool {
        !accelerationRequested && !thinkingOff && !sharedPrefixCacheRequested
    }

    static func sharedPrefixCacheIsLegal(runtime: String, jit: Bool, hasAPIKey: Bool, hasSplashPreset: Bool = false, hasServingProfile: Bool = false, hasTrainingReceipt: Bool = false, options: LocalInferenceOptions) -> Bool {
        guard let mib = options.sharedPrefixCacheMiB else { return true }
        guard (16...2048).contains(mib) else { return false }
        guard runtime == "mlx_lm" else { return false }
        guard jit, hasAPIKey, !hasSplashPreset, !hasServingProfile, !hasTrainingReceipt else { return false }
        guard !options.accelerationRequested, options.systemPrompt.isEmpty else { return false }
        return true
    }

    /// A Splash preset owns memory. Other JIT launches keep the requested policy.
    static func retainedMemoryPolicy(_ policy: EndpointMemoryPolicy?, jit: Bool, splashPresetName: String?) -> EndpointMemoryPolicy? {
        jit && splashPresetName == nil ? policy : nil
    }
}
