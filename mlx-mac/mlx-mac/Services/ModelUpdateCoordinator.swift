import Foundation

/// User-confirmed revision replacement. A durable stage precedes each operation;
/// interrupted operations are never replayed automatically after launch.
@MainActor
final class ModelUpdateCoordinator: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var repo = ""
    @Published private(set) var candidates: [ModelUpdatePreviousModel] = []
    @Published private(set) var selectedPreviousPath: String?
    @Published private(set) var review: ModelUpdateReview?
    @Published private(set) var records: [ModelUpdateRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    @Published private(set) var persistenceError: String?
    @Published private(set) var recoveryReview: ModelUpdateRecoveryReview?
    @Published private(set) var activeRecordID: UUID?
    @Published private(set) var selectedBits: Int?
    @Published private(set) var selectedProjector: String?
    @Published private(set) var selectedFile: String?
    @Published private(set) var selectedCompanions: [String]?
    @Published private(set) var sourceConfirmed = false
    @Published var includesUnattributedModels = false
    var visibleCandidates: [ModelUpdatePreviousModel] {
        candidates.filter { includesUnattributedModels || $0.needsSourceConfirmation != true }
    }

    var preparationReview: ModelUpdatePreparationReview? {
        guard activeRecord?.stage == .awaitingPreparation, activeRecord?.state == .inProgress else { return nil }
        return activeRecord?.preparation
    }
    var protectedPaths: [String] {
        guard isRunning || preparationReview != nil, let record = activeRecord else { return [] }
        return Array(Set([record.review.previous.path, record.review.downloadedModelPath,
            record.review.sourceDirectory, record.review.destinationPath] + (record.review.dependencies ?? []).map(\.directory)))
    }

    var onCompletion: ((UUID) async -> Void)?
    var onDiscardReview: ((UUID) -> Void)?
    private var api: ModelUpdateAPI
    private let store: JSONStore<ModelUpdateRecord>
    private let now: () -> Date
    private let io = DispatchQueue(label: "model-update-history", qos: .utility)
    private var historyTask: Task<Void, Never>?
    private var hasLoadedHistory = false
    private var generation = UUID()
    private var alertID: UUID?

    init(api: ModelUpdateAPI,
         store: JSONStore<ModelUpdateRecord> = JSONStore(fileURL: JSONStore<ModelUpdateRecord>.defaultFileURL("model-updates.json")),
         now: @escaping () -> Date = Date.init) {
        self.api = api; self.store = store; self.now = now
        historyTask = Task { await loadHistory() }
    }

    /// AppHost wires captured integrations after its stored properties are initialized.
    func configure(api: ModelUpdateAPI) {
        precondition(!isRunning && !isLoading && !isPreparing)
        self.api = api
    }

    func waitForHistory() async { await historyTask?.value }

    var activeRecord: ModelUpdateRecord? { records.first { $0.id == activeRecordID } }
    var interruptedRecords: [ModelUpdateRecord] { records.filter { $0.state == .interrupted } }
    var resumableRecords: [ModelUpdateRecord] { records.filter { $0.state == .interrupted || $0.state == .failed } }

    func begin(repo: String, alertID: UUID? = nil) async {
        guard !isRunning && preparationReview == nil else { isPresented = true; return }
        discardReview()
        generation = UUID()
        let request = generation
        self.repo = repo; self.alertID = alertID
        candidates = []; selectedPreviousPath = nil; selectedBits = nil; selectedProjector = nil; selectedFile = nil; sourceConfirmed = false; selectedCompanions = nil; includesUnattributedModels = false; review = nil
        activeRecordID = nil; error = nil; isPreparing = false; isLoading = true; isPresented = true
        await waitForHistory()
        guard request == generation else { return }
        guard hasLoadedHistory else { isLoading = false; error = persistenceError; return }
        do {
            let found = try await api.candidates(repo)
            guard request == generation else { return }
            candidates = found.filter { $0.repo.caseInsensitiveCompare(repo) == .orderedSame }
            if candidates.isEmpty {
                error = "No previous installation from this repository is in the current library. Add it from Hugging Face to review it as a new model."
            }
        } catch {
            if request == generation { self.error = AppHost.render(error) }
        }
        if request == generation { isLoading = false }
    }

    func selectPrevious(path: String?) async {
        selectedBits = nil; selectedProjector = nil; selectedFile = nil; sourceConfirmed = false; selectedCompanions = nil
        await prepareSelection(path: path)
    }

    func selectPreparation(bits: Int?, file: String?, projector: String?, sourceConfirmed: Bool, additionalFiles: [String]? = nil) async {
        guard !isRunning, activeRecord == nil else { return }
        selectedCompanions = additionalFiles ?? selectedCompanions
        selectedBits = bits; selectedProjector = projector; selectedFile = file; self.sourceConfirmed = sourceConfirmed
        await prepareSelection(path: selectedPreviousPath)
    }

    private func prepareSelection(path: String?) async {
        guard !isRunning else { return }
        discardReview()
        generation = UUID()
        let request = generation
        selectedPreviousPath = path; review = nil; activeRecordID = nil; error = nil
        guard let candidate = candidates.first(where: { $0.path == path }) else { isPreparing = false; return }
        isPreparing = true
        var preparedID: UUID?
        do {
            let prepared: ModelUpdateReview
            if let prepare = api.prepareWithOptions { prepared = try await prepare(repo, candidate, ModelUpdateSettings(qBits: selectedBits, ggufFile: selectedFile, projectorFile: selectedProjector, sourceConfirmed: sourceConfirmed, additionalFiles: selectedCompanions)) }
            else { prepared = try await api.prepare(repo, candidate) }
            preparedID = prepared.id
            guard request == generation else { onDiscardReview?(prepared.id); return }
            guard prepared.previous == candidate, prepared.repo.caseInsensitiveCompare(repo) == .orderedSame else {
                throw ModelUpdateError.invalid("The update preview no longer matches the selected previous model. Review it again.")
            }
            try prepared.validate()
            review = prepared
        } catch {
            if let preparedID { onDiscardReview?(preparedID) }
            if request == generation { self.error = AppHost.render(error) }
        }
        if request == generation { isPreparing = false }
    }

    /// Closing a preview never dismisses its Watch alert. In-flight operations finish
    /// under their captured review even if the presentation is closed.
    func close() {
        isPresented = false
        if !isRunning && preparationReview == nil { discardReview(); generation = UUID(); isLoading = false; isPreparing = false }
    }

    private func discardReview() {
        if let review { onDiscardReview?(review.id) }
        review = nil
    }

    @discardableResult
    func confirm(quarantinePrevious: Bool) async -> Bool {
        guard !isRunning, let review, hasLoadedHistory else { return false }
        isRunning = true; error = nil
        defer { isRunning = false }
        do {
            try review.validateForDownload()
            guard !quarantinePrevious || review.previous.canQuarantine else {
                throw ModelUpdateError.invalid(review.previous.retentionReason ?? "The previous model must stay in its existing cache.")
            }
            guard !records.contains(where: { $0.id == review.id }) else {
                throw ModelUpdateError.invalid("This review has already been used. Review the current library and endpoints before starting another update.")
            }
            let date = now()
            var record = ModelUpdateRecord(id: review.id, alertID: alertID, review: review,
                quarantinePrevious: quarantinePrevious, createdAt: date, updatedAt: date,
                stage: .accepted, state: .inProgress, installation: nil, error: nil)
            activeRecordID = record.id
            try await save(record)
            do {
                try await advance(&record, to: .downloading)
                try Task.checkCancellation()
                try await api.revalidate(review, .download)
                let source = try await api.download(review)
                try source.validateDownload(for: review)
                record.downloadedSource = source
                try await save(record)
                if review.needsPreparation {
                    let preview = try await api.previewPreparation(review, source)
                    try preview.validate(for: review)
                    record.preparation = preview
                    try await advance(&record, to: .awaitingPreparation)
                    return false
                }
                try source.validate(for: review)
                record.installation = source
                try await save(record)
                return await finish(record)
            } catch {
                await fail(record, error: error)
                return false
            }
        } catch { self.error = AppHost.render(error); return false }
    }

    /// The downloaded source stays inert until its concrete local preparation plan is confirmed.
    @discardableResult
    func confirmPreparation(_ preview: ModelUpdatePreparationReview) async -> Bool {
        guard !isRunning, var record = activeRecord, record.state == .inProgress,
              record.stage == .awaitingPreparation, record.preparation == preview,
              let source = record.downloadedSource else { return false }
        isRunning = true; error = nil
        defer { isRunning = false }
        do {
            try preview.validate(for: record.review)
            try source.validateDownload(for: record.review)
            try await advance(&record, to: .preparing)
            try Task.checkCancellation()
            try await api.revalidate(record.review, .prepare)
            switch try await api.prepareInstallation(record.review, source, preview) {
            case .installed(let installed):
                try installed.validate(for: record.review)
                record.installation = installed
                try await save(record)
                return await finish(record)
            case .review(let next):
                try next.validate(for: record.review)
                record.preparation = next
                try await advance(&record, to: .awaitingPreparation)
                return false
            }
        } catch { await fail(record, error: error); return false }
    }

    var canRevisePreparation: Bool {
        guard !isRunning, !isPreparing, let record = activeRecord else { return false }
        return record.review.needsPreparation && record.downloadedSource != nil && record.installation == nil && record.state != .completed
    }

    @discardableResult
    func revisePreparation(bits: Int) async -> Bool {
        guard canRevisePreparation, let original = activeRecord else { return false }
        isPreparing = true; error = nil
        defer { isPreparing = false }
        do {
            let revised = try await api.revisePreparation(original, bits)
            guard revised.id == original.id, revised.review.previous == original.review.previous,
                  revised.review.targetRevision == original.review.targetRevision,
                  revised.review.resolution == original.review.resolution,
                  revised.review.previewHash == original.review.previewHash,
                  revised.review.sourceDirectory == original.review.sourceDirectory,
                  revised.review.additionalFiles == original.review.additionalFiles,
                  revised.review.projectorFile == original.review.projectorFile,
                  revised.review.reviewedEndpoints == original.review.reviewedEndpoints,
                  revised.review.cleanupSnapshot == original.review.cleanupSnapshot,
                  revised.downloadedSource == original.downloadedSource, revised.installation == nil,
                  revised.state == .inProgress, revised.stage == .awaitingPreparation,
                  let preparation = revised.preparation else { throw ModelUpdateError.invalid("Preparation settings changed the captured download or endpoints.") }
            try revised.review.validateForDownload()
            try preparation.validate(for: revised.review)
            try await save(revised)
            review = revised.review
            selectedBits = bits
            return true
        } catch { self.error = AppHost.render(error); return false }
    }

    func cancelRecovery() { recoveryReview = nil }

    func reviewRecovery(recordID: UUID) async {
        guard !isRunning, preparationReview == nil || activeRecordID == recordID, let record = resumableRecords.first(where: { $0.id == recordID }) else { return }
        isPreparing = true; recoveryReview = nil; error = nil
        defer { isPreparing = false }
        do { recoveryReview = try await api.previewRecovery(record) }
        catch { self.error = AppHost.render(error) }
    }

    @discardableResult
    func confirmRecovery(_ preview: ModelUpdateRecoveryReview) async -> Bool {
        guard !isRunning, recoveryReview == preview,
              let record = resumableRecords.first(where: { $0.id == preview.recordID }) else { return false }
        isRunning = true; error = nil
        do {
            let recovered = try await api.applyRecovery(record, preview)
            guard recovered.id == record.id, recovered.review == record.review else { throw ModelUpdateError.unavailable }
            try await save(recovered)
            recoveryReview = nil; isRunning = false
            return await resume(recordID: recovered.id)
        } catch { self.error = AppHost.render(error); isRunning = false; return false }
    }

    /// An explicit continuation reconnects receipts and rechecks current files and endpoints.
    /// Loading history never invokes this operation.
    @discardableResult
    func resume(recordID: UUID) async -> Bool {
        guard !isRunning, preparationReview == nil || activeRecordID == recordID, hasLoadedHistory, var record = records.first(where: { $0.id == recordID }),
              record.state == .failed || record.state == .interrupted else { return false }
        discardReview()
        generation = UUID(); activeRecordID = recordID; review = record.review; repo = record.review.repo
        selectedPreviousPath = record.review.previous.path; isPresented = true; error = nil; isRunning = true
        defer { isRunning = false }
        do {
            record.state = .inProgress; record.error = nil; record.updatedAt = now()
            try await save(record)
            record = try await api.recover(record)
            guard record.id == recordID, record.review == review else { throw ModelUpdateError.invalid("The saved update changed during recovery.") }
            try await save(record)
            if record.installation != nil { return await finish(record) }
            if record.downloadedSource == nil {
                try await advance(&record, to: .downloading)
                try await api.revalidate(record.review, .download)
                let source = try await api.download(record.review)
                try source.validateDownload(for: record.review)
                record.downloadedSource = source
                try await save(record)
            }
            guard let source = record.downloadedSource else { throw ModelUpdateError.unavailable }
            if record.review.needsPreparation {
                if record.preparation?.operation != .observeConversion {
                    record.preparation = try await api.previewPreparation(record.review, source)
                }
                try record.preparation?.validate(for: record.review)
                try await advance(&record, to: .awaitingPreparation)
                return false
            }
            try source.validate(for: record.review)
            record.installation = source
            try await save(record)
            return await finish(record)
        } catch { await fail(record, error: error); return false }
    }

    private func finish(_ captured: ModelUpdateRecord) async -> Bool {
        var record = captured
        let review = record.review
        do {
            guard let installed = record.installation else { throw ModelUpdateError.unavailable }
            if record.endpointsSwitched != true {
            try await advance(&record, to: .verifying)
            try Task.checkCancellation()
            try await api.revalidate(review, .verify)
            let verified = try await api.verify(review, installed)
            try verified.validate(for: review)
            guard verified.path == installed.path, verified.signature == installed.signature else {
                throw ModelUpdateError.invalid("Verification returned a different model. The previous version was kept.")
            }
            record.installation = verified
            try await save(record)

            try await advance(&record, to: .switching)
            try Task.checkCancellation()
            try await api.revalidate(review, .switchEndpoints)
            try await api.switchEndpoints(review, verified)
            record.endpointsSwitched = true
            record.switchedEndpoints = api.switchedEndpoints(review)
            try await save(record)
            }

            if record.quarantinePrevious && record.cleanupCompleted != true {
                try await advance(&record, to: .quarantining)
                try Task.checkCancellation()
                try await api.revalidate(review, .quarantinePrevious)
                try await api.quarantinePrevious(review, record.installation ?? installed)
                record.cleanupCompleted = true
                try await save(record)
            }
            record.stage = .completed; record.state = .completed; record.updatedAt = now()
            try await save(record)
            if let alertID = record.alertID { await onCompletion?(alertID) }
            return true
        } catch { await fail(record, error: error); return false }
    }

    private func fail(_ captured: ModelUpdateRecord, error: Error) async {
        var record = captured
        record.state = error is CancellationError ? .interrupted : .failed
        record.error = AppHost.render(error); record.updatedAt = now()
        self.error = record.error
        do { try await save(record) } catch { self.error = persistenceError }
    }

    private func advance(_ record: inout ModelUpdateRecord, to stage: ModelUpdateStage) async throws {
        record.stage = stage; record.updatedAt = now()
        try await save(record)
    }

    private func save(_ record: ModelUpdateRecord) async throws {
        let store = store
        do {
            try await WorkbenchIO.perform(on: io) { Result { try store.upsert(record, id: \.id) } }.get()
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
            else { records.insert(record, at: 0) }
            persistenceError = nil
        } catch {
            persistenceError = "The model update could not be saved: \(AppHost.render(error))"
            throw error
        }
    }

    private func loadHistory() async {
        defer { historyTask = nil }
        let store = store
        do {
            let loaded = try await WorkbenchIO.perform(on: io) { Result { try store.load() } }.get()
            records = loaded.sorted { $0.updatedAt > $1.updatedAt }.map { record in
                guard record.state == .inProgress else { return record }
                var interrupted = record
                interrupted.state = .interrupted
                interrupted.error = "The update was interrupted during \(record.stage.title.lowercased()). Continue the saved update to recheck its files, receipts and endpoints."
                return interrupted
            }
            // Persist interruption before accepting another mutation. No operation is
            // inferred to have succeeded and no cleanup is resumed from a stale review.
            let recovered = records
            if recovered != loaded.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                try await WorkbenchIO.perform(on: io) { Result { try store.replaceAll(recovered) } }.get()
            }
            hasLoadedHistory = true
        } catch {
            persistenceError = "Saved model updates are unavailable: \(AppHost.render(error))"
        }
    }
}
