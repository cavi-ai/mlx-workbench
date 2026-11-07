import Foundation
import CryptoKit
import Darwin

struct ManagedModelInstall: Codable, Equatable, Sendable {
    let repo: String
    let revision: String
    let path: String
    let signature: String
    let installedAt: Date
    var file: String? = nil
    var subfolder: String? = nil
}

/// Provenance for completed Workbench downloads. Provider caches stay in place.
actor ManagedModelInstallStore {
    private let store: JSONStore<ManagedModelInstall>
    init(store: JSONStore<ManagedModelInstall> = JSONStore(fileURL: JSONStore<ManagedModelInstall>.defaultFileURL("managed-models.json"))) {
        self.store = store
    }
    func records() throws -> [ManagedModelInstall] { try store.load() }
    func record(_ install: ManagedModelInstall) throws {
        guard ModelUpdateReview.isCommit(install.revision), install.path.hasPrefix("/"), !install.signature.isEmpty else {
            throw ModelUpdateError.invalid("The installed model is missing its source revision or file signature.")
        }
        _ = try Self.sourceReference(repo: install.repo, file: install.file, subfolder: install.subfolder)
        try Self.refuseLinks(in: install.path)
        try store.mutate { records in
            records.removeAll { $0.path == install.path }
            records.append(install)
            return records
        }
    }
    /// A changed folder never inherits a recorded repository revision.
    func verifiedRecord(path: String, signature: String) throws -> ManagedModelInstall? {
        try store.load().first { $0.path == path && $0.signature == signature && ModelUpdateReview.isCommit($0.revision) }
    }

    func forget(path: String) throws {
        try store.mutate { records in records.removeAll { $0.path == path }; return records }
    }

    nonisolated static func directory(root: String, source: IntakeSource, file: String? = nil) -> String? {
        let selectedFile = file ?? source.file
        guard (try? sourceReference(repo: source.repo, file: selectedFile, subfolder: source.subfolder)) != nil else { return nil }
        let parts = source.repo.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let revision = source.fetchRevision
        let component = ModelUpdateReview.isCommit(revision) ? revision.lowercased() : "download-" + UUID().uuidString.lowercased()
        var destination = URL(fileURLWithPath: root).appendingPathComponent("managed").appendingPathComponent(parts[0])
            .appendingPathComponent(parts[1])
        if let selection = selectedFile.map({ "file:" + $0 }) ?? source.subfolder.map({ "subfolder:" + $0 }) {
            let digest = SHA256.hash(data: Data(selection.utf8)).map { String(format: "%02x", $0) }.joined()
            destination.appendPathComponent("selection-" + String(digest.prefix(32)))
        }
        return destination.appendingPathComponent(component).path
    }

    nonisolated static func sourceReference(repo: String, file: String?, subfolder: String?) throws -> String {
        let repoParts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard repoParts.count == 2, repoParts.allSatisfy({ validSourceComponent(String($0), limit: 96) }),
              file == nil || subfolder == nil else {
            throw ModelUpdateError.invalid("The previous model has an invalid source selection. Review it in Add from Hugging Face.")
        }
        if let file {
            guard file.lowercased().hasSuffix(".gguf"), validSourcePath(file) else {
                throw ModelUpdateError.invalid("The previous model has an invalid source file.")
            }
            return "https://huggingface.co/\(repo)/blob/main/\(file)"
        }
        if let subfolder {
            guard validSourcePath(subfolder) else { throw ModelUpdateError.invalid("The previous model has an invalid checkpoint folder.") }
            return "\(repo)/\(subfolder)"
        }
        return repo
    }

    /// Cache layout records the selected checkpoint beneath its immutable snapshot.
    nonisolated static func cacheSelection(path: String, repo: String) -> (revision: String, file: String?, subfolder: String?)? {
        guard HFRepoID.forPath(path)?.caseInsensitiveCompare(repo) == .orderedSame else { return nil }
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard let marker = parts.firstIndex(where: { $0.hasPrefix("models--") }),
              marker + 2 < parts.count, parts[marker + 1] == "snapshots",
              ModelUpdateReview.isCommit(parts[marker + 2]) else { return nil }
        let remainder = Array(parts.dropFirst(marker + 3))
        let selection = remainder.isEmpty ? nil : remainder.joined(separator: "/")
        let file = selection?.lowercased().hasSuffix(".gguf") == true ? selection : nil
        let subfolder = file == nil ? selection : nil
        guard (try? sourceReference(repo: repo, file: file, subfolder: subfolder)) != nil else { return nil }
        return (parts[marker + 2], file, subfolder)
    }

    /// Legacy records without checkpoint selection are valid only at the repo root.
    nonisolated static func matchesManagedSourcePath(_ install: ManagedModelInstall, root: String) -> Bool {
        let source = IntakeSource(input: install.repo, repo: install.repo, revision: install.revision,
            file: install.file, subfolder: install.subfolder, url: "https://huggingface.co/\(install.repo)")
        guard let directory = directory(root: root, source: source),
              (try? sourceReference(repo: install.repo, file: install.file, subfolder: install.subfolder)) != nil else { return false }
        let suffix = install.file ?? install.subfolder
        let expected = suffix.map { URL(fileURLWithPath: directory).appendingPathComponent($0).path } ?? directory
        return URL(fileURLWithPath: install.path).standardizedFileURL.path == expected
    }

    nonisolated private static func validSourcePath(_ path: String) -> Bool {
        !path.isEmpty && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { validSourceComponent(String($0), limit: 255) }
    }

    nonisolated private static func validSourceComponent(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.count <= limit && value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    }

    /// Bounded metadata identity, including each weight's inode and change time.
    /// Cache links may resolve only into that repository's blob directory.
    nonisolated static func signature(path: String) throws -> String {
        try refuseLinks(in: path)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let parts = root.pathComponents
        let cacheBlobs: String? = parts.firstIndex(of: "snapshots").map {
            NSString.path(withComponents: Array(parts.prefix($0))) + "/blobs/"
        }
        var pending = [root]
        var facts: [String] = []
        while let item = pending.popLast() {
            var info = stat()
            guard lstat(item.path, &info) == 0 else { throw ModelUpdateError.invalid("The model files changed or cannot be read. Scan and review again.") }
            let kind = info.st_mode & S_IFMT
            let relative = String(item.path.dropFirst(root.path.count))
            facts.append("\(relative)|\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec)|\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec)|\(info.st_ctimespec.tv_nsec)")
            if kind == S_IFLNK {
                let target = item.resolvingSymlinksInPath()
                guard let cacheBlobs, HFRepoID.forPath(path) != nil, target.path.hasPrefix(cacheBlobs),
                      let attrs = try? fm.attributesOfItem(atPath: target.path), attrs[.type] as? FileAttributeType == .typeRegular else {
                    throw ModelUpdateError.invalid("The model contains an unowned link. Review its storage before updating.")
                }
                var targetInfo = stat()
                guard stat(target.path, &targetInfo) == 0 else { throw ModelUpdateError.invalid("A model cache blob is missing.") }
                facts.append("\(target.path)|\(targetInfo.st_ino)|\(targetInfo.st_size)|\(targetInfo.st_mtimespec.tv_sec)|\(targetInfo.st_ctimespec.tv_sec)|\(targetInfo.st_ctimespec.tv_nsec)")
            } else if kind == S_IFDIR {
                pending += try fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
            } else if kind != S_IFREG {
                throw ModelUpdateError.invalid("The model contains a special file. Review its storage before updating.")
            }
            guard facts.count + pending.count <= 10000 else { throw ModelUpdateError.invalid("The model has too many files for a bounded update review.") }
        }
        return SHA256.hash(data: Data(facts.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func refuseLinks(in path: String) throws {
        guard path.hasPrefix("/") else { throw ModelUpdateError.invalid("Choose an absolute managed model folder.") }
        var component = URL(fileURLWithPath: path).standardizedFileURL
        while component.path != "/" {
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: component.path) {
                if ["/var", "/tmp", "/etc"].contains(component.path), target == "private" + component.path { return }
                throw ModelUpdateError.invalid("The managed model path contains a symbolic link: \(component.path). Choose its original folder.")
            }
            component.deleteLastPathComponent()
        }
    }
}
