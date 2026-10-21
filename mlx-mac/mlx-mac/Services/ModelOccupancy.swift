import Foundation

/// Which models active work holds right now. Stop and unload refusals and reclaim
/// protection read the same claims and one identity rule (`HFRepoID.matches`).
struct ModelOccupancy: Equatable, Sendable {
    enum Holder: Equatable, Sendable {
        case verification, comparison, hostedComparison
        case runningServer, endpoint, preference, inferenceTask, conversion

        /// Runs that serve the model themselves and fail if its server stops.
        var needsServer: Bool { self == .verification || self == .comparison || self == .hostedComparison }
    }

    struct Claim: Equatable, Sendable {
        let identity: String
        let holder: Holder
    }

    private(set) var claims: [Claim] = []
    private let libraryPaths: [String]

    init(libraryPaths: [String] = []) { self.libraryPaths = libraryPaths }

    mutating func add(_ identities: some Sequence<String>, for holder: Holder) {
        claims += identities.filter { !$0.isEmpty }.map { Claim(identity: $0, holder: holder) }
    }

    /// Whether stopping or unloading this model's server would break a run that serves it.
    func blocksStop(modelIdentity: String) -> Bool {
        claims.contains { $0.holder.needsServer && HFRepoID.matches($0.identity, modelIdentity) }
    }

    func blocksStop(_ server: ServerInfo) -> Bool { blocksStop(modelIdentity: server.modelIdentity) }

    /// Claimed identities plus every library path one of them matches; reclaim and
    /// model guidance never move these.
    var protectedPaths: Set<String> {
        Set(claims.map(\.identity)).union(libraryPaths.filter { path in
            claims.contains { HFRepoID.matches($0.identity, path) }
        })
    }
}
