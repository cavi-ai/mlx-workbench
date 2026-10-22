import Foundation

/// Per-record transactions; the original JSON remains an untouched migration backup.
final class ModelWorkflowStore: Sendable {
    private let archive: RecordArchive<ConversionWorkflow>
    var databaseURL: URL { archive.url }

    init(fileURL: URL) { archive = RecordArchive(legacyURL: fileURL) }
    func load() throws -> [ConversionWorkflow] { try archive.load() }
    func upsert(_ record: ConversionWorkflow) throws { try archive.upsert(record) }

    func replace(_ records: [ConversionWorkflow]) throws { try archive.replaceAll(records) }
    func remove(id: String) throws {
        guard let id = UUID(uuidString: id) else { throw WorkflowEvidenceError.invalid("Invalid workflow identity.") }
        _ = try archive.update(id: id) { _ in nil }
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        WorkbenchStatePaths.applicationSupport(fileManager: fileManager)
            .appendingPathComponent("model-workflows.json", isDirectory: false)
    }
}
