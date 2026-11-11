import Foundation

private struct UseWorkspacePreferences: Codable {
    var request = UseRequestDefaults()
    var selectedID: UUID?
}

/// All archive and preference access runs on one I/O queue, including startup recovery.
final class UseSessionStore: @unchecked Sendable {
    private let archive: RecordArchive<UseSession>
    private let preferences: JSONStore<UseWorkspacePreferences>
    private let io = DispatchQueue(label: "mlx-workbench.use-history")
    init(url: URL = JSONStore<UseSession>.defaultFileURL("use-sessions.json")) {
        archive = RecordArchive(legacyURL: url, descending: true, project: { data in
            let session = try JSONDecoder().decode(UseSession.self, from: data)
            return try JSONEncoder().encode(session.summary)
        })
        preferences = JSONStore(fileURL: url.deletingLastPathComponent().appendingPathComponent("use-defaults.json"))
    }
    func list() async throws -> [UseSession] {
        try await perform { try self.archive.load().sorted { $0.updatedAt > $1.updatedAt } }
    }
    func record(id: UUID) async throws -> UseSession? {
        try await perform {
            let session = try self.archive.record(id: id)
            try session?.validate()
            return session
        }
    }
    func save(_ session: UseSession) async throws {
        try await perform {
            var value = session
            value.imageHashes = Set(value.allImages.map(\.sha256))
            try value.validate()
            try self.archive.upsert(value)
        }
    }
    func defaults() async throws -> UseRequestDefaults {
        try await perform {
            let value = try self.preferences.load().first?.request ?? UseRequestDefaults()
            try value.validate()
            return value
        }
    }
    func saveDefaults(_ value: UseRequestDefaults) async throws {
        try await perform {
            try value.validate()
            try self.preferences.mutate { entries in
                var entry = entries.first ?? UseWorkspacePreferences()
                entry.request = value; entries = [entry]
            }
        }
    }
    func selectedID() async throws -> UUID? { try await perform { try self.preferences.load().first?.selectedID } }
    func select(_ id: UUID) async throws {
        try await perform {
            try self.preferences.mutate { entries in
                var entry = entries.first ?? UseWorkspacePreferences()
                entry.selectedID = id; entries = [entry]
            }
        }
    }
    func retainedImageHashes() async throws -> Set<String> {
        try await perform { Set(try self.archive.load().flatMap(\.imageHashes)) }
    }
    func recoverInterrupted() async throws {
        try await perform {
            for summary in try self.archive.load() where summary.wasSending {
                _ = try self.archive.update(id: summary.id) { original in
                    var session = original
                    session.wasSending = false
                    for index in session.turns.indices where session.turns[index].state == .sending {
                        session.turns[index].state = .interrupted
                        session.turns[index].notice = UseSessionError.interrupted.localizedDescription
                    }
                    try session.validate()
                    return session
                }
            }
        }
    }
    private func perform<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            io.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
