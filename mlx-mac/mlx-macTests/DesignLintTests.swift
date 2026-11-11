import XCTest
import AppKit
import SwiftUI

@testable import mlx_workbench

/// Static checks over the SwiftUI sources so the design tokens stay the only
/// way to pick a font, a color, a spacing, a radius, a tint or a curve, and
/// routes stay typed.
final class DesignLintTests: XCTestCase {
    /// Contrast is checked after appearance resolution, including the
    /// foreground used by the custom yellow primary action.
    @MainActor
    func testBrandPaletteKeepsReadableTextInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let window = resolved(NSColor.windowBackgroundColor, in: appearance)
            for background in [WorkbenchColor.surface, WorkbenchColor.well] {
                let base = resolved(background, in: appearance).composited(over: window)
                XCTAssertGreaterThanOrEqual(ratio(resolved(WorkbenchColor.ink, in: appearance), base), 4.5, name.rawValue)
                XCTAssertGreaterThanOrEqual(ratio(resolved(WorkbenchColor.accent, in: appearance), base), 4.5, name.rawValue)
            }
            XCTAssertGreaterThanOrEqual(ratio(resolved(WorkbenchColor.ink, in: appearance), window), 4.5, name.rawValue)
            XCTAssertGreaterThanOrEqual(ratio(resolved(WorkbenchColor.accent, in: appearance), window), 4.5, name.rawValue)
            let action = resolved(WorkbenchColor.action, in: appearance)
            let pressed = resolved(WorkbenchColor.actionPressed, in: appearance)
            let onAccent = resolved(WorkbenchColor.onAccent, in: appearance)
            XCTAssertGreaterThanOrEqual(ratio(onAccent, action), 7, name.rawValue)
            XCTAssertGreaterThanOrEqual(ratio(onAccent, pressed), 7, name.rawValue)
        }
    }

    @MainActor
    func testSurfaceAndWellStepAboveTheSystemWindowBackground() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let window = resolved(NSColor.windowBackgroundColor, in: appearance)
            let surface = resolved(WorkbenchColor.surface, in: appearance).composited(over: window)
            let well = resolved(WorkbenchColor.well, in: appearance).composited(over: window)
            let surfaceRatio = ratio(surface, window), wellRatio = ratio(well, window)
            print("DESIGN-LINT \(name.rawValue) surface=\(surfaceRatio) well=\(wellRatio)")
            XCTAssertGreaterThanOrEqual(surfaceRatio, 1.1, name.rawValue)
            XCTAssertGreaterThan(wellRatio, surfaceRatio, name.rawValue)
        }
    }

    @MainActor
    func testAccentAssetMatchesTheBrandAccentInBothAppearances() throws {
        let expected: [(NSAppearance.Name, UInt32)] = [(.aqua, 0x785900), (.darkAqua, 0xFFD43B)]
        for (name, hex) in expected {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let asset = try XCTUnwrap(NSColor(named: "AccentColor"), "AccentColor asset missing")
            let fromAsset = resolved(asset, in: appearance)
            let brand = resolved(WorkbenchColor.accent, in: appearance)
            let target = NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                                 blue: CGFloat(hex & 255) / 255, alpha: 1)
            for (lhs, rhs) in [(fromAsset, brand), (fromAsset, target)] {
                XCTAssertEqual(lhs.redComponent, rhs.redComponent, accuracy: 1.0 / 255, name.rawValue)
                XCTAssertEqual(lhs.greenComponent, rhs.greenComponent, accuracy: 1.0 / 255, name.rawValue)
                XCTAssertEqual(lhs.blueComponent, rhs.blueComponent, accuracy: 1.0 / 255, name.rawValue)
            }
        }
    }

    @MainActor
    func testWindowRootFollowsTheSystemAppearance() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = try XCTUnwrap(NSAppearance(named: name))
            let hosting = NSHostingView(rootView: Text("Root").workbenchTheme())
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            XCTAssertEqual(hosting.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), name, name.rawValue)
        }
    }

    @MainActor
    func testSelectionForegroundIsReadableOnTheSelectionFill() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let fill = resolved(NSColor.selectedContentBackgroundColor, in: appearance)
            let selection = ratio(resolved(WorkbenchColor.onSelection, in: appearance), fill)
            let accentFill = ratio(resolved(WorkbenchColor.onAccentFill, in: appearance),
                                   resolved(WorkbenchColor.accent, in: appearance))
            print("DESIGN-LINT \(name.rawValue) onSelection=\(selection) onAccentFill=\(accentFill)")
            XCTAssertGreaterThanOrEqual(selection, 4.5, name.rawValue)
            XCTAssertGreaterThanOrEqual(accentFill, 4.5, name.rawValue)
        }
    }

    @MainActor
    private func resolved(_ color: Color, in appearance: NSAppearance) -> NSColor {
        var result = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            let value = NSColor(color)
            result = value.usingColorSpace(.sRGB) ?? value
        }
        return result
    }

    @MainActor
    private func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    private func ratio(_ foreground: NSColor, _ background: NSColor) -> Double {
        let a = foreground.composited(over: background).luminance, b = background.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private struct Rule {
        let pattern: String
        let reason: String
        var allowedFiles: Set<String> = []
        var isRegex = false
    }

    private static let rules: [Rule] = [
        Rule(pattern: ".font(.", reason: "raw text style; use WorkbenchTypography", allowedFiles: ["DesignSystem.swift"]),
        Rule(pattern: "Font.system(", reason: "raw font; use WorkbenchTypography", allowedFiles: ["DesignSystem.swift"]),
        Rule(pattern: #"Font\.(caption2?|footnote)\b"#, reason: "10-point text style; the floor is 11 points", isRegex: true),
        Rule(pattern: "Color(nsColor:", reason: "raw AppKit color; use WorkbenchColor", allowedFiles: ["DesignSystem.swift"]),
        Rule(pattern: #"Color\.(white|black|gray|red|green|blue|orange|yellow)\b"#, reason: "literal color; use a WorkbenchColor role", allowedFiles: ["DesignSystem.swift"], isRegex: true),
        Rule(pattern: "NSColor(hex", reason: "hex color literal; use WorkbenchColor"),
        Rule(pattern: ".foregroundColor(", reason: "use .foregroundStyle with a WorkbenchColor role"),
        Rule(pattern: ".foregroundStyle(.secondary", reason: "use WorkbenchColor.muted"),
        Rule(pattern: #"spacing: [1-9]"#, reason: "literal spacing; use WorkbenchSpacing", allowedFiles: ["DesignSystem.swift"], isRegex: true),
        Rule(pattern: #"\.padding\(((\.[a-zA-Z]+|\[[^\]]*\]), )?[0-9]"#, reason: "literal padding; use WorkbenchSpacing", allowedFiles: ["DesignSystem.swift"], isRegex: true),
        Rule(pattern: #"cornerRadius: [0-9]"#, reason: "literal radius; use WorkbenchRadius", allowedFiles: ["DesignSystem.swift"], isRegex: true),
        Rule(pattern: #"opacity\([0-9.]+\)"#, reason: "literal opacity; use WorkbenchTint", allowedFiles: ["DesignSystem.swift"], isRegex: true),
        Rule(pattern: ".animation(", reason: "raw animation; use workbenchAnimation with a WorkbenchMotion curve", allowedFiles: ["DesignSystem.swift"]),
        Rule(pattern: ".tracking(", reason: "letter-spaced text; use sentence case with the type token"),
        Rule(pattern: ".kerning(", reason: "letter-spaced text; use sentence case with the type token"),
        Rule(pattern: "onRouteSelection(\"", reason: "route passed as a string; use AppRoute"),
        Rule(pattern: "AnyView(", reason: "type erasure in the view tree; use @ViewBuilder"),
        Rule(pattern: #"\.background\(WorkbenchColor\.canvas(\)|, ignoresSafeAreaEdges)"#,
             reason: "painted canvas; the window and sheets draw their own background", isRegex: true),
        Rule(pattern: #"\.background\s*\{\s*WorkbenchColor\.canvas"#,
             reason: "painted canvas; the window and sheets draw their own background", isRegex: true),
        Rule(pattern: "preferredColorScheme", reason: "forced appearance; the app follows the system appearance"),
    ]

    private static func violations(in line: String, file: String) -> [String] {
        rules.compactMap { rule in
            guard !rule.allowedFiles.contains(file) else { return nil }
            let matches = rule.isRegex
                ? line.range(of: rule.pattern, options: .regularExpression) != nil
                : line.contains(rule.pattern)
            return matches ? rule.reason : nil
        }
    }

    private static var uiDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // mlx-macTests
            .deletingLastPathComponent()   // mlx-mac (project dir)
            .appendingPathComponent("mlx-mac/UI", isDirectory: true)
    }

    private func swiftSources() throws -> [URL] {
        let directory = Self.uiDirectory
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue,
            "UI source directory not found at \(directory.path)"
        )
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    func testUISourcesUseDesignTokensAndTypedRoutes() throws {
        let sources = try swiftSources()
        XCTAssertGreaterThan(sources.count, 10, "expected the UI sources to be enumerated")

        var violations: [String] = []
        for file in sources {
            let name = file.lastPathComponent
            let text = try String(contentsOf: file, encoding: .utf8)
            for (offset, line) in text.components(separatedBy: "\n").enumerated() {
                for reason in Self.violations(in: line, file: name) {
                    violations.append("\(name):\(offset + 1): \(reason) — \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty, "Design lint violations:\n" + violations.joined(separator: "\n"))
    }

    func testLiteralRulesFlagLiteralsAndPassTokens() {
        let flagged = [
            "HStack(spacing: 6) {",
            "VStack(alignment: .leading, spacing: 10) {",
            ".padding(8)",
            ".padding(.top, 14)",
            ".padding([.horizontal, .bottom], 12)",
            "RoundedRectangle(cornerRadius: 3)",
            ".background(WorkbenchColor.accent.opacity(0.05))",
            ".animation(.easeInOut(duration: 0.6), value: fraction)",
            ".foregroundStyle(Color.white)",
            ".fill(Color.orange)",
            "static let metadata = Font.caption",
            "static let note = Font.footnote.monospaced()",
            "Text(\"SERVING MODELS\").tracking(1)",
            "Text(title).font(WorkbenchTypography.metadata).kerning(0.5)",
            ".background(WorkbenchColor.canvas)",
            ".background(WorkbenchColor.canvas, ignoresSafeAreaEdges: .all)",
            ".background { WorkbenchColor.canvas }",
            ".preferredColorScheme(.dark)",
        ]
        for line in flagged {
            XCTAssertFalse(Self.violations(in: line, file: "Sample.swift").isEmpty, "expected a violation: \(line)")
        }

        let clean = [
            "HStack(spacing: WorkbenchSpacing.xs) {",
            "VStack(spacing: 0) {",
            ".padding()",
            ".padding(WorkbenchSpacing.sm)",
            ".padding(.top, WorkbenchSpacing.xs)",
            "RoundedRectangle(cornerRadius: WorkbenchRadius.chip)",
            ".background(WorkbenchColor.accent.opacity(.wash))",
            ".workbenchAnimation(WorkbenchMotion.progress, value: fraction)",
            "view.opacity(phase)",
            ".fill(Color.clear)",
            ".foregroundStyle(WorkbenchColor.onAccent)",
            "static let metadata = Font.subheadline",
            "Text(\"Serving models\").font(WorkbenchTypography.metadata.weight(.semibold))",
            "let trackingRate = measuredTrackingRate",
            ".background(WorkbenchColor.canvas, in: RoundedRectangle(cornerRadius: WorkbenchRadius.control))",
        ]
        for line in clean {
            XCTAssertEqual(Self.violations(in: line, file: "Sample.swift"), [], "unexpected violation: \(line)")
        }
    }
}

private extension NSColor {
    /// This color over an opaque base, in sRGB.
    func composited(over base: NSColor) -> NSColor {
        let fg = usingColorSpace(.sRGB)!, bg = base.usingColorSpace(.sRGB)!
        let alpha = fg.alphaComponent
        return NSColor(srgbRed: fg.redComponent * alpha + bg.redComponent * (1 - alpha),
                       green: fg.greenComponent * alpha + bg.greenComponent * (1 - alpha),
                       blue: fg.blueComponent * alpha + bg.blueComponent * (1 - alpha), alpha: 1)
    }

    /// WCAG relative luminance of an opaque sRGB color.
    var luminance: Double {
        let color = usingColorSpace(.sRGB)!
        let values = [color.redComponent, color.greenComponent, color.blueComponent].map { value -> Double in
            let channel = Double(value)
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
    }
}

final class ModelUpdateReviewPresentationTests: XCTestCase {
    func testUpdateBitsUseRepositoryLimitsAndTheConfiguredGGUFConversionChoices() {
        let repository = review(kind: .repository, bits: 4, supported: [8])
        XCTAssertEqual(ModelUpdateReviewPresentation.bitWidths(repository), [8])
        XCTAssertFalse(ModelUpdateReviewPresentation.canDownload(review: repository, settingsLocked: false))
        let gguf = review(kind: .gguf, bits: 4, supported: [32])
        XCTAssertEqual(ModelUpdateReviewPresentation.bitWidths(gguf), Config.Q_BITS_CHOICES.filter { $0 != 32 }.sorted())
        XCTAssertEqual(ModelUpdateReviewPresentation.bitWidths(review()), [])
    }

    func testRequiredFileProjectorAndSourceConfirmationBlockTheDownloadAction() {
        XCTAssertFalse(ModelUpdateReviewPresentation.canDownload(review: nil, settingsLocked: false))
        XCTAssertFalse(ModelUpdateReviewPresentation.canDownload(review: review(file: nil), settingsLocked: false))
        var missingProjector = review()
        missingProjector.requiresProjector = true
        XCTAssertFalse(ModelUpdateReviewPresentation.canDownload(review: missingProjector, settingsLocked: false))
        missingProjector.projectorFile = "vision/mmproj.gguf"
        missingProjector.additionalFiles = ["vision/mmproj.gguf"]
        XCTAssertTrue(ModelUpdateReviewPresentation.canDownload(review: missingProjector, settingsLocked: false))
        var unrecorded = review()
        var previous = unrecorded.previous
        previous.needsSourceConfirmation = true
        unrecorded = ModelUpdateReview(id: unrecorded.id, repo: unrecorded.repo, previous: previous,
            resolution: unrecorded.resolution, targetRevision: unrecorded.targetRevision,
            destinationPath: unrecorded.destinationPath, previewHash: unrecorded.previewHash, endpointSummary: [])
        XCTAssertFalse(ModelUpdateReviewPresentation.canDownload(review: unrecorded, settingsLocked: false))
        unrecorded.sourceConfirmed = true
        XCTAssertTrue(ModelUpdateReviewPresentation.canDownload(review: unrecorded, settingsLocked: false))
    }

    func testAcceptedOrBusyUpdateSettingsStayFrozen() {
        XCTAssertFalse(ModelUpdateReviewPresentation.settingsLocked(isLoading: false, isPreparing: false, isRunning: false, accepted: false))
        for state in [(true, false, false, false), (false, true, false, false), (false, false, true, false), (false, false, false, true)] {
            let locked = ModelUpdateReviewPresentation.settingsLocked(isLoading: state.0, isPreparing: state.1,
                isRunning: state.2, accepted: state.3)
            XCTAssertTrue(locked)
            XCTAssertFalse(ModelUpdateReviewPresentation.canDownload(review: review(), settingsLocked: locked))
        }
    }

    func testCompanionChoicesExcludeMainProjectorAndAutomaticSplitShards() {
        var split = review(file: "weights-00001-of-00002.gguf", files: [
            "weights-00001-of-00002.gguf", "weights-00002-of-00002.gguf",
            "vision/mmproj.gguf", "audio/encoder.gguf", "audio/decoder.gguf",
        ])
        split.projectorFile = "vision/mmproj.gguf"
        XCTAssertEqual(ModelUpdateReviewPresentation.companionChoices(split).map(\.name), ["audio/encoder.gguf", "audio/decoder.gguf"])
        XCTAssertEqual(ModelUpdateGGUFSelection.shards(main: split.resolution.source.file,
            available: split.resolution.files.gguf.map(\.name)).files, ["weights-00002-of-00002.gguf"])
    }

    func testCompanionSelectionPreservesExplicitEmptyAndFiltersToFiniteChoices() {
        var selected = review(files: ["model.gguf", "vision/mmproj.gguf", "audio/encoder.gguf"])
        selected.projectorFile = "vision/mmproj.gguf"
        selected.additionalFiles = ["vision/mmproj.gguf", "audio/encoder.gguf"]
        XCTAssertEqual(ModelUpdateReviewPresentation.companionSelection(selected, selected: nil), ["audio/encoder.gguf"])
        XCTAssertEqual(ModelUpdateReviewPresentation.companionSelection(selected, selected: []), [])
        XCTAssertEqual(ModelUpdateReviewPresentation.companionSelection(selected,
            selected: ["model.gguf", "vision/mmproj.gguf", "audio/encoder.gguf", "audio/encoder.gguf", "missing.gguf"]),
            ["audio/encoder.gguf"])
    }

    func testMissingRecordedCompanionsRequireExplicitSelectionReview() {
        var missing = review()
        missing.requiredCompanionSelection = true
        XCTAssertFalse(ModelUpdateReviewPresentation.canDownload(review: missing, settingsLocked: false))
        XCTAssertNotNil(missing.missingSelectionReason)
        missing.requiredCompanionSelection = false
        XCTAssertTrue(ModelUpdateReviewPresentation.canDownload(review: missing, settingsLocked: false))
    }

    func testPreparationCorrectionUsesOnlyTheCurrentSupportedWidths() {
        let unsupportedRecipe = review(kind: .repository, bits: 5, supported: [4, 8])
        XCTAssertEqual(ModelUpdateReviewPresentation.preparationRevisionBits(unsupportedRecipe, selected: nil), 4)
        XCTAssertEqual(ModelUpdateReviewPresentation.preparationRevisionBits(unsupportedRecipe, selected: 8), 8)
        XCTAssertEqual(ModelUpdateReviewPresentation.preparationRevisionBits(unsupportedRecipe, selected: 6), 4)
        let gguf = review(kind: .gguf, bits: 5)
        XCTAssertEqual(ModelUpdateReviewPresentation.preparationRevisionBits(gguf, selected: nil), 5)
        XCTAssertEqual(ModelUpdateReviewPresentation.preparationRevisionBits(gguf, selected: 4), 4)
        XCTAssertNil(ModelUpdateReviewPresentation.preparationRevisionBits(review(), selected: 4))
    }

    func testPreparationCorrectionRequiresAnIdleRevisableRecordAndChangedSupportedWidth() {
        let captured = review(kind: .repository, bits: 4, supported: [4, 8])
        XCTAssertTrue(ModelUpdateReviewPresentation.canReviewPreparationSettings(captured, bits: 8,
            canRevise: true, isBusy: false, recoveryPending: false))
        for bits in [nil, 4, 5] as [Int?] {
            XCTAssertFalse(ModelUpdateReviewPresentation.canReviewPreparationSettings(captured, bits: bits,
                canRevise: true, isBusy: false, recoveryPending: false))
        }
        for gate in [(false, false, false), (true, true, false), (true, false, true)] {
            XCTAssertFalse(ModelUpdateReviewPresentation.canReviewPreparationSettings(captured, bits: 8,
                canRevise: gate.0, isBusy: gate.1, recoveryPending: gate.2))
        }
        XCTAssertTrue(ModelUpdateReviewPresentation.settingsLocked(isLoading: false, isPreparing: false,
            isRunning: false, accepted: true), "Preparation correction must not unlock captured source settings")
    }

    func testPreparationActionsKeepDownloadInstallAndConversionAsSeparateReviews() {
        let raw = review()
        let converted = review(kind: .repository)
        XCTAssertEqual(ModelUpdateReviewPresentation.downloadTitle(raw), "Download and verify update")
        XCTAssertEqual(ModelUpdateReviewPresentation.downloadTitle(converted), "Download source for preparation")
        var preparation = ModelUpdatePreparationReview(id: UUID(), previewHash: "preparation", recipe: converted.conversion!,
            repo: converted.repo, sourcePath: "/models/download", outputPath: converted.destinationPath,
            fetchReceipt: "/state/fetch.json", sourceFiles: [.init(path: "/models/download", signature: "source")])
        XCTAssertEqual(ModelUpdateReviewPresentation.preparationTitle(preparation), "Review local conversion")
        XCTAssertEqual(ModelUpdateReviewPresentation.preparationAction(preparation), "Convert and verify update")
        preparation.operation = .installBackend; preparation.backendInstallID = "mlx-lm"
        XCTAssertEqual(ModelUpdateReviewPresentation.preparationTitle(preparation), "Review converter installation")
        XCTAssertEqual(ModelUpdateReviewPresentation.preparationAction(preparation), "Install converter and review preparation")
        preparation.operation = .observeConversion
        XCTAssertEqual(ModelUpdateReviewPresentation.preparationTitle(preparation), "Review saved conversion")
        XCTAssertEqual(ModelUpdateReviewPresentation.preparationAction(preparation), "Continue preparation and verification")
    }

    func testRecoveryActionNamesOnlyTheCapturedFailedFiles() {
        let empty = ModelUpdateRecoveryReview(recordID: UUID(), snapshots: [], failedReceipts: [], queueItems: ["failed-job"], resetsDownload: false)
        XCTAssertEqual(ModelUpdateReviewPresentation.recoveryAction(empty), "Retry failed preparation")
        let snapshot = QuarantineFileSnapshot(path: "/models/failed-output", bytes: 100, device: 1, inode: 2,
            modifiedAt: Date(), createdAt: Date())
        let files = ModelUpdateRecoveryReview(recordID: UUID(), snapshots: [snapshot], failedReceipts: [], queueItems: [], resetsDownload: true)
        XCTAssertEqual(ModelUpdateReviewPresentation.recoveryAction(files), "Quarantine failed files and retry")
    }

    private func review(kind: ModelUpdateConversionRecipe.Kind? = nil, bits: Int = 4,
                        supported: [Int]? = nil, file: String? = "model.gguf", files: [String]? = nil) -> ModelUpdateReview {
        let revision = String(repeating: "b", count: 40)
        let gguf = kind != .repository
        let resolution = IntakeResolution(schema: "intake/1",
            source: IntakeSource(input: "org/model", repo: "org/model", revision: revision,
                file: gguf ? file : nil, subfolder: nil, url: "https://huggingface.co/org/model"),
            verdict: gguf ? .gguf : .convertible, reasons: [], backend: "mlx-lm", backendInstalled: true,
            modelType: "qwen2", components: [], task: nil, customCode: false, gated: false,
            libraryName: nil, pipelineTag: nil, transformersVersion: nil, bytes: 1, downloadBytes: nil,
            estimatedOutputBytes: nil, qBits: supported, recipe: nil,
            files: IntakeFiles(safetensors: 1, gguf: (files ?? ["model.gguf", "vision/mmproj.gguf"]).map {
                .init(name: $0, bytes: 1)
            }, python: []),
            warnings: [])
        let previous = ModelUpdatePreviousModel(repo: "org/model", path: "/models/old", signature: "old",
            revision: String(repeating: "a", count: 40), displayName: "Old model", canQuarantine: false,
            retentionReason: nil, file: gguf ? "model.gguf" : nil)
        return ModelUpdateReview(id: UUID(), repo: "org/model", previous: previous, resolution: resolution,
            targetRevision: revision, destinationPath: "/models/new", previewHash: "download", endpointSummary: [],
            conversion: kind.map { .init(kind: $0, qBits: bits, backend: $0 == .repository ? "mlx-lm" : nil, modelType: nil) },
            downloadDirectory: kind == nil ? nil : "/models/download")
    }
}
