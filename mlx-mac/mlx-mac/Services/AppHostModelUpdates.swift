import Foundation

@MainActor
final class ModelUpdateCaptures {
    struct Capture {
        let endpoints: [EndpointSlot]
        let cleanup: QuarantineFileSnapshot?
    }
    private var values: [UUID: Capture] = [:]
    subscript(_ id: UUID) -> Capture? { values[id] }
    func insert(_ id: UUID, endpoints: [EndpointSlot], cleanup: QuarantineFileSnapshot?) {
        values[id] = Capture(endpoints: endpoints, cleanup: cleanup)
    }
    func discard(_ id: UUID) { values[id] = nil }
}

extension AppHost {
    func configureModelUpdates() {
        modelUpdates.configure(api: ModelUpdateAPI(
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
                try await self.verifyModelUpdate(review, installed: installed)
            }, switchEndpoints: { [weak self] review, installed in
                guard let self, let slots = self.modelUpdateCaptures[review.id]?.endpoints else { throw ModelUpdateError.unavailable }
                try installed.validate(for: review)
                guard await self.endpoint.replaceModelForUpdate(expected: slots, modelPath: installed.path) else {
                    throw ModelUpdateError.invalid(self.endpoint.lastError ?? "The endpoints could not switch. The previous files remain in place.")
                }
                await self.modelWorkflow.refreshServers()
                await self.servingInventory.refresh()
                guard self.modelWorkflow.serversError == nil else {
                    throw ModelUpdateError.invalid("The endpoint switched, but serving status could not be refreshed. The previous files were kept.")
                }
            }, quarantinePrevious: { [weak self] review, installed in
                guard let self, let expected = self.modelUpdateCaptures[review.id]?.cleanup else { throw ModelUpdateError.unavailable }
                try installed.validate(for: review)
                let protected = Array(self.occupancy.protectedPaths), root = self.config.outputDir, destination = self.config.quarantineDir
                _ = try await WorkbenchIO.perform { Result {
                    try Quarantine.moveFolder(expected: expected, roots: [root], protected: protected, quarantineDir: destination)
                } }.get()
                try await self.managedModels.forget(path: review.previous.path)
                await self.rescan()
            }))
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

    private func updateCandidates(repo: String) async throws -> [ModelUpdatePreviousModel] {
        await modelPurposes.waitForHistory()
        guard modelPurposes.hasLoadedHistory else { throw ModelUpdateError.invalid("Saved model purposes are unavailable. Resolve them before reviewing replacement.") }
        let records = try await managedModels.records()
        var result: [ModelUpdatePreviousModel] = []
        let managedRoot = URL(fileURLWithPath: config.outputDir).appendingPathComponent("managed").path + "/"
        for model in librarySnapshot?.models ?? [] {
            let path = model.item.path
            let install = records.first { $0.path == path && $0.repo.caseInsensitiveCompare(repo) == .orderedSame }
            guard install != nil || HFRepoID.forPath(path)?.caseInsensitiveCompare(repo) == .orderedSame else { continue }
            let signature = try await WorkbenchIO.perform { Result { try ManagedModelInstallStore.signature(path: path) } }.get()
            let cache = ManagedModelInstallStore.cacheSelection(path: path, repo: repo)
            let verifiedInstall = try await managedModels.verifiedRecord(path: path, signature: signature)
            let sourceMatches = install.map { ManagedModelInstallStore.matchesManagedSourcePath($0, root: config.outputDir) } ?? false
            let attributed = install == nil || verifiedInstall == install && sourceMatches
            let revision = attributed ? (install?.revision ?? cache?.revision) : nil
            let retained = modelPurposes.purpose(for: path)?.note
            let managed = install != nil && attributed && path.hasPrefix(managedRoot) && retained == nil
            let cleanupReason: String?
            if managed {
                if config.quarantineDir.isEmpty {
                    cleanupReason = "Configure a Quarantine folder before removing this version. It will stay in place during this update."
                } else {
                    let roots = [config.outputDir]
                    let result = await WorkbenchIO.perform { Result { try Quarantine.folderSnapshot(target: path, roots: roots, protected: []) } }
                    switch result {
                    case .success: cleanupReason = nil
                    case .failure(let error): cleanupReason = "This version will stay in place. " + Self.render(error)
                    }
                }
            } else { cleanupReason = nil }
            let provenanceReason: String?
            if install != nil && verifiedInstall != install {
                provenanceReason = "This installation changed after download. Its source revision is no longer confirmed; review it in Add from Hugging Face."
            } else if install != nil && !sourceMatches {
                provenanceReason = "This installation has no matching checkpoint selection. Review its source in Add from Hugging Face."
            } else { provenanceReason = nil }
            result.append(ModelUpdatePreviousModel(repo: repo, path: path, signature: signature,
                revision: revision, displayName: model.displayName, canQuarantine: managed && cleanupReason == nil,
                retentionReason: provenanceReason ?? cleanupReason ?? retained.map { "Kept: " + $0 } ?? (managed ? nil : "This copy stays in its provider cache. Review cleanup with that provider after the update."),
                file: install?.file ?? cache?.file, subfolder: install?.subfolder ?? cache?.subfolder))
        }
        return result
    }

    private func prepareModelUpdate(repo: String, previous: ModelUpdatePreviousModel) async throws -> ModelUpdateReview {
        guard try await updateCandidates(repo: repo).contains(previous), !intake.isBusy else {
            throw ModelUpdateError.invalid("The selected installation changed or another download is active. Review again.")
        }
        guard previous.revision != nil else {
            throw ModelUpdateError.invalid(previous.retentionReason ?? "The previous source revision is unavailable. Review it in Add from Hugging Face.")
        }
        let source = try ManagedModelInstallStore.sourceReference(repo: repo, file: previous.file, subfolder: previous.subfolder)
        let resolution = try await api.intakeResolve(source: source)
        guard resolution.verdict == .alreadyMLX, previous.file == nil, resolution.source.file == nil else { throw ModelUpdateError.requiresPreparation }
        guard ModelUpdateReview.isCommit(resolution.source.fetchRevision),
              let root = ManagedModelInstallStore.directory(root: config.outputDir, source: resolution.source) else {
            throw ModelUpdateError.invalid("The engine did not resolve an immutable model revision. Update the engine and review again.")
        }
        let destination = resolution.source.subfolder.map { URL(fileURLWithPath: root).appendingPathComponent($0).path } ?? root
        try await WorkbenchIO.perform { Result { try ManagedModelInstallStore.refuseLinks(in: destination) } }.get()
        guard !FileManager.default.fileExists(atPath: root) else { throw ModelUpdateError.invalid("This revision already has a managed folder. Review it in Library before downloading another copy.") }
        let slots = endpoint.fleet.slots.filter { $0.modelPath == previous.path }
        guard slots.allSatisfy({ $0.servingProfile == nil }) else { throw ModelUpdateError.requiresPreparation }
        let plan = try await api.intakeFetchPreview(IntakeFetchRequest(source: resolution.source.reference,
            revision: resolution.source.fetchRevision, file: resolution.source.file, localDir: root, modelType: resolution.modelType))
        guard let hash = plan["preview_hash"] as? String, !hash.isEmpty else { throw ModelUpdateError.invalid("The engine returned no download preview.") }
        let review = ModelUpdateReview(id: UUID(), repo: repo, previous: previous, resolution: resolution,
            targetRevision: resolution.source.fetchRevision, destinationPath: destination, previewHash: hash,
            endpointSummary: slots.map { "Port \($0.port) · \($0.enabled ? "enabled" : "disabled")" + ($0.accelerationOptions.requested ? " · acceleration requires a new preview" : "") })
        try review.validate()
        try await WorkbenchIO.perform { Result { try ManagedModelInstallStore.refuseLinks(in: review.destinationPath) } }.get()
        var cleanup: QuarantineFileSnapshot?
        if previous.canQuarantine {
            let path = previous.path, roots = [config.outputDir]
            cleanup = try await WorkbenchIO.perform { Result {
                try Quarantine.folderSnapshot(target: path, roots: roots, protected: [])
            } }.get()
        }
        modelUpdateCaptures.insert(review.id, endpoints: slots, cleanup: cleanup)
        return review
    }

    private func revalidateModelUpdate(_ review: ModelUpdateReview, mutation: ModelUpdateMutation) async throws {
        try review.validate()
        try await WorkbenchIO.perform { Result { try ManagedModelInstallStore.refuseLinks(in: review.destinationPath) } }.get()
        guard let expected = modelUpdateCaptures[review.id]?.endpoints, !reclaim.isApplying,
              comparison.activeRunID == nil, hostedComparison.activeRunID == nil,
              !occupancy.blocksStop(modelIdentity: review.previous.path) else {
            throw ModelUpdateError.invalid("Finish work using these models before continuing the update.")
        }
        let oldPath = review.previous.path
        let signature = try await WorkbenchIO.perform { Result { try ManagedModelInstallStore.signature(path: oldPath) } }.get()
        guard signature == review.previous.signature else { throw ModelUpdateError.invalid("The previous model changed. Its files were kept; review the update again.") }
        let records = try await managedModels.records()
        if let recorded = records.first(where: { $0.path == oldPath }) {
            guard recorded.repo.caseInsensitiveCompare(review.repo) == .orderedSame,
                  recorded.signature == signature, recorded.revision == review.previous.revision,
                  recorded.file == review.previous.file, recorded.subfolder == review.previous.subfolder,
                  ManagedModelInstallStore.matchesManagedSourcePath(recorded, root: config.outputDir) else {
                throw ModelUpdateError.invalid("The previous installation's source record changed. Its files were kept; review the update again.")
            }
        } else if review.previous.canQuarantine {
            throw ModelUpdateError.invalid("The previous installation's source record is unavailable. Its files were kept.")
        }

        if mutation != .quarantinePrevious {
            guard expected.allSatisfy({ slot in endpoint.fleet.slots.contains(slot) }),
                  endpoint.fleet.slots.filter({ $0.modelPath == oldPath }) == expected else {
                throw ModelUpdateError.invalid("Endpoint settings changed. Review the update again.")
            }
        }
        if mutation == .download {
            guard !intake.isBusy, !FileManager.default.fileExists(atPath: review.destinationPath) else { throw ModelUpdateError.invalid("Another download or destination now exists. Review again.") }
        }
        if mutation == .switchEndpoints || mutation == .quarantinePrevious {
            guard let installed = modelUpdates.activeRecord?.installation else { throw ModelUpdateError.invalid("The installed revision is unavailable. Review the update again.") }
            try installed.validate(for: review)
            let current = try await WorkbenchIO.perform { Result { try ManagedModelInstallStore.signature(path: installed.path) } }.get()
            guard current == installed.signature, case .verified = verification.status(for: installed.path, signature: installed.signature) else {
                throw ModelUpdateError.invalid("The new model changed or no longer has matching verification. The previous files were kept.")
            }
        }
        if mutation == .quarantinePrevious {
            await modelWorkflow.refreshServers()
            await servingInventory.refresh(refreshHosts: true)
            guard modelWorkflow.serversError == nil, servingInventory.supportsEngineDiscovery, servingInventory.snapshot.sourceErrors.isEmpty,
                  !servingInventory.snapshot.services.contains(where: { $0.isLocal && ($0.stale || $0.modelPath == oldPath && $0.server?.state == "running" || $0.modelID == oldPath && $0.residency == .loaded) }),
                  !occupancy.protectedPaths.contains(oldPath) else {
                throw ModelUpdateError.invalid("The previous model is still in use or serving status is incomplete. Its files were kept.")
            }
        }
    }

    private func downloadModelUpdate(_ review: ModelUpdateReview) async throws -> ModelUpdateInstallation {
        guard let root = ManagedModelInstallStore.directory(root: config.outputDir, source: review.resolution.source),
              review.destinationPath == (review.resolution.source.subfolder.map { URL(fileURLWithPath: root).appendingPathComponent($0).path } ?? root) else { throw ModelUpdateError.invalid("The managed destination changed. Review again.") }
        let path = try await intake.download(resolution: review.resolution, localDir: root, previewHash: review.previewHash)
        let modelPath = review.resolution.source.subfolder.map { URL(fileURLWithPath: path).appendingPathComponent($0).path } ?? path
        guard modelPath == review.destinationPath else { throw ModelUpdateError.invalid("The downloaded model is in a different location. The previous files were kept.") }
        let signature = try await WorkbenchIO.perform { Result { try ManagedModelInstallStore.signature(path: modelPath) } }.get()
        try await managedModels.record(ManagedModelInstall(repo: review.repo, revision: review.targetRevision,
            path: modelPath, signature: signature, installedAt: Date(),
            file: review.resolution.source.file, subfolder: review.resolution.source.subfolder))
        await rescan()
        return ModelUpdateInstallation(repo: review.repo, revision: review.targetRevision, path: modelPath, signature: signature)
    }

    private func verifyModelUpdate(_ review: ModelUpdateReview, installed: ModelUpdateInstallation) async throws {
        try installed.validate(for: review)
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
    }
}
