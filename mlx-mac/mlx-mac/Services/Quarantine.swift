import Foundation

// MARK: - Quarantine
//
// Swift port of mlx_workbench/quarantine.py — identical semantics: move
// (never delete) a redundant `.gguf` into the quarantine directory and record
// where it came from, so the user can review, restore, or delete it
// themselves. Only `.gguf` files inside a configured scan root may move.

enum QuarantineError: LocalizedError {
    case notGGUF(String)
    case notFound(String)
    case outsideRoots(String)
    case alreadyQuarantined(String)
    case moveFailed(String)

    var errorDescription: String? {
        switch self {
        case .notGGUF:
            return "Only .gguf files can be moved from here. Move anything else yourself, deliberately."
        case .notFound(let path):
            return "No file at \(path). Rescan; the file may already have been moved."
        case .outsideRoots(let path):
            return "\(path) is not under any configured scan root. Add its directory to gguf_roots first, or move the file yourself."
        case .alreadyQuarantined(let path):
            return "\(path) is already in the quarantine directory."
        case .moveFailed(let detail):
            return "The file could not be moved: \(detail). Check free space and permissions on the quarantine directory."
        }
    }
}

struct QuarantineRecord: Codable, Equatable, Sendable {
    let movedAt: String
    let from: String
    let to: String
    let bytes: Int64

    enum CodingKeys: String, CodingKey {
        case from, to, bytes
        case movedAt = "moved_at"
    }
}

enum Quarantine {
    static let ledgerName = "quarantine-ledger.jsonl"
    static let maxLedgerBytes = 4 * 1024 * 1024

    /// Allow only .gguf files that live under a configured scan root.
    /// Returns the canonical resolved path.
    static func guardPath(_ target: String, roots: [String], fileManager: FileManager = .default) throws -> String {
        let location = resolve(target)
        guard location.lowercased().hasSuffix(".gguf") else {
            throw QuarantineError.notGGUF(location)
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: location, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw QuarantineError.notFound(location)
        }
        let allowed = roots.map(resolve).filter { !$0.isEmpty }
        guard allowed.contains(where: { isWithin(location, parent: $0) }) else {
            throw QuarantineError.outsideRoots(location)
        }
        return location
    }

    /// Move one redundant GGUF into the quarantine directory. Never deletes.
    @discardableResult
    static func move(
        target: String,
        roots: [String],
        quarantineDir: String,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> QuarantineRecord {
        let location = try guardPath(target, roots: roots, fileManager: fileManager)
        let destinationRoot = resolve(quarantineDir)
        if isWithin(location, parent: destinationRoot) {
            throw QuarantineError.alreadyQuarantined(location)
        }
        try fileManager.createDirectory(atPath: destinationRoot, withIntermediateDirectories: true)

        let stamp = stampFormatter.string(from: now)
        let name = (location as NSString).lastPathComponent
        var destination = "\(destinationRoot)/\(stamp)-\(name)"
        var suffix = 1
        while fileManager.fileExists(atPath: destination) {
            destination = "\(destinationRoot)/\(stamp)-\(suffix)-\(name)"
            suffix += 1
        }

        let size = (try? fileManager.attributesOfItem(atPath: location)[.size] as? Int64) ?? 0
        do {
            try fileManager.moveItem(atPath: location, toPath: destination)
        } catch {
            throw QuarantineError.moveFailed(error.localizedDescription)
        }

        let record = QuarantineRecord(
            movedAt: isoFormatter.string(from: now),
            from: location,
            to: destination,
            bytes: size
        )
        appendLedger(record, quarantineDir: destinationRoot, fileManager: fileManager)
        return record
    }

    /// Recent quarantine records, newest first.
    static func ledger(quarantineDir: String, limit: Int = 200, fileManager: FileManager = .default) -> [QuarantineRecord] {
        let ledgerURL = URL(fileURLWithPath: resolve(quarantineDir)).appendingPathComponent(ledgerName)
        guard let data = try? Data(contentsOf: ledgerURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").suffix(limit).compactMap { line in
            try? decoder.decode(QuarantineRecord.self, from: Data(line.utf8))
        }.reversed()
    }

    // MARK: - Internals

    static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    static func isWithin(_ child: String, parent: String) -> Bool {
        child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    private static func appendLedger(_ record: QuarantineRecord, quarantineDir: String, fileManager: FileManager) {
        let ledgerURL = URL(fileURLWithPath: quarantineDir).appendingPathComponent(ledgerName)
        if let size = try? fileManager.attributesOfItem(atPath: ledgerURL.path)[.size] as? Int64,
           size > maxLedgerBytes {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        var line = data
        line.append(contentsOf: [0x0A])
        if fileManager.fileExists(atPath: ledgerURL.path),
           let handle = try? FileHandle(forWritingTo: ledgerURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: ledgerURL)
        }
    }
}
