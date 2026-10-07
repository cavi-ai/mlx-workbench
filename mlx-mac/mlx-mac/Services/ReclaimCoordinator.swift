import CryptoKit
import Foundation

// MARK: - ReclaimCoordinator
//
// Batched reclaim apply for the Disk Pressure Advisor (premium spec 04).
// Preview freezes the exact move set under a hash; confirm re-guards every
// path against the quarantine rules and moves sequentially — per-item
// failures are recorded and never roll back prior successes (quarantine is
// reversible).

struct ReclaimPlanItem: Equatable, Sendable {
    let path: String
    let bytes: Int64
}

struct ReclaimPlan: Equatable, Sendable {
    let items: [ReclaimPlanItem]
    let previewHash: String
    let totalBytes: Int64
}

struct ReclaimMoveResult: Equatable, Sendable {
    let path: String
    let destination: String?
    let error: String?
}

struct QuarantineTrashPlan: Equatable, Sendable {
    let record: QuarantineRecord
    let snapshot: QuarantineFileSnapshot
    let quarantineDir: String
}

struct ModelFolderReclaimPlan: Equatable, Sendable {
    let snapshot: QuarantineFileSnapshot
    let roots: [String]
    let quarantineDir: String
}

struct SourceCleanupCandidate: Identifiable {
    let workflow: ConversionWorkflow
    let bytes: Int64?
    let reason: String?
    var id: UUID { workflow.id }
    var title: String { URL(fileURLWithPath: workflow.completedModelPath ?? workflow.outputPath).lastPathComponent }
}

enum ReclaimError: LocalizedError {
    case nothingSelected
    case previewHashMismatch

    var errorDescription: String? {
        switch self {
        case .nothingSelected: return "Select reclaimable items before previewing."
        case .previewHashMismatch: return "The reclaim selection changed after preview. Preview it again before confirming."
        }
    }
}

@MainActor
final class ReclaimCoordinator: ObservableObject {
    @Published private(set) var opportunities: [ReclaimOpportunity] = []
    @Published private(set) var plan: ReclaimPlan?
    @Published private(set) var lastMoves: [ReclaimMoveResult] = []
    @Published private(set) var isApplying = false
    @Published private(set) var lastError: String?
    /// Currently-quarantined files from the ledger, newest first — records
    /// whose quarantined file no longer exists (restored, or removed by the
    /// user) drop out of the view.
    @Published private(set) var quarantined: [QuarantineRecord] = []
    @Published private(set) var trashPlan: QuarantineTrashPlan?
    @Published private(set) var trashNote: String?
    @Published private(set) var folderPlan: ModelFolderReclaimPlan?
    @Published private(set) var sourcePlan: ConvertedSourcePlan?
    @Published private(set) var sourceCleanupNote: String?
    @Published private(set) var sourceCandidates: [SourceCleanupCandidate] = []
    @Published private(set) var sourceHistory: [SourceCleanupBatch] = []
    @Published private(set) var sourceHistoryError: String?
    @Published private(set) var sourceRestorePlan: SourceRestorePlan?
    @Published private(set) var isCheckingSources = false
    @Published private(set) var sourcesChecked = false
    /// Incomplete HF-cache findings from the last cache check, with the
    /// prune preview hash when one has been previewed.
    @Published private(set) var cacheFindings: [DoctorFinding] = []
    @Published private(set) var cachePruneHash: String?
    @Published private(set) var cachePruneNote: String?

    /// Injected by AppHost: the authoritative doctor flows. Nil when the
    /// agent is unavailable — cache reclaim rows hide.
    var doctorScan: (() async throws -> DoctorResult)?
    var doctorPrunePreview: (() async throws -> DoctorResult)?
    var doctorPruneConfirm: ((String) async throws -> DoctorResult)?

    private let now: () -> Date
    private let fileManager: FileManager
    private let sourceJournalURL: URL
    private let sourceTrashRoots: [String]?
    private var sourceHistoryGeneration = 0

    private var sourceRoots: [String] { Array(Set(ggufRoots() + mlxRoots())).sorted() }

    func checkSources(workflows: [ConversionWorkflow]) async {
        guard !isApplying, !isCheckingSources else { return }
        isCheckingSources = true
        defer { isCheckingSources = false }
        let roots = sourceRoots, protected = protectedPaths(), manager = fileManager
        let candidates = await Task.detached(priority: .userInitiated) {
            workflows.filter { $0.state == .verified }.map { workflow in
                do {
                    let plan = try ConvertedSourceCleanup.preview(workflow: workflow, roots: roots, protected: protected, fileManager: manager)
                    return SourceCleanupCandidate(workflow: workflow, bytes: plan.bytes, reason: nil)
                } catch {
                    return SourceCleanupCandidate(workflow: workflow, bytes: nil, reason: error.localizedDescription)
                }
            }.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
        }.value
        guard roots == sourceRoots, protected == protectedPaths() else {
            sourceCandidates = []; sourcesChecked = false
            lastError = QuarantineError.changedSincePreview.errorDescription
            return
        }
        sourceCandidates = candidates
        sourcesChecked = true
        await refreshSourceHistory()
    }

    func refreshSourceHistory() async {
        sourceHistoryGeneration += 1
        let generation = sourceHistoryGeneration
        let roots = sourceRoots, url = sourceJournalURL, trash = sourceTrashRoots, manager = fileManager
        do {
            let history = try await Task.detached(priority: .utility) {
                try ConvertedSourceRecovery.history(roots: roots, journalURL: url, trashRoots: trash, fileManager: manager)
            }.value
            guard roots == sourceRoots, generation == sourceHistoryGeneration else { return }
            sourceHistory = history
            sourceHistoryError = nil
        } catch {
            guard generation == sourceHistoryGeneration else { return }
            sourceHistory = []
            sourceHistoryError = AppHost.render(error)
        }
    }

    func previewSourceRestore(ids: [String]) async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        sourceRestorePlan = nil; lastError = nil; sourceCleanupNote = nil
        let roots = sourceRoots, url = sourceJournalURL, trash = sourceTrashRoots, manager = fileManager
        do {
            sourceRestorePlan = try await Task.detached(priority: .userInitiated) {
                try ConvertedSourceRecovery.preview(ids: ids, roots: roots, journalURL: url, trashRoots: trash, fileManager: manager)
            }.value
        } catch { lastError = AppHost.render(error) }
    }

    func confirmSourceRestore() async {
        guard !isApplying, let plan = sourceRestorePlan else { return }
        isApplying = true
        defer { isApplying = false; sourceRestorePlan = nil }
        let roots = sourceRoots, url = sourceJournalURL, trash = sourceTrashRoots, manager = fileManager
        do {
            try await Task.detached(priority: .userInitiated) {
                try ConvertedSourceRecovery.restore(plan, roots: roots, journalURL: url, trashRoots: trash, fileManager: manager)
            }.value
            sourceCleanupNote = "Restored \(plan.items.count) source items to their original locations."
            lastError = nil
            sourceCandidates = []; sourcesChecked = false
        } catch { lastError = AppHost.render(error) }
        await refreshSourceHistory()
    }

    func cancelSourceRestore() { if !isApplying { sourceRestorePlan = nil } }

    /// Set post-init (AppHost wires these to live config); closures so the
    /// coordinator always reads the current values.
    var quarantineDir: () -> String = { "" }
    var ggufRoots: () -> [String] = { [] }
    var mlxRoots: () -> [String] = { [] }
    var protectedPaths: () -> [String] = { [] }

    private var protectedFolderPaths: [String] {
        protectedPaths() + opportunities.compactMap { $0.replacement?.keeper.path }
    }

    func previewSource(_ workflow: ConversionWorkflow) async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        sourcePlan = nil; sourceCleanupNote = nil; lastError = nil
        let roots = Array(Set(ggufRoots() + mlxRoots())).sorted(), protected = protectedPaths(), manager = fileManager
        do {
            sourcePlan = try await Task.detached(priority: .userInitiated) {
                try ConvertedSourceCleanup.preview(workflow: workflow, roots: roots, protected: protected, fileManager: manager)
            }.value
        } catch { lastError = AppHost.render(error) }
    }

    func confirmSource(_ workflow: ConversionWorkflow) async {
        guard !isApplying, let plan = sourcePlan else { return }
        isApplying = true
        defer { isApplying = false; sourcePlan = nil }
        let roots = Array(Set(ggufRoots() + mlxRoots())).sorted(), protected = protectedPaths(), manager = fileManager
        do {
            let url = sourceJournalURL
            let moves = try await Task.detached(priority: .userInitiated) {
                try ConvertedSourceCleanup.apply(plan, workflow: workflow, roots: roots, protected: protected, fileManager: manager, journalURL: url)
            }.value
            sourceCleanupNote = "Moved \(moves.count) source items to Trash. Empty Trash when you want to release their disk space."
            lastError = nil
            sourceCandidates = []; sourcesChecked = false
        } catch { lastError = AppHost.render(error) }
        await refreshSourceHistory()
    }

    func cancelSource() { if !isApplying { sourcePlan = nil } }

    func previewFolder(_ path: String) async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        folderPlan = nil
        lastError = nil
        let roots = mlxRoots(), protected = protectedFolderPaths, dir = quarantineDir(), manager = fileManager
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try Quarantine.folderSnapshot(target: path, roots: roots, protected: protected, fileManager: manager)
            }.value
            guard roots == mlxRoots(), dir == quarantineDir() else { throw QuarantineError.changedSincePreview }
            folderPlan = ModelFolderReclaimPlan(snapshot: snapshot, roots: roots, quarantineDir: dir)
        } catch { lastError = AppHost.render(error) }
    }

    func cancelFolder() { if !isApplying { folderPlan = nil } }

    func confirmFolder() async {
        guard !isApplying, let preview = folderPlan else { return }
        guard preview.roots == mlxRoots(), preview.quarantineDir == quarantineDir() else {
            folderPlan = nil
            lastError = QuarantineError.changedSincePreview.errorDescription
            return
        }
        isApplying = true
        let protected = protectedFolderPaths, manager = fileManager, timestamp = now()
        do {
            let record = try await Task.detached(priority: .userInitiated) {
                try Quarantine.moveFolder(expected: preview.snapshot, roots: preview.roots, protected: protected, quarantineDir: preview.quarantineDir, now: timestamp, fileManager: manager)
            }.value
            lastMoves = [ReclaimMoveResult(path: record.from, destination: record.to, error: nil)]
            lastError = nil
        } catch { lastError = AppHost.render(error) }
        folderPlan = nil
        isApplying = false
        refreshQuarantined()
    }

    init(
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default,
        sourceJournalURL: URL = ConvertedSourceRecovery.journalURL,
        sourceTrashRoots: [String]? = nil
    ) {
        self.now = now
        self.fileManager = fileManager
        self.sourceJournalURL = sourceJournalURL
        self.sourceTrashRoots = sourceTrashRoots
    }

    var totalReclaimableBytes: Int64 {
        opportunities.filter(\.actionable).reduce(0) { $0 + $1.bytes }
    }

    /// Badge text for the sidebar when reclaimable bytes exceed the
    /// threshold; nil below it.
    var badgeText: String? {
        guard totalReclaimableBytes >= ReclaimAdvisor.badgeThresholdBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: totalReclaimableBytes, countStyle: .file)
    }

    func analyze(
        snapshot: LibrarySnapshot?,
        duplicates: [DuplicateGroup],
        lastUsedByPath: [String: Date],
        isVerified: (String) -> Bool,
        occupiedPaths: Set<String>,
        staleDays: Int = ReclaimAdvisor.defaultStaleDays,
        measuredSuperseded: [ReclaimOpportunity] = []
    ) {
        opportunities = ReclaimAdvisor.opportunities(
            snapshot: snapshot,
            duplicates: duplicates,
            lastUsedByPath: lastUsedByPath,
            isVerified: isVerified,
            occupiedPaths: occupiedPaths,
            staleDays: staleDays,
            measuredSuperseded: measuredSuperseded
        )
        plan = nil
        lastMoves = []
    }

    /// Test seam: inject opportunities without a full snapshot.
    func setOpportunitiesForTesting(_ value: [ReclaimOpportunity]) {
        opportunities = value
    }

    /// Re-read the quarantine ledger, keeping only records whose quarantined
    /// file still exists — the list means "currently quarantined". The ledger
    /// file itself stays an append-only audit trail (a restored record's file
    /// simply leaves the directory).
    func refreshQuarantined() {
        let dir = quarantineDir()
        quarantined = Quarantine.ledger(quarantineDir: dir, limit: 10000, fileManager: fileManager).filter { record in
            record.deletedAt == nil && (try? Quarantine.guardQuarantinedPath(record.to, quarantineDir: dir, kind: record.kind, fileManager: fileManager)) != nil
        }
    }

    /// Put a quarantined file back where it came from, then refresh.
    func restore(_ record: QuarantineRecord) async {
        guard !isApplying else { return }
        isApplying = true
        let dir = quarantineDir(), manager = fileManager
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try Quarantine.trashSnapshot(record, quarantineDir: dir, fileManager: manager)
                try Quarantine.restore(record, fileManager: manager)
            }.value
            lastError = nil
        } catch {
            lastError = AppHost.render(error)
        }
        isApplying = false
        refreshQuarantined()
    }

    func previewTrash(_ record: QuarantineRecord) async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        lastError = nil
        trashNote = nil
        do {
            let dir = quarantineDir(), manager = fileManager
            let snapshot = try await Task.detached(priority: .userInitiated) { try Quarantine.trashSnapshot(record, quarantineDir: dir, fileManager: manager) }.value
            guard dir == quarantineDir() else { throw QuarantineError.changedSincePreview }
            trashPlan = QuarantineTrashPlan(record: record, snapshot: snapshot, quarantineDir: dir)
        } catch {
            trashPlan = nil
            lastError = AppHost.render(error)
            refreshQuarantined()
        }
    }

    func cancelTrash() { if !isApplying { trashPlan = nil } }

    func confirmTrash() async {
        guard !isApplying, let preview = trashPlan else { return }
        guard quarantineDir() == preview.quarantineDir else {
            lastError = QuarantineError.changedSincePreview.errorDescription
            trashPlan = nil
            return
        }
        isApplying = true
        let fileManager = fileManager
        let timestamp = now()
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try Quarantine.trash(preview.record, quarantineDir: preview.quarantineDir, expected: preview.snapshot, now: timestamp, fileManager: fileManager)
            }.value
            trashNote = "Moved \(URL(fileURLWithPath: preview.record.from).lastPathComponent) to Trash. Empty Trash in Finder to free disk space."
            lastError = result.ledgerWarning
        } catch { lastError = AppHost.render(error) }
        isApplying = false
        trashPlan = nil
        refreshQuarantined()
    }

    /// Freeze the selected actionable paths into a hashed plan.
    func preview(selected: Set<String>) {
        lastError = nil
        let actionable = Set(opportunities
            .filter { $0.actionable && selected.contains($0.id) }
            .flatMap { $0.paths })
            .sorted()
        guard !actionable.isEmpty else {
            plan = nil
            lastError = ReclaimError.nothingSelected.errorDescription
            return
        }
        var items: [ReclaimPlanItem] = []
        for path in actionable {
            let size = (try? fileManager.attributesOfItem(atPath: Quarantine.resolve(path))[.size] as? Int64) ?? 0
            items.append(ReclaimPlanItem(path: path, bytes: size))
        }
        let hash = Self.hash(items: items)
        plan = ReclaimPlan(items: items, previewHash: hash, totalBytes: items.reduce(0) { $0 + $1.bytes })
    }

    /// Confirm the frozen plan: re-guard each path (drift check) and move
    /// sequentially. Returns per-item results.
    @discardableResult
    func confirm(previewHash hash: String) -> [ReclaimMoveResult]? {
        guard !isApplying else { return nil }
        guard let plan, plan.previewHash == hash else {
            lastError = ReclaimError.previewHashMismatch.errorDescription
            return nil
        }
        isApplying = true
        defer { isApplying = false }
        var results: [ReclaimMoveResult] = []
        for item in plan.items {
            do {
                let record = try Quarantine.move(
                    target: item.path,
                    roots: ggufRoots(),
                    quarantineDir: quarantineDir(),
                    now: now(),
                    fileManager: fileManager
                )
                results.append(ReclaimMoveResult(path: item.path, destination: record.to, error: nil))
            } catch {
                results.append(ReclaimMoveResult(path: item.path, destination: nil, error: AppHost.render(error)))
            }
        }
        lastMoves = results
        lastError = results.contains(where: { $0.error != nil })
            ? "Some items could not be moved; see per-item results."
            : nil
        self.plan = nil
        refreshQuarantined()
        // Moved items leave the opportunity set immediately; the next
        // library scan is the authoritative refresh.
        let moved = Set(results.compactMap { $0.error == nil ? $0.path : nil })
        opportunities = opportunities.filter { $0.paths.allSatisfy { !moved.contains($0) } }
        return results
    }

    static func hash(items: [ReclaimPlanItem]) -> String {
        let canonical = items.map { "\($0.path)|\($0.bytes)" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - HF-cache prune (via doctor)

    var cacheReclaimableBytes: Int64 {
        cacheFindings.reduce(0) { $0 + ($1.size ?? 0) }
    }

    /// Scan for incomplete-cache reclaim candidates (read-only).
    func checkCache() async {
        guard let doctorScan else { return }
        do {
            let result = try await doctorScan()
            cacheFindings = result.findings ?? []
            cachePruneNote = nil
        } catch {
            lastError = AppHost.render(error)
        }
    }

    /// Preview the prune through the authoritative doctor flow.
    func previewCachePrune() async {
        guard let doctorPrunePreview else { return }
        do {
            let result = try await doctorPrunePreview()
            cachePruneHash = result.preview_hash
            if result.preview_hash == nil {
                cachePruneNote = "Nothing to prune."
            }
        } catch {
            cachePruneHash = nil
            lastError = AppHost.render(error)
        }
    }

    /// Confirm a previously previewed prune. The hash must match the one the
    /// preview produced — same intent-drift discipline as everything else.
    @discardableResult
    func confirmCachePrune() async -> Bool {
        guard let doctorPruneConfirm, let hash = cachePruneHash else {
            lastError = ReclaimError.previewHashMismatch.errorDescription
            return false
        }
        do {
            let result = try await doctorPruneConfirm(hash)
            let removed = (result.removed ?? []).filter { $0.removed == true }.count
            cachePruneNote = "Pruned \(removed) cache item(s)."
            cacheFindings = result.findings ?? []
            cachePruneHash = nil
            return true
        } catch {
            lastError = AppHost.render(error)
            return false
        }
    }
}
