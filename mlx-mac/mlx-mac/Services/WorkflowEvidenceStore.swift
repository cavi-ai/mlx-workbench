import Foundation

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

    static func decode(_ data: Data) throws -> WorkflowReport {
        guard data.count <= maxBytes else { throw WorkflowEvidenceError.invalid("maximum file size is 4 MiB") }
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

    private static func validate(_ records: [WorkflowEvidence]) throws {
        guard records.count <= maxRecords else { throw WorkflowEvidenceError.invalid("maximum 2000 records") }
        var ids = Set<UUID>()
        for record in records {
            try record.validate()
            guard ids.insert(record.id).inserted else { throw WorkflowEvidenceError.invalid("duplicate record id") }
        }
    }

    @discardableResult
    func importReport(_ data: Data) throws -> Int {
        guard loaded else { throw WorkflowEvidenceError.invalid("saved store unavailable; preserve and repair it before importing") }
        let report = try Self.decode(data)
        var merged = records
        for record in report.records {
            if let existing = merged.first(where: { $0.id == record.id }) {
                guard existing == record else { throw WorkflowEvidenceError.invalid("conflicting record id \(record.id)") }
            } else { merged.append(record) }
        }
        try Self.validate(merged)
        try store.replaceAll(merged)
        let count = merged.count - records.count
        records = merged
        lastError = nil
        return count
    }

    func importFile(_ url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
        return try importReport(data)
    }
}
