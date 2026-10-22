import Foundation
import os
import SQLite3

/// Atomic per-record payloads and optional lightweight entries. Migration keeps the original
/// JSON array untouched and commits only after every record validates.
final class RecordArchive<Value: Codable & Identifiable>: Sendable where Value.ID == UUID {
    let legacyURL: URL
    var url: URL { legacyURL.appendingPathExtension("sqlite") }
    private let lock: NSRecursiveLock
    private let project: @Sendable (Data) throws -> Data
    private let descending: Bool
    init(legacyURL: URL, descending: Bool = false, project: @escaping @Sendable (Data) throws -> Data = { $0 }) {
        self.legacyURL = legacyURL; self.descending = descending; self.project = project
        lock = RecordArchiveFileLock.lock(for: legacyURL)
    }

    func replaceAll(_ values: [Value]) throws {
        try database { db in
            try transaction(db) {
                try execute(db, "DELETE FROM records")
                for value in values { try write(db, id: value.id, payload: JSONEncoder().encode(value), replacing: false) }
            }
        }
    }

    func load() throws -> [Value] {
        try database { db in
            let statement = try prepare(db, "SELECT summary FROM records ORDER BY rowid " + (descending ? "DESC" : "ASC"))
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
                    guard updated.id == id else { throw WorkflowEvidenceError.invalid("Record identity cannot change.") }
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
        let summary = try project(payload)
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
    private func database<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        for file in [legacyURL, url] where FileManager.default.fileExists(atPath: file.path) {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw WorkflowEvidenceError.invalid("Saved history cannot be a symbolic link.")
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw WorkflowEvidenceError.invalid("Saved history could not be opened.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        try execute(db, "PRAGMA synchronous=FULL")
        // Existing archives need only a read to validate their schema. Readers
        // must not acquire the reserved writer lock just to inspect a run.
        if try schemaVersion(db) == 1 { return try body(db) }
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
    private func schemaVersion(_ db: OpaquePointer) throws -> Int32? {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, "SELECT version FROM metadata", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        if status != SQLITE_OK {
            // Only a new database lacks the metadata table; other failures are
            // corruption or I/O errors and must never authorize migration.
            let check = try prepare(db, "SELECT name FROM sqlite_master WHERE name='metadata'")
            defer { sqlite3_finalize(check) }
            guard sqlite3_step(check) == SQLITE_DONE else { throw failure(db) }
            return nil
        }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW, sqlite3_column_int(statement, 0) == 1 else {
            throw WorkflowEvidenceError.invalid("Unsupported history schema.")
        }
        return 1
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
        WorkflowEvidenceError.invalid("Saved history: \(String(cString: sqlite3_errmsg(db)))")
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

private enum RecordArchiveFileLock {
    private static let registry = OSAllocatedUnfairLock(initialState: [String: NSRecursiveLock]())
    static func lock(for url: URL) -> NSRecursiveLock {
        registry.withLock { locks in
            let key = url.standardizedFileURL.path
            if let lock = locks[key] { return lock }
            let lock = NSRecursiveLock()
            locks[key] = lock
            return lock
        }
    }
}
