import Combine
import Foundation

@MainActor
final class HealthBackendSession: ObservableObject {
    struct Snapshot {
        let list: BackendList
        let checkedAt: Date
    }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var error: String?
    @Published private(set) var isRefreshing = false
    private let fetch: () async throws -> BackendList
    private let now: () -> Date
    private var source: String?
    private var generation = 0

    init(fetch: @escaping () async throws -> BackendList, now: @escaping () -> Date = Date.init) {
        self.fetch = fetch
        self.now = now
    }

    var checkedAt: Date? { snapshot?.checkedAt }
    var rows: [HealthBackendRow] {
        snapshot?.list.backends.filter { !$0.builtin }.map(HealthBackendRow.init) ?? []
    }
    var isStale: Bool { snapshot != nil && (error != nil || isRefreshing) }

    func refresh(source: String) async {
        if self.source != source {
            self.source = source
            generation += 1
            snapshot = nil
            error = nil
            isRefreshing = false
        }
        guard !isRefreshing else { return }
        let generation = generation
        isRefreshing = true
        error = nil
        defer { if self.generation == generation { isRefreshing = false } }
        do {
            let list = try await fetch()
            guard self.generation == generation else { return }
            guard list.schema == "backends/1",
                  Set(list.backends.map(\.id)).count == list.backends.count,
                  list.backends.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw BridgeError.skillOutputUnreadable
            }
            snapshot = Snapshot(list: list, checkedAt: now())
        } catch {
            guard self.generation == generation else { return }
            self.error = AppHost.render(error)
        }
    }
}
