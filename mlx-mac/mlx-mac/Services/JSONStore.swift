import Foundation

// MARK: - JSONStore
//
// Generic durable list store: JSON array on disk, atomic replace, and a
// throw on corrupt data so a damaged file is never silently overwritten
// (upsert loads first, so corruption blocks writes until a human looks).
// New state stores should use this instead of cloning the pattern.

final class JSONStore<Value: Codable> {
    private let fileURL: URL
    private let fileManager: FileManager
    private let replaceItem: (URL, URL) throws -> Void
    private let mutationLock = NSLock()

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.replaceItem = { existingURL, temporaryURL in
            _ = try fileManager.replaceItemAt(
                existingURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        }
    }

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        replaceItem: @escaping (URL, URL) throws -> Void
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.replaceItem = replaceItem
    }

    func load() throws -> [Value] {
        try withLock {
            try loadUnlocked()
        }
    }

    func replaceAll(_ values: [Value]) throws {
        try withLock {
            try write(values)
        }
    }

    func upsert<ID: Equatable>(_ value: Value, id keyPath: KeyPath<Value, ID>) throws {
        try withLock {
            var values = try loadUnlocked()
            if let index = values.firstIndex(where: { $0[keyPath: keyPath] == value[keyPath: keyPath] }) {
                values[index] = value
            } else {
                values.append(value)
            }
            try write(values)
        }
    }

    private func loadUnlocked() throws -> [Value] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([Value].self, from: Data(contentsOf: fileURL))
    }

    private func write(_ values: [Value]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(values)
        let directory = fileURL.deletingLastPathComponent()
        let temporaryURL = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try? fileManager.removeItem(at: temporaryURL)
        }

        do {
            try data.write(to: temporaryURL, options: .atomic)
            if fileManager.fileExists(atPath: fileURL.path) {
                try replaceItem(fileURL, temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return try operation()
    }

    static func defaultFileURL(_ fileName: String, fileManager: FileManager = .default) -> URL {
        let applicationSupport: URL
        if let url = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            applicationSupport = url
        } else {
            applicationSupport = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }

        return applicationSupport
            .appendingPathComponent("mlx-workbench", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
