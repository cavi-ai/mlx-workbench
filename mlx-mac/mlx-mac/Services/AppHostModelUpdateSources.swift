import Foundation

extension AppHost {
    func prepareCompleteModelUpdate(repo: String, previous: ModelUpdatePreviousModel,
                                    settings: ModelUpdateSettings) async throws -> ModelUpdateReview {
        guard try await updateCandidates(repo: repo).contains(previous), !intake.isBusy,
              previous.signature?.isEmpty == false else {
            throw ModelUpdateError.invalid("The selected files changed or are unavailable. Refresh the library before reviewing this update.")
        }
        let requested = try ManagedModelInstallStore.sourceReference(repo: repo, file: nil, subfolder: previous.subfolder)
        var resolution = try await api.intakeResolve(source: requested)
        guard ModelUpdateReview.isCommit(resolution.source.fetchRevision) else {
            throw ModelUpdateError.invalid("The engine did not resolve an immutable revision. Update the engine and review again.")
        }
        if resolution.verdict == .gguf {
            let selected = settings.ggufFile ?? previous.file.flatMap { old in resolution.files.gguf.contains(where: { $0.name == old }) ? old : nil }
            resolution = try Self.updateResolution(resolution, selecting: selected?.isEmpty == true ? nil : selected)
        }
        let conversion: ModelUpdateConversionRecipe?
        if [.convertible, .convertibleAfterInstall].contains(resolution.verdict) {
            let bits = settings.qBits ?? previous.convertedOrigin?.recipe.qBits ?? config.qBits
            conversion = .init(kind: .repository, qBits: bits, backend: resolution.backend, modelType: resolution.modelType)
        } else if resolution.verdict == .gguf && previous.isConverted == true {
            let bits = settings.qBits ?? previous.convertedOrigin?.recipe.qBits ?? config.qBits
            conversion = .init(kind: .gguf, qBits: bits, backend: nil, modelType: nil)
        } else {
            guard resolution.verdict == .alreadyMLX || resolution.verdict == .gguf else {
                throw ModelUpdateError.invalid(resolution.reasons.first ?? "The new revision does not declare a supported local runtime.")
            }
            conversion = nil
        }
        let slots = endpoint.fleet.slots.filter { $0.modelPath == previous.path }
        let bundleSelection = ModelUpdateGGUFSelection.bundle(previous: previous, settings: settings,
            main: resolution.source.file, available: resolution.files.gguf.map(\.name))
        let projector = bundleSelection.projector, additional = bundleSelection.additionalFiles
        let needsProjector = resolution.verdict == .gguf && bundleSelection.requiresProjector
        try await api.requireModelUpdatePreparation()
        guard let proposedDirectory = ManagedModelInstallStore.directory(root: config.outputDir, source: resolution.source) else {
            throw ModelUpdateError.invalid("The managed source directory is unavailable.")
        }
        let plan = try await api.intakeFetchPreview(.init(source: resolution.source.reference, revision: resolution.source.fetchRevision,
            file: resolution.source.file, localDir: proposedDirectory, modelType: resolution.modelType, additionalFiles: resolution.source.file == nil ? [] : additional))
        guard let admissionHash = plan.string("preview_hash"), !admissionHash.isEmpty else { throw ModelUpdateError.unavailable }
        let storage = plan["storage"] as? [String: Any]
        let reusing = storage?["mode"] as? String == "reuse"
        let directory = plan.string("local_dir") ?? proposedDirectory
        let originalHash = storage?["fetch_preview_hash"] as? String
        let originalReceipt = storage?["receipt"] as? String
        guard directory == proposedDirectory || reusing,
              !reusing || originalHash?.isEmpty == false && originalReceipt?.hasPrefix("/") == true else {
            throw ModelUpdateError.invalid("The engine did not bind the existing source to its original receipt.")
        }
        let downloadedPath = (resolution.source.file ?? resolution.source.subfolder).map {
            URL(fileURLWithPath: directory).appendingPathComponent($0).path
        } ?? directory
        let output: String
        if let conversion {
            guard let prepared = ManagedModelInstallStore.preparedDirectory(root: config.outputDir, source: resolution.source, recipe: conversion) else {
                throw ModelUpdateError.invalid("The managed preparation directory is unavailable.")
            }
            output = prepared
        } else { output = downloadedPath }
        try await WorkbenchIO.perform { Result {
            try ManagedModelInstallStore.refuseLinks(in: directory)
            try ManagedModelInstallStore.refuseLinks(in: output)
        } }.get()
        guard (reusing || !FileManager.default.fileExists(atPath: directory)),
              (!FileManager.default.fileExists(atPath: output) || reusing && conversion == nil) else {
            throw ModelUpdateError.invalid("This revision already has files. Continue its saved update, or review those files in Library before starting another download.")
        }
        let reviewID = UUID()
        let hash = reusing ? originalHash! : admissionHash
        var requestedDependencies: [(repo: String, revision: String?, files: [String])] = []
        if let recipe = resolution.recipe { requestedDependencies.append((recipe.base, recipe.baseRevision, [])) }
        if let required = plan["required_dependencies"] {
            guard let rows = required as? [[String: Any]] else { throw ModelUpdateError.invalid("The engine returned unreadable required components.") }
            for row in rows {
                guard let repo = row["repo"] as? String, let files = row["files"] as? [String],
                      row["revision"] == nil || row["revision"] is NSNull || row["revision"] is String else {
                    throw ModelUpdateError.invalid("A required component has no valid repository or file selection.")
                }
                requestedDependencies.append((repo, row["revision"] as? String, files))
            }
        }
        var dependencies: [ModelUpdateDependency] = []
        let existingFetches = requestedDependencies.isEmpty ? [] : try await api.intakeStatus()
        for requested in requestedDependencies {
            _ = try ManagedModelInstallStore.sourceReference(repo: requested.repo, file: nil, subfolder: nil)
            let files = requested.files.sorted()
            guard Set(files).count == files.count, files.allSatisfy(Self.validUpdateDependencyFile) else {
                throw ModelUpdateError.invalid("A required component contains an unsafe file path.")
            }
            var component = try await api.intakeResolve(source: requested.repo, revision: requested.revision)
            guard ModelUpdateReview.isCommit(component.source.fetchRevision), component.source.repo == requested.repo else {
                throw ModelUpdateError.invalid("A required component did not resolve to an immutable revision.")
            }
            if let first = files.first { component = try Self.updateResolution(component, selecting: first, requireGGUF: false) }
            if dependencies.contains(where: { $0.resolution.source == component.source && $0.additionalFiles == Array(files.dropFirst()) }) { continue }
            let extras = Array(files.dropFirst())
            if let existing = try Self.reusableUpdateDependency(component, extras: extras, root: config.outputDir, fetches: existingFetches) {
                dependencies.append(existing)
                continue
            }
            guard let location = ManagedModelInstallStore.dependencyDirectory(root: config.outputDir, source: component.source, additionalFiles: extras) else {
                throw ModelUpdateError.invalid("The required component has no valid immutable storage identity.")
            }
            try ManagedModelInstallStore.refuseLinks(in: location)
            let plan = try await api.intakeFetchPreview(.init(source: component.source.reference, revision: component.source.fetchRevision,
                file: component.source.file, localDir: location, modelType: component.modelType, additionalFiles: Array(files.dropFirst())))
            guard let hash = plan.string("preview_hash"), !hash.isEmpty,
                  (plan["required_dependencies"] as? [Any] ?? []).isEmpty else {
                throw ModelUpdateError.invalid("A required component needs additional unresolved dependencies.")
            }
            let selectedLocation = plan.string("local_dir") ?? location
            let reuse = plan["storage"] as? [String: Any]
            guard selectedLocation == location || reuse?["mode"] as? String == "reuse" else { throw ModelUpdateError.unavailable }
            try ManagedModelInstallStore.refuseLinks(in: selectedLocation)
            dependencies.append(.init(resolution: component, directory: selectedLocation, modelPath: selectedLocation,
                previewHash: reuse?["fetch_preview_hash"] as? String ?? hash, additionalFiles: extras, shared: true,
                fetchReceipt: reuse?["receipt"] as? String, admissionPreviewHash: reuse?["mode"] as? String == "reuse" ? hash : nil))
        }
        let downloads = plan["downloads"] as? [[String: Any]] ?? []
        let downloadsDirectory = plan["downloads_dir"] as? String
        guard downloads.isEmpty || downloadsDirectory == URL(fileURLWithPath: directory).appendingPathComponent("support").path else {
            throw ModelUpdateError.invalid("Required assets must download inside this managed revision.")
        }
        var review = ModelUpdateReview(id: reviewID, repo: repo, previous: previous, resolution: resolution,
            targetRevision: resolution.source.fetchRevision, destinationPath: output, previewHash: hash,
            endpointSummary: slots.map { "Port \($0.port) · \($0.enabled ? "enabled" : "disabled")" + ($0.servingProfile == nil ? "" : " · fresh Strata profile verification") },
            conversion: conversion, downloadDirectory: directory, additionalFiles: additional,
            projectorFile: projector, requiresProjector: needsProjector,
            dependencies: dependencies, sourceConfirmed: settings.sourceConfirmed, reviewedEndpoints: slots, fileSelectionConfirmed: settings.ggufFile?.isEmpty == false)
        let ledger = try await managedModels.records().first { $0.path == previous.path }
        let bundle = Self.modelUpdateBundle(ledger, root: config.outputDir)
        var cleanup: QuarantineFileSnapshot?
        if previous.canQuarantine {
            let path = previous.path, roots = [config.outputDir]
            cleanup = try await WorkbenchIO.perform { Result { try Quarantine.modelUpdateSnapshot(target: path, roots: roots, protected: [],
                managedBundle: bundle?.directory, bundleFiles: bundle?.files ?? []) } }.get()
        }
        review.requiredCompanionSelection = bundleSelection.requiresCompanionSelection; review.selectionProblem = bundleSelection.problem
        review.cleanupPath = cleanup?.path; review.cleanupSnapshot = cleanup; review.previousInstall = ledger
        review.cleanupBundle = bundle?.directory; review.cleanupFiles = bundle?.files
        review.downloadsDirectory = downloadsDirectory
        review.downloadFetchReceipt = reusing ? originalReceipt : nil
        review.downloadAdmissionPreviewHash = reusing ? admissionHash : nil
        try review.validate()
        modelUpdateCaptures.insert(review.id, endpoints: slots, cleanup: cleanup, sourceInstall: ledger,
            managedBundle: bundle?.directory, bundleFiles: bundle?.files ?? [])
        return review
    }

    nonisolated static func reusableUpdateDependency(_ resolution: IntakeResolution, extras: [String], root: String,
                                                     fetches: [FetchJob]) throws -> ModelUpdateDependency? {
        let matches = fetches.filter {
            $0.state == "done" && $0.repo == resolution.source.repo && $0.revision == resolution.source.fetchRevision &&
            $0.file == resolution.source.file && $0.subfolder == resolution.source.subfolder &&
            ($0.additionalFiles ?? []).sorted() == extras.sorted() && $0.previewHash?.isEmpty == false &&
            $0.localDir == $0.path && $0.path?.hasPrefix(URL(fileURLWithPath: root).standardizedFileURL.path + "/") == true
        }
        guard matches.count <= 1 else { throw ModelUpdateError.invalid("Several completed sources claim this required component. Review their storage before continuing.") }
        guard let job = matches.first, let path = job.path, let hash = job.previewHash else { return nil }
        try ManagedModelInstallStore.refuseLinks(in: path)
        return .init(resolution: resolution, directory: path, modelPath: path, previewHash: hash,
                     additionalFiles: extras.sorted(), shared: true, fetchReceipt: job.receipt)
    }

    func validateUpdateDownloadLocation(_ review: ModelUpdateReview) async throws {
        if review.downloadFetchReceipt == nil,
           ManagedModelInstallStore.directory(root: config.outputDir, source: review.resolution.source) == review.sourceDirectory { return }
        guard review.downloadAdmissionPreviewHash != nil, let receipt = review.downloadFetchReceipt else {
            throw ModelUpdateError.invalid("The managed source location changed. Review the update again.")
        }
        let plan = try await api.intakeFetchPreview(.init(source: review.resolution.source.reference,
            revision: review.targetRevision, file: review.resolution.source.file, localDir: review.sourceDirectory,
            modelType: review.resolution.modelType, additionalFiles: review.additionalFiles ?? []))
        let storage = plan["storage"] as? [String: Any]
        guard storage?["mode"] as? String == "reuse", storage?["receipt"] as? String == receipt,
              storage?["fetch_preview_hash"] as? String == review.previewHash,
              plan.string("local_dir") == review.sourceDirectory else {
            throw ModelUpdateError.invalid("The reused source changed. Review its original receipt before continuing.")
        }
    }

    static func validUpdateDependencyFile(_ file: String) -> Bool {
        !file.isEmpty && file.count <= 4096 && !file.hasPrefix("/") && !file.contains("\\") &&
        file.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }

    static func updateResolution(_ resolution: IntakeResolution, selecting file: String?, requireGGUF: Bool = true) throws -> IntakeResolution {
        guard let file else { return resolution }
        guard Self.validUpdateDependencyFile(file) else { throw ModelUpdateError.invalid("The selected source file has an unsafe path.") }
        guard !requireGGUF || resolution.files.gguf.contains(where: { $0.name == file }) else {
            throw ModelUpdateError.invalid("The selected GGUF is not in the new revision. Choose its replacement file.")
        }
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(resolution)) as? [String: Any],
              var source = object["source"] as? [String: Any] else { throw ModelUpdateError.unavailable }
        source["file"] = file; source["subfolder"] = NSNull()
        object["source"] = source
        object["download_bytes"] = resolution.files.gguf.first(where: { $0.name == file })?.bytes
        return try JSONDecoder().decode(IntakeResolution.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

extension AppHost {
    func recoverModelUpdate(_ saved: ModelUpdateRecord) async throws -> ModelUpdateRecord {
        let review = saved.review
        try review.validateForDownload()
        try await validateUpdateDownloadLocation(review)
        let completedFetches = review.dependencies?.contains(where: { $0.shared == true }) == true ? try await api.intakeStatus() : []
        var verifiedShared = Set<String>()
        for component in review.dependencies ?? [] where component.shared == true {
            if component.directory == ManagedModelInstallStore.dependencyDirectory(root: config.outputDir,
                source: component.resolution.source, additionalFiles: component.additionalFiles) {
                verifiedShared.insert(component.directory)
            } else if (try? Self.reusableUpdateDependency(component.resolution, extras: component.additionalFiles,
                       root: config.outputDir, fetches: completedFetches)) == component {
                verifiedShared.insert(component.directory)
            } else if component.admissionPreviewHash != nil {
                let plan = try await api.intakeFetchPreview(.init(source: component.resolution.source.reference,
                    revision: component.resolution.source.fetchRevision, file: component.resolution.source.file,
                    localDir: component.directory, modelType: component.resolution.modelType, additionalFiles: component.additionalFiles))
                let storage = plan["storage"] as? [String: Any]
                if storage?["mode"] as? String == "reuse", storage?["receipt"] as? String == component.fetchReceipt,
                   storage?["fetch_preview_hash"] as? String == component.previewHash,
                   plan.string("local_dir") == component.directory { verifiedShared.insert(component.directory) }
            }
        }
        guard let expected = review.reviewedEndpoints,
              review.dependencies?.enumerated().allSatisfy({ index, component in
                  if component.shared == true {
                      return verifiedShared.contains(component.directory)
                  }
                  return component.directory == URL(fileURLWithPath: config.outputDir).appendingPathComponent("managed-dependencies")
                    .appendingPathComponent(review.id.uuidString.lowercased()).appendingPathComponent(String(index)).path
              }) ?? true else {
            throw ModelUpdateError.invalid("This saved update has no complete endpoint or managed-source capture. Review it again from Watch.")
        }
        if let recipe = review.conversion {
            guard ManagedModelInstallStore.preparedDirectory(root: config.outputDir, source: review.resolution.source, recipe: recipe) == review.destinationPath else {
                throw ModelUpdateError.invalid("The managed preparation root changed. Restore its configured location before continuing.")
            }
        }
        modelUpdateCaptures.insert(review.id, endpoints: expected, cleanup: review.cleanupSnapshot,
            sourceInstall: review.previousInstall, managedBundle: review.cleanupBundle, bundleFiles: review.cleanupFiles ?? [])
        var recovered = saved
        if let source = saved.downloadedSource { try await validateUpdateSources(source) }
        if let installed = saved.installation {
            try installed.validate(for: review)
            guard try await updateRecoverySignature(installed.path) == installed.signature else {
                throw ModelUpdateError.invalid("The prepared files changed after interruption. Review their recovery before retrying.")
            }
            // A crash between a fleet commit and the update-record write is resolved
            // through exact desired-state and receipt readback, never a repeated stop.
            if expected.isEmpty && saved.endpointsSwitched == true || Self.matchesSwitchedUpdate(expected: expected, current: endpoint.fleet.slots,
                                          installed: installed) {
                try await validateRecoveredEndpoints(expected: expected, installed: installed)
                recovered.endpointsSwitched = true
                recovered.switchedEndpoints = endpoint.fleet.slots.filter { slot in expected.contains { $0.id == slot.id } }
            } else {
                guard saved.endpointsSwitched != true,
                      expected.allSatisfy({ endpoint.fleet.slots.contains($0) }),
                      endpoint.fleet.slots.filter({ $0.modelPath == review.previous.path }) == expected else {
                    throw ModelUpdateError.invalid("Endpoint settings changed after interruption. The previous files were kept.")
                }
                recovered.endpointsSwitched = false
            }
        }
        if recovered.endpointsSwitched == true, saved.quarantinePrevious,
           !FileManager.default.fileExists(atPath: review.previous.path) {
            guard let snapshot = review.cleanupSnapshot else { throw ModelUpdateError.unavailable }
            let destination = config.quarantineDir
            let confirmed = try await WorkbenchIO.perform { Result {
                try Quarantine.confirmModelUpdateMove(expected: snapshot, quarantineDir: destination)
            } }.get()
            guard confirmed else { throw ModelUpdateError.invalid("The previous files are missing and no matching recoverable move was found.") }
            try await managedModels.forget(path: review.previous.path)
            recovered.cleanupCompleted = true
        }
        if recovered.cleanupCompleted != true {
            guard try await updateRecoverySignature(review.previous.path) == review.previous.signature,
                  try await managedModels.records().first(where: { $0.path == review.previous.path }) == review.previousInstall else {
                throw ModelUpdateError.invalid("The previous files or their source record changed after interruption.")
            }
        }
        if saved.installation == nil, let source = saved.downloadedSource, var preparation = saved.preparation,
           preparation.operation != .installBackend {
            let jobs = try await api.convertStatus().filter { $0.previewHash == preparation.previewHash && $0.out == preparation.outputPath }
            let queued = try await api.conversionQueue(.object(["operation": .string("snapshot")])).snapshot().items.filter {
                $0.previewHash == preparation.previewHash && $0.out == preparation.outputPath
            }
            let observed = try ModelUpdatePreparationState.observedJob(jobs: jobs, previewHash: preparation.previewHash, output: preparation.outputPath)
            guard queued.count <= 1 else { throw ModelUpdateError.invalid("Several jobs claim this saved preparation.") }
            if let job = observed {
                guard ["done", "running", "starting", "queued"].contains(job.state), let details = job.sourceDetails else {
                    throw ModelUpdateError.invalid("Preparation failed. Review its incomplete output for Quarantine before retrying.")
                }
                try Self.validateUpdateConversionDetails(details, review: review, source: source)
                preparation.operation = .observeConversion
                recovered.preparation = preparation
            } else if let item = queued.first {
                guard item.state != .failed else { throw ModelUpdateError.invalid("The queued preparation failed. Review recovery before retrying.") }
                preparation.operation = .observeConversion
                recovered.preparation = preparation
            } else if !jobs.isEmpty {
                throw ModelUpdateError.invalid("Preparation failed. Review its incomplete output for Quarantine before retrying.")
            }
        }
        return recovered
    }

    private func updateRecoverySignature(_ path: String) async throws -> String {
        try await WorkbenchIO.perform { Result { try ManagedModelInstallStore.signature(path: path) } }.get()
    }

    static func matchesSwitchedUpdate(expected: [EndpointSlot], current: [EndpointSlot], installed: ModelUpdateInstallation) -> Bool {
        guard !expected.isEmpty else { return false }
        let ids = Set(expected.map(\.id))
        let slots = current.filter { ids.contains($0.id) }
        guard slots.count == expected.count,
              !current.contains(where: { $0.modelPath == expected.first?.modelPath }) else { return false }
        return expected.allSatisfy { original in
            guard var actual = slots.first(where: { $0.id == original.id }) else { return false }
            var replacement = original
            replacement.modelPath = installed.path
            replacement.acceleration = nil; replacement.accelerationPreviewHash = nil; replacement.profilePreviewHash = nil
            if let profile = original.servingProfile {
                guard let fresh = installed.profileReplacements?[profile.id], fresh.id != profile.id,
                      fresh.modelPath == installed.path, fresh.options == profile.options,
                      fresh.hasPassedVerification, fresh.sourceRunID == nil, fresh.sourceLaneID == nil else { return false }
                replacement.servingProfile = fresh
            }
            actual.profilePreviewHash = nil
            return actual == replacement
        }
    }

    private func validateRecoveredEndpoints(expected: [EndpointSlot], installed: ModelUpdateInstallation) async throws {
        let servers = try await api.serveStatus()
        for old in expected where old.enabled {
            guard let slot = endpoint.fleet.slots.first(where: { $0.id == old.id }),
                  let server = servers.first(where: { $0.port == old.port && $0.state == "running" && $0.matchesUnadaptedModel(installed.path) }),
                  (server.jit == true) == slot.usesJIT,
                  !slot.usesJIT || server.memoryPolicy == slot.memoryPolicy,
                  slot.servingProfile == nil || ServingProfile.matchesReceipt(server, previewHash: slot.profilePreviewHash) else {
                throw ModelUpdateError.invalid("The switched endpoint could not be confirmed. Refresh Run before continuing cleanup.")
            }
        }
    }
}

extension AppHost {
    func previewModelUpdateRecovery(_ record: ModelUpdateRecord) async throws -> ModelUpdateRecoveryReview {
        await modelUpdates.waitForHistory()
        guard modelUpdates.persistenceError == nil else { throw ModelUpdateError.invalid("Saved update ownership is unavailable. Restore its history before moving shared files.") }
        let review = record.review
        try review.validateForDownload()
        guard record.endpointsSwitched != true, !reclaim.isApplying, !intake.isBusy,
              try await updateRecoverySignature(review.previous.path) == review.previous.signature,
              try await managedModels.records().first(where: { $0.path == review.previous.path }) == review.previousInstall,
              let endpoints = review.reviewedEndpoints,
              endpoints.allSatisfy({ endpoint.fleet.slots.contains($0) }),
              endpoint.fleet.slots.filter({ $0.modelPath == review.previous.path }) == endpoints else {
            throw ModelUpdateError.invalid("The previous model or endpoints changed. Refresh their status before reviewing recovery.")
        }
        let fetches = try await api.intakeStatus()
        var paths: [String] = [], receipts: [String] = [], resetDownload = false
        var components: [(IntakeResolution, String, [String], String)] = []
        if review.downloadFetchReceipt == nil {
            components.append((review.resolution, review.sourceDirectory, review.additionalFiles ?? [], review.previewHash))
        }
        let retainedComponents = modelUpdates.records.filter { $0.id != record.id }.flatMap {
            $0.downloadedSource?.sourceFiles?.map(\.path) ?? []
        }
        for component in review.dependencies ?? [] {
            let failedNewShared = component.shared == true && component.fetchReceipt == nil && record.downloadedSource == nil &&
                component.directory == ManagedModelInstallStore.dependencyDirectory(root: config.outputDir,
                    source: component.resolution.source, additionalFiles: component.additionalFiles) &&
                !retainedComponents.contains(where: { $0 == component.directory || $0.hasPrefix(component.directory + "/") || component.directory.hasPrefix($0 + "/") })
            if component.shared != true || failedNewShared {
                components.append((component.resolution, component.directory, component.additionalFiles, component.previewHash))
            }
        }
        for (resolution, directory, extras, hash) in components {
            let matches = fetches.filter {
                $0.repo == resolution.source.repo && $0.revision == resolution.source.fetchRevision &&
                $0.file == resolution.source.file && $0.subfolder == resolution.source.subfolder &&
                $0.localDir == directory && ($0.additionalFiles ?? []).sorted() == extras.sorted() && $0.previewHash == hash
            }
            guard !matches.contains(where: { $0.state == "running" }) else {
                throw ModelUpdateError.invalid("A source download is still running. Continue its saved update instead of moving its files.")
            }
            if matches.contains(where: { $0.state == "done" }) { continue }
            if let failed = matches.max(by: { ($0.startedAt ?? "") < ($1.startedAt ?? "") }), failed.state == "failed" {
                guard failed.processesQuiescent == true else {
                    throw ModelUpdateError.invalid("The source download has not been confirmed stopped. Refresh Jobs before moving its files.")
                }
                receipts.append(failed.receipt); resetDownload = true
                if FileManager.default.fileExists(atPath: directory) { paths.append(directory) }
            }
        }
        var queueItems: [String] = []
        if let preparation = record.preparation, preparation.operation != .installBackend {
            let jobs = try await api.convertStatus().filter { $0.out == preparation.outputPath && $0.previewHash == preparation.previewHash }
            guard !jobs.contains(where: { ["running", "starting", "queued"].contains($0.state) }) else {
                throw ModelUpdateError.invalid("Preparation is still running. Continue its saved update instead of moving its output.")
            }
            let queued = try await api.conversionQueue(.object(["operation": .string("snapshot")])).snapshot().items.filter { $0.out == preparation.outputPath }
            guard queued.allSatisfy({ $0.previewHash == preparation.previewHash && $0.state == .failed }) else {
                throw ModelUpdateError.invalid("The preparation queue changed or is still active.")
            }
            queueItems = queued.map(\.id)
            if !jobs.isEmpty, jobs.allSatisfy({ $0.state == "failed" }) {
                guard jobs.allSatisfy({ $0.processesQuiescent == true }) else {
                    throw ModelUpdateError.invalid("Preparation processes have not been confirmed stopped. Its output remains protected.")
                }
                receipts += jobs.compactMap(\.receipt)
                if FileManager.default.fileExists(atPath: preparation.outputPath) { paths.append(preparation.outputPath) }
            } else if FileManager.default.fileExists(atPath: preparation.outputPath) {
                throw ModelUpdateError.invalid("The preparation output has no matching terminal failure receipt. Inspect Jobs before recovery.")
            }
        }
        guard !receipts.isEmpty || !queueItems.isEmpty else {
            throw ModelUpdateError.invalid("No failed staged files need recovery. Continue the saved update to recheck its current progress.")
        }
        let root = config.outputDir, protected = Array(occupancy.excluding(.modelUpdate).protectedPaths)
        let snapshots = try await WorkbenchIO.perform { Result {
            try paths.sorted().map { try Quarantine.updateStagingSnapshot(target: $0, roots: [root], protected: protected) }
        } }.get()
        return .init(recordID: record.id, snapshots: snapshots, failedReceipts: receipts.sorted(), queueItems: queueItems.sorted(), resetsDownload: resetDownload)
    }

    func applyModelUpdateRecovery(_ record: ModelUpdateRecord, preview: ModelUpdateRecoveryReview) async throws -> ModelUpdateRecord {
        guard preview.recordID == record.id, try await previewModelUpdateRecovery(record) == preview else {
            throw ModelUpdateError.invalid("Staged files or their receipts changed after recovery review.")
        }
        let root = config.outputDir, destination = config.quarantineDir
        let protected = Array(occupancy.excluding(.modelUpdate).protectedPaths)
        for snapshot in preview.snapshots {
            _ = try await WorkbenchIO.perform { Result {
                try Quarantine.moveUpdateStaging(expected: snapshot, roots: [root], protected: protected, quarantineDir: destination)
            } }.get()
            try await managedModels.forget(path: snapshot.path)
        }
        for id in preview.queueItems {
            _ = try await api.conversionQueue(.object(["operation": .string("cancel"), "id": .string(id)]))
        }
        var recovered = record
        if preview.resetsDownload { recovered.downloadedSource = nil }
        recovered.installation = nil; recovered.preparation = nil; recovered.endpointsSwitched = nil
        recovered.switchedEndpoints = nil; recovered.cleanupCompleted = nil
        recovered.state = .interrupted; recovered.stage = preview.resetsDownload ? .downloading : .awaitingPreparation
        recovered.error = nil; recovered.updatedAt = Date()
        await rescan()
        return recovered
    }
}
