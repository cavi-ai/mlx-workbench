import Foundation

extension WorkbenchAPI {
    /// Runs the front door until it stops; it exits with the app through `--watch-parent`.
    func frontDoorRun(port: Int, keySHA256: String) async throws {
        _ = try await raw(["serve", "front-door", "--port", String(port), "--api-key-sha256", keySHA256, "--json", "--watch-parent"],
                          timeout: .infinity, cancellable: true)
    }
}

/// The app-owned front door while it answers authenticated model listings.
struct FrontDoorListener: Equatable, Sendable {
    let port: Int
    let apiKeySHA256: String
    let models: [String]
    var apiBase: String { "http://127.0.0.1:\(port)/v1" }
}

/// Owns one `mlx-agent serve front-door` child on loopback. Routes and their lifecycle stay with each endpoint.
@MainActor
final class FrontDoorCoordinator: ObservableObject {
    typealias Run = @Sendable (_ port: Int, _ keySHA256: String) async throws -> Void
    typealias Models = @Sendable (_ port: Int, _ token: String) async throws -> [String]

    @Published private(set) var listening: FrontDoorListener?
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    private let token: @Sendable (String) async throws -> String
    private let run: Run
    private let models: Models
    private let portInUse: @Sendable (Int) async -> Bool
    private var session: Task<Void, Never>?
    private var generation = UUID()
    private var stopping = false

    init(api: WorkbenchAPI,
         token: @escaping @Sendable (String) async throws -> String = { hash in
             try await Task.detached(priority: .utility) { try EndpointCredentialStore.token(for: hash) }.value
         },
         run: Run? = nil,
         models: @escaping Models = FrontDoorCoordinator.liveModels,
         portInUse: @escaping @Sendable (Int) async -> Bool = FrontDoorCoordinator.livePortInUse) {
        self.token = token
        self.run = run ?? { port, key in try await api.frontDoorRun(port: port, keySHA256: key) }
        self.models = models
        self.portInUse = portInUse
    }

    var isRunning: Bool { session != nil }

    /// The front door as a client address: every routed model, the first as the default.
    var endpoint: WireEndpoint? {
        guard session != nil, let listening, let first = listening.models.first else { return nil }
        return WireEndpoint(baseURL: listening.apiBase, modelName: first, apiKeySHA256: listening.apiKeySHA256, models: listening.models)
    }

    func start(_ settings: FrontDoorSettings) async {
        guard !busy, session == nil else { return }
        busy = true; error = nil
        defer { busy = false }
        let port = settings.port, digest = settings.apiKeySHA256
        guard !(await portInUse(port)) else {
            error = "Port \(port) is in use on 127.0.0.1. Choose another front door port."; return
        }
        let key: String
        do { key = try await token(digest) }
        catch { self.error = "The front door key is unavailable in Keychain."; return }
        let id = UUID(); generation = id
        session = Task { [weak self, run] in
            do {
                try await run(port, digest)
                guard let self, self.generation == id else { return }
                self.ended(nil)
            } catch {
                guard let self, self.generation == id else { return }
                self.ended(error)
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while session != nil, generation == id, ProcessInfo.processInfo.systemUptime < deadline {
            if let names = try? await models(port, key), session != nil, generation == id {
                listening = FrontDoorListener(port: port, apiKeySHA256: digest, models: names); return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if session != nil, generation == id {
            await end()
            error = "The front door did not answer on port \(port). Start it again."
        }
    }

    /// Read the routed models again; endpoints join and leave as they start and stop.
    func refresh() async {
        guard !busy, session != nil, let current = listening else { return }
        busy = true; defer { busy = false }
        do {
            let names = try await models(current.port, try await token(current.apiKeySHA256))
            if session != nil, listening == current { listening = FrontDoorListener(port: current.port, apiKeySHA256: current.apiKeySHA256, models: names) }
            error = nil
        } catch { self.error = "The front door model list is unavailable: \(AppHost.render(error))" }
    }

    func stop() async {
        guard !busy, session != nil else { return }
        busy = true; defer { busy = false }
        await end()
        error = nil
    }

    private func end() async {
        let running = session
        stopping = true; generation = UUID(); session = nil; listening = nil
        running?.cancel()
        await running?.value
        stopping = false
    }

    private func ended(_ failure: Error?) {
        session = nil; listening = nil
        guard !stopping else { return }
        if let failure, !(failure is CancellationError) {
            let bridge = failure as? BridgeError
            error = bridge?.errorDescription ?? AppHost.render(failure)
        } else {
            error = "The front door stopped. Start it again."
        }
    }

    nonisolated static let liveModels: Models = { port, token in
        let host = ModelHost(name: "Front door", provider: .openAICompatible, baseURL: "http://127.0.0.1:\(port)")
        let data = try await HostHTTPClient().request(host: host, path: "v1/models", token: token, maximumBytes: 1_048_576, timeout: 5)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else { throw HostHTTPError.invalidResponse }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty, (row["task_kinds"] as? [Any])?.isEmpty ?? true else { return nil }
            return id
        }
    }

    nonisolated static let livePortInUse: @Sendable (Int) async -> Bool = { port in
        let host = ModelHost(name: "Front door", provider: .openAICompatible, baseURL: "http://127.0.0.1:\(port)")
        do { _ = try await HostHTTPClient().request(host: host, path: "health", maximumBytes: 4_096, timeout: 2); return true }
        catch HostHTTPError.requestFailed { return false }
        catch { return true }
    }
}
