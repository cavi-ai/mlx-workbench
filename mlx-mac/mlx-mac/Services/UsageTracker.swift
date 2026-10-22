import Foundation

// MARK: - UsageTracker
//
// Last-used evidence per model path: stamped when a model is served,
// verified, or measured in a comparison. The Disk Pressure Advisor's
// staleness detector trusts this over file mtimes.

struct UsageStamp: Codable, Equatable, Sendable {
    let path: String
    var lastUsedAt: Date
    var lastServedAt: Date? = nil
}

@MainActor
final class UsageTracker: ObservableObject {
    @Published private(set) var lastUsedByPath: [String: Date] = [:]
    @Published private(set) var lastServedByPath: [String: Date] = [:]
    @Published private(set) var persistenceError: String?

    private let store: JSONStore<UsageStamp>
    private let now: () -> Date
    private let io = DispatchQueue(label: "usage-history", qos: .utility)
    private var historyTask: Task<Void, Never>?
    private var pendingWrite: Task<Bool, Never>?

    init(store: JSONStore<UsageStamp>, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        historyTask = Task { await loadHistory() }
    }

    func waitForHistory() async { await historyTask?.value }
    func waitForPersistence() async {
        await waitForHistory()
        _ = await pendingWrite?.value
    }

    private func loadHistory() async {
        defer { historyTask = nil }
        let store = store
        do {
            let saved = try await WorkbenchIO.perform(on: io) { Result { try store.load() } }.get()
            publish(saved)
        } catch {
            persistenceError = "Saved usage evidence is unavailable: \(AppHost.render(error))"
        }
    }

    @discardableResult
    func record(_ path: String) -> Task<Bool, Never> {
        persist(path, served: false)
    }

    @discardableResult
    func recordServed(_ path: String) -> Task<Bool, Never> {
        persist(path, served: true)
    }

    private func persist(_ path: String, served: Bool) -> Task<Bool, Never> {
        guard !path.isEmpty else { return Task { false } }
        let date = now()
        let previous = pendingWrite, store = store
        let task = Task {
            await waitForHistory()
            _ = await previous?.value
            do {
                let saved = try await WorkbenchIO.perform(on: io) { Result {
                    try store.mutate { values in
                        let index = values.firstIndex { $0.path == path }
                        let prior = index.map { values[$0] }
                        let stamp = UsageStamp(path: path, lastUsedAt: date, lastServedAt: served ? date : prior?.lastServedAt)
                        if let index { values[index] = stamp } else { values.append(stamp) }
                        return values
                    }
                } }.get()
                publish(saved)
                persistenceError = nil
                return true
            } catch {
                persistenceError = "Usage evidence could not be saved: \(AppHost.render(error))"
                return false
            }
        }
        pendingWrite = task
        return task
    }

    private func publish(_ saved: [UsageStamp]) {
        lastUsedByPath = Dictionary(saved.map { ($0.path, $0.lastUsedAt) }, uniquingKeysWith: { _, latest in latest })
        lastServedByPath = Dictionary(saved.compactMap { stamp in stamp.lastServedAt.map { (stamp.path, $0) } },
                                      uniquingKeysWith: { _, latest in latest })
    }
}
