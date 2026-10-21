import Foundation

/// Comparison summaries retain metrics and references while complete records
/// remain available for authoritative checks and output inspection.
final class ComparisonRecordArchive<Value: Codable & Identifiable>: RecordArchive<Value> where Value.ID == UUID {
    init(legacyURL: URL) {
        super.init(legacyURL: legacyURL, descending: true) { payload in
            let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            let run = root?["run"] as? [String: Any] ?? root
            guard run?["historyDetailsOmitted"] as? Bool != true else {
                throw WorkflowEvidenceError.invalid("Load the complete comparison before saving changes.")
            }
            return try Self.summary(payload)
        }
    }
    static func summarized(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: summary(JSONEncoder().encode(value)))
    }

    private static func summary(_ payload: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw WorkflowEvidenceError.invalid("Invalid comparison record.")
        }
        let hosted = root["run"] != nil
        var run = (hosted ? root["run"] as? [String: Any] : root) ?? [:]
        run["historyDetailsOmitted"] = true
        if var results = run["results"] as? [[String: Any]] {
            for index in results.indices {
                if var samples = results[index]["samples"] as? [[String: Any]] {
                    for sample in samples.indices {
                        let text = samples[sample]["fullOutput"] as? String ?? samples[sample]["outputExcerpt"] as? String ?? ""
                        samples[sample]["historyCompletedAnswer"] = samples[sample]["error"] as? String == nil
                            && samples[sample]["finishReason"] as? String == "stop"
                            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        samples[sample]["historyAnswerPresent"] = !ChatRecordedText(text).answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        samples[sample]["historyOutputIsEmpty"] = text.isEmpty
                        samples[sample].removeValue(forKey: "fullOutput")
                        samples[sample].removeValue(forKey: "reasoningText")
                    }
                    results[index]["samples"] = samples
                }
            }
            run["results"] = results
        }
        if hosted { root["run"] = run; root["submissions"] = [] } else { root = run }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

/// Serial durability boundary. Cancellation never abandons a write or ownership receipt.
final class RecordHistoryWorker<Value: Codable & Identifiable & Sendable>: @unchecked Sendable where Value.ID == UUID {
    private let store: JSONStore<Value>
    private let archive: ComparisonRecordArchive<Value>?
    private let queue = DispatchQueue(label: "comparison-history", qos: .utility)
    init(store: JSONStore<Value>, indexed: Bool = false) {
        self.store = store
        archive = indexed ? ComparisonRecordArchive(legacyURL: store.url) : nil
    }
    private func loadSync() throws -> [Value] { try archive?.load() ?? store.loadStreaming() }
    func load() async throws -> [Value] { try await perform { try self.loadSync() } }
    func upsert(_ value: Value) async throws {
        try await perform {
            if let archive = self.archive { try archive.upsert(value) }
            else { try self.store.upsertStreaming(value, id: \.id) }
        }
    }
    private func recordSync(id: UUID) throws -> Value? {
        if let archive { return try archive.record(id: id) }
        return try store.findStreaming(id: id, keyPath: \.id)
    }
    func record(id: UUID) async throws -> Value? { try await perform { try self.recordSync(id: id) } }
    func summarized(_ value: Value) async throws -> Value {
        try await perform { self.archive == nil ? value : try ComparisonRecordArchive<Value>.summarized(value) }
    }
    func update(id: UUID, transform: @escaping @Sendable (Value) throws -> Value?) async throws -> Bool {
        try await perform {
            if let archive = self.archive { return try archive.update(id: id, transform: transform) }
            return try self.store.updateStreaming(id: id, keyPath: \.id, transform: transform)
        }
    }
    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { do { continuation.resume(returning: try operation()) } catch { continuation.resume(throwing: error) } }
        }
    }
}
typealias ComparisonHistoryWorker = RecordHistoryWorker<ComparisonRun>
