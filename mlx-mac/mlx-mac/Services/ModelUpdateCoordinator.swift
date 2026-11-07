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
    @Published private(set) var activeRecordID: UUID?

    var onCompletion: ((UUID) async -> Void)?
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

    func begin(repo: String, alertID: UUID? = nil) async {
        guard !isRunning else { isPresented = true; return }
        generation = UUID()
        let request = generation
        self.repo = repo; self.alertID = alertID
        candidates = []; selectedPreviousPath = nil; review = nil
        activeRecordID = nil; error = nil; isLoading = true; isPresented = true
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
        guard !isRunning else { return }
        generation = UUID()
        let request = generation
        selectedPreviousPath = path; review = nil; activeRecordID = nil; error = nil
        guard let candidate = candidates.first(where: { $0.path == path }) else { isPreparing = false; return }
        isPreparing = true
        do {
            let prepared = try await api.prepare(repo, candidate)
            guard request == generation else { return }
            guard prepared.previous == candidate, prepared.repo.caseInsensitiveCompare(repo) == .orderedSame else {
                throw ModelUpdateError.invalid("The update preview no longer matches the selected previous model. Review it again.")
            }
            try prepared.validate()
            review = prepared
        } catch {
            if request == generation { self.error = AppHost.render(error) }
        }
        if request == generation { isPreparing = false }
    }

    /// Closing a preview never dismisses its Watch alert. In-flight operations finish
    /// under their captured review even if the presentation is closed.
    func close() {
        isPresented = false
        if !isRunning { generation = UUID(); isLoading = false; isPreparing = false }
    }

    @discardableResult
    func confirm(quarantinePrevious: Bool) async -> Bool {
        guard !isRunning, let review, hasLoadedHistory else { return false }
        isRunning = true; error = nil
        defer { isRunning = false }
        do {
            try review.validate()
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
                let installed = try await api.download(review)
                try installed.validate(for: review)
                record.installation = installed
                try await save(record)

                try await advance(&record, to: .verifying)
                try Task.checkCancellation()
                try await api.revalidate(review, .verify)
                try await api.verify(review, installed)

                try await advance(&record, to: .switching)
                try Task.checkCancellation()
                try await api.revalidate(review, .switchEndpoints)
                try await api.switchEndpoints(review, installed)

                if quarantinePrevious {
                    try await advance(&record, to: .quarantining)
                    try Task.checkCancellation()
                    try await api.revalidate(review, .quarantinePrevious)
                    try await api.quarantinePrevious(review, installed)
                }
                var completed = record
                completed.stage = .completed; completed.state = .completed
                completed.updatedAt = now()
                try await save(completed)
                if let alertID = completed.alertID { await onCompletion?(alertID) }
                return true
            } catch {
                record.state = error is CancellationError ? .interrupted : .failed
                record.error = AppHost.render(error); record.updatedAt = now()
                self.error = record.error
                do { try await save(record) } catch { self.error = persistenceError }
                return false
            }
        } catch {
            self.error = AppHost.render(error)
            return false
        }
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
                interrupted.error = "The update was interrupted during \(record.stage.title.lowercased()). Refresh the library and endpoints before reviewing another update."
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
