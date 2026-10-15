import Combine
import Foundation

@MainActor
final class TrainingEvaluationSession: ObservableObject {
    enum Operation { case previewing, evaluating }
    struct Preview {
        let prompt: String
        let plan: LabValue
        let hash: String
    }

    @Published var prompt = "" {
        didSet {
            guard prompt != oldValue else { return }
            revision += 1
            preview = nil
            result = nil
            errorMessage = nil
        }
    }
    @Published private(set) var operation: Operation?
    @Published private(set) var preview: Preview?
    @Published private(set) var result: LabResponse?
    @Published private(set) var errorMessage: String?
    private let receipt: String
    private let request: (LabRequest) async throws -> LabResponse
    private var revision = 0

    init(receipt: String, request: @escaping (LabRequest) async throws -> LabResponse) {
        self.receipt = receipt
        self.request = request
    }

    var isBusy: Bool { operation != nil }
    var canPreview: Bool { !isBusy && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canEvaluate: Bool { !isBusy && preview != nil && preview?.prompt == prompt }

    @discardableResult
    func previewEvaluation() -> Task<Void, Never>? {
        guard canPreview else { return nil }
        let prompt = prompt, revision = revision
        operation = .previewing
        preview = nil
        result = nil
        errorMessage = nil
        return Task {
            defer { operation = nil }
            do {
                let response = try await request(LabRequest(operation: "training-preview", receipt: receipt,
                    prompt: prompt, maxTokens: 128))
                guard self.revision == revision else { return }
                guard let plan = response.plan, let hash = plan.object?["preview_hash"]?.text,
                      !hash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    errorMessage = "Evaluation preview did not include a confirmation hash. Preview again before running."
                    return
                }
                preview = Preview(prompt: prompt, plan: plan, hash: hash)
            } catch {
                guard self.revision == revision else { return }
                errorMessage = AppHost.render(error)
            }
        }
    }

    @discardableResult
    func evaluate() -> Task<Void, Never>? {
        guard canEvaluate, let preview else { return nil }
        let revision = revision
        operation = .evaluating
        result = nil
        errorMessage = nil
        return Task {
            defer { operation = nil }
            do {
                let response = try await request(LabRequest(operation: "training-evaluate", receipt: receipt,
                    prompt: preview.prompt, maxTokens: 128, previewHash: preview.hash))
                guard self.revision == revision else { return }
                guard let outputs = response.report?.object?["outputs"]?.object,
                      outputs["baseline"]?.text != nil, outputs["adapter"]?.text != nil,
                      let digest = response.artifactSHA256, !digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    errorMessage = "Evaluation did not return paired outputs and a retained report hash. Run the comparison again."
                    return
                }
                result = response
            } catch {
                guard self.revision == revision else { return }
                errorMessage = AppHost.render(error)
            }
        }
    }
}
