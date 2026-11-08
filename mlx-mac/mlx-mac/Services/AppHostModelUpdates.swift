import Foundation

@MainActor
final class ModelUpdateCaptures {
    struct Capture {
        let endpoints: [EndpointSlot]
        let cleanup: QuarantineFileSnapshot?
        let sourceInstall: ManagedModelInstall?
        let managedBundle: String?
        let bundleFiles: [String]
    }
    private var values: [UUID: Capture] = [:]
    subscript(_ id: UUID) -> Capture? { values[id] }
    func insert(_ id: UUID, endpoints: [EndpointSlot], cleanup: QuarantineFileSnapshot?, sourceInstall: ManagedModelInstall? = nil, managedBundle: String? = nil, bundleFiles: [String] = []) {
        values[id] = Capture(endpoints: endpoints, cleanup: cleanup, sourceInstall: sourceInstall, managedBundle: managedBundle, bundleFiles: bundleFiles)
    }
    func discard(_ id: UUID) { values[id] = nil }
}

extension AppHost {
    func configureModelUpdates() {
        var integration = ModelUpdateAPI(
            candidates: { [weak self] repo in
                guard let self else { throw ModelUpdateError.unavailable }
                return try await self.updateCandidates(repo: repo)
            }, prepare: { [weak self] repo, previous in
                guard let self else { throw ModelUpdateError.unavailable }
                return try await self.prepareModelUpdate(repo: repo, previous: previous)
            }, revalidate: { [weak self] review, mutation in
                guard let self else { throw ModelUpdateError.unavailable }
                try await self.revalidateModelUpdate(review, mutation: mutation)
            }, download: { [weak self] review in
                guard let self else { throw ModelUpdateError.unavailable }
                return try await self.downloadModelUpdate(review)
            }, verify: { [weak self] review, installed in
                guard let self else { throw ModelUpdateError.unavailable }
                return try await self.verifyModelUpdate(review, installed: installed)
            }, switchEndpoints: { [weak self] review, installed in
                guard let self, let slots = self.modelUpdateCaptures[review.id]?.endpoints else { throw ModelUpdateError.unavailable }
                try installed.validate(for: review)
                guard await self.endpoint.replaceModelForUpdate(expected: slots, modelPath: installed.path, profileReplacements: installed.profileReplacements ?? [:]) else {
                    throw ModelUpdateError.invalid(self.endpoint.lastError ?? "The endpoints could not switch. The previous files remain in place.")
                }
                await self.modelWorkflow.refreshServers()
                await self.servingInventory.refresh()
                guard self.modelWorkflow.serversError == nil else {
                    throw ModelUpdateError.invalid("The endpoint switched, but serving status could not be refreshed. The previous files were kept.")
                }
            }, quarantinePrevious: { [weak self] review, installed in
                guard let self, let capture = self.modelUpdateCaptures[review.id], let expected = capture.cleanup else { throw ModelUpdateError.unavailable }
                try installed.validate(for: review)
                let protected = Array(self.occupancy.excluding(.modelUpdate).protectedPaths), root = self.config.outputDir, destination = self.config.quarantineDir
                _ = try await WorkbenchIO.perform { Result {
                    try Quarantine.moveModelUpdate(expected: expected, roots: [root], protected: protected, quarantineDir: destination,
                        managedBundle: capture.managedBundle, bundleFiles: capture.bundleFiles)
                } }.get()
                try await self.managedModels.forget(path: review.previous.path)
                await self.rescan()
            })
        integration.prepareWithOptions = { [weak self] repo, previous, settings in
            guard let self else { throw ModelUpdateError.unavailable }
            return try await self.prepareCompleteModelUpdate(repo: repo, previous: previous, settings: settings)
        }
        integration.previewPreparation = { [weak self] review, source in
            guard let self else { throw ModelUpdateError.unavailable }
            return try await self.previewModelUpdatePreparation(review, source: source)
        }
        integration.prepareInstallation = { [weak self] review, source, preview in
            guard let self else { throw ModelUpdateError.unavailable }
            return try await self.prepareModelUpdateInstallation(review, source: source, prepared: preview)
        }
        integration.revisePreparation = { [weak self] record, bits in
            guard let self else { throw ModelUpdateError.unavailable }
            return try await self.reviseModelUpdatePreparation(record, bits: bits)
        }
        integration.previewRecovery = { [weak self] record in
            guard let self else { throw ModelUpdateError.unavailable }
            return try await self.previewModelUpdateRecovery(record)
        }
        integration.applyRecovery = { [weak self] record, preview in
            guard let self else { throw ModelUpdateError.unavailable }
            return try await self.applyModelUpdateRecovery(record, preview: preview)
        }
        integration.recover = { [weak self] record in
            guard let self else { throw ModelUpdateError.unavailable }
            return try await self.recoverModelUpdate(record)
        }
        integration.switchedEndpoints = { [weak self] review in
            guard let self else { return nil }
            let ids = Set((review.reviewedEndpoints ?? []).map(\.id))
            return self.endpoint.fleet.slots.filter { ids.contains($0.id) }
        }
        modelUpdates.configure(api: integration)
        modelUpdates.onCompletion = { [weak self] alert in
            guard let self else { return }
            _ = await self.watch.dismiss(alert).value
        }
        modelUpdates.onDiscardReview = { [weak self] id in
            self?.modelUpdateCaptures.discard(id)
        }
    }

    func recordManagedInstall(_ resolution: IntakeResolution, path: String) async throws {
        guard ModelUpdateReview.isCommit(resolution.source.fetchRevision),
              path.hasPrefix(URL(fileURLWithPath: config.outputDir).appendingPathComponent("managed").path + "/") else { return }
        let signature = try await WorkbenchIO.perform { Result { try ManagedModelInstallStore.signature(path: path) } }.get()
        let install = ManagedModelInstall(repo: resolution.source.repo,
            revision: resolution.source.fetchRevision, path: path, signature: signature, installedAt: Date(),
            file: resolution.source.file, subfolder: resolution.source.subfolder)
        guard ManagedModelInstallStore.matchesManagedSourcePath(install, root: config.outputDir) else {
            throw ModelUpdateError.invalid("The downloaded folder does not match its recorded checkpoint selection.")
        }
        try await managedModels.record(install)
    }

    func updateCandidates(repo: String) async throws -> [ModelUpdatePreviousModel] {
        await modelPurposes.waitForHistory()
        guard modelPurposes.hasLoadedHistory else { throw ModelUpdateError.invalid("Saved model purposes are unavailable. Resolve them before reviewing replacement.") }
        let records = try await managedModels.records()
        let jobs = try await api.convertStatus()
        let root = URL(fileURLWithPath: config.outputDir).standardizedFileURL.path
        var result: [ModelUpdatePreviousModel] = []
        for model in librarySnapshot?.models ?? [] {
            let path = model.item.path
            let recorded = records.first { $0.path == path }
            let cachedRepo = HFRepoID.forPath(path)
            if let recorded, recorded.repo.caseInsensitiveCompare(repo) != .orderedSame { continue }
            if let cachedRepo, cachedRepo.caseInsensitiveCompare(repo) != .orderedSame { continue }
            let signature = try? await WorkbenchIO.perform { Result { try ManagedModelInstallStore.signature(path: path) } }.get()
            let cache = ManagedModelInstallStore.cacheSelection(path: path, repo: repo)
            let attributed = recorded.map {
                $0.signature == signature && ManagedModelInstallStore.matchesManagedSourcePath($0, root: root)
            } ?? false
            let known = attributed || cache != nil
            let revision = attributed ? recorded?.revision : cache?.revision
            // Retained receipts can suggest preparation settings. They never assert
            // an unrecorded historical revision for a converted output.
            let job = jobs.filter { $0.out == path }.max { ($0.startedAt ?? "") < ($1.startedAt ?? "") }
            if let origin = job?.sourceDetails?.origin, origin.repo.caseInsensitiveCompare(repo) != .orderedSame { continue }
            var conversion = attributed ? recorded?.preparation : nil
            if conversion == nil, let job, let receipt = job.receipt, let bits = job.qBits,
               let source = job.sourceDetails?.path ?? (job.source == "gguf" ? job.repo : nil),
               let fingerprint = job.sourceDetails?.signature ?? job.sourceDetails?.fingerprint,
               receipt.hasPrefix("/"), !fingerprint.isEmpty {
                let kind: ModelUpdateConversionRecipe.Kind = job.source == "gguf" || job.sourceDetails?.kind == "gguf" ? .gguf : .repository
                let recipe = ModelUpdateConversionRecipe(kind: kind, qBits: bits, backend: kind == .repository ? (job.backend ?? "mlx-lm") : nil, modelType: job.modelType)
                if (try? recipe.validate()) != nil {
                    conversion = .init(recipe: recipe, sourcePath: source, sourceSignature: fingerprint, conversionReceipt: receipt,
                        fetchReceipt: job.sourceDetails?.fetchReceipt,
                        projectorFile: Self.updateProjectorSelection(source: source, file: job.sourceDetails?.origin?.file, projector: job.sourceDetails?.projector?.path),
                        requiresProjector: job.sourceDetails?.projector != nil)
                }
            }
            let file = recorded?.file ?? cache?.file ?? job?.sourceDetails?.origin?.file
            let subfolder = recorded?.subfolder ?? cache?.subfolder ?? job?.sourceDetails?.origin?.subfolder
            let retained = modelPurposes.purpose(for: path)?.note
            let localOutput = path.hasPrefix(root + "/") && cachedRepo == nil
            var canQuarantine = signature != nil && retained == nil && localOutput && !config.quarantineDir.isEmpty
            var reason = retained.map { "Kept: " + $0 }
            if canQuarantine {
                let bundle = Self.modelUpdateBundle(recorded, root: root)
                let outcome = await WorkbenchIO.perform { Result { try Quarantine.modelUpdateSnapshot(target: path, roots: [root], protected: [], managedBundle: bundle?.directory, bundleFiles: bundle?.files ?? []) } }
                if case .failure(let error) = outcome { canQuarantine = false; reason = Self.render(error) }
            }
            if signature == nil { reason = "These files are unavailable or unreadable. Refresh the library after restoring access." }
            else if reason == nil && !known { reason = "The previous repository revision is unknown. Confirm the source; the current files are protected by their exact file identity." }
            else if reason == nil && !localOutput { reason = "This copy stays in its provider cache. Review cleanup with that provider after the update." }
            else if reason == nil && config.quarantineDir.isEmpty { reason = "Configure Quarantine before requesting removal of the previous version." }
            result.append(.init(repo: repo, path: path, signature: signature, revision: revision,
                displayName: model.displayName, canQuarantine: canQuarantine, retentionReason: reason,
                file: file, subfolder: subfolder, convertedOrigin: conversion,
                needsSourceConfirmation: !known, isConverted: URL(fileURLWithPath: path).pathExtension.lowercased() != "gguf",
                requiresProjector: recorded?.requiresProjector == true || conversion?.requiresProjector == true || model.item.task?.type == .visionLanguage,
                additionalFiles: recorded?.additionalFiles, projectorFile: recorded?.projectorFile))
        }
        return result
    }

    static func modelUpdateBundle(_ install: ManagedModelInstall?, root: String) -> (directory: String, files: [String])? {
        guard let install, install.preparation == nil, let main = install.file,
              main.lowercased().hasSuffix(".gguf"), ManagedModelInstallStore.matchesManagedSourcePath(install, root: root) else { return nil }
        let source = IntakeSource(input: install.repo, repo: install.repo, revision: install.revision,
            file: main, subfolder: nil, url: "https://huggingface.co/" + install.repo)
        guard let directory = ManagedModelInstallStore.directory(root: root, source: source) else { return nil }
        return (directory, [main] + (install.additionalFiles ?? []).filter { $0 != main }.sorted())
    }

    private static func updateProjectorSelection(source: String, file: String?, projector: String?) -> String? {
        guard let file, let projector else { return nil }
        var root = URL(fileURLWithPath: source)
        for _ in file.split(separator: "/") { root.deleteLastPathComponent() }
        guard projector.hasPrefix(root.path + "/") else { return nil }
        return String(projector.dropFirst(root.path.count + 1))
    }

    private func prepareModelUpdate(repo: String, previous: ModelUpdatePreviousModel) async throws -> ModelUpdateReview {
        try await prepareCompleteModelUpdate(repo: repo, previous: previous, settings: ModelUpdateSettings())
    }

    func revalidateModelUpdate(_ review: ModelUpdateReview, mutation: ModelUpdateMutation) async throws {
        try review.validateForDownload()
        try await WorkbenchIO.perform { Result { try ManagedModelInstallStore.refuseLinks(in: review.destinationPath) } }.get()
        guard let expected = modelUpdateCaptures[review.id]?.endpoints, !reclaim.isApplying,
              comparison.activeRunID == nil, hostedComparison.activeRunID == nil,
              !occupancy.excluding(.modelUpdate).blocksStop(modelIdentity: review.previous.path) else {
            throw ModelUpdateError.invalid("Finish work using these models before continuing the update.")
        }
        let oldPath = review.previous.path
        let cleanupDone = modelUpdates.activeRecord?.cleanupCompleted == true
        let signature = cleanupDone ? review.previous.signature : try await WorkbenchIO.perform { Result { try ManagedModelInstallStore.signature(path: oldPath) } }.get()
        guard signature == review.previous.signature else { throw ModelUpdateError.invalid("The previous model changed. Its files were kept; review the update again.") }
        let records = try await managedModels.records()
        guard cleanupDone || records.first(where: { $0.path == oldPath }) == modelUpdateCaptures[review.id]?.sourceInstall else {
            throw ModelUpdateError.invalid("The previous installation's source record changed. Review the update again.")
        }

        if mutation != .quarantinePrevious && modelUpdates.activeRecord?.endpointsSwitched != true {
            guard expected.allSatisfy({ slot in endpoint.fleet.slots.contains(slot) }),
                  endpoint.fleet.slots.filter({ $0.modelPath == oldPath }) == expected else {
                throw ModelUpdateError.invalid("Endpoint settings changed. Review the update again.")
            }
        }
        if mutation == .download {
            guard !intake.isBusy, !FileManager.default.fileExists(atPath: review.destinationPath) || review.destinationPath == review.downloadedModelPath else { throw ModelUpdateError.invalid("Another download or destination now exists. Review again.") }
        }
        if mutation == .prepare, let source = modelUpdates.activeRecord?.downloadedSource { try await validateUpdateSources(source) }
        if mutation == .verify || mutation == .switchEndpoints || mutation == .quarantinePrevious {
            guard let installed = modelUpdates.activeRecord?.installation else { throw ModelUpdateError.invalid("The installed revision is unavailable. Review the update again.") }
            try installed.validate(for: review)
            let current = try await WorkbenchIO.perform { Result { try ManagedModelInstallStore.signature(path: installed.path) } }.get()
            guard current == installed.signature else { throw ModelUpdateError.invalid("The prepared model changed. Review its files before continuing.") }
            if mutation != .verify {
                let profiles = expected.compactMap(\.servingProfile)
                for original in profiles {
                    guard let replacement = installed.profileReplacements?[original.id], replacement.modelPath == installed.path,
                          replacement.options == original.options else { throw ModelUpdateError.invalid("A fresh source-bound Strata profile is missing.") }
                    let currentProfile = try servingProfiles.resolve(replacement)
                    _ = try await currentProfile.preview(api: api, port: nil)
                }
                if expected.isEmpty || expected.contains(where: { $0.servingProfile == nil }) {
                    guard case .verified = verification.status(for: installed.path, signature: installed.signature) else {
                        throw ModelUpdateError.invalid("The new model no longer has matching verification. The previous files were kept.")
                    }
                }
            }
        }
        if mutation == .quarantinePrevious {
            guard let installed = modelUpdates.activeRecord?.installation,
                  expected.isEmpty || Self.matchesSwitchedUpdate(expected: expected, current: endpoint.fleet.slots, installed: installed) else {
                throw ModelUpdateError.invalid("Switched endpoint settings changed. Review Run before continuing cleanup.")
            }
            await modelWorkflow.refreshServers()
            await servingInventory.refresh(refreshHosts: true)
            guard modelWorkflow.serversError == nil, servingInventory.supportsEngineDiscovery, servingInventory.snapshot.sourceErrors.isEmpty,
                  !servingInventory.snapshot.services.contains(where: { $0.isLocal && ($0.stale || $0.modelPath == oldPath && $0.server?.state == "running" || $0.modelID == oldPath && $0.residency == .loaded) }),
                  !occupancy.excluding(.modelUpdate).protectedPaths.contains(oldPath) else {
                throw ModelUpdateError.invalid("The previous model is still in use or serving status is incomplete. Its files were kept.")
            }
        }
    }

    private func downloadModelUpdate(_ review: ModelUpdateReview) async throws -> ModelUpdateInstallation {
        try await downloadCompleteModelUpdate(review)
    }

    private func verifyModelUpdate(_ review: ModelUpdateReview, installed: ModelUpdateInstallation) async throws -> ModelUpdateInstallation {
        try installed.validate(for: review)
        guard let captured = modelUpdateCaptures[review.id] else { throw ModelUpdateError.unavailable }
        var result = installed
        let profiles = captured.endpoints.compactMap(\.servingProfile)
        if !profiles.isEmpty {
            result.profileReplacements = try await servingProfiles.createUpdateReplacements(expected: profiles, modelPath: installed.path)
        }
        if !captured.endpoints.isEmpty && captured.endpoints.allSatisfy({ $0.servingProfile != nil }) {
            let signature = try await WorkbenchIO.perform { Result { try ManagedModelInstallStore.signature(path: installed.path) } }.get()
            guard signature == installed.signature else { throw ModelUpdateError.invalid("The new model files changed during profile verification. The previous model was kept.") }
            return result
        }
        guard verification.activeModelPath == nil else { throw ModelUpdateError.invalid("Another verification is active. The previous files were kept.") }
        verification.verifyNow(modelPath: installed.path, signature: installed.signature)
        while verification.activeModelPath != nil {
            try await Task.sleep(for: .milliseconds(250))
        }
        guard case .verified = verification.status(for: installed.path, signature: installed.signature) else {
            throw ModelUpdateError.invalid(verification.lastError ?? "The new revision did not pass verification. The previous model and endpoints were kept.")
        }
        let signature = try await WorkbenchIO.perform { Result { try ManagedModelInstallStore.signature(path: installed.path) } }.get()
        guard signature == installed.signature else { throw ModelUpdateError.invalid("The new model files changed during verification. The previous model was kept.") }
        return result
    }
}
