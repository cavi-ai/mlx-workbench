import Foundation

struct ModelPurpose: Codable, Equatable, Sendable {
    let path: String
    let signature: String?
    let note: String
}

/// Explicit reasons for retaining models. Failed reads block changes and cleanup.
@MainActor
final class ModelPurposeStore: ObservableObject {
    @Published private(set) var records: [ModelPurpose] = []
    @Published private(set) var hasLoadedHistory = false
    @Published private(set) var isSaving = false
    @Published private(set) var error: String?
    var canEdit: () -> Bool = { true }
    private let store: JSONStore<ModelPurpose>
    private let io = DispatchQueue(label: "model-purposes", qos: .utility)
    private var loadTask: Task<Void, Never>?

    init(store: JSONStore<ModelPurpose> = JSONStore(fileURL: JSONStore<ModelPurpose>.defaultFileURL("model-purposes.json"))) {
        self.store = store
        loadTask = Task {
            do {
                records = try await WorkbenchIO.perform(on: io) { Result { try store.load() } }.get()
                hasLoadedHistory = true
            } catch { self.error = "Saved model purposes are unavailable: \(AppHost.render(error))" }
        }
    }

    func waitForHistory() async { await loadTask?.value }
    var protectedPaths: Set<String> { Set(records.map(\.path)) }
    func purpose(for path: String) -> ModelPurpose? { records.first { $0.path == path } }

    @discardableResult
    func save(path: String, signature: String?, note: String) async -> Bool {
        await waitForHistory()
        guard hasLoadedHistory, !isSaving else { return false }
        guard canEdit() else { error = "Wait for cleanup to finish before changing model purposes."; return false }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), note.count <= 500 else {
            error = "Choose a local model and keep its purpose within 500 characters."
            return false
        }
        isSaving = true
        defer { isSaving = false }
        let store = store
        do {
            let saved = try await WorkbenchIO.perform(on: io) { Result {
                try store.mutate { records in
                    records.removeAll { $0.path == path }
                    if !note.isEmpty { records.append(ModelPurpose(path: path, signature: signature, note: note)) }
                    return records
                }
            } }.get()
            records = saved; error = nil
            return true
        } catch { self.error = AppHost.render(error); return false }
    }
}
