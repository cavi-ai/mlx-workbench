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

    private let now: () -> Date
    private let fileManager: FileManager

    /// Set post-init (AppHost wires these to live config); closures so the
    /// coordinator always reads the current values.
    var quarantineDir: () -> String = { "" }
    var ggufRoots: () -> [String] = { [] }

    init(
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.now = now
        self.fileManager = fileManager
    }

    var totalReclaimableBytes: Int64 {
        opportunities.reduce(0) { $0 + $1.bytes }
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
        occupiedPaths: Set<String>
    ) {
        opportunities = ReclaimAdvisor.opportunities(
            snapshot: snapshot,
            duplicates: duplicates,
            lastUsedByPath: lastUsedByPath,
            isVerified: isVerified,
            occupiedPaths: occupiedPaths
        )
        plan = nil
        lastMoves = []
    }

    /// Test seam: inject opportunities without a full snapshot.
    func setOpportunitiesForTesting(_ value: [ReclaimOpportunity]) {
        opportunities = value
    }

    /// Freeze the selected actionable paths into a hashed plan.
    func preview(selected: Set<String>) {
        lastError = nil
        let actionable = opportunities
            .filter { $0.actionable && selected.contains($0.id) }
            .flatMap { $0.paths }
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
}
