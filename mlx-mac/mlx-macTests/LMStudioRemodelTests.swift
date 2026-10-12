import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

// MARK: - Fixtures

private enum LMFixtures {
    static let totalBytes: Int64 = 137_438_953_472
    static let hardware = HardwareProfile(chip: "Apple M4 Max", model: nil, memoryBytes: totalBytes, macOSVersion: nil)
    static let reserveGB = 4.0
    static let context = FitAdvisor.defaultContextTokens
    static let root = "/lm"

    /// A live reading with 100 GB available: a 96 GB budget after the 4 GB reserve.
    static func memory(available: Int64 = 100_000_000_000) -> MemorySnapshot {
        MemorySnapshot(totalBytes: totalBytes, availableBytes: available)
    }

    static func task(_ type: ModelTaskType) -> ModelTask {
        ModelTask(type: type, useCases: [], source: "registry", confidence: "confirmed")
    }

    static func gguf(
        _ path: String, bytes: Int64 = 4_000_000_000, quant: String? = "Q4_K_M", status: String = "pending",
        companion: Bool? = false, readable: Bool? = true, outputs: [String] = [], key: String? = "model-a",
        readiness: ModelReadiness? = nil
    ) -> LibraryModel {
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: bytes, modifiedAt: nil, shard: nil,
            modelKey: key, architecture: nil, quantization: quant, parameters: nil, structure: nil, signature: nil,
            companion: companion, readable: readable, status: status, outputs: outputs, tensorCount: nil, error: nil
        )
        return LibraryModel(item: item, readiness: readiness)
    }

    static func mlx(_ path: String, bytes: Int64 = 4_000_000_000, quant: String? = "q8", task: ModelTaskType? = nil) -> LibraryModel {
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: bytes, modifiedAt: nil, shard: nil,
            modelKey: "mlx", architecture: nil, quantization: quant, parameters: nil, structure: nil, signature: nil,
            companion: nil, readable: true, status: "ready", outputs: [path], tensorCount: nil, error: nil,
            task: task.map(Self.task)
        )
        return LibraryModel(item: item, readiness: .ready, sourcePaths: [path], outputPaths: [path])
    }

    static func snapshot(_ models: [LibraryModel]) -> LibrarySnapshot {
        LibrarySnapshot(models: models, groups: [], hardware: hardware, generatedAt: Date(timeIntervalSinceReferenceDate: 1_000_000_000))
    }

    static func folder(
        _ path: String = root, source: LMStudioShelfResolver.Source = .settings, isPresent: Bool = true,
        gguf: LMStudioShelfResolver.Coverage? = nil, mlx: LMStudioShelfResolver.Coverage? = nil
    ) -> LMStudioShelfResolver.Folder {
        let scanned = LMStudioShelfResolver.Coverage.scanned(root: path, folder: path)
        return LMStudioShelfResolver.Folder(url: URL(fileURLWithPath: path), source: source, isPresent: isPresent, gguf: gguf ?? scanned, mlx: mlx ?? scanned)
    }

    static func resolution(_ folders: [LMStudioShelfResolver.Folder] = [folder()], installed: Bool = true) -> LMStudioShelfResolver.Resolution {
        LMStudioShelfResolver.Resolution(installed: installed, folders: folders)
    }

    static func present(
        resolution: LMStudioShelfResolver.Resolution? = resolution(), snapshot: LibrarySnapshot? = snapshot([]),
        isScanning: Bool = false, lastError: String? = nil, memory: MemorySnapshot? = memory(), hasProbed: Bool = true
    ) -> LMStudioShelfPresentation {
        LMStudioShelfPresentation.make(
            resolution: resolution, snapshot: snapshot, isScanning: isScanning, lastError: lastError, memory: memory,
            hasProbed: hasProbed, contextTokens: context, reserveGB: reserveGB, hardware: hardware
        )
    }

    static func lanes(_ presentation: LMStudioShelfPresentation) -> [LMStudioLane] {
        if case .lanes(let lanes) = presentation.state { return lanes }
        return []
    }

    static func rows(_ presentation: LMStudioShelfPresentation, _ format: LMStudioRow.Format) -> [LMStudioRow] {
        lanes(presentation).first { $0.format == format }?.rows ?? []
    }
}

private typealias F = LMFixtures

// MARK: - Resolver

final class LMStudioResolverTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/user")

    private func parse(_ json: String, home: URL? = nil) -> URL? {
        LMStudioShelfResolver.parseDownloadsFolder(settingsJSON: Data(json.utf8), home: home ?? self.home)
    }

    func testTheDownloadsFolderIsReadFromTheTopLevelString() {
        XCTAssertEqual(parse(#"{"downloadsFolder": "/models/lms"}"#)?.path, "/models/lms")
        XCTAssertEqual(parse(#"{"downloadsFolder": "~/models/lms"}"#)?.path, "/home/user/models/lms")
        XCTAssertEqual(parse(#"{"downloadsFolder": "~"}"#)?.path, "/home/user")
        XCTAssertEqual(parse(#"{"downloadsFolder": "/models/a/../lms"}"#)?.path, "/models/lms")
    }

    func testAnAbsentEmptyNonStringOrInvalidSettingYieldsNothing() {
        XCTAssertNil(parse(#"{"other": 1}"#))
        XCTAssertNil(parse(#"{"downloadsFolder": ""}"#))
        XCTAssertNil(parse(#"{"downloadsFolder": "   "}"#))
        XCTAssertNil(parse(#"{"downloadsFolder": 7}"#))
        XCTAssertNil(parse(#"{"downloadsFolder": ["/a"]}"#))
        XCTAssertNil(parse(#"{"downloadsFolder": "relative/path"}"#))
        XCTAssertNil(parse(#"{"nested": {"downloadsFolder": "/a"}}"#))
        XCTAssertNil(parse("not json"))
        XCTAssertNil(parse("[]"))
    }

    func testSettingsOverOneMegabyteAreIgnored() {
        let padding = String(repeating: "x", count: LMStudioShelfResolver.settingsByteLimit)
        XCTAssertNil(parse(#"{"downloadsFolder": "/models/lms", "pad": ""# + padding + #""}"#))
    }

    func testTheSkipSetEqualsTheVendoredAgents() throws {
        let gguf = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/mlx-agent/providers/codex/src/mlx_agent/gguf.py")
        let source = try String(contentsOf: gguf, encoding: .utf8)
        let block = try XCTUnwrap(source.range(of: #"(?s)_SKIP_DIRECTORIES = \{(.*?)\}"#, options: .regularExpression))
        let text = String(source[block])
        let names = try NSRegularExpression(pattern: #""([^"]+)""#)
        let parsed = names.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
        XCTAssertEqual(LMStudioShelfResolver.agentSkippedNames, Set(parsed))
        XCTAssertTrue(source.contains(#"if name not in _SKIP_DIRECTORIES and not name.startswith(".")"#))
    }

    // MARK: Coverage

    private func coverage(
        _ folder: String, scanned: [String]?, configured: [String] = []
    ) -> LMStudioShelfResolver.Coverage {
        LMStudioShelfResolver.coverage(
            of: URL(fileURLWithPath: folder), scannedRoots: scanned, configuredRoots: configured, fileIdentity: { _ in nil }
        )
    }

    func testAFolderInsideAScannedRootIsScannedAndKeepsTheRootsSpelling() {
        XCTAssertEqual(coverage("/m/lms", scanned: ["/m"]), .scanned(root: "/m", folder: "/m/lms"))
        XCTAssertEqual(coverage("/m", scanned: ["/m"]), .scanned(root: "/m", folder: "/m"))
        XCTAssertEqual(coverage("/m/a/b", scanned: ["/x", "/m/"]), .scanned(root: "/m", folder: "/m/a/b"))
    }

    func testAHiddenOrSkippedComponentBelowTheRootIsNotScanned() {
        XCTAssertEqual(coverage("/m/.lmstudio/models", scanned: ["/m"], configured: ["/m"]), .notConfigured)
        for name in LMStudioShelfResolver.agentSkippedNames {
            XCTAssertEqual(coverage("/m/\(name)/models", scanned: ["/m"], configured: ["/m"]), .notConfigured, name)
        }
        XCTAssertEqual(coverage("/m/node_modules_extra/models", scanned: ["/m"]), .scanned(root: "/m", folder: "/m/node_modules_extra/models"))
        XCTAssertEqual(coverage("/m/.lmstudio/models", scanned: ["/m/.lmstudio"]), .scanned(root: "/m/.lmstudio", folder: "/m/.lmstudio/models"))
    }

    func testConfiguredButNotYetScannedAndNotConfigured() {
        XCTAssertEqual(coverage("/m/lms", scanned: ["/other"], configured: ["/m"]), .configuredNotScanned)
        XCTAssertEqual(coverage("/m/lms", scanned: ["/other"], configured: ["/else"]), .notConfigured)
        XCTAssertEqual(coverage("/m/lms", scanned: [], configured: []), .notConfigured)
    }

    func testNoScannedRootsMeansUnknown() {
        XCTAssertEqual(coverage("/m/lms", scanned: nil, configured: ["/m"]), .unknown)
    }

    func testGGUFAndMLXRootsDifferPerFormat() {
        let folder = URL(fileURLWithPath: "/m/lms")
        let roots = ScanRoots(gguf: ["/m"], mlx: ["/elsewhere"])
        XCTAssertEqual(
            LMStudioShelfResolver.coverage(of: folder, scannedRoots: roots.gguf, configuredRoots: [], fileIdentity: { _ in nil }),
            .scanned(root: "/m", folder: "/m/lms")
        )
        XCTAssertEqual(
            LMStudioShelfResolver.coverage(of: folder, scannedRoots: roots.mlx, configuredRoots: ["/m"], fileIdentity: { _ in nil }),
            .configuredNotScanned
        )
    }

    func testComponentWisePrefixDoesNotMatchASiblingWithTheSamePrefix() {
        func relative(_ path: String, _ base: String) -> [String]? {
            LMStudioPathMath.relative(of: LMStudioPathMath.components(path), under: LMStudioPathMath.components(base))
        }
        XCTAssertEqual(relative("/lm/a/b.gguf", "/lm"), ["a", "b.gguf"])
        XCTAssertEqual(relative("/lm", "/lm"), [])
        XCTAssertNil(relative("/lm-other/a.gguf", "/lm"))
        XCTAssertNil(relative("/else/a", "/lm"))
        XCTAssertEqual(relative("/lm/a/../b/c.gguf", "/lm/"), ["b", "c.gguf"])
    }

    func testPathMathNeverReadsTheFileSystem() {
        XCTAssertEqual(LMStudioPathMath.components("/definitely/not/on/disk/model.gguf"), ["/", "definitely", "not", "on", "disk", "model.gguf"])
        XCTAssertEqual(LMStudioPathMath.directory("/x/y/model.gguf"), LMStudioPathMath.directory("/x/y/other.gguf"))
        XCTAssertNotEqual(LMStudioPathMath.directory("/x/y/model.gguf"), LMStudioPathMath.directory("/x/z/model.gguf"))
    }

    // MARK: Resolve

    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lms-home-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testTheSettingsFolderIsTheOnlyFolderWhenLMStudioNamesOne() throws {
        let home = try makeHome()
        let shelf = home.appendingPathComponent("drive/lms")
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".lmstudio/models"), withIntermediateDirectories: true)
        try write(#"{"downloadsFolder": "\#(shelf.path)"}"#, to: home.appendingPathComponent(".lmstudio/settings.json"))
        let resolution = LMStudioShelfResolver.resolve(
            home: home, scannedRoots: ScanRoots(gguf: [home.appendingPathComponent("drive").path], mlx: []),
            configGGUFRoots: [], configMLXRoots: []
        )
        XCTAssertTrue(resolution.installed)
        XCTAssertEqual(resolution.folders.map(\.source), [.settings])
        XCTAssertEqual(resolution.folders[0].url.path, shelf.path)
        XCTAssertEqual(resolution.folders[0].gguf, .scanned(root: home.appendingPathComponent("drive").path, folder: shelf.path))
        XCTAssertEqual(resolution.folders[0].mlx, .notConfigured)
    }

    func testThePresentDefaultIsTheFolderWhenSettingsNameNone() throws {
        let home = try makeHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".lmstudio/models"), withIntermediateDirectories: true)
        try write(#"{"other": 1}"#, to: home.appendingPathComponent(".lmstudio/settings.json"))
        let resolution = LMStudioShelfResolver.resolve(home: home, scannedRoots: nil, configGGUFRoots: [], configMLXRoots: [])
        XCTAssertEqual(resolution.folders.map(\.source), [.default])
        let bare = try makeHome()
        try FileManager.default.createDirectory(at: bare.appendingPathComponent(".lmstudio/models"), withIntermediateDirectories: true)
        XCTAssertEqual(LMStudioShelfResolver.resolve(home: bare, scannedRoots: nil, configGGUFRoots: [], configMLXRoots: []).folders.map(\.source), [.default])
    }

    func testAMissingSettingsFolderStaysTheOnlyFolderBesideAPresentDefault() throws {
        let home = try makeHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".lmstudio/models"), withIntermediateDirectories: true)
        try write(#"{"downloadsFolder": "\#(home.path)/gone/lms"}"#, to: home.appendingPathComponent(".lmstudio/settings.json"))
        let resolution = LMStudioShelfResolver.resolve(home: home, scannedRoots: nil, configGGUFRoots: [], configMLXRoots: [])
        XCTAssertEqual(resolution.folders.map(\.source), [.settings])
        XCTAssertEqual(resolution.folders.map(\.isPresent), [false])
    }

    func testAMissingSettingsFolderIsKeptNotPresentAndAbsentDefaultsAreDropped() throws {
        let home = try makeHome()
        try write(#"{"downloadsFolder": "\#(home.path)/gone/lms"}"#, to: home.appendingPathComponent(".lmstudio/settings.json"))
        let resolution = LMStudioShelfResolver.resolve(home: home, scannedRoots: nil, configGGUFRoots: [], configMLXRoots: [])
        XCTAssertEqual(resolution.folders.count, 1)
        XCTAssertEqual(resolution.folders[0].source, .settings)
        XCTAssertFalse(resolution.folders[0].isPresent)
        XCTAssertEqual(resolution.folders[0].gguf, .unknown)
    }

    func testTheSameFolderUnderTwoCandidatesIsListedOnce() throws {
        let home = try makeHome()
        let models = home.appendingPathComponent(".lmstudio/models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try write(#"{"downloadsFolder": "\#(models.path)"}"#, to: home.appendingPathComponent(".lmstudio/settings.json"))
        let resolution = LMStudioShelfResolver.resolve(home: home, scannedRoots: nil, configGGUFRoots: [], configMLXRoots: [])
        XCTAssertEqual(resolution.folders.map(\.source), [.settings])
    }

    func testTheDownloadsFolderFollowsASymlinkedSettingsFileAndSkipsOtherFileTypes() throws {
        let home = try makeHome()
        let real = home.appendingPathComponent("dotfiles/lmstudio-settings.json")
        try write(#"{"downloadsFolder": "~/lms"}"#, to: real)
        let settings = home.appendingPathComponent(".lmstudio/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: real)
        XCTAssertEqual(LMStudioShelfResolver.downloadsFolder(home: home)?.path, home.appendingPathComponent("lms").path)

        try FileManager.default.removeItem(at: settings)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        XCTAssertNil(LMStudioShelfResolver.downloadsFolder(home: home))
    }

    func testNothingInstalledResolvesToNoFolders() throws {
        let home = try makeHome()
        let resolution = LMStudioShelfResolver.resolve(home: home, scannedRoots: nil, configGGUFRoots: [], configMLXRoots: [])
        XCTAssertFalse(resolution.installed)
        XCTAssertTrue(resolution.folders.isEmpty)
    }
}

// MARK: - Rows

final class LMStudioRowsTests: XCTestCase {
    private let dir = "/lm/publisher-a/model-a-GGUF"

    func testACompanionIsNotARowAndAttachesToItsGGUFWithBuiltHelp() throws {
        let projector = F.gguf("\(dir)/mmproj-F16.gguf", bytes: 1_800_000_000, quant: "F16", status: "companion", companion: true)
        let presentation = F.present(snapshot: F.snapshot([F.gguf("\(dir)/model-a-Q4_K_M.gguf"), projector]))
        let rows = F.rows(presentation, .gguf)
        XCTAssertEqual(rows.count, 1)
        let size = ByteCountFormatter.string(fromByteCount: 1_800_000_000, countStyle: .file)
        XCTAssertEqual(rows[0].tags, [.visionProjector(help: "mmproj-F16.gguf (\(size)) isn't converted; the MLX output is text only.")])
        XCTAssertEqual(rows[0].tags[0].title, "Vision projector")
        XCTAssertEqual(rows[0].action, .prepare)
    }

    func testACompanionInAnotherDirectoryDoesNotAttach() {
        let projector = F.gguf("/lm/publisher-b/other/mmproj.gguf", status: "companion", companion: true)
        let rows = F.rows(F.present(snapshot: F.snapshot([F.gguf("\(dir)/model-a-Q4_K_M.gguf"), projector])), .gguf)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].tags.isEmpty)
    }

    func testShardsAreNotRowsAndTheirBytesJoinTheHead() {
        let head = F.gguf("\(dir)/model-a-Q4-00001-of-00002.gguf", bytes: 30_000_000_000)
        let tail = F.gguf("\(dir)/model-a-Q4-00002-of-00002.gguf", bytes: 20_000_000_000, status: "shard")
        let other = F.gguf("/lm/publisher-z/other/model-a-Q4-00002-of-00002.gguf", bytes: 9_000_000_000, status: "shard")
        let rows = F.rows(F.present(snapshot: F.snapshot([head, tail, other])), .gguf)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bytes, 50_000_000_000)
        XCTAssertEqual(rows[0].sizeText, ByteCountFormatter.string(fromByteCount: 50_000_000_000, countStyle: .file))
    }

    func testTheFitIsMadeFromTheSummedSize() {
        let head = F.gguf("\(dir)/m-00001-of-00002.gguf", bytes: 30_000_000_000)
        let tail = F.gguf("\(dir)/m-00002-of-00002.gguf", bytes: 80_000_000_000, status: "shard")
        let whole = F.rows(F.present(snapshot: F.snapshot([head, tail])), .gguf)[0]
        let alone = F.rows(F.present(snapshot: F.snapshot([head])), .gguf)[0]
        XCTAssertEqual(whole.fit.tone, .wontFit)
        XCTAssertEqual(alone.fit.tone, .fits)
    }

    func testAnUnreadableFileHasNoActionAndSaysSo() {
        let unreadable = F.gguf("\(dir)/model-a-Q4_K_M.gguf", readable: false)
        let rows = F.rows(F.present(snapshot: F.snapshot([unreadable])), .gguf)
        XCTAssertTrue(rows[0].isUnreadable)
        XCTAssertEqual(rows[0].action, .none)
        XCTAssertTrue(rows[0].accessibilityLabel.contains("This file can't be read."))
    }

    func testAConvertedGGUFRunsItsServableReadyOutput() {
        let output = "/lm/publisher-c/model-c-8bit"
        let converted = F.gguf("\(dir)/model-a-Q4_K_M.gguf", status: "converted", outputs: [output])
        let rows = F.rows(F.present(snapshot: F.snapshot([converted, F.mlx(output)])), .gguf)
        XCTAssertEqual(rows[0].tags, [.converted])
        XCTAssertEqual(rows[0].action, .run(path: output))
        XCTAssertEqual(rows[0].action.title, "Run…")
    }

    func testAConvertedGGUFWithoutAServableOutputInTheSnapshotHasNoAction() {
        let converted = F.gguf("\(dir)/model-a-Q4_K_M.gguf", status: "converted", outputs: ["/elsewhere/out"])
        XCTAssertEqual(F.rows(F.present(snapshot: F.snapshot([converted])), .gguf)[0].action, .none)
        let output = "/lm/publisher-c/model-c-8bit"
        let embedding = F.gguf("\(dir)/model-a-Q4_K_M.gguf", status: "converted", outputs: [output])
        let rows = F.rows(F.present(snapshot: F.snapshot([embedding, F.mlx(output, task: .embedding)])), .gguf)
        XCTAssertEqual(rows[0].action, .none)
    }

    func testMLXRunsWhenServableAndReadyAndOtherwiseHasNoAction() {
        let a = F.mlx("/lm/publisher-a/model-a-8bit")
        let b = F.mlx("/lm/publisher-b/model-b-8bit", task: .imageGeneration)
        let rows = F.rows(F.present(snapshot: F.snapshot([a, b])), .mlx)
        XCTAssertEqual(rows.first { $0.id == a.item.path }?.action, .run(path: a.item.path))
        XCTAssertEqual(rows.first { $0.id == b.item.path }?.action, LMStudioRow.Action.none)
    }

    func testUnquantizedMLXFoldersAreNotListedAndBitsReadAsBits() {
        let unquantized = F.mlx("/lm/publisher-a/model-a-bf16", quant: nil)
        let quantized = F.mlx("/lm/publisher-a/model-a-4bit", quant: "q4")
        let rows = F.rows(F.present(snapshot: F.snapshot([unquantized, quantized])), .mlx)
        XCTAssertEqual(rows.map(\.id), [quantized.item.path])
        XCTAssertEqual(rows[0].quantText, "4-bit")
        XCTAssertEqual(rows[0].figuresText, "4-bit · \(ByteCountFormatter.string(fromByteCount: 4_000_000_000, countStyle: .file))")
        XCTAssertEqual(LMStudioLane(format: .mlx, rows: rows, notice: nil).footer, "Unquantized MLX folders aren't listed.")
        XCTAssertNil(LMStudioLane(format: .gguf, rows: [], notice: nil).footer)
    }

    func testTheRepoLabelIsPublisherAndRepoWithAFlatFallback() {
        let deep = F.gguf("/lm/publisher-a/model-a-GGUF/model-a-Q4_K_M.gguf")
        let flat = F.gguf("/lm/loose-model-Q8_0.gguf", quant: "Q8_0")
        let oneDirectory = F.gguf("/lm/only-dir/model-q.gguf", quant: "Q2_K")
        let mlxDeep = F.mlx("/lm/publisher-a/model-a-8bit")
        let mlxFlat = F.mlx("/lm/flat-model-4bit", quant: "q4")
        let presentation = F.present(snapshot: F.snapshot([deep, flat, oneDirectory, mlxDeep, mlxFlat]))
        let labels = Dictionary(uniqueKeysWithValues: (F.rows(presentation, .gguf) + F.rows(presentation, .mlx)).map { ($0.id, $0.repo) })
        XCTAssertEqual(labels[deep.item.path], "publisher-a/model-a-GGUF")
        XCTAssertEqual(labels[flat.item.path], "loose-model-Q8_0.gguf")
        XCTAssertEqual(labels[oneDirectory.item.path], "model-q.gguf")
        XCTAssertEqual(labels[mlxDeep.item.path], "publisher-a/model-a-8bit")
        XCTAssertEqual(labels[mlxFlat.item.path], "flat-model-4bit")
    }

    func testLanesSortByFitThenSizeThenPath() {
        let big = F.mlx("/lm/p/big-8bit", bytes: 200_000_000_000)
        let mid = F.mlx("/lm/p/mid-8bit", bytes: 8_000_000_000)
        let small = F.mlx("/lm/p/small-8bit", bytes: 2_000_000_000)
        let twinB = F.mlx("/lm/p/b-twin-8bit", bytes: 2_000_000_000)
        let rows = F.rows(F.present(snapshot: F.snapshot([big, mid, small, twinB])), .mlx)
        XCTAssertEqual(rows.map(\.id), [twinB, small, mid, big].map(\.item.path))
        XCTAssertEqual(rows.map(\.fit.tone), [.fits, .fits, .fits, .wontFit])
    }

    func testOnlyModelsInsideAScannedFolderAreListed() {
        let inside = F.mlx("/lm/p/in-8bit")
        let outside = F.mlx("/elsewhere/p/out-8bit")
        let sibling = F.mlx("/lm-other/p/sib-8bit")
        let rows = F.rows(F.present(snapshot: F.snapshot([inside, outside, sibling])), .mlx)
        XCTAssertEqual(rows.map(\.id), [inside.item.path])
    }

    func testRowsMatchTheScannedSpellingNotTheResolvedOne() {
        let folder = F.folder("/real/lms", gguf: .scanned(root: "/alias", folder: "/alias/lms"), mlx: .scanned(root: "/alias", folder: "/alias/lms"))
        let model = F.mlx("/alias/lms/p/a-8bit")
        let rows = F.rows(F.present(resolution: F.resolution([folder]), snapshot: F.snapshot([model])), .mlx)
        XCTAssertEqual(rows.map(\.id), [model.item.path])
    }

    func testEveryRowIsOneAccessibilityElementNamingRepoFormatQuantSizeAndFit() {
        let rows = F.rows(F.present(snapshot: F.snapshot([F.mlx("/lm/publisher-a/model-a-8bit")])), .mlx)
        let label = rows[0].accessibilityLabel
        for part in ["publisher-a/model-a-8bit", "MLX", "8-bit", "4 GB"] {
            XCTAssertTrue(label.contains(part), "\(part) in \(label)")
        }
        XCTAssertTrue(label.localizedCaseInsensitiveContains("fits"))
    }

    func testPlaceholderRowsImplyNoCountOrFit() {
        let placeholder = LMStudioRow.placeholder(0)
        XCTAssertEqual(placeholder.fit.state, .redacted)
        XCTAssertEqual(placeholder.action, .none)
        XCTAssertEqual(placeholder.bytes, 0)
    }

    func testSummaryCountsLaneRows() {
        let fits = F.mlx("/lm/p/a-8bit")
        let huge = F.mlx("/lm/p/b-8bit", bytes: 200_000_000_000)
        let toConvert = F.gguf("\(dir)/model-a-Q4_K_M.gguf", bytes: 5_000_000_000)
        let converted = F.gguf("/lm/publisher-b/model-b/model-b-Q4.gguf", bytes: 6_000_000_000, status: "converted", outputs: [fits.item.path])
        let summary = F.present(snapshot: F.snapshot([fits, huge, toConvert, converted])).summary
        XCTAssertEqual(summary.mlxModels, 2)
        XCTAssertEqual(summary.ggufToConvert, 1)
        XCTAssertEqual(summary.mlxFitNow, 1)
        XCTAssertEqual(summary.totalBytes, 4_000_000_000 + 200_000_000_000 + 5_000_000_000 + 6_000_000_000)
        let size = ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file)
        XCTAssertEqual(summary.items.map(\.figure), ["2", "1", "1", size])
        XCTAssertEqual(summary.items.map(\.label), ["MLX models", "GGUF to convert", "fit now", "on disk"])
        XCTAssertEqual(LMStudioSummary(mlxModels: 1, ggufToConvert: 0, mlxFitNow: 0, totalBytes: 0).items[0].label, "MLX model")
    }

    func testLaneTitlesNameTheFormat() {
        XCTAssertEqual(LMStudioLane(format: .mlx, rows: [], notice: nil).title, "MLX models")
        XCTAssertEqual(LMStudioLane(format: .gguf, rows: [], notice: nil).title, "GGUF files")
    }

    func testAccessibilityActionsListTheRowActionThenTheMenuActions() {
        let menu = ["Show in Library", "Reveal in Finder", "Copy Path"]
        let output = "/lm/publisher-c/model-c-8bit"
        let prepare = F.rows(F.present(snapshot: F.snapshot([F.gguf("\(dir)/model-a-Q4_K_M.gguf")])), .gguf)[0]
        XCTAssertEqual(prepare.accessibilityActionNames, ["Prepare…"] + menu)
        let run = F.rows(F.present(snapshot: F.snapshot([F.mlx(output)])), .mlx)[0]
        XCTAssertEqual(run.accessibilityActionNames, ["Run…"] + menu)
        let none = F.rows(F.present(snapshot: F.snapshot([F.mlx(output, task: .imageGeneration)])), .mlx)[0]
        XCTAssertEqual(none.accessibilityActionNames, menu)
    }

    func testTagHelpIsTheAccessibilityHint() {
        let projector = F.gguf("\(dir)/mmproj-F16.gguf", bytes: 1_800_000_000, quant: "F16", status: "companion", companion: true)
        let rows = F.rows(F.present(snapshot: F.snapshot([F.gguf("\(dir)/model-a-Q4_K_M.gguf"), projector])), .gguf)
        XCTAssertTrue(rows[0].accessibilityHint.contains("mmproj-F16.gguf"))
    }

    func testRowsClassifyFromStringsEvenWhenNothingExistsOnDisk() {
        let missing = "/definitely-not-on-disk-\(UUID().uuidString)"
        let folder = F.folder(missing)
        let head = F.gguf("\(missing)/p/r-GGUF/r-Q4-00001-of-00002.gguf", bytes: 3_000_000_000, key: "r")
        let tail = F.gguf("\(missing)/p/r-GGUF/r-Q4-00002-of-00002.gguf", bytes: 2_000_000_000, status: "shard", key: "r")
        let projector = F.gguf("\(missing)/p/r-GGUF/mmproj.gguf", status: "companion", companion: true)
        let mlx = F.mlx("\(missing)/p/m-8bit")
        let built = F.present(resolution: F.resolution([folder]), snapshot: F.snapshot([head, tail, projector, mlx]))
        let ggufRows = F.rows(built, .gguf)
        XCTAssertEqual(ggufRows.count, 1)
        XCTAssertEqual(ggufRows[0].bytes, 5_000_000_000)
        XCTAssertEqual(ggufRows[0].tags.map(\.title), ["Vision projector"])
        XCTAssertEqual(F.rows(built, .mlx).map(\.id), [mlx.item.path])
    }

    func testAMatchingPrebuiltIndexIsUsedAndAStaleOneIsRebuilt() {
        let resolution = F.resolution()
        let first = F.snapshot([F.mlx("/lm/p/a-8bit")])
        let index = LMStudioShelfIndex.make(snapshot: first, resolution: resolution)
        XCTAssertTrue(index.matches(snapshot: first, resolution: resolution))
        let later = LibrarySnapshot(
            models: [F.mlx("/lm/p/b-8bit")], groups: [], hardware: F.hardware, generatedAt: Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        )
        XCTAssertFalse(index.matches(snapshot: later, resolution: resolution))
        let built = LMStudioShelfPresentation.make(
            resolution: resolution, snapshot: later, index: index, isScanning: false, lastError: nil, memory: F.memory(),
            hasProbed: true, contextTokens: F.context, reserveGB: F.reserveGB, hardware: F.hardware
        )
        XCTAssertEqual(F.rows(built, .mlx).map(\.id), ["/lm/p/b-8bit"])
    }

    func testTheLegendComesFromTheSharedBudgetOwner() {
        let built = F.present(memory: F.memory(), hasProbed: true)
        XCTAssertEqual(built.legend, DiscoverLegend.make(memory: F.memory(), hasProbed: true, reserveGB: F.reserveGB, contextTokens: F.context, hardware: F.hardware))
    }
}

// MARK: - States

final class LMStudioStateTests: XCTestCase {
    private func state(
        resolution: LMStudioShelfResolver.Resolution? = F.resolution(), snapshot: LibrarySnapshot? = F.snapshot([]),
        isScanning: Bool = false, lastError: String? = nil
    ) -> LMStudioShelfState {
        F.present(resolution: resolution, snapshot: snapshot, isScanning: isScanning, lastError: lastError).state
    }

    func testResolvingUntilTheResolverReturns() {
        XCTAssertEqual(state(resolution: nil), .resolving)
    }

    func testNotFoundWhenLMStudioIsNotInstalledAndHasNoFolders() {
        XCTAssertEqual(state(resolution: F.resolution([], installed: false)), .notFound)
        XCTAssertEqual(LMStudioShelfState.notFoundSentence, "LM Studio isn't set up on this Mac. Its models appear here after LM Studio downloads one.")
    }

    func testAMissingSettingsFolderNamesItAndConnectingTheDriveIsTheFix() {
        let missing = F.folder("/Volumes/Gone/lms", isPresent: false, gguf: .unknown, mlx: .unknown)
        XCTAssertEqual(state(resolution: F.resolution([missing])), .folderMissing(path: "/Volumes/Gone/lms"))
        XCTAssertEqual(
            LMStudioShelfState.folderMissingSentence(path: "/Volumes/Gone/lms"),
            "LM Studio keeps models in /Volumes/Gone/lms, which isn't available. Connect the drive, then scan again."
        )
    }

    func testTheSettingsFolderDecidesOverAnyOtherScannedFolder() {
        let gone = F.folder("/Volumes/Gone/lms", isPresent: false, gguf: .unknown, mlx: .unknown)
        let scannedDefault = F.folder("/home/user/.lmstudio/models", source: .default)
        XCTAssertEqual(state(resolution: F.resolution([gone, scannedDefault]), snapshot: F.snapshot([])), .folderMissing(path: "/Volumes/Gone/lms"))

        let unscanned = F.folder("/Volumes/Models/lms", gguf: .notConfigured, mlx: .notConfigured)
        XCTAssertEqual(
            state(resolution: F.resolution([unscanned, scannedDefault]), snapshot: F.snapshot([])),
            .folderNotice(.notConfigured(path: "/Volumes/Models/lms"))
        )
        let pending = F.folder("/Volumes/Models/lms", gguf: .configuredNotScanned, mlx: .configuredNotScanned)
        XCTAssertEqual(
            state(resolution: F.resolution([pending, scannedDefault]), snapshot: F.snapshot([])),
            .folderNotice(.configuredNotScanned)
        )
    }

    func testInstalledWithNoFoldersIsNotFound() {
        XCTAssertEqual(state(resolution: F.resolution([], installed: true)), .notFound)
    }

    func testNotConfiguredForOneFormatReplacesThatLaneOnly() {
        let folder = F.folder(mlx: .notConfigured)
        let built = F.present(resolution: F.resolution([folder]), snapshot: F.snapshot([F.gguf("/lm/p/r/model-Q4.gguf")]))
        let lanes = F.lanes(built)
        XCTAssertEqual(lanes.map(\.format), [.mlx, .gguf])
        XCTAssertEqual(lanes[0].notice, .notConfigured(path: "/lm"))
        XCTAssertTrue(lanes[0].rows.isEmpty)
        XCTAssertEqual(lanes[1].rows.count, 1)
        XCTAssertEqual(
            LMStudioShelfState.notConfiguredSentence(path: "/lm"),
            "LM Studio keeps models in /lm, which the Library does not scan. Add it under Library folders in Settings."
        )
    }

    func testConfiguredButNotYetScannedOffersAScan() {
        let folder = F.folder(gguf: .configuredNotScanned, mlx: .configuredNotScanned)
        let resolved = state(resolution: F.resolution([folder]))
        XCTAssertEqual(resolved, .folderNotice(.configuredNotScanned))
        let neither = state(resolution: F.resolution([F.folder(gguf: .notConfigured, mlx: .notConfigured)]))
        XCTAssertEqual(neither, .folderNotice(.notConfigured(path: "/lm")))
        XCTAssertEqual(LMStudioShelfState.configuredNotScannedSentence, "Added in Settings; scan to list it.")
    }

    func testALibraryThatNeverScannedOffersAScan() {
        XCTAssertEqual(state(snapshot: nil), .libraryNotScanned)
        XCTAssertEqual(state(resolution: F.resolution([F.folder(gguf: .unknown, mlx: .unknown)])), .libraryNotScanned)
    }

    func testScanningWithoutASnapshotShowsPlaceholders() {
        XCTAssertEqual(state(snapshot: nil, isScanning: true), .scanning)
    }

    func testAFailedScanWithoutASnapshotShowsTheErrorAndWithOneKeepsTheRows() {
        XCTAssertEqual(state(snapshot: nil, lastError: "agent exited 2"), .scanFailed("agent exited 2"))
        let kept = state(snapshot: F.snapshot([F.mlx("/lm/p/a-8bit")]), lastError: "agent exited 2")
        if case .lanes = kept {} else { XCTFail("rows stay when a snapshot exists") }
        XCTAssertEqual(LMStudioShelfPresentation.bannerText(snapshot: F.snapshot([]), lastError: "agent exited 2"), "agent exited 2")
        XCTAssertNil(LMStudioShelfPresentation.bannerText(snapshot: nil, lastError: "agent exited 2"))
    }

    func testAScannedFolderWithNoModelsIsEmpty() {
        XCTAssertEqual(state(snapshot: F.snapshot([F.mlx("/elsewhere/a-8bit")])), .emptyFolder)
        XCTAssertEqual(LMStudioShelfState.emptyFolderSentence, "LM Studio's folder has no models yet.")
    }

    func testALaneWithNoRowsIsOmitted() {
        let lanes = F.lanes(F.present(snapshot: F.snapshot([F.mlx("/lm/p/a-8bit")])))
        XCTAssertEqual(lanes.map(\.format), [.mlx])
    }

    func testEveryFolderGetsASourceCaptionAndACoverageWord() {
        let home = URL(fileURLWithPath: "/home/user")
        let settings = LMStudioFolderLine.make(F.folder("/home/user/.models/lms"), home: home)
        XCTAssertEqual(settings.displayPath, "~/.models/lms")
        XCTAssertEqual(settings.sourceCaption, "From LM Studio settings")
        XCTAssertEqual(settings.coverageWord, "Scanned")
        XCTAssertEqual(LMStudioFolderLine.make(F.folder(source: .default), home: home).sourceCaption, "LM Studio default")
        XCTAssertEqual(LMStudioFolderLine.make(F.folder(source: .legacy), home: home).sourceCaption, "Older LM Studio folder")
        XCTAssertEqual(LMStudioFolderLine.coverageWord(F.folder(isPresent: false)), "Not available")
        XCTAssertEqual(LMStudioFolderLine.coverageWord(F.folder(mlx: .notConfigured)), "Scanned for GGUF")
        XCTAssertEqual(LMStudioFolderLine.coverageWord(F.folder(gguf: .notConfigured, mlx: .notConfigured)), "Not scanned")
        XCTAssertEqual(LMStudioFolderLine.coverageWord(F.folder(gguf: .configuredNotScanned, mlx: .configuredNotScanned)), "Scan to list it")
        XCTAssertEqual(LMStudioFolderLine.coverageWord(F.folder(gguf: .unknown, mlx: .unknown)), "Waiting for a scan")
        XCTAssertEqual(LMStudioFolderLine.abbreviated("/elsewhere/lms", home: home), "/elsewhere/lms")
        XCTAssertEqual(LMStudioFolderLine.abbreviated("/home/user-two/lms", home: home), "/home/user-two/lms")
    }
}

// MARK: - Layout

final class LMStudioLayoutTests: XCTestCase {
    func testLayoutFlipsAtTheMeasuredViewports() {
        let wide = LMStudioLayout(viewportWidth: 1220)
        XCTAssertEqual(wide.contentWidth, WorkbenchSize.LMStudio.contentMaxWidth)
        XCTAssertEqual(wide.rowTier, .wide)
        XCTAssertFalse(wide.headerWraps)
        XCTAssertFalse(wide.legendWraps)
        let medium = LMStudioLayout(viewportWidth: 824)
        XCTAssertEqual(medium.rowTier, .medium)
        XCTAssertFalse(medium.headerWraps)
        XCTAssertFalse(medium.legendWraps)
        let narrow = LMStudioLayout(viewportWidth: 514)
        XCTAssertEqual(narrow.rowTier, .stacked)
        XCTAssertTrue(narrow.headerWraps)
        XCTAssertTrue(narrow.legendWraps)
        XCTAssertEqual(LMStudioLayout(viewportWidth: 4000).contentWidth, WorkbenchSize.LMStudio.contentMaxWidth)
        XCTAssertEqual(LMStudioLayout(viewportWidth: 0).contentWidth, 0)
    }

    func testEachThresholdFlipsWithAndWithoutAPreviousLayout() {
        let inset = WorkbenchSpacing.pageInset * 2
        func viewport(_ content: CGFloat) -> CGFloat { content + inset }
        let hysteresis = WorkbenchSize.LMStudio.hysteresis

        let row = WorkbenchSize.LMStudio.rowThreshold
        XCTAssertEqual(LMStudioLayout(viewportWidth: viewport(row)).rowTier, .wide)
        XCTAssertEqual(LMStudioLayout(viewportWidth: viewport(row - 1)).rowTier, .medium)
        let medium = LMStudioLayout(viewportWidth: viewport(row - 1))
        XCTAssertEqual(LMStudioLayout(viewportWidth: viewport(row + 1), previous: medium).rowTier, .medium)
        XCTAssertEqual(LMStudioLayout(viewportWidth: viewport(row + hysteresis), previous: medium).rowTier, .wide)

        let mediumEdge = WorkbenchSize.LMStudio.mediumThreshold
        XCTAssertEqual(LMStudioLayout(viewportWidth: viewport(mediumEdge)).rowTier, .medium)
        XCTAssertEqual(LMStudioLayout(viewportWidth: viewport(mediumEdge - 1)).rowTier, .stacked)
        let stacked = LMStudioLayout(viewportWidth: viewport(mediumEdge - 1))
        XCTAssertEqual(LMStudioLayout(viewportWidth: viewport(mediumEdge + 1), previous: stacked).rowTier, .stacked)
        XCTAssertEqual(LMStudioLayout(viewportWidth: viewport(mediumEdge + hysteresis), previous: stacked).rowTier, .medium)
        XCTAssertEqual(LMStudioLayout(viewportWidth: viewport(row + hysteresis), previous: stacked).rowTier, .wide)
        XCTAssertEqual(LMStudioLayout(viewportWidth: viewport(mediumEdge - 1), previous: LMStudioLayout(viewportWidth: viewport(row))).rowTier, .stacked)

        let header = WorkbenchSize.LMStudio.headerThreshold
        XCTAssertFalse(LMStudioLayout(viewportWidth: viewport(header)).headerWraps)
        XCTAssertTrue(LMStudioLayout(viewportWidth: viewport(header - 1)).headerWraps)
        let wraps = LMStudioLayout(viewportWidth: viewport(header - 1))
        XCTAssertTrue(LMStudioLayout(viewportWidth: viewport(header + 1), previous: wraps).headerWraps)
        XCTAssertFalse(LMStudioLayout(viewportWidth: viewport(header + hysteresis), previous: wraps).headerWraps)

        let legend = WorkbenchSize.LMStudio.legendThreshold
        XCTAssertTrue(LMStudioLayout(viewportWidth: viewport(legend - 1)).legendWraps)
        XCTAssertFalse(LMStudioLayout(viewportWidth: viewport(legend)).legendWraps)
    }

    func testTheRowThresholdIsTheSumOfItsColumnsAndFitsTheContentWidth() {
        let size = WorkbenchSize.LMStudio.self
        XCTAssertEqual(
            size.rowThreshold,
            size.symbolColumn + size.nameMinimum + size.fitColumn + size.figuresWidth + size.actionWidth
                + size.columnGap * 4 + WorkbenchSpacing.surfaceInset * 2
        )
        XCTAssertLessThanOrEqual(size.rowThreshold, size.contentMaxWidth)
        XCTAssertEqual(size.fitColumn, WorkbenchSize.Discover.barWidth)
        XCTAssertEqual(size.figuresWidth, WorkbenchSize.Discover.figuresWidth)
    }

    func testTheMediumThresholdFitsTheNarrowestOfferedWindowAndSitsBelowTheWideOne() {
        let size = WorkbenchSize.LMStudio.self
        XCTAssertEqual(
            size.mediumThreshold,
            size.symbolColumn + size.nameMediumMinimum + size.fitColumn + max(size.figuresWidth, size.actionWidth)
                + size.columnGap * 3 + WorkbenchSpacing.surfaceInset * 2
        )
        XCTAssertLessThanOrEqual(size.mediumThreshold, 824 - 2 * WorkbenchSpacing.pageInset)
        XCTAssertLessThan(size.mediumThreshold, size.rowThreshold)
    }

    func testTheRouteDescriptionNamesWhatTheScreenDoes() {
        XCTAssertEqual(AppRoute.lmStudio.pageDescription, "See LM Studio's models: what runs here and what needs converting.")
    }
}

// MARK: - Source

final class LMStudioSourceTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/UI/Views/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let files = ["LMStudioView.swift", "LMStudioShelfViews.swift", "LMStudioShelfPresentation.swift"]

    func testTheScreenDoesNoFileWalkingAndNeverWritesConfig() throws {
        for name in files {
            let text = try source(name)
            for banned in ["FileManager", "enumerator(", "saveSettingsConfig", "Process(", "URLSession", "NSOpenPanel", "fileURLWithPath"] {
                XCTAssertFalse(text.contains(banned), "\(name) contains \(banned)")
            }
        }
    }

    func testExactlyOneViewObservesTheResourceMonitor() throws {
        var count = 0
        for name in files {
            for line in try source(name).split(separator: "\n") where line.contains("@ObservedObject") && line.contains("SystemResourceMonitor") {
                count += 1
            }
        }
        XCTAssertEqual(count, 1)
        XCTAssertTrue(try source("LMStudioShelfViews.swift").contains("@ObservedObject var resources: SystemResourceMonitor"))
    }

    func testNoProminentButtonNoPaintedCanvasAndTheResolverRunsOffTheMainActor() throws {
        let all = try files.map(source).joined(separator: "\n")
        XCTAssertFalse(all.contains("borderedProminent"))
        XCTAssertFalse(all.contains(".background(WorkbenchColor.canvas"))
        let page = try source("LMStudioView.swift")
        XCTAssertTrue(page.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(page.contains(".task(id: resolveKey)"))
        XCTAssertTrue(page.contains("guard fixedResolution == nil else"))
        XCTAssertTrue(page.contains("loader.load(isActive: isRouteActive)"))
    }

    func testSettingsDiscoveryNeverSpawnsProcesses() throws {
        let services = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/Services")
        let resolver = try String(contentsOf: services.appendingPathComponent("LMStudioShelfResolver.swift"), encoding: .utf8)
        let config = try String(contentsOf: services.appendingPathComponent("AppConfig.swift"), encoding: .utf8)
        let start = try XCTUnwrap(config.range(of: "static func discoverGgufRoots("))
        let end = try XCTUnwrap(config.range(of: "static func defaultQuarantineDir("))
        for (name, text) in [("LMStudioShelfResolver.swift", resolver), ("discoverGgufRoots", String(config[start.lowerBound..<end.lowerBound]))] {
            for banned in ["Process(", "URLSession", "enumerator("] {
                XCTAssertFalse(text.contains(banned), "\(name) contains \(banned)")
            }
        }
        XCTAssertTrue(String(config[start.lowerBound..<end.lowerBound]).contains("LMStudioShelfResolver.downloadsFolder(home: home)"))
    }

    func testThePageDefaultsToTheHostedSafeHome() throws {
        let page = try source("LMStudioView.swift")
        XCTAssertTrue(page.contains("home: URL = WorkbenchStatePaths.userHome()"))
        XCTAssertFalse(page.contains("Path.home()"))
    }

    func testRemovedSurfacesStayRemoved() throws {
        let page = try source("LMStudioView.swift")
        for removed in ["LMStudioScanState", "LMSModel", "discoverLMStudio", "Choose…", "Optional source dir", #"Text("LM Studio")"#] {
            XCTAssertFalse(page.contains(removed), removed)
        }
    }

    func testRepoNamesAreProportionalOnBothShelves() throws {
        for name in ["LMStudioShelfViews.swift", "DiscoverViews.swift"] {
            let text = try source(name)
            let start = try XCTUnwrap(text.range(of: "Text(row.repo)"), name)
            XCTAssertFalse(String(text[start.upperBound...].prefix(80)).contains("compactValue"), name)
        }
    }

    func testTheViewShowsTheBannerTextTheModelBuilds() throws {
        let page = try source("LMStudioView.swift")
        XCTAssertTrue(page.contains("LMStudioShelfPresentation.bannerText("))
        XCTAssertFalse(page.contains("ErrorBanner(text: appHost.lastError)"))
    }
}

// MARK: - Resolution loader

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
final class LMStudioResolutionLoaderTests: XCTestCase {
    private func resolution(_ path: String) -> LMStudioShelfResolver.Resolution { F.resolution([F.folder(path)]) }

    func testAnInactiveRouteNeverCallsTheResolver() async {
        let loader = LMStudioResolutionLoader()
        var calls = 0
        await loader.load(isActive: false) { calls += 1; return self.resolution("/a") }
        XCTAssertEqual(calls, 0)
        XCTAssertNil(loader.resolution)
    }

    func testReactivatingResolvesAgain() async {
        let loader = LMStudioResolutionLoader()
        var calls = 0
        await loader.load(isActive: false) { calls += 1; return self.resolution("/a") }
        await loader.load(isActive: true) { calls += 1; return self.resolution("/a") }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(loader.resolution, resolution("/a"))
    }

    func testAFinishedScanChangesTheKeySoItResolvesAgainWhetherItSucceededOrFailed() {
        func key(_ finished: Int) -> LMStudioResolveKey {
            LMStudioResolveKey(
                scannedAt: nil, isRouteActive: true, scannedRoots: nil, ggufRoots: [], mlxRoots: [], outputDir: "/out", scansFinished: finished
            )
        }
        XCTAssertEqual(LMStudioResolveKey.scansFinished(0, wasScanning: false, isScanning: true), 0)
        XCTAssertEqual(LMStudioResolveKey.scansFinished(0, wasScanning: true, isScanning: false), 1)
        XCTAssertNotEqual(key(0), key(LMStudioResolveKey.scansFinished(0, wasScanning: true, isScanning: false)))
        XCTAssertEqual(key(1), key(LMStudioResolveKey.scansFinished(1, wasScanning: false, isScanning: false)))
    }

    func testASlowFirstResultDoesNotOverwriteASecond() async {
        let loader = LMStudioResolutionLoader()
        let gate = Gate()
        let first = Task { await loader.load(isActive: true) { await gate.wait(); return self.resolution("/first") } }
        first.cancel()
        await loader.load(isActive: true) { self.resolution("/second") }
        await gate.open()
        await first.value
        XCTAssertEqual(loader.resolution, resolution("/second"))
    }
}

// MARK: - Renders

@MainActor
final class LMStudioRenderTests: XCTestCase {
    private func config() -> Config {
        Config(
            schemaVersion: Config.SCHEMA_VERSION, ggufRoots: ["/m"], mlxRoots: [], outputDir: "/out/mlx",
            mlxAgentPath: "/agent", quarantineDir: "/quarantine", qBits: 4, signatures: true, host: "127.0.0.1",
            port: 8765, verificationEnabled: true, watchEnabled: true, fitReserveGB: F.reserveGB, reclaimStaleDays: 60,
            comparisonMaxTokens: 512
        )
    }

    private func host(snapshot: LibrarySnapshot?, isScanning: Bool = false, lastError: String? = nil) -> AppHost {
        let host = AppHost(
            config: config(), discoveredRoots: [], configPath: "/state/config.json", agentHealth: .notConfigured,
            runtimeReport: RuntimeReport(
                convert: ConvertStatus(ok: true, modules: [:], executables: [:], missingModules: [], missingExecutables: [], install: "make install", message: "Ready."),
                serve: ServeStatus(ok: true, executables: [:], missingExecutables: [], install: "make install", message: "Ready."),
                install: "make install", ok: true
            ), hardwareProfile: F.hardware,
            modelWorkflowAPI: ModelWorkflowAPI(
                convertPreview: { _, _, _ in [:] }, convertStart: { _, _, _, _ in [:] }, convertStatus: { [] },
                servePreview: { _, _, _ in [:] }, serveStart: { _, _, _, _ in [:] }, serveStatus: { [] }, serveStop: { _ in [:] }
            ),
            modelWorkflowPersistence: ModelWorkflowPersistence(load: { [] }, upsert: { _ in })
        )
        host.librarySnapshot = snapshot
        host.isScanning = isScanning
        host.lastError = lastError
        return host
    }

    private func monitor() async -> SystemResourceMonitor {
        let reading = F.memory(available: 60_000_000_000)
        let monitor = SystemResourceMonitor(probe: { reading })
        await monitor.refreshMemory()
        return monitor
    }

    private let populated: [LibraryModel] = {
        let projector = F.gguf("/lm/publisher-a/model-a-GGUF/mmproj-F16.gguf", bytes: 1_800_000_000, quant: "F16", status: "companion", companion: true)
        return [
            F.mlx("/lm/publisher-a/model-a-8bit", bytes: 9_000_000_000),
            F.mlx("/lm/publisher-b/model-b-4bit", bytes: 21_000_000_000, quant: "q4"),
            F.mlx("/lm/publisher-c/model-c-8bit", bytes: 48_000_000_000),
            F.mlx("/lm/publisher-d/model-d-8bit", bytes: 130_000_000_000),
            F.mlx("/lm/publisher-e/image-model-8bit", bytes: 12_000_000_000, task: .imageGeneration),
            F.gguf("/lm/publisher-a/model-a-GGUF/model-a-Q6_K.gguf", bytes: 24_000_000_000, quant: "Q6_K"),
            projector,
            F.gguf("/lm/publisher-f/model-f-GGUF/model-f-Q8_0.gguf", bytes: 29_000_000_000, quant: "Q8_0", readable: false),
            F.gguf("/lm/publisher-g/model-g-GGUF/model-g-Q4_K_M.gguf", bytes: 16_000_000_000, status: "converted", outputs: ["/lm/publisher-b/model-b-4bit"]),
        ]
    }()

    private func attach<Content: View>(_ view: Content, name: String, viewport: CGFloat, dark: Bool, height: CGFloat = 1500) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: viewport, height: height).background(WorkbenchColor.canvas).preferredColorScheme(dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: viewport, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
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

    func testEveryStateRendersDarkAndLightAtEveryWidth() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let home = URL(fileURLWithPath: "/home/user")
        let shelf = "/home/user/.models/lmstudio"
        let scanned = LMStudioShelfResolver.Coverage.scanned(root: "/home/user/.models", folder: shelf)
        let present = [F.folder(shelf, gguf: scanned, mlx: scanned)]
        let moved = populated.map { model -> LibraryModel in
            let item = model.item
            func rebased(_ value: String) -> String { value.replacingOccurrences(of: "/lm/", with: shelf + "/") }
            let copy = ModelItem(
                path: rebased(item.path), name: item.name, bytes: item.bytes, modifiedAt: nil, shard: nil, modelKey: item.modelKey,
                architecture: nil, quantization: item.quantization, parameters: nil, structure: nil, signature: nil,
                companion: item.companion, readable: item.readable, status: item.status, outputs: item.outputs.map(rebased),
                tensorCount: nil, error: nil, task: item.task
            )
            return LibraryModel(item: copy, readiness: model.readiness, sourcePaths: [copy.path], outputPaths: copy.outputs)
        }
        struct Scenario {
            let name: String
            let resolution: LMStudioShelfResolver.Resolution?
            let snapshot: LibrarySnapshot?
            var isScanning = false
            var lastError: String?
        }
        let scenarios = [
            Scenario(name: "populated", resolution: F.resolution(present), snapshot: F.snapshot(moved)),
            Scenario(name: "populated-error", resolution: F.resolution(present), snapshot: F.snapshot(moved), lastError: "The last scan failed: agent exited 2."),
            Scenario(name: "resolving", resolution: nil, snapshot: nil),
            Scenario(name: "scanning", resolution: F.resolution(present), snapshot: nil, isScanning: true),
            Scenario(name: "not-found", resolution: F.resolution([], installed: false), snapshot: nil),
            Scenario(name: "folder-missing", resolution: F.resolution([F.folder(shelf, isPresent: false, gguf: .unknown, mlx: .unknown)]), snapshot: nil),
            Scenario(name: "mlx-not-configured", resolution: F.resolution([F.folder(shelf, gguf: scanned, mlx: .notConfigured)]), snapshot: F.snapshot(moved)),
            Scenario(name: "not-configured", resolution: F.resolution([F.folder(shelf, gguf: .notConfigured, mlx: .notConfigured)]), snapshot: F.snapshot(moved)),
            Scenario(name: "configured-not-scanned", resolution: F.resolution([F.folder(shelf, gguf: .configuredNotScanned, mlx: .configuredNotScanned)]), snapshot: F.snapshot(moved)),
            Scenario(name: "never-scanned", resolution: F.resolution([F.folder(shelf, gguf: .unknown, mlx: .unknown)]), snapshot: nil),
            Scenario(name: "scan-failed", resolution: F.resolution(present), snapshot: nil, lastError: "Fixture scan failed: agent unavailable."),
            Scenario(name: "empty", resolution: F.resolution(present), snapshot: F.snapshot([])),
        ]
        let resources = await monitor()
        for scenario in scenarios {
            for dark in [true, false] {
                for width in [CGFloat(1220), 824, 514] {
                    let page = LMStudioView(
                        appHost: host(snapshot: scenario.snapshot, isScanning: scenario.isScanning, lastError: scenario.lastError),
                        resources: resources, home: home, resolution: scenario.resolution
                    )
                    // A resolving page is held before its resolver runs, which needs an active route.
                    try await attach(
                        page.environment(\.isRouteActive, scenario.resolution != nil), name: scenario.name, viewport: width, dark: dark
                    )
                }
            }
        }
    }
}
