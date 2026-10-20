import Foundation

@MainActor
final class ModelHostsCoordinator: ObservableObject {
    @Published private(set) var hosts: [ModelHost] = []
    @Published private(set) var inventories: [UUID: HostInventory] = [:]
    @Published private(set) var refreshing: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var storageError: String?
    private let store: JSONStore<ModelHost>
    private let fetch: @Sendable (ModelHost, String?) async throws -> HostInventory
    private let readToken: (UUID) throws -> String?
    private let writeToken: (String?, UUID) throws -> Void
    private var generations: [UUID: UUID] = [:]

    init(store: JSONStore<ModelHost> = JSONStore(fileURL: JSONStore<ModelHost>.defaultFileURL("model-hosts.json")),
         readToken: @escaping (UUID) throws -> String? = HostCredentialStore.token,
         writeToken: @escaping (String?, UUID) throws -> Void = HostCredentialStore.setToken,
         fetch: @escaping @Sendable (ModelHost, String?) async throws -> HostInventory = { host, token in
             try await ModelHostClient().inventory(host: host, token: token)
         }) {
        self.store = store; self.fetch = fetch; self.readToken = readToken; self.writeToken = writeToken
        do {
            let saved = try store.load()
            guard Set(saved.map(\.id)).count == saved.count else { throw HostedIntegrationError.invalid("Saved host identities are duplicated.") }
            for host in saved { _ = try host.validatedURL() }
            hosts = saved
        } catch { storageError = "Model hosts could not be read. Resolve the saved host file before editing it." }
    }

    func token(for id: UUID) throws -> String? { try readToken(id) }

    func save(_ host: ModelHost, token: String?, replaceToken: Bool) throws {
        guard storageError == nil else { throw HostedIntegrationError.invalid(storageError!) }
        _ = try host.validatedURL()
        guard !host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, host.name.count <= 120 else {
            throw HostedIntegrationError.invalid("Enter a host name of 1–120 characters.")
        }
        let oldToken = replaceToken ? try readToken(host.id) : nil
        if replaceToken { try writeToken(token?.isEmpty == true ? nil : token, host.id) }
        do { try store.upsert(host, id: \.id) }
        catch {
            if replaceToken {
                do { try writeToken(oldToken, host.id) }
                catch { throw HostedIntegrationError.invalid("Host settings were not saved and the previous credential could not be restored. Review the credential before retrying.") }
            }
            throw HostedIntegrationError.invalid("Host settings could not be saved. The previous configuration is unchanged.")
        }
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            if hosts[index] != host { inventories[host.id] = nil }
            hosts[index] = host
        } else { hosts.append(host) }
        generations[host.id] = UUID(); refreshing.remove(host.id); errors[host.id] = nil
    }

    func remove(_ id: UUID) throws {
        guard storageError == nil else { throw HostedIntegrationError.invalid(storageError!) }
        guard try store.update(id: id, keyPath: \.id, transform: { _ in nil }) else {
            throw HostedIntegrationError.invalid("This host is no longer saved. Reopen the host list.")
        }
        hosts.removeAll { $0.id == id }; inventories[id] = nil; generations[id] = UUID()
        refreshing.remove(id); errors[id] = nil
        do { try writeToken(nil, id) }
        catch { throw HostedIntegrationError.invalid("The host was removed, but its Keychain credential could not be removed.") }
    }

    func refresh(_ id: UUID) async {
        guard let host = hosts.first(where: { $0.id == id }), !refreshing.contains(id) else { return }
        let generation = UUID(); generations[id] = generation; refreshing.insert(id); errors[id] = nil
        defer { if generations[id] == generation { refreshing.remove(id) } }
        do {
            let result = try await fetch(host, readToken(id))
            guard !Task.isCancelled, generations[id] == generation, hosts.contains(host) else { return }
            guard result.host == host, result.models.allSatisfy({ $0.hostID == id }),
                  Set(result.models.map(\.id)).count == result.models.count else {
                throw HostedIntegrationError.invalid("The host returned inconsistent model identities.")
            }
            inventories[id] = result
        } catch {
            guard generations[id] == generation, hosts.contains(host) else { return }
            errors[id] = error is CancellationError ? "Refresh cancelled. Previous inventory retained." : "Refresh failed. Check the host address, credentials and running server. Previous inventory retained."
        }
    }
}
