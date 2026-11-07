import Foundation

/// A concrete local installation, never a related repository or a family-name match.
struct ModelUpdatePreviousModel: Codable, Equatable, Identifiable {
    let repo: String
    let path: String
    let signature: String?
    let revision: String?
    let displayName: String
    let canQuarantine: Bool
    let retentionReason: String?
    var file: String? = nil
    var subfolder: String? = nil

    var id: String { path }
}

/// Captures the choices shown at confirmation. The engine preview and target revision
/// are pinned; endpoint identities/settings are captured by the integration when prepared.
struct ModelUpdateReview: Codable, Equatable, Identifiable {
    let id: UUID
    let repo: String
    let previous: ModelUpdatePreviousModel
    let resolution: IntakeResolution
    let targetRevision: String
    let destinationPath: String
    let previewHash: String
    let endpointSummary: [String]

    var downloadBytes: Int64? { resolution.downloadBytes }

    func validate() throws {
        guard previous.repo.caseInsensitiveCompare(repo) == .orderedSame,
              resolution.source.repo.caseInsensitiveCompare(repo) == .orderedSame else {
            throw ModelUpdateError.invalid("Choose a previous installation from the same Hugging Face repository.")
        }
        guard resolution.source.file == previous.file, resolution.source.subfolder == previous.subfolder else {
            throw ModelUpdateError.invalid("The new revision must use the same checkpoint folder and file as the previous model.")
        }
        _ = try ManagedModelInstallStore.sourceReference(repo: repo, file: previous.file, subfolder: previous.subfolder)
        guard resolution.verdict == .alreadyMLX, previous.file == nil, resolution.source.file == nil else {
            throw ModelUpdateError.requiresPreparation
        }
        guard Self.isCommit(targetRevision),
              resolution.source.fetchRevision.lowercased() == targetRevision.lowercased(),
              let oldRevision = previous.revision, Self.isCommit(oldRevision),
              oldRevision.lowercased() != targetRevision.lowercased(),
              let signature = previous.signature, !signature.isEmpty,
              !previewHash.isEmpty else {
            throw ModelUpdateError.invalid("The previous and new revisions must be known and different. Refresh the model library and review again.")
        }
        let old = URL(fileURLWithPath: previous.path).standardizedFileURL.path
        let new = URL(fileURLWithPath: destinationPath).standardizedFileURL.path
        guard previous.path.hasPrefix("/"), destinationPath.hasPrefix("/"), old != new,
              !new.hasPrefix(old + "/"), !old.hasPrefix(new + "/") else {
            throw ModelUpdateError.invalid("The update needs a separate managed model folder.")
        }
    }

    static func isCommit(_ value: String) -> Bool {
        value.count == 40 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }
}

struct ModelUpdateInstallation: Codable, Equatable {
    let repo: String
    let revision: String
    let path: String
    let signature: String

    func validate(for review: ModelUpdateReview) throws {
        guard repo.caseInsensitiveCompare(review.repo) == .orderedSame,
              revision.lowercased() == review.targetRevision.lowercased(),
              path == review.destinationPath, !signature.isEmpty else {
            throw ModelUpdateError.invalid("The download does not match the reviewed repository, revision and destination.")
        }
    }
}

enum ModelUpdateStage: String, Codable, Equatable {
    case accepted, downloading, verifying, switching, quarantining, completed

    var title: String {
        switch self {
        case .accepted: return "Update accepted"
        case .downloading: return "Downloading new revision"
        case .verifying: return "Verifying new revision"
        case .switching: return "Switching managed endpoints"
        case .quarantining: return "Moving previous version to Quarantine"
        case .completed: return "Update completed"
        }
    }
}

enum ModelUpdateState: String, Codable, Equatable { case inProgress, interrupted, failed, completed }

struct ModelUpdateRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let alertID: UUID?
    let review: ModelUpdateReview
    let quarantinePrevious: Bool
    let createdAt: Date
    var updatedAt: Date
    var stage: ModelUpdateStage
    var state: ModelUpdateState
    var installation: ModelUpdateInstallation?
    var error: String?
}

enum ModelUpdateMutation: Equatable { case download, verify, switchEndpoints, quarantinePrevious }

enum ModelUpdateError: LocalizedError {
    case invalid(String)
    case requiresPreparation
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .requiresPreparation: return "This revision needs preparation. Review it in Add from Hugging Face before choosing a conversion. The previous model will stay in place."
        case .unavailable: return "Model updates are unavailable."
        }
    }
}

/// Integration owns authoritative receipts, managed-install provenance, endpoint rollback,
/// occupancy checks and Quarantine. Every operation rechecks its captured review.
struct ModelUpdateAPI {
    var candidates: (String) async throws -> [ModelUpdatePreviousModel]
    var prepare: (String, ModelUpdatePreviousModel) async throws -> ModelUpdateReview
    var revalidate: (ModelUpdateReview, ModelUpdateMutation) async throws -> Void
    var download: (ModelUpdateReview) async throws -> ModelUpdateInstallation
    var verify: (ModelUpdateReview, ModelUpdateInstallation) async throws -> Void
    var switchEndpoints: (ModelUpdateReview, ModelUpdateInstallation) async throws -> Void
    var quarantinePrevious: (ModelUpdateReview, ModelUpdateInstallation) async throws -> Void

    static var unavailable: ModelUpdateAPI {
        ModelUpdateAPI(candidates: { _ in throw ModelUpdateError.unavailable },
            prepare: { _, _ in throw ModelUpdateError.unavailable },
            revalidate: { _, _ in throw ModelUpdateError.unavailable },
            download: { _ in throw ModelUpdateError.unavailable },
            verify: { _, _ in throw ModelUpdateError.unavailable },
            switchEndpoints: { _, _ in throw ModelUpdateError.unavailable },
            quarantinePrevious: { _, _ in throw ModelUpdateError.unavailable })
    }
}
