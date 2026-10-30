import Foundation

/// Which models active work holds right now. Stop and unload refusals and reclaim
/// protection read the same claims and one identity rule (`HFRepoID.matches`).
struct ModelOccupancy: Equatable, Sendable {
    enum Holder: Equatable, Sendable {
        case verification, comparison, hostedComparison, promptTest
        case runningServer, endpoint, preference, retention, inferenceTask, conversion

        /// Runs that serve the model themselves and fail if its server stops.
        var needsServer: Bool { self == .verification || self == .comparison || self == .hostedComparison || self == .promptTest }
    }

    struct Claim: Equatable, Sendable {
        let identity: String
        let holder: Holder
        let key: HFRepoID.Identity

        init(identity: String, holder: Holder) {
            self.identity = identity
            self.holder = holder
            key = HFRepoID.Identity(identity)
        }
    }

    struct LibraryPath: Equatable, Sendable {
        let path: String
        let key: HFRepoID.Identity
    }

    private(set) var claims: [Claim] = []
    private let library: [LibraryPath]

    init(libraryPaths: [String] = []) {
        library = libraryPaths.map { LibraryPath(path: $0, key: HFRepoID.Identity($0)) }
    }

    init(library: [LibraryPath]) { self.library = library }

    mutating func add(_ identities: some Sequence<String>, for holder: Holder) {
        claims += identities.filter { !$0.isEmpty }.map { Claim(identity: $0, holder: holder) }
    }

    /// Whether stopping or unloading this model's server would break a run that serves it.
    func blocksStop(modelIdentity: String, excluding holder: Holder? = nil) -> Bool {
        let key = HFRepoID.Identity(modelIdentity)
        return claims.contains { $0.holder != holder && $0.holder.needsServer && $0.key.matches(key) }
    }

    func blocksStop(_ server: ServerInfo, excluding holder: Holder? = nil) -> Bool {
        blocksStop(modelIdentity: server.modelIdentity, excluding: holder)
    }

    /// Claimed identities plus every library path one of them matches; reclaim and
    /// model guidance never move these.
    var protectedPaths: Set<String> {
        let claimedPaths = Set(claims.compactMap(\.key.resolvedPath))
        let repoClaims = Set(claims.filter { $0.key.resolvedPath == nil }.map(\.key.repoKey))
        let pathClaimRepos = Set(claims.filter { $0.key.resolvedPath != nil }.map(\.key.repoKey))
        return Set(claims.map(\.identity)).union(library.filter { entry in
            if repoClaims.contains(entry.key.repoKey) { return true }
            if let path = entry.key.resolvedPath { return claimedPaths.contains(path) }
            return pathClaimRepos.contains(entry.key.repoKey)
        }.map(\.path))
    }
}
