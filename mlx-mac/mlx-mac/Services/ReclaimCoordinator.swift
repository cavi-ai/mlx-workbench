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

/// How one model copy leaves the disk, frozen at preview and rechecked at confirm.
enum CopyRemovalStep: Equatable, Sendable {
    case quarantineFiles([ReclaimPlanItem])
    case quarantineFolder(QuarantineFileSnapshot)
    case trashRepository(LibraryTrashPlan)
    case quarantineOllama(OllamaRemovalPlan)
    case quarantineAsset(AssetRemovalReview)

    var summary: String {
        switch self {
        case .quarantineFiles(let files): files.count == 1 ? "GGUF file to quarantine" : "\(files.count) GGUF files to quarantine"
        case .quarantineFolder: "Folder to quarantine"
        case .trashRepository: "Hugging Face cache repository to Trash"
        case .quarantineAsset: "Model file to quarantine"
        case .quarantineOllama(let plan): plan.blobs.isEmpty ? "Ollama tag to quarantine; its weights stay for other tags" : "Ollama tag and unshared weights to quarantine"
        }
    }
}

struct CopyRemoval: Identifiable, Equatable, Sendable {
    let path: String
    let name: String
    let step: CopyRemovalStep?
    let refusal: String?
    var id: String { path }
}

struct CopyRemovalPlan: Equatable, Sendable {
    let removals: [CopyRemoval]
    let freedBytes: Int64
    let roots: [String]
    let quarantineDir: String
    var actionable: [CopyRemoval] { removals.filter { $0.step != nil } }
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
    case ownershipUnavailable(String)
    case servingOwnershipUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .ownershipUnavailable(let message), .servingOwnershipUnavailable(let message): return message
        case .nothingSelected: return "Select reclaimable items before previewing."
        case .previewHashMismatch: return "The reclaim selection changed after preview. Preview it again before confirming."
        }
    }
}

enum CopyRemovalError {
    case serving(String), other(String)

    @MainActor init(_ error: Error) {
        if let issue = error as? ReclaimError, case .servingOwnershipUnavailable(let message) = issue { self = .serving(message) }
        else { self = .other(AppHost.render(error)) }
    }
}

private struct CopyOwnershipCheckFailure: Error { let underlying: Error }

@MainActor
final class ReclaimCoordinator: ObservableObject {
    @Published private(set) var opportunities: [ReclaimOpportunity] = []
    @Published private(set) var plan: ReclaimPlan?
    @Published private(set) var lastMoves: [ReclaimMoveResult] = []
    @Published private(set) var isApplying = false
    @Published private(set) var progressMessage: String?
    @Published private(set) var lastError: String?
    /// Currently-quarantined files from the ledger, newest first — records
    /// whose quarantined file no longer exists (restored, or removed by the
    /// user) drop out of the view.
    @Published private(set) var quarantined: [QuarantineRecord] = []
    @Published private(set) var trashPlan: QuarantineTrashPlan?
    @Published private(set) var trashNote: String?
    @Published private(set) var folderPlan: ModelFolderReclaimPlan?
    @Published private(set) var copyPlan: CopyRemovalPlan?
    @Published private(set) var copyError: CopyRemovalError?
    @Published private(set) var copyMoves: [ReclaimMoveResult] = []
    @Published private(set) var libraryTrashPlan: LibraryTrashPlan?
    @Published private(set) var libraryTrashNote: String?
    @Published private(set) var libraryTrashError: String?
    var servingModelPaths: (() async throws -> [String])?
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
    private var quarantineGeneration = 0
    private let quarantineIO = DispatchQueue(label: "ai.cavi.workbench.quarantine", qos: .userInitiated)

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

    private var duplicateKeepers: [String] = []

    private var protectedFolderPaths: [String] {
        protectedPaths() + duplicateKeepers + opportunities.compactMap { $0.replacement?.keeper.path }
    }

    func previewLibraryTrash(_ path: String) async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        libraryTrashPlan = nil; libraryTrashNote = nil; libraryTrashError = nil
        do {
            guard let servingModelPaths else { throw QuarantineError.unsafeFolder("serving status is unavailable; refresh Health before retrying.") }
            let serving = try await servingModelPaths()
            let roots = sourceRoots, protected = protectedFolderPaths + serving, manager = fileManager
            let plan = try await Task.detached(priority: .userInitiated) {
                try Quarantine.previewModelTrash(path, roots: roots, protected: protected, fileManager: manager)
            }.value
            guard roots == sourceRoots else { throw QuarantineError.changedSincePreview }
            libraryTrashPlan = plan
        } catch { libraryTrashError = AppHost.render(error) }
    }

    func cancelLibraryTrash() { if !isApplying { libraryTrashPlan = nil } }

    func confirmLibraryTrash() async {
        guard !isApplying, let plan = libraryTrashPlan else { return }
        isApplying = true
        defer { isApplying = false; libraryTrashPlan = nil }
        do {
            guard let servingModelPaths else { throw QuarantineError.unsafeFolder("serving status is unavailable.") }
            let serving = try await servingModelPaths()
            let roots = sourceRoots, protected = protectedFolderPaths + serving, manager = fileManager
            let destination = try await Task.detached(priority: .userInitiated) {
                try Quarantine.trashModel(plan, roots: roots, protected: protected, fileManager: manager)
            }.value
            libraryTrashNote = "Moved to Trash. Recover in Finder: \(destination.path)"
            libraryTrashError = nil
        } catch { libraryTrashError = AppHost.render(error) }
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
        await refreshQuarantined()
    }

    /// Freeze how each selected copy leaves the disk. Copies a guard refuses
    /// stay in the plan with the reason and are skipped at confirm.
    func previewCopies(_ selected: Set<String>, items: [StoredModel], duplicates: [DuplicateGroup] = [], keep: [String: String] = [:]) async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        copyPlan = nil; copyError = nil; copyMoves = []
        do {
            guard let servingModelPaths else { throw ReclaimError.servingOwnershipUnavailable("Serving status is unavailable. Refresh Serving, then retry model removal.") }
            let serving = try await servingModelPaths()
            let roots = sourceRoots, protected = protectedFolderPaths + serving, dir = quarantineDir(), manager = fileManager
            let paths = DiskLedger.expanded(selected, items: items)
            let chosen = items.filter { paths.contains($0.path) }
            let freed = DiskLedger.freedBytes(removing: paths, items: items)
            let assetProtected = protectedPaths() + opportunities.compactMap { $0.replacement?.keeper.path } + serving
            let removals = await Task.detached(priority: .userInitiated) {
                Self.removals(chosen, roots: roots, protected: protected, fileManager: manager,
                              allItems: items, selected: paths, duplicates: duplicates,
                              quarantineDir: dir, assetProtected: assetProtected, keep: keep)
            }.value
            guard roots == sourceRoots, dir == quarantineDir() else { throw QuarantineError.changedSincePreview }
            copyPlan = CopyRemovalPlan(removals: removals, freedBytes: freed, roots: roots, quarantineDir: dir)
        } catch is CancellationError { return }
        catch { if !Task.isCancelled { copyError = CopyRemovalError(error) } }
    }

    nonisolated static func removals(_ items: [StoredModel], roots: [String], protected: [String], fileManager: FileManager,
                                     allItems: [StoredModel] = [], selected: Set<String> = [], duplicates: [DuplicateGroup] = [],
                                     quarantineDir: String = "", assetProtected: [String] = [], keep: [String: String] = [:]) -> [CopyRemoval] {
        var repositories = Set<String>()
        return items.compactMap { item in
            if let repository = DiskLedger.cacheRepository(item), !repositories.insert(repository).inserted { return nil }
            do {
                let step: CopyRemovalStep
                switch (item.kind, item.store) {
                case ("asset", _):
                    guard let digest = item.asset?.sha256,
                          let group = duplicates.first(where: { $0.kind == "exact" && $0.verification == "full_sha256"
                              && $0.identity == "asset:sha256:" + digest && $0.sources.contains(item.path) }),
                          let identity = group.identity else {
                        throw QuarantineError.unsafeFolder("Compare the files before removal.")
                    }
                    let candidates = allItems.filter { !selected.contains($0.path) && $0.path != item.path
                        && group.sources.contains($0.path) && $0.kind == "asset" && $0.asset?.sha256 == digest
                        && $0.files.first?.id != item.files.first?.id }.sorted { $0.path < $1.path }
                    let chosen = keep[identity]
                    let protected = Set(assetProtected)
                    let keeper = chosen.flatMap { path in candidates.first { $0.path == path } }
                        ?? (chosen == nil ? candidates.first { DiskLedger.isProtected($0.path, by: protected) } : nil)
                        ?? (chosen == nil ? candidates.first { $0.path == group.keep } : nil)
                        ?? (chosen == nil ? candidates.first : nil)
                    guard let keeper else {
                        throw QuarantineError.unsafeFolder("Keep an unselected matching copy.")
                    }
                    let source = try Quarantine.assetReview(item, roots: roots, protected: assetProtected, quarantineDir: quarantineDir, fileManager: fileManager)
                    let retained = try Quarantine.assetReview(keeper, roots: roots, protected: [], quarantineDir: quarantineDir, requireSameVolume: false, fileManager: fileManager)
                    step = .quarantineAsset(AssetRemovalReview(source: source, keeper: retained))
                case ("ollama", _):
                    step = .quarantineOllama(try Quarantine.ollamaSnapshot(manifest: item.path, roots: roots, protected: protected, fileManager: fileManager))
                case (_, "huggingface"):
                    step = .trashRepository(try Quarantine.previewModelTrash(item.path, roots: roots, protected: protected, fileManager: fileManager))
                case ("gguf", _):
                    let files = try DiskLedger.removedFiles(of: item).map { file in
                        let path = try Quarantine.guardPath(file.path, roots: roots, fileManager: fileManager)
                        guard !DiskLedger.isProtected(path, by: Set(protected)) else { throw QuarantineError.unsafeFolder("the model is serving, preferred, or in use.") }
                        return ReclaimPlanItem(path: path, bytes: (try fileManager.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
                    }
                    step = .quarantineFiles(files)
                default:
                    step = .quarantineFolder(try Quarantine.folderSnapshot(target: item.path, roots: roots, protected: protected, fileManager: fileManager))
                }
                return CopyRemoval(path: item.path, name: item.name, step: step, refusal: nil)
            } catch {
                return CopyRemoval(path: item.path, name: item.name, step: nil, refusal: error.localizedDescription)
            }
        }
    }

    func cancelCopies() { if !isApplying { copyPlan = nil } }

    /// Apply the frozen plan copy by copy; each step rechecks its own preview.
    func confirmCopies() async {
        guard !isApplying, let plan = copyPlan else { return }
        guard plan.roots == sourceRoots, plan.quarantineDir == quarantineDir() else {
            copyPlan = nil
            copyError = CopyRemovalError(QuarantineError.changedSincePreview)
            return
        }
        isApplying = true
        defer { isApplying = false; progressMessage = nil; copyPlan = nil }
        var results: [ReclaimMoveResult] = []
        let manager = fileManager
        let cancellation = AssetVerificationCancellation()
        let deadline = ProcessInfo.processInfo.systemUptime + 600
        func checkedServing() async throws -> [String] {
            do {
                guard let servingModelPaths else {
                    throw ReclaimError.servingOwnershipUnavailable("Serving status is unavailable. Refresh Serving, then retry model removal.")
                }
                return try await servingModelPaths()
            } catch is CancellationError { throw CancellationError() }
            catch { throw CopyOwnershipCheckFailure(underlying: error) }
        }
        for (index, removal) in plan.actionable.enumerated() {
            if Task.isCancelled { cancellation.cancel(); break }
            guard let step = removal.step else { continue }
            progressMessage = "Removing \(index + 1) of \(plan.actionable.count)…"
            do {
                let serving = try await checkedServing()
                try Task.checkCancellation()
                let protected = protectedFolderPaths + serving, roots = plan.roots, dir = plan.quarantineDir, timestamp = now()
                if case .quarantineAsset(let asset) = step {
                    let assetProtected = protectedPaths() + opportunities.compactMap { $0.replacement?.keeper.path } + serving
                    let worker = Task.detached(priority: .userInitiated) {
                        try Quarantine.verifyAsset(asset.source, roots: roots, protected: assetProtected, quarantineDir: dir,
                                                   cancellation: cancellation, deadline: deadline, fileManager: manager)
                        try Quarantine.verifyAsset(asset.keeper, roots: roots, protected: [], quarantineDir: dir,
                                                   cancellation: cancellation, deadline: deadline, requireSameVolume: false, fileManager: manager)
                    }
                    try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel() }
                    try Task.checkCancellation()
                    try cancellation.check(deadline: deadline)
                    let freshServing = try await checkedServing()
                    try Task.checkCancellation()
                    let freshProtected = protectedPaths() + opportunities.compactMap { $0.replacement?.keeper.path } + freshServing
                    guard roots == sourceRoots, dir == quarantineDir() else { throw QuarantineError.changedSincePreview }
                    let mover = Task.detached(priority: .userInitiated) {
                        try cancellation.check(deadline: deadline)
                        return try Quarantine.moveAsset(asset, roots: roots, protected: freshProtected, quarantineDir: dir, now: timestamp, fileManager: manager)
                    }
                    let record = try await withTaskCancellationHandler { try await mover.value } onCancel: { cancellation.cancel() }
                    results.append(ReclaimMoveResult(path: removal.path, destination: record.to, error: nil))
                    continue
                }
                let destination = try await Task.detached(priority: .userInitiated) { () throws -> String in
                    switch step {
                    case .quarantineFiles(let files):
                        var last = ""
                        for file in files {
                            guard (try manager.attributesOfItem(atPath: file.path)[.size] as? Int64) == file.bytes,
                                  !DiskLedger.isProtected(file.path, by: Set(protected)) else { throw QuarantineError.changedSincePreview }
                            last = try Quarantine.move(target: file.path, roots: roots, quarantineDir: dir, now: timestamp, fileManager: manager).to
                        }
                        return last
                    case .quarantineFolder(let snapshot):
                        return try Quarantine.moveFolder(expected: snapshot, roots: roots, protected: protected, quarantineDir: dir, now: timestamp, fileManager: manager).to
                    case .trashRepository(let trash):
                        return try Quarantine.trashModel(trash, roots: roots, protected: protected, fileManager: manager).path
                    case .quarantineOllama(let ollama):
                        return try Quarantine.moveOllamaModel(expected: ollama, roots: roots, protected: protected, quarantineDir: dir, now: timestamp, fileManager: manager).to
                    case .quarantineAsset: throw QuarantineError.changedSincePreview
                    }
                }.value
                results.append(ReclaimMoveResult(path: removal.path, destination: destination, error: nil))
            } catch is CancellationError {
                break
            } catch let failure as CopyOwnershipCheckFailure {
                if Task.isCancelled { break }
                copyError = CopyRemovalError(failure.underlying)
                results.append(ReclaimMoveResult(path: removal.path, destination: nil, error: AppHost.render(failure.underlying)))
                break
            } catch {
                results.append(ReclaimMoveResult(path: removal.path, destination: nil, error: AppHost.render(error)))
            }
        }
        copyMoves = results
        if case nil = copyError, results.contains(where: { $0.error != nil }) {
            copyError = .other("Some copies could not be removed; see per-item results.")
        }
        await refreshQuarantined()
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
        duplicateKeepers = duplicates.filter { $0.kind == "exact" }.compactMap(\.keep)
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
    func refreshQuarantined() async {
        quarantineGeneration &+= 1
        let generation = quarantineGeneration
        let dir = quarantineDir(), manager = fileManager
        let records = await WorkbenchIO.perform(on: quarantineIO) {
            Quarantine.ledger(quarantineDir: dir, limit: 10000, fileManager: manager).filter { record in
                record.deletedAt == nil && (try? Quarantine.guardQuarantinedPath(record.to, quarantineDir: dir, kind: record.kind, fileManager: manager)) != nil
            }
        }
        guard generation == quarantineGeneration, dir == quarantineDir() else { return }
        quarantined = records
    }

    /// Put a quarantined file back where it came from, then refresh.
    func restore(_ record: QuarantineRecord) async {
        guard !isApplying else { return }
        isApplying = true
        let dir = quarantineDir(), manager = fileManager
        do {
            if record.kind == .assetFile {
                let original = Quarantine.resolve(record.from)
                guard sourceRoots.contains(where: { Quarantine.isWithin(original, parent: Quarantine.resolve($0)) && original != Quarantine.resolve($0) }),
                      !DiskLedger.isProtected(original, by: Set(protectedPaths())) else {
                    throw QuarantineError.unsafeFolder("The original model folder is no longer available or is protected.")
                }
            }
            try await Task.detached(priority: .userInitiated) {
                _ = try Quarantine.trashSnapshot(record, quarantineDir: dir, fileManager: manager)
                try Quarantine.restore(record, fileManager: manager)
            }.value
            lastError = nil
        } catch {
            lastError = AppHost.render(error)
        }
        isApplying = false
        await refreshQuarantined()
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
            await refreshQuarantined()
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
        await refreshQuarantined()
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
    func confirm(previewHash hash: String) async -> [ReclaimMoveResult]? {
        guard !isApplying else { return nil }
        guard let plan, plan.previewHash == hash else {
            lastError = ReclaimError.previewHashMismatch.errorDescription
            return nil
        }
        isApplying = true
        defer { isApplying = false; progressMessage = nil }
        var results: [ReclaimMoveResult] = []
        let roots = ggufRoots(), directory = quarantineDir(), manager = fileManager
        for (index, item) in plan.items.enumerated() {
            progressMessage = "Quarantining \(index + 1) of \(plan.items.count)…"
            do {
                try Task.checkCancellation()
                guard roots == ggufRoots(), directory == quarantineDir() else { throw QuarantineError.changedSincePreview }
                let path = Quarantine.resolve(item.path)
                guard !protectedFolderPaths.contains(where: { protected in
                    guard protected.hasPrefix("/") else { return HFRepoID.matches(protected, path) }
                    let other = Quarantine.resolve(protected)
                    return path == other || path.hasPrefix(other + "/") || other.hasPrefix(path + "/")
                }) else { throw QuarantineError.unsafeFolder("the model is retained or in use.") }
                let movedAt = now()
                let record = try await WorkbenchIO.perform(on: quarantineIO) { Result {
                    try Quarantine.move(target: item.path, roots: roots, quarantineDir: directory,
                        now: movedAt, fileManager: manager)
                } }.get()
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
        await refreshQuarantined()
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

    /// Wiring drift is not reclaimable; only cache findings count here.
    static func cacheFindings(in result: DoctorResult) -> [DoctorFinding] {
        (result.findings ?? []).filter { !$0.isDrift }
    }

    /// Scan for incomplete-cache reclaim candidates (read-only).
    func checkCache() async {
        guard let doctorScan else { return }
        do {
            let result = try await doctorScan()
            cacheFindings = Self.cacheFindings(in: result)
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
            cacheFindings = Self.cacheFindings(in: result)
            cachePruneHash = nil
            return true
        } catch {
            lastError = AppHost.render(error)
            return false
        }
    }
}
