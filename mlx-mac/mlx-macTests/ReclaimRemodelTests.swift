import XCTest

@testable import mlx_workbench

// MARK: - Fixtures

private enum Fixture {
    static let hash = String(repeating: "cdaaf36416f8", count: 5) + "abcd"
    static let hubBlob = "/Users/test/.cache/hf/hub/blobs/cd/\(hash)"

    static func opportunity(_ path: String, bytes: Int64, actionable: Bool = true, kind: ReclaimKind = .stale) -> ReclaimOpportunity {
        ReclaimOpportunity(kind: kind, paths: [path], bytes: bytes, evidence: "Not used in 90 days", confidence: .high, actionable: actionable)
    }

    static func quarantine(_ from: String, bytes: Int64, kind: QuarantineKind? = nil, movedAt: String = "2026-10-02T22:09:57.872974+00:00") -> QuarantineRecord {
        QuarantineRecord(movedAt: movedAt, from: from, to: "/q/\(UUID().uuidString)", bytes: bytes, deletedAt: nil, kind: kind)
    }

    static func item(_ state: SourceCleanupState, bytes: Int64? = nil, from: String = hubBlob, outputPath: String? = nil, movedAt: Date? = nil) -> SourceCleanupHistoryItem {
        SourceCleanupHistoryItem(
            record: ConvertedSourceMove(id: UUID().uuidString, from: from, to: "/Trash/\(UUID().uuidString)", outputPath: outputPath, movedAt: movedAt, bytes: bytes),
            state: state
        )
    }

    static func batch(_ items: [SourceCleanupHistoryItem]) -> SourceCleanupBatch {
        SourceCleanupBatch(id: UUID().uuidString, items: items)
    }

    static func workflow(sourcePath: String, output: String = "/models/atlas-MLX-4bit") -> ConversionWorkflow {
        ConversionWorkflow(
            id: UUID(), sourcePath: sourcePath, sourceModelKey: nil, sourceSignature: nil, outputPath: output, previewHash: "hash",
            jobReceipt: nil, completedModelPath: output, state: .verified, serveState: .idle, message: nil, errorMessage: nil,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), updatedAt: Date(timeIntervalSince1970: 1_790_000_000), lastKnownAgentState: "done"
        )
    }

    static func candidate(_ sourcePath: String, bytes: Int64?) -> SourceCleanupCandidate {
        SourceCleanupCandidate(workflow: workflow(sourcePath: sourcePath), bytes: bytes, reason: bytes == nil ? "Shared with another model." : nil)
    }

    static func model(path: String, name: String) -> LibraryModel {
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: 1_000, modifiedAt: nil, shard: nil,
            modelKey: path, architecture: nil, quantization: "4-bit", parameters: nil,
            structure: nil, signature: "signature", companion: nil, readable: true, status: "ready",
            outputs: [], tensorCount: nil, error: nil, task: nil
        )
        return LibraryModel(item: item, displayName: name, readiness: .ready)
    }

    static func ledger(
        opportunities: [ReclaimOpportunity] = [],
        quarantined: [QuarantineRecord] = [],
        candidates: [SourceCleanupCandidate] = [],
        checked: Bool = true,
        history: [SourceCleanupBatch] = [],
        hasLibrary: Bool = true
    ) -> ReclaimLedger {
        ReclaimLedger(opportunities: opportunities, quarantined: quarantined, candidates: candidates, sourcesChecked: checked, history: history, hasLibrary: hasLibrary)
    }

    static var uiDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/UI", isDirectory: true)
    }

    static func source(_ relative: String) throws -> String {
        try String(contentsOf: uiDirectory.appendingPathComponent(relative), encoding: .utf8)
    }

    static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}

// MARK: - AC1 ledger populations and freshness

@MainActor
final class ReclaimRemodelTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000_000)

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-reclaim-remodel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadyStageSumsActionableBytesAndMatchesTheBadgeOwner() {
        let opportunities = [
            Fixture.opportunity("/m/a.gguf", bytes: 100),
            Fixture.opportunity("/m/b.gguf", bytes: 50, actionable: false),
            Fixture.opportunity("/m/c.gguf", bytes: 25),
        ]
        let ledger = Fixture.ledger(opportunities: opportunities)
        let coordinator = ReclaimCoordinator()
        coordinator.setOpportunitiesForTesting(opportunities)
        XCTAssertEqual(ledger.readyBytes, 125)
        XCTAssertEqual(ledger.readyCount, 2)
        XCTAssertEqual(ledger.readyBytes, coordinator.totalReclaimableBytes)
        XCTAssertEqual(ledger.stages.first { $0.id == .ready }?.figure, .bytes(125))
    }

    func testQuarantineStageCountsEveryLedgerRecordIncludingFolders() {
        let ledger = Fixture.ledger(quarantined: [
            Fixture.quarantine("/m/a.gguf", bytes: 10),
            Fixture.quarantine("/m/folder", bytes: 90, kind: .mlxDirectory),
        ])
        XCTAssertEqual(ledger.quarantineBytes, 100)
        XCTAssertEqual(ledger.quarantineCount, 2)
        XCTAssertEqual(ledger.stages.first { $0.id == .quarantine }?.detail, "2 files")
    }

    func testRecordsMarkedDeletedLeaveQuarantineAndTheLedger() throws {
        let hold = try makeRoot()
        let directory = Quarantine.resolve(hold.path)
        let kept = "\(directory)/kept.gguf", gone = "\(directory)/gone.gguf"
        try Data("kept".utf8).write(to: URL(fileURLWithPath: kept))
        try Data("gone".utf8).write(to: URL(fileURLWithPath: gone))
        let encoder = JSONEncoder()
        let lines = [
            QuarantineRecord(movedAt: "2026-10-02T22:09:57+00:00", from: "/m/kept.gguf", to: kept, bytes: 4, deletedAt: nil, kind: nil),
            QuarantineRecord(movedAt: "2026-10-02T22:09:58+00:00", from: "/m/gone.gguf", to: gone, bytes: 4, deletedAt: "2026-10-03T00:00:00+00:00", kind: nil),
        ].map { String(decoding: try! encoder.encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: URL(fileURLWithPath: "\(directory)/\(Quarantine.ledgerName)"), atomically: true, encoding: .utf8)

        let coordinator = ReclaimCoordinator()
        coordinator.quarantineDir = { directory }
        coordinator.refreshQuarantined()
        let ledger = Fixture.ledger(quarantined: coordinator.quarantined)

        XCTAssertEqual(coordinator.quarantined.map(\.from), ["/m/kept.gguf"])
        XCTAssertEqual(ledger.quarantineCount, 1)
        XCTAssertEqual(ledger.stages.first { $0.id == .trash }?.figure, .bytes(0))
    }

    func testTrashStageCountsInTrashAndConflictAndNeverCountsUnknownBytesAsZero() {
        let history = [Fixture.batch([
            Fixture.item(.inTrash, bytes: nil),
            Fixture.item(.conflict, bytes: 10),
            Fixture.item(.restored, bytes: 999),
            Fixture.item(.unavailable, bytes: 999),
            Fixture.item(.incomplete, bytes: 999),
            Fixture.item(.needsReview, bytes: 999),
        ])]
        let ledger = Fixture.ledger(history: history)
        XCTAssertEqual(ledger.trashItemCount, 2)
        XCTAssertEqual(ledger.trashKnownBytes, 10)
        XCTAssertEqual(ledger.trashUnknownCount, 1)
        let trash = ledger.stages.first { $0.id == .trash }
        XCTAssertEqual(trash?.figure, .bytes(10))
        XCTAssertEqual(trash?.detail, "2 items · 1 size not recorded")
    }

    func testTrashStageWithNoRecordedSizesShowsTheCountAndSaysSizeNotRecorded() {
        let ledger = Fixture.ledger(history: [Fixture.batch((0..<11).map { _ in Fixture.item(.inTrash) })])
        let trash = ledger.stages.first { $0.id == .trash }
        XCTAssertEqual(trash?.figure, .items(11))
        XCTAssertEqual(trash?.numeral, "11")
        XCTAssertEqual(trash?.detail, "11 items · size not recorded")
        XCTAssertEqual(trash?.caption, "still on disk until Trash is emptied")
    }

    func testEmptyStagesSayWhatIsEmptyAndDropTheCaption() {
        let stages = Fixture.ledger().stages
        XCTAssertEqual(stages.map(\.detail), ["No suggestions", "Empty", "Nothing in Trash"])
        XCTAssertEqual(stages.map(\.caption), ["", "", ""])
        XCTAssertEqual(stages.map(\.subject), [nil, nil, nil])
    }

    func testNonEmptyStagesNameTheirLargestMemberAndTheReadyStageSaysHowOldItIs() {
        let models = [Fixture.model(path: "/m/big.gguf", name: "Big Model")]
        let generated = Date(timeIntervalSinceReferenceDate: 1_000_000_000)
        let from = "/h/hub/models--Qwen--Qwen-Image-2.1/blobs/\(Fixture.hash)"
        let ledger = ReclaimLedger(
            opportunities: [Fixture.opportunity("/m/big.gguf", bytes: 90), Fixture.opportunity("/m/small.gguf", bytes: 10)],
            quarantined: [Fixture.quarantine("/m/a.gguf", bytes: 5), Fixture.quarantine("/m/folder", bytes: 50, kind: .mlxDirectory)],
            candidates: [],
            sourcesChecked: true,
            history: [Fixture.batch([Fixture.item(.inTrash, bytes: 7, from: "/src/small.gguf"), Fixture.item(.inTrash, bytes: 70, from: from, outputPath: "/models/atlas-MLX-4bit")])],
            hasLibrary: true,
            models: models,
            generatedAt: generated,
            now: generated.addingTimeInterval(300)
        )
        XCTAssertEqual(ledger.stages.map(\.subject), [
            "Big Model · Stale",
            "folder · Local MLX folder",
            "Qwen/Qwen-Image-2.1 · original of verified atlas-MLX-4bit",
        ])
        XCTAssertEqual(ledger.stages[0].asOf, "as of " + WorkbenchRelativeTime.text(for: generated, style: .full, now: generated.addingTimeInterval(300)))
        XCTAssertNil(ledger.stages[1].asOf)
        XCTAssertEqual(ledger.stages[0].caption, "can move to quarantine now")
        XCTAssertNil(Fixture.ledger().stages[0].asOf)
    }

    func testRelativeTimeNeverReadsFutureWithinSkew() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000_000)
        for offset in [-0.3, -5, 0.5, 5] as [TimeInterval] {
            let text = WorkbenchRelativeTime.text(for: now.addingTimeInterval(offset), style: .full, now: now)
            XCTAssertEqual(text, "just now")
            XCTAssertFalse(text.hasPrefix("in "))
        }
        XCTAssertTrue(WorkbenchRelativeTime.text(for: now.addingTimeInterval(-300), style: .full, now: now).contains("ago"))
        XCTAssertTrue(WorkbenchRelativeTime.text(for: now.addingTimeInterval(3600), style: .full, now: now).hasPrefix("in "))
    }

    func testReadyStageFreshnessNeverReadsFutureWhenSnapshotIsStampedAfterNow() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000_000)
        let ledger = ReclaimLedger(
            opportunities: [Fixture.opportunity("/m/big.gguf", bytes: 90)],
            quarantined: [], candidates: [], sourcesChecked: true, history: [], hasLibrary: true,
            models: [Fixture.model(path: "/m/big.gguf", name: "Big Model")],
            generatedAt: now.addingTimeInterval(0.5),
            now: now
        )
        let asOf = ledger.stages[0].asOf ?? ""
        XCTAssertTrue(asOf.hasPrefix("as of "))
        XCTAssertFalse(asOf.contains("in "))
    }

    func testOriginalsBlockShowsTheDesignedStateOnlyBeforeTheCheckRuns() {
        XCTAssertEqual(ReclaimOriginalsState(isChecking: false, isChecked: false, eligibleCount: 0), .unchecked)
        XCTAssertEqual(ReclaimOriginalsState(isChecking: true, isChecked: false, eligibleCount: 0), .checking)
        XCTAssertEqual(ReclaimOriginalsState(isChecking: false, isChecked: true, eligibleCount: 0), .none)
        XCTAssertEqual(ReclaimOriginalsState(isChecking: false, isChecked: true, eligibleCount: 2), .listed)
        XCTAssertEqual(ReclaimOriginalsState.uncheckedText, "Check originals to find sources that can be removed safely.")
    }

    func testOriginalsAreNotCheckedUntilTheCheckRuns() {
        let candidates = [Fixture.candidate("/src/a.gguf", bytes: 400)]
        XCTAssertEqual(Fixture.ledger(candidates: candidates, checked: false).originalsLine, "Originals not checked")
        XCTAssertEqual(Fixture.ledger(candidates: [], checked: true).originalsLine, "No eligible originals")
        XCTAssertEqual(Fixture.ledger(candidates: [Fixture.candidate("/src/a.gguf", bytes: nil)], checked: true).originalsLine, "No eligible originals")
    }

    func testOriginalsOverlappingAnOpportunityAreCountedOnce() {
        let candidates = [Fixture.candidate("/src/a.gguf", bytes: 400), Fixture.candidate("/src/b.gguf", bytes: 600)]
        let ledger = Fixture.ledger(opportunities: [Fixture.opportunity("/src/a.gguf", bytes: 400)], candidates: candidates)
        XCTAssertEqual(ledger.originalsCount, 1)
        XCTAssertEqual(ledger.originalsBytes, 600)
        XCTAssertEqual(ledger.originalsLine, "1 original · \(ReclaimFormat.byteCount(600))")
    }

    func testHeroWaitsForTheLibraryThenReadsTheAnalysis() {
        let waiting = Fixture.ledger(hasLibrary: false).stages.first { $0.id == .ready }
        XCTAssertEqual(waiting?.figure, .pending)
        XCTAssertEqual(waiting?.numeral, "—")
        let landed = Fixture.ledger(opportunities: [Fixture.opportunity("/m/a.gguf", bytes: 5_000_000_000)]).stages.first { $0.id == .ready }
        XCTAssertEqual(landed?.figure, .bytes(5_000_000_000))
    }

    func testFreshnessReanalyzesOnANewSnapshotOnly() {
        let first = Date(timeIntervalSince1970: 1_790_000_000), second = first.addingTimeInterval(60)
        XCTAssertTrue(ReclaimFreshness.shouldReanalyze(analyzed: nil, current: first, hasOpenPreview: false, hasUnreadMoves: false))
        XCTAssertTrue(ReclaimFreshness.shouldReanalyze(analyzed: first, current: second, hasOpenPreview: false, hasUnreadMoves: false))
        XCTAssertFalse(ReclaimFreshness.shouldReanalyze(analyzed: second, current: second, hasOpenPreview: false, hasUnreadMoves: false))
        XCTAssertFalse(ReclaimFreshness.shouldReanalyze(analyzed: nil, current: nil, hasOpenPreview: false, hasUnreadMoves: false))
    }

    func testAnOpenPlanOrUnreadMovesAreNeverWipedByFreshness() throws {
        let root = try makeRoot()
        let file = root.appendingPathComponent("stale.gguf")
        try Data("weights".utf8).write(to: file)
        let coordinator = ReclaimCoordinator(now: { self.now })
        let opportunity = Fixture.opportunity(file.path, bytes: 7)
        coordinator.setOpportunitiesForTesting([opportunity])
        XCTAssertFalse(ReclaimFreshness.hasOpenPreview(coordinator))

        coordinator.preview(selected: [opportunity.id])
        XCTAssertTrue(ReclaimFreshness.hasOpenPreview(coordinator))
        let generation = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertFalse(ReclaimFreshness.shouldReanalyze(analyzed: nil, current: generation, hasOpenPreview: ReclaimFreshness.hasOpenPreview(coordinator), hasUnreadMoves: false))

        coordinator.analyze(snapshot: nil, duplicates: [], lastUsedByPath: [:], isVerified: { _ in false }, occupiedPaths: [])
        XCTAssertFalse(ReclaimFreshness.hasOpenPreview(coordinator))
        XCTAssertTrue(ReclaimFreshness.shouldReanalyze(analyzed: nil, current: generation, hasOpenPreview: ReclaimFreshness.hasOpenPreview(coordinator), hasUnreadMoves: false))
        XCTAssertFalse(ReclaimFreshness.shouldReanalyze(analyzed: nil, current: generation, hasOpenPreview: false, hasUnreadMoves: true))
    }
}

// MARK: - AC4 names

final class ReclaimNamesTests: XCTestCase {
    func testHubBlobOutsideAnyRepoFolderIsACacheFileWithTheHashInDetailOnly() {
        let name = ReclaimNames.resolve(paths: [Fixture.hubBlob], models: [])
        XCTAssertEqual(name.title, "Cache file")
        XCTAssertEqual(name.detail, Fixture.hash)
        XCTAssertTrue(name.isCacheFile)
        XCTAssertFalse(ReclaimNames.isHashName(name.title))
    }

    func testModelsFolderResolvesToTheRepoId() {
        let path = "/h/hub/models--abenzerps--Qwen-Image-2.1-Uncensored-GGUF/blobs/\(Fixture.hash)"
        let name = ReclaimNames.resolve(paths: [path], models: [])
        XCTAssertEqual(name.title, "abenzerps/Qwen-Image-2.1-Uncensored-GGUF")
        XCTAssertFalse(name.isCacheFile)
    }

    func testHistoryBatchWithAnOutputPathIsNamedBySourceAndDescribesTheOutput() {
        let from = "/h/hub/models--Qwen--Qwen-Image-2.1/blobs/\(Fixture.hash)"
        let row = ReclaimHistoryRow(Fixture.batch([Fixture.item(.unavailable, from: from, outputPath: "/models/atlas-MLX-4bit")]), models: [])
        XCTAssertEqual(row.name.title, "Qwen/Qwen-Image-2.1")
        XCTAssertEqual(row.subtitle, "Earlier cleanup · Original of atlas-MLX-4bit · Trash item unavailable")
        let mixed = ReclaimHistoryRow(Fixture.batch([Fixture.item(.inTrash, from: from), Fixture.item(.restored, from: from)]), models: [])
        XCTAssertEqual(mixed.subtitle, "Earlier cleanup")
    }

    func testPlainFileAndFolderKeepTheirNames() {
        XCTAssertEqual(ReclaimNames.resolve(paths: ["/models/qwen.gguf"], models: []).title, "qwen.gguf")
        XCTAssertEqual(ReclaimNames.resolve(paths: ["/models/Atlas-MLX-4bit"], models: []).title, "Atlas-MLX-4bit")
    }

    func testLibraryDisplayNameComesFirst() {
        let model = Fixture.model(path: "/models/qwen.gguf", name: "Qwen 3")
        XCTAssertEqual(ReclaimNames.resolve(paths: ["/models/qwen.gguf"], models: [model]).title, "Qwen 3")
    }

    func testIncompleteCacheBlobIsACacheFile() {
        let name = ReclaimNames.resolve(paths: ["/h/hub/blobs/ab/\(Fixture.hash).incomplete"], models: [])
        XCTAssertEqual(name.title, "Cache file")
    }

    func testHistoryRowsNameBatchesWithoutMergingThem() {
        let blob = Fixture.batch([Fixture.item(.inTrash, bytes: 40)])
        let folder = Fixture.batch([Fixture.item(.inTrash, from: "/h/hub/models--Qwen--Qwen-Image-2.1/blobs/\(Fixture.hash)")])
        let rows = [blob, folder].map { ReclaimHistoryRow($0, models: []) }
        XCTAssertEqual(rows.map(\.name.title), ["Cache file", "Qwen/Qwen-Image-2.1"])
        XCTAssertEqual(rows[0].subtitle, "Earlier cleanup · \(ReclaimFormat.byteCount(40)) · In Trash")
        XCTAssertEqual(rows[1].subtitle, "Earlier cleanup · In Trash")
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
    }

    func testMovedAtFormatsIsoAndKeepsUnparseableText() {
        XCTAssertNotEqual(ReclaimFormat.movedAt("2026-10-02T22:09:57.872974+00:00"), "2026-10-02T22:09:57.872974+00:00")
        XCTAssertEqual(ReclaimFormat.movedAt("yesterday-ish"), "yesterday-ish")
    }
}

// MARK: - AC3 errors once, AC2 survivors, AC10 states

@MainActor
final class ReclaimPageStateTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-workbench-reclaim-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEachReclaimErrorHasExactlyOneBanner() throws {
        let coordinator = ReclaimCoordinator()
        coordinator.preview(selected: [])
        XCTAssertEqual(coordinator.lastError, ReclaimError.nothingSelected.errorDescription)

        let reclaimFiles = ["Views/DuplicatesView.swift", "Views/SourceCleanupSection.swift", "Views/ReclaimViews.swift", "Views/ReclaimPresentation.swift"]
        let text = try reclaimFiles.map(Fixture.source).joined(separator: "\n")
        XCTAssertEqual(Fixture.occurrences(of: "ErrorBanner(text: reclaim.lastError)", in: text), 1)
        XCTAssertEqual(Fixture.occurrences(of: "ErrorBanner(text: reclaim.sourceHistoryError)", in: text), 1)
        XCTAssertEqual(Fixture.occurrences(of: "ErrorBanner(text: appHost.lastError)", in: text), 1)
    }

    func testMoveResultsAndCacheCheckSurviveAnEmptyOpportunityList() throws {
        let root = try makeRoot(), quarantine = try makeRoot()
        let file = root.appendingPathComponent("stale.gguf")
        try Data("weights".utf8).write(to: file)
        let coordinator = ReclaimCoordinator(now: { Date(timeIntervalSinceReferenceDate: 1_000_000_000) })
        coordinator.quarantineDir = { quarantine.path }
        coordinator.ggufRoots = { [root.path] }
        coordinator.doctorScan = { throw CancellationError() }
        let opportunity = Fixture.opportunity(file.path, bytes: 7)
        coordinator.setOpportunitiesForTesting([opportunity])
        coordinator.preview(selected: [opportunity.id])
        let plan = try XCTUnwrap(coordinator.plan)
        coordinator.confirm(previewHash: plan.previewHash)

        XCTAssertTrue(coordinator.opportunities.isEmpty)
        XCTAssertEqual(coordinator.lastMoves.count, 1)
        let state = ReclaimSuggestionsState(
            opportunityCount: coordinator.opportunities.count,
            candidateCount: coordinator.sourceCandidates.count,
            lastMoveCount: coordinator.lastMoves.count,
            cacheAvailable: coordinator.doctorScan != nil,
            cacheFindingCount: coordinator.cacheFindings.count
        )
        XCTAssertTrue(state.showsEmpty)
        XCTAssertTrue(state.showsMoveResults)
        XCTAssertTrue(state.showsCacheControls)
    }

    func testCacheCheckIsHiddenOnlyWhenTheAgentCannotRunIt() {
        let state = ReclaimSuggestionsState(opportunityCount: 0, candidateCount: 0, lastMoveCount: 0, cacheAvailable: false, cacheFindingCount: 0)
        XCTAssertFalse(state.showsCacheControls)
        XCTAssertFalse(state.showsMoveResults)
        XCTAssertTrue(state.showsEmpty)
    }

    func testCacheSummaryNeverTurnsUnknownSizesIntoZero() {
        let unsized = ReclaimCacheSummary(findings: [DoctorFinding(path: "/a", kind: nil, message: nil, size: nil)])
        XCTAssertEqual(unsized.text, "1 incomplete cache item · size not recorded")
        let mixed = ReclaimCacheSummary(findings: [
            DoctorFinding(path: "/a", kind: nil, message: nil, size: 1_000_000),
            DoctorFinding(path: "/b", kind: nil, message: nil, size: nil),
        ])
        XCTAssertEqual(mixed.text, "2 incomplete cache items · \(ReclaimFormat.byteCount(1_000_000)) reclaimable · 1 size not recorded")
    }

    func testSuggestionRowsExplainReviewOnlyItemsInWordsAndNeverPaintBytesAsWarnings() throws {
        let review = ReclaimSuggestionRow(Fixture.opportunity("/m/folder", bytes: 3, actionable: false), models: [])
        XCTAssertFalse(review.isActionable)
        XCTAssertEqual(review.reason, "Review only: not selectable here. Quarantine a local MLX folder with Review model folder…; shared Hugging Face cache snapshots are protected.")
        XCTAssertTrue(review.evidence.hasSuffix("High confidence"))
        let actionable = ReclaimSuggestionRow(Fixture.opportunity("/m/a.gguf", bytes: 3), models: [])
        XCTAssertNil(actionable.reason)

        XCTAssertEqual(Fixture.occurrences(of: "WorkbenchColor.warning", in: try Fixture.source("Views/DuplicatesView.swift")), 0)
        // The one remaining use is the legacy-record notice in the restore sheet.
        let cleanup = try Fixture.source("Views/SourceCleanupSection.swift")
        XCTAssertEqual(Fixture.occurrences(of: "WorkbenchColor.warning", in: cleanup), 1)
        let notice = try XCTUnwrap(cleanup.components(separatedBy: "WorkbenchColor.warning").first?.components(separatedBy: "\n").suffix(2).joined())
        XCTAssertTrue(notice.contains("Earlier entries did not record file identity."))
    }

    func testGroupsFollowAFixedKindOrder() {
        let groups = ReclaimSuggestionGroup.groups([
            Fixture.opportunity("/m/a.gguf", bytes: 1, kind: .crossRootDuplicate),
            Fixture.opportunity("/m/b.gguf", bytes: 1, kind: .stale),
        ])
        XCTAssertEqual(groups.map(\.kind), [.stale, .crossRootDuplicate])
    }
}

// MARK: - AC6 prominence

@MainActor
final class ReclaimProminenceTests: XCTestCase {
    func testOneProminentActionPerStateWithConfirmFirst() {
        let cases: [(plan: Bool, selection: Bool, prune: Bool, expected: ReclaimAction?)] = [
            (false, false, false, nil),
            (false, true, false, .previewReclaim),
            (false, false, true, .confirmPrune),
            (false, true, true, .previewReclaim),
            (true, false, false, .confirmQuarantine),
            (true, true, false, .confirmQuarantine),
            (true, false, true, .confirmQuarantine),
            (true, true, true, .confirmQuarantine),
        ]
        for state in cases {
            let primary = ReclaimProminence.primary(hasPlan: state.plan, hasSelection: state.selection, hasPrunePreview: state.prune)
            XCTAssertEqual(primary, state.expected, "\(state)")
            XCTAssertLessThanOrEqual(ReclaimAction.allCases.filter { $0 == primary }.count, 1)
        }
    }

    func testSelectionThenPreviewDrivesTheCoordinatorStates() throws {
        let coordinator = ReclaimCoordinator()
        let opportunity = Fixture.opportunity("/m/x.gguf", bytes: 1)
        coordinator.setOpportunitiesForTesting([opportunity])
        XCTAssertNil(ReclaimProminence.primary(hasPlan: coordinator.plan != nil, hasSelection: false, hasPrunePreview: false))
        XCTAssertEqual(ReclaimProminence.primary(hasPlan: coordinator.plan != nil, hasSelection: true, hasPrunePreview: false), .previewReclaim)
        coordinator.preview(selected: [opportunity.id])
        XCTAssertEqual(ReclaimProminence.primary(hasPlan: coordinator.plan != nil, hasSelection: true, hasPrunePreview: false), .confirmQuarantine)
    }

    func testProminentStylesAreConfinedToTheDeclaredRegions() throws {
        XCTAssertEqual(Fixture.occurrences(of: ".borderedProminent", in: try Fixture.source("Views/ReclaimViews.swift")), 1)
        // Sheet confirms: Move to Trash and Quarantine folder.
        XCTAssertEqual(Fixture.occurrences(of: ".borderedProminent", in: try Fixture.source("Views/DuplicatesView.swift")), 2)
        // Sheet confirms: Move originals to Trash and Restore originals.
        XCTAssertEqual(Fixture.occurrences(of: ".borderedProminent", in: try Fixture.source("Views/SourceCleanupSection.swift")), 2)
    }

    func testSurfaceAndBorderedActionsAreConfinedToTheLeadControls() throws {
        let page = try Fixture.source("Views/DuplicatesView.swift")
        let cleanup = try Fixture.source("Views/SourceCleanupSection.swift")
        XCTAssertEqual(Fixture.occurrences(of: "WorkbenchSurface", in: page), 1)
        XCTAssertEqual(Fixture.occurrences(of: "WorkbenchSurface", in: cleanup), 0)
        XCTAssertFalse(page.contains("\"Check originals\""))
        XCTAssertTrue(cleanup.contains("\"Check originals\""))
        XCTAssertEqual(Fixture.occurrences(of: ".borderless", in: page), 2)
        XCTAssertEqual(Fixture.occurrences(of: ".borderless", in: cleanup), 1)
    }

    func testEveryRequiredLabelSurvives() throws {
        let text = try ["Views/DuplicatesView.swift", "Views/SourceCleanupSection.swift", "Views/ReclaimViews.swift", "ComparisonInsightsView.swift"]
            .map { try Fixture.source($0.hasPrefix("Views/") ? $0 : "Views/\($0)") }.joined(separator: "\n")
        let labels = [
            "Analyze", "Review model folder…", "Preview reclaim", "Confirm quarantine", "Check HF cache", "Preview prune", "Confirm prune",
            "Put back", "Move to Trash", "Show all", "Check originals", "Review originals", "Reveal in Trash", "Review restore", "Refresh",
            "Rescan library", "Review folder cleanup…", "Move originals to Trash", "Quarantine model folder", "Restore original sources",
            "Restore originals", "Quarantine folder",
        ]
        for label in labels {
            XCTAssertTrue(text.contains("\"\(label)"), "missing label: \(label)")
        }
    }
}

// MARK: - AC13 sheets, AC5 triggers

@MainActor
final class ReclaimSheetAndTriggerTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEachSheetOpensFromItsOwnState() {
        let id = UUID()
        func sheets(trash: Bool = false, folder: Bool = false, plan: UUID? = nil, reviewed: UUID? = nil, restore: Bool = false, active: Bool = true) -> Set<ReclaimSheet> {
            ReclaimSheets.presented(hasTrashPlan: trash, hasFolderPlan: folder, sourcePlanWorkflowID: plan, reviewedSourceID: reviewed, hasRestorePlan: restore, isRouteActive: active)
        }
        XCTAssertEqual(sheets(), [])
        XCTAssertEqual(sheets(trash: true), [.moveToTrash])
        XCTAssertEqual(sheets(folder: true), [.quarantineFolder])
        XCTAssertEqual(sheets(plan: id, reviewed: id), [.moveOriginals])
        XCTAssertEqual(sheets(restore: true), [.restoreOriginals])
        XCTAssertEqual(sheets(plan: id, reviewed: id, restore: true, active: false), [])
        XCTAssertEqual(sheets(plan: id, reviewed: UUID()), [])
    }

    func testAutoCleanupPlanNeverPresentsASheet() async throws {
        let fm = FileManager.default
        let root = try makeRoot()
        let source = root.appendingPathComponent("hub/models--org--source/snapshots/abc")
        let blob = root.appendingPathComponent("hub/blobs/ab/abcdef")
        let output = root.appendingPathComponent("output/model-MLX-4bit")
        for url in [source, blob.deletingLastPathComponent(), output] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data("source weights".utf8).write(to: blob)
        try fm.createSymbolicLink(at: source.appendingPathComponent("model.safetensors"), withDestinationURL: blob)
        try Data("{\"quantization\":{\"bits\":4}}".utf8).write(to: output.appendingPathComponent("config.json"))
        try Data("converted weights".utf8).write(to: output.appendingPathComponent("model.safetensors"))
        let receipt = root.appendingPathComponent("receipt.json")
        let payload: [String: Any] = ["exit_status": "done", "out": output.path, "argv": ["convert", "--hf-path", source.path, "--mlx-path", output.path]]
        try JSONSerialization.data(withJSONObject: payload).write(to: receipt)
        let stamp = Date().addingTimeInterval(1)
        let workflow = ConversionWorkflow(
            id: UUID(), sourcePath: "hf://org/source", sourceModelKey: nil, sourceSignature: nil, outputPath: output.path, previewHash: "hash",
            jobReceipt: receipt.path, completedModelPath: output.path, state: .verified, serveState: .idle, message: nil, errorMessage: nil,
            createdAt: stamp, updatedAt: stamp, lastKnownAgentState: "done"
        )

        let reclaim = ReclaimCoordinator(sourceJournalURL: root.appendingPathComponent("journal.json"), sourceTrashRoots: [])
        reclaim.mlxRoots = { [root.path] }
        await reclaim.previewSource(workflow)

        let planned = try XCTUnwrap(reclaim.sourcePlan)
        XCTAssertEqual(planned.workflow.id, workflow.id)
        let auto = ReclaimSheets.presented(hasTrashPlan: false, hasFolderPlan: false, sourcePlanWorkflowID: planned.workflow.id, reviewedSourceID: nil, hasRestorePlan: false, isRouteActive: true)
        XCTAssertEqual(auto, [])
        let reviewed = ReclaimSheets.presented(hasTrashPlan: false, hasFolderPlan: false, sourcePlanWorkflowID: planned.workflow.id, reviewedSourceID: workflow.id, hasRestorePlan: false, isRouteActive: true)
        XCTAssertEqual(reviewed, [.moveOriginals])
        let hostText = try String(contentsOf: Fixture.uiDirectory.deletingLastPathComponent().appendingPathComponent("AppHost.swift"), encoding: .utf8)
        XCTAssertEqual(Fixture.occurrences(of: "reviewedSourceID", in: hostText), 0)
    }

    func testViewingTriggersAreFirstMountOnly() throws {
        XCTAssertEqual(ReclaimTriggers.onMount(hasScan: true, isScanning: false), [.analyze, .refreshQuarantined])
        XCTAssertEqual(ReclaimTriggers.onMount(hasScan: false, isScanning: false), [.analyze, .refreshQuarantined, .rescan])
        XCTAssertEqual(ReclaimTriggers.onMount(hasScan: false, isScanning: true), [.analyze, .refreshQuarantined])

        let page = try Fixture.source("Views/DuplicatesView.swift")
        XCTAssertFalse(page.contains("onChange(of: isRouteActive"))
        XCTAssertEqual(Fixture.occurrences(of: ".onAppear", in: page), 1)
        let history = try Fixture.source("Views/SourceCleanupSection.swift")
        XCTAssertEqual(Fixture.occurrences(of: ".task { await reclaim.refreshSourceHistory() }", in: history), 1)
    }

    func testToolbarRescanIsRouteActiveAndDisabledWhileScanning() throws {
        let page = try Fixture.source("Views/DuplicatesView.swift")
        let toolbar = try XCTUnwrap(page.components(separatedBy: ".toolbar {").dropFirst().first?.components(separatedBy: ".onAppear").first)
        XCTAssertTrue(toolbar.contains("if isRouteActive"))
        XCTAssertTrue(toolbar.contains("appHost.requestRescan()"))
        XCTAssertTrue(toolbar.contains(".disabled(appHost.isScanning)"))
    }
}

// MARK: - AC9 layout

final class ReclaimLayoutTests: XCTestCase {
    func testWidthsDeriveFromTheRunContentWidth() {
        let mobile = ReclaimLayout(viewportWidth: 560)
        XCTAssertEqual(mobile.contentWidth, 512)
        XCTAssertEqual(mobile.innerWidth, 472)
        let desktop = ReclaimLayout(viewportWidth: 1220)
        XCTAssertEqual(desktop.contentWidth, 1100)
        XCTAssertEqual(desktop.innerWidth, 1060)
        XCTAssertEqual(ReclaimLayout(viewportWidth: 2400).contentWidth, 1100)
    }

    func testThreeStagesStackBelowTheirMinimumAndBackAboveItPlusHysteresis() {
        XCTAssertEqual(WorkbenchSize.Reclaim.stageThreshold, 632)
        XCTAssertTrue(ReclaimLayout(viewportWidth: 670).stacksStages)
        XCTAssertFalse(ReclaimLayout(viewportWidth: 680).stacksStages)
        let stacked = ReclaimLayout(viewportWidth: 670)
        XCTAssertTrue(ReclaimLayout(viewportWidth: 690, previous: stacked).stacksStages)
        XCTAssertFalse(ReclaimLayout(viewportWidth: 696, previous: stacked).stacksStages)
    }

    func testRowsAndHeaderCollapseAtTheirThresholds() {
        let tablet = ReclaimLayout(viewportWidth: 840)
        XCTAssertFalse(tablet.stacksStages)
        XCTAssertFalse(tablet.compactSuggestions)
        XCTAssertFalse(tablet.wrapsHeader)
        XCTAssertFalse(tablet.compactQuarantine)
        XCTAssertFalse(tablet.compactHistory)
        let mobile = ReclaimLayout(viewportWidth: 560)
        XCTAssertTrue(mobile.stacksStages)
        XCTAssertTrue(mobile.compactSuggestions)
        XCTAssertTrue(mobile.wrapsHeader)
        XCTAssertTrue(mobile.compactQuarantine)
        XCTAssertTrue(mobile.compactHistory)
        let narrowWide = ReclaimLayout(viewportWidth: 610)
        XCTAssertFalse(narrowWide.compactSuggestions)
        XCTAssertTrue(narrowWide.wrapsHeader)
    }

    func testHysteresisKeepsACompactLayoutUntilItClearsTheThreshold() {
        XCTAssertTrue(ReclaimLayout.isCompact(width: 519, threshold: 520, wasCompact: false))
        XCTAssertFalse(ReclaimLayout.isCompact(width: 520, threshold: 520, wasCompact: false))
        XCTAssertTrue(ReclaimLayout.isCompact(width: 535, threshold: 520, wasCompact: true))
        XCTAssertFalse(ReclaimLayout.isCompact(width: 536, threshold: 520, wasCompact: true))
    }
}
