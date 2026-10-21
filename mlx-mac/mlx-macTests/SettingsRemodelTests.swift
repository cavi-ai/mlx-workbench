import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

// MARK: - Fixtures

private enum SettingsFixtures {
    static let stamp = Date(timeIntervalSinceReferenceDate: 1_000_000_000)

    static func runtimeReport(ok: Bool) -> RuntimeReport {
        let message = ok ? "Ready." : "Missing mlx-lm."
        return RuntimeReport(
            convert: ConvertStatus(ok: ok, modules: [:], executables: [:], missingModules: ok ? [] : ["mlx_lm"], missingExecutables: [], install: "make install", message: message),
            serve: ServeStatus(ok: ok, executables: [:], missingExecutables: [], install: "make install", message: message),
            install: "make install", ok: ok
        )
    }

    static func idleWorkflowAPI() -> ModelWorkflowAPI {
        ModelWorkflowAPI(
            convertPreview: { _, _, _ in [:] },
            convertStart: { _, _, _, _ in [:] },
            convertStatus: { [] },
            servePreview: { _, _, _ in [:] },
            serveStart: { _, _, _, _ in [:] },
            serveStatus: { [] },
            serveStop: { _ in [:] }
        )
    }

    static func idleWorkflowPersistence() -> ModelWorkflowPersistence {
        ModelWorkflowPersistence(load: { [] }, upsert: { _ in })
    }

    @MainActor
    static func host(
        config: Config, scanOperation: @escaping @Sendable ([String], [String], Bool, Int?) async throws -> ScanResult
    ) -> AppHost {
        AppHost(
            config: config, discoveredRoots: [], configPath: "/state/config.json",
            agentHealth: .notConfigured, runtimeReport: runtimeReport(ok: true),
            scanOperation: scanOperation,
            modelWorkflowAPI: idleWorkflowAPI(), modelWorkflowPersistence: idleWorkflowPersistence()
        )
    }

    static func model(_ path: String, bytes: Int64 = 1_000) -> LibraryModel {
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: bytes,
            modifiedAt: nil, shard: nil,
            modelKey: "model", architecture: nil, quantization: "Q4_K_M", parameters: nil,
            structure: nil, signature: nil, companion: nil, readable: true,
            status: "ready", outputs: [], tensorCount: nil, error: nil, task: nil
        )
        return LibraryModel(item: item, readiness: .ready)
    }

    static func snapshot(_ models: [LibraryModel], generatedAt: Date = stamp) -> LibrarySnapshot {
        LibrarySnapshot(models: models, groups: [], hardware: HardwareProfile.current(), generatedAt: generatedAt)
    }

    /// Render snapshots read as scanned two hours before the render clock.
    static func renderStamp(now: Date) -> Date { now.addingTimeInterval(-2 * 3600) }

    static func config(gguf: [String], mlx: [String] = [], output: String = "/out/mlx", agent: String = "/agent") -> Config {
        Config(
            schemaVersion: Config.SCHEMA_VERSION, ggufRoots: gguf, mlxRoots: mlx, outputDir: output,
            mlxAgentPath: agent, quarantineDir: "/quarantine", qBits: 4, signatures: true, host: "127.0.0.1",
            port: 8765, verificationEnabled: true, watchEnabled: true, fitReserveGB: 4, reclaimStaleDays: 60,
            comparisonMaxTokens: 512
        )
    }

    /// Draft equals saved unless a draft list is given.
    static func make(
        saved: Config,
        gguf: [String]? = nil,
        mlx: [String]? = nil,
        output: String? = nil,
        models: [LibraryModel]? = [],
        scanned: ScanRoots?,
        directories: [String: SettingsDirectoryState] = [:],
        isScanning: Bool = false
    ) -> SettingsPresentation {
        SettingsPresentation.make(
            saved: saved,
            ggufRoots: gguf ?? saved.ggufRoots,
            mlxRoots: mlx ?? saved.mlxRoots,
            outputDir: output ?? saved.outputDir,
            snapshot: models.map { snapshot($0) },
            scannedRoots: scanned,
            directories: directories,
            isScanning: isScanning
        )
    }
}

// MARK: - Ledger rows (AC1, AC4)

final class SettingsLedgerTests: XCTestCase {
    private typealias F = SettingsFixtures

    func testCountedRowSumsModelBytesAndNamesModels() {
        let saved = F.config(gguf: ["/m"])
        let ledger = F.make(
            saved: saved, models: [F.model("/m/a.gguf", bytes: 2_000_000), F.model("/m/b.gguf", bytes: 3_000_000)],
            scanned: ScanRoots(gguf: ["/m"], mlx: ["/m", "/out/mlx"])
        )
        XCTAssertEqual(ledger.gguf.map(\.state), [.counted(models: 2, bytes: 5_000_000)])
        XCTAssertEqual(ledger.gguf[0].state.figures, "2 models · " + ByteCountFormatter.string(fromByteCount: 5_000_000, countStyle: .file))
        let single = F.make(saved: saved, models: [F.model("/m/a.gguf")], scanned: ScanRoots(gguf: ["/m"], mlx: ["/m"]))
        XCTAssertTrue(single.gguf[0].state.figures.hasPrefix("1 model · "))
    }

    func testEveryRowState() {
        let saved = F.config(gguf: ["/m"])
        let scanned = ScanRoots(gguf: ["/m"], mlx: ["/m", "/out/mlx"])
        XCTAssertEqual(F.make(saved: saved, scanned: scanned).gguf[0].state, .none)
        XCTAssertEqual(F.make(saved: saved, gguf: ["/m", "/draft"], scanned: scanned).gguf[1].state, .draftOnly)
        XCTAssertEqual(F.make(saved: F.config(gguf: ["/m", "/new"]), scanned: scanned).gguf[1].state, .notInLastScan)
        XCTAssertEqual(F.make(saved: saved, scanned: scanned, directories: ["/m": .missing]).gguf[0].state, .missing)
        XCTAssertEqual(F.make(saved: saved, scanned: scanned, directories: ["/m": .notDirectory]).gguf[0].state, .notDirectory)
        XCTAssertEqual(F.make(saved: saved, models: nil, scanned: nil).gguf[0].state, .noSnapshot)
        XCTAssertEqual(F.make(saved: saved, models: [], scanned: nil).gguf[0].state, .noSnapshot, "a snapshot with no recorded roots has no figures")
        XCTAssertEqual(F.make(saved: saved, models: nil, scanned: nil, isScanning: true).gguf[0].state, .scanning)
        XCTAssertEqual(F.make(saved: F.config(gguf: ["/m", "/new"]), scanned: scanned, isScanning: true).gguf[1].state, .scanning)
    }

    func testNotInLastScanOffersRescanAndNeverAZero() {
        let state = SettingsLedgerRow.State.notInLastScan
        XCTAssertTrue(state.offersRescan)
        XCTAssertFalse(state.figures.contains("0"))
        let others: [SettingsLedgerRow.State] = [.none, .draftOnly, .missing, .notDirectory, .noSnapshot, .scanning, .counted(models: 1, bytes: 1)]
        for other in others { XCTAssertFalse(other.offersRescan) }
    }

    func testDraftOnlyCopyMakesNoClaimAboutScanning() {
        XCTAssertEqual(SettingsLedgerRow.State.draftOnly.figures, "Not saved yet")
        XCTAssertFalse(SettingsLedgerRow.State.draftOnly.figures.lowercased().contains("scan"))
    }

    func testOutputRowCountsModelsNotConvertedModelsAndNeverCallsSizesDiskUse() throws {
        let saved = F.config(gguf: ["/m"], output: "/out/mlx")
        let ledger = F.make(
            saved: saved, models: [F.model("/out/mlx/q-4bit", bytes: 4_000_000)], scanned: ScanRoots(gguf: ["/m"], mlx: ["/m", "/out/mlx"])
        )
        let output = try XCTUnwrap(ledger.output)
        XCTAssertTrue(output.state.figures.hasPrefix("1 model · "))
        let footer = SettingsPresentation.footer(snapshot: F.snapshot([]), now: F.stamp)
        for text in [output.state.figures, footer] {
            for banned in ["converted", "disk", "uses"] { XCTAssertFalse(text.lowercased().contains(banned), text) }
        }
        XCTAssertTrue(footer.contains("as of"))
    }

    func testEmptyStatesNameTheirResolution() {
        XCTAssertEqual(SettingsPresentation.emptyGGUF, "Saving uses the detected folders")
        XCTAssertEqual(SettingsPresentation.emptyMLX, "MLX models are found in the GGUF folders and the output directory")
        let empty = F.make(saved: F.config(gguf: []), scanned: ScanRoots(gguf: [], mlx: ["/out/mlx"]))
        XCTAssertTrue(empty.gguf.isEmpty)
        XCTAssertTrue(empty.mlx.isEmpty)
        XCTAssertNil(SettingsPresentation.outsideText(0))
        XCTAssertEqual(SettingsPresentation.outsideText(1), "1 model outside these folders")
        XCTAssertEqual(SettingsPresentation.outsideText(3), "3 models outside these folders")
    }

    func testCountedFiguresCarryTheInkToneNotSuccess() {
        let counted = SettingsLedgerRow.State.counted(models: 2, bytes: 5_000_000)
        XCTAssertEqual(counted.tone, .neutral)
        XCTAssertTrue(counted.isCounted)
        XCTAssertFalse(SettingsLedgerRow.State.none.isCounted)
        for state in [SettingsLedgerRow.State.none, .notInLastScan, .draftOnly, .missing, .notDirectory, .noSnapshot, .scanning, counted] {
            XCTAssertNotEqual(state.tone, .positive, "\(state)")
        }
    }

    func testRenderSnapshotsAreStampedTwoHoursBeforeTheRenderClock() {
        let now = Date()
        let snapshot = F.snapshot([], generatedAt: F.renderStamp(now: now))
        XCTAssertTrue(SettingsPresentation.footer(snapshot: snapshot, now: now).contains("as of 2 hours ago"))
    }

    func testFooterWithoutASnapshotClaimsNoDate() {
        XCTAssertFalse(SettingsPresentation.footer(snapshot: nil, now: F.stamp).contains("as of"))
    }
}

// MARK: - Attribution (AC3)

final class SettingsAttributionTests: XCTestCase {
    private typealias F = SettingsFixtures

    private func counts(_ rows: [SettingsLedgerRow]) -> [Int] {
        rows.map { row in
            if case .counted(let models, _) = row.state { return models }
            return 0
        }
    }

    func testTildeRootMatchesItsExpandedModelPaths() {
        let ledger = F.make(
            saved: F.config(gguf: ["~/models"]), models: [F.model(NSHomeDirectory() + "/models/a.gguf")],
            scanned: ScanRoots(gguf: ["~/models"], mlx: ["~/models"])
        )
        XCTAssertEqual(counts(ledger.gguf), [1])
    }

    func testTrailingSlashAndDotSegmentsNormalize() {
        let ledger = F.make(
            saved: F.config(gguf: ["/a/./b/../models/"]), models: [F.model("/a/models/x.gguf")],
            scanned: ScanRoots(gguf: ["/a/models"], mlx: [])
        )
        XCTAssertEqual(counts(ledger.gguf), [1])
    }

    func testSiblingWithSharedPrefixIsNotInsideTheRoot() {
        let ledger = F.make(
            saved: F.config(gguf: ["/a/models"]), models: [F.model("/a/models-old/y.gguf")],
            scanned: ScanRoots(gguf: ["/a/models"], mlx: [])
        )
        XCTAssertEqual(ledger.gguf[0].state, .none)
        XCTAssertEqual(ledger.outsideModels, 1)
    }

    func testNestedRootsGiveTheModelToTheDeepestRow() {
        let ledger = F.make(
            saved: F.config(gguf: ["/a", "/a/b"]), models: [F.model("/a/b/m.gguf"), F.model("/a/z.gguf")],
            scanned: ScanRoots(gguf: ["/a", "/a/b"], mlx: [])
        )
        XCTAssertEqual(counts(ledger.gguf), [1, 1])
        XCTAssertEqual(ledger.outsideModels, 0)
    }

    func testOutputDirectoryNestedInARootIsNotCountedTwice() {
        let ledger = F.make(
            saved: F.config(gguf: ["/m"], output: "/m/mlx"),
            models: [F.model("/m/q.gguf"), F.model("/m/mlx/o-4bit")],
            scanned: ScanRoots(gguf: ["/m"], mlx: ["/m"])
        )
        XCTAssertEqual(counts(ledger.gguf), [1])
        XCTAssertEqual(ledger.output?.state, .counted(models: 1, bytes: 1_000))
        XCTAssertEqual(ledger.outsideModels, 0)
    }

    func testHuggingFaceSnapshotUnderAGGUFRootCountsWhileMLXRootsAreEmpty() {
        let ledger = F.make(
            saved: F.config(gguf: ["/hf"], mlx: []), models: [F.model("/hf/models--x/snapshots/abc")],
            scanned: ScanRoots(gguf: ["/hf"], mlx: ["/hf", "/out/mlx"])
        )
        XCTAssertEqual(counts(ledger.gguf), [1])
        XCTAssertTrue(ledger.mlx.isEmpty)
    }

    func testModelUnderNoRowIsReportedNotDropped() {
        let ledger = F.make(
            saved: F.config(gguf: ["/m"]), models: [F.model("/m/a.gguf"), F.model("/elsewhere/b.gguf"), F.model("/elsewhere/c.gguf")],
            scanned: ScanRoots(gguf: ["/m"], mlx: ["/m"])
        )
        XCTAssertEqual(ledger.outsideModels, 2)
    }

    func testRootSavedAfterTheSnapshotOwnsNothing() {
        let ledger = F.make(
            saved: F.config(gguf: ["/m", "/other"]), models: [F.model("/m/a.gguf")],
            scanned: ScanRoots(gguf: ["/m"], mlx: ["/m"])
        )
        XCTAssertEqual(ledger.gguf[1].state, .notInLastScan)
        XCTAssertEqual(ledger.gguf[0].state, .counted(models: 1, bytes: 1_000))
    }

    func testRootInsideAScannedRootWasReadByThatScanAndOwnsItsModels() {
        let ledger = F.make(
            saved: F.config(gguf: ["/m", "/m/new"]), models: [F.model("/m/new/n.gguf"), F.model("/m/a.gguf")],
            scanned: ScanRoots(gguf: ["/m"], mlx: ["/m"])
        )
        XCTAssertEqual(ledger.gguf.map(\.state), [.counted(models: 1, bytes: 1_000), .counted(models: 1, bytes: 1_000)])
    }

    func testDraftOnlyRootNeverTakesModelsFromASavedRoot() {
        let ledger = F.make(
            saved: F.config(gguf: ["/m"]), gguf: ["/m", "/m/draft"], models: [F.model("/m/draft/x.gguf")],
            scanned: ScanRoots(gguf: ["/m"], mlx: ["/m"])
        )
        XCTAssertEqual(ledger.gguf[0].state, .counted(models: 1, bytes: 1_000))
        XCTAssertEqual(ledger.gguf[1].state, .draftOnly)
    }

    func testNilSnapshotGivesNoFiguresAndNoOutsideCount() {
        let ledger = F.make(saved: F.config(gguf: ["/m"]), models: nil, scanned: nil)
        XCTAssertEqual(ledger.gguf.map(\.state), [.noSnapshot])
        XCTAssertEqual(ledger.output?.state, .noSnapshot)
        XCTAssertEqual(ledger.outsideModels, 0)
    }

    func testTheSameModelPathIsCountedOnce() {
        let ledger = F.make(
            saved: F.config(gguf: ["/m"]), models: [F.model("/m/a.gguf"), F.model("/m//a.gguf")],
            scanned: ScanRoots(gguf: ["/m"], mlx: ["/m"])
        )
        XCTAssertEqual(counts(ledger.gguf), [1])
    }

    func testARootListedAsGGUFAndMLXShowsTheSameFigures() {
        let ledger = F.make(
            saved: F.config(gguf: ["/m"], mlx: ["/m"]), models: [F.model("/m/a.gguf")],
            scanned: ScanRoots(gguf: ["/m"], mlx: ["/m"])
        )
        XCTAssertEqual(ledger.gguf.map(\.state), ledger.mlx.map(\.state))
        XCTAssertEqual(ledger.gguf[0].state, .counted(models: 1, bytes: 1_000))
    }

    func testPathBoundaryHelpers() {
        XCTAssertTrue(SettingsPath.contains(root: "/", path: "/a"))
        XCTAssertTrue(SettingsPath.contains(root: "/a", path: "/a"))
        XCTAssertFalse(SettingsPath.contains(root: "/a", path: "/ab"))
        XCTAssertFalse(SettingsPath.contains(root: "", path: "/a"))
        XCTAssertEqual(SettingsPath.normalized("/a//b/./c/../d/"), "/a/b/d")
    }
}

// MARK: - Scanned roots (AC2)

@MainActor
final class SettingsScannedRootsTests: XCTestCase {
    private actor Recorder {
        var calls: [(gguf: [String], mlx: [String])] = []
        func record(_ gguf: [String], _ mlx: [String]) { calls.append((gguf, mlx)) }
    }

    private func scan() -> ScanResult {
        ScanResult(
            roots: nil, models: [], outputs: [], pending: [], duplicates: [],
            totals: ScanTotals(gguf: 0, pending: 0, converted: 0, unreadable: 0, bytes: 0, reclaimableBytes: 0)
        )
    }

    private func makeHost(_ config: Config, recorder: Recorder) -> AppHost {
        let result = scan()
        return SettingsFixtures.host(config: config) { gguf, mlx, _, _ in
            await recorder.record(gguf, mlx)
            return result
        }
    }

    func testNothingIsRecordedBeforeTheFirstScan() {
        let host = makeHost(SettingsFixtures.config(gguf: ["/m"]), recorder: Recorder())
        XCTAssertNil(host.scannedRoots)
    }

    func testRecordedRootsAreExactlyTheRootsPassedToTheScan() async {
        let cases: [([String], [String], String)] = [
            (["/m"], [], "/elsewhere/mlx"),
            (["/m"], [], "/m/mlx"),
            (["/m"], ["/x"], "/x/mlx"),
            (["/m"], ["/x"], "/y/mlx"),
        ]
        for (gguf, mlx, output) in cases {
            let recorder = Recorder()
            let host = makeHost(SettingsFixtures.config(gguf: gguf, mlx: mlx, output: output), recorder: recorder)
            await host.rescan()
            let call = await recorder.calls[0]
            XCTAssertEqual(host.scannedRoots, ScanRoots(gguf: call.gguf, mlx: call.mlx), "\(gguf) \(mlx) \(output)")
        }
    }

    func testEmptyMLXRootsFallBackToTheGGUFRootsAndOutputOutsideThemIsAdded() async {
        let host = makeHost(SettingsFixtures.config(gguf: ["/m"], output: "/elsewhere/mlx"), recorder: Recorder())
        await host.rescan()
        XCTAssertEqual(host.scannedRoots, ScanRoots(gguf: ["/m"], mlx: ["/m", "/elsewhere/mlx"]))
    }

    func testOutputInsideARootIsNotAppended() async {
        let host = makeHost(SettingsFixtures.config(gguf: ["/m"], output: "/m/mlx"), recorder: Recorder())
        await host.rescan()
        XCTAssertEqual(host.scannedRoots, ScanRoots(gguf: ["/m"], mlx: ["/m"]))
    }

    func testEmptyGGUFRootsFallBackToTheDetectedFolders() async {
        let recorder = Recorder()
        let host = makeHost(SettingsFixtures.config(gguf: [], output: "/elsewhere/mlx"), recorder: recorder)
        await host.rescan()
        let call = await recorder.calls[0]
        XCTAssertEqual(host.scannedRoots?.gguf, call.gguf)
    }

    func testAFailedScanKeepsTheRootsOfTheLastSnapshot() async {
        let calls = Recorder()
        let result = scan()
        let host = SettingsFixtures.host(config: SettingsFixtures.config(gguf: ["/m"])) { gguf, mlx, _, _ in
            await calls.record(gguf, mlx)
            if await calls.calls.count > 1 { throw CancellationError() }
            return result
        }
        await host.rescan()
        let first = host.scannedRoots
        await host.rescan()
        XCTAssertNotNil(first)
        XCTAssertEqual(host.scannedRoots, first)
    }
}

// MARK: - Probe (AC5)

final class SettingsProbeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testProbeClassifiesExistingMissingFileAndSymlinkedDirectory() throws {
        let directory = root.appendingPathComponent("dir")
        let file = root.appendingPathComponent("file.txt")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let missing = root.appendingPathComponent("missing").path

        let states = SettingsDirectoryProbe.live.states(for: [directory.path, file.path, link.path, missing, "  ", directory.path + "  "])

        XCTAssertEqual(states[directory.path], .exists)
        XCTAssertEqual(states[file.path], .notDirectory)
        XCTAssertEqual(states[link.path], .exists)
        XCTAssertEqual(states[missing], .missing)
        XCTAssertEqual(states.count, 4, "blank paths are skipped and spellings collapse after trimming")
    }

    func testWarningsKeepTheirMeaning() {
        XCTAssertNil(SettingsDirectoryState.exists.warning)
        XCTAssertEqual(SettingsDirectoryState.missing.warning, "Directory does not exist yet.")
        XCTAssertEqual(SettingsDirectoryState.notDirectory.warning, "Path exists but is not a directory.")
    }

    func testInjectedProbeIsUsedInsteadOfTheFileSystem() {
        let probe = SettingsDirectoryProbe { _ in .notDirectory }
        XCTAssertEqual(probe.states(for: ["/anything"]), ["/anything": .notDirectory])
    }

    func testFileSystemAccessLivesOnlyInTheProbe() throws {
        let views = Self.viewsDirectory
        for name in ["SettingsView.swift", "SettingsPresentation.swift"] {
            let text = try String(contentsOf: views.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("FileManager"), "\(name) must not touch FileManager")
            XCTAssertFalse(text.contains("fileExists"), name)
            XCTAssertFalse(text.contains("fileIdentity"), name)
        }
        let probe = try String(contentsOf: views.appendingPathComponent("SettingsDirectoryProbe.swift"), encoding: .utf8)
        XCTAssertTrue(probe.contains("FileManager"))
    }

    static var viewsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/UI/Views", isDirectory: true)
    }
}

// MARK: - Engine row (AC8)

@MainActor
final class SettingsEngineDetectionTests: XCTestCase {
    func testNoMatchRetainsTheDraftAndReportsTheOutcome() async {
        let detection = SettingsEngineDetection(discover: { "" })
        let path = await detection.detect(currentPath: "/chosen/engine")
        XCTAssertEqual(path, "/chosen/engine")
        XCTAssertEqual(detection.state, .notFound(path: "/chosen/engine"))
    }

    func testFoundCheckoutIsOnlyAnUnsavedSelection() async {
        let detection = SettingsEngineDetection(discover: { "/detected/engine" })
        let path = await detection.detect(currentPath: "/chosen/engine")
        XCTAssertEqual(path, "/detected/engine")
        XCTAssertEqual(detection.state, .found(path: "/detected/engine"))
    }

    func testFailureRetainsTheDraftAndReportsTheError() async {
        let detection = SettingsEngineDetection(discover: { throw CocoaError(.fileReadNoPermission) })
        let path = await detection.detect(currentPath: "/chosen/engine")
        XCTAssertEqual(path, "/chosen/engine")
        guard case .failed(let keptPath, let message) = detection.state else { return XCTFail("Expected detection failure") }
        XCTAssertEqual(keptPath, "/chosen/engine")
        XCTAssertFalse(message.isEmpty)
    }

    func testSearchingIsVisibleAndCancelledResultsCannotReplaceTheDraft() async {
        let gate = SettingsDetectionGate()
        let detection = SettingsEngineDetection(discover: { await gate.result() })
        let pending = Task { await detection.detect(currentPath: "/chosen/engine") }
        await gate.waitForStart()
        XCTAssertTrue(detection.isDetecting)
        let duplicate = await detection.detect(currentPath: "/second/engine")
        XCTAssertNil(duplicate)
        XCTAssertTrue(detection.isDetecting)
        detection.cancel()
        await gate.release("/late/engine")
        let result = await pending.value
        XCTAssertNil(result)
        XCTAssertEqual(detection.state, .idle)
    }
}

private actor SettingsDetectionGate {
    private var pending: CheckedContinuation<String, Never>?
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func result() async -> String {
        started = true
        waiter?.resume(); waiter = nil
        return await withCheckedContinuation { pending = $0 }
    }
    func waitForStart() async {
        if !started { await withCheckedContinuation { waiter = $0 } }
    }
    func release(_ value: String) { pending?.resume(returning: value); pending = nil }
}

final class SettingsEngineStatusTests: XCTestCase {
    private func make(_ health: AgentHealth, saved: String = "/agent", draft: String = "/agent") -> SettingsEngineStatus {
        SettingsEngineStatus.make(health: health, savedPath: saved, draftPath: draft)
    }

    func testStatusDescribesTheSavedCheckout() {
        XCTAssertEqual(make(.ready(path: "/agent", cli: "/agent/scripts/mlx-agent")).word, "Found")
        XCTAssertEqual(make(.notFound(path: "/agent", cli: "x")).word, "Not found")
        XCTAssertEqual(make(.notUsable(path: "/agent", cli: "x", reason: "scripts/mlx-agent is not readable.")).detail, "scripts/mlx-agent is not readable.")
        XCTAssertEqual(make(.notConfigured, saved: "", draft: "").word, "Not configured")
    }

    func testDraftThatDiffersFromTheSavedPathIsNeverFound() {
        let healths: [AgentHealth] = [.ready(path: "/agent", cli: "x"), .notFound(path: "/agent", cli: "x"), .notConfigured]
        for health in healths {
            let status = make(health, saved: "/agent", draft: "/other")
            XCTAssertEqual(status.word, "Checked when you save")
            XCTAssertNil(status.detail)
        }
        XCTAssertEqual(make(.ready(path: "/agent", cli: "x"), saved: "/agent", draft: " /agent ").word, "Found")
    }

    func testStatusNeverRepeatsThePath() {
        let status = make(.notFound(path: "/agent/checkout", cli: "x"), saved: "/agent/checkout", draft: "/agent/checkout")
        XCTAssertFalse((status.detail ?? "").contains("/agent/checkout"))
    }
}

// MARK: - Layout

final class SettingsLayoutTests: XCTestCase {
    private func layout(inner: CGFloat, previous: SettingsLayout? = nil) -> SettingsLayout {
        SettingsLayout(viewportWidth: SettingsLayout.viewportWidth(forInnerWidth: inner), previous: previous)
    }

    func testRowFlipsAtThresholdWithHysteresis() {
        XCTAssertTrue(layout(inner: 519).stacksRows)
        XCTAssertFalse(layout(inner: 520).stacksRows)
        let compact = layout(inner: 519)
        XCTAssertTrue(layout(inner: 535, previous: compact).stacksRows)
        XCTAssertFalse(layout(inner: 536, previous: compact).stacksRows)
        let wide = layout(inner: 600)
        XCTAssertTrue(layout(inner: 519, previous: wide).stacksRows)
    }

    func testLedgerFlipsAtThresholdWithHysteresis() {
        XCTAssertTrue(layout(inner: 479).stacksLedgerFigures)
        XCTAssertFalse(layout(inner: 480).stacksLedgerFigures)
        let compact = layout(inner: 479)
        XCTAssertTrue(layout(inner: 495, previous: compact).stacksLedgerFigures)
        XCTAssertFalse(layout(inner: 496, previous: compact).stacksLedgerFigures)
    }

    func testMeasuredViewports() {
        let narrow = SettingsLayout(viewportWidth: 514)
        XCTAssertEqual(narrow.contentWidth, 466)
        XCTAssertEqual(narrow.innerWidth, 434)
        XCTAssertTrue(narrow.stacksRows)
        XCTAssertTrue(narrow.stacksLedgerFigures)
        for viewport: CGFloat in [824, 1220, 4000] {
            let wide = SettingsLayout(viewportWidth: viewport)
            XCTAssertEqual(wide.contentWidth, WorkbenchSize.Settings.contentMaxWidth)
            XCTAssertEqual(wide.innerWidth, 688)
            XCTAssertFalse(wide.stacksRows)
            XCTAssertFalse(wide.stacksLedgerFigures)
        }
        let none = SettingsLayout(viewportWidth: 0)
        XCTAssertEqual(none.contentWidth, 0)
        XCTAssertEqual(none.innerWidth, 0)
    }
}

// MARK: - Routes (AC9)

final class SettingsRouteTests: XCTestCase {
    private let stamp = Date(timeIntervalSinceReferenceDate: 1_000_000_000)

    private func workflow(state: ConversionWorkflowState, completedModelPath: String? = nil) -> ConversionWorkflow {
        ConversionWorkflow(
            id: UUID(), sourcePath: "/models/source.gguf", sourceModelKey: nil, sourceSignature: nil,
            outputPath: "/models/out", previewHash: nil, jobReceipt: nil, completedModelPath: completedModelPath,
            state: state, serveState: .idle, message: nil, errorMessage: nil, createdAt: stamp, updatedAt: stamp,
            lastKnownAgentState: nil
        )
    }

    private func derive(
        workflow: ConversionWorkflow, snapshot: LibrarySnapshot?, rootsConfigured: Bool = true, agentReady: Bool = true,
        convertRuntimeReady: Bool = true, serveRuntimeReady: Bool = true
    ) -> HomeNextAction {
        HomeNextAction.derive(
            workflow: workflow, snapshot: snapshot, rootsConfigured: rootsConfigured, isScanning: false, lastError: nil,
            agentReady: agentReady, convertRuntimeReady: convertRuntimeReady, serveRuntimeReady: serveRuntimeReady
        )
    }

    func testPrepareRuntimeRepairRoutesToHealth() {
        let source = SettingsFixtures.model("/models/source.gguf")
        let needsConversion = LibraryModel(item: source.item, readiness: .needsConversion)
        let action = derive(workflow: workflow(state: .idle), snapshot: SettingsFixtures.snapshot([needsConversion]), convertRuntimeReady: false)
        XCTAssertEqual(action.title, "Repair the Prepare runtime")
        XCTAssertEqual(action.route, AppRoute.health.rawValue)
        XCTAssertEqual(action.buttonTitle, "Open Health")
    }

    func testRunRuntimeRepairRoutesToHealth() {
        let model = SettingsFixtures.model("/models/atlas-mlx")
        let action = derive(
            workflow: workflow(state: .completed, completedModelPath: model.item.path),
            snapshot: SettingsFixtures.snapshot([model]), serveRuntimeReady: false
        )
        XCTAssertEqual(action.title, "Repair the Run runtime")
        XCTAssertEqual(action.route, AppRoute.health.rawValue)
        XCTAssertEqual(action.buttonTitle, "Open Health")
    }

    func testRootsAndAgentConfigurationStayOnSettings() {
        let idle = workflow(state: .idle)
        for action in [derive(workflow: idle, snapshot: nil, rootsConfigured: false), derive(workflow: idle, snapshot: nil, agentReady: false)] {
            XCTAssertEqual(action.route, AppRoute.settings.rawValue)
            XCTAssertEqual(action.buttonTitle, "Open Settings")
        }
    }

    func testRunViewSendsRuntimeRepairToHealth() throws {
        let url = SettingsProbeTests.viewsDirectory.appendingPathComponent("ServeView.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(#"Button("Open Health") { onRouteSelection(.health) }"#))
        XCTAssertFalse(text.contains("Open Settings after installing"))
    }

    func testSettingsOffersHealthOnlyWhileTheRuntimeNeedsSetup() throws {
        let text = try String(contentsOf: SettingsProbeTests.viewsDirectory.appendingPathComponent("SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("if !appHost.runtimeReport.ok {"))
        XCTAssertTrue(text.contains(#"Button("Open Health") { onRouteSelection(.health) }"#))
        XCTAssertFalse(text.contains("RuntimeInstallView"))
    }
}

// MARK: - Save validation

final class SettingsInputValidationTests: XCTestCase {
    @MainActor
    func testSettingsRenderingAndPersistencePreserveUnexposedConnectionValues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json"), module = ConfigModule(pathOverride: root.appendingPathComponent("config.json").path)
        var config = SettingsFixtures.config(gguf: [root.appendingPathComponent("models").path])
        config.host = "::1"; config.port = 54321; config.watchEnabled = false
        _ = try module.save(config)
        var original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        original["future_feature"] = "preserve-me"
        try JSONSerialization.data(withJSONObject: original).write(to: url, options: .atomic)
        let host = AppHost(configModule: module, config: config, configPath: url.path,
            runtimeReport: SettingsFixtures.runtimeReport(ok: true),
            modelWorkflowAPI: SettingsFixtures.idleWorkflowAPI(), modelWorkflowPersistence: SettingsFixtures.idleWorkflowPersistence())
        let view = NSHostingView(rootView: SettingsView(appHost: host, onRouteSelection: { _ in })
            .environment(\.isRouteActive, true).frame(width: 1000, height: 2200)
            .background(WorkbenchColor.canvas).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 2200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        try await Task.sleep(for: .milliseconds(250)); view.layoutSubtreeIfNeeded()
        let fields = descendants(view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertFalse(fields.contains { $0.stringValue == "::1" }, "Legacy API host must not be an editable Settings field.")
        XCTAssertFalse(fields.contains { $0.stringValue == "54321" }, "Legacy API port must not be an editable Settings field.")
        original["host"] = "localhost"
        original["port"] = 54322
        try JSONSerialization.data(withJSONObject: original).write(to: url, options: .atomic)
        // The VM UI suite exercises Save; this checks its persistence boundary separately from rendering.
        var edited = host.config
        edited.qBits = 8
        let accepted = await host.saveSettingsConfig(edited)
        XCTAssertTrue(accepted)
        XCTAssertEqual(host.config.qBits, 8)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(saved["q_bits"] as? Int, 8)
        XCTAssertEqual(saved["host"] as? String, "localhost")
        XCTAssertEqual(saved["port"] as? Int, 54322)
        XCTAssertEqual(host.config.host, "localhost")
        XCTAssertEqual(host.config.port, 54322)
        XCTAssertEqual(saved["future_feature"] as? String, "preserve-me")
    }

    func testFirstInvalidFieldFollowsScreenOrderAndAdvancesAfterCorrection() {
        var validation = SettingsInputValidation(fitReserve: "17",
            staleDays: "1", comparisonTokens: "63")
        let fields: [SettingsInputValidation.Field] = [.fitReserve, .staleDays, .comparisonTokens]
        XCTAssertEqual(SettingsInputValidation.Field.allCases, fields)
        let corrections: [(WritableKeyPath<SettingsInputValidation, String>, String)] = [
            (\.fitReserve, "4"),
            (\.staleDays, "60"), (\.comparisonTokens, "512"),
        ]
        for (index, correction) in corrections.enumerated() {
            let invalid = validation.firstInvalid
            XCTAssertEqual(invalid?.field, fields[index])
            XCTAssertEqual(invalid?.guidance, fields[index].label + ": " + (invalid?.instruction ?? ""))
            validation[keyPath: correction.0] = correction.1
        }
        XCTAssertNil(validation.firstInvalid)
    }

    func testEachFieldNamesItsExistingValidationInstruction() {
        let cases: [(SettingsInputValidation.Field, WritableKeyPath<SettingsInputValidation, String>, String)] = [
            (.fitReserve, \.fitReserve, "Enter a number between 0 and 16."),
            (.staleDays, \.staleDays, "Enter an integer between 2 and 365."),
            (.comparisonTokens, \.comparisonTokens, "Enter an integer between 64 and 4096."),
        ]
        for (field, key, instruction) in cases {
            var validation = SettingsInputValidation()
            validation[keyPath: key] = "invalid"
            XCTAssertEqual(validation.firstInvalid, .init(field: field, instruction: instruction))
            XCTAssertEqual(validation.firstInvalid?.guidance, field.label + ": " + instruction)
        }
    }

    func testNumericBoundsAndWhitespaceRemainAccepted() {
        let cases: [(WritableKeyPath<SettingsInputValidation, String>, [String])] = [
            (\.fitReserve, ["0", "16", " 4.5\n"]),
            (\.staleDays, ["2", "365", " 60\n"]),
            (\.comparisonTokens, ["64", "4096", " 512\n"]),
        ]
        for (key, values) in cases {
            for value in values {
                var validation = SettingsInputValidation()
                validation[keyPath: key] = value
                XCTAssertNil(validation.firstInvalid, value)
                XCTAssertEqual(validation[keyPath: key], value)
            }
        }
    }

    func testNumericOutOfRangeMalformedAndNonfiniteInputsRemainRejected() {
        let cases: [(SettingsInputValidation.Field, WritableKeyPath<SettingsInputValidation, String>, [String])] = [
            (.fitReserve, \.fitReserve, ["", "abc", "-0.1", "16.1", "nan", "inf", "-inf"]),
            (.staleDays, \.staleDays, ["", "abc", "1", "366", "2.5", "999999999999999999999999999"]),
            (.comparisonTokens, \.comparisonTokens, ["", "abc", "63", "4097", "64.5", "999999999999999999999999999"]),
        ]
        for (field, key, values) in cases {
            for value in values {
                var validation = SettingsInputValidation()
                validation[keyPath: key] = value
                XCTAssertEqual(validation.firstInvalid?.field, field, value)
                XCTAssertEqual(validation[keyPath: key], value)
            }
        }
    }
}

// MARK: - Source contract (AC6, AC7, AC11)

final class SettingsSourceContractTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        try String(contentsOf: SettingsProbeTests.viewsDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    func testEveryLabelledFieldAppearsInTheUITestsDocumentOrder() throws {
        let text = try source("SettingsView.swift")
        let labels = ["mlx-agent checkout", "Output directory", "Quarantine directory",
                      "Fit reserve in gigabytes", "Stale after days", "Comparison maximum tokens"]
        let indices = try labels.map { label in try XCTUnwrap(text.range(of: "\"\(label)\"")?.lowerBound, label) }
        XCTAssertEqual(indices, indices.sorted())
        let sections = ["engineSection", "locationsSection", "storageSection", "servingSection",
                        "conversionSection", "advisorsSection", "updatesSection"]
        let body = try XCTUnwrap(text.range(of: "var body: some View"))
        let bodyOrder = try sections.map {
            let pattern = #"(?m)^\s+"# + NSRegularExpression.escapedPattern(for: $0) + #"\s*$"#
            return try XCTUnwrap(text.range(of: pattern, options: .regularExpression,
                range: body.lowerBound..<text.endIndex)?.lowerBound, $0)
        }
        XCTAssertEqual(bodyOrder, bodyOrder.sorted())
        let definitionOrder = try sections.map { try XCTUnwrap(text.range(of: "private var \($0): some View")?.lowerBound, $0) }
        XCTAssertEqual(definitionOrder, definitionOrder.sorted())
    }

    func testEngineStatusAndAgentFieldAreInTheFirstSection() throws {
        let text = try source("SettingsView.swift")
        let engine = try XCTUnwrap(text.range(of: "private var engineSection"))
        let locations = try XCTUnwrap(text.range(of: "private var locationsSection"))
        let section = text[engine.lowerBound..<locations.lowerBound]
        XCTAssertTrue(section.contains(#"label: "Engine status""#))
        XCTAssertTrue(section.contains(#"label: "mlx-agent checkout""#))
    }

    func testNoNestedScrollContainersOrFormControls() throws {
        let text = try source("SettingsView.swift")
        XCTAssertEqual(text.components(separatedBy: "ScrollView {").count - 1, 2, "the page and the update log")
        let containers = text.replacingOccurrences(of: "ScrollViewReader", with: "")
            .replacingOccurrences(of: "ScrollViewProxy", with: "")
        XCTAssertEqual(containers.components(separatedBy: "ScrollView").count - 1, 2)
        for banned in ["Form {", "List(", "List {", "Table(", "TextEditor", ".animation("] {
            XCTAssertFalse(text.contains(banned), banned)
        }
        let log = try XCTUnwrap(text.range(of: "if !updater.logTail.isEmpty {"))
        XCTAssertTrue(text[log.lowerBound...].contains("DisclosureGroup(\"Update log\")"))
    }

    func testRouteSelectionComesFromTheShellAndNeverFromDefaults() throws {
        let view = try source("SettingsView.swift")
        for banned in ["UserDefaults", "selectionStorageKey", "selectRoute"] {
            XCTAssertFalse(view.contains(banned), banned)
        }
        XCTAssertTrue(view.contains("onRouteSelection: @escaping (AppRoute) -> Void\n    ) {"))
        let shell = try String(
            contentsOf: SettingsProbeTests.viewsDirectory.deletingLastPathComponent().appendingPathComponent("ContentView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(shell.contains("SettingsView(appHost: appHost, onRouteSelection: navigate)"))
    }

    func testBooleansAreSwitchRowsInTheLabelControlGrid() throws {
        let text = try source("SettingsView.swift")
        let row = try XCTUnwrap(text.range(of: "struct SettingsToggleRow"))
        let end = try XCTUnwrap(text.range(of: "struct SettingsStatusLabel"))
        let body = text[row.lowerBound..<end.lowerBound]
        XCTAssertTrue(body.contains("SettingsRow(label: title, stacked: stacked)"))
        XCTAssertTrue(body.contains("Toggle(title, isOn: $isOn)"))
        XCTAssertTrue(body.contains(".toggleStyle(.switch)"))
        XCTAssertTrue(body.contains(".labelsHidden()"))
        for title in ["Sign converted outputs", "Verify conversions (canary quality gate)", "Watch & regression alerts"] {
            XCTAssertTrue(text.contains("title: \"\(title)\""), title)
        }
        XCTAssertEqual(text.components(separatedBy: "Toggle(").count - 1, 1)
    }

    func testStatusColourIsNotUsedAsDecorationOnFiguresOrRemoveButtons() throws {
        let text = try source("SettingsView.swift")
        let figures = try XCTUnwrap(text.range(of: "struct SettingsFigureText"))
        let ledger = try XCTUnwrap(text.range(of: "struct SettingsLedgerRowView"))
        let figureBody = text[figures.lowerBound..<ledger.lowerBound]
        XCTAssertTrue(figureBody.contains("state.isCounted ? WorkbenchTypography.tabular"))
        XCTAssertTrue(figureBody.contains("state.isCounted ? WorkbenchColor.ink"))
        let remove = try XCTUnwrap(text.range(of: "Image(systemName: \"minus.circle.fill\")"))
        XCTAssertTrue(text[remove.lowerBound...].prefix(120).contains("WorkbenchColor.muted"))
        XCTAssertTrue(text.contains(".frame(width: WorkbenchSize.Settings.bitsPickerWidth, alignment: .leading)"))
    }

    func testSurvivingStringsAndControls() throws {
        let text = try source("SettingsView.swift") + (try source("SettingsPresentation.swift"))
        let survivors = [
            "Engine status", "Detect", "Choose…", "Add Folder…", "Add Detected", "Remove \\(row.path)",
            "Check for updates", "Update to \\(offer.target)", "Relaunch", "Rebuild & relaunch", "Update log",
            "uncommitted change(s) in the checkout — commit or discard them before updating.",
            "This app is not running from a repository checkout, so in-app updates are unavailable. Install updates by replacing the app with a newly built one.",
            "Default bits", "4-bit", "8-bit", "Sign converted outputs", "Verify conversions (canary quality gate)",
            "Watch & regression alerts", "Unsaved changes", "All changes saved", "Saved to \\(appHost.configPath)",
            "Settings could not be saved.", "Discard", "Save", ".keyboardShortcut(.defaultAction)",
            "Enter a number between 0 and 16.", "Enter an integer between 2 and 365.", "Enter an integer between 64 and 4096.",
            "Directory does not exist yet.", "Path exists but is not a directory.",
            "Serving", "Open Run", "Fit reserve in gigabytes", "Stale after days",
            "Comparison maximum tokens", "Output directory", "Quarantine directory", "mlx-agent checkout",
            "Channel", "Open Health", "Rescan",
        ]
        for survivor in survivors { XCTAssertTrue(text.contains(survivor), survivor) }
        XCTAssertFalse(text.contains("No directories added."))
        XCTAssertFalse(text.contains("Scanned after you save"))
    }

    func testPromptsCarryThePlaceholders() throws {
        let text = try source("SettingsView.swift")
        XCTAssertFalse(text.contains("TextField(placeholder"))
        XCTAssertEqual(text.components(separatedBy: "prompt: Text(").count - 1, 2)
    }

    func testFigureMotionIsGatedAndKeyedOnTheSnapshot() throws {
        let text = try source("SettingsView.swift")
        XCTAssertTrue(text.contains(".contentTransition(isRouteActive ? .numericText() : .identity)"))
        XCTAssertTrue(text.contains(".workbenchAnimation(value: stamp)"))
        XCTAssertTrue(text.contains("stamp: appHost.librarySnapshot?.generatedAt"))
    }

    func testSaveDoesNotRescan() throws {
        let text = try source("SettingsView.swift")
        let save = try XCTUnwrap(text.range(of: "private func save()"))
        let folder = try XCTUnwrap(text.range(of: "// MARK: - Folder picker"))
        XCTAssertFalse(text[save.lowerBound..<folder.lowerBound].contains("Rescan"))
        XCTAssertFalse(text[save.lowerBound..<folder.lowerBound].contains("requestRescan"))
    }

    func testDiscoveryAndPanelsAreOnlyInActions() throws {
        let text = try source("SettingsView.swift")
        XCTAssertFalse(text.contains("Config.discoverAgentPath()"))
        XCTAssertTrue(text.contains("detect: detectEngine"))
        XCTAssertTrue(text.contains("await engineDetection.detect(currentPath: original)"))
        XCTAssertEqual(text.components(separatedBy: "Config.discoverGgufRoots()").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: "NSOpenPanel()").count - 1, 2)
    }
}

// MARK: - Renders

@MainActor
final class SettingsRenderTests: XCTestCase {
    private typealias F = SettingsFixtures

    private struct Scenario {
        var name: String
        var config: Config
        var models: [LibraryModel]? = []
        var scanned: ScanRoots?
        var scanning = false
        var agent: AgentHealth = .ready(path: "/agent", cli: "/agent/scripts/mlx-agent")
        var runtimeOk = true
        var probe: @Sendable (String) -> SettingsDirectoryState = { _ in .exists }
    }

    private func scenarios() -> [Scenario] {
        let home = NSHomeDirectory()
        let counted = F.config(gguf: ["\(home)/.cache/huggingface/hub", "\(home)/.models"], output: "\(home)/.models/mlx")
        let models = [
            F.model("\(home)/.cache/huggingface/hub/models--a/snapshots/1", bytes: 310_000_000_000),
            F.model("\(home)/.models/b.gguf", bytes: 4_200_000_000),
            F.model("\(home)/.models/mlx/c-4bit", bytes: 2_100_000_000),
            F.model("/elsewhere/d.gguf", bytes: 1_000_000_000),
        ]
        let scanned = ScanRoots(gguf: counted.ggufRoots, mlx: counted.ggufRoots)
        return [
            Scenario(name: "counted-nested-output", config: counted, models: models, scanned: scanned),
            Scenario(name: "none", config: counted, models: [], scanned: scanned),
            Scenario(name: "saved-not-scanned", config: counted, models: models, scanned: ScanRoots(gguf: ["\(home)/.models"], mlx: ["\(home)/.models"])),
            Scenario(name: "missing", config: counted, models: models, scanned: scanned, probe: { $0.hasSuffix(".models") ? .missing : .exists }),
            Scenario(name: "not-a-directory", config: counted, models: models, scanned: scanned, probe: { $0.hasSuffix(".models") ? .notDirectory : .exists }),
            Scenario(name: "no-snapshot", config: counted, models: nil, scanned: nil),
            Scenario(name: "scanning", config: counted, models: nil, scanned: nil, scanning: true),
            Scenario(name: "empty-gguf", config: F.config(gguf: []), models: [], scanned: nil),
            Scenario(name: "agent-not-found", config: counted, models: models, scanned: scanned, agent: .notFound(path: "/agent", cli: "x")),
            Scenario(name: "agent-not-usable", config: counted, models: models, scanned: scanned, agent: .notUsable(path: "/agent", cli: "x", reason: "scripts/mlx-agent is not readable.")),
            Scenario(name: "agent-not-configured", config: F.config(gguf: ["/m"], agent: ""), models: models, scanned: scanned, agent: .notConfigured),
            Scenario(name: "runtime-not-ok", config: counted, models: models, scanned: scanned, runtimeOk: false),
        ]
    }

    private func makeHost(_ scenario: Scenario, updater: UpdateCoordinator? = nil) -> AppHost {
        let now = Date()
        let host = AppHost(
            config: scenario.config, discoveredRoots: ["/detected/models"], configPath: "/state/mlx-workbench/config.json",
            agentHealth: scenario.agent, runtimeReport: F.runtimeReport(ok: scenario.runtimeOk), hardwareProfile: HardwareProfile.current(),
            now: { now }, updater: updater
        )
        host.librarySnapshot = scenario.models.map { F.snapshot($0, generatedAt: F.renderStamp(now: now)) }
        host.scannedRoots = scenario.scanned
        host.isScanning = scenario.scanning
        return host
    }

    private func attach<Content: View>(_ view: Content, name: String, viewport: CGFloat, dark: Bool, height: CGFloat = 1400) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: viewport, height: height).background(WorkbenchColor.canvas).preferredColorScheme(dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: viewport, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)
        hosting.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "\(name)-\(dark ? "dark" : "light")-\(Int(viewport))"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var draftGallery: some View {
        let saved = F.config(gguf: ["/m"])
        let ledger = F.make(saved: saved, gguf: ["/m", "/draft"], models: [F.model("/m/a.gguf")], scanned: ScanRoots(gguf: ["/m"], mlx: ["/m"]))
        return VStack(alignment: .leading, spacing: WorkbenchSpacing.md) {
            ForEach(Array(ledger.gguf.enumerated()), id: \.offset) { _, row in
                SettingsLedgerRowView(row: row, stacksFigures: false, isRouteActive: true, stamp: F.stamp, isScanning: false, onRescan: {}, onRemove: {})
            }
            SettingsStatusLabel(word: "Checked when you save", detail: nil, symbol: "questionmark.circle", tone: .neutral)
            SettingsRow(label: "Fit reserve", message: "Enter a number between 0 and 16.", stacked: false) {
                TextField("Fit reserve in gigabytes", text: .constant("17"), prompt: Text("4")).textFieldStyle(.roundedBorder)
            }
            SettingsRow(label: "Output directory", warning: SettingsDirectoryState.missing.warning, stacked: false) {
                TextField("Output directory", text: .constant("~/models/mlx"), prompt: Text("~/models/mlx")).textFieldStyle(.roundedBorder)
            }
        }
        .padding(WorkbenchSpacing.pageInset)
    }

    private final class RenderInstaller: ReleaseInstalling, @unchecked Sendable {
        func fetchRelease(_ url: URL) async throws -> ReleaseEntry {
            let name = "mlx-workbench-0.5.0.dmg"
            let asset = ReleaseAsset(
                name: name, downloadURL: URL(string: "https://example.invalid/\(name)")!,
                size: 1, digest: "sha256:" + String(repeating: "a", count: 64)
            )
            return ReleaseEntry(tagName: "v0.5.0", draft: false, prerelease: false, assets: [asset])
        }

        func install(_ offer: ReleaseOffer, replacing bundle: URL, log: @escaping @Sendable (String) -> Void) async throws -> InstalledBuild {
            InstalledBuild(version: "0.5.0", commit: "", channel: "release")
        }

        func relaunch(_ bundle: URL) {}
    }

    private func updateDefaults() throws -> UserDefaults {
        let suite = "mlx-workbench-settings-render-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// Drives UpdateCoordinator through its injected git runner or installer to each rendered phase.
    private func updatePhases() async throws -> [(name: String, updater: UpdateCoordinator)] {
        let checkout = URL(fileURLWithPath: "/render/checkout", isDirectory: true)
        func git(status: String, failFetch: Bool = false) -> @Sendable ([String]) throws -> String {
            { argv in
                if argv.contains("status") { return status }
                if argv.contains("describe") { throw UpdateCoordinator.UpdateError.gitFailed("describe", "no tag") }
                if argv.contains("fetch") && failFetch { throw UpdateCoordinator.UpdateError.gitFailed("fetch","Could not resolve host: github.com") }
                if argv.contains("tag") { return "v0.5.0\nv0.4.0\n" }
                if argv.contains("rev-parse") { return "a0c36da\n" }
                return ""
            }
        }
        let dirty = UpdateCoordinator(repoRoot: checkout, defaults: try updateDefaults(), runGit: git(status: " M a.swift\n M b.swift\n"))
        await dirty.check()
        let failed = UpdateCoordinator(repoRoot: checkout, defaults: try updateDefaults(), runGit: git(status: "", failFetch: true))
        await failed.check()

        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-render-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("MLX Workbench.app")
        try FileManager.default.createDirectory(at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let updated = UpdateCoordinator(
            repoRoot: nil,
            installed: .init(bundle: bundle, build: InstalledBuild(version: "0.4.0", commit: "", channel: "release"), installer: RenderInstaller()),
            defaults: try updateDefaults(), runGit: { _ in "" }
        )
        await updated.check()
        guard case .available(let offer) = updated.phase else { throw XCTSkip("release offer not reached: \(updated.phase)") }
        await updated.apply(offer: offer)

        XCTAssertEqual(dirty.phase, .available(.init(target: "v0.5.0", current: "a0c36da", dirtyFiles: 2)))
        XCTAssertEqual(updated.phase, .updated(target: "v0.5.0"))
        guard case .failed = failed.phase else { throw XCTSkip("failed phase not reached: \(failed.phase)") }
        return [("update-available-dirty", dirty), ("update-updated", updated), ("update-failed", failed)]
    }

    func testEveryUpdatePhaseRendersDarkAndLight() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let scenario = try XCTUnwrap(scenarios().first)
        for phase in try await updatePhases() {
            for dark in [true, false] {
                for viewport in [CGFloat(1220), 514] {
                    let host = makeHost(scenario, updater: phase.updater)
                    try await attach(
                        SettingsView(appHost: host, probe: SettingsDirectoryProbe(state: scenario.probe), onRouteSelection: { _ in })
                            .environment(\.isRouteActive, true),
                        name: phase.name, viewport: viewport, dark: dark, height: 2000
                    )
                }
            }
        }
    }

    func testEveryStateRendersDarkAndLightAtEveryWidth() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let widths: [(label: CGFloat, viewport: CGFloat)] = [(1556, 1220), (1050, 824), (740, 514)]
        for scenario in scenarios() {
            for dark in [true, false] {
                for width in widths {
                    let host = makeHost(scenario)
                    let probe = SettingsDirectoryProbe(state: scenario.probe)
                    try await attach(
                        SettingsView(appHost: host, probe: probe, onRouteSelection: { _ in }).environment(\.isRouteActive, true),
                        name: scenario.name, viewport: width.viewport, dark: dark
                    )
                }
            }
        }
        for dark in [true, false] {
            for width in widths {
                try await attach(draftGallery, name: "draft-states", viewport: width.viewport, dark: dark, height: 600)
            }
        }
    }
}
