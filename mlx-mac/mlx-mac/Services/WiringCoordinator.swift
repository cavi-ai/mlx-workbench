import CryptoKit
import Foundation

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

    var errorDescription: String? {
        switch self {
        case .noPlansPreviewed: return "Preview client wiring before confirming it."
        case .previewHashMismatch: return "The wiring intent changed after preview. Preview it again before confirming."
        case .fileChangedSincePreview(let client): return "\(client): the config file changed after the preview; preview again."
        case .postWriteValidationFailed(let client): return "\(client): the written config did not validate; the previous file was restored."
        case .noTransactionToRollback: return "There is no wiring transaction to roll back."
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
    @Published private(set) var lastError: String?
    @Published private(set) var persistenceError: String?

    private let adapters: [ClientAdapter]
    private let home: URL
    private let fileManager: FileManager
    private let store: JSONStore<WiringTransaction>
    private let now: () -> Date

    /// Plans frozen at preview time; confirm applies exactly these.
    private var previewedPlans: [ClientEditPlan] = []
    private var previewedEndpoint: WireEndpoint?

    init(
        adapters: [ClientAdapter] = ClientAdapters.all,
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        fileManager: FileManager = .default,
        store: JSONStore<WiringTransaction>,
        now: @escaping () -> Date = Date.init
    ) {
        self.adapters = adapters
        self.home = home
        self.fileManager = fileManager
        self.store = store
        self.now = now
        do {
            transactions = try store.load().sorted { $0.appliedAt > $1.appliedAt }
        } catch {
            persistenceError = "Saved wiring transactions are unavailable: \(AppHost.render(error))"
        }
    }

    /// Detect installed clients. Advisory rows appear only when the client
    /// looks installed; writable rows when the config or its directory exists.
    func detect() {
        installations = adapters.compactMap { $0.installation(home: home, fileManager: fileManager) }
    }

    /// Compute edit plans for every detected writable client and freeze them
    /// under a preview hash.
    func preview(endpoint: WireEndpoint) {
        detect()
        lastError = nil
        var built: [ClientEditPlan] = []
        for installation in installations where !installation.advisoryOnly {
            guard let adapter = adapters.first(where: { $0.clientID == installation.clientID }),
                  let path = installation.configPath else { continue }
            let before = try? String(contentsOfFile: path, encoding: .utf8)
            do {
                let after = try adapter.plan(before, endpoint)
                let rewrites = before != nil && JSONCTolerant.strip(before ?? "") != before
                built.append(ClientEditPlan(
                    clientID: installation.clientID,
                    displayName: installation.displayName,
                    configPath: path,
                    before: before,
                    after: after,
                    summary: summary(for: installation.clientID, endpoint: endpoint, creating: before == nil),
                    rewritesFile: rewrites
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

    /// Apply the frozen plans. Per-client drift (file changed since preview)
    /// skips that client instead of guessing. Per-client failures do not
    /// roll back prior successes — backups make every write reversible.
    @discardableResult
    func confirm(endpoint: WireEndpoint, previewHash hash: String) -> WiringTransaction? {
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
                failures.append("\(plan.displayName): \(AppHost.render(error))")
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
        previewedEndpoint = nil
        previewHash = nil
        plans = []
        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        return transaction
    }

    /// Restore the latest transaction's backups, newest write first.
    func rollback() {
        guard let transaction = transactions.first, transaction.rolledBackAt == nil else {
            lastError = WiringError.noTransactionToRollback.errorDescription
            return
        }
        var failures: [String] = []
        for receipt in transaction.receipts.reversed() {
            guard let backup = receipt.backupPath else { continue }
            do {
                try restore(backup: backup, to: receipt.configPath)
            } catch {
                failures.append("\(receipt.clientID): \(AppHost.render(error))")
            }
        }
        if let index = transactions.firstIndex(where: { $0.id == transaction.id }) {
            transactions[index].rolledBackAt = now()
            transactions[index].failures.append(contentsOf: failures)
            persist(transactions[index])
        }
        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    var rollbackAvailable: Bool {
        transactions.first != nil && transactions.first?.rolledBackAt == nil
    }

    // MARK: - Apply internals

    private func apply(_ plan: ClientEditPlan) throws -> ClientEditReceipt {
        // Drift guard: the file must still match what the preview saw.
        let current = try? String(contentsOfFile: plan.configPath, encoding: .utf8)
        guard current == plan.before else {
            throw WiringError.fileChangedSincePreview(client: plan.displayName)
        }

        let fileURL = URL(fileURLWithPath: plan.configPath)
        var backupPath: String?
        if plan.before != nil {
            let backup = fileURL.appendingPathExtension("mlxmac-backup-\(Self.backupStamp(now()))")
            try fileManager.copyItem(at: fileURL, to: backup)
            backupPath = backup.path
        }

        do {
            try writeAtomically(plan.after, to: fileURL)
            // Post-write validation: what landed must parse (JSON targets)
            // and must equal the plan. A failure restores the backup.
            let landed = try String(contentsOf: fileURL, encoding: .utf8)
            if plan.configPath.hasSuffix(".json") || plan.configPath.hasSuffix(".jsonc") {
                _ = try JSONCTolerant.parse(landed)
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
            appliedAt: now()
        )
    }

    private func writeAtomically(_ contents: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try Data(contents.utf8).write(to: temporary, options: .atomic)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func restore(backup: String, to path: String) throws {
        let backupURL = URL(fileURLWithPath: backup)
        let targetURL = URL(fileURLWithPath: path)
        if fileManager.fileExists(atPath: targetURL.path) {
            // replaceItemAt consumes its source; restore from a temp copy so
            // the backup survives for repeatability.
            let temporaryCopy = targetURL.appendingPathExtension("restore-\(UUID().uuidString)")
            try fileManager.copyItem(at: backupURL, to: temporaryCopy)
            _ = try fileManager.replaceItemAt(targetURL, withItemAt: temporaryCopy)
        } else {
            try fileManager.copyItem(at: backupURL, to: targetURL)
        }
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
        var canonical = "endpoint:\(endpoint.baseURL)|\(endpoint.modelName)\n"
        for plan in plans.sorted(by: { $0.clientID < $1.clientID }) {
            canonical += "plan:\(plan.clientID)|\(plan.configPath)|\(plan.after)\n"
        }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func summary(for clientID: String, endpoint: WireEndpoint, creating: Bool) -> String {
        let verb = creating ? "Create config" : "Update config"
        return "\(verb); point at \(endpoint.baseURL), model \(endpoint.modelName)"
    }

    private static func backupStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
