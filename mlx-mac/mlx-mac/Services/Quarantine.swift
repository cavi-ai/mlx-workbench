import Foundation
import CryptoKit
import Darwin

// MARK: - Quarantine
//
// GGUF parity with the web, plus explicitly reviewed local MLX directories.
// Quarantine moves are reversible; removal uses native macOS Trash only.

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
    case unsafeFolder(String)

    var errorDescription: String? {
        switch self {
        case .notGGUF:
            return "Only .gguf files can be moved from here. Move anything else yourself, deliberately."
        case .notFound(let path):
            return "No file at \(path). Rescan; the file may already have been moved."
        case .outsideRoots(let path):
            return "\(path) is not inside an allowed scan root, or is itself a configured root. Review your scan roots in Settings."
        case .alreadyQuarantined(let path):
            return "\(path) is already in the quarantine directory."
        case .moveFailed(let detail):
            return "The file could not be moved: \(detail). Check free space and permissions on the quarantine directory."
        case .restoreBlocked(let path):
            return "Cannot put \(path) back: a file already exists at the original location. Resolve it yourself first."
        case .symlinkRefused(let path):
            return "\(path) is a symbolic link; refusing to move or write through it."
        case .notInQuarantine(let path):
            return "\(path) is not a recorded GGUF file or MLX folder in the configured quarantine directory."
        case .changedSincePreview:
            return "The item or its configuration changed after preview. Review it again before moving it."
        case .trashFailed(let detail):
            return "Could not move the file to Trash: \(detail). Refresh quarantine before retrying."
        case .unsafeFolder(let detail):
            return "Cannot quarantine this model folder: \(detail)"
        }
    }
}

enum QuarantineKind: String, Codable, Sendable { case mlxDirectory }

struct QuarantineRecord: Codable, Equatable, Sendable {
    let movedAt: String
    let from: String
    let to: String
    let bytes: Int64
    var deletedAt: String? = nil
    var kind: QuarantineKind? = nil

    enum CodingKeys: String, CodingKey {
        case from, to, bytes, kind
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
    var treeFingerprint: String? = nil
    var fileCount: Int? = nil
}

struct QuarantineTrashResult: Sendable {
    let bytes: Int64
    let ledgerWarning: String?
}

enum Quarantine {
    static let ledgerName = "quarantine-ledger.jsonl"
    static let maxLedgerBytes = 4 * 1024 * 1024

    /// Local, independently owned MLX outputs only. Cache snapshots and shared
    /// files require the cache manager's own reference-aware cleanup.
    static func folderSnapshot(target: String, roots: [String], protected: [String], fileManager: FileManager = .default) throws -> QuarantineFileSnapshot {
        let expanded = NSString(string: target).expandingTildeInPath
        try refuseLinks(in: expanded, fileManager: fileManager)
        let path = resolve(target)
        let allowed = roots.filter { !$0.isEmpty }.map(resolve)
        guard allowed.contains(where: { path != $0 && isWithin(path, parent: $0) }),
              !allowed.contains(where: { isWithin($0, parent: path) }) else {
            throw QuarantineError.outsideRoots(path)
        }
        guard HFRepoID.forPath(path) == nil else { throw QuarantineError.unsafeFolder("Hugging Face cache snapshots must be cleaned through Check HF cache.") }
        guard !protected.filter({ $0.hasPrefix("/") }).map(resolve).contains(where: { isWithin(path, parent: $0) || isWithin($0, parent: path) }) else {
            throw QuarantineError.unsafeFolder("the folder is in use, preferred, or contains a protected model.")
        }
        let snapshot = try directorySnapshot(path, fileManager: fileManager)
        let configURL = URL(fileURLWithPath: path).appendingPathComponent("config.json")
        let attrs = try fileManager.attributesOfItem(atPath: configURL.path)
        guard let size = attrs[.size] as? Int64, size <= 1024 * 1024,
              let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any],
              config["quantization"] is [String: Any] || fileManager.fileExists(atPath: path + "/mlx-converter.json") else {
            throw QuarantineError.unsafeFolder("no recognized MLX conversion config.")
        }
        let contents = try fileManager.contentsOfDirectory(atPath: path)
        let hasWeights = contents.contains { $0.hasSuffix(".safetensors") && (try? fileManager.attributesOfItem(atPath: path + "/" + $0)[.type] as? FileAttributeType) == .typeRegular }
        let components = config["components"] as? [String] ?? []
        let hasComponentWeights = !components.isEmpty && components.allSatisfy { name in
            !name.isEmpty && name != "." && name != ".." && !name.contains("/") &&
            ((try? fileManager.contentsOfDirectory(atPath: path + "/" + name))?.contains { $0.hasSuffix(".safetensors") && (try? fileManager.attributesOfItem(atPath: path + "/" + name + "/" + $0)[.type] as? FileAttributeType) == .typeRegular } == true)
        }
        guard hasWeights || hasComponentWeights else { throw QuarantineError.unsafeFolder("no MLX safetensors weights.") }
        return snapshot
    }

    static func moveFolder(expected: QuarantineFileSnapshot, roots: [String], protected: [String], quarantineDir: String,
                           now: Date = Date(), fileManager: FileManager = .default) throws -> QuarantineRecord {
        guard !quarantineDir.isEmpty else { throw QuarantineError.unsafeFolder("configure a quarantine directory first.") }
        try refuseLinks(in: NSString(string: quarantineDir).expandingTildeInPath, fileManager: fileManager)
        let destinationRoot = resolve(quarantineDir)
        guard !isWithin(destinationRoot, parent: expected.path), !isWithin(expected.path, parent: destinationRoot) else {
            throw QuarantineError.alreadyQuarantined(expected.path)
        }
        try fileManager.createDirectory(atPath: destinationRoot, withIntermediateDirectories: true)
        let attributes = try fileManager.attributesOfItem(atPath: destinationRoot)
        guard attributes[.systemNumber] as? UInt64 == expected.device else {
            throw QuarantineError.unsafeFolder("quarantine must be on the same volume for an atomic folder move.")
        }
        let current = try folderSnapshot(target: expected.path, roots: roots, protected: protected, fileManager: fileManager)
        guard current == expected else { throw QuarantineError.changedSincePreview }
        try refuseLinks(in: destinationRoot, fileManager: fileManager)
        let ledgerURL = URL(fileURLWithPath: destinationRoot).appendingPathComponent(ledgerName)
        try JSONStore<QuarantineRecord>.refuseSymlink(ledgerURL, fileManager: fileManager)
        if fileManager.fileExists(atPath: ledgerURL.path) {
            guard fileManager.isWritableFile(atPath: ledgerURL.path),
                  let size = try fileManager.attributesOfItem(atPath: ledgerURL.path)[.size] as? Int64,
                  size < maxLedgerBytes - 4096 else { throw QuarantineError.unsafeFolder("quarantine history is full or unwritable.") }
        }
        let destination = URL(fileURLWithPath: destinationRoot).appendingPathComponent(UUID().uuidString + "-" + URL(fileURLWithPath: current.path).lastPathComponent).path
        try fileManager.moveItem(atPath: current.path, toPath: destination)
        let record = QuarantineRecord(movedAt: isoFormatter.string(from: now), from: current.path, to: destination, bytes: current.bytes, kind: .mlxDirectory)
        // A folder must remain recoverable through its ledger. Roll back if
        // recording fails, rather than reporting an unrecorded move as success.
        do {
            try refuseLinks(in: destinationRoot, fileManager: fileManager)
            try JSONStore<QuarantineRecord>.refuseSymlink(ledgerURL, fileManager: fileManager)
            var data = fileManager.fileExists(atPath: ledgerURL.path) ? try Data(contentsOf: ledgerURL) : Data()
            guard data.count < maxLedgerBytes - 4096 else { throw QuarantineError.unsafeFolder("quarantine history is full.") }
            if !data.isEmpty, data.last != 0x0A { data.append(0x0A) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data.append(try encoder.encode(record))
            data.append(0x0A)
            try data.write(to: ledgerURL, options: .atomic)
        } catch {
            do { try fileManager.moveItem(atPath: destination, toPath: current.path) }
            catch { throw QuarantineError.unsafeFolder("history and rollback failed; recover the folder at \(destination). \(error.localizedDescription)") }
            throw QuarantineError.unsafeFolder("could not record the move; the folder was put back.")
        }
        return record
    }

    private static func refuseLinks(in path: String, fileManager: FileManager) throws {
        var component = URL(fileURLWithPath: path).standardizedFileURL
        while component.path != "/" {
            // macOS exposes these system-owned aliases for its writable volume.
            if ["/var", "/tmp", "/etc"].contains(component.path),
               (try? fileManager.destinationOfSymbolicLink(atPath: component.path)) == "private" + component.path { break }
            if (try? fileManager.destinationOfSymbolicLink(atPath: component.path)) != nil { throw QuarantineError.symlinkRefused(component.path) }
            component.deleteLastPathComponent()
        }
    }

    private static func directorySnapshot(_ path: String, fileManager: FileManager) throws -> QuarantineFileSnapshot {
        let root = try fileManager.attributesOfItem(atPath: path)
        guard root[.type] as? FileAttributeType == .typeDirectory,
              let device = root[.systemNumber] as? UInt64, let inode = root[.systemFileNumber] as? UInt64,
              let modified = root[.modificationDate] as? Date, let created = root[.creationDate] as? Date else {
            throw QuarantineError.unsafeFolder("the selected path is not a model directory.")
        }
        var entries: [String] = []
        var bytes: Int64 = 0
        var fileCount = 0
        var pending = [path]
        while let directory = pending.popLast() {
            for name in try fileManager.contentsOfDirectory(atPath: directory).sorted() {
                let child = directory + "/" + name
                let attrs = try fileManager.attributesOfItem(atPath: child)
                let type = attrs[.type] as? FileAttributeType
                guard type == .typeDirectory || type == .typeRegular,
                      attrs[.systemNumber] as? UInt64 == device else { throw QuarantineError.unsafeFolder("links, special files and mounted volumes are not allowed: \(child)") }
                let size = (attrs[.size] as? Int64) ?? 0
                if type == .typeRegular {
                    guard (attrs[.referenceCount] as? UInt64 ?? 1) == 1 else { throw QuarantineError.unsafeFolder("shared hard-linked files are not allowed: \(child)") }
                    bytes += size
                    fileCount += 1
                } else { pending.append(child) }
                let relative = String(child.dropFirst(path.count))
                let date = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970.bitPattern ?? 0
                var status = stat()
                guard lstat(child, &status) == 0 else { throw QuarantineError.changedSincePreview }
                entries.append("\(relative)|\(type?.rawValue ?? "")|\(attrs[.systemFileNumber] ?? 0)|\(size)|\(date)|\(status.st_ctimespec.tv_sec)|\(status.st_ctimespec.tv_nsec)")
                guard entries.count <= 10000 else { throw QuarantineError.unsafeFolder("more than 10,000 entries; review this folder in Finder.") }
            }
        }
        let fingerprint = SHA256.hash(data: Data(entries.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        return QuarantineFileSnapshot(path: path, bytes: bytes, device: device, inode: inode, modifiedAt: modified, createdAt: created, treeFingerprint: fingerprint, fileCount: fileCount)
    }

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
        let path = try guardQuarantinedPath(record.to, quarantineDir: quarantineDir, kind: record.kind, fileManager: fileManager)
        guard record.deletedAt == nil, ledger(quarantineDir: quarantineDir, limit: 10000, fileManager: fileManager).contains(record) else { throw QuarantineError.notInQuarantine(record.to) }
        if record.kind == .mlxDirectory { return try directorySnapshot(path, fileManager: fileManager) }
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

    static func guardQuarantinedPath(_ path: String, quarantineDir: String, kind: QuarantineKind? = nil, fileManager: FileManager = .default) throws -> String {
        let expandedRoot = NSString(string: quarantineDir).expandingTildeInPath
        if kind == .mlxDirectory { try refuseLinks(in: path, fileManager: fileManager); try refuseLinks(in: expandedRoot, fileManager: fileManager) }
        guard expandedRoot.hasPrefix("/"), resolve(expandedRoot) != "/", path.hasPrefix("/") else {
            throw QuarantineError.notInQuarantine(path)
        }
        if (try? fileManager.destinationOfSymbolicLink(atPath: expandedRoot)) != nil {
            throw QuarantineError.symlinkRefused(expandedRoot)
        }
        let root = resolve(expandedRoot)
        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard target.lastPathComponent != ledgerName, (kind == .mlxDirectory || target.path.lowercased().hasSuffix(".gguf")),
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
        guard attributes[.type] as? FileAttributeType == (kind == .mlxDirectory ? .typeDirectory : .typeRegular) else {
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
        if record.kind == .mlxDirectory { try refuseLinks(in: record.to, fileManager: fileManager) }
        guard fileManager.fileExists(atPath: quarantined, isDirectory: &isDirectory), isDirectory.boolValue == (record.kind == .mlxDirectory) else {
            throw QuarantineError.notFound(quarantined)
        }
        let original = resolve(record.from)
        // Never write through a symlink when putting a file back; resolve()
        // follows links, so the check must use the unresolved path.
        let expandedOriginal = NSString(string: record.from).expandingTildeInPath
        if record.kind == .mlxDirectory { try refuseLinks(in: expandedOriginal, fileManager: fileManager) }
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

struct ConvertedSourcePlan: Equatable {
    let workflow: ConversionWorkflow
    let roots: [String]
    let paths: [String]
    let bytes: Int64
    let fingerprint: String
}

struct ConvertedSourceMove: Codable, Equatable, Identifiable {
    let id: String
    let from: String
    var to: String?
    var batchID: String? = nil
    var workflowID: String? = nil
    var outputPath: String? = nil
    var movedAt: Date? = nil
    var bytes: Int64? = nil
    var trashFingerprint: String? = nil
    var restoredAt: Date? = nil
}

/// Reclaim only sources identified by a successful conversion receipt, after
/// verification. Cache links are references, never independently owned weights.
enum ConvertedSourceCleanup {
    static func preview(workflow: ConversionWorkflow, roots: [String], protected: [String], fileManager fm: FileManager = .default) throws -> ConvertedSourcePlan {
        guard workflow.state == .verified, let receiptPath = workflow.jobReceipt,
              let output = workflow.completedModelPath else { throw refused("the conversion must pass verification first.") }
        try noParentLinks(receiptPath, fm: fm)
        let data = try Data(contentsOf: URL(fileURLWithPath: receiptPath))
        guard data.count <= 1024 * 1024,
              let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              receipt["exit_status"] as? String == "done", let out = receipt["out"] as? String,
              Quarantine.resolve(out) == Quarantine.resolve(output),
              let argv = receipt["argv"] as? [String] else { throw refused("no matching successful conversion receipt.") }
        let outputSnapshot = try Quarantine.folderSnapshot(target: output, roots: roots, protected: [], fileManager: fm)
        let outputEntries = try entries(outputSnapshot.path, fm: fm)
        for path in outputEntries where path.hasSuffix(".safetensors") || path.hasSuffix(".json") {
            if let modified = try fm.attributesOfItem(atPath: path)[.modificationDate] as? Date, modified > workflow.updatedAt {
                throw refused("the converted output changed after verification; verify it again.")
            }
        }
        var sourcePaths = [String]()
        for flag in ["--hf-path", "--lora", "--gguf"] {
            if let index = argv.firstIndex(of: flag), argv.indices.contains(index + 1) { sourcePaths.append(argv[index + 1]) }
        }
        // Older receipts used a repo id; resolve only its existing refs/main.
        if sourcePaths.allSatisfy({ !$0.hasPrefix("/") }) {
            for root in roots {
                let repo = (receipt["repo"] as? String) ?? String(workflow.sourcePath.dropFirst("hf://".count))
                let entry = NSString(string: root).expandingTildeInPath + "/models--" + repo.replacingOccurrences(of: "/", with: "--")
                if let revision = try? String(contentsOfFile: entry + "/refs/main", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                   !revision.isEmpty, !revision.contains("/"), revision != ".", revision != ".." {
                    sourcePaths = [entry + "/snapshots/" + revision]
                    break
                }
            }
        }
        guard !sourcePaths.isEmpty, sourcePaths.allSatisfy({ $0.hasPrefix("/") }) else { throw refused("the receipt does not identify a local source.") }
        let allowed = roots.map(Quarantine.resolve)
        var targets = Set<String>(), cacheRoots = Set<String>(), candidates = Set<String>()
        for source in sourcePaths {
            let components = URL(fileURLWithPath: source).standardizedFileURL.pathComponents
            if let index = components.firstIndex(where: { $0.hasPrefix("models--") }), components.count > index + 2, components[index + 1] == "snapshots" {
                let spelling = NSString.path(withComponents: Array(components.prefix(index + 1)))
                if (try? fm.destinationOfSymbolicLink(atPath: spelling)) != nil { throw QuarantineError.symlinkRefused(spelling) }
                let cacheSpelling = URL(fileURLWithPath: spelling).deletingLastPathComponent().path
                let repo: String
                if roots.contains(where: { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath).standardizedFileURL.path == cacheSpelling }) {
                    // A configured cache alias is supported only through its
                    // physical root; model directories themselves remain fenced.
                    repo = Quarantine.resolve(cacheSpelling) + "/" + components[index]
                } else { repo = spelling }
                try noParentLinks(repo, fm: fm)
                let snapshots = try fm.contentsOfDirectory(atPath: repo + "/snapshots")
                guard snapshots == [components[index + 2]] else { throw refused("the source cache contains other revisions; keep them or review the cache separately.") }
                targets.insert(repo)
                cacheRoots.insert(URL(fileURLWithPath: repo).deletingLastPathComponent().path)
            } else if source.lowercased().hasSuffix(".gguf") {
                try noParentLinks(source, fm: fm)
                targets.insert(try Quarantine.guardPath(source, roots: roots, fileManager: fm))
            } else { throw refused("only receipt-owned GGUF files or single-revision HF sources can be reclaimed.") }
        }
        for target in targets {
            guard allowed.contains(where: { target != $0 && Quarantine.isWithin(target, parent: $0) }),
                  !allowed.contains(where: { Quarantine.isWithin($0, parent: target) }),
                  !Quarantine.isWithin(outputSnapshot.path, parent: target),
                  !Quarantine.isWithin(target, parent: outputSnapshot.path),
                  !isProtected(target, protected: protected) else { throw refused("a source is outside the configured roots or still in use.") }
            for item in try entries(target, fm: fm) {
                if let _ = try? fm.destinationOfSymbolicLink(atPath: item) {
                    let resolved = Quarantine.resolve(item)
                    guard let cache = cacheRoots.first(where: { Quarantine.isWithin(resolved, parent: $0) }) else { throw refused("a source links outside its owned cache.") }
                    if Quarantine.isWithin(resolved, parent: cache + "/blobs") { candidates.insert(resolved) }
                }
            }
        }
        // Walk every configured model root and the entire cache, without
        // following links. A surviving reference protects a shared blob.
        var references = [String]()
        var visited = Set<String>()
        for root in Set(allowed).union(cacheRoots) where fm.fileExists(atPath: root) {
            for item in try entries(root, excluding: targets, fm: fm) where visited.insert(item).inserted {
                if let destination = try? fm.destinationOfSymbolicLink(atPath: item) {
                    candidates.remove(Quarantine.resolve(item))
                    references.append(item + "|" + destination)
                }
            }
        }
        for blob in candidates {
            try noParentLinks(blob, fm: fm)
            let attrs = try fm.attributesOfItem(atPath: blob)
            if attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.referenceCount] as? Int ?? 1) == 1, !isProtected(blob, protected: protected) { targets.insert(blob) }
        }
        let paths = targets.sorted { lhs, rhs in
            // Remove cache references before moving their unshared payloads.
            let ld = (try? fm.attributesOfItem(atPath: lhs)[.type] as? FileAttributeType) == .typeDirectory
            let rd = (try? fm.attributesOfItem(atPath: rhs)[.type] as? FileAttributeType) == .typeDirectory
            return ld == rd ? lhs < rhs : ld
        }
        var states = references + [outputSnapshot.treeFingerprint ?? "", outputSnapshot.path]
        var bytes: Int64 = 0
        for target in paths {
            for item in try entries(target, fm: fm) {
                let attrs = try fm.attributesOfItem(atPath: item)
                let link = (try? fm.destinationOfSymbolicLink(atPath: item)) ?? ""
                let size = attrs[.size] as? Int64 ?? 0
                var status = stat()
                guard lstat(item, &status) == 0 else { throw QuarantineError.changedSincePreview }
                states.append("\(item)|\(status.st_dev)|\(status.st_ino)|\(size)|\(status.st_mtimespec)|\(status.st_ctimespec)|\(link)")
                if attrs[.type] as? FileAttributeType == .typeRegular { bytes += size }
            }
        }
        let fingerprint = SHA256.hash(data: Data(states.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        return ConvertedSourcePlan(workflow: workflow, roots: roots, paths: paths, bytes: bytes, fingerprint: fingerprint)
    }

    static func apply(_ plan: ConvertedSourcePlan, workflow: ConversionWorkflow, roots: [String], protected: [String],
                      fileManager fm: FileManager = .default, journalURL: URL = JSONStore<ConvertedSourceMove>.defaultFileURL("source-cleanup.json"),
                      trash: ((URL) throws -> URL)? = nil) throws -> [ConvertedSourceMove] {
        guard workflow == plan.workflow, roots == plan.roots,
              try preview(workflow: workflow, roots: roots, protected: protected, fileManager: fm).fingerprint == plan.fingerprint else { throw QuarantineError.changedSincePreview }
        let store = JSONStore<ConvertedSourceMove>(fileURL: journalURL, fileManager: fm)
        let batchID = UUID().uuidString
        var moves = [ConvertedSourceMove]()
        for path in plan.paths {
            var move = ConvertedSourceMove(id: UUID().uuidString, from: path, to: nil)
            move.batchID = batchID
            move.workflowID = workflow.id.uuidString
            move.outputPath = workflow.completedModelPath
            try store.upsert(move, id: \.id)
            let destination: URL
            if let trash { destination = try trash(URL(fileURLWithPath: path)) }
            else {
                var url: NSURL?
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &url)
                guard let url else { throw refused("Trash did not return a recovery location; inspect Finder before retrying.") }
                destination = url as URL
            }
            move.to = destination.path
            move.movedAt = Date()
            moves.append(move)
            do { try store.upsert(move, id: \.id) }
            catch { throw refused("moved \(path) to \(destination.path), but could not update recovery history: \(error.localizedDescription)") }
            // Persist the native recovery URL before inspecting the moved tree,
            // so even an interrupted identity capture leaves a Finder location.
            let snapshot = try ConvertedSourceRecovery.snapshot(destination.path, fileManager: fm)
            move.bytes = snapshot.bytes
            move.trashFingerprint = snapshot.fingerprint
            try store.upsert(move, id: \.id)
            moves[moves.count - 1] = move
        }
        return moves
    }

    private static func entries(_ root: String, excluding: Set<String> = [], fm: FileManager) throws -> [String] {
        var result = [String](), pending = [root]
        while let path = pending.popLast() {
            if excluding.contains(path) { continue }
            let attrs = try fm.attributesOfItem(atPath: path)
            result.append(path)
            guard result.count < 100000 else { throw refused("the reference scan is too large; review this source manually.") }
            if attrs[.type] as? FileAttributeType == .typeDirectory {
                pending.append(contentsOf: try fm.contentsOfDirectory(atPath: path).map { path + "/" + $0 })
            }
        }
        return result
    }

    private static func noParentLinks(_ path: String, fm: FileManager) throws {
        var url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
        while url.path != "/" {
            if ["/var", "/tmp", "/etc"].contains(url.path), (try? fm.destinationOfSymbolicLink(atPath: url.path)) == "private" + url.path { break }
            if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil { throw QuarantineError.symlinkRefused(url.path) }
            url.deleteLastPathComponent()
        }
    }

    private static func isProtected(_ path: String, protected: [String]) -> Bool {
        protected.contains { item in
            if item.hasPrefix("/") {
                let canonical = Quarantine.resolve(item)
                return Quarantine.isWithin(path, parent: canonical) || Quarantine.isWithin(canonical, parent: path)
            }
            return HFRepoID.forPath(path) == item
        }
    }

    private static func refused(_ reason: String) -> QuarantineError { .unsafeFolder(reason) }
}
