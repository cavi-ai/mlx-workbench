import Foundation
import os

// MARK: - HFRepoID
//
// Repo identities are for display, wiring and compatibility with older serve
// receipts. Launches preserve exact local paths through --path, including
// Hugging Face snapshots; they must not resolve that repo again for execution.

enum HFRepoID {
    /// The repo id for a path inside the Hugging Face cache layout, else nil.
    static func forPath(_ path: String) -> String? {
        let components = URL(filePath: NSString(string: path).expandingTildeInPath, directoryHint: .notDirectory)
            .standardizedFileURL
            .pathComponents
        guard let marker = components.first(where: { $0.hasPrefix("models--") }) else { return nil }
        let id = marker.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
        return id.isEmpty || id.hasPrefix("/") ? nil : id
    }

    /// The identity serve status reports for a model: its repo id when the
    /// path is in the HF cache, else the path itself. Use when comparing a
    /// library model path against `ServerInfo.repo`.
    static func serveIdentity(for path: String) -> String {
        guard path.hasPrefix("/") || path.hasPrefix("~") else { return path }
        if let known = resolvedPaths.withLock({ $0[path] }) { return known }
        let resolved = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        resolvedPaths.withLock { cache in
            if cache.count >= maximumResolvedPaths { cache.removeAll(keepingCapacity: true) }
            cache[path] = resolved
        }
        return resolved
    }

    static func forgetResolvedPaths() {
        resolvedPaths.withLock { $0.removeAll() }
    }

    /// Current path receipts distinguish revisions. Older repo-only receipts
    /// remain compatible without collapsing two explicit filesystem paths.
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        Identity(lhs).matches(Identity(rhs))
    }

    struct Identity: Hashable, Sendable {
        let resolvedPath: String?
        let repoKey: String

        init(_ value: String) {
            let serve = HFRepoID.serveIdentity(for: value)
            resolvedPath = serve.hasPrefix("/") ? serve : nil
            repoKey = HFRepoID.forPath(value) ?? serve
        }

        func matches(_ other: Identity) -> Bool {
            if let resolvedPath, let otherPath = other.resolvedPath { return resolvedPath == otherPath }
            return repoKey == other.repoKey
        }
    }

    private static let maximumResolvedPaths = 4096
    private static let resolvedPaths = OSAllocatedUnfairLock(initialState: [String: String]())
}
