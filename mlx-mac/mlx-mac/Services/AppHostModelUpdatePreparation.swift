import Foundation

extension AppHost {
    func downloadCompleteModelUpdate(_ review: ModelUpdateReview) async throws -> ModelUpdateInstallation {
        try review.validateForDownload()
        let selection = review.resolution.source
        guard ManagedModelInstallStore.directory(root: config.outputDir, source: selection) == review.sourceDirectory else {
            throw ModelUpdateError.invalid("The managed source location changed. Review the update again.")
        }
        let fetched = try await fetchModelUpdateComponent(resolution: review.resolution, directory: review.sourceDirectory,
            extras: review.additionalFiles ?? [], previewHash: review.previewHash)
        try Self.validateUpdateFetch(fetched, resolution: review.resolution, directory: review.sourceDirectory,
            extras: review.additionalFiles ?? [], previewHash: review.previewHash)
        var identities = [try await updateSourceIdentity(review.downloadedModelPath)]
        if review.sourceDirectory != review.downloadedModelPath { identities.append(try await updateSourceIdentity(review.sourceDirectory)) }
        for file in review.additionalFiles ?? [] {
            identities.append(try await updateSourceIdentity(URL(fileURLWithPath: review.sourceDirectory).appendingPathComponent(file).path))
        }
        var dependencyReceipts: [String] = []
        for component in review.dependencies ?? [] {
            let completed = try await fetchModelUpdateComponent(resolution: component.resolution, directory: component.directory,
                extras: component.additionalFiles, previewHash: component.previewHash)
            try Self.validateUpdateFetch(completed, resolution: component.resolution, directory: component.directory,
                extras: component.additionalFiles, previewHash: component.previewHash)
            identities.append(try await updateSourceIdentity(component.modelPath))
            dependencyReceipts.append(completed.receipt)
        }
        let source = ModelUpdateInstallation(repo: review.repo, revision: review.targetRevision,
            path: review.downloadedModelPath, signature: identities[0].signature,
            fetchReceipt: fetched.receipt, dependencyFetchReceipts: dependencyReceipts, sourceFiles: identities)
        try await managedModels.record(ManagedModelInstall(repo: review.repo, revision: review.targetRevision,
            path: source.path, signature: source.signature, installedAt: Date(), file: selection.file,
            subfolder: selection.subfolder, additionalFiles: review.additionalFiles, projectorFile: review.projectorFile, requiresProjector: review.requiresProjector))
        await rescan()
        return source
    }

    private func fetchModelUpdateComponent(resolution: IntakeResolution, directory: String,
                                            extras: [String], previewHash: String) async throws -> FetchJob {
        // A directory is never overwritten. Only its exact immutable receipt can be reattached.
        if FileManager.default.fileExists(atPath: directory) {
            let deadline = Date().addingTimeInterval(86_400)
            repeat {
                try Task.checkCancellation()
                let matches = try await api.intakeStatus().filter {
                    $0.repo == resolution.source.repo && $0.revision == resolution.source.fetchRevision &&
                    $0.file == resolution.source.file && $0.subfolder == resolution.source.subfolder &&
                    $0.localDir == directory && ($0.additionalFiles ?? []).sorted() == extras.sorted() &&
                    $0.previewHash == previewHash
                }
                let live = matches.filter { ["done", "running"].contains($0.state) }
                guard live.count <= 1 else { throw ModelUpdateError.invalid("Several live receipts claim this source directory.") }
                guard let job = live.first ?? matches.max(by: { ($0.startedAt ?? "") < ($1.startedAt ?? "") }) else {
                    throw ModelUpdateError.invalid("Existing source files have no matching download receipt. Review recovery before retrying.")
                }
                if job.state == "done" {
                    try Self.validateUpdateFetch(job, resolution: resolution, directory: directory, extras: extras, previewHash: previewHash)
                    return job
                }
                guard job.state == "running" else {
                    throw ModelUpdateError.invalid("A source download failed. Review its incomplete files for Quarantine before retrying.")
                }
                try await Task.sleep(for: .seconds(1))
            } while Date() < deadline
            throw ModelUpdateError.invalid("The source download is still running. Continue this saved update after checking status.")
        }
        _ = try await intake.download(resolution: resolution, localDir: directory, previewHash: previewHash, additionalFiles: extras)
        guard let job = intake.completedFetch else { throw ModelUpdateError.unavailable }
        try Self.validateUpdateFetch(job, resolution: resolution, directory: directory, extras: extras, previewHash: previewHash)
        return job
    }

    private static func validateUpdateFetch(_ job: FetchJob, resolution: IntakeResolution, directory: String,
                                            extras: [String], previewHash: String) throws {
        let expected = directory
        guard job.state == "done", job.repo == resolution.source.repo, job.revision == resolution.source.fetchRevision,
              job.file == resolution.source.file, job.subfolder == resolution.source.subfolder,
              job.localDir == directory, job.path == expected, (job.additionalFiles ?? []).sorted() == extras.sorted(),
              job.previewHash == previewHash else {
            throw ModelUpdateError.invalid("The completed download does not match the reviewed source, files and destination.")
        }
    }

    private func updateSourceIdentity(_ path: String) async throws -> ModelUpdateLocalSource {
        let signature = try await WorkbenchIO.perform { Result { try ManagedModelInstallStore.signature(path: path) } }.get()
        return .init(path: path, signature: signature)
    }

    func validateUpdateSources(_ source: ModelUpdateInstallation) async throws {
        for expected in source.sourceFiles ?? [.init(path: source.path, signature: source.signature)] {
            guard try await updateSourceIdentity(expected.path) == expected else {
                throw ModelUpdateError.invalid("Downloaded source files changed after review. The previous version remains in place.")
            }
        }
    }

    func previewModelUpdatePreparation(_ review: ModelUpdateReview, source: ModelUpdateInstallation) async throws -> ModelUpdatePreparationReview {
        try await api.requireModelUpdatePreparation()
        try source.validateDownload(for: review)
        try await validateUpdateSources(source)
        guard let recipe = review.conversion, let receipt = source.fetchReceipt else { throw ModelUpdateError.unavailable }
        let projector = review.projectorFile.map { URL(fileURLWithPath: review.sourceDirectory).appendingPathComponent($0).path }
        var prepared = ModelUpdatePreparationReview(id: UUID(), previewHash: "", recipe: recipe, repo: review.repo,
            sourcePath: source.path, outputPath: review.destinationPath, fetchReceipt: receipt,
            sourceFiles: source.sourceFiles ?? [.init(path: source.path, signature: source.signature)], projectorPath: projector,
            requireProjector: review.requiresProjector == true, dependencyFetchReceipts: source.dependencyFetchReceipts ?? [],
            subfolder: review.resolution.source.subfolder, downloadsDirectory: review.downloadsDirectory)
        if recipe.kind == .repository, let backend = recipe.backend {
            let registry = try await api.backendList()
            guard let entry = registry.backends.first(where: { $0.id == backend }) else {
                throw ModelUpdateError.invalid("The declared converter is unavailable in the selected engine.")
            }
            if entry.state != .installed {
                guard entry.state != .installing else { throw ModelUpdateError.invalid("The converter is still installing. Check its status before continuing this update.") }
                let plan = try await api.backendInstallPreview(id: backend)
                guard let hash = plan.string("preview_hash"), !hash.isEmpty,
                      let id = plan.string("id"), id == backend, let version = plan.string("version"), !version.isEmpty,
                      let package = plan.string("package"), !package.isEmpty, let target = plan.string("target"), target.hasPrefix("/"),
                      let network = plan["network"] as? [String] else { throw ModelUpdateError.unavailable }
                prepared = ModelUpdatePreparationReview(id: prepared.id, previewHash: hash, recipe: recipe, repo: prepared.repo,
                    sourcePath: prepared.sourcePath, outputPath: prepared.outputPath, fetchReceipt: receipt,
                    sourceFiles: prepared.sourceFiles, projectorPath: projector, requireProjector: prepared.requireProjector,
                    dependencyFetchReceipts: prepared.dependencyFetchReceipts, subfolder: prepared.subfolder,
                    operation: .installBackend, backendInstallID: backend, downloadsDirectory: prepared.downloadsDirectory,
                    backendInstallation: .init(id: id, version: version, package: package, target: target, network: network))
                return prepared
            }
        }
        let plan = try await api.modelUpdateConversionPreview(prepared, subfolder: prepared.subfolder)
        guard let hash = plan.string("preview_hash"), !hash.isEmpty else { throw ModelUpdateError.unavailable }
        try Self.validateUpdateConversionSource(plan: plan, review: review, source: source, recipe: recipe)
        prepared = ModelUpdatePreparationReview(id: prepared.id, previewHash: hash, recipe: recipe, repo: prepared.repo,
            sourcePath: prepared.sourcePath, outputPath: prepared.outputPath, fetchReceipt: receipt,
            sourceFiles: prepared.sourceFiles, projectorPath: projector, requireProjector: prepared.requireProjector,
            dependencyFetchReceipts: prepared.dependencyFetchReceipts, subfolder: prepared.subfolder, downloadsDirectory: prepared.downloadsDirectory)
        try prepared.validate(for: review)
        return prepared
    }

    func prepareModelUpdateInstallation(_ review: ModelUpdateReview, source: ModelUpdateInstallation,
                                       prepared: ModelUpdatePreparationReview) async throws -> ModelUpdatePreparedResult {
        try prepared.validate(for: review)
        guard prepared.fetchReceipt == source.fetchReceipt,
              prepared.sourceFiles == source.sourceFiles,
              prepared.dependencyFetchReceipts == (source.dependencyFetchReceipts ?? []) else {
            throw ModelUpdateError.invalid("Preparation no longer matches its saved downloaded-source evidence.")
        }
        try await validateUpdateSources(source)
        if prepared.operation == .installBackend {
            guard let backend = prepared.backendInstallID else { throw ModelUpdateError.unavailable }
            _ = try await api.backendInstallStart(id: backend, previewHash: prepared.previewHash)
            let deadline = Date().addingTimeInterval(1_800)
            repeat {
                try Task.checkCancellation()
                let entry = try await api.backendList().backends.first { $0.id == backend }
                if entry?.state == .installed {
                    return .review(try await previewModelUpdatePreparation(review, source: source))
                }
                if entry?.state == .failed { throw ModelUpdateError.invalid("The converter installation failed. The previous model was kept.") }
                try await Task.sleep(for: .seconds(1))
            } while Date() < deadline
            throw ModelUpdateError.invalid("Converter installation has not completed. Check its status before resuming this update.")
        }
        let queued: WebQueueItem?
        var previousReceipts = Set<String>()
        if prepared.operation == .observeConversion {
            let snapshot = try await api.conversionQueue(.object(["operation": .string("snapshot")])).snapshot()
            let matching = snapshot.items.filter { $0.previewHash == prepared.previewHash && $0.out == prepared.outputPath }
            guard matching.count <= 1 else { throw ModelUpdateError.invalid("Several queued jobs claim this preparation.") }
            queued = matching.first
        } else {
            let fresh = try await api.modelUpdateConversionPreview(prepared, subfolder: prepared.subfolder)
            guard fresh.string("preview_hash") == prepared.previewHash else {
                throw ModelUpdateError.invalid("The local preparation plan changed. Review it again before converting.")
            }
            try Self.validateUpdateConversionSource(plan: fresh, review: review, source: source, recipe: prepared.recipe)
            let existing = try await api.conversionQueue(.object(["operation": .string("snapshot")])).snapshot()
            guard !existing.items.contains(where: { $0.out == prepared.outputPath }) else {
                throw ModelUpdateError.invalid("This destination already has a queued preparation. Continue its saved update instead.")
            }
            previousReceipts = Set(try await api.convertStatus().filter {
                $0.previewHash == prepared.previewHash && $0.out == prepared.outputPath
            }.compactMap(\.receipt))
            let queue = try await api.conversionQueue(prepared.enqueueRequest).snapshot()
            let matching = queue.items.filter { $0.previewHash == prepared.previewHash && $0.out == prepared.outputPath }
            guard matching.count == 1, let item = matching.first else {
                throw ModelUpdateError.invalid("Preparation did not enter the durable queue exactly once. Review Jobs before continuing.")
            }
            queued = item
        }
        let deadline = Date().addingTimeInterval(86_400)
        repeat {
            try Task.checkCancellation()
            if let queued {
                let snapshot = try await api.conversionQueue(.object(["operation": .string("snapshot")])).snapshot()
                if let current = snapshot.items.first(where: { $0.id == queued.id }) {
                    guard current.state != .failed else { throw ModelUpdateError.invalid("The queued preparation failed. Review Jobs before retrying.") }
                    _ = try await api.conversionQueue(.object(["operation": .string("run")]))
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
            }
            let jobs = try await api.convertStatus()
            if let job = try ModelUpdatePreparationState.observedJob(jobs: jobs, previewHash: prepared.previewHash,
                output: prepared.outputPath, excludingReceipts: previousReceipts) {
                if job.state == "done" {
                    guard job.completionObserved == true, job.exitCode == 0, let receipt = job.receipt,
                          job.qBits == prepared.recipe.qBits,
                          prepared.recipe.kind == .gguf || job.backend == prepared.recipe.backend && job.modelType == prepared.recipe.modelType, let details = job.sourceDetails else {
                        throw ModelUpdateError.invalid("The converter did not record successful completion for this exact preparation.")
                    }
                    try Self.validateUpdateConversionDetails(details, review: review, source: source)
                    try await validateUpdateSources(source)
                    let output = try await updateSourceIdentity(review.destinationPath)
                    let installation = ModelUpdateInstallation(repo: review.repo, revision: review.targetRevision,
                        path: output.path, signature: output.signature, fetchReceipt: source.fetchReceipt,
                        dependencyFetchReceipts: source.dependencyFetchReceipts, sourceFiles: source.sourceFiles,
                        conversionReceipt: receipt, conversionPreviewHash: prepared.previewHash)
                    let origin = ModelUpdateConvertedOrigin(recipe: prepared.recipe, sourcePath: source.path,
                        sourceSignature: source.signature, conversionReceipt: receipt, fetchReceipt: source.fetchReceipt,
                        projectorFile: review.projectorFile, requiresProjector: review.requiresProjector)
                    try await managedModels.record(ManagedModelInstall(repo: review.repo, revision: review.targetRevision,
                        path: output.path, signature: output.signature, installedAt: Date(), file: review.resolution.source.file,
                        subfolder: review.resolution.source.subfolder, preparation: origin))
                    await rescan()
                    return .installed(installation)
                }
                guard ["running", "queued", "starting"].contains(job.state) else {
                    throw ModelUpdateError.invalid("Preparation failed or has no observed successful completion. The previous model and endpoints were kept.")
                }
            } else {
                throw ModelUpdateError.invalid("Preparation failed or has no matching launch receipt. Review its saved progress and failed files before retrying.")
            }
            try await Task.sleep(for: .seconds(1))
        } while Date() < deadline
        throw ModelUpdateError.invalid("Preparation has not finished. Its queue and receipt remain in Jobs; resume the saved update after checking status.")
    }

    static func validateUpdateConversionSource(plan: [String: Any], review: ModelUpdateReview,
                                               source: ModelUpdateInstallation, recipe: ModelUpdateConversionRecipe) throws {
        guard plan.string("out") == review.destinationPath, plan.int("q_bits") == recipe.qBits,
              let raw = plan["source"] as? [String: Any] else {
            throw ModelUpdateError.invalid("The converter returned a different destination or quantization.")
        }
        let details = try WorkbenchAPI.decode(ModelConversionSourceDetails.self, from: raw)
        try validateUpdateConversionDetails(details, review: review, source: source)
    }

    static func validateUpdateConversionDetails(_ details: ModelConversionSourceDetails,
                                               review: ModelUpdateReview, source: ModelUpdateInstallation) throws {
        guard let origin = details.origin, origin.repo.caseInsensitiveCompare(review.repo) == .orderedSame,
              origin.revision.lowercased() == review.targetRevision.lowercased(),
              origin.file == review.resolution.source.file, origin.subfolder == review.resolution.source.subfolder,
              (origin.additionalFiles ?? []).sorted() == (review.additionalFiles ?? []).sorted(),
              details.path == review.downloadedModelPath, details.fetchReceipt == source.fetchReceipt else {
            throw ModelUpdateError.invalid("Preparation source evidence differs from the reviewed repository, revision or files.")
        }
        if let projector = review.projectorFile {
            guard details.projector?.path == URL(fileURLWithPath: review.sourceDirectory).appendingPathComponent(projector).path,
                  details.projector?.signature?.isEmpty == false else {
                throw ModelUpdateError.invalid("The converter did not bind the selected vision projector to its preparation.")
            }
        } else if review.requiresProjector == true { throw ModelUpdateError.invalid("The update must preserve its vision projector.") }
        let receipts = (details.dependencies ?? []).compactMap { value -> String? in
            guard case .object(let fields) = value, let value = fields["fetch_receipt"], case .string(let path) = value else { return nil }
            return path
        }
        guard receipts.sorted() == (source.dependencyFetchReceipts ?? []).sorted() else {
            throw ModelUpdateError.invalid("The converter's recipe dependencies differ from the downloaded pinned components.")
        }
    }
}


extension AppHost {
    /// Only unlaunched preparation settings can change; downloaded inputs stay immutable.
    func reviseModelUpdatePreparation(_ record: ModelUpdateRecord, bits: Int) async throws -> ModelUpdateRecord {
        guard let source = record.downloadedSource, let original = record.review.conversion,
              record.installation == nil, record.endpointsSwitched != true else { throw ModelUpdateError.unavailable }
        try await revalidateModelUpdate(record.review, mutation: .prepare)
        try await validateUpdateSources(source)
        let jobs = try await api.convertStatus()
        let queue = try await api.conversionQueue(.object(["operation": .string("snapshot")])).snapshot()
        guard ModelUpdatePreparationState.canRevise(output: record.review.destinationPath, jobs: jobs, queue: queue.items,
            outputExists: FileManager.default.fileExists(atPath: record.review.destinationPath)) else {
            throw ModelUpdateError.invalid("Preparation already has a job or output. Continue its saved progress or review failed-file recovery first.")
        }
        let recipe = ModelUpdateConversionRecipe(kind: original.kind, qBits: bits, backend: original.backend, modelType: original.modelType)
        try recipe.validate()
        guard let output = ManagedModelInstallStore.preparedDirectory(root: config.outputDir, source: record.review.resolution.source, recipe: recipe),
              !FileManager.default.fileExists(atPath: output) else { throw ModelUpdateError.invalid("The revised preparation destination already exists.") }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record.review)) as? [String: Any] ?? [:]
        object["conversion"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe))
        object["destinationPath"] = output
        let review = try JSONDecoder().decode(ModelUpdateReview.self, from: JSONSerialization.data(withJSONObject: object))
        try review.validateForDownload()
        let preparation = try await previewModelUpdatePreparation(review, source: source)
        return ModelUpdateRecord(id: record.id, alertID: record.alertID, review: review, quarantinePrevious: record.quarantinePrevious,
            createdAt: record.createdAt, updatedAt: Date(), stage: .awaitingPreparation, state: .inProgress,
            installation: nil, error: nil, downloadedSource: source, preparation: preparation)
    }
}
