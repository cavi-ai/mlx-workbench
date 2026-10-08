import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

final class LibraryRemodelTests: XCTestCase {
    private let hardware = HardwareProfile(chip: "M4", model: "Mac16,1", memoryBytes: 64_000_000_000, macOSVersion: "14.0")
    private let reserveGB = 4.0
    private let context = FitAdvisor.defaultContextTokens
    private let stamp = Date(timeIntervalSinceReferenceDate: 1_000_000_000)

    // MARK: - Symbol vocabulary

    func testSymbolVocabularyPinsAllElevenNamesAndEachResolves() {
        let expected: [ModelTaskType: String] = [
            .textLLM: "text.bubble",
            .visionLanguage: "eye",
            .speechToText: "waveform",
            .textToSpeech: "speaker.wave.2",
            .musicGeneration: "music.note",
            .embedding: "point.3.connected.trianglepath.dotted",
            .classification: "tag",
            .imageGeneration: "photo",
            .videoGeneration: "film",
            .speculativeDraft: "bolt",
            .other: "cube",
        ]
        XCTAssertEqual(ModelTaskType.allCases.count, 11)
        XCTAssertEqual(Set(ModelTaskType.allCases), Set(expected.keys))
        for type in ModelTaskType.allCases {
            XCTAssertEqual(type.symbolName, expected[type], type.rawValue)
            XCTAssertNotNil(NSImage(systemSymbolName: type.symbolName, accessibilityDescription: nil), type.symbolName)
        }
    }

    func testRowWithoutATaskUsesTheOtherSymbol() {
        let row = LibraryRow.variant(model(path: "/m/a.gguf", type: nil))
        XCTAssertEqual(row.taskType, .other)
        XCTAssertEqual(row.taskType.symbolName, "cube")
    }

    // MARK: - Tone owner

    func testToneOwnerMapsEveryToneToItsColor() {
        XCTAssertEqual(ModelBudgetPresentation.Tone.fits.color, WorkbenchColor.accent)
        XCTAssertEqual(ModelBudgetPresentation.Tone.tight.color, WorkbenchColor.warning)
        XCTAssertEqual(ModelBudgetPresentation.Tone.wontFit.color, WorkbenchColor.failure)
        XCTAssertEqual(ModelBudgetPresentation.Tone.neutral.color, WorkbenchColor.muted)
    }

    // MARK: - Fit states

    func testFitsTightAndWontFitUseOverviewWordsAndConsistentFill() {
        let chat = model(path: "/m/chat.gguf", type: .textLLM, bytes: 8_000_000_000, parameters: "8B")
        let fits = fit(chat, memory: snapshot(available: 40_000_000_000))
        let tight = fit(chat, memory: snapshot(available: 15_500_000_000))
        let wont = fit(chat, memory: snapshot(available: 8_000_000_000))

        XCTAssertEqual([fits.word, tight.word, wont.word], ["Fits", "Tight", "Won't fit"])
        XCTAssertEqual([fits.tone, tight.tone, wont.tone], [.fits, .tight, .wontFit])
        XCTAssertEqual([fits.state, tight.state, wont.state], [.estimated, .estimated, .estimated])
        XCTAssertFalse([fits.word, tight.word, wont.word].contains("Too big"))

        let fitsFill = try! XCTUnwrap(fits.fill)
        let tightFill = try! XCTUnwrap(tight.fill)
        let wontFill = try! XCTUnwrap(wont.fill)
        XCTAssertLessThanOrEqual(fitsFill, 0.85)
        XCTAssertGreaterThan(tightFill, 0.85)
        XCTAssertLessThanOrEqual(tightFill, 1)
        XCTAssertEqual(wontFill, 1)
    }

    func testBudgetAtOrBelowZeroIsAFullWontFitGauge() {
        let chat = model(path: "/m/chat.gguf", type: .textLLM, bytes: 8_000_000_000, parameters: "8B")
        for available in [Int64(4_000_000_000), 3_000_000_000, 0] {
            let presentation = fit(chat, memory: snapshot(available: available))
            XCTAssertEqual(presentation.word, "Won't fit", "\(available)")
            XCTAssertEqual(presentation.fill, 1, "\(available)")
        }
    }

    func testUnsupportedTypeAndZeroBytesAreMutedDashesWithAReason() {
        let speech = model(path: "/m/tts.gguf", type: .textToSpeech, bytes: 1_000_000_000)
        let speechFit = fit(speech, memory: snapshot(available: 40_000_000_000))
        XCTAssertEqual(speechFit.state, .notEstimated)
        XCTAssertEqual(speechFit.word, "—")
        XCTAssertNil(speechFit.fill)
        XCTAssertEqual(speechFit.help, "Fit not estimated for text-to-speech models")

        let empty = model(path: "/m/empty.gguf", type: .textLLM, bytes: 0)
        let emptyFit = fit(empty, memory: snapshot(available: 40_000_000_000))
        XCTAssertEqual(emptyFit.state, .notEstimated)
        XCTAssertEqual(emptyFit.word, "—")
        XCTAssertEqual(emptyFit.help, "Fit not estimated: model size unavailable")
        XCTAssertEqual(emptyFit.accessibilityLabel, "Fits now: Fit not estimated: model size unavailable")

        let beforeProbe = fit(speech, memory: nil, hasProbed: false)
        XCTAssertEqual(beforeProbe.state, .notEstimated)
    }

    func testMemoryNotYetReadIsRedactedAndAFailedReadIsUnavailable() {
        let chat = model(path: "/m/chat.gguf", type: .textLLM, bytes: 8_000_000_000, parameters: "8B")
        let loading = fit(chat, memory: nil, hasProbed: false)
        XCTAssertEqual(loading.state, .redacted)
        XCTAssertNil(loading.fill)

        let failed = fit(chat, memory: nil, hasProbed: true)
        XCTAssertEqual(failed.state, .unavailable)
        XCTAssertEqual(failed.word, "Unavailable")
        XCTAssertNil(failed.fill)
        XCTAssertEqual(failed.accessibilityLabel, "Fits now: memory reading unavailable")
    }

    func testFamilyRowShowsItsBestVariantAndBucketRowsShowNone() {
        let small = model(path: "/m/small.gguf", type: .textLLM, bytes: 4_000_000_000, parameters: "8B", name: "Small")
        let large = model(path: "/m/large.gguf", type: .textLLM, bytes: 30_000_000_000, parameters: "8B", name: "Large")
        let memory = snapshot(available: 20_000_000_000)

        let best = LibraryFitPresentation.best(of: [large, small], memory: memory, hasProbed: true, contextTokens: context, reserveGB: reserveGB, hardware: hardware)
        XCTAssertEqual(best?.word, "Fits")
        XCTAssertEqual(best, fit(small, memory: memory))

        let groups = groups(of: [small, large], family: "Family")
        let familyRows = LibraryTablePresentation.rows(groups: groups, sortOrder: [])
        XCTAssertEqual(familyRows.count, 1)
        XCTAssertTrue(familyRows[0].isFamily)
        XCTAssertFalse(familyRows[0].isBucket)
        XCTAssertEqual(Set(familyRows[0].fitModels.map(\.item.path)), ["/m/small.gguf", "/m/large.gguf"])

        let typeRows = LibraryTablePresentation.typeRows(groups: groups, sortOrder: [])
        XCTAssertFalse(typeRows.isEmpty)
        XCTAssertTrue(typeRows.allSatisfy(\.isBucket))
        XCTAssertTrue((typeRows.first?.children ?? []).allSatisfy(\.isBucket))
        XCTAssertEqual(typeRows.first?.fitSortKey, Int64.max)
    }

    // MARK: - Sort key

    func testFitSortKeyIsMemoryIndependentAndOrdersByEstimatedNeed() {
        let models = [
            model(path: "/m/big.gguf", type: .textLLM, bytes: 30_000_000_000, parameters: "8B", name: "Big"),
            model(path: "/m/tts.gguf", type: .textToSpeech, bytes: 1_000_000_000, name: "Speech"),
            model(path: "/m/small.gguf", type: .textLLM, bytes: 2_000_000_000, parameters: "8B", name: "Small"),
            model(path: "/m/mid.gguf", type: .textLLM, bytes: 12_000_000_000, parameters: "8B", name: "Mid"),
        ]
        let rows = LibraryTablePresentation.rows(
            groups: models.flatMap { groups(of: [$0], family: $0.displayName) },
            sortOrder: [KeyPathComparator(\LibraryRow.fitSortKey)]
        )
        XCTAssertEqual(rows.map(\.name), ["Small", "Mid", "Big", "Speech"])
        XCTAssertEqual(rows[0].fitSortKey, FitAdvisor.neededBytes(modelBytes: 2_000_000_000, contextTokens: context, parameters: "8B"))
        XCTAssertEqual(rows[3].fitSortKey, Int64.max)

        let snapshots = [snapshot(available: 60_000_000_000), snapshot(available: 18_000_000_000)]
        var orders: [[String]] = []
        for memory in snapshots {
            let presentations = rows.map {
                LibraryFitPresentation.best(of: $0.fitModels, memory: memory, hasProbed: true, contextTokens: context, reserveGB: reserveGB, hardware: hardware)!
            }
            let ranks = presentations.map(\.rank)
            XCTAssertEqual(ranks, ranks.sorted(), "fits < tight < won't fit < unknown under \(memory.availableBytes)")
            XCTAssertEqual(presentations.last?.state, .notEstimated)
            orders.append(rows.map(\.id))
        }
        XCTAssertEqual(orders[0], orders[1])
        XCTAssertEqual(Set(snapshots.map { snapshotRanks(rows, memory: $0) }).count, 2, "the two snapshots must produce different verdicts")
    }

    private func snapshotRanks(_ rows: [LibraryRow], memory: MemorySnapshot) -> [Int] {
        rows.map {
            LibraryFitPresentation.best(of: $0.fitModels, memory: memory, hasProbed: true, contextTokens: context, reserveGB: reserveGB, hardware: hardware)!.rank
        }
    }

    func testAnimationKeyIgnoresProbesThatKeepTheVerdict() {
        let chat = model(path: "/m/chat.gguf", type: .textLLM, bytes: 8_000_000_000, parameters: "8B")
        let first = fit(chat, memory: snapshot(available: 40_000_000_000))
        let second = fit(chat, memory: snapshot(available: 40_050_000_000))
        XCTAssertEqual(first.fill, second.fill, "ordinary drift between probes leaves the gauge still")
        XCTAssertEqual(first.animationKey, second.animationKey)
        XCTAssertEqual(LibraryFitPresentation.quantized(0.30), LibraryFitPresentation.quantized(0.31))
        XCTAssertNotEqual(LibraryFitPresentation.quantized(0.30), LibraryFitPresentation.quantized(0.40))
        let halved = fit(chat, memory: snapshot(available: 20_000_000_000))
        XCTAssertNotEqual(first.fill, halved.fill)
        XCTAssertEqual(first.animationKey, halved.animationKey, "a probe that keeps the verdict never animates the gauge")

        let tight = fit(chat, memory: snapshot(available: 15_500_000_000))
        XCTAssertNotEqual(first.animationKey, tight.animationKey)

        let longer = LibraryFitPresentation.make(model: chat, memory: snapshot(available: 40_000_000_000), hasProbed: true, contextTokens: context * 2, reserveGB: reserveGB, hardware: hardware)
        XCTAssertNotEqual(first.animationKey, longer.animationKey)
    }

    // MARK: - Column tiers

    func testColumnTiersFollowTheThresholds() {
        func tier(_ width: CGFloat) -> LibraryColumnTier { .resolve(width: width) }
        XCTAssertEqual(tier(800), LibraryColumnTier(showsModified: true, showsSizeBar: true, showsStatus: true, showsGauge: true, showsQuant: true, showsSize: true))
        XCTAssertFalse(tier(779).showsModified)
        XCTAssertTrue(tier(779).showsSizeBar)
        XCTAssertFalse(tier(699).showsSizeBar)
        XCTAssertTrue(tier(699).showsStatus)
        XCTAssertFalse(tier(639).showsStatus)
        XCTAssertTrue(tier(639).showsGauge)
        XCTAssertFalse(tier(519).showsGauge)
        XCTAssertTrue(tier(519).showsQuant)
        XCTAssertFalse(tier(439).showsQuant)
        XCTAssertTrue(tier(439).showsSize)
        XCTAssertFalse(tier(349).showsSize)
        XCTAssertEqual(tier(779).showsModified, false)
        XCTAssertEqual(tier(780).showsModified, true)
        let narrowest = tier(179)
        XCTAssertEqual(narrowest, LibraryColumnTier(showsModified: false, showsSizeBar: false, showsStatus: false, showsGauge: false, showsQuant: false, showsSize: false))
    }

    func testColumnTierHysteresisKeepsAHiddenColumnHiddenUntilItClearsTheThreshold() {
        let wide = LibraryColumnTier.resolve(width: 800)
        let narrowed = LibraryColumnTier.resolve(width: 770, previous: wide)
        XCTAssertFalse(narrowed.showsModified)
        let hovering = LibraryColumnTier.resolve(width: 785, previous: narrowed)
        XCTAssertFalse(hovering.showsModified, "within 16 pt of the threshold the column stays hidden")
        let cleared = LibraryColumnTier.resolve(width: 796, previous: narrowed)
        XCTAssertTrue(cleared.showsModified)
        let stillShown = LibraryColumnTier.resolve(width: 780, previous: cleared)
        XCTAssertTrue(stillShown.showsModified)
    }

    // MARK: - Row text

    func testSublineKeepsLocationInInspector() {
        let local = model(path: "/vault/gguf/llama.gguf", type: .textLLM, name: "Llama")
        XCTAssertEqual(LibraryTablePresentation.subline(for: local), "Text LLM")

        let repeated = model(path: "/vault/Llama/llama.gguf", type: .textLLM, name: "Llama")
        XCTAssertEqual(LibraryTablePresentation.subline(for: repeated), "Text LLM")

        let cached = model(path: "/Users/x/.cache/huggingface/hub/models--org--name/snapshots/abc/config.json", type: .visionLanguage, name: "org/name")
        XCTAssertEqual(LibraryTablePresentation.subline(for: cached), "Vision-language")

        let untyped = model(path: "/vault/gguf/x.gguf", type: nil, name: "X")
        XCTAssertEqual(LibraryTablePresentation.subline(for: untyped), "")
    }

    func testBrowsingFamilyHeadingsCombineSizesAndKeepSingleModelsGrouped() {
        let small = model(path: "/m/Qwen3-4B-4bit", type: .textLLM, name: "org/Qwen3-4B-4bit")
        let large = model(path: "/m/Qwen3-8B-8bit", type: .textLLM, name: "org/Qwen3-8B-8bit")
        let llama = model(path: "/m/Llama-3B", type: .textLLM, name: "Llama-3B")
        let source = [small, large, llama].flatMap { groups(of: [$0], family: $0.displayName) }
        let rows = LibraryTablePresentation.familyRows(groups: source, sortOrder: [])
        XCTAssertEqual(rows.map(\.name), ["Llama", "Qwen3"])
        XCTAssertTrue(rows.allSatisfy(\.isFamily))
        XCTAssertEqual(rows[0].children?.count, 1)
        XCTAssertEqual(rows[1].children?.map(\.name), ["Qwen3-4B-4bit", "Qwen3-8B-8bit"])
        XCTAssertEqual(Set(rows.flatMap(\.fitModels).map(\.item.path)), Set([small, large, llama].map(\.item.path)))
        let snapshot = LibrarySnapshot(models: [small, large, llama], groups: source.map(\.sourceGroup), hardware: hardware, generatedAt: stamp)
        XCTAssertEqual(LibraryPresentation.summary(for: snapshot, familyCount: rows.count).families, 2)
    }

    @MainActor
    func testLibraryAndSidebarRenderAtCompactAndWideWindowSizes() async throws {
        let host = AppHost(config: Config.defaults(), hardwareProfile: hardware)
        let models = [
            model(path: "/m/Qwen3-4B-4bit", type: .textLLM, name: "mlx-community/Qwen3-4B-4bit"),
            model(path: "/m/Qwen3-8B-8bit", type: .textLLM, name: "mlx-community/Qwen3-8B-8bit"),
            model(path: "/m/Llama-3B", type: .textLLM, name: "Llama-3B"),
        ]
        host.librarySnapshot = LibrarySnapshot(models: models, groups: models.map {
            ModelGroup(variants: [$0], normalizedModelKey: $0.item.path, primaryDisplayName: $0.displayName)
        }, hardware: hardware, totalBytes: models.reduce(0) { $0 + $1.item.bytes }, generatedAt: stamp)
        for width in [960.0, 1440.0] {
            let root = NavigationSplitView {
                AppSidebar(selectedRoute: .constant(.library)).navigationSplitViewColumnWidth(210)
            } detail: {
                LibraryView(appHost: host).environment(\.isRouteActive, true)
            }.frame(width: width, height: 760).preferredColorScheme(.dark)
            let view = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(250))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "Library and sidebar at \(Int(width)) pt"; attachment.lifetime = .keepAlways
            add(attachment)
            if let directory = ProcessInfo.processInfo.environment["MLX_UI_EVIDENCE_DIR"] {
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("library-\(Int(width)).png"))
            }
            window.close()
        }
    }

    func testModifiedIsARelativeDateAndADashWhenUnknown() {
        XCTAssertEqual(LibraryTablePresentation.modifiedText(nil), "—")
        let text = LibraryTablePresentation.modifiedText(stamp, now: stamp.addingTimeInterval(2 * 86_400))
        XCTAssertFalse(text.isEmpty)
        XCTAssertNotEqual(text, "—")
    }

    func testMagnitudeScaleIsTheLargestLeafNotAFamilyTotal() {
        let small = model(path: "/m/s.gguf", type: .textLLM, bytes: 1_000, name: "S")
        let large = model(path: "/m/l.gguf", type: .textLLM, bytes: 4_000, name: "L")
        let rows = LibraryTablePresentation.rows(groups: groups(of: [small, large], family: "Fam"), sortOrder: [])
        XCTAssertEqual(rows[0].bytes, 5_000)
        XCTAssertEqual(LibraryTablePresentation.largestLeafBytes(in: rows), 4_000)
        XCTAssertEqual(LibraryTablePresentation.largestLeafBytes(in: []), 0)
    }

    // MARK: - Inspector text

    func testHeaderLinesDropSizeThenQuantAndOmitUnknownParts() {
        let full = model(path: "/m/a.gguf", type: .textLLM, bytes: 1_000_000_000, quantization: "Q4_K_M")
        let lines = ModelDetailsPresentation.headerLines(for: full)
        XCTAssertEqual(lines, [
            "Text LLM · Q4_K_M · " + LibraryTablePresentation.byteCount(1_000_000_000),
            "Text LLM · Q4_K_M",
            "Text LLM",
        ])
        XCTAssertEqual(ModelDetailsPresentation.headerLine(for: full), lines[0])

        let bare = model(path: "/m/b.gguf", type: nil, bytes: 1_000_000_000, quantization: nil)
        XCTAssertEqual(ModelDetailsPresentation.headerLines(for: bare), [LibraryTablePresentation.byteCount(1_000_000_000)])
    }

    func testDetailsKeepEveryIdentityRowAndOnlyDropUnknownAndHeaderFacts() {
        let source = model(path: "/m/source.gguf", type: .textLLM, bytes: 1_000, parameters: nil, quantization: nil, status: "needs_conversion", architecture: nil)
        let identity = ModelDetailsPresentation.identityRows(for: source, prepareDestination: "/m/out")
        let display = ModelDetailsPresentation.displayRows(for: source, prepareDestination: "/m/out")
        let headerFacts = Set(ModelDetailsPresentation.headerLines(for: source)[0].components(separatedBy: " · "))

        let expectedLabels: [String] = identity
            .filter { $0.value != "Unknown" }
            .filter { !(["Type", "Quantization", "Size"].contains($0.label) && headerFacts.contains($0.value)) }
            .map { $0.label }
        XCTAssertEqual(display.map { $0.label }, expectedLabels)
        XCTAssertTrue(display.contains { $0.label == "Prepare destination" })
        XCTAssertTrue(display.contains { $0.label == "Readiness" })
        XCTAssertFalse(display.contains { $0.value == "Unknown" })
        XCTAssertEqual(display.first { $0.label == "Path" }?.prose, false)
        XCTAssertEqual(display.first { $0.label == "Prepare destination" }?.prose, false)
        XCTAssertEqual(display.first { $0.label == "Readiness" }?.prose, true)
    }

    func testDetailsDoNotRepeatTheHeaderTypeQuantizationAndSize() {
        let chat = model(path: "/m/chat-mlx", type: .textLLM, bytes: 5_420_000_000, quantization: "q4")
        let header = ModelDetailsPresentation.headerLines(for: chat)[0]
        let identity = ModelDetailsPresentation.identityRows(for: chat, prepareDestination: nil)
        let display = ModelDetailsPresentation.displayRows(for: chat, prepareDestination: nil)

        for label in ["Type", "Quantization", "Size"] {
            guard let row = identity.first(where: { $0.label == label }) else { continue }
            if header.components(separatedBy: " · ").contains(row.value) {
                XCTAssertFalse(display.contains { $0.label == label }, "\(label) is already in the header: \(header)")
            } else {
                XCTAssertTrue(display.contains { $0.label == label }, "\(label) differs from the header and stays")
            }
        }
        XCTAssertTrue(identity.contains { $0.label == "Type" }, "identityRows is unchanged")
    }

    func testOutputsRowIsHiddenOnlyWhenItRepeatsThePath() {
        let same = LibraryModel(item: model(path: "/m/out-mlx", type: .textLLM).item, displayName: nil, outputPaths: ["/m/out-mlx"])
        XCTAssertTrue(ModelDetailsPresentation.identityRows(for: same, prepareDestination: nil).contains { $0.label == "Outputs" })
        XCTAssertFalse(ModelDetailsPresentation.displayRows(for: same, prepareDestination: nil).contains { $0.label == "Outputs" })

        let different = LibraryModel(item: model(path: "/m/source.gguf", type: .textLLM).item, displayName: nil, outputPaths: ["/m/out-mlx"])
        XCTAssertEqual(ModelDetailsPresentation.displayRows(for: different, prepareDestination: nil).first { $0.label == "Outputs" }?.value, "/m/out-mlx")
    }

    func testDrafterRowSurvivesIntoDetails() {
        let drafter = model(path: "/m/draft.gguf", type: .speculativeDraft, draftTarget: "Target")
        let display = ModelDetailsPresentation.displayRows(for: drafter, prepareDestination: nil)
        XCTAssertTrue(display.contains { $0.label == "Drafter for" })
    }

    // MARK: - Next action with no snapshot

    func testCompletedWorkflowWithoutASnapshotFallsThroughToTheScanChain() {
        let completed = workflow(state: .completed, completedModelPath: "/models/atlas-mlx")

        let scanning = derive(workflow: completed, snapshot: nil, isScanning: true)
        XCTAssertEqual(scanning.title, "View library scan")
        XCTAssertEqual(scanning.route, AppRoute.library.rawValue)

        let idle = derive(workflow: completed, snapshot: nil, isScanning: false)
        XCTAssertEqual(idle.title, "Scan the model library")
        XCTAssertEqual(idle.route, AppRoute.library.rawValue)

        let noRoots = derive(workflow: completed, snapshot: nil, rootsConfigured: false)
        XCTAssertEqual(noRoots.title, "Configure model roots")
        XCTAssertEqual(noRoots.route, AppRoute.settings.rawValue)

        let noAgent = derive(workflow: completed, snapshot: nil, agentReady: false)
        XCTAssertEqual(noAgent.title, "Configure mlx-agent")

        let failed = derive(workflow: completed, snapshot: nil, lastError: "scan failed")
        XCTAssertEqual(failed.title, "Resolve the library scan")
    }

    // MARK: - Helpers

    private func fit(_ model: LibraryModel, memory: MemorySnapshot?, hasProbed: Bool = true) -> LibraryFitPresentation {
        LibraryFitPresentation.make(model: model, memory: memory, hasProbed: hasProbed, contextTokens: context, reserveGB: reserveGB, hardware: hardware)
    }

    private func snapshot(available: Int64) -> MemorySnapshot {
        MemorySnapshot(totalBytes: 64_000_000_000, availableBytes: available)
    }

    private func groups(of models: [LibraryModel], family: String) -> [LibraryGroupViewModel] {
        let group = ModelGroup(variants: models, normalizedModelKey: family.lowercased(), primaryDisplayName: family)
        return [LibraryGroupViewModel(sourceGroup: group, variants: models)]
    }

    private func model(
        path: String,
        type: ModelTaskType?,
        bytes: Int64 = 1_000_000_000,
        parameters: String? = "8B",
        quantization: String? = "Q4_K_M",
        status: String = "ready",
        architecture: String? = "llama",
        name: String? = nil,
        draftTarget: String? = nil
    ) -> LibraryModel {
        let item = ModelItem(
            path: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            bytes: bytes,
            modifiedAt: nil,
            shard: nil,
            modelKey: "key",
            architecture: architecture,
            quantization: quantization,
            parameters: parameters,
            structure: nil,
            signature: nil,
            companion: nil,
            readable: true,
            status: status,
            outputs: [],
            tensorCount: nil,
            error: nil,
            task: type.map { ModelTask(type: $0, useCases: [], source: "registry", confidence: "confirmed") },
            draft: draftTarget.map { ModelDraft(port: nil, target: $0, blockSize: nil) }
        )
        return LibraryModel(item: item, displayName: name)
    }

    private func derive(
        workflow: ConversionWorkflow,
        snapshot: LibrarySnapshot?,
        rootsConfigured: Bool = true,
        isScanning: Bool = false,
        lastError: String? = nil,
        agentReady: Bool = true
    ) -> HomeNextAction {
        HomeNextAction.derive(
            workflow: workflow,
            snapshot: snapshot,
            rootsConfigured: rootsConfigured,
            isScanning: isScanning,
            lastError: lastError,
            agentReady: agentReady,
            convertRuntimeReady: true,
            serveRuntimeReady: true
        )
    }

    private func workflow(state: ConversionWorkflowState, completedModelPath: String?) -> ConversionWorkflow {
        ConversionWorkflow(
            id: UUID(),
            sourcePath: "/models/source.gguf",
            sourceModelKey: nil,
            sourceSignature: nil,
            outputPath: "/models/out",
            previewHash: nil,
            jobReceipt: nil,
            completedModelPath: completedModelPath,
            state: state,
            serveState: .idle,
            message: nil,
            errorMessage: nil,
            createdAt: stamp,
            updatedAt: stamp,
            lastKnownAgentState: nil
        )
    }
}
