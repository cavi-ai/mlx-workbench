import Foundation
import SQLite3

/// Atomic per-run payloads and lightweight entries. Migration keeps the original
/// JSON array untouched and commits only after every record validates.
final class ComparisonRecordArchive<Value: Codable & Identifiable> where Value.ID == UUID {
    let legacyURL: URL
    var url: URL { legacyURL.appendingPathExtension("sqlite") }
    private let lock = NSRecursiveLock()
    init(legacyURL: URL) { self.legacyURL = legacyURL }
    static func summarized(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: summary(JSONEncoder().encode(value)))
    }

    func load() throws -> [Value] {
        try database { db in
            let statement = try prepare(db, "SELECT summary FROM records ORDER BY rowid DESC")
            defer { sqlite3_finalize(statement) }
            var values: [Value] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return values }
                guard status == SQLITE_ROW else { throw failure(db) }
                values.append(try JSONDecoder().decode(Value.self, from: data(statement, column: 0)))
            }
        }
    }
    func record(id: UUID) throws -> Value? { try database { try read($0, id: id) } }
    func upsert(_ value: Value) throws {
        try database { db in try transaction(db) { try write(db, id: value.id, payload: JSONEncoder().encode(value)) } }
    }
    func update(id: UUID, transform: (Value) throws -> Value?) throws -> Bool {
        try database { db in
            try transaction(db) {
                guard let original = try read(db, id: id) else { return false }
                if let updated = try transform(original) {
                    guard updated.id == id else { throw WorkflowEvidenceError.invalid("Comparison identity cannot change.") }
                    try write(db, id: id, payload: JSONEncoder().encode(updated))
                } else {
                    let statement = try prepare(db, "DELETE FROM records WHERE id = ?")
                    defer { sqlite3_finalize(statement) }
                    bind(id.uuidString, to: statement, column: 1)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(db) }
                }
                return true
            }
        }
    }
    private func read(_ db: OpaquePointer, id: UUID) throws -> Value? {
        let statement = try prepare(db, "SELECT payload FROM records WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: statement, column: 1)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure(db) }
        return try JSONDecoder().decode(Value.self, from: data(statement, column: 0))
    }
    private func write(_ db: OpaquePointer, id: UUID, payload: Data, replacing: Bool = true) throws {
        let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let run = root?["run"] as? [String: Any] ?? root
        guard run?["historyDetailsOmitted"] as? Bool != true else {
            throw WorkflowEvidenceError.invalid("Load the complete comparison before saving changes.")
        }
        let summary = try Self.summary(payload)
        let sql = replacing ? "INSERT INTO records(id,payload,summary) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,summary=excluded.summary"
                            : "INSERT INTO records(id,payload,summary) VALUES(?,?,?)"
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: statement, column: 1)
        bind(payload, to: statement, column: 2); bind(summary, to: statement, column: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(db) }
    }
    /// Preserve metrics, cohort identity, ownership and reviews without retaining
    /// answer bodies or submitted graphs. Output views hydrate before rendering.
    private static func summary(_ payload: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw WorkflowEvidenceError.invalid("Invalid comparison record.")
        }
        let hosted = root["run"] != nil
        var run = (hosted ? root["run"] as? [String: Any] : root) ?? [:]
        run["historyDetailsOmitted"] = true
        if var results = run["results"] as? [[String: Any]] {
            for index in results.indices {
                if var samples = results[index]["samples"] as? [[String: Any]] {
                    for sample in samples.indices {
                        let text = samples[sample]["fullOutput"] as? String ?? samples[sample]["outputExcerpt"] as? String ?? ""
                        samples[sample]["historyCompletedAnswer"] = samples[sample]["error"] == nil
                            && samples[sample]["finishReason"] as? String == "stop"
                            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        samples[sample]["historyAnswerPresent"] = !ChatRecordedText(text).answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        samples[sample]["historyOutputIsEmpty"] = text.isEmpty
                        samples[sample].removeValue(forKey: "fullOutput")
                        samples[sample].removeValue(forKey: "reasoningText")
                    }
                    results[index]["samples"] = samples
                }
            }
            run["results"] = results
        }
        if hosted { root["run"] = run; root["submissions"] = [] } else { root = run }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
    private func database<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        for file in [legacyURL, url] where FileManager.default.fileExists(atPath: file.path) {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw WorkflowEvidenceError.invalid("Comparison history cannot be a symbolic link.")
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw WorkflowEvidenceError.invalid("Comparison history could not be opened.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        try execute(db, "PRAGMA synchronous=FULL")
        try transaction(db) {
            try execute(db, "CREATE TABLE IF NOT EXISTS metadata(version INTEGER NOT NULL)")
            let version = try prepare(db, "SELECT version FROM metadata")
            let status = sqlite3_step(version)
            let migrated = status == SQLITE_ROW
            let supported = !migrated || sqlite3_column_int(version, 0) == 1
            sqlite3_finalize(version)
            guard (status == SQLITE_ROW || status == SQLITE_DONE), supported else { throw failure(db) }
            if !migrated {
                try execute(db, "CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL,payload BLOB NOT NULL,summary BLOB NOT NULL)")
                try JSONRecordStream.forEach(at: legacyURL) { payload in
                    let value = try JSONDecoder().decode(Value.self, from: payload)
                    try write(db, id: value.id, payload: payload, replacing: false)
                }
                try execute(db, "INSERT INTO metadata VALUES(1)")
            }
        }
        return try body(db)
    }
    private func transaction<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
        try execute(db, "BEGIN IMMEDIATE")
        do { let value = try body(); try execute(db, "COMMIT"); return value }
        catch { try? execute(db, "ROLLBACK"); throw error }
    }
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure(db) }
    }
    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure(db) }
        return statement
    }
    private func failure(_ db: OpaquePointer) -> Error {
        WorkflowEvidenceError.invalid("Comparison history: \(String(cString: sqlite3_errmsg(db)))")
    }
    private func bind(_ value: String, to statement: OpaquePointer, column: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, column, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func bind(_ value: Data, to statement: OpaquePointer, column: Int32) {
        _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, column, $0.baseAddress, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func data(_ statement: OpaquePointer, column: Int32) -> Data {
        Data(bytes: sqlite3_column_blob(statement, column), count: Int(sqlite3_column_bytes(statement, column)))
    }
}

/// Serial durability boundary. Cancellation never abandons a write or ownership receipt.
final class RecordHistoryWorker<Value: Codable & Identifiable & Sendable>: @unchecked Sendable where Value.ID == UUID {
    private let store: JSONStore<Value>
    private let archive: ComparisonRecordArchive<Value>?
    private let queue = DispatchQueue(label: "comparison-history", qos: .utility)
    init(store: JSONStore<Value>, indexed: Bool = false) {
        self.store = store
        archive = indexed ? ComparisonRecordArchive(legacyURL: store.url) : nil
    }
    func loadSync() throws -> [Value] { try archive?.load() ?? store.loadStreaming() }
    func load() async throws -> [Value] { try await perform { try self.loadSync() } }
    func upsert(_ value: Value) async throws {
        try await perform {
            if let archive = self.archive { try archive.upsert(value) }
            else { try self.store.upsertStreaming(value, id: \.id) }
        }
    }
    func recordSync(id: UUID) throws -> Value? {
        if let archive { return try archive.record(id: id) }
        return try store.findStreaming(id: id, keyPath: \.id)
    }
    func record(id: UUID) async throws -> Value? { try await perform { try self.recordSync(id: id) } }
    func summarized(_ value: Value) async throws -> Value {
        try await perform { self.archive == nil ? value : try ComparisonRecordArchive<Value>.summarized(value) }
    }
    func update(id: UUID, transform: @escaping @Sendable (Value) throws -> Value?) async throws -> Bool {
        try await perform {
            if let archive = self.archive { return try archive.update(id: id, transform: transform) }
            return try self.store.updateStreaming(id: id, keyPath: \.id, transform: transform)
        }
    }
    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { do { continuation.resume(returning: try operation()) } catch { continuation.resume(throwing: error) } }
        }
    }
}
typealias ComparisonHistoryWorker = RecordHistoryWorker<ComparisonRun>
