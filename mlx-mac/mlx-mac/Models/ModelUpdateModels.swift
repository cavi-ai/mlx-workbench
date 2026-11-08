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
    var convertedOrigin: ModelUpdateConvertedOrigin? = nil
    var needsSourceConfirmation: Bool? = nil
    var isConverted: Bool? = nil
    var requiresProjector: Bool? = nil
    var additionalFiles: [String]? = nil
    var projectorFile: String? = nil

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
    var conversion: ModelUpdateConversionRecipe? = nil
    var downloadDirectory: String? = nil
    var additionalFiles: [String]? = nil
    var projectorFile: String? = nil
    var requiresProjector: Bool? = nil
    var dependencies: [ModelUpdateDependency]? = nil
    var sourceConfirmed: Bool? = nil
    var reviewedEndpoints: [EndpointSlot]? = nil
    var fileSelectionConfirmed: Bool? = nil
    var requiredCompanionSelection: Bool? = nil
    var selectionProblem: String? = nil
    var cleanupPath: String? = nil
    var cleanupSnapshot: QuarantineFileSnapshot? = nil
    var previousInstall: ManagedModelInstall? = nil
    var cleanupBundle: String? = nil
    var cleanupFiles: [String]? = nil
    var downloadsDirectory: String? = nil
    var downloadFetchReceipt: String? = nil
    var downloadAdmissionPreviewHash: String? = nil

    var missingSelectionReason: String? {
        if let selectionProblem { return selectionProblem }
        if requiredCompanionSelection == true { return "Review the companion files missing from this new revision and choose their replacements." }
        if previous.needsSourceConfirmation == true && sourceConfirmed != true { return "Confirm the repository source for this local model." }
        if let conversion, conversion.kind == .repository,
           !(resolution.qBits ?? [4, 8]).contains(conversion.qBits) { return "Choose a bit width supported by this revision." }
        if resolution.verdict == .gguf && resolution.source.file == nil { return "Choose the GGUF file to download from this revision." }
        if requiresProjector == true && projectorFile == nil { return "Choose the vision projector to preserve image support." }
        return nil
    }
    func validateForDownload() throws {
        try validate()
        if let reason = missingSelectionReason { throw ModelUpdateError.invalid(reason) }
    }

    var sourceDirectory: String {
        if let downloadDirectory { return downloadDirectory }
        var root = URL(fileURLWithPath: destinationPath)
        if let selection = resolution.source.file ?? resolution.source.subfolder {
            for _ in selection.split(separator: "/") { root.deleteLastPathComponent() }
        }
        return root.path
    }
    var downloadedModelPath: String {
        (resolution.source.file ?? resolution.source.subfolder).map {
            URL(fileURLWithPath: sourceDirectory).appendingPathComponent($0).path
        } ?? sourceDirectory
    }
    var needsPreparation: Bool { conversion != nil }

    var downloadBytes: Int64? {
        guard resolution.verdict == .gguf, let main = resolution.source.file else { return resolution.downloadBytes }
        let names = Set([main] + (additionalFiles ?? []))
        let files = resolution.files.gguf.filter { names.contains($0.name) }
        guard files.count == names.count else { return nil }
        var total: Int64 = 0
        for file in files {
            let (sum, overflow) = total.addingReportingOverflow(file.bytes)
            guard file.bytes >= 0, !overflow else { return nil }
            total = sum
        }
        return total
    }

    func validate() throws {
        guard previous.repo.caseInsensitiveCompare(repo) == .orderedSame,
              resolution.source.repo.caseInsensitiveCompare(repo) == .orderedSame else {
            throw ModelUpdateError.invalid("Choose a previous installation from the same Hugging Face repository.")
        }
        guard previous.needsSourceConfirmation == true ||
              resolution.source.file == previous.file && resolution.source.subfolder == previous.subfolder ||
              resolution.verdict == .gguf && resolution.source.subfolder == nil && (resolution.source.file == nil || fileSelectionConfirmed == true) else {
            throw ModelUpdateError.invalid("The new revision must use the same checkpoint folder and file as the previous model.")
        }
        _ = try ManagedModelInstallStore.sourceReference(repo: repo, file: previous.file, subfolder: previous.subfolder)
        if let conversion {
            try conversion.validate()
            if conversion.kind == .gguf {
                guard resolution.verdict == .gguf,
                      resolution.source.file.map({ file in resolution.files.gguf.contains(where: { $0.name == file }) }) ?? true else { throw ModelUpdateError.requiresPreparation }
            } else {
                guard [.convertible, .convertibleAfterInstall].contains(resolution.verdict),
                      conversion.backend == resolution.backend, conversion.modelType == resolution.modelType else {
                    throw ModelUpdateError.invalid("This revision does not support the reviewed conversion settings.")
                }
            }
            guard downloadDirectory != nil, downloadedModelPath != destinationPath else {
                throw ModelUpdateError.invalid("Preparation needs separate source and output folders.")
            }
        } else {
            guard resolution.verdict == .alreadyMLX && previous.file == nil || resolution.verdict == .gguf else { throw ModelUpdateError.requiresPreparation }
        }
        let extras = additionalFiles ?? []
        guard Set(extras).count == extras.count, !extras.contains(resolution.source.file ?? ""),
              projectorFile.map({ extras.contains($0) }) ?? true else {
            throw ModelUpdateError.invalid("Review the exact companion files required by this model.")
        }
        for file in extras {
            _ = try ManagedModelInstallStore.sourceReference(repo: repo, file: file, subfolder: nil)
            guard resolution.files.gguf.contains(where: { $0.name == file }) else {
                throw ModelUpdateError.invalid("A selected companion file is missing from the new revision.")
            }
        }
        guard Self.isCommit(targetRevision),
              resolution.source.fetchRevision.lowercased() == targetRevision.lowercased(),
              previous.revision.map({ Self.isCommit($0) && $0.lowercased() != targetRevision.lowercased() }) ?? (previous.convertedOrigin != nil || previous.needsSourceConfirmation == true),
              let signature = previous.signature, !signature.isEmpty,
              !previewHash.isEmpty else {
            throw ModelUpdateError.invalid("The previous and new revisions must be known and different. Refresh the model library and review again.")
        }
        let source = URL(fileURLWithPath: sourceDirectory).standardizedFileURL.path
        guard sourceDirectory.hasPrefix("/"), sourceDirectory == source,
              source != previous.path, !source.hasPrefix(previous.path + "/"), !previous.path.hasPrefix(source + "/"),
              !needsPreparation || !destinationPath.hasPrefix(source + "/") && !source.hasPrefix(destinationPath + "/") else {
            throw ModelUpdateError.invalid("The source download needs a separate managed folder.")
        }
        let dependencyPaths = (dependencies ?? []).map(\.directory)
        guard Set(dependencyPaths).count == dependencyPaths.count,
              dependencyPaths.allSatisfy({ path in
                  path.hasPrefix("/") && path == URL(fileURLWithPath: path).standardizedFileURL.path &&
                  ![previous.path, source, destinationPath].contains(where: { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") })
              }) else { throw ModelUpdateError.invalid("Required components need separate managed folders.") }
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
    var fetchReceipt: String? = nil
    var dependencyFetchReceipts: [String]? = nil
    var sourceFiles: [ModelUpdateLocalSource]? = nil
    var conversionReceipt: String? = nil
    var conversionPreviewHash: String? = nil
    var profileReplacements: [UUID: ServingProfile]? = nil

    func validateDownload(for review: ModelUpdateReview) throws {
        guard repo.caseInsensitiveCompare(review.repo) == .orderedSame,
              revision.lowercased() == review.targetRevision.lowercased(),
              path == review.downloadedModelPath, !signature.isEmpty else {
            throw ModelUpdateError.invalid("The download does not match the reviewed source and revision.")
        }
        if review.needsPreparation, fetchReceipt?.hasPrefix("/") != true {
            throw ModelUpdateError.invalid("Preparation requires the completed source download receipt.")
        }
    }

    func validate(for review: ModelUpdateReview) throws {
        guard repo.caseInsensitiveCompare(review.repo) == .orderedSame,
              revision.lowercased() == review.targetRevision.lowercased(),
              path == review.destinationPath, !signature.isEmpty else {
            throw ModelUpdateError.invalid("The download does not match the reviewed repository, revision and destination.")
        }
    }
}

enum ModelUpdateStage: String, Codable, Equatable {
    case accepted, downloading, awaitingPreparation, preparing, verifying, switching, quarantining, completed

    var title: String {
        switch self {
        case .accepted: return "Update accepted"
        case .downloading: return "Downloading new revision"
        case .awaitingPreparation: return "Review preparation"
        case .preparing: return "Preparing new revision"
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
    var downloadedSource: ModelUpdateInstallation? = nil
    var preparation: ModelUpdatePreparationReview? = nil
    var endpointsSwitched: Bool? = nil
    var switchedEndpoints: [EndpointSlot]? = nil
    var cleanupCompleted: Bool? = nil
}

enum ModelUpdateMutation: Equatable { case download, prepare, verify, switchEndpoints, quarantinePrevious }

enum ModelUpdateError: LocalizedError {
    case invalid(String)
    case requiresPreparation
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .requiresPreparation: return "This revision does not declare a supported preparation recipe. The previous model will stay in place."
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
    var verify: (ModelUpdateReview, ModelUpdateInstallation) async throws -> ModelUpdateInstallation
    var switchEndpoints: (ModelUpdateReview, ModelUpdateInstallation) async throws -> Void
    var quarantinePrevious: (ModelUpdateReview, ModelUpdateInstallation) async throws -> Void
    var previewPreparation: (ModelUpdateReview, ModelUpdateInstallation) async throws -> ModelUpdatePreparationReview = { _, _ in throw ModelUpdateError.unavailable }
    var prepareInstallation: (ModelUpdateReview, ModelUpdateInstallation, ModelUpdatePreparationReview) async throws -> ModelUpdatePreparedResult = { _, _, _ in throw ModelUpdateError.unavailable }
    var revisePreparation: (ModelUpdateRecord, Int) async throws -> ModelUpdateRecord = { _, _ in throw ModelUpdateError.unavailable }
    var previewRecovery: (ModelUpdateRecord) async throws -> ModelUpdateRecoveryReview = { _ in throw ModelUpdateError.unavailable }
    var applyRecovery: (ModelUpdateRecord, ModelUpdateRecoveryReview) async throws -> ModelUpdateRecord = { _, _ in throw ModelUpdateError.unavailable }
    var recover: (ModelUpdateRecord) async throws -> ModelUpdateRecord = { _ in throw ModelUpdateError.unavailable }
    var switchedEndpoints: (ModelUpdateReview) -> [EndpointSlot]? = { _ in nil }
    var prepareWithOptions: ((String, ModelUpdatePreviousModel, ModelUpdateSettings) async throws -> ModelUpdateReview)? = nil

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

/// Only terminal failed staging paths can be moved by this separate confirmation.
struct ModelUpdateRecoveryReview: Equatable, Identifiable {
    let recordID: UUID
    let snapshots: [QuarantineFileSnapshot]
    let failedReceipts: [String]
    let queueItems: [String]
    let resetsDownload: Bool
    var id: UUID { recordID }
}
