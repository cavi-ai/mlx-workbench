import Foundation

// MARK: - UsageTracker
//
// Last-used evidence per model path: stamped when a model is served,
// verified, or measured in a comparison. The Disk Pressure Advisor's
// staleness detector trusts this over file mtimes.

struct UsageStamp: Codable, Equatable, Sendable {
    let path: String
    var lastUsedAt: Date
}

@MainActor
final class UsageTracker: ObservableObject {
    @Published private(set) var lastUsedByPath: [String: Date] = [:]
    @Published private(set) var persistenceError: String?

    private let store: JSONStore<UsageStamp>
    private let now: () -> Date

    init(store: JSONStore<UsageStamp>, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        do {
            lastUsedByPath = Dictionary(
                uniqueKeysWithValues: try store.load().map { ($0.path, $0.lastUsedAt) }
            )
        } catch {
            persistenceError = "Saved usage evidence is unavailable: \(AppHost.render(error))"
        }
    }

    func record(_ path: String) {
        guard !path.isEmpty else { return }
        let stamp = UsageStamp(path: path, lastUsedAt: now())
        lastUsedByPath[path] = stamp.lastUsedAt
        do {
            try store.upsert(stamp, id: \.path)
        } catch {
            persistenceError = "Usage evidence could not be saved: \(AppHost.render(error))"
        }
    }
}
