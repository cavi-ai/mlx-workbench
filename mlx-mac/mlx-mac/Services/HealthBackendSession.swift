import Combine
import Foundation

/// An explicit Library → Health → Library intent, never a request to execute a model.
struct ModelRuntimeRecoveryRequest: Equatable, Identifiable {
    let id = UUID()
    let modelPath: String
    let modelName: String
    let backendID: String
    private let signature: String?
    private let task: ModelTask?

    init?(model: LibraryModel) {
        guard model.readiness == .needsRuntime, let backend = model.item.backend,
              !backend.installed, !backend.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        modelPath = model.item.path
        modelName = model.displayName
        backendID = backend.id
        signature = model.item.signature
        task = model.item.task
    }

    func matches(_ model: LibraryModel) -> Bool {
        model.item.path == modelPath && model.item.signature == signature
            && model.item.task == task && model.item.backend?.id == backendID
    }
}

@MainActor
final class ModelRuntimeRecoverySession: ObservableObject {
    struct InstallPlan {
        let version: String
        let target: String
        let package: String
        let network: [String]
        let hash: String
    }

    @Published private(set) var request: ModelRuntimeRecoveryRequest?
    @Published private(set) var backend: BackendEntry?
    @Published private(set) var plan: InstallPlan?
    @Published private(set) var error: String?
    @Published private(set) var isBusy = false
    @Published private(set) var installationLog: BackendInstallLog?
    @Published private(set) var isReadingLog = false
    private(set) var source: String?
    private var generation = 0
    private let fetch: () async throws -> BackendList
    private let preview: (String) async throws -> [String: Any]
    private let start: (String, String) async throws -> Void
    private let pollInterval: Duration
    private let pollLimit: Int
    private let readLog: (String) async -> BackendInstallLog

    init(fetch: @escaping () async throws -> BackendList,
         preview: @escaping (String) async throws -> [String: Any],
         start: @escaping (String, String) async throws -> Void,
         pollInterval: Duration = .seconds(2), pollLimit: Int = 1800,
         readLog: @escaping (String) async -> BackendInstallLog = { path in
             await Task.detached(priority: .utility) { BackendInstallLog.read(path: path) }.value
         }) {
        self.fetch = fetch
        self.preview = preview
        self.start = start
        self.pollInterval = pollInterval
        self.pollLimit = pollLimit
        self.readLog = readLog
    }

    var canReview: Bool {
        !isBusy && backend?.builtin == false && (backend?.state == .absent || backend?.state == .failed)
    }

    func check(request: ModelRuntimeRecoveryRequest, source: String) async {
        if self.request?.id == request.id, self.source == source, isBusy { return }
        generation += 1
        clearLog()
        let token = generation
        self.request = request
        self.source = source
        backend = nil
        plan = nil
        error = nil
        isBusy = true
        defer { if generation == token { isBusy = false } }
        do {
            let entry = try await entry(for: request.backendID)
            guard generation == token else { return }
            backend = entry
        } catch { if generation == token { self.error = AppHost.render(error) } }
    }

    func cancelReview() { plan = nil }

    func loadInstallationLog(isCurrent: () -> Bool) async {
        guard !isBusy, !isReadingLog, isCurrent(), let backend,
              let path = backend.logPath, !path.isEmpty else { return }
        let token = generation
        isReadingLog = true
        installationLog = nil
        defer { if generation == token { isReadingLog = false } }
        let log = await readLog(path)
        guard generation == token, self.backend == backend, isCurrent() else { return }
        installationLog = log
    }

    private func clearLog() {
        installationLog = nil
        isReadingLog = false
    }

    func review(isCurrent: () -> Bool) async {
        guard canReview, let request else { return }
        generation += 1
        clearLog()
        let token = generation
        isBusy = true
        error = nil
        plan = nil
        defer { if generation == token { isBusy = false } }
        do {
            try requireCurrent(token, isCurrent)
            let entry = try await entry(for: request.backendID)
            try requireCurrent(token, isCurrent)
            backend = entry
            guard !entry.builtin, entry.state == .absent || entry.state == .failed else {
                throw RecoveryError("Refresh requirements before installing this backend.")
            }
            let raw = try await preview(request.backendID)
            try requireCurrent(token, isCurrent)
            guard raw["id"] as? String == request.backendID,
                  let hash = nonempty(raw["preview_hash"]), let version = nonempty(raw["version"]),
                  let target = nonempty(raw["target"]), target.hasPrefix("/"),
                  let package = nonempty(raw["package"]), let network = raw["network"] as? [String] else {
                throw RecoveryError("The backend installation preview is incomplete. Review it again before installing.")
            }
            plan = InstallPlan(version: version, target: target, package: package, network: network, hash: hash)
        } catch { if generation == token { self.error = AppHost.render(error) } }
    }

    func install(isCurrent: () -> Bool) async {
        guard !isBusy, let request, let plan else { return }
        generation += 1
        clearLog()
        let token = generation
        self.plan = nil // Every retry needs a fresh reviewed preview, including a failed start.
        error = nil
        isBusy = true
        defer { if generation == token { isBusy = false } }
        do {
            try requireCurrent(token, isCurrent)
            try await start(request.backendID, plan.hash)
            for _ in 0..<pollLimit {
                try requireCurrent(token, isCurrent)
                let entry = try await entry(for: request.backendID)
                try requireCurrent(token, isCurrent)
                backend = entry
                switch entry.state {
                case .installed: return
                case .installing: try await Task.sleep(for: pollInterval)
                case .failed, .absent:
                    throw RecoveryError("Installing \(request.backendID) failed. Review a new preview to retry.\(entry.logPath.map { " Log: " + $0 } ?? "")")
                case .unknown:
                    throw RecoveryError("The backend returned an unknown installation state. Refresh requirements before retrying.")
                }
            }
            throw RecoveryError("Installation is still pending. Refresh requirements to check its status; no second installation was started.")
        } catch { if generation == token { self.error = AppHost.render(error) } }
    }

    private func entry(for id: String) async throws -> BackendEntry {
        let list = try await fetch()
        guard list.schema == "backends/1", Set(list.backends.map(\.id)).count == list.backends.count,
              let entry = list.backends.first(where: { $0.id == id }) else {
            throw RecoveryError("The selected engine did not report this model's backend. Check the engine in Settings, then refresh requirements.")
        }
        return entry
    }

    private func requireCurrent(_ token: Int, _ isCurrent: () -> Bool) throws {
        guard generation == token, isCurrent() else {
            throw RecoveryError("The model or engine changed. Select the model again in Library before repairing its runtime.")
        }
    }

    private func nonempty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private struct RecoveryError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

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
