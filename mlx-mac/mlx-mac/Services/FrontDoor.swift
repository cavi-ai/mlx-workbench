import Foundation

extension WorkbenchAPI {
    /// Runs the front door until it stops; it exits with the app through `--watch-parent`.
    func frontDoorRun(port: Int, keySHA256: String) async throws {
        _ = try await raw(["serve", "front-door", "--port", String(port), "--api-key-sha256", keySHA256, "--json", "--watch-parent"],
                          timeout: .infinity, cancellable: true)
    }
}

/// One model route advertised by the front door at `/v1/models`.
struct FrontDoorRoute: Equatable, Sendable, Identifiable {
    let id: String
    let taskKinds: [String]

    init(id: String, taskKinds: [String] = []) {
        self.id = id
        self.taskKinds = taskKinds
    }

    var isTyped: Bool { !taskKinds.isEmpty }
    var isChat: Bool { taskKinds.isEmpty }
}

/// Two or more enabled fleet slots sharing the front door key advertise the same model name,
/// which causes the front door to omit the model from `/v1/models` and return `409 ambiguous_model`.
struct FrontDoorCollision: Equatable, Sendable, Identifiable {
    let modelName: String
    let ports: [Int]
    var id: String { modelName }

    var warningMessage: String {
        let portList = ports.map { ":\($0)" }.joined(separator: ", ")
        return "Model \"\(modelName)\" is served by multiple Workbench API endpoints (\(portList)). Requests will fail with 409 ambiguous_model until only one endpoint uses the Workbench API key for this model."
    }
}

/// The app-owned front door while it answers authenticated model listings.
struct FrontDoorListener: Equatable, Sendable {
    let port: Int
    let apiKeySHA256: String
    let routes: [FrontDoorRoute]

    init(port: Int, apiKeySHA256: String, routes: [FrontDoorRoute]) {
        self.port = port
        self.apiKeySHA256 = apiKeySHA256
        self.routes = routes
    }

    init(port: Int, apiKeySHA256: String, models: [String]) {
        self.init(port: port, apiKeySHA256: apiKeySHA256, routes: models.map { FrontDoorRoute(id: $0) })
    }

    /// Chat-compatible model IDs (routes without typed `task_kinds`).
    var models: [String] { chatModels }
    var chatModels: [String] { routes.filter(\.isChat).map(\.id) }
    var typedRoutes: [FrontDoorRoute] { routes.filter(\.isTyped) }
    var allModelIDs: [String] { routes.map(\.id) }
    var apiBase: String { "http://127.0.0.1:\(port)/v1" }
}

/// Owns one `mlx-agent serve front-door` child on loopback. Routes and their lifecycle stay with each endpoint.
@MainActor
final class FrontDoorCoordinator: ObservableObject {
    typealias Run = @Sendable (_ port: Int, _ keySHA256: String) async throws -> Void
    typealias Routes = @Sendable (_ port: Int, _ token: String) async throws -> [FrontDoorRoute]
    typealias Models = @Sendable (_ port: Int, _ token: String) async throws -> [String]

    @Published private(set) var listening: FrontDoorListener?
    @Published private(set) var collisions: [FrontDoorCollision] = []
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    private let token: @Sendable (String) async throws -> String
    private let run: Run
    private let fetchRoutes: Routes
    private let portInUse: @Sendable (Int) async -> Bool
    private var session: Task<Void, Never>?
    private var endpointRefresh: Task<Void, Never>?
    private var generation = UUID()
    private var stopping = false

    init(api: WorkbenchAPI,
         token: @escaping @Sendable (String) async throws -> String = { hash in
             try await Task.detached(priority: .utility) { try EndpointCredentialStore.token(for: hash) }.value
         },
         run: Run? = nil,
         routes: @escaping Routes = FrontDoorCoordinator.liveRoutes,
         portInUse: @escaping @Sendable (Int) async -> Bool = FrontDoorCoordinator.livePortInUse) {
        self.token = token
        self.run = run ?? { port, key in try await api.frontDoorRun(port: port, keySHA256: key) }
        self.fetchRoutes = routes
        self.portInUse = portInUse
    }

    convenience init(api: WorkbenchAPI,
                     token: @escaping @Sendable (String) async throws -> String = { hash in
                         try await Task.detached(priority: .utility) { try EndpointCredentialStore.token(for: hash) }.value
                     },
                     run: Run? = nil,
                     models: @escaping Models,
                     portInUse: @escaping @Sendable (Int) async -> Bool = FrontDoorCoordinator.livePortInUse) {
        self.init(api: api, token: token, run: run,
                  routes: { port, key in try await models(port, key).map { FrontDoorRoute(id: $0) } },
                  portInUse: portInUse)
    }

    var isRunning: Bool { session != nil }

    /// The front door as a client address: defaults to the first chat-capable model while exposing all routed models.
    var endpoint: WireEndpoint? {
        guard session != nil, let listening, let firstChat = listening.chatModels.first else { return nil }
        return WireEndpoint(baseURL: listening.apiBase, modelName: firstChat, apiKeySHA256: listening.apiKeySHA256, models: listening.allModelIDs)
    }

    func updateCollisions(slots: [EndpointSlot], frontDoorKeySHA256: String?) {
        let updated = Self.detectCollisions(slots: slots, frontDoorKeySHA256: frontDoorKeySHA256)
        if collisions != updated { collisions = updated }
    }

    func start(_ settings: FrontDoorSettings) async {
        guard !busy, session == nil else { return }
        busy = true; error = nil
        defer { busy = false }
        let port = settings.port, digest = settings.apiKeySHA256
        guard !(await portInUse(port)) else {
            error = "Port \(port) is in use on 127.0.0.1. Choose another Workbench API port."; return
        }
        let key: String
        do { key = try await token(digest) }
        catch { self.error = "The Workbench API key is unavailable in Keychain."; return }
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
            if let discovered = try? await fetchRoutes(port, key), session != nil, generation == id {
                listening = FrontDoorListener(port: port, apiKeySHA256: digest, routes: discovered); return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if session != nil, generation == id {
            await end()
            error = "The Workbench API did not answer on port \(port). Start it again."
        }
    }

    /// Read the routed models again; endpoints join and leave as they start and stop.
    func refresh() async {
        guard !busy, session != nil, let current = listening else { return }
        busy = true; defer { busy = false }
        do {
            let discovered = try await fetchRoutes(current.port, try await token(current.apiKeySHA256))
            if session != nil, listening == current { listening = FrontDoorListener(port: current.port, apiKeySHA256: current.apiKeySHA256, routes: discovered) }
            error = nil
        } catch { self.error = "The Workbench API model list is unavailable: \(AppHost.render(error))" }
    }

    func refreshAfterEndpointChange() {
        endpointRefresh?.cancel()
        guard listening != nil else { return }
        let id = generation
        endpointRefresh = Task { [weak self] in
            // A model-list read can start discovery and still return cached routes.
            // Give the engine's five-second cache and twelve-second discovery wait time to elapse.
            let delays: [Duration] = [.zero, .milliseconds(5_100), .seconds(1), .seconds(12)]
            for delay in delays {
                if delay != .zero {
                    do { try await Task.sleep(for: delay) }
                    catch { return }
                }
                guard !Task.isCancelled, let self, self.generation == id else { return }
                await self.refresh()
            }
        }
    }

    func stop() async {
        guard !busy, session != nil else { return }
        busy = true; defer { busy = false }
        await end()
        error = nil
    }

    private func end() async {
        let running = session
        endpointRefresh?.cancel(); endpointRefresh = nil
        stopping = true; generation = UUID(); session = nil; listening = nil
        running?.cancel()
        await running?.value
        stopping = false
    }

    private func ended(_ failure: Error?) {
        endpointRefresh?.cancel(); endpointRefresh = nil
        session = nil; listening = nil
        guard !stopping else { return }
        if let failure, !(failure is CancellationError) {
            let bridge = failure as? BridgeError
            error = bridge?.errorDescription ?? AppHost.render(failure)
        } else {
            error = "The Workbench API stopped. Start it again."
        }
    }

    /// Mirrors `mlx_agent.jit_serve.public_model_name` so collision checks match backend route table keys.
    nonisolated static func publicModelName(for localPath: String) -> String {
        let trimmed = localPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let url = URL(fileURLWithPath: trimmed).standardized
        let parent = url.deletingLastPathComponent()
        let grandParent = parent.deletingLastPathComponent()
        if parent.lastPathComponent == "snapshots",
           grandParent.lastPathComponent.hasPrefix("models--") {
            let suffix = String(grandParent.lastPathComponent.dropFirst("models--".count))
            return suffix.replacingOccurrences(of: "--", with: "/")
        }
        return url.lastPathComponent
    }

    /// Detects duplicate public model names among enabled fleet slots sharing the front door key digest.
    nonisolated static func detectCollisions(slots: [EndpointSlot], frontDoorKeySHA256: String?) -> [FrontDoorCollision] {
        guard let digest = frontDoorKeySHA256, !digest.isEmpty else { return [] }
        var portsByModel: [String: [Int]] = [:]
        for slot in slots where slot.enabled && slot.apiKeySHA256 == digest {
            let name = publicModelName(for: slot.modelPath)
            guard !name.isEmpty else { continue }
            portsByModel[name, default: []].append(slot.port)
        }
        return portsByModel.compactMap { modelName, ports in
            guard ports.count > 1 else { return nil }
            return FrontDoorCollision(modelName: modelName, ports: ports.sorted())
        }
        .sorted { $0.modelName < $1.modelName }
    }

    nonisolated static func parseRoutes(from data: Data) throws -> [FrontDoorRoute] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else { throw HostHTTPError.invalidResponse }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let rawKinds = row["task_kinds"] as? [Any] ?? []
            let taskKinds = rawKinds.compactMap { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } }
            return FrontDoorRoute(id: id, taskKinds: taskKinds)
        }
    }

    nonisolated static let liveRoutes: Routes = { port, token in
        let host = ModelHost(name: "Workbench API", provider: .openAICompatible, baseURL: "http://127.0.0.1:\(port)")
        let data = try await HostHTTPClient().request(host: host, path: "v1/models", token: token, maximumBytes: 1_048_576, timeout: 5)
        return try parseRoutes(from: data)
    }

    nonisolated static let liveModels: Models = { port, token in
        try await liveRoutes(port, token).filter(\.isChat).map(\.id)
    }

    nonisolated static let livePortInUse: @Sendable (Int) async -> Bool = { port in
        let host = ModelHost(name: "Workbench API", provider: .openAICompatible, baseURL: "http://127.0.0.1:\(port)")
        do { _ = try await HostHTTPClient().request(host: host, path: "health", maximumBytes: 4_096, timeout: 2); return true }
        catch HostHTTPError.requestFailed { return false }
        catch { return true }
    }
}
