import XCTest
import AppKit
import Observation
import SwiftUI

@testable import mlx_workbench

/// Tokens resolve through the stored theme, and every theme stays opaque,
/// stepped and legible in each appearance it draws.
final class WorkbenchThemeTests: XCTestCase {
    private var previous = WorkbenchTheme.system

    override func setUp() {
        super.setUp()
        previous = WorkbenchThemeState.shared.theme
    }

    override func tearDown() {
        WorkbenchThemeState.shared.theme = previous
        super.tearDown()
    }

    @MainActor
    func testStoredThemeSelectsTheColorsTheTokensDraw() throws {
        let suite = "workbench-theme-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))

        XCTAssertEqual(WorkbenchTheme.stored(in: defaults), .system)
        defaults.set("retired", forKey: WorkbenchTheme.storageKey)
        XCTAssertEqual(WorkbenchTheme.stored(in: defaults), .system)

        func canvas(storing theme: WorkbenchTheme, in appearance: NSAppearance) -> NSColor {
            defaults.set(theme.rawValue, forKey: WorkbenchTheme.storageKey)
            WorkbenchThemeState.shared.theme = WorkbenchTheme.stored(in: defaults)
            return resolved(WorkbenchColor.canvas, in: appearance)
        }
        let midnight = canvas(storing: .midnight, in: dark)
        let graphite = canvas(storing: .graphite, in: dark)
        let paper = canvas(storing: .paper, in: light)
        XCTAssertLessThan(luminance(midnight), 0.01)
        XCTAssertGreaterThan(luminance(graphite), luminance(midnight))
        XCTAssertGreaterThan(luminance(paper), 0.8)

        // A view that read a token is invalidated when the theme changes.
        let invalidated = expectation(description: "token reader invalidated")
        withObservationTracking { _ = WorkbenchColor.surface } onChange: { invalidated.fulfill() }
        WorkbenchThemeState.shared.theme = .midnight
        wait(for: [invalidated], timeout: 1)
    }

    @MainActor
    func testEveryThemeIsOpaqueSteppedAndLegible() throws {
        for theme in WorkbenchTheme.allCases {
            WorkbenchThemeState.shared.theme = theme
            let names: [NSAppearance.Name] = switch theme.colorScheme {
            case nil: [.aqua, .darkAqua]
            case .light?: [.aqua]
            default: [.darkAqua]
            }
            for name in names {
                let appearance = try XCTUnwrap(NSAppearance(named: name))
                let context = "\(theme.rawValue) \(name.rawValue)"
                let canvas = resolved(WorkbenchColor.canvas, in: appearance)
                let surface = resolved(WorkbenchColor.surface, in: appearance)
                let well = resolved(WorkbenchColor.well, in: appearance)
                let sidebar = resolved(WorkbenchColor.sidebar, in: appearance)
                for background in [canvas, surface, well, sidebar] {
                    XCTAssertEqual(background.alphaComponent, 1, context)
                }
                XCTAssertGreaterThanOrEqual(ratio(surface, canvas), 1.1, context)
                XCTAssertGreaterThanOrEqual(ratio(well, canvas), 1.1, context)
                XCTAssertGreaterThanOrEqual(ratio(well, surface), 1.1, context)
                for background in [canvas, surface, well] {
                    XCTAssertGreaterThanOrEqual(ratio(resolved(WorkbenchColor.ink, in: appearance), background), 7, context)
                    XCTAssertGreaterThanOrEqual(ratio(resolved(WorkbenchColor.muted, in: appearance), background), 4.5, context)
                    XCTAssertGreaterThanOrEqual(ratio(resolved(WorkbenchColor.accent, in: appearance), background), 4.5, context)
                    for category in ModelCategory.allCases {
                        XCTAssertGreaterThanOrEqual(ratio(resolved(category.color, in: appearance), background), 4.5,
                                                    context + " " + category.rawValue)
                    }
                }
                XCTAssertGreaterThanOrEqual(ratio(resolved(WorkbenchColor.onAccent, in: appearance),
                                                  resolved(WorkbenchColor.action, in: appearance)), 7, context)
            }
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

    private func luminance(_ color: NSColor) -> Double {
        let values = [color.redComponent, color.greenComponent, color.blueComponent].map { value -> Double in
            let channel = Double(value)
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
    }

    private func ratio(_ foreground: NSColor, _ background: NSColor) -> Double {
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
