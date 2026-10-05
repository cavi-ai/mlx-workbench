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

    init(store: JSONStore<UsageStamp>, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        do {
            for stamp in try store.load() {
                lastUsedByPath[stamp.path] = stamp.lastUsedAt
                lastServedByPath[stamp.path] = stamp.lastServedAt
            }
        } catch {
            persistenceError = "Saved usage evidence is unavailable: \(AppHost.render(error))"
        }
    }

    func record(_ path: String) {
        guard !path.isEmpty else { return }
        persist(path, served: false)
    }

    func recordServed(_ path: String) {
        guard !path.isEmpty else { return }
        persist(path, served: true)
    }

    private func persist(_ path: String, served: Bool) {
        let date = now()
        let stamp = UsageStamp(path: path, lastUsedAt: date, lastServedAt: served ? date : lastServedByPath[path])
        lastUsedByPath[path] = stamp.lastUsedAt
        lastServedByPath[path] = stamp.lastServedAt
        do {
            try store.upsert(stamp, id: \.path)
        } catch {
            persistenceError = "Usage evidence could not be saved: \(AppHost.render(error))"
        }
    }
}
