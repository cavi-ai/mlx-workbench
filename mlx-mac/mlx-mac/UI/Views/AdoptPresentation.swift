import Foundation

// MARK: - Roles

/// Adopt takes exactly the roles `discover --role` takes, minus Any: an adoption needs a role.
enum AdoptRole {
    static let choices = WorkbenchAPI.discoveryRoleOrder
    static let initial = "general"

    static func title(_ role: String) -> String { DiscoverRole.title(role) }
}

// MARK: - Outcome

/// The agent's reported fields, verbatim; absent or empty ones are omitted.
struct AdoptOutcomeItem: Equatable {
    let figure: String
    let label: String
}

enum AdoptOutcome {
    static func items(_ response: AdoptResult?) -> [AdoptOutcomeItem] {
        guard let response else { return [] }
        return [
            ("Status", response.status),
            ("Phase", response.phase),
            ("Evidence strength", response.evidenceStrength),
        ].compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return AdoptOutcomeItem(figure: value, label: label)
        }
    }
}

// MARK: - Recommendation

enum AdoptNextStep: Equatable {
    /// A Library model matches the repository; `canRun` when it is ready and servable.
    case inLibrary(model: LibraryModel, canRun: Bool)
    case addFromHuggingFace(enabled: Bool, help: String)
}

enum AdoptRecommendationState: Equatable {
    case idle
    case noRecommendation
    case recommended(repo: String, step: AdoptNextStep)

    static let idleSentence = "The recommendation appears after adoption starts."
    static let noRecommendationSentence = "No recommendation reported."

    /// The library match is exact on the Hugging Face repo id of a cached model.
    static func make(response: AdoptResult?, library: LibrarySnapshot?, intakeIsBusy: Bool) -> AdoptRecommendationState {
        guard let response else { return .idle }
        guard let repo = response.model, !repo.isEmpty else { return .noRecommendation }
        if let model = library?.models.first(where: { HFRepoID.forPath($0.item.path) == repo }) {
            let canRun = ModelTaskPresentation.isServable(model) && model.readiness == .ready
            return .recommended(repo: repo, step: .inLibrary(model: model, canRun: canRun))
        }
        return .recommended(repo: repo, step: .addFromHuggingFace(
            enabled: DiscoverIntakeAction.isEnabled(intakeIsBusy: intakeIsBusy),
            help: DiscoverIntakeAction.help(intakeIsBusy: intakeIsBusy)
        ))
    }
}
