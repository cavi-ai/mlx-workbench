import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

// MARK: - Fixtures

private enum IntakeFixtures {
    static let totalBytes: Int64 = 137_438_953_472
    static let hardware = HardwareProfile(chip: "Apple M4 Max", model: nil, memoryBytes: totalBytes, macOSVersion: nil)
    static let repo = "mlx-community/Qwen3-8B-4bit"
    static let cachePath = "/render/.cache/huggingface/hub/models--mlx-community--Qwen3-8B-4bit/snapshots/abc123"
    static let live = MemorySnapshot(totalBytes: totalBytes, availableBytes: 60_000_000_000)

    struct Spec {
        var verdict = "convertible"
        var repo = IntakeFixtures.repo
        var subfolder: String?
        var revision = "main"
        var backend: String? = "mlx-lm"
        var backendInstalled = true
        var modelType: String? = "qwen3"
        var task: String? = "text_llm"
        var bytes: Int64 = 16_400_000_000
        var downloadBytes: Int64?
        var estimates: String = #"{"4":4800000000,"8":8700000000}"#
        var qBits: String = "null"
        var recipe = false
        var components = "[]"
        var reasons = "[]"
        var warnings = "[]"
        var gguf = "[]"
    }

    static func resolution(_ spec: Spec = Spec()) throws -> IntakeResolution {
        let task = spec.task.map { #"{"type":"\#($0)","use_cases":["chat"],"source":"pipeline_tag","confidence":"confirmed"}"# } ?? "null"
        let recipe = spec.recipe
            ? #"{"base":"Qwen/Qwen-Image-2.1","base_revision":"abc","lora":"style.safetensors","lora_scale":1.0}"#
            : "null"
        let json = """
        {"schema":"intake/1","source":{"input":"\(spec.repo)","repo":"\(spec.repo)","revision":"\(spec.revision)","file":null,
         "subfolder":\(spec.subfolder.map { "\"\($0)\"" } ?? "null"),"url":"https://huggingface.co/\(spec.repo)"},
         "verdict":"\(spec.verdict)","reasons":\(spec.reasons),"backend":\(spec.backend.map { "\"\($0)\"" } ?? "null"),
         "backend_installed":\(spec.backendInstalled),"model_type":\(spec.modelType.map { "\"\($0)\"" } ?? "null"),
         "components":\(spec.components),"task":\(task),"custom_code":false,"gated":false,"library_name":null,
         "pipeline_tag":null,"transformers_version":null,"bytes":\(spec.bytes),
         "download_bytes":\(spec.downloadBytes.map(String.init) ?? "null"),"estimated_output_bytes":\(spec.estimates),
         "q_bits":\(spec.qBits),"recipe":\(recipe),
         "files":{"safetensors":4,"gguf":\(spec.gguf),"python":[]},"warnings":\(spec.warnings)}
        """
        return try JSONDecoder().decode(IntakeResolution.self, from: Data(json.utf8))
    }

    static func model(_ path: String, readiness: ModelReadiness = .ready) -> LibraryModel {
        let item = ModelItem(
            path: path, name: URL(fileURLWithPath: path).lastPathComponent, bytes: 4_800_000_000,
            modifiedAt: nil, shard: nil,
            modelKey: "model", architecture: nil, quantization: "4bit", parameters: nil,
            structure: nil, signature: nil, companion: nil, readable: true,
            status: "ready", outputs: [], tensorCount: nil, error: nil, task: nil
        )
        return LibraryModel(item: item, readiness: readiness)
    }

    static func snapshot(_ models: [LibraryModel]) -> LibrarySnapshot {
        LibrarySnapshot(models: models, groups: [], hardware: hardware, generatedAt: Date(timeIntervalSinceReferenceDate: 1_000_000_000))
    }

    static func fit(_ resolution: IntakeResolution, qBits: Int = 4, selectedGGUF: String? = nil, memory: MemorySnapshot? = live, hasProbed: Bool = true) -> IntakeFit? {
        IntakeFit.make(
            resolution, qBits: qBits, selectedGGUF: selectedGGUF, memory: memory, hasProbed: hasProbed,
            contextTokens: FitAdvisor.defaultContextTokens, reserveGB: 4, hardware: hardware
        )
    }
}

// MARK: - Presentation

final class IntakeRemodelTests: XCTestCase {
    private typealias F = IntakeFixtures

    func testEveryVerdictHasASentenceSymbolAndTone() throws {
        let expected: [(IntakeVerdict, IntakeVerdictLine.Tone)] = [
            (.unknown, .warning), (.blocked, .failure), (.alreadyMLX, .positive), (.gguf, .neutral),
            (.convertible, .positive), (.convertibleAfterInstall, .neutral), (.unsupported, .failure),
        ]
        for (verdict, tone) in expected {
            let line = IntakeVerdictLine.make(try F.resolution(F.Spec(verdict: verdict.rawValue)))
            XCTAssertTrue(line.sentence.hasPrefix(verdict.title + ". "), line.sentence)
            XCTAssertFalse(line.symbol.isEmpty)
            XCTAssertEqual(line.tone, tone, verdict.rawValue)
            XCTAssertFalse(line.sentence.contains(verdict.rawValue) && verdict.rawValue.contains("_"), "no raw enum string")
        }
    }

    func testVerdictSentenceNamesTheBackendToInstall() throws {
        let after = try F.resolution(F.Spec(verdict: "convertible_after_install", backend: "mlx-audio", backendInstalled: false))
        XCTAssertTrue(IntakeVerdictLine.make(after).sentence.contains("Install mlx-audio first"))
        let mlx = try F.resolution(F.Spec(verdict: "already_mlx", backend: "mlx-vlm", backendInstalled: false))
        XCTAssertTrue(IntakeVerdictLine.make(mlx).sentence.contains("once mlx-vlm is installed"))
        let ready = try F.resolution(F.Spec(verdict: "already_mlx", backend: "mlx-lm", backendInstalled: true))
        XCTAssertTrue(IntakeVerdictLine.make(ready).sentence.contains("without conversion"))
    }

    func testItemsLeadWithTheSizesAndOmitWhatIsAbsent() throws {
        let full = try F.resolution(F.Spec(downloadBytes: 15_000_000_000))
        let items = IntakePresentation.items(full, qBits: 4)
        XCTAssertEqual(items.map(\.label), ["Download size", "Estimated 4-bit output", "Type", "Use cases", "Architecture", "Backend"])
        XCTAssertEqual(items[0].figure, LibraryTablePresentation.byteCount(15_000_000_000))
        XCTAssertEqual(items[1].figure, LibraryTablePresentation.byteCount(4_800_000_000))
        XCTAssertTrue(items[0].isNumeric && items[1].isNumeric)
        XCTAssertFalse(items[2].isNumeric)
        XCTAssertEqual(IntakePresentation.items(full, qBits: 8).map(\.label)[1], "Estimated 8-bit output")

        let bare = try F.resolution(F.Spec(backend: nil, modelType: nil, task: nil, estimates: "null"))
        XCTAssertEqual(IntakePresentation.items(bare, qBits: 4).map(\.label), ["Download size", "Architecture"])
        XCTAssertEqual(IntakePresentation.items(bare, qBits: 4)[1].figure, "Unknown")
    }

    func testBackendItemSaysWhenItIsNotInstalled() throws {
        let missing = try F.resolution(F.Spec(backend: "mlx-audio", backendInstalled: false))
        XCTAssertEqual(IntakePresentation.items(missing, qBits: 4).first { $0.label == "Backend" }?.figure, "mlx-audio (not installed)")
        let installed = try F.resolution(F.Spec(backend: "mlx-audio", backendInstalled: true))
        XCTAssertEqual(IntakePresentation.items(installed, qBits: 4).first { $0.label == "Backend" }?.figure, "mlx-audio")
    }

    func testRecipeItemNamesWhatTheModelIsBuiltFrom() throws {
        let recipe = try F.resolution(F.Spec(task: "image_generation", estimates: "null", recipe: true))
        XCTAssertEqual(IntakePresentation.items(recipe, qBits: 4).first { $0.label == "Built from" }?.figure,
                       "Qwen/Qwen-Image-2.1 + style.safetensors")
    }

    func testNarrowedBitWidthSelectsTheEstimateThatWillBeUsed() throws {
        let only8 = try F.resolution(F.Spec(qBits: "[8]"))
        XCTAssertEqual(IntakePresentation.items(only8, qBits: 4)[1].label, "Estimated 8-bit output")
    }

    func testReasonCodesKeepTheirSentencesAndWarningsFollow() throws {
        let value = try F.resolution(F.Spec(
            verdict: "unsupported", modelType: "thing",
            reasons: #"["arch_not_in_registry","custom_code","no_config","gated","not_found_or_private","hub_unreachable","other_code"]"#,
            warnings: #"["Large repository."]"#
        ))
        XCTAssertEqual(IntakePresentation.reasonTexts(value), [
            "No installed or declared MLX backend implements thing.",
            "The repository ships custom modeling code; it is read, never executed.",
            "The repository has no readable config.json.",
            "The repository is gated; downloads need a token, which intake does not handle.",
            "The repository does not exist or is private.",
            "Hugging Face could not be reached.",
            "other_code",
            "Large repository.",
        ])
    }

    func testComponentRowsMarkMissingImplementations() throws {
        let components = """
        [{"role":"model","config_key":null,"model_type":"audio8","matches":[]},
         {"role":"audio","config_key":null,"model_type":"whisper","matches":[{"backend":"mlx-audio","category":"stt","match":"exact","module":"mlx_audio.stt.whisper"}]}]
        """
        let rows = IntakePresentation.componentRows(try F.resolution(F.Spec(components: components)))
        XCTAssertEqual(rows, [
            IntakeComponentRow(role: "model", type: "audio8", detail: "No MLX implementation", isMatched: false),
            IntakeComponentRow(role: "audio", type: "whisper", detail: "mlx_audio.stt.whisper (exact)", isMatched: true),
        ])
    }

    func testActivitySentences() {
        XCTAssertNil(IntakeActivityPresentation.sentence(.idle))
        XCTAssertNil(IntakeActivityPresentation.sentence(.failed("x")))
        XCTAssertEqual(IntakeActivityPresentation.sentence(.resolving), "Reading the model card and config…")
        XCTAssertEqual(IntakeActivityPresentation.sentence(.downloading(repo: "a/b")), "Downloading a/b…")
        XCTAssertEqual(IntakeActivityPresentation.sentence(.installing(backend: "mlx-lm")), "Installing mlx-lm into its own environment…")
        XCTAssertTrue(IntakeActivityPresentation.idleSentence.contains("nothing downloads until you confirm"))
    }

    // MARK: Fit

    func testFitUsesTheEstimatedOutputAtTheConfiguredWidth() throws {
        let value = try F.resolution()
        let fit = try XCTUnwrap(F.fit(value))
        XCTAssertEqual(fit.state, .estimated)
        XCTAssertEqual(fit.tone, .fits)
        XCTAssertNotNil(fit.fill)
        XCTAssertTrue(fit.showsTrack)
        XCTAssertTrue(fit.detail.contains("estimated 4-bit output, \(LibraryTablePresentation.byteCount(4_800_000_000))"), fit.detail)
        let eight = try XCTUnwrap(F.fit(value, qBits: 8))
        XCTAssertTrue(eight.detail.contains("estimated 8-bit output"), eight.detail)
    }

    func testFitFlagsAnOutputLargerThanTheBudget() throws {
        let huge = try F.resolution(F.Spec(estimates: #"{"4":400000000000}"#))
        let fit = try XCTUnwrap(F.fit(huge))
        XCTAssertEqual(fit.tone, .wontFit)
        XCTAssertEqual(fit.word, "Won't fit")
    }

    func testAlreadyMLXFallsBackToTheDownloadSize() throws {
        let value = try F.resolution(F.Spec(verdict: "already_mlx", bytes: 9_000_000_000, downloadBytes: 4_800_000_000, estimates: "null"))
        let fit = try XCTUnwrap(F.fit(value))
        XCTAssertEqual(fit.state, .estimated)
        XCTAssertTrue(fit.detail.contains("download size, \(LibraryTablePresentation.byteCount(4_800_000_000))"), fit.detail)
        let noDownload = try F.resolution(F.Spec(verdict: "already_mlx", bytes: 4_000_000_000, estimates: "null"))
        XCTAssertTrue(try XCTUnwrap(F.fit(noDownload)).detail.contains("download size, \(LibraryTablePresentation.byteCount(4_000_000_000))"))
    }

    func testNonServableTasksSayNoFitIsEstimated() throws {
        let value = try F.resolution(F.Spec(task: "speech_to_text"))
        let fit = try XCTUnwrap(F.fit(value))
        XCTAssertEqual(fit.state, .notServable)
        XCTAssertFalse(fit.showsTrack)
        XCTAssertEqual(fit.detail, "Fit is not estimated for speech-to-text models.")
    }

    func testConvertibleWithoutAnEstimateHasNoSizeToFit() throws {
        let value = try F.resolution(F.Spec(estimates: "null"))
        let fit = try XCTUnwrap(F.fit(value))
        XCTAssertEqual(fit.state, .sizeUnknown)
        XCTAssertNil(fit.fill)
        XCTAssertFalse(fit.showsTrack)
    }

    func testGGUFFitUsesTheSelectedFile() throws {
        let gguf = #"[{"name":"model-Q4_K_M.gguf","bytes":4900000000},{"name":"model-Q8_0.gguf","bytes":8700000000}]"#
        let value = try F.resolution(F.Spec(verdict: "gguf", backend: nil, estimates: "null", gguf: gguf))
        let fit = try XCTUnwrap(F.fit(value, selectedGGUF: "model-Q4_K_M.gguf"))
        XCTAssertEqual(fit.state, .estimated)
        XCTAssertTrue(fit.detail.contains("selected file, \(LibraryTablePresentation.byteCount(4_900_000_000))"), fit.detail)
        XCTAssertTrue(try XCTUnwrap(F.fit(value, selectedGGUF: "model-Q8_0.gguf")).detail.contains("selected file, \(LibraryTablePresentation.byteCount(8_700_000_000))"))
        XCTAssertEqual(try XCTUnwrap(F.fit(value)).state, .sizeUnknown)
    }

    func testAConvertibleWithoutAnEstimateMakesNoClaimAboutTheRepository() throws {
        for spec in [F.Spec(estimates: "null"), F.Spec(estimates: "null", recipe: true)] {
            let fit = try XCTUnwrap(F.fit(try F.resolution(spec)))
            XCTAssertEqual(fit.state, .sizeUnknown)
            XCTAssertFalse(fit.detail.contains("does not report"))
            XCTAssertFalse(fit.detail.lowercased().contains("repository"))
        }
    }

    func testTheLoadingPlaceholderIsNeverSpoken() throws {
        let loading = try XCTUnwrap(F.fit(try F.resolution(), memory: nil, hasProbed: false))
        XCTAssertEqual(loading.state, .redacted)
        XCTAssertFalse(loading.accessibilityLabel.contains("Won't fit"))
        XCTAssertEqual(loading.accessibilityLabel, "Fit on this Mac: reading memory")
        let live = try XCTUnwrap(F.fit(try F.resolution()))
        XCTAssertTrue(live.accessibilityLabel.contains(live.word))
    }

    func testFitFollowsTheMemoryReading() throws {
        let value = try F.resolution()
        XCTAssertEqual(F.fit(value, memory: nil, hasProbed: false)?.state, .redacted)
        XCTAssertEqual(F.fit(value, memory: nil, hasProbed: true)?.state, .unavailable)
        XCTAssertEqual(F.fit(value, memory: nil, hasProbed: true)?.detail, "Memory reading unavailable")
    }

    func testVerdictsWithoutADownloadShowNoFit() throws {
        for verdict in ["blocked", "unsupported", "unknown"] {
            XCTAssertNil(F.fit(try F.resolution(F.Spec(verdict: verdict))), verdict)
        }
        for verdict in ["already_mlx", "gguf", "convertible", "convertible_after_install"] {
            XCTAssertNotNil(F.fit(try F.resolution(F.Spec(verdict: verdict))), verdict)
        }
    }

    // MARK: Library

    func testLibraryMatchIsExactOnTheRepositoryRoot() throws {
        let ready = IntakeLibraryMatch.readyPaths(in: F.snapshot([F.model(F.cachePath), F.model("/models/local")]))
        let value = try F.resolution()
        XCTAssertEqual(IntakeLibraryMatch.path(for: value, readyPaths: ready), F.cachePath)
        XCTAssertNil(IntakeLibraryMatch.path(for: try F.resolution(F.Spec(repo: "other/repo")), readyPaths: ready))
        XCTAssertNil(IntakeLibraryMatch.path(for: try F.resolution(F.Spec(subfolder: "multilingual")), readyPaths: ready))
        XCTAssertNil(IntakeLibraryMatch.path(for: value, readyPaths: []))
    }

    func testLibraryMatchNeedsTheReadyModelAtTheRequestedRevision() throws {
        let ready = IntakeLibraryMatch.readyPaths(in: F.snapshot([F.model(F.cachePath)]))
        XCTAssertNil(IntakeLibraryMatch.path(for: try F.resolution(F.Spec(revision: "def")), readyPaths: ready))
        XCTAssertEqual(IntakeLibraryMatch.path(for: try F.resolution(F.Spec(revision: "abc123")), readyPaths: ready), F.cachePath)
        let incomplete = IntakeLibraryMatch.readyPaths(in: F.snapshot([F.model(F.cachePath, readiness: .incompleteCache)]))
        XCTAssertTrue(incomplete.isEmpty)
        XCTAssertNil(IntakeLibraryMatch.path(for: try F.resolution(), readyPaths: incomplete))
    }

    func testAnAlreadyDownloadedModelSaysSo() throws {
        let value = try F.resolution(F.Spec(verdict: "already_mlx"))
        XCTAssertTrue(IntakeVerdictLine.make(value).sentence.contains("downloads and runs"))
        XCTAssertTrue(IntakeVerdictLine.make(value, inLibrary: true).sentence.contains("already downloaded"))
    }

    // MARK: Log override

    func testLogChoiceHoldsUntilANewCheckStarts() {
        XCTAssertEqual(IntakeLogPresentation.override(true, after: .downloading(repo: "a/b")), true)
        XCTAssertEqual(IntakeLogPresentation.override(true, after: .failed("x")), true)
        XCTAssertEqual(IntakeLogPresentation.override(false, after: .installing(backend: "mlx-lm")), false)
        XCTAssertNil(IntakeLogPresentation.override(true, after: .resolving))
        XCTAssertTrue(IntakeLogPresentation.isExpanded(override: true, activity: .failed("x"), lines: []))
        XCTAssertTrue(IntakeLogPresentation.isExpanded(override: nil, activity: .failed("x"), lines: ["line"]))
        XCTAssertFalse(IntakeLogPresentation.isExpanded(override: nil, activity: .failed("x"), lines: []))
        XCTAssertFalse(IntakeLogPresentation.isExpanded(override: nil, activity: .idle, lines: ["line"]))
        XCTAssertTrue(IntakeLogPresentation.isExpanded(override: nil, activity: .downloading(repo: "a/b"), lines: []))
    }

    // MARK: Log

    func testLogExpandsOnlyWhileDownloadingOrInstalling() {
        XCTAssertTrue(IntakeLogPresentation.autoExpands(.downloading(repo: "a/b")))
        XCTAssertTrue(IntakeLogPresentation.autoExpands(.installing(backend: "mlx-lm")))
        for activity: IntakeCoordinator.Activity in [.idle, .resolving, .analyzing, .drafting, .failed("x")] {
            XCTAssertFalse(IntakeLogPresentation.autoExpands(activity))
        }
    }

    func testLogIsVisibleWithLinesOrWhileItIsBeingWritten() {
        XCTAssertFalse(IntakeLogPresentation.isVisible(activity: .idle, lines: []))
        XCTAssertTrue(IntakeLogPresentation.isVisible(activity: .idle, lines: ["done"]))
        XCTAssertTrue(IntakeLogPresentation.isVisible(activity: .downloading(repo: "a/b"), lines: []))
        XCTAssertEqual(IntakeLogPresentation.title(.downloading(repo: "a/b")), "Download log")
        XCTAssertEqual(IntakeLogPresentation.title(.installing(backend: "mlx-lm")), "Install log")
        XCTAssertEqual(IntakeLogPresentation.title(.idle), "Log")
    }
}

// MARK: - Source

final class IntakeSourceTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mlx-mac/UI/Views/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheWindowDoesNotRepeatItsTitleOrFixTheLabelColumn() throws {
        let sheet = try source("IntakeSheet.swift")
        XCTAssertNil(sheet.range(of: #"Text\("Add from Hugging Face"\)\s*\.font\(WorkbenchTypography\.title\)"#, options: .regularExpression))
        XCTAssertFalse(sheet.contains("frame(width: 80"))
        XCTAssertFalse(try source("PortAnalysisPanel.swift").contains("frame(width: 80"))
        XCTAssertFalse(sheet.contains("minWidth: 640"))
    }

    func testNoRawEnumStringReachesABadge() throws {
        let sheet = try source("IntakeSheet.swift")
        XCTAssertFalse(sheet.contains("StatusBadge"))
        XCTAssertNil(sheet.range(of: #"StatusBadge\([^)]*\.rawValue"#, options: .regularExpression))
    }

    func testOnlyTheFitViewObservesTheMemoryMonitorAndOneButtonIsProminent() throws {
        let sheet = try source("IntakeSheet.swift")
        XCTAssertEqual(sheet.components(separatedBy: "@ObservedObject var resources").count - 1, 1)
        let actions = try XCTUnwrap(sheet.range(of: "switch resolution.verdict {"))
        let branches = sheet[actions.upperBound...].components(separatedBy: "\n            case ").dropFirst()
        var prominent: [String: Int] = [:]
        for branch in branches.prefix(5) {
            let name = String(branch.prefix(while: { $0 != ":" }))
            prominent[name] = branch.components(separatedBy: ".borderedProminent").count - 1
        }
        XCTAssertEqual(prominent[".convertibleAfterInstall"], 1)
        XCTAssertEqual(prominent[".convertible"], 1)
        XCTAssertEqual(prominent[".gguf"], 1)
        XCTAssertEqual(prominent[".alreadyMLX"], 2, "install or download, never both")
        XCTAssertEqual(prominent[".unknown"], 0)
    }

    func testTheLogIsNotDumpedBeneathTheResult() throws {
        let sheet = try source("IntakeSheet.swift")
        XCTAssertFalse(sheet.contains("intake.logTail.joined"))
        XCTAssertTrue(sheet.contains("IntakeLogDisclosure("))
    }
}

// MARK: - Renders

@MainActor
final class IntakeRenderTests: XCTestCase {
    private typealias F = IntakeFixtures

    private func config() -> Config {
        Config(
            schemaVersion: Config.SCHEMA_VERSION, ggufRoots: ["/m"], mlxRoots: [], outputDir: "/out/mlx",
            mlxAgentPath: "/agent", quarantineDir: "/quarantine", qBits: 4, signatures: true, host: "127.0.0.1",
            port: 8765, verificationEnabled: true, watchEnabled: true, fitReserveGB: 4, reclaimStaleDays: 60,
            comparisonMaxTokens: 512
        )
    }

    private func host(library: [LibraryModel]) -> AppHost {
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
        host.librarySnapshot = F.snapshot(library)
        return host
    }

    private func monitor() async -> SystemResourceMonitor {
        let reading = F.live
        let monitor = SystemResourceMonitor(probe: { reading })
        await monitor.refreshMemory()
        return monitor
    }

    private func attach<Content: View>(_ view: Content, name: String, viewport: CGFloat, dark: Bool, height: CGFloat = 760) async throws {
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
        attachment.name = "intake-\(name)-\(dark ? "dark" : "light")-\(Int(viewport))"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct Scenario {
        let name: String
        let spec: F.Spec?
        var library: [LibraryModel] = []
        var phase: Phase = .resolved
        var memory: Memory = .live
    }

    private enum Memory {
        case live, loading, unavailable
    }

    private enum Phase {
        case idle, resolving, resolved, failed, downloading
    }

    private func makeCoordinator(_ scenario: Scenario, log: String) throws -> IntakeCoordinator {
        let resolution = try scenario.spec.map { try F.resolution($0) }
        let job = FetchJob(
            receipt: "r", repo: resolution?.source.repo, revision: "main", file: nil, subfolder: nil, localDir: nil,
            state: "running", path: nil, logPath: log, startedAt: nil, completedAt: nil
        )
        let api = IntakeAPI.stub(
            resolve: { _ in
                switch scenario.phase {
                case .resolving:
                    try await Task.sleep(for: .seconds(3600))
                    throw IntakeStubError.unused
                case .failed:
                    throw IntakeStubError.unused
                default:
                    return try XCTUnwrap(resolution)
                }
            },
            fetchPreview: { _ in ["preview_hash": "h"] },
            fetchStart: { _, _ in [:] },
            fetchStatus: { [job] }
        )
        let intake = IntakeCoordinator(api: api, pollInterval: .seconds(3600), pollLimit: 3)
        intake.sourceText = resolution?.source.reference ?? "mlx-community/Qwen3-8B-4bit"
        return intake
    }

    func testEveryStateRendersDarkAndLightAtEveryWidth() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MLX_WORKBENCH_RENDERS"] == "1")
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("intake-render-\(UUID().uuidString).log")
        try "Fetching 12 files\nmodel-00001-of-00004.safetensors 41%\nmodel-00002-of-00004.safetensors 12%".write(to: log, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: log) }

        let components = """
        [{"role":"model","config_key":null,"model_type":"audio8_asr_infinite","matches":[]},
         {"role":"audio","config_key":null,"model_type":"whisper","matches":[{"backend":"mlx-audio","category":"stt","match":"exact","module":"mlx_audio.stt.models.whisper"}]}]
        """
        let gguf = #"[{"name":"model-Q4_K_M.gguf","bytes":4900000000},{"name":"model-Q8_0.gguf","bytes":8700000000}]"#
        let scenarios = [
            Scenario(name: "idle", spec: nil, phase: .idle),
            Scenario(name: "resolving", spec: nil, phase: .resolving),
            Scenario(name: "convertible", spec: F.Spec(downloadBytes: 16_400_000_000)),
            Scenario(
                name: "convertible-after-install",
                spec: F.Spec(verdict: "convertible_after_install", backend: "mlx-audio", backendInstalled: false, modelType: "audio8_asr_infinite", task: "speech_to_text", components: components)
            ),
            Scenario(
                name: "already-mlx-in-library",
                spec: F.Spec(verdict: "already_mlx", bytes: 4_800_000_000, downloadBytes: 4_800_000_000, estimates: "null"),
                library: [F.model(F.cachePath)]
            ),
            Scenario(name: "gguf", spec: F.Spec(verdict: "gguf", backend: nil, estimates: "null", gguf: gguf)),
            Scenario(
                name: "blocked",
                spec: F.Spec(verdict: "blocked", backend: nil, estimates: "null", reasons: #"["gated","custom_code"]"#, warnings: #"["Large repository."]"#)
            ),
            Scenario(name: "failed", spec: nil, phase: .failed),
            Scenario(name: "downloading", spec: F.Spec(), phase: .downloading),
            Scenario(name: "fit-loading", spec: F.Spec(), memory: .loading),
            Scenario(name: "fit-unavailable", spec: F.Spec(), memory: .unavailable),
        ]
        let live = await monitor()
        let loading = SystemResourceMonitor(probe: { nil })
        let unavailable = SystemResourceMonitor(probe: { nil })
        await unavailable.refreshMemory()
        for scenario in scenarios {
            let resources: SystemResourceMonitor
            switch scenario.memory {
            case .live: resources = live
            case .loading: resources = loading
            case .unavailable: resources = unavailable
            }
            for dark in [true, false] {
                for width in [CGFloat(720), 560] {
                    let intake = try makeCoordinator(scenario, log: log.path)
                    var work: Task<Void, Never>?
                    switch scenario.phase {
                    case .idle:
                        break
                    case .resolving:
                        work = Task { await intake.resolve() }
                    case .resolved, .failed:
                        await intake.resolve()
                    case .downloading:
                        await intake.resolve()
                        work = Task { _ = await intake.download(localDir: nil) }
                    }
                    for _ in 0..<200 {
                        if scenario.phase == .resolving, intake.activity == .resolving { break }
                        if scenario.phase == .downloading, !intake.logTail.isEmpty { break }
                        if scenario.phase != .resolving, scenario.phase != .downloading { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let sheet = IntakeSheet(intake: intake, appHost: host(library: scenario.library), resources: resources, onRouteSelection: { _ in })
                    try await attach(sheet, name: scenario.name, viewport: width, dark: dark)
                    work?.cancel()
                }
            }
        }
    }
}
