import Foundation

// MARK: - HFRepoID
//
// Repo identities are for display, wiring and compatibility with older serve
// receipts. Launches preserve exact local paths through --path, including
// Hugging Face snapshots; they must not resolve that repo again for execution.

enum HFRepoID {
    /// The repo id for a path inside the Hugging Face cache layout, else nil.
    static func forPath(_ path: String) -> String? {
        let components = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
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
        if path.hasPrefix("/") || path.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return path
    }

    /// Current path receipts distinguish revisions. Older repo-only receipts
    /// remain compatible without collapsing two explicit filesystem paths.
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let a = serveIdentity(for: lhs), b = serveIdentity(for: rhs)
        if a.hasPrefix("/"), b.hasPrefix("/") { return a == b }
        return (forPath(lhs) ?? a) == (forPath(rhs) ?? b)
    }
}
