import Foundation

enum CatalogFreshness: String, Codable, Equatable, Hashable {
    case current
    case stale

    static let metadataTTL: TimeInterval = 24 * 60 * 60

    static func classify(
        fetchedAt: Date,
        now: Date,
        ttl: TimeInterval = metadataTTL
    ) -> CatalogFreshness {
        guard ttl > 0 else { return .stale }
        return now.timeIntervalSince(fetchedAt) <= ttl ? .current : .stale
    }
}

struct CatalogSnapshot: Codable, Equatable, Hashable {
    let provider: String
    let source: String
    let revision: String
    let fetchedAt: Date
    let metadataOnly: Bool
    let records: [CatalogRecord]

    var sourceLabel: String {
        "\(provider) · \(source)"
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case source
        case revision
        case fetchedAt = "fetched_at"
        case metadataOnly = "metadata_only"
        case records
    }
}

enum CatalogState: Equatable {
    case unavailable(message: String)
    case missing
    case corrupt(message: String)
    case current(CatalogSnapshot)
    case stale(CatalogSnapshot)
    case offline(snapshot: CatalogSnapshot?, message: String)

    var snapshot: CatalogSnapshot? {
        switch self {
        case .current(let snapshot), .stale(let snapshot):
            return snapshot
        case .offline(let snapshot, _):
            return snapshot
        case .unavailable, .missing, .corrupt:
            return nil
        }
    }

    var statusLabel: String {
        switch self {
        case .unavailable:
            return "Unavailable"
        case .missing:
            return "Missing"
        case .corrupt:
            return "Corrupt"
        case .current:
            return "Current"
        case .stale:
            return "Stale"
        case .offline:
            return "Offline"
        }
    }

    var detailMessage: String? {
        switch self {
        case .unavailable(let message), .corrupt(let message), .offline(_, let message):
            return message
        case .missing, .current, .stale:
            return nil
        }
    }
}

struct CatalogRecord: Codable, Equatable, Hashable {
    let repoIdentity: String
    let revision: String
    let updatedAt: Date
    let roles: [UseCase]?
    let estimatedMemoryBytes: Int64?
    let formats: [String]
    let sourceURL: URL

    init(
        repoIdentity: String,
        revision: String,
        updatedAt: Date,
        roles: [UseCase]? = nil,
        estimatedMemoryBytes: Int64? = nil,
        formats: [String],
        sourceURL: URL
    ) {
        self.repoIdentity = repoIdentity
        self.revision = revision
        self.updatedAt = updatedAt
        self.roles = roles
        self.estimatedMemoryBytes = estimatedMemoryBytes
        self.formats = formats
        self.sourceURL = sourceURL
    }

    private enum CodingKeys: String, CodingKey {
        case repoIdentity = "repo_identity"
        case revision
        case updatedAt = "updated_at"
        case roles
        case estimatedMemoryBytes = "estimated_memory_bytes"
        case formats
        case sourceURL = "source_url"
    }
}
