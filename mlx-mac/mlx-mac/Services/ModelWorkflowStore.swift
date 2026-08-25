import Foundation

final class ModelWorkflowStore {
    private static let fileName = "model-workflows.json"

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() throws -> [ConversionWorkflow] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        return try JSONDecoder().decode([ConversionWorkflow].self, from: Data(contentsOf: fileURL))
    }

    func replace(_ records: [ConversionWorkflow]) throws {
        try write(records)
    }

    func upsert(_ record: ConversionWorkflow) throws {
        var records = try load()
        if let index = records.firstIndex(where: { $0.persistenceIdentifier == record.persistenceIdentifier }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try write(records)
    }

    func remove(id: String) throws {
        try write(try load().filter { $0.persistenceIdentifier != id })
    }

    private func write(_ records: [ConversionWorkflow]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(records)
        let directory = fileURL.deletingLastPathComponent()
        let temporaryURL = fileURL.appendingPathExtension("tmp")

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try? fileManager.removeItem(at: temporaryURL)
        }

        do {
            try data.write(to: temporaryURL, options: .atomic)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
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
