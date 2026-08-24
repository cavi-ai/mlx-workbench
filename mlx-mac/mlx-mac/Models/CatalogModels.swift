import Foundation

enum CatalogFreshness: Codable, Equatable, Hashable {
    case current(fetchedAt: Date, sourceLabel: String)
    case stale(fetchedAt: Date, sourceLabel: String)
    case offline(fetchedAt: Date, sourceLabel: String)

    var fetchedAt: Date {
        switch self {
        case .current(let fetchedAt, _), .stale(let fetchedAt, _), .offline(let fetchedAt, _):
            return fetchedAt
        }
    }

    var sourceLabel: String {
        switch self {
        case .current(_, let sourceLabel), .stale(_, let sourceLabel), .offline(_, let sourceLabel):
            return sourceLabel
        }
    }

    var kind: String {
        switch self {
        case .current:
            return "current"
        case .stale:
            return "stale"
        case .offline:
            return "offline"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        let sourceLabel = try container.decode(String.self, forKey: .sourceLabel)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "current":
            self = .current(fetchedAt: fetchedAt, sourceLabel: sourceLabel)
        case "stale":
            self = .stale(fetchedAt: fetchedAt, sourceLabel: sourceLabel)
        case "offline":
            self = .offline(fetchedAt: fetchedAt, sourceLabel: sourceLabel)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown catalog freshness: \(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(sourceLabel, forKey: .sourceLabel)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case fetchedAt = "fetched_at"
        case sourceLabel = "source_label"
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
