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
    var systemPrompt = ""
    static let exampleLimit = 500
    static let maxRecordBytes = 1024 * 1024
    static let maxFileBytes = 64 * 1024 * 1024

    struct ImportedDataset: Equatable, Sendable {
        let examples: [Example]
        let systemPrompt: String?
    }

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
        let hasSystemPrompt = !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        for (name, examples) in [("train.jsonl", train), ("valid.jsonl", valid)] {
            var data = Data()
            for example in examples {
                var messages: [[String: String]] = []
                if hasSystemPrompt {
                    messages.append(["role": "system", "content": systemPrompt])
                }
                messages.append(["role": "user", "content": example.prompt])
                messages.append(["role": "assistant", "content": example.reply])
                // JSON serialization escapes embedded newlines; one example stays on one physical line.
                var record = try JSONSerialization.data(withJSONObject: ["messages": messages], options: [.sortedKeys])
                record.append(10)
                guard record.count <= Self.maxRecordBytes else { throw TrainingDatasetError(message: "An example exceeds the engine’s 1 MiB record limit.") }
                data.append(record)
                guard data.count <= Self.maxFileBytes else { throw TrainingDatasetError(message: "\(name) exceeds the engine’s 64 MiB file limit.") }
            }
            result[name] = data
        }
        return result
    }

    /// Safely import chat examples from a local JSONL file, refusing symlinks and enforcing
    /// the engine's 1 MiB record cap and 64 MiB file cap.
    static func importJSONL(from url: URL) throws -> ImportedDataset {
        guard url.isFileURL, !url.path.isEmpty else {
            throw TrainingDatasetError(message: "Choose a local JSONL file to import.")
        }
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { errno = EINVAL; return -1 }
            return open(path, O_RDONLY | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP {
                throw TrainingDatasetError(message: "Symbolic links are not permitted when importing a training dataset.")
            }
            throw TrainingDatasetError(message: "Could not open JSONL file: \(String(cString: strerror(code))).")
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            throw TrainingDatasetError(message: "Could not inspect JSONL file: \(String(cString: strerror(errno))).")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw TrainingDatasetError(message: "Choose a regular JSONL file to import.")
        }
        guard st.st_size <= Int64(Self.maxFileBytes) else {
            throw TrainingDatasetError(message: "The JSONL file exceeds the 64 MiB file limit.")
        }

        var data = Data()
        let chunkSize = 65_536
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress, chunkSize)
            }
            if count > 0 {
                if data.count + count > Self.maxFileBytes {
                    throw TrainingDatasetError(message: "The JSONL file exceeds the 64 MiB file limit.")
                }
                data.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw TrainingDatasetError(message: "Could not read JSONL file: \(String(cString: strerror(errno))).")
            }
        }
        return try parseJSONL(data)
    }

    static func parseJSONL(_ data: Data) throws -> ImportedDataset {
        guard data.count <= Self.maxFileBytes else {
            throw TrainingDatasetError(message: "The JSONL file exceeds the 64 MiB file limit.")
        }
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard !lines.isEmpty else {
            throw TrainingDatasetError(message: "The JSONL file contains no examples.")
        }

        var examples: [Example] = []
        var detectedSystemPrompt: String?

        for (index, rawSlice) in lines.enumerated() {
            let lineNumber = index + 1
            var lineData = Data(rawSlice)
            if lineData.last == 13 { lineData.removeLast() }
            guard lineData.count + 1 <= Self.maxRecordBytes else {
                throw TrainingDatasetError(message: "Line \(lineNumber) exceeds the 1 MiB record limit.")
            }
            guard let text = String(data: lineData, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TrainingDatasetError(message: "Line \(lineNumber) is blank or not valid UTF-8.")
            }
            guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                throw TrainingDatasetError(message: "Line \(lineNumber) is not a valid JSON object.")
            }
            if let rawMessages = object["messages"] as? [[String: Any]] {
                var parsed: [(role: String, content: String)] = []
                for message in rawMessages {
                    guard let role = message["role"] as? String,
                          let content = message["content"] as? String else {
                        throw TrainingDatasetError(message: "Line \(lineNumber) has a message without string role and content.")
                    }
                    parsed.append((role, content))
                }
                var cursor = 0
                if let first = parsed.first, first.role == "system" {
                    let trimmedSystem = first.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedSystem.isEmpty {
                        if let existing = detectedSystemPrompt, existing != first.content {
                            throw TrainingDatasetError(message: "Line \(lineNumber) has a different system prompt than earlier records.")
                        }
                        detectedSystemPrompt = first.content
                    }
                    cursor = 1
                }
                guard parsed.count - cursor == 2,
                      parsed[cursor].role == "user",
                      parsed[cursor + 1].role == "assistant" else {
                    throw TrainingDatasetError(message: "Line \(lineNumber) must contain one user message followed by one assistant message (with an optional leading system message).")
                }
                let prompt = parsed[cursor].content
                let reply = parsed[cursor + 1].content
                guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TrainingDatasetError(message: "Line \(lineNumber) has an empty user or assistant message.")
                }
                examples.append(Example(prompt: prompt, reply: reply))
            } else if let prompt = object["prompt"] as? String,
                      let reply = (object["completion"] as? String) ?? (object["reply"] as? String) {
                guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TrainingDatasetError(message: "Line \(lineNumber) has an empty prompt or completion.")
                }
                examples.append(Example(prompt: prompt, reply: reply))
            } else {
                throw TrainingDatasetError(message: "Line \(lineNumber) must contain a messages array or prompt/completion strings.")
            }
        }
        return ImportedDataset(examples: examples, systemPrompt: detectedSystemPrompt)
    }

    /// Extract completed text-only chat turns from a saved UseSession.
    static func importSession(_ session: UseSession) throws -> ImportedDataset {
        let examples = session.turns.compactMap { turn -> Example? in
            guard turn.state.suppliesContext, turn.images.isEmpty else { return nil }
            guard !turn.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !turn.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Example(prompt: turn.prompt, reply: turn.answer)
        }
        guard !examples.isEmpty else {
            throw TrainingDatasetError(message: "This session has no completed text-only turns to import.")
        }
        let system = session.settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : session.settings.systemPrompt
        return ImportedDataset(examples: examples, systemPrompt: system)
    }

    /// Deterministically deduplicate and partition examples into non-overlapping training and validation splits.
    static func autoSplit(
        _ examples: [Example],
        batchSize: Int,
        validationRatio: Double = 0.2,
        seed: UInt64 = 42
    ) throws -> (train: [Example], valid: [Example]) {
        guard (1...64).contains(batchSize) else {
            throw TrainingDatasetError(message: "Choose a batch size from 1 to 64 in Training.")
        }
        guard validationRatio.isFinite, validationRatio > 0, validationRatio < 1 else {
            throw TrainingDatasetError(message: "Validation split ratio must be between 0 and 1.")
        }
        var seen = Set<Content>()
        var unique: [Example] = []
        for example in examples {
            guard !example.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !example.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TrainingDatasetError(message: "All imported examples must have a user request and an assistant reply.")
            }
            if seen.insert(Content(example)).inserted {
                unique.append(Example(prompt: example.prompt, reply: example.reply))
            }
        }
        guard unique.count >= batchSize * 2 else {
            throw TrainingDatasetError(message: "Auto-split needs at least \(batchSize * 2) unique examples for batch size \(batchSize) (found \(unique.count)).")
        }
        var shuffled = unique
        var rng = SplitMix64(seed: seed)
        if shuffled.count > 1 {
            for index in stride(from: shuffled.count - 1, through: 1, by: -1) {
                let swapIndex = Int(rng.next() % UInt64(index + 1))
                if swapIndex != index {
                    shuffled.swapAt(index, swapIndex)
                }
            }
        }
        let desiredValid = Int((Double(shuffled.count) * validationRatio).rounded())
        let validCount = max(batchSize, min(shuffled.count - batchSize, desiredValid))
        let trainCount = shuffled.count - validCount
        guard trainCount <= Self.exampleLimit, validCount <= Self.exampleLimit else {
            throw TrainingDatasetError(message: "Auto-split exceeds the editor limit of \(Self.exampleLimit) examples per split.")
        }
        return (
            train: Array(shuffled.prefix(trainCount)),
            valid: Array(shuffled.suffix(validCount))
        )
    }

    mutating func applyAutoSplit(
        _ examples: [Example],
        systemPrompt: String? = nil,
        validationRatio: Double = 0.2,
        seed: UInt64 = 42
    ) throws {
        let splits = try Self.autoSplit(examples, batchSize: batchSize, validationRatio: validationRatio, seed: seed)
        train = splits.train
        valid = splits.valid
        if let systemPrompt {
            self.systemPrompt = systemPrompt
        }
    }

    private struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }
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
