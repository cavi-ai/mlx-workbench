import Foundation

// MARK: - EndpointFleetStore
//
// Fleet persistence (spec 09 P1): the `endpoint-fleet.json` store plus the
// one-time migration from the legacy single-endpoint `endpoint-config.json`.
// The legacy file is a read-only migration source — it is never written or
// deleted, so a downgrade finds it untouched (same discipline as quarantine
// and corrupt-queue preservation).

struct EndpointFleetLoad: Equatable {
    let config: EndpointFleetConfig
    /// Non-nil when an existing fleet file could not be read (corrupt JSON
    /// or schema mismatch). The file is left in place; the next successful
    /// save replaces it.
    let problem: String?
}

struct EndpointFleetStore {
    let fleetStore: JSONStore<EndpointFleetConfig>
    let legacyStore: JSONStore<EndpointConfig>
    private let fileManager: FileManager

    init(
        fleetStore: JSONStore<EndpointFleetConfig>,
        legacyStore: JSONStore<EndpointConfig>,
        fileManager: FileManager = .default
    ) {
        self.fleetStore = fleetStore
        self.legacyStore = legacyStore
        self.fileManager = fileManager
    }

    /// Derive the fleet store location beside the legacy config file.
    static func defaultFleetStore(
        legacyStore: JSONStore<EndpointConfig>
    ) -> JSONStore<EndpointFleetConfig> {
        JSONStore<EndpointFleetConfig>(
            fileURL: legacyStore.url
                .deletingLastPathComponent()
                .appendingPathComponent("endpoint-fleet.json")
        )
    }

    func load() -> EndpointFleetLoad {
        if fileManager.fileExists(atPath: fleetStore.url.path) {
            do {
                let config = try fleetStore.load().first ?? .empty
                return EndpointFleetLoad(config: config, problem: nil)
            } catch {
                return EndpointFleetLoad(
                    config: .empty,
                    problem: "Saved endpoint fleet is unavailable: \(error.localizedDescription)"
                )
            }
        }
        return migrateLegacy()
    }

    /// Validate invariants, then persist. Validation failures throw before
    /// anything touches disk.
    func save(_ config: EndpointFleetConfig) throws {
        try config.validated()
        try fleetStore.replaceAll([config])
    }

    // MARK: - migration

    private func migrateLegacy() -> EndpointFleetLoad {
        guard let legacy = try? legacyStore.load().first,
              legacy.enabled || !legacy.modelPath.isEmpty else {
            return EndpointFleetLoad(config: .empty, problem: nil)
        }
        let migrated = EndpointFleetConfig(
            slots: [EndpointSlot(
                enabled: legacy.enabled,
                port: legacy.port,
                modelPath: legacy.modelPath,
                role: nil
            )],
            installedAtLogin: legacy.installedAtLogin
        )
        // Persist the migration so it happens once; a save failure is
        // non-fatal (the in-memory config is still correct).
        try? save(migrated)
        return EndpointFleetLoad(config: migrated, problem: nil)
    }
}
