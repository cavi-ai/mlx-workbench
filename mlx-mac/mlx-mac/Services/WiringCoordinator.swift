import Combine
import CryptoKit
import Foundation
import Darwin

// MARK: - WiringCoordinator
//
// Cross-client Wiring (premium spec 02): detect installed clients, compute
// per-client edit plans, preview them with a hash (same grammar as
// convert/serve), then apply as one transaction — atomic writes, per-file
// backups, drift re-check at confirm, and one-click rollback.

enum WiringError: LocalizedError {
    case noPlansPreviewed
    case previewHashMismatch
    case fileChangedSincePreview(client: String)
    case postWriteValidationFailed(client: String)
    case noTransactionToRollback
    case symlinkRefused(client: String)
    case serverChanged
    case credentialUnavailable
    case credentialUnsupported(client: String)
    case createdFileChanged
    case rollbackFileChanged
    case rollbackEvidenceMissing

    var errorDescription: String? {
        switch self {
        case .noPlansPreviewed: return "Preview client wiring before confirming it."
        case .previewHashMismatch: return "The wiring intent changed after preview. Preview it again before confirming."
        case .fileChangedSincePreview(let client): return "\(client): the config file changed after the preview; preview again."
        case .postWriteValidationFailed(let client): return "\(client): the written config did not validate; the previous file was restored."
        case .noTransactionToRollback: return "There is no wiring transaction to roll back."
        case .symlinkRefused(let client): return "\(client): the config path or its backup target is a symbolic link; refusing to write through it."
        case .credentialUnavailable: return "The endpoint inference key is unavailable or changed. Check its API-key setup in Run, then preview again."
        case .credentialUnsupported(let client): return "\(client): authenticated setup is not supported by this adapter."
        case .serverChanged: return "The selected server stopped or changed. Refresh and preview client wiring again."
        case .createdFileChanged: return "The config file changed after wiring created it; it was left in place."
        case .rollbackFileChanged: return "The config file changed after wiring; it was left in place. Review the backup before restoring it."
        case .rollbackEvidenceMissing: return "This older wiring record cannot confirm the current config contents. Restore its backup manually after review."
        }
    }
}

@MainActor
final class WiringCoordinator: ObservableObject {
    @Published private(set) var installations: [ClientInstallation] = []
    @Published private(set) var plans: [ClientEditPlan] = []
    @Published private(set) var previewHash: String?
    @Published private(set) var transactions: [WiringTransaction] = []
    @Published private(set) var isApplying = false
    @Published private(set) var isCheckingServer = false
    @Published private(set) var lastError: String?
    @Published private(set) var persistenceError: String?
    /// What each writable client's config file says right now, by client id.
    @Published private(set) var readings: [String: ClientConfigStatus] = [:]

    private let adapters: [ClientAdapter]
    private let home: URL
    private let fileManager: FileManager
    private let configSource: ClientConfigSource
    private let credential: @MainActor (String) async throws -> String
    private let store: JSONStore<WiringTransaction>
    /// Moves a file to the macOS Trash; rollback never deletes permanently.
    private let moveToTrash: (URL) throws -> Void
    private let now: () -> Date
    private var readGeneration = 0
    private var readQueued = false
    private var transactionObserver: AnyCancellable?

    /// Plans frozen at preview time; confirm applies exactly these.
    private var previewedPlans: [ClientEditPlan] = []
    private var previewedEndpoint: WireEndpoint?
    private var previewedServer: ServerInfo?

    /// The endpoint captured with the server-backed preview, independent of current selection.
    var reviewedEndpoint: WireEndpoint? { previewedServer.flatMap { WireEndpoint(server: $0) } }

    var setupClients: [ClientInstallation] { adapters.compactMap { $0.configurationInstallation(home: home) } }

    func previewMatches(server: ServerInfo?) -> Bool {
        guard let server, let reviewed = previewedServer,
              previewHash != nil, !plans.isEmpty else { return false }
        return ClientWiringSelection.sameServer(reviewed, server)
    }

    init(
        adapters: [ClientAdapter] = ClientAdapters.all,
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        fileManager: FileManager = .default,
        configSource: @escaping ClientConfigSource = ClientConfigFile.live,
        store: JSONStore<WiringTransaction>,
        credential: @escaping @MainActor (String) async throws -> String = { hash in
            try await Task.detached(priority: .utility) { try EndpointCredentialStore.token(for: hash) }.value
        },
        moveToTrash: ((URL) throws -> Void)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.adapters = adapters
        self.home = home
        self.fileManager = fileManager
        self.configSource = configSource
        self.credential = credential
        self.store = store
        self.moveToTrash = moveToTrash ?? { try fileManager.trashItem(at: $0, resultingItemURL: nil) }
        self.now = now
        do {
            transactions = try store.load().sorted { $0.appliedAt > $1.appliedAt }
        } catch {
            persistenceError = "Saved wiring transactions are unavailable: \(AppHost.render(error))"
        }
        // A confirm outcome or a rollback changes the transaction list; the files are read again afterwards.
        transactionObserver = $transactions.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReadings() }
        }
    }

    /// Detect clients again, then read every writable client's config off the main actor and publish the result,
    /// unless a newer read or a confirm/rollback outcome superseded this one.
    func refreshReadings() async {
        detect()
        readGeneration &+= 1
        await readConfigs(generation: readGeneration)
    }

    private func scheduleReadings() {
        readGeneration &+= 1
        guard !readQueued else { return }
        readQueued = true
        Task { [weak self] in
            guard let self else { return }
            self.readQueued = false
            self.detect()
            await self.readConfigs(generation: self.readGeneration)
        }
    }

    private func readConfigs(generation: Int) async {
        let targets = installations.compactMap { installation -> (id: String, path: String, adapter: ClientAdapter)? in
            guard !installation.advisoryOnly, let path = installation.configPath,
                  let adapter = adapters.first(where: { $0.clientID == installation.clientID }) else { return nil }
            return (installation.clientID, path, adapter)
        }
        var next: [String: ClientConfigStatus] = [:]
        for target in targets {
            next[target.id] = await configSource(target.path, target.adapter)
        }
        guard generation == readGeneration else { return }
        readings = next
    }

    /// Detect installed clients. Advisory rows appear only when the client
    /// looks installed; writable rows when the config or its directory exists.
    func detect() {
        installations = adapters.compactMap { $0.installation(home: home, fileManager: fileManager) }
    }

    /// Compute edit plans for every detected writable client and freeze them
    /// under a preview hash.
    func preview(endpoint: WireEndpoint, clientIDs: Set<String>? = nil) {
        guard !isCheckingServer, !isApplying else { return }
        guard endpoint.apiKeySHA256 == nil else {
            invalidateServerPreview(); lastError = WiringError.serverChanged.errorDescription; return
        }
        buildPreview(endpoint: endpoint, clientIDs: clientIDs, key: nil)
    }

    private func buildPreview(endpoint: WireEndpoint, clientIDs: Set<String>?, key: String?) {
        previewedServer = nil
        detect()
        lastError = nil
        let targets: [ClientInstallation]
        if let clientIDs {
            guard !clientIDs.isEmpty, clientIDs.isSubset(of: Set(setupClients.map(\.clientID))) else {
                invalidateServerPreview()
                lastError = "Choose a supported writable client before reviewing setup."
                return
            }
            targets = setupClients.filter { clientIDs.contains($0.clientID) }
        } else { targets = installations }
        var built: [ClientEditPlan] = []
        for installation in targets where !installation.advisoryOnly {
            guard let adapter = adapters.first(where: { $0.clientID == installation.clientID }),
                  let path = installation.configPath else { continue }
            do {
                if let bytes = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? NSNumber,
                   bytes.intValue > ClientConfigFile.sizeLimit { throw WorkflowEvidenceError.invalid("Config is larger than 1 MB.") }
                let before = try? String(contentsOfFile: path, encoding: .utf8)
                if clientIDs != nil {
                    let diagnosis = ClientSetupDiagnosis.make(clientID: installation.clientID,
                        status: ClientConfigFile.load(path: path, adapter: adapter), servers: [])
                    guard diagnosis.canPreview else {
                        throw WorkflowEvidenceError.invalid(diagnosis.message)
                    }
                }
                let after = try adapter.authenticatedPlan(before, endpoint, key: key)
                let rewrites = before != nil && (adapter.normalizesFormatting || JSONCTolerant.strip(before ?? "") != before)
                built.append(ClientEditPlan(
                    clientID: installation.clientID,
                    displayName: installation.displayName,
                    configPath: path,
                    before: before,
                    after: after,
                    summary: summary(for: installation.clientID, endpoint: endpoint, creating: before == nil),
                    rewritesFile: rewrites,
                    credentialInstruction: endpoint.apiKeySHA256 == nil ? nil : adapter.credentialInstruction
                ))
            } catch {
                lastError = "\(installation.displayName): \(AppHost.render(error))"
            }
        }
        previewedPlans = built
        previewedEndpoint = endpoint
        plans = built
        previewHash = Self.hash(plans: built, endpoint: endpoint)
    }

    func preview(server: ServerInfo, clientIDs: Set<String>? = nil) async {
        guard !isCheckingServer, !isApplying else { return }
        guard let endpoint = WireEndpoint(server: server) else {
            invalidateServerPreview(); lastError = WiringError.serverChanged.errorDescription; return
        }
        isCheckingServer = true
        defer { isCheckingServer = false }
        do {
            let key = try await inferenceKey(for: endpoint)
            try Task.checkCancellation()
            buildPreview(endpoint: endpoint, clientIDs: clientIDs, key: key)
            previewedServer = server
        } catch {
            invalidateServerPreview()
            lastError = Task.isCancelled ? nil : WiringError.credentialUnavailable.errorDescription
        }
    }

    /// Read authoritative status immediately before the existing config-write boundary.
    func confirm(server: ServerInfo, previewHash hash: String,
                 currentServers: () async throws -> [ServerInfo]) async -> WiringTransaction? {
        guard !isCheckingServer, !isApplying else { return nil }
        guard let reviewed = previewedServer, ClientWiringSelection.sameServer(reviewed, server),
              let endpoint = WireEndpoint(server: server), previewHash == hash else {
            lastError = WiringError.previewHashMismatch.errorDescription; return nil
        }
        isCheckingServer = true
        defer { isCheckingServer = false }
        do {
            _ = try await inferenceKey(for: endpoint)
            try Task.checkCancellation()
            let servers = try await currentServers()
            try Task.checkCancellation()
            let matches = servers.filter { $0.port == reviewed.port && $0.state?.lowercased() == "running" }
            guard matches.count == 1, ClientWiringSelection.sameServer(reviewed, matches[0]),
                  previewedServer == reviewed, previewHash == hash else {
                invalidateServerPreview(); lastError = WiringError.serverChanged.errorDescription; return nil
            }
            return applyPreview(endpoint: endpoint, previewHash: hash)
        } catch {
            invalidateServerPreview()
            lastError = Task.isCancelled ? nil : (error is WiringError ? AppHost.render(error)
                : "Server status unavailable; no client files changed: \(AppHost.render(error))")
            return nil
        }
    }

    /// Explicit transfer to a client's native key store, with fresh endpoint identity.
    func inferenceKey(server: ServerInfo, currentServers: () async throws -> [ServerInfo]) async throws -> String {
        guard !isApplying, !isCheckingServer, let endpoint = WireEndpoint(server: server), endpoint.apiKeySHA256 != nil else {
            throw WiringError.credentialUnavailable
        }
        isCheckingServer = true
        defer { isCheckingServer = false }
        try Task.checkCancellation()
        let key = try await inferenceKey(for: endpoint)
        try Task.checkCancellation()
        let servers = try await currentServers()
        try Task.checkCancellation()
        let candidates = servers.filter { $0.port == server.port }
        guard candidates.count == 1, ClientWiringSelection.sameServer(server, candidates[0]) else {
            throw WiringError.serverChanged
        }
        guard let key else { throw WiringError.credentialUnavailable }
        return key
    }

    private func inferenceKey(for endpoint: WireEndpoint) async throws -> String? {
        guard let hash = endpoint.apiKeySHA256 else { return nil }
        do {
            let key = try await credential(hash)
            guard (32...512).contains(key.utf8.count), key.utf8.allSatisfy({ (33...126).contains($0) }),
                  EndpointCredentialStore.digest(key) == hash else { throw WiringError.credentialUnavailable }
            return key
        } catch { throw WiringError.credentialUnavailable }
    }

    private func invalidateServerPreview() {
        previewedServer = nil; previewedEndpoint = nil; previewedPlans = []; plans = []; previewHash = nil
    }

    /// Apply the frozen plans. Per-client drift (file changed since preview)
    /// skips that client instead of guessing. Per-client failures do not
    /// roll back prior successes — backups make every write reversible.
    @discardableResult
    func confirm(endpoint: WireEndpoint, previewHash hash: String) -> WiringTransaction? {
        guard !isCheckingServer, previewedServer == nil, endpoint.apiKeySHA256 == nil else {
            lastError = "Confirm this preview with a fresh server status check."
            return nil
        }
        return applyPreview(endpoint: endpoint, previewHash: hash)
    }

    private func applyPreview(endpoint: WireEndpoint, previewHash hash: String) -> WiringTransaction? {
        guard !previewedPlans.isEmpty else {
            lastError = WiringError.noPlansPreviewed.errorDescription
            return nil
        }
        guard previewedEndpoint == endpoint, previewHash == hash else {
            lastError = WiringError.previewHashMismatch.errorDescription
            return nil
        }
        isApplying = true
        defer { isApplying = false }

        var receipts: [ClientEditReceipt] = []
        var failures: [String] = []
        for plan in previewedPlans {
            do {
                receipts.append(try apply(plan))
            } catch {
                // Client-specific WiringError descriptions already name their client.
                let message = AppHost.render(error)
                failures.append(error is WiringError ? message : "\(plan.displayName): \(message)")
            }
        }

        let transaction = WiringTransaction(
            id: UUID(),
            previewHash: hash,
            endpointBaseURL: endpoint.baseURL,
            modelName: endpoint.modelName,
            appliedAt: now(),
            receipts: receipts,
            failures: failures,
            rolledBackAt: nil
        )
        transactions.insert(transaction, at: 0)
        persist(transaction)
        previewedPlans = []
        previewedServer = nil
        previewedEndpoint = nil
        previewHash = nil
        plans = []
        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        return transaction
    }

    /// Restore the latest transaction's backups and move the files it created
    /// to the Trash, newest write first.
    func rollback(transactionID: UUID? = nil) {
        guard !isApplying, !isCheckingServer else { return }
        let requested: WiringTransaction?
        if let transactionID { requested = transactions.first { $0.id == transactionID } }
        else { requested = transactions.first }
        guard let transaction = requested, transaction.rolledBackAt == nil else {
            lastError = WiringError.noTransactionToRollback.errorDescription
            return
        }
        var failures: [String] = []
        var restored = Set(transaction.rolledBackConfigPaths ?? [])
        for receipt in transaction.receipts.reversed() {
            guard !restored.contains(receipt.configPath) else { continue }
            do {
                if let backup = receipt.backupPath {
                    guard let expected = receipt.writtenFileSHA256 else { throw WiringError.rollbackEvidenceMissing }
                    let target = URL(fileURLWithPath: receipt.configPath)
                    try Self.refuseSymlink(target, client: nil, fileManager: fileManager)
                    guard Self.sha256Hex(try Data(contentsOf: target)) == expected else { throw WiringError.rollbackFileChanged }
                    try restore(backup: backup, to: receipt.configPath)
                } else if let written = receipt.createdFileSHA256 {
                    try trashCreated(receipt.configPath, writtenSHA256: written)
                }
                restored.insert(receipt.configPath)
            } catch {
                failures.append("\(receipt.clientID): \(AppHost.render(error))")
            }
        }
        if let index = transactions.firstIndex(where: { $0.id == transaction.id }) {
            transactions[index].rolledBackAt = failures.isEmpty ? now() : nil
            transactions[index].rolledBackConfigPaths = restored.sorted()
            for failure in failures where !transactions[index].failures.contains(failure) {
                transactions[index].failures.append(failure)
            }
            persist(transactions[index])
        }
        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    var rollbackAvailable: Bool {
        transactions.first.map { !$0.receipts.isEmpty && $0.rolledBackAt == nil } ?? false
    }

    /// Bind the connection test to the exact file this transaction wrote, including its credential.
    func matchesAppliedConfig(_ receipt: ClientEditReceipt, endpoint: WireEndpoint) async -> Bool {
        guard let expected = receipt.writtenFileSHA256,
              let adapter = adapters.first(where: { $0.clientID == receipt.clientID }),
              adapter.configurationInstallation(home: home)?.configPath == receipt.configPath else { return false }
        let boundary = home.path
        return await WorkbenchIO.perform {
            let url = URL(fileURLWithPath: receipt.configPath)
            var ancestor = url
            while ancestor.path != boundary && ancestor.path != "/" {
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) == nil else { return false }
                ancestor.deleteLastPathComponent()
            }
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
                  let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
                  bytes.intValue <= ClientConfigFile.sizeLimit,
                  let data = FileManager.default.contents(atPath: url.path), Self.sha256Hex(data) == expected,
                  let text = String(data: data, encoding: .utf8),
                  case .entries(let entries) = adapter.read(text) else { return false }
            return entries.contains { ClientEndpointURL.port(of: $0.baseURL) == ClientEndpointURL.port(of: endpoint.baseURL) && $0.models.contains(endpoint.modelName) }
        }
    }

    // MARK: - Apply internals

    private func apply(_ plan: ClientEditPlan) throws -> ClientEditReceipt {
        // Creating a missing config must not follow a linked parent, including
        // one substituted after review. Stop at the configured home boundary.
        var target = URL(fileURLWithPath: plan.configPath)
        while target.path != home.path && target.path != "/" {
            try Self.refuseSymlink(target, client: plan.displayName, fileManager: fileManager)
            target.deleteLastPathComponent()
        }
        // Drift guard: the file must still match what the preview saw.
        let current = try? String(contentsOfFile: plan.configPath, encoding: .utf8)
        let itemExists = (try? fileManager.attributesOfItem(atPath: plan.configPath)) != nil
        guard current == plan.before, !(plan.before == nil && itemExists) else {
            throw WiringError.fileChangedSincePreview(client: plan.displayName)
        }

        let fileURL = URL(fileURLWithPath: plan.configPath)
        var backupPath: String?
        if plan.before != nil {
            let backup = fileURL.appendingPathExtension("mlxmac-backup-\(Self.backupStamp(now()))")
            try Self.refuseSymlink(fileURL, client: plan.displayName, fileManager: fileManager)
            try Self.refuseSymlink(backup, client: plan.displayName, fileManager: fileManager)
            try fileManager.copyItem(at: fileURL, to: backup)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            backupPath = backup.path
        }
        // Only a write to a path with nothing at it creates the file; an unreadable existing file does not count.
        let createsFile = plan.before == nil && (try? fileManager.attributesOfItem(atPath: plan.configPath)) == nil

        do {
            try writeAtomically(plan.after, to: fileURL)
            // Post-write validation: what landed must parse (JSON targets)
            // and must equal the plan. A failure restores the backup.
            let landed = try String(contentsOf: fileURL, encoding: .utf8)
            do {
                if let validate = adapters.first(where: { $0.clientID == plan.clientID })?.validate {
                    try validate(landed)
                } else if plan.configPath.hasSuffix(".json") || plan.configPath.hasSuffix(".jsonc") {
                    _ = try JSONCTolerant.parse(landed)
                }
            } catch {
                throw WiringError.postWriteValidationFailed(client: plan.displayName)
            }
            guard landed == plan.after else {
                throw WiringError.postWriteValidationFailed(client: plan.displayName)
            }
        } catch {
            if let backupPath {
                try? restore(backup: backupPath, to: plan.configPath)
            } else {
                try? fileManager.removeItem(at: fileURL)
            }
            throw error
        }

        return ClientEditReceipt(
            clientID: plan.clientID,
            configPath: plan.configPath,
            backupPath: backupPath,
            createdFileSHA256: createsFile ? Self.sha256Hex(Data(plan.after.utf8)) : nil,
            writtenFileSHA256: Self.sha256Hex(Data(plan.after.utf8)),
            appliedAt: now(),
            credentialInstruction: plan.credentialInstruction
        )
    }

    private func writeAtomically(_ contents: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: Data(contents.utf8))
            try handle.synchronize()
            try handle.close()
            if fileManager.fileExists(atPath: url.path) {
                try Self.refuseSymlink(url, client: nil, fileManager: fileManager)
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary, options: .usingNewMetadataOnly)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    /// A symlink at a write target would redirect the write outside the
    /// allowlisted client-config paths. Never follow one.
    private static func refuseSymlink(
        _ url: URL, client: String?, fileManager: FileManager
    ) throws {
        do {
            _ = try fileManager.destinationOfSymbolicLink(atPath: url.path)
        } catch {
            // Not a symbolic link; the write proceeds normally.
            return
        }
        if let client {
            throw WiringError.symlinkRefused(client: client)
        }
        throw CocoaError(.fileWriteUnknown)
    }

    private func restore(backup: String, to path: String) throws {
        let backupURL = URL(fileURLWithPath: backup)
        let targetURL = URL(fileURLWithPath: path)
        try Self.refuseSymlink(targetURL, client: nil, fileManager: fileManager)
        if fileManager.fileExists(atPath: targetURL.path) {
            // replaceItemAt consumes its source; restore from a temp copy so
            // the backup survives for repeatability.
            let temporaryCopy = targetURL.appendingPathExtension("restore-\(UUID().uuidString)")
            try fileManager.copyItem(at: backupURL, to: temporaryCopy)
            _ = try fileManager.replaceItemAt(targetURL, withItemAt: temporaryCopy, options: .usingNewMetadataOnly)
        } else {
            try fileManager.copyItem(at: backupURL, to: targetURL)
        }
    }

    /// A created config goes to the Trash only while it still holds exactly
    /// what the wiring wrote; an edited file stays in place.
    private func trashCreated(_ path: String, writtenSHA256: String) throws {
        let targetURL = URL(fileURLWithPath: path)
        try Self.refuseSymlink(targetURL, client: nil, fileManager: fileManager)
        guard fileManager.fileExists(atPath: targetURL.path) else { return }
        guard Self.sha256Hex(try Data(contentsOf: targetURL)) == writtenSHA256 else {
            throw WiringError.createdFileChanged
        }
        try moveToTrash(targetURL)
    }

    private func persist(_ transaction: WiringTransaction) {
        do {
            try store.upsert(transaction, id: \.id)
        } catch {
            persistenceError = "Wiring transaction could not be saved: \(AppHost.render(error))"
        }
    }

    // MARK: - Hashing and summaries

    static func hash(plans: [ClientEditPlan], endpoint: WireEndpoint) -> String {
        var canonical = "endpoint:\(endpoint.baseURL)|\(endpoint.modelName)|\(endpoint.apiKeySHA256 ?? "")\n"
        for plan in plans.sorted(by: { $0.clientID < $1.clientID }) {
            canonical += "plan:\(plan.clientID)|\(plan.configPath)|\(plan.after)\n"
        }
        return sha256Hex(Data(canonical.utf8))
    }

    nonisolated private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func summary(for clientID: String, endpoint: WireEndpoint, creating: Bool) -> String {
        let verb = creating ? "Create config" : "Update config"
        let auth = endpoint.apiKeySHA256 == nil ? "" : (adapters.first { $0.clientID == clientID }?.credentialInstruction != nil
            ? "; finish API-key setup in the client" : "; inference key in owner-only config")
        return "\(verb); point at \(endpoint.baseURL), model \(endpoint.modelName)\(auth)"
    }

    private static func backupStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
