import Foundation

struct WorkflowImportPreview: Equatable, Sendable {
    let report: WorkflowReport
    let newRecords: [WorkflowEvidence]
    let duplicateCount: Int
    fileprivate let savedRecords: [WorkflowEvidence]
}

@MainActor
final class WorkflowEvidenceStore: ObservableObject {
    static let maxBytes = 4 * 1024 * 1024
    static let maxRecords = 2000
    @Published private(set) var records: [WorkflowEvidence] = []
    @Published private(set) var lastError: String?
    private let store: JSONStore<WorkflowEvidence>
    private var loaded = false

    init(store: JSONStore<WorkflowEvidence>) {
        self.store = store
        do {
            let saved = try store.load()
            try Self.validate(saved)
            records = saved
            loaded = true
        } catch { lastError = AppHost.render(error) }
    }

    nonisolated static func decode(_ data: Data) throws -> WorkflowReport {
        guard data.count <= maxBytes else { throw WorkflowEvidenceError.invalid("maximum file size is 4 MiB") }
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["reportDraft"] != nil {
            throw WorkflowEvidenceError.invalid("this is a capture request, not measured evidence; fill and save its reportDraft object")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw WorkflowEvidenceError.invalid("ISO8601 measuredAt") }
            return date
        }
        let report = try decoder.decode(WorkflowReport.self, from: data)
        guard report.schemaVersion == 1 else { throw WorkflowEvidenceError.invalid("unsupported schemaVersion") }
        try validate(report.records)
        return report
    }

    nonisolated static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    nonisolated private static func validate(_ records: [WorkflowEvidence]) throws {
        guard records.count <= maxRecords else { throw WorkflowEvidenceError.invalid("maximum 2000 records") }
        var ids = Set<UUID>()
        for record in records {
            try record.validate()
            guard ids.insert(record.id).inserted else { throw WorkflowEvidenceError.invalid("duplicate record id") }
        }
    }

    @discardableResult
    func importReport(_ data: Data) throws -> Int {
        try confirmImport(previewReport(data))
    }

    func previewReport(_ data: Data) throws -> WorkflowImportPreview {
        try previewReport(Self.decode(data))
    }

    func previewReport(_ report: WorkflowReport) throws -> WorkflowImportPreview {
        guard loaded else { throw WorkflowEvidenceError.invalid("saved store unavailable; preserve and repair it before importing") }
        guard try store.load() == records else { throw WorkflowEvidenceError.invalid("saved evidence changed; restart Workbench before importing") }
        guard report.schemaVersion == 1 else { throw WorkflowEvidenceError.invalid("unsupported schemaVersion") }
        try Self.validate(report.records)
        var merged = records
        for record in report.records {
            if let existing = merged.first(where: { $0.id == record.id }) {
                guard existing == record else { throw WorkflowEvidenceError.invalid("conflicting record id \(record.id)") }
            } else { merged.append(record) }
        }
        try Self.validate(merged)
        let added = Array(merged.dropFirst(records.count))
        return WorkflowImportPreview(report: report, newRecords: added, duplicateCount: report.records.count - added.count, savedRecords: records)
    }

    @discardableResult
    func confirmImport(_ preview: WorkflowImportPreview) throws -> Int {
        guard loaded, records == preview.savedRecords, try store.load() == preview.savedRecords else {
            throw WorkflowEvidenceError.invalid("saved evidence changed after preview; review the report again")
        }
        let merged = records + preview.newRecords
        try Self.validate(merged)
        if preview.newRecords.isEmpty { return 0 }
        try store.replaceAll(merged)
        let count = merged.count - records.count
        records = merged
        lastError = nil
        return count
    }

    nonisolated static func readReport(_ url: URL) throws -> WorkflowReport {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
        return try decode(data)
    }

    func importFile(_ url: URL) throws -> Int {
        try confirmImport(previewReport(Self.readReport(url)))
    }
}
