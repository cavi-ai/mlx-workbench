import Foundation

struct ModelUpdateSettings: Equatable {
    var qBits: Int? = nil
    var ggufFile: String? = nil
    var projectorFile: String? = nil
    var sourceConfirmed = false
    var additionalFiles: [String]? = nil
}

/// The transformation selected for the new revision, independent of its download.
struct ModelUpdateConversionRecipe: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case gguf, repository }
    let kind: Kind
    let qBits: Int
    let backend: String?
    let modelType: String?

    func validate() throws {
        guard [4, 5, 6, 8, 32].contains(qBits),
              kind != .gguf || qBits != 32,
              kind != .repository || backend?.isEmpty == false else {
            throw ModelUpdateError.invalid("Choose a supported converter and bit width for this revision.")
        }
    }
    var title: String {
        "\(qBits)-bit · " + (kind == .gguf ? "GGUF conversion" : (backend ?? "MLX conversion"))
    }
}

/// Retained, exact source evidence for an existing converted artifact.
struct ModelUpdateConvertedOrigin: Codable, Equatable, Sendable {
    let recipe: ModelUpdateConversionRecipe
    let sourcePath: String
    let sourceSignature: String
    let conversionReceipt: String
    var fetchReceipt: String? = nil
    var projectorFile: String? = nil
    var workflowID: UUID? = nil
    var requiresProjector: Bool? = nil
}

struct ModelUpdateLocalSource: Codable, Equatable, Sendable {
    let path: String
    let signature: String
}

struct ModelUpdateDependency: Codable, Equatable {
    let resolution: IntakeResolution
    let directory: String
    let modelPath: String
    let previewHash: String
    var additionalFiles: [String] = []
}

/// Local preparation is previewed only after the pinned source download finishes.
/// Confirming this value cannot change the source, converter or destination.
struct ModelUpdatePreparationReview: Codable, Equatable, Identifiable {
    let id: UUID
    let previewHash: String
    let recipe: ModelUpdateConversionRecipe
    let repo: String
    let sourcePath: String
    let outputPath: String
    let fetchReceipt: String
    let sourceFiles: [ModelUpdateLocalSource]
    var projectorPath: String? = nil
    var requireProjector = false
    var dependencyFetchReceipts: [String] = []
    var subfolder: String? = nil
    var operation: Operation = .convert
    var backendInstallID: String? = nil
    var downloadsDirectory: String? = nil
    var backendInstallation: ModelUpdateBackendInstallation? = nil
    enum Operation: String, Codable { case convert, installBackend, observeConversion }

    func validate(for review: ModelUpdateReview) throws {
        try recipe.validate()
        guard recipe == review.conversion, repo == review.repo,
              sourcePath == review.downloadedModelPath, outputPath == review.destinationPath,
              subfolder == review.resolution.source.subfolder, downloadsDirectory == review.downloadsDirectory,
              requireProjector == (review.requiresProjector == true),
              operation != .installBackend || backendInstallID == recipe.backend && backendInstallation?.id == backendInstallID,
              !previewHash.isEmpty, fetchReceipt.hasPrefix("/"), !sourceFiles.isEmpty,
              sourceFiles.contains(where: { $0.path == sourcePath }),
              sourceFiles.allSatisfy({ $0.path.hasPrefix("/") && !$0.signature.isEmpty }),
              Set(sourceFiles.map(\.path)).count == sourceFiles.count,
              !requireProjector || projectorPath != nil,
              projectorPath == review.projectorFile.map({ URL(fileURLWithPath: review.sourceDirectory).appendingPathComponent($0).path }),
              dependencyFetchReceipts.count == (review.dependencies?.count ?? 0),
              Set(dependencyFetchReceipts).count == dependencyFetchReceipts.count,
              dependencyFetchReceipts.allSatisfy({ $0.hasPrefix("/") }) else {
            throw ModelUpdateError.invalid("The preparation no longer matches the downloaded revision and reviewed settings.")
        }
    }

    var enqueueRequest: LabValue {
        var fields: [String: LabValue] = [
            "operation": .string("enqueue"), "kind": .string(recipe.kind == .gguf ? "gguf" : "repo"),
            "preview_hash": .string(previewHash), "q_bits": .integer(recipe.qBits),
            "out": .string(outputPath), "label": .string(repo + " update"),
            "fetch_receipt": .string(fetchReceipt), "require_completion": .boolean(true),
            "require_projector": .boolean(requireProjector),
            "dependency_fetch_receipts": .array(dependencyFetchReceipts.map(LabValue.string)),
        ]
        if recipe.kind == .gguf { fields["path"] = .string(sourcePath) }
        else {
            fields["repo"] = .string(repo); fields["source_path"] = .string(sourcePath)
            if let backend = recipe.backend { fields["backend"] = .string(backend) }
            if let modelType = recipe.modelType { fields["model_type"] = .string(modelType) }
            if let subfolder { fields["subfolder"] = .string(subfolder) }
        }
        if let downloadsDirectory { fields["downloads_dir"] = .string(downloadsDirectory) }
        if let projectorPath { fields["projector"] = .string(projectorPath) }
        return .object(fields)
    }
}

/// Additional source details are emitted by the engine; the legacy source label remains separate.
struct ModelConversionSourceDetails: Codable, Equatable, Sendable {
    struct Origin: Codable, Equatable, Sendable {
        let repo: String
        let revision: String
        let file: String?
        let subfolder: String?
        var additionalFiles: [String]?
        enum CodingKeys: String, CodingKey { case repo, revision, file, subfolder; case additionalFiles = "additional_files" }
    }
    struct Projector: Codable, Equatable, Sendable {
        let path: String
        let signature: String?
    }
    let kind: String?
    let repo: String?
    let path: String?
    let signature: String?
    let fingerprint: String?
    let origin: Origin?
    let projector: Projector?
    let fetchReceipt: String?
    var recipe: LabValue? = nil
    var dependencies: [LabValue]? = nil
    enum CodingKeys: String, CodingKey {
        case kind, repo, path, signature, fingerprint, origin, projector, recipe, dependencies
        case fetchReceipt = "fetch_receipt"
    }
}

enum ModelUpdatePreparedResult {
    case installed(ModelUpdateInstallation)
    case review(ModelUpdatePreparationReview)
}

/// GGUF split names declare a finite ordered set. Always start with shard one.
enum ModelUpdateGGUFSelection {
    struct Bundle {
        let projector: String?
        let additionalFiles: [String]
        let requiresProjector: Bool
        let requiresCompanionSelection: Bool
        let problem: String?
    }
    static func bundle(previous: ModelUpdatePreviousModel, settings: ModelUpdateSettings,
                       main: String?, available: [String]) -> Bundle {
        let oldProjector = previous.projectorFile ?? previous.convertedOrigin?.projectorFile
        let projector = settings.projectorFile.map { $0.isEmpty ? nil : $0 } ??
            oldProjector.flatMap { available.contains($0) ? $0 : nil }
        let selectedShards = shards(main: main, available: available)
        let companions = (previous.additionalFiles ?? []).filter { $0 != oldProjector && !isShard($0) }
        let selected = settings.additionalFiles ?? companions.filter { available.contains($0) }
        return Bundle(projector: projector,
            additionalFiles: Array(Set(selected + [projector].compactMap { $0 } + selectedShards.files)).filter { $0 != main }.sorted(),
            requiresProjector: previous.requiresProjector == true || previous.convertedOrigin?.requiresProjector == true || oldProjector != nil,
            requiresCompanionSelection: settings.additionalFiles == nil && companions.contains { !available.contains($0) },
            problem: selectedShards.problem)
    }

    static func shards(main: String?, available: [String]) -> (files: [String], problem: String?) {
        guard let main else { return ([], nil) }
        let pattern = "^(.*)-([0-9]{5})-of-([0-9]{5})(\\.gguf)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: main, range: NSRange(main.startIndex..., in: main)),
              let prefix = Range(match.range(at: 1), in: main), let first = Range(match.range(at: 2), in: main),
              let total = Range(match.range(at: 3), in: main), let suffix = Range(match.range(at: 4), in: main),
              let count = Int(main[total]) else { return ([], nil) }
        guard main[first] == "00001", (1...1000).contains(count) else {
            return ([], "Choose the first shard of a supported GGUF bundle.")
        }
        let files = (1...count).map { String(main[prefix]) + String(format: "-%05d-of-%05d", $0, count) + main[suffix] }
        guard Set(files).isSubset(of: Set(available)) else { return ([], "This revision is missing a declared GGUF shard. Choose a complete bundle.") }
        return (Array(files.dropFirst()), nil)
    }
    static func isShard(_ file: String) -> Bool {
        file.range(of: "-[0-9]{5}-of-[0-9]{5}\\.gguf$", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

struct ModelUpdateBackendInstallation: Codable, Equatable {
    let id: String
    let version: String
    let package: String
    let target: String
    let network: [String]
}

/// Failed preparation may be revised after recoverable cleanup; live or
/// successfully completed work must be reattached instead of abandoned.
enum ModelUpdatePreparationState {
    static func observedJob(jobs: [Job], previewHash: String, output: String, excludingReceipts: Set<String> = []) throws -> Job? {
        let matching = jobs.filter { $0.previewHash == previewHash && $0.out == output && !excludingReceipts.contains($0.receipt ?? "") }
        guard matching.allSatisfy({ ["done", "running", "queued", "starting", "failed"].contains($0.state) }) else {
            throw ModelUpdateError.invalid("Preparation process ownership is unknown. Its files remain protected.")
        }
        let observed = matching.filter { $0.state != "failed" }
        guard observed.count <= 1 else { throw ModelUpdateError.invalid("Several conversion receipts claim this preparation. Review Jobs before continuing.") }
        return observed.first
    }

    static func canRevise(output: String, jobs: [Job], queue: [WebQueueItem], outputExists: Bool) -> Bool {
        !outputExists && !queue.contains(where: { $0.out == output }) &&
        jobs.filter { $0.out == output }.allSatisfy { $0.state == "failed" && $0.processesQuiescent == true }
    }
}
