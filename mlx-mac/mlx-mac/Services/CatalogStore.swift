import Foundation

final class CatalogStore {
    enum LoadResult: Equatable {
        case missing
        case corrupt(message: String)
        case snapshot(CatalogSnapshot)
    }

    enum StoreError: LocalizedError, Equatable {
        case payloadTooLarge(actualBytes: Int, maxBytes: Int)
        case unsupportedSchema(Int)
        case invalidMetadataSemantics

        var errorDescription: String? {
            switch self {
            case .payloadTooLarge(let actualBytes, let maxBytes):
                return "Catalog cache exceeds the \(maxBytes)-byte limit (\(actualBytes) bytes)."
            case .unsupportedSchema(let schemaVersion):
                return "Catalog cache schema \(schemaVersion) is not supported."
            case .invalidMetadataSemantics:
                return "Catalog cache contained non-metadata content."
            }
        }
    }

    static let schemaVersion = 1
    static let defaultMaxBytes = 512 * 1024

    private let fileManager: FileManager
    private let appSupportDirectory: () -> URL
    private let maxBytes: Int
    private let cacheFileName: String

    init(
        fileManager: FileManager = .default,
        maxBytes: Int = defaultMaxBytes,
        cacheFileName: String = "catalog-v1.json",
        appSupportDirectory: @escaping () -> URL = CatalogStore.defaultApplicationSupportDirectory
    ) {
        self.fileManager = fileManager
        self.maxBytes = maxBytes
        self.cacheFileName = cacheFileName
        self.appSupportDirectory = appSupportDirectory
    }

    func cacheURL() -> URL {
        appSupportDirectory()
            .appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent(cacheFileName, isDirectory: false)
    }

    func load() -> LoadResult {
        let location = cacheURL()
        guard fileManager.fileExists(atPath: location.path) else {
            return .missing
        }

        do {
            let data = try Data(contentsOf: location)
            guard data.count <= maxBytes else {
                throw StoreError.payloadTooLarge(actualBytes: data.count, maxBytes: maxBytes)
            }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.schemaVersion == Self.schemaVersion else {
                throw StoreError.unsupportedSchema(envelope.schemaVersion)
            }
            guard envelope.snapshot.metadataOnly else {
                throw StoreError.invalidMetadataSemantics
            }
            return .snapshot(envelope.snapshot)
        } catch {
            return .corrupt(message: Self.describe(error))
        }
    }

    func save(_ snapshot: CatalogSnapshot) throws {
        guard snapshot.metadataOnly else {
            throw StoreError.invalidMetadataSemantics
        }

        let envelope = Envelope(schemaVersion: Self.schemaVersion, snapshot: snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(envelope)
        guard data.count <= maxBytes else {
            throw StoreError.payloadTooLarge(actualBytes: data.count, maxBytes: maxBytes)
        }

        let location = cacheURL()
        let directory = location.deletingLastPathComponent()
        let temp = location.appendingPathExtension("tmp")

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: temp.path) {
            try? fileManager.removeItem(at: temp)
        }

        do {
            try data.write(to: temp, options: .atomic)
            if fileManager.fileExists(atPath: location.path) {
                _ = try fileManager.replaceItemAt(
                    location,
                    withItemAt: temp,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try fileManager.moveItem(at: temp, to: location)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    private static func defaultApplicationSupportDirectory() -> URL {
        if let url = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return url.appendingPathComponent("mlx-workbench", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/mlx-workbench", isDirectory: true)
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let snapshot: CatalogSnapshot

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case snapshot
        }
    }
}
