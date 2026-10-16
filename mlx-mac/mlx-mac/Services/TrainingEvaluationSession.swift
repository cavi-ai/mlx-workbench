import Combine
import Foundation

@MainActor
final class TrainingEvaluationSession: ObservableObject {
    enum Operation { case previewing, evaluating, savingReview }
    struct Preview {
        let prompt: String
        let maxTokens: Int?
        let suite: TrainingEvaluationSuite?
        let revision: Int
        let plan: LabValue
        let hash: String
    }
    struct ReviewDraft: Equatable {
        var preference = ""
        var notes = ""
    }

    @Published var prompt = "" {
        didSet {
            guard prompt != oldValue else { return }
            invalidate()
        }
    }
    @Published var maxTokens = "128" { didSet { if maxTokens != oldValue { invalidate() } } }
    @Published private(set) var suite: TrainingEvaluationSuite? { didSet { if suite != oldValue { invalidate() } } }
    @Published private(set) var operation: Operation?
    @Published private(set) var preview: Preview?
    @Published private(set) var result: LabResponse?
    @Published private(set) var errorMessage: String?
    @Published private(set) var samples: [TrainingEvaluationSample] = []
    @Published private(set) var reviews: [TrainingEvaluationReview] = []
    @Published private(set) var reviewDrafts: [String: ReviewDraft] = [:]
    @Published private(set) var reviewError: String?
    @Published private(set) var reviewNotice: String?
    @Published var selectedPromptID = ""
    let isRetainedOnly: Bool
    private let receipt: String
    private let request: (LabRequest) async throws -> LabResponse
    private var revision = 0

    init(receipt: String, retained: LabResponse? = nil, request: @escaping (LabRequest) async throws -> LabResponse) {
        self.receipt = receipt
        self.request = request
        isRetainedOnly = retained != nil
        if let retained {
            do { try publish(retained) } catch { errorMessage = AppHost.render(error) }
        }
    }

    var isBusy: Bool { operation != nil }
    var canChangeSetup: Bool { !isBusy && !hasUnsavedReviews }
    var inputValidation: String? {
        guard suite == nil else { return nil }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.count > 8000 {
            return "Enter an evaluation prompt of 1–8,000 characters."
        }
        guard let limit = Int(maxTokens), (1...512).contains(limit) else { return "Enter a token limit from 1 to 512." }
        return nil
    }
    var canPreview: Bool { canChangeSetup && !isRetainedOnly && inputValidation == nil }
    var canEvaluate: Bool { canChangeSetup && !isRetainedOnly && preview?.revision == revision }
    var selectedSample: TrainingEvaluationSample? { samples.first { $0.id == selectedPromptID } ?? samples.first }
    var hasUnsavedReviews: Bool {
        reviewDrafts.contains { id, draft in draft != savedDraft(id) }
    }
    func draft(_ id: String) -> ReviewDraft { reviewDrafts[id] ?? savedDraft(id) }
    private func savedDraft(_ id: String) -> ReviewDraft {
        guard let review = reviews.first(where: { $0.promptID == id }) else { return ReviewDraft() }
        return ReviewDraft(preference: review.preference, notes: review.notes)
    }
    func updateReview(_ id: String, _ draft: ReviewDraft) {
        guard !isBusy, samples.contains(where: { $0.id == id }) else { return }
        reviewDrafts[id] = draft; reviewError = nil; reviewNotice = nil
    }
    func selectSuite(_ set: PromptSet) {
        guard canChangeSetup else { return }
        do { suite = try TrainingEvaluationSuite(set); errorMessage = nil }
        catch { errorMessage = AppHost.render(error) }
    }
    func useSinglePrompt() { if canChangeSetup { suite = nil } }

    private func clearEvidence() {
        result = nil; samples = []; reviews = []; reviewDrafts = [:]
        selectedPromptID = ""; reviewError = nil; reviewNotice = nil
    }
    private func invalidate() {
        revision += 1; preview = nil; clearEvidence(); errorMessage = nil
    }
    private func publish(_ response: LabResponse) throws {
        guard let id = response.evaluationID, !id.isEmpty, let report = response.report,
              let digest = response.artifactSHA256, digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw WorkflowEvidenceError.invalid("Evaluation did not return a retained identity and report hash.")
        }
        let parsed = try TrainingEvaluationSample.parse(report)
        try validateReviews(response.reviews ?? [], evaluationID: id, digest: digest, samples: parsed)
        result = response; samples = parsed; reviews = response.reviews ?? []
        reviewDrafts = [:]; selectedPromptID = parsed.first?.id ?? ""
    }
    private func validateReviews(_ values: [TrainingEvaluationReview], evaluationID: String, digest: String,
                                samples: [TrainingEvaluationSample]) throws {
        guard Set(values.map(\.promptID)).count == values.count,
              values.allSatisfy({ review in !review.id.isEmpty && review.evaluationID == evaluationID && review.artifactSHA256 == digest
                  && samples.contains(where: { sample in sample.id == review.promptID })
                  && TrainingEvaluationReview.preferences.contains(review.preference) && review.notes.count <= 2000 }) else {
            throw WorkflowEvidenceError.invalid("A review does not match this retained evaluation.")
        }
    }

    @discardableResult
    func previewEvaluation() -> Task<Void, Never>? {
        guard canPreview else { return nil }
        let prompt = prompt, revision = revision
        let suite = suite, limit = suite == nil ? Int(maxTokens) : nil
        operation = .previewing
        preview = nil
        clearEvidence()
        errorMessage = nil
        return Task {
            defer { operation = nil }
            do {
                let response = try await request(LabRequest(operation: "training-preview", receipt: receipt,
                    prompt: suite == nil ? prompt : nil, maxTokens: limit, promptSuite: suite))
                guard self.revision == revision else { return }
                guard let plan = response.plan, let hash = plan.object?["preview_hash"]?.text,
                      !hash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    errorMessage = "Evaluation preview did not include a confirmation hash. Preview again before running."
                    return
                }
                if let suite {
                    guard let captured = plan.object?["prompt_suite"],
                          try JSONDecoder().decode(TrainingEvaluationSuite.self, from: JSONEncoder().encode(captured)) == suite else {
                        throw WorkflowEvidenceError.invalid("The preview returned different evaluation prompts.")
                    }
                }
                preview = Preview(prompt: prompt, maxTokens: limit, suite: suite, revision: revision, plan: plan, hash: hash)
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
        clearEvidence()
        errorMessage = nil
        return Task {
            defer { operation = nil }
            do {
                let response = try await request(LabRequest(operation: "training-evaluate", receipt: receipt,
                    prompt: preview.suite == nil ? preview.prompt : nil, maxTokens: preview.maxTokens,
                    previewHash: preview.hash, promptSuite: preview.suite))
                guard self.revision == revision else { return }
                guard let report = response.report, report.object?["preview_hash"]?.text == preview.hash else {
                    throw WorkflowEvidenceError.invalid("The retained report does not match the reviewed evaluation.")
                }
                let parsed = try TrainingEvaluationSample.parse(report)
                if let suite = preview.suite {
                    guard parsed.map(\.id) == suite.prompts.map(\.id),
                          zip(parsed, suite.prompts).allSatisfy({ pair in pair.0.prompt == pair.1.text && pair.0.maxTokens == pair.1.maxTokens }) else {
                        throw WorkflowEvidenceError.invalid("Evaluation did not return every reviewed prompt in order.")
                    }
                } else {
                    guard parsed.count == 1, parsed[0].prompt == preview.prompt, parsed[0].maxTokens == preview.maxTokens else {
                        throw WorkflowEvidenceError.invalid("The evaluation prompt or token limit changed.")
                    }
                }
                try publish(response)
            } catch {
                guard self.revision == revision else { return }
                errorMessage = AppHost.render(error)
            }
        }
    }

    var reviewValidation: String? {
        guard let selectedSample else { return "Choose a retained prompt." }
        let value = draft(selectedSample.id)
        if !TrainingEvaluationReview.preferences.contains(value.preference) { return "Choose a preference before saving." }
        return value.notes.count > 2000 ? "Keep review notes within 2,000 characters." : nil
    }
    var canSaveReview: Bool {
        guard !isBusy, let selectedSample, result != nil, reviewValidation == nil else { return false }
        return draft(selectedSample.id) != savedDraft(selectedSample.id)
    }

    @discardableResult
    func saveReview() -> Task<Void, Never>? {
        guard canSaveReview, let sample = selectedSample, let response = result,
              let identity = response.evaluationID, let digest = response.artifactSHA256 else { return nil }
        let captured = draft(sample.id), revision = revision
        operation = .savingReview; reviewError = nil; reviewNotice = nil
        return Task {
            defer { operation = nil }
            do {
                let saved = try await request(LabRequest(operation: "training-review", preference: captured.preference,
                    notes: captured.notes, evaluationID: identity, promptID: sample.id, artifactSHA256: digest))
                guard self.revision == revision else { return }
                guard saved.evaluationID == identity, saved.artifactSHA256 == digest, let values = saved.reviews,
                      let reviewID = saved.reviewID,
                      values.contains(where: { $0.id == reviewID && $0.promptID == sample.id
                          && $0.preference == captured.preference && $0.notes == captured.notes }) else {
                    throw WorkflowEvidenceError.invalid("The saved review could not be confirmed for this report.")
                }
                try validateReviews(values, evaluationID: identity, digest: digest, samples: samples)
                reviews = values; var updated = response; updated.reviews = values; result = updated
                reviewDrafts[sample.id] = captured; reviewNotice = "Review saved."
            } catch {
                guard self.revision == revision else { return }
                reviewError = AppHost.render(error)
            }
        }
    }
}
