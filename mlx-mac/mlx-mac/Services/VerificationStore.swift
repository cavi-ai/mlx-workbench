import Foundation

/// Per-record transactions; the original JSON remains an untouched migration backup.
final class VerificationStore: @unchecked Sendable {
    private let archive: RecordArchive<VerificationReport>
    var databaseURL: URL { archive.url }

    init(fileURL: URL) { archive = RecordArchive(legacyURL: fileURL) }
    func load() throws -> [VerificationReport] { try archive.load() }
    func upsert(_ record: VerificationReport) throws { try archive.upsert(record) }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        WorkbenchStatePaths.applicationSupport(fileManager: fileManager)
            .appendingPathComponent("verification-reports.json", isDirectory: false)
    }
}
