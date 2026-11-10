import Combine
import Foundation

@MainActor
final class ServedTaskSessions: ObservableObject {
    @Published private(set) var origins: [ServedTaskOrigin] = []
    @Published private(set) var error: String?
    private let engine: WorkbenchAPI
    private let store: ServedTaskStore
    private let client: ServedTaskClient
    private var sessions: [String: InferenceTaskCoordinator] = [:]
    private var observations: [String: AnyCancellable] = [:]
    private var loaded = false

    init(engine: WorkbenchAPI, store: ServedTaskStore = ServedTaskStore(), client: ServedTaskClient? = nil) {
        self.engine = engine; self.store = store; self.client = client ?? .live(api: engine)
    }

    var activeModelPaths: Set<String> {
        sessions.reduce(into: Set<String>()) { paths, entry in
            paths.formUnion(entry.value.activeModelPaths)
            if entry.value.busy || entry.value.startOutcomeUnknown,
               let path = origins.first(where: { $0.id == entry.key })?.server.path { paths.insert(path) }
        }
    }

    func load() async {
        guard !loaded else { return }
        do {
            let entries = try await store.entries()
            for entry in entries { install(entry) }
            loaded = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func refreshHistories() async {
        await load()
        for session in sessions.values { await session.refreshRecent() }
    }

    func coordinator(for origin: ServedTaskOrigin) -> InferenceTaskCoordinator? { sessions[origin.id] }

    func select(_ origin: ServedTaskOrigin) async throws -> InferenceTaskCoordinator {
        await load()
        try await store.register(origin)
        let entry = try await store.entry(origin)
        install(entry)
        return sessions[origin.id]!
    }

    /// This acknowledges uncertainty only; it never retries the request.
    func allowAnotherSubmission(_ origin: ServedTaskOrigin) async throws {
        try await store.resolve(origin)
        sessions[origin.id]?.setSubmissionUnresolved(false)
    }

    private func install(_ entry: ServedTaskEntry) {
        guard sessions[entry.origin.id] == nil else { return }
        let api = ServedTaskAPI(origin: entry.origin, engine: engine, store: store, client: client)
        let coordinator = InferenceTaskCoordinator(api: api, artifactRoot: entry.origin.artifactRoot,
                                                   clearsUncertainStartOnRefresh: false)
        coordinator.seedHistory(entry.records, submissionUnresolved: entry.submissionUnresolved)
        sessions[entry.origin.id] = coordinator
        observations[entry.origin.id] = coordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        origins.append(entry.origin)
    }
}
