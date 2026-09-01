import Foundation
import SQLite3

// MARK: - PromptHistoryImport
//
// Comparison phase 2 (spec 03): opt-in import of the user's real opencode
// prompts as a comparison prompt set. Read-only access to opencode's local
// SQLite store (immutable mode — never writes, never touches credentials).
// The import only happens on an explicit button press.

enum PromptHistoryImport {
    struct ImportResult: Equatable {
        let prompts: [String]
        let sourcePath: String
    }

    static let defaultLimit = 20
    static let minimumLength = 24

    /// Default opencode storage location; nil when absent.
    static func defaultDatabasePath(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> String? {
        let path = home.appendingPathComponent(".local/share/opencode/opencode.db").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Most recent distinct user prompts, longest-cap capped, newest first.
    /// Returns nil when the database is missing or unreadable.
    static func importPrompts(
        databasePath: String,
        limit: Int = defaultLimit,
        minimumLength: Int = minimumLength
    ) -> ImportResult? {
        var handle: OpaquePointer?
        // immutable=1: read-only, no WAL side effects on the live database.
        let uri = "file:\(databasePath)?immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }

        let query = """
        SELECT json_extract(p.data, '$.text')
        FROM part p
        JOIN message m ON p.message_id = m.id
        WHERE json_extract(m.data, '$.role') = 'user'
          AND json_extract(p.data, '$.type') = 'text'
        ORDER BY m.time_created DESC
        LIMIT 500;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var prompts: [String] = []
        var seen: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW, prompts.count < limit {
            guard let textPointer = sqlite3_column_text(statement, 0) else { continue }
            let raw = String(cString: textPointer).trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip tiny messages and command invocations; keep real prompts.
            guard raw.count >= minimumLength, !raw.hasPrefix("/") else { continue }
            let key = String(raw.prefix(120))
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            prompts.append(String(raw.prefix(2000)))
        }
        guard !prompts.isEmpty else { return nil }
        return ImportResult(prompts: prompts, sourcePath: databasePath)
    }
}
