import Combine
import Foundation

struct StudyRecipeOption: Decodable, Sendable {
    let modelID: String
    let displayName: String
    let revisions: [String]
    let unavailableReason: String?
    enum CodingKeys: String, CodingKey {
        case modelID = "model_id", displayName = "display_name", revisions, unavailableReason = "unavailable_reason"
    }
}

struct StudyRecipeDraft: Equatable {
    var revision = ""
    var prompt = ""
    var negativePrompt = ""
    var seed = "42"
    var width = "256"
    var height = "144"
    var frames = "17"
    var fps = "8"
    var steps = "20"
    var guidance = "5"

    var validationError: String? {
        guard revision.count == 40, revision.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            return "Choose a cached model revision."
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 8000, negativePrompt.count <= 8000 else {
            return "Enter a prompt of up to 8,000 characters. The negative prompt has the same limit."
        }
        guard let seed = Int(seed), seed >= 0 else { return "Seed must be a nonnegative integer." }
        for (name, raw) in [("Width", width), ("Height", height)] {
            guard let value = Int(raw), (16...4096).contains(value), value % 16 == 0 else {
                return "\(name) must be 16–4096, in multiples of 16."
            }
        }
        guard let frames = Int(frames), (17...129).contains(frames), (frames - 1) % 16 == 0 else {
            return "Frames must be 17–129 and equal 16n+1."
        }
        guard let fps = Int(fps), (1...120).contains(fps) else { return "FPS must be 1–120." }
        guard let steps = Int(steps), (1...1000).contains(steps) else { return "Inference steps must be 1–1000." }
        guard let guidance = Double(guidance), guidance.isFinite, (0...100).contains(guidance) else { return "Guidance must be 0–100." }
        return nil
    }

    var settings: LabValue? {
        guard validationError == nil, let seed = Int(seed), let width = Int(width), let height = Int(height),
              let frames = Int(frames), let fps = Int(fps), let steps = Int(steps), let guidance = Double(guidance) else { return nil }
        return .object(["revision": .string(revision), "prompt": .string(prompt), "negative_prompt": .string(negativePrompt),
            "seed": .integer(seed), "width": .integer(width), "height": .integer(height), "num_frames": .integer(frames),
            "fps": .integer(fps), "inference_steps": .integer(steps), "guidance_scale": .number(guidance)])
    }
}

@MainActor
final class StudyRecipeSession: ObservableObject {
    @Published var draft = StudyRecipeDraft() {
        didSet { if draft != oldValue { manifest = nil; error = nil } }
    }
    @Published private(set) var options: [StudyRecipeOption] = []
    @Published private(set) var manifest: LabValue?
    @Published private(set) var error: String?
    @Published private(set) var isBusy = false
    private let request: (LabRequest) async throws -> LabResponse

    init(request: @escaping (LabRequest) async throws -> LabResponse) { self.request = request }

    var unavailableReason: String? {
        if isBusy { return "Wait for the current recipe request to finish." }
        guard let option = options.first else {
            return "Refresh availability to check the cached model and study runtime."
        }
        if let reason = option.unavailableReason { return reason }
        guard !option.revisions.isEmpty else {
            return "No cached revision is available. Use the supported Diffusers model in your configured Hugging Face cache, then Refresh availability."
        }
        if let error = draft.validationError { return error }
        guard option.revisions.contains(draft.revision) else {
            return "The selected revision is no longer available. Choose a current cached revision."
        }
        return nil
    }
    var canCapture: Bool { unavailableReason == nil }

    func load() async {
        guard !isBusy else { return }
        isBusy = true
        manifest = nil
        defer { isBusy = false }
        do {
            let response = try await request(LabRequest(operation: "recipe-catalog"))
            guard let options = response.recipes, options.count == 1,
                  options[0].modelID == "Wan-AI/Wan2.1-T2V-1.3B-Diffusers" else { throw BridgeError.skillOutputUnreadable }
            self.options = options
            if draft.revision.isEmpty, let revision = options.first?.revisions.first { draft.revision = revision }
            error = nil
        } catch { options = []; self.error = AppHost.render(error) }
    }

    func capture() async {
        guard canCapture, let settings = draft.settings else { return }
        let captured = draft
        isBusy = true
        manifest = nil
        error = nil
        defer { isBusy = false }
        do {
            let response = try await request(LabRequest(operation: "recipe-prepare", settings: settings))
            guard draft == captured else { return }
            guard let value = response.manifest, let fields = value.object,
                  fields["model_id"]?.text == options.first?.modelID,
                  fields["adapter_id"]?.text == "diffusers.wan2.1-t2v-1.3b.mps.v1",
                  fields["model_revision"]?.text == captured.revision,
                  let digest = fields["model_checksum"]?.text, digest.hasPrefix("sha256:"), digest.count == 71,
                  let assets = fields["source_checksums"]?.object, !assets.isEmpty,
                  let versions = fields["runtime_versions"]?.object, !versions.isEmpty,
                  settings.object?.allSatisfy({ name, expected in
                      if name == "revision" { return true }
                      let actual = fields[name]
                      if let number = expected.decimal { return actual?.decimal == number }
                      return actual == expected
                  }) == true else { throw BridgeError.skillOutputUnreadable }
            manifest = value
        } catch {
            guard draft == captured else { return }
            self.error = AppHost.render(error)
        }
    }
}
