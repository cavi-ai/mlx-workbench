import Foundation

// MARK: - VerificationStore
//
// Durable verification reports, following the ModelWorkflowStore pattern:
// JSON, atomic replace, and a throw on corrupt data so a damaged file is
// never silently overwritten (upsert loads first, so corruption blocks
// writes until a human looks).

final class VerificationStore {
    private static let fileName = "verification-reports.json"
    private static let mutationLock = NSLock()

    private let fileURL: URL
    private let fileManager: FileManager
    private let replaceItem: (URL, URL) throws -> Void

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

    func load() throws -> [VerificationReport] {
        try withLock {
            guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
            return try JSONDecoder().decode([VerificationReport].self, from: Data(contentsOf: fileURL))
        }
    }

    func upsert(_ report: VerificationReport) throws {
        try withLock {
            var reports = try loadUnlocked()
            if let index = reports.firstIndex(where: { $0.id == report.id }) {
                reports[index] = report
            } else {
                reports.append(report)
            }
            try write(reports)
        }
    }

    private func loadUnlocked() throws -> [VerificationReport] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([VerificationReport].self, from: Data(contentsOf: fileURL))
    }

    private func write(_ reports: [VerificationReport]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(reports)
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
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        return try operation()
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
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
