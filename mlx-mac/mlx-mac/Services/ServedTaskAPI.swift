import CryptoKit
import Foundation

/// A task destination names one process, not whichever server later occupies its port.
struct ServedTaskOrigin: Codable, Equatable, Identifiable, Sendable {
    let server: ServerInfo
    let id: String
    var artifactRoot: URL {
        URL(fileURLWithPath: server.receiptsDirectory!, isDirectory: true)
            .appendingPathComponent(".mlx-agent-receipts/tasks/\(server.port!)", isDirectory: true)
    }

    init(server: ServerInfo) throws {
        guard server.runtime == "tasks", server.state == "running", (server.pid ?? 0) > 0,
              let port = server.port, (1...65535).contains(port),
              let path = server.path, Self.absolute(path),
              let directory = server.receiptsDirectory, Self.absolute(directory),
              let receipt = server.receipt, Self.absolute(receipt),
              receipt == URL(fileURLWithPath: directory).appendingPathComponent(".mlx-agent-receipts/serve/\(port).json").path,
              let started = server.processStartedAt, !started.isEmpty,
              let launched = server.startedAt, !launched.isEmpty,
              let kinds = server.taskKinds, !kinds.isEmpty, Set(kinds).count == kinds.count,
              server.adapterPath == nil, server.adapterIdentity == nil, server.trainingBinding == nil,
              server.apiKeySHA256.map({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) ?? true else {
            throw ServedTaskError.changed
        }
        self.server = server
        let identity = [receipt, directory, path, server.modelIdentity, String(port), String(server.pid!), started, launched,
                        server.apiKeySHA256 ?? "", kinds.sorted().joined(separator: ",")]
        id = SHA256.hash(data: try JSONEncoder().encode(identity)).map { String(format: "%02x", $0) }.joined()
    }

    func matches(_ current: ServerInfo) -> Bool {
        current.state == "running" && server.sameProcess(as: current) && server.path == current.path
            && server.receiptsDirectory == current.receiptsDirectory && server.taskKinds == current.taskKinds
    }

    func validate(_ record: TaskRecord, fullIdentity: Bool = true) throws {
        guard let uuid = UUID(uuidString: record.id), uuid.uuidString.lowercased() == record.id,
              record.isSupported, record.modelPath == server.path,
              server.taskKinds?.contains(record.kind.wireValue) == true,
              record.supervisor?.pid == server.pid else { throw ServedTaskError.foreignTask }
        if fullIdentity {
            guard let identity = record.supervisor?.identity, let started = server.processStartedAt,
                  identity.hasPrefix(started + " ") else { throw ServedTaskError.foreignTask }
        }
        let request = artifactRoot.appendingPathComponent("artifacts/\(record.id)/request.json").path
        guard record.request.path == request else { throw ServedTaskError.foreignTask }
    }

    private static func absolute(_ path: String) -> Bool {
        path.hasPrefix("/") && URL(fileURLWithPath: path).standardizedFileURL.path == path
            && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

enum ServedTaskError: LocalizedError {
    case changed, foreignTask, busy, unresolved, key, unsupported
    var errorDescription: String? {
        switch self {
        case .changed: "The selected server changed or is unavailable. Choose its current endpoint to start a new job. Recorded jobs remain attached to the original server."
        case .foreignTask: "This job does not belong to the selected server process."
        case .busy: "This server is busy. Wait for its active job to finish, then try again. Your inputs are retained."
        case .unresolved: "A previous submission was not confirmed. Review Recent tasks before allowing another submission."
        case .key: "The inference API key is unavailable or does not match this endpoint. Configure its key in Run."
        case .unsupported: "This endpoint does not advertise the selected model and task type. Refresh serving status."
        }
    }
}

struct ServedTaskEntry: Codable, Sendable {
    let origin: ServedTaskOrigin
    var records: [TaskRecord] = []
    var submissionID: UUID?
    var submissionUnresolved: Bool { submissionID != nil }
}

/// App-owned origin evidence only. Task execution, records and artifacts stay engine-owned.
actor ServedTaskStore {
    private let store: JSONStore<ServedTaskEntry>
    init(url: URL = JSONStore<ServedTaskEntry>.defaultFileURL("task-endpoints.json")) { store = JSONStore(fileURL: url) }
    func entries() throws -> [ServedTaskEntry] {
        try store.load().map { entry in
            guard try ServedTaskOrigin(server: entry.origin.server) == entry.origin else { throw ServedTaskError.changed }
            for record in entry.records { try entry.origin.validate(record) }
            return entry
        }
    }
    func entry(_ origin: ServedTaskOrigin) throws -> ServedTaskEntry {
        try entries().first { $0.origin.id == origin.id } ?? ServedTaskEntry(origin: origin)
    }
    func register(_ origin: ServedTaskOrigin) throws {
        _ = try entries()
        try store.mutate { entries in
            if !entries.contains(where: { $0.origin.id == origin.id }) { entries.append(ServedTaskEntry(origin: origin)) }
        }
    }
    func begin(_ origin: ServedTaskOrigin) throws -> UUID {
        try register(origin)
        let submissionID = UUID()
        try store.mutate { entries in
            let index = entries.firstIndex { $0.origin.id == origin.id }!
            guard !entries[index].submissionUnresolved else { throw ServedTaskError.unresolved }
            entries[index].submissionID = submissionID
        }
        return submissionID
    }
    func resolve(_ origin: ServedTaskOrigin, submissionID: UUID? = nil) throws {
        try store.mutate { entries in
            guard let index = entries.firstIndex(where: { $0.origin.id == origin.id }) else { return }
            if submissionID == nil || entries[index].submissionID == submissionID { entries[index].submissionID = nil }
        }
    }
    func remember(_ record: TaskRecord, origin: ServedTaskOrigin, resolvingSubmission: UUID? = nil) throws {
        try remember([record], origin: origin, resolvingSubmission: resolvingSubmission)
    }
    func remember(_ records: [TaskRecord], origin: ServedTaskOrigin, resolvingSubmission: UUID? = nil) throws {
        for record in records { try origin.validate(record) }
        try register(origin)
        try store.mutate { entries in
            let index = entries.firstIndex { $0.origin.id == origin.id }!
            let ids = Set(records.map(\.id))
            entries[index].records.removeAll { ids.contains($0.id) }
            entries[index].records.append(contentsOf: records)
            if let resolvingSubmission, entries[index].submissionID == resolvingSubmission { entries[index].submissionID = nil }
        }
    }
}

struct ServedTaskClient: Sendable {
    var servers: @Sendable (String) async throws -> [ServerInfo]
    var credential: @Sendable (String) async throws -> String
    var request: @Sendable (ServerInfo, String, String, Data?, String?) async throws -> Data
    static func live(api: WorkbenchAPI) -> Self {
        Self(servers: { try await api.serveStatus(receiptsDirectory: $0) }, credential: { hash in
            try await Task.detached(priority: .utility) { try EndpointCredentialStore.token(for: hash) }.value
        }, request: { server, path, method, body, token in
            let host = ModelHost(name: "Model jobs", provider: .openAICompatible, baseURL: "http://127.0.0.1:\(server.port ?? 0)")
            return try await HostHTTPClient().request(host: host, path: path, method: method, body: body,
                                                      token: token, maximumBytes: 1_048_576, timeout: method == "GET" ? 5 : 120)
        })
    }
}

struct ServedTaskAPI: InferenceTaskAPI {
    let origin: ServedTaskOrigin
    let engine: WorkbenchAPI
    let store: ServedTaskStore
    let client: ServedTaskClient

    func taskCapabilities() async throws -> TaskCapabilities {
        guard try await !store.entry(origin).submissionUnresolved else { throw TaskStartOutcomeUnknown() }
        let kinds = try await advertisedKinds()
        let capabilities = try await engine.taskCapabilities()
        return TaskCapabilities(schema: capabilities.schema, requestSchema: capabilities.requestSchema,
                                runSchema: capabilities.runSchema, tasks: capabilities.tasks.filter { kinds.contains($0.kind.wireValue) })
    }

    func taskMediaCapabilities(modelPath: String) async throws -> TaskCapabilities {
        guard Quarantine.resolve(modelPath) == Quarantine.resolve(origin.server.path!) else { throw ServedTaskError.foreignTask }
        let kinds = try await advertisedKinds()
        let capabilities = try await engine.taskMediaCapabilities(modelPath: modelPath)
        return TaskCapabilities(schema: capabilities.schema, requestSchema: capabilities.requestSchema,
                                runSchema: capabilities.runSchema, tasks: capabilities.tasks.filter { kinds.contains($0.kind.wireValue) },
                                model: capabilities.model)
    }

    func taskStart(_ request: TaskRequest) async throws -> TaskRecord {
        try request.validate()
        guard Quarantine.resolve(request.modelPath) == Quarantine.resolve(origin.server.path!) else { throw ServedTaskError.foreignTask }
        let token = try await authorization()
        let kinds = try await advertisedKinds(token: token)
        guard kinds.contains(request.kind.wireValue) else { throw ServedTaskError.unsupported }
        let body = try JSONEncoder().encode(["kind": JSONValue.string(request.kind.wireValue), "parameters": .object(request.parameters)])
        try await checkIdentity()
        let submissionID: UUID
        do { submissionID = try await store.begin(origin) }
        catch ServedTaskError.unresolved { throw TaskStartOutcomeUnknown() }
        do {
            let data = try await client.request(origin.server, "/v1/tasks", "POST", body, token)
            let record = try JSONDecoder().decode(TaskRecord.self, from: data)
            try origin.validate(record)
            guard record.kind == request.kind else { throw ServedTaskError.foreignTask }
            try await store.remember(record, origin: origin, resolvingSubmission: submissionID)
            return record
        } catch let error as HostHTTPError {
            if case .httpStatus(let status) = error, [400, 401, 403, 404, 409, 422].contains(status) {
                try await store.resolve(origin, submissionID: submissionID)
                if status == 409 { throw ServedTaskError.busy }
                throw error
            }
            throw TaskStartOutcomeUnknown()
        } catch { throw TaskStartOutcomeUnknown() }
    }

    func taskList(limit: Int) async throws -> TaskPage {
        guard (1...100).contains(limit) else { throw TaskProtocolError.invalidRequest }
        let saved = try await store.entry(origin)
        let page = try await engine.taskList(limit: limit, stateDirectory: origin.artifactRoot)
        var records = saved.records
        // A replaced server can push an older active job out of the bounded page.
        // Reconcile that job by its already verified ID instead of retaining a stale claim.
        let listed = Set(page.tasks.map(\.id))
        for known in saved.records where known.state.isActive && !listed.contains(known.id) {
            let summary = try await engine.taskStatus(id: known.id, stateDirectory: origin.artifactRoot)
            try validateSummary(summary, known: known)
            let updated = try restoringOwner(summary, known: known)
            records.removeAll { $0.id == known.id }; records.append(updated)
        }
        var token: String?
        let canDiscover: Bool
        do { token = try await authorization(); _ = try await advertisedKinds(token: token); canDiscover = true }
        catch { canDiscover = false }
        for summary in page.tasks {
            if let known = saved.records.first(where: { $0.id == summary.id }) {
                try validateSummary(summary, known: known)
                // Keep the process evidence stripped from CLI summaries.
                records.removeAll { $0.id == known.id }
                let updated = try restoringOwner(summary, known: known)
                records.append(updated)
            } else if canDiscover, summary.modelPath == origin.server.path, summary.supervisor?.pid == origin.server.pid {
                // Never bind a port's old jobs to its replacement process.
                guard let record = try? await remoteRecord(summary.id, token: token) else { continue }
                records.append(record)
            }
        }
        if !records.isEmpty { try await store.remember(records, origin: origin) }
        records.sort { $0.createdAt > $1.createdAt }
        return TaskPage(tasks: Array(records.prefix(limit)), hasMore: page.hasMore || records.count > limit)
    }

    func taskStatus(id: String) async throws -> TaskRecord {
        let known = try await boundRecord(id)
        let record = try await engine.taskStatus(id: id, stateDirectory: origin.artifactRoot)
        try validateSummary(record, known: known)
        let restored = try restoringOwner(record, known: known)
        try await store.remember(restored, origin: origin)
        return restored
    }
    func taskResult(id: String) async throws -> TaskResultResponse {
        let known = try await boundRecord(id)
        let result = try await engine.taskResult(id: id, stateDirectory: origin.artifactRoot)
        try validateSummary(result.task, known: known)
        return result
    }
    func taskVerifyModel(id: String) async throws -> TaskModelVerification {
        _ = try await taskStatus(id: id)
        return try await engine.taskVerifyModel(id: id, stateDirectory: origin.artifactRoot)
    }
    func taskCancel(id: String) async throws -> TaskRecord {
        _ = try await boundRecord(id)
        let token = try await authorization()
        _ = try await advertisedKinds(token: token)
        _ = try await remoteRecord(id, token: token)
        try await checkIdentity()
        let data = try await client.request(origin.server, "/v1/tasks/\(id)/cancel", "POST", Data("{}".utf8), token)
        let record = try JSONDecoder().decode(TaskRecord.self, from: data)
        try origin.validate(record)
        try await store.remember(record, origin: origin)
        return record
    }

    private func boundRecord(_ id: String) async throws -> TaskRecord {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id,
              let record = try await store.entry(origin).records.first(where: { $0.id == id }) else { throw ServedTaskError.foreignTask }
        try origin.validate(record)
        return record
    }
    private func validateSummary(_ record: TaskRecord, known: TaskRecord) throws {
        try origin.validate(record, fullIdentity: false)
        guard record.id == known.id, record.kind == known.kind, record.createdAt == known.createdAt,
              record.request == known.request, record.identity == known.identity else { throw ServedTaskError.foreignTask }
    }
    private func restoringOwner(_ record: TaskRecord, known: TaskRecord) throws -> TaskRecord {
        // Restore only previously verified evidence; the engine's state and artifact references stay unchanged.
        var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        fields["supervisor"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(known.supervisor))
        return try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    private func remoteRecord(_ id: String, token: String?) async throws -> TaskRecord {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw TaskProtocolError.invalidIdentifier }
        let data = try await client.request(origin.server, "/v1/tasks/\(id)", "GET", nil, token)
        let record = try JSONDecoder().decode(TaskRecord.self, from: data)
        guard record.id == id else { throw ServedTaskError.foreignTask }
        try origin.validate(record)
        return record
    }
    private func checkIdentity() async throws {
        let servers = try await client.servers(origin.server.receiptsDirectory!)
        let candidates = servers.filter { $0.port == origin.server.port }
        guard candidates.count == 1, let current = candidates.first, origin.matches(current) else { throw ServedTaskError.changed }
    }
    private func authorization() async throws -> String? {
        try await checkIdentity()
        guard let hash = origin.server.apiKeySHA256 else { return nil }
        let token: String
        do { token = try await client.credential(hash) } catch { throw ServedTaskError.key }
        guard SHA256.hash(data: Data(token.utf8)).map({ String(format: "%02x", $0) }).joined() == hash else { throw ServedTaskError.key }
        return token
    }
    private func advertisedKinds() async throws -> [String] {
        let token = try await authorization()
        return try await advertisedKinds(token: token)
    }
    private func advertisedKinds(token: String?) async throws -> [String] {
        try await checkIdentity()
        struct Models: Decodable { let data: [Model] }
        struct Model: Decodable { let id: String; let api: String; let task_kinds: [String] }
        let data = try await client.request(origin.server, "/v1/models", "GET", nil, token)
        let models = try JSONDecoder().decode(Models.self, from: data).data
        guard models.count == 1, let model = models.first, model.id == origin.server.modelIdentity,
              model.api == "/v1/tasks", Set(model.task_kinds) == Set(origin.server.taskKinds ?? []) else { throw ServedTaskError.unsupported }
        return model.task_kinds
    }
}
