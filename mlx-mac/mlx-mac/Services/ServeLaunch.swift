import Foundation

/// Which runtime, Splash preset, and memory policy a launch may combine.
/// Start now, a saved endpoint, and a login item all ask this before they build arguments.
struct ServeLaunch: Equatable, Sendable {
    var runtime: String
    /// Splash preset name passed as `--profile`. Nil for a Strata profile or an ordinary runtime.
    var splashPresetName: String?
    var includesMemoryPolicy: Bool

    /// Saved endpoint and login item. `otherwise` is `"auto"` for a login item.
    static func saved(splashPresetName: String?, hasServingProfile: Bool, jit: Bool, accelerationRequested: Bool, thinkingOff: Bool, otherwise: String = "auto") throws -> ServeLaunch {
        if let name = splashPresetName {
            guard splashPresetIsLegal(jit: jit, hasServingProfile: hasServingProfile, accelerationRequested: accelerationRequested) else {
                throw WorkflowEvidenceError.invalid("Splash preset is unavailable for this endpoint.")
            }
            return ServeLaunch(runtime: "splash", splashPresetName: name, includesMemoryPolicy: false)
        }
        if hasServingProfile {
            guard profileAllows(accelerationRequested: accelerationRequested, thinkingOff: thinkingOff) else {
                throw WorkflowEvidenceError.invalid("Local acceleration cannot be combined with a Strata serving profile.")
            }
            return ServeLaunch(runtime: "strata", splashPresetName: nil, includesMemoryPolicy: jit)
        }
        return ServeLaunch(runtime: otherwise, splashPresetName: nil, includesMemoryPolicy: jit)
    }

    /// Start now. A Splash runtime here is the picker value, not a named preset.
    static func startNow(runtime: String, hasServingProfile: Bool, options: LocalInferenceOptions) throws {
        let conflictsWithProfile = hasServingProfile && (options.accelerationRequested || options.thinkingOff)
        let textOnVision = options.textRequested && (runtime == "mlx-vlm" || options.visionCache)
        let visionOnText = options.visionCache && runtime == "mlx_lm"
        guard !conflictsWithProfile, !textOnVision, !visionOnText else {
            throw WorkflowEvidenceError.invalid("Choose text acceleration for MLX-LM or vision feature reuse for MLX-VLM, without a Strata profile.")
        }
    }

    static func splashPresetIsLegal(jit: Bool, hasServingProfile: Bool, accelerationRequested: Bool) -> Bool {
        jit && !hasServingProfile && !accelerationRequested
    }

    static func profileAllows(accelerationRequested: Bool, thinkingOff: Bool) -> Bool {
        !accelerationRequested && !thinkingOff
    }

    /// A Splash preset owns memory. Other JIT launches keep the requested policy.
    static func retainedMemoryPolicy(_ policy: EndpointMemoryPolicy?, jit: Bool, splashPresetName: String?) -> EndpointMemoryPolicy? {
        jit && splashPresetName == nil ? policy : nil
    }
}
