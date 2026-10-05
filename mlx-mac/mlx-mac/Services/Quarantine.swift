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
    case restoreBlocked(String)
    case symlinkRefused(String)
    case notInQuarantine(String)
    case changedSincePreview
    case trashFailed(String)

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
        case .restoreBlocked(let path):
            return "Cannot put \(path) back: a file already exists at the original location. Resolve it yourself first."
        case .symlinkRefused(let path):
            return "\(path) is a symbolic link; refusing to move or write through it."
        case .notInQuarantine(let path):
            return "\(path) is not a recorded regular GGUF file in the configured quarantine directory."
        case .changedSincePreview:
            return "The quarantined file changed after preview. Review it again before moving it to Trash."
        case .trashFailed(let detail):
            return "Could not move the file to Trash: \(detail). Refresh quarantine before retrying."
        }
    }
}

struct QuarantineRecord: Codable, Equatable, Sendable {
    let movedAt: String
    let from: String
    let to: String
    let bytes: Int64
    var deletedAt: String? = nil

    enum CodingKeys: String, CodingKey {
        case from, to, bytes
        case movedAt = "moved_at"
        case deletedAt = "deleted_at"
    }
}

struct QuarantineFileSnapshot: Equatable, Sendable {
    let path: String
    let bytes: Int64
    let device: UInt64
    let inode: UInt64
    let modifiedAt: Date
    let createdAt: Date
}

struct QuarantineTrashResult: Sendable {
    let bytes: Int64
    let ledgerWarning: String?
}

enum Quarantine {
    static let ledgerName = "quarantine-ledger.jsonl"
    static let maxLedgerBytes = 4 * 1024 * 1024

    /// Allow only .gguf files that live under a configured scan root.
    /// Returns the canonical resolved path.
    static func guardPath(_ target: String, roots: [String], fileManager: FileManager = .default) throws -> String {
        // A symlinked source must be refused before resolve() follows it:
        // the check runs on the user-supplied path, not the canonical one.
        let expanded = NSString(string: target).expandingTildeInPath
        if (try? fileManager.destinationOfSymbolicLink(atPath: expanded)) != nil {
            throw QuarantineError.symlinkRefused(expanded)
        }
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
        // A symlink at the quarantine dir would redirect where files land;
        // check the user-supplied path before resolve() hides the link.
        let expandedRoot = NSString(string: quarantineDir).expandingTildeInPath
        let destinationRoot = resolve(quarantineDir)
        if fileManager.fileExists(atPath: destinationRoot),
           (try? fileManager.destinationOfSymbolicLink(atPath: expandedRoot)) != nil {
            throw QuarantineError.symlinkRefused(expandedRoot)
        }
        if isWithin(location, parent: destinationRoot) {
            throw QuarantineError.alreadyQuarantined(location)
        }
        try fileManager.createDirectory(atPath: destinationRoot, withIntermediateDirectories: true)
        if (try? fileManager.destinationOfSymbolicLink(atPath: destinationRoot)) != nil {
            throw QuarantineError.symlinkRefused(destinationRoot)
        }

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
        guard !quarantineDir.isEmpty, limit > 0,
              (try? fileManager.destinationOfSymbolicLink(atPath: NSString(string: quarantineDir).expandingTildeInPath)) == nil,
              (try? fileManager.destinationOfSymbolicLink(atPath: ledgerURL.path)) == nil,
              let size = try? fileManager.attributesOfItem(atPath: ledgerURL.path)[.size] as? Int64, size <= maxLedgerBytes,
              let data = try? Data(contentsOf: ledgerURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").suffix(limit).compactMap { line in
            try? decoder.decode(QuarantineRecord.self, from: Data(line.utf8))
        }.reversed()
    }

    /// Files offered for Trash must still belong to this quarantine and its ledger.
    static func trashSnapshot(_ record: QuarantineRecord, quarantineDir: String, fileManager: FileManager = .default) throws -> QuarantineFileSnapshot {
        let path = try guardQuarantinedPath(record.to, quarantineDir: quarantineDir, fileManager: fileManager)
        let attributes = try fileManager.attributesOfItem(atPath: path)
        guard record.deletedAt == nil,
              let bytes = attributes[.size] as? Int64,
              let device = attributes[.systemNumber] as? UInt64,
              let inode = attributes[.systemFileNumber] as? UInt64,
              let modified = attributes[.modificationDate] as? Date,
              let created = attributes[.creationDate] as? Date,
              ledger(quarantineDir: quarantineDir, limit: 10000, fileManager: fileManager).contains(record) else {
            throw QuarantineError.notInQuarantine(record.to)
        }
        return QuarantineFileSnapshot(path: path, bytes: bytes, device: device, inode: inode, modifiedAt: modified, createdAt: created)
    }

    static func guardQuarantinedPath(_ path: String, quarantineDir: String, fileManager: FileManager = .default) throws -> String {
        let expandedRoot = NSString(string: quarantineDir).expandingTildeInPath
        guard expandedRoot.hasPrefix("/"), resolve(expandedRoot) != "/", path.hasPrefix("/") else {
            throw QuarantineError.notInQuarantine(path)
        }
        if (try? fileManager.destinationOfSymbolicLink(atPath: expandedRoot)) != nil {
            throw QuarantineError.symlinkRefused(expandedRoot)
        }
        let root = resolve(expandedRoot)
        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard target.lastPathComponent != ledgerName, target.path.lowercased().hasSuffix(".gguf"),
              target.path != root, isWithin(target.path, parent: root) else {
            throw QuarantineError.notInQuarantine(path)
        }
        var component = target
        while component.path != root {
            if (try? fileManager.destinationOfSymbolicLink(atPath: component.path)) != nil {
                throw QuarantineError.symlinkRefused(component.path)
            }
            component.deleteLastPathComponent()
        }
        let attributes = try fileManager.attributesOfItem(atPath: target.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw QuarantineError.notInQuarantine(path)
        }
        return target.path
    }

    /// Native macOS Trash only. Never fall back to unlinking a file.
    static func trash(_ record: QuarantineRecord, quarantineDir: String, expected: QuarantineFileSnapshot,
                      now: Date = Date(), fileManager: FileManager = .default,
                      trashFile: ((URL) throws -> Void)? = nil) throws -> QuarantineTrashResult {
        let quarantineRoot = resolve(quarantineDir)
        let current = try trashSnapshot(record, quarantineDir: quarantineDir, fileManager: fileManager)
        guard current == expected else { throw QuarantineError.changedSincePreview }
        do {
            let url = URL(fileURLWithPath: current.path)
            if let trashFile { try trashFile(url) }
            else { try fileManager.trashItem(at: url, resultingItemURL: nil) }
        } catch { throw QuarantineError.trashFailed(error.localizedDescription) }
        // Preserve unknown fields and history, matching the web's deleted_at contract.
        do {
            try refuseRootDrift(quarantineDir, expected: quarantineRoot, fileManager: fileManager)
            let ledgerURL = URL(fileURLWithPath: quarantineRoot).appendingPathComponent(ledgerName)
            try JSONStore<QuarantineRecord>.refuseSymlink(ledgerURL, fileManager: fileManager)
            let data = try Data(contentsOf: ledgerURL)
            guard data.count <= maxLedgerBytes, let text = String(data: data, encoding: .utf8) else {
                throw QuarantineError.notInQuarantine(ledgerURL.path)
            }
            let lines = try text.split(separator: "\n").map { line -> String in
                guard var json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      json["to"] as? String == record.to, json["moved_at"] as? String == record.movedAt else { return String(line) }
                json["deleted_at"] = isoFormatter.string(from: now)
                return String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), as: UTF8.self)
            }
            try refuseRootDrift(quarantineDir, expected: quarantineRoot, fileManager: fileManager)
            try JSONStore<QuarantineRecord>.refuseSymlink(ledgerURL, fileManager: fileManager)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: ledgerURL, options: .atomic)
            return QuarantineTrashResult(bytes: current.bytes, ledgerWarning: nil)
        } catch {
            return QuarantineTrashResult(bytes: current.bytes, ledgerWarning: "Moved to Trash, but could not update quarantine history: \(error.localizedDescription)")
        }
    }

    /// Put a quarantined file back where it came from. Extends the Python
    /// original (which has no restore): the guard is the same spirit — move,
    /// never delete, and refuse rather than overwrite. The original location
    /// must be free; the quarantined copy must still exist. The ledger is
    /// left untouched: the record's file simply leaves the quarantine dir.
    static func restore(_ record: QuarantineRecord, fileManager: FileManager = .default) throws {
        let quarantined = resolve(record.to)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: quarantined, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw QuarantineError.notFound(quarantined)
        }
        let original = resolve(record.from)
        // Never write through a symlink when putting a file back; resolve()
        // follows links, so the check must use the unresolved path.
        let expandedOriginal = NSString(string: record.from).expandingTildeInPath
        if (try? fileManager.destinationOfSymbolicLink(atPath: expandedOriginal)) != nil {
            throw QuarantineError.symlinkRefused(original)
        }
        if fileManager.fileExists(atPath: original) {
            throw QuarantineError.restoreBlocked(original)
        }
        do {
            try fileManager.moveItem(atPath: quarantined, toPath: original)
        } catch {
            throw QuarantineError.moveFailed(error.localizedDescription)
        }
    }

    // MARK: - Internals

    private static func refuseRootDrift(_ directory: String, expected: String, fileManager: FileManager) throws {
        let expanded = NSString(string: directory).expandingTildeInPath
        if (try? fileManager.destinationOfSymbolicLink(atPath: expanded)) != nil {
            throw QuarantineError.symlinkRefused(expanded)
        }
        guard resolve(expanded) == expected else { throw QuarantineError.changedSincePreview }
    }

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
        guard (try? fileManager.destinationOfSymbolicLink(atPath: ledgerURL.path)) == nil else { return }
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
