import Foundation

@MainActor
final class ModelHostsCoordinator: ObservableObject {
    @Published private(set) var hosts: [ModelHost] = []
    @Published private(set) var inventories: [UUID: HostInventory] = [:]
    @Published private(set) var refreshing: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var storageError: String?
    @Published private(set) var resourcePreview: HostResourcePreview?
    @Published private(set) var resourceBusy = false
    @Published private(set) var resourceApplying = false
    @Published private(set) var resourceMessage: String?
    @Published private(set) var resourceHostID: UUID?
    var resourceUseBlocked: () -> Bool = { false }
    private let store: JSONStore<ModelHost>
    private let fetch: @Sendable (ModelHost, String?) async throws -> HostInventory
    private let readToken: (UUID) throws -> String?
    private let writeToken: (String?, UUID) throws -> Void
    private var generations: [UUID: UUID] = [:]
    private let inspectResource: @Sendable (ModelHost, HostResourceSelection, String?) async throws -> HostResourcePreview
    private let releaseResource: @Sendable (HostResourcePreview, String?) async throws -> Void
    private var resourceGeneration = UUID()

    init(store: JSONStore<ModelHost> = JSONStore(fileURL: JSONStore<ModelHost>.defaultFileURL("model-hosts.json")),
         readToken: @escaping (UUID) throws -> String? = HostCredentialStore.token,
         writeToken: @escaping (String?, UUID) throws -> Void = HostCredentialStore.setToken,
         fetch: @escaping @Sendable (ModelHost, String?) async throws -> HostInventory = { host, token in
             try await ModelHostClient().inventory(host: host, token: token)
         },
         inspectResource: @escaping @Sendable (ModelHost, HostResourceSelection, String?) async throws -> HostResourcePreview = { host, selection, token in
             try await HostResourceClient().preview(host: host, selection: selection, token: token)
         },
         releaseResource: @escaping @Sendable (HostResourcePreview, String?) async throws -> Void = { preview, token in
             try await HostResourceClient().release(preview: preview, token: token)
         }) {
        self.store = store; self.fetch = fetch; self.readToken = readToken; self.writeToken = writeToken
        self.inspectResource = inspectResource; self.releaseResource = releaseResource
        do {
            let saved = try store.load()
            guard Set(saved.map(\.id)).count == saved.count else { throw HostedIntegrationError.invalid("Saved host identities are duplicated.") }
            for host in saved { _ = try host.validatedURL() }
            hosts = saved
        } catch { storageError = "Model hosts could not be read. Resolve the saved host file before editing it." }
    }

    func token(for id: UUID) throws -> String? { try readToken(id) }

    /// Checks the unsaved connection through the same read-only adapter as Refresh.
    /// Neither host state, published inventory nor Keychain is modified.
    func checkConnection(_ host: ModelHost, token: String?, replaceToken: Bool) async throws -> HostInventory {
        _ = try host.validatedURL()
        if let message = host.validationMessage { throw HostedIntegrationError.invalid(message) }
        let credential = replaceToken ? (token?.isEmpty == true ? nil : token) : try readToken(host.id)
        let result = try await fetch(host, credential)
        try Task.checkCancellation()
        guard result.host == host, result.models.allSatisfy({ $0.hostID == host.id }),
              Set(result.models.map(\.id)).count == result.models.count else { throw HostHTTPError.invalidResponse }
        return result
    }

    func save(_ host: ModelHost, token: String?, replaceToken: Bool) throws {
        guard !resourceBusy else { throw HostedIntegrationError.invalid("Wait for the host memory operation to finish.") }
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
        cancelResourcePreview()
    }

    func remove(_ id: UUID) throws {
        guard !resourceBusy else { throw HostedIntegrationError.invalid("Wait for the host memory operation to finish.") }
        guard storageError == nil else { throw HostedIntegrationError.invalid(storageError!) }
        guard try store.update(id: id, keyPath: \.id, transform: { _ in nil }) else {
            throw HostedIntegrationError.invalid("This host is no longer saved. Reopen the host list.")
        }
        hosts.removeAll { $0.id == id }; inventories[id] = nil; generations[id] = UUID()
        refreshing.remove(id); errors[id] = nil
        cancelResourcePreview()
        do { try writeToken(nil, id) }
        catch { throw HostedIntegrationError.invalid("The host was removed, but its Keychain credential could not be removed.") }
    }

    func prepareResource(hostID: UUID, selection: HostResourceSelection) async {
        guard !resourceBusy else { return }
        resourcePreview = nil; resourceMessage = nil
        resourceHostID = hostID
        guard storageError == nil else { resourceMessage = storageError; return }
        guard let host = hosts.first(where: { $0.id == hostID }) else { resourceMessage = "This host connection is no longer saved."; return }
        guard !resourceUseBlocked() else { resourceMessage = "Finish the active Workbench comparison before unloading models."; return }
        let generation = UUID(); resourceGeneration = generation; resourceBusy = true
        defer { if resourceGeneration == generation { resourceBusy = false } }
        do {
            let preview = try await inspectResource(host, selection, readToken(host.id))
            guard !Task.isCancelled, resourceGeneration == generation, hosts.contains(host) else { return }
            guard !resourceUseBlocked() else { throw HostedIntegrationError.invalid("Finish the active Workbench comparison before unloading models.") }
            guard preview.host == host, preview.selection == selection else { throw HostHTTPError.invalidResponse }
            resourcePreview = preview
        } catch { if resourceGeneration == generation { resourceMessage = AppHost.render(error) } }
    }

    func cancelResourcePreview() {
        guard !resourceApplying else { return }
        resourceGeneration = UUID(); resourcePreview = nil; resourceBusy = false; resourceMessage = nil
    }

    func confirmResource() async {
        guard !resourceBusy, let preview = resourcePreview else { return }
        guard storageError == nil, hosts.contains(preview.host), !resourceUseBlocked() else {
            resourcePreview = nil
            resourceMessage = storageError ?? "The connection changed or a Workbench comparison is active. Check again before unloading."; return
        }
        let generation = UUID(); resourceGeneration = generation; resourceBusy = true; resourceMessage = nil
        defer { if resourceGeneration == generation { resourceBusy = false; resourceApplying = false } }
        do {
            let token = try readToken(preview.host.id)
            let fresh = try await inspectResource(preview.host, preview.selection, token)
            guard !Task.isCancelled, resourceGeneration == generation, hosts.contains(preview.host) else { return }
            guard fresh.host == preview.host, fresh.selection == preview.selection, !resourceUseBlocked() else {
                throw HostedIntegrationError.invalid("The connection changed or a Workbench comparison is active. Check again before unloading.")
            }
            guard preview.matches(fresh) else {
                resourcePreview = fresh
                resourceMessage = "Activity or model details changed. Review the updated check and confirm again."; return
            }
            resourcePreview = nil; resourceApplying = true
            var outcome = "Request accepted."
            do { try await releaseResource(fresh, token) }
            catch {
                if case HostHTTPError.httpStatus(let status) = error { outcome = "Request rejected (HTTP \(status))." }
                else { outcome = "Request outcome unknown. The host may have accepted it. No automatic retry was made." }
            }
            let refreshed = await refresh(preview.host.id)
            guard resourceGeneration == generation else { return }
            resourceMessage = outcome + " " + resourceReadback(fresh, refreshed: refreshed)
        } catch {
            if resourceGeneration == generation { resourcePreview = nil; resourceMessage = AppHost.render(error) }
        }
    }

    private func resourceReadback(_ preview: HostResourcePreview, refreshed: Bool) -> String {
        guard refreshed, errors[preview.host.id] == nil, let inventory = inventories[preview.host.id] else {
            return "A fresh inventory could not be read; the previous inventory is retained. Memory release could not be verified."
        }
        if preview.host.provider == .comfyUI {
            return "ComfyUI does not report completion of memory cleanup; released memory could not be verified."
        }
        guard let model = inventory.models.first(where: { $0.modelID == preview.selection.modelID }) else {
            return "The model is absent from the refreshed inventory; memory release could not be verified."
        }
        if preview.host.provider == .ollama {
            guard let digest = preview.model?.digest, model.digest == digest else {
                return "The model identity changed; unloading the selected weights could not be verified."
            }
        }
        if preview.host.provider == .lmStudio {
            guard let instances = model.loadedInstanceIDs, let instance = preview.selection.instanceID else {
                return "Loaded-instance state is unavailable; memory release could not be verified."
            }
            return instances.contains(instance) ? "The selected instance is still reported loaded." : "The selected instance is no longer loaded."
        }
        switch model.isLoaded {
        case false: return "The model is no longer loaded."
        case true: return "The model is still reported loaded."
        case nil: return "Loaded state is unknown; memory release could not be verified."
        }
    }

    @discardableResult
    func refresh(_ id: UUID) async -> Bool {
        guard let host = hosts.first(where: { $0.id == id }), !refreshing.contains(id) else { return false }
        let generation = UUID(); generations[id] = generation; refreshing.insert(id); errors[id] = nil
        defer { if generations[id] == generation { refreshing.remove(id) } }
        do {
            let result = try await fetch(host, readToken(id))
            guard !Task.isCancelled, generations[id] == generation, hosts.contains(host) else { return false }
            guard result.host == host, result.models.allSatisfy({ $0.hostID == id }),
                  Set(result.models.map(\.id)).count == result.models.count else {
                throw HostedIntegrationError.invalid("The host returned inconsistent model identities.")
            }
            inventories[id] = result
            return true
        } catch {
            guard generations[id] == generation, hosts.contains(host) else { return false }
            let retained = inventories[id] == nil ? "No inventory is available yet." : "Previous inventory retained."
            errors[id] = error is CancellationError ? "Refresh cancelled. \(retained)"
                : "Refresh failed. \(ModelHostConnectionCheck.guidance(for: error)) \(retained)"
            return false
        }
    }
}
