import Darwin
import Foundation

/// User-authored chat examples. The engine remains the final dataset validator.
struct TrainingDatasetDraft: Equatable, Sendable {
    struct Example: Equatable, Identifiable, Sendable {
        var id = UUID()
        var prompt = ""
        var reply = ""
    }
    enum Split: String, CaseIterable, Identifiable {
        case train, valid
        var id: String { rawValue }
        var title: String { self == .train ? "Training" : "Validation" }
    }
    let batchSize: Int
    var train = [Example()]
    var valid = [Example()]
    static let exampleLimit = 500

    struct ValidationIssue: Equatable {
        let message: String
        var split: Split? = nil
        var exampleID: UUID? = nil
    }

    var validationMessage: String? { validationIssue?.message }

    var validationIssue: ValidationIssue? {
        guard (1...64).contains(batchSize) else {
            return .init(message: "Choose a batch size from 1 to 64 in Training.")
        }
        for split in Split.allCases {
            let examples = split == .train ? train : valid
            let label = split.title
            guard examples.count >= batchSize else {
                return .init(message: "\(label) needs at least \(batchSize) examples for the selected batch size (\(examples.count) so far).", split: split)
            }
            guard examples.count <= Self.exampleLimit else {
                return .init(message: "Use at most \(Self.exampleLimit) examples per split in this editor.", split: split)
            }
            guard Set(examples.map(\.id)).count == examples.count else {
                return .init(message: "\(label) has repeated example identities. Reopen the editor.")
            }
            for (index, example) in examples.enumerated() {
                if example.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .init(message: "\(label) example \(index + 1) needs a user request.", split: split, exampleID: example.id)
                }
                if example.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .init(message: "\(label) example \(index + 1) needs an assistant reply.", split: split, exampleID: example.id)
                }
            }
        }
        let learning = Set(train.map(Content.init))
        if let example = valid.first(where: { learning.contains(Content($0)) }) {
            return .init(message: "An example appears in both splits. Keep validation examples separate from training.",
                         split: .valid, exampleID: example.id)
        }
        return nil
    }

    private struct Content: Hashable {
        let prompt: String
        let reply: String
        init(_ example: Example) {
            prompt = example.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            reply = example.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func encodedSplits() throws -> [String: Data] {
        if let message = validationMessage { throw TrainingDatasetError(message: message) }
        var result: [String: Data] = [:]
        for (name, examples) in [("train.jsonl", train), ("valid.jsonl", valid)] {
            var data = Data()
            for example in examples {
                // JSON serialization escapes embedded newlines; one example stays on one physical line.
                var record = try JSONSerialization.data(withJSONObject: ["messages": [
                    ["role": "user", "content": example.prompt], ["role": "assistant", "content": example.reply]
                ]], options: [.sortedKeys])
                record.append(10)
                guard record.count <= 1024 * 1024 else { throw TrainingDatasetError(message: "An example exceeds the engine’s 1 MiB record limit.") }
                data.append(record)
                guard data.count <= 64 * 1024 * 1024 else { throw TrainingDatasetError(message: "\(name) exceeds the engine’s 64 MiB file limit.") }
            }
            result[name] = data
        }
        return result
    }
}

struct TrainingDatasetError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum TrainingDatasetExporter {
    /// Publish both files together into a new directory, without replacing any existing item.
    static func save(_ draft: TrainingDatasetDraft, to destination: URL) throws {
        let files = try draft.encodedSplits()
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty else {
            throw TrainingDatasetError(message: "Choose a new local dataset folder.")
        }
        let fm = FileManager.default
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".workbench-dataset-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var published = false
        defer { if !published { try? fm.removeItem(at: stage) } }
        for (name, data) in files {
            try data.write(to: stage.appendingPathComponent(name), options: .withoutOverwriting)
        }
        let status = stage.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                renamex_np(source, target, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else {
            let code = errno
            if code == EEXIST || code == ENOTEMPTY {
                throw TrainingDatasetError(message: "That destination already exists. Choose a new folder name; existing datasets are never replaced.")
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        published = true
    }
}
