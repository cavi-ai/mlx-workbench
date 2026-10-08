import XCTest

/// Static checks over the SwiftUI sources so the design tokens stay the only
/// way to pick a font, a color, a spacing, a radius, a tint or a curve, and
/// routes stay typed.
final class DesignLintTests: XCTestCase {
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
        ]
        for line in clean {
            XCTAssertEqual(Self.violations(in: line, file: "Sample.swift"), [], "unexpected violation: \(line)")
        }
    }
}
