import Foundation

protocol CatalogMetadataProviding {
    func fetchCatalogMetadata() async throws -> CatalogSnapshot
}

protocol CatalogRefreshing {
    var isConfigured: Bool { get }
    var unavailableMessage: String { get }

    func refresh() async throws -> CatalogSnapshot
}

enum CatalogClientError: LocalizedError, Equatable {
    case unavailable(String)
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidPayload(let message):
            return message
        }
    }
}

struct CatalogClient: CatalogRefreshing {
    let provider: (any CatalogMetadataProviding)?
    let unavailableMessage: String

    init(
        provider: (any CatalogMetadataProviding)? = nil,
        unavailableMessage: String = "Catalog metadata refresh is unavailable because no provider is configured."
    ) {
        self.provider = provider
        self.unavailableMessage = unavailableMessage
    }

    var isConfigured: Bool {
        provider != nil
    }

    func refresh() async throws -> CatalogSnapshot {
        guard let provider else {
            throw CatalogClientError.unavailable(unavailableMessage)
        }

        let snapshot = try await provider.fetchCatalogMetadata()
        guard snapshot.metadataOnly else {
            throw CatalogClientError.invalidPayload(
                "Catalog refresh returned non-metadata content; only metadata-only payloads are supported."
            )
        }
        return snapshot
    }
}
