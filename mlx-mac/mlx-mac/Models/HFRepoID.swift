import Foundation

// MARK: - HFRepoID
//
// The pinned mlx-agent's `serve start` accepts Hugging Face repo ids
// (org/name) present in the local HF cache, and refuses filesystem paths
// (model_not_local). Library models that live inside the HF cache layout
// (…/hub/models--org--name/snapshots/<rev>/…) therefore must be served by
// repo id. This mapper is the single place that translation happens;
// paths outside the HF layout pass through unchanged.

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
        forPath(path) ?? path
    }
}
